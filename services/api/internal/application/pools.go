package application

import (
	"context"
	"crypto/sha256"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

// UnknownPoolMember replaces the name of a member the actor has no access to.
const UnknownPoolMember = "otra persona"

// poolGate orders membership changes against inventory locks. Lockers share it and read a
// membership that cannot change until they commit. Global order: gate, row locks, pool, accounts by id.
const poolGate = 7205759403792793

func takePoolGate(ctx context.Context, tx pgx.Tx, kind string) error {
	switch kind {
	case "create_pool", "leave_pool":
		return closePoolGate(ctx, tx)
	}
	return sharePoolGate(ctx, tx)
}
func sharePoolGate(ctx context.Context, tx pgx.Tx) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock_shared($1)`, int64(poolGate))
	return err
}

type CreatePoolCommand struct {
	Mutation
	AccountIDs []string
	// El saldo común parte de lo que hay en la caja, contado desde esta cuenta.
	CountedAccountID string
	CountedQuantity  domain.Quantity
}
type LeavePoolCommand struct {
	Mutation
	PoolID    string
	AccountID string
}
type PoolResult struct {
	PoolID string `json:"pool_id"`
	Status string `json:"status"`
}
type PoolMember struct {
	PatientDisplayName *string `json:"patient_display_name"`
	You                bool    `json:"you"`
	Current            bool    `json:"current"`
	Status             string  `json:"status"`
}
type PoolView struct {
	PoolID  string       `json:"pool_id"`
	Status  string       `json:"status"`
	Members []PoolMember `json:"members"`
}
type PoolCandidate struct {
	AccountID          string  `json:"account_id"`
	TreatmentID        string  `json:"treatment_id"`
	PatientID          string  `json:"patient_id"`
	PatientDisplayName *string `json:"patient_display_name"`
	You                bool    `json:"you"`
}
type MovementView struct {
	ID                 string    `json:"movement_id"`
	Quantity           string    `json:"quantity_delta"`
	Reason             string    `json:"reason"`
	Note               string    `json:"note"`
	ActorID            string    `json:"actor_id"`
	CreatedAt          time.Time `json:"created_at"`
	Shared             bool      `json:"shared"`
	PatientDisplayName *string   `json:"patient_display_name,omitempty"`
}

func activePool(ctx context.Context, tx pgx.Tx, account string) (string, error) {
	var pool string
	err := tx.QueryRow(ctx, `SELECT p.id::text FROM inventory_pool_members m JOIN inventory_pools p ON p.id=m.pool_id WHERE m.account_id=$1 AND m.status='accepted' AND p.status='active'`, account).Scan(&pool)
	if err == pgx.ErrNoRows {
		return "", nil
	}
	return pool, err
}

func poolAccounts(ctx context.Context, tx pgx.Tx, pool string) ([]string, error) {
	rows, err := tx.Query(ctx, `SELECT account_id::text FROM inventory_pool_members WHERE pool_id=$1 AND status='accepted' ORDER BY account_id`, pool)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// sharedAccounts lists the accounts behind a balance: the account alone, or its active pool.
func sharedAccounts(ctx context.Context, tx pgx.Tx, account string) ([]string, error) {
	pool, err := activePool(ctx, tx, account)
	if err != nil {
		return nil, err
	}
	if pool == "" {
		return []string{account}, nil
	}
	return poolAccounts(ctx, tx, pool)
}

func lockAccounts(ctx context.Context, tx pgx.Tx, accounts []string) error {
	rows, err := tx.Query(ctx, `SELECT id FROM inventory_accounts WHERE id=ANY($1::uuid[]) ORDER BY id FOR UPDATE`, accounts)
	if err != nil {
		return err
	}
	rows.Close()
	return rows.Err()
}

// lockInventory locks what an account's balance depends on and returns its treatment.
func lockInventory(ctx context.Context, tx pgx.Tx, account string) (string, error) {
	if err := sharePoolGate(ctx, tx); err != nil {
		return "", err
	}
	var treatment string
	if err := tx.QueryRow(ctx, `SELECT treatment_id::text FROM inventory_accounts WHERE id=$1`, account).Scan(&treatment); err != nil {
		return "", translate(err)
	}
	pool, err := activePool(ctx, tx, account)
	if err != nil {
		return "", err
	}
	accounts := []string{account}
	if pool != "" {
		if _, err = tx.Exec(ctx, `SELECT id FROM inventory_pools WHERE id=$1 FOR UPDATE`, pool); err != nil {
			return "", err
		}
		if accounts, err = poolAccounts(ctx, tx, pool); err != nil {
			return "", err
		}
	}
	return treatment, lockAccounts(ctx, tx, accounts)
}

func closePoolGate(ctx context.Context, tx pgx.Tx) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, int64(poolGate))
	return err
}

func medicationKey(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

type poolAccount struct {
	id, patient, name, strength, form, unit string
	archived                                *time.Time
	threshold                               int
}

func (a poolAccount) sameMedication(b poolAccount) bool {
	return medicationKey(a.name) == medicationKey(b.name) && medicationKey(a.strength) == medicationKey(b.strength) && medicationKey(a.form) == medicationKey(b.form) && a.unit == b.unit
}

const poolAccountQuery = `SELECT a.id::text,a.patient_user_id::text,m.name,m.strength_label,m.form,a.unit,t.archived_at,a.low_stock_days_threshold FROM inventory_accounts a JOIN treatments t ON t.id=a.treatment_id JOIN medications m ON m.id=t.medication_id`

func scanPoolAccount(row pgx.Row) (poolAccount, error) {
	var a poolAccount
	err := row.Scan(&a.id, &a.patient, &a.name, &a.strength, &a.form, &a.unit, &a.archived, &a.threshold)
	return a, err
}

func (s *Service) CreateInventoryPool(ctx context.Context, c CreatePoolCommand) (PoolResult, error) {
	ids := make([]string, len(c.AccountIDs))
	for i, id := range c.AccountIDs {
		ids[i] = strings.ToLower(id)
	}
	slices.Sort(ids)
	c.CountedAccountID = strings.ToLower(c.CountedAccountID)
	if len(ids) < 2 || len(slices.Compact(ids)) != len(c.AccountIDs) || !slices.Contains(ids, c.CountedAccountID) || c.CountedQuantity < 0 || !c.CountedQuantity.Valid() {
		return PoolResult{}, ErrInvalid
	}
	return transact(ctx, s, c.Mutation, accountTarget(ids[0]), ScopeInventory, "create_pool", c, func(tx pgx.Tx) (PoolResult, error) {
		var zero PoolResult
		for _, id := range ids[1:] {
			if err := authorize(ctx, tx, c.ActorID, accountTarget(id), ScopeInventory); err != nil {
				return zero, err
			}
		}
		if err := closePoolGate(ctx, tx); err != nil {
			return zero, err
		}
		if err := lockAccounts(ctx, tx, ids); err != nil {
			return zero, err
		}
		accounts := make([]poolAccount, 0, len(ids))
		for _, id := range ids {
			account, err := scanPoolAccount(tx.QueryRow(ctx, poolAccountQuery+` WHERE a.id=$1`, id))
			if err != nil {
				return zero, err
			}
			if account.archived != nil || (len(accounts) > 0 && !account.sameMedication(accounts[0])) {
				return zero, ErrInvalid
			}
			accounts = append(accounts, account)
		}
		var live int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM inventory_pool_members WHERE account_id=ANY($1::uuid[]) AND status IN ('pending','accepted')`, ids).Scan(&live); err != nil {
			return zero, err
		}
		if live > 0 {
			return zero, ErrConflict
		}
		now := s.now().UTC()
		out := PoolResult{PoolID: domain.NewID(), Status: "active"}
		threshold := accounts[0].threshold
		for _, account := range accounts[1:] {
			threshold = min(threshold, account.threshold)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO inventory_pools(id,status,created_by,client_operation_id,created_at,activated_at,low_stock_days_threshold) VALUES($1,'active',$2,$3,$4,$4,$5)`, out.PoolID, c.ActorID, c.OperationID, now, threshold); err != nil {
			return zero, err
		}
		for _, account := range accounts {
			if _, err := tx.Exec(ctx, `INSERT INTO inventory_pool_members(pool_id,account_id,patient_user_id,status,decided_by,decided_at) VALUES($1,$2,$3,'accepted',$4,$5)`, out.PoolID, account.id, account.patient, c.ActorID, now); err != nil {
				return zero, err
			}
		}
		return out, countSharedBox(ctx, tx, c, ids, now)
	})
}

// countSharedBox deja el saldo común igual a lo contado: sumar dos saldos de una misma caja
// la contaría dos veces. El ajuste es un conteo físico auditable en la cuenta indicada.
func countSharedBox(ctx context.Context, tx pgx.Tx, c CreatePoolCommand, accounts []string, now time.Time) error {
	current, err := balanceOf(ctx, tx, accounts)
	if err != nil {
		return err
	}
	delta := c.CountedQuantity - current
	if !delta.Valid() {
		return ErrInvalid
	}
	var treatment string
	if err = tx.QueryRow(ctx, `SELECT treatment_id::text FROM inventory_accounts WHERE id=$1`, c.CountedAccountID).Scan(&treatment); err != nil {
		return err
	}
	var movementID *string
	if delta != 0 {
		id, err := movement(ctx, tx, c.Mutation, c.CountedAccountID, treatment, delta, "manual_adjustment", nil, nil, now)
		if err != nil {
			return err
		}
		movementID = &id
	}
	_, err = tx.Exec(ctx, `INSERT INTO inventory_counts(inventory_account_id,actor_user_id,client_operation_id,previous_balance,counted_quantity,reason,movement_id,created_at) VALUES($1,$2,$3,$4::numeric,$5::numeric,'Conteo al compartir la caja',$6,$7)`, c.CountedAccountID, c.ActorID, c.OperationID, current.String(), c.CountedQuantity.String(), movementID, now)
	return err
}

// settlePool applies the rules that follow any change in membership and returns the status.
func settlePool(ctx context.Context, tx pgx.Tx, pool string, now time.Time) (string, error) {
	var status string
	if err := tx.QueryRow(ctx, `SELECT status FROM inventory_pools WHERE id=$1`, pool).Scan(&status); err != nil {
		return "", err
	}
	var live int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM inventory_pool_members WHERE pool_id=$1 AND status='accepted'`, pool).Scan(&live); err != nil {
		return "", err
	}
	if live >= 2 {
		return status, nil
	}
	// La cuenta restante conserva su saldo y queda libre para compartir otra vez.
	if _, err := tx.Exec(ctx, `UPDATE inventory_pool_members SET status='left',decided_at=$2 WHERE pool_id=$1 AND status='accepted'`, pool, now); err != nil {
		return "", err
	}
	_, err := tx.Exec(ctx, `UPDATE inventory_pools SET status='dissolved',dissolved_at=$2 WHERE id=$1`, pool, now)
	return "dissolved", err
}

// derivedOperation gives the second movement of a transfer its own stable operation key.
func derivedOperation(operation, account string) string {
	b := sha256.Sum256([]byte(strings.ToLower(operation + "/" + account)))
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func (s *Service) LeaveInventoryPool(ctx context.Context, c LeavePoolCommand) (PoolResult, error) {
	if !domain.ValidID(c.PoolID) {
		return PoolResult{}, ErrInvalid
	}
	c.AccountID = strings.ToLower(c.AccountID)
	return transact(ctx, s, c.Mutation, accountTarget(c.AccountID), ScopeInventory, "leave_pool", c, func(tx pgx.Tx) (PoolResult, error) {
		var zero PoolResult
		if err := closePoolGate(ctx, tx); err != nil {
			return zero, err
		}
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM inventory_pools WHERE id=$1 FOR UPDATE`, c.PoolID).Scan(&status); err != nil {
			return zero, err
		}
		accounts, err := poolAccounts(ctx, tx, c.PoolID)
		if err != nil {
			return zero, err
		}
		var member string
		err = tx.QueryRow(ctx, `SELECT status FROM inventory_pool_members WHERE pool_id=$1 AND account_id=$2 AND status IN ('pending','accepted')`, c.PoolID, c.AccountID).Scan(&member)
		if err != nil {
			return zero, err
		}
		if err = lockAccounts(ctx, tx, append(accounts, c.AccountID)); err != nil {
			return zero, err
		}
		now := s.now().UTC()
		if status == "active" {
			if err = transferOut(ctx, tx, c, accounts, now); err != nil {
				return zero, err
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE inventory_pool_members SET status='left',decided_by=$3,decided_at=$4 WHERE pool_id=$1 AND account_id=$2`, c.PoolID, c.AccountID, c.ActorID, now); err != nil {
			return zero, err
		}
		settled, err := settlePool(ctx, tx, c.PoolID, now)
		return PoolResult{c.PoolID, settled}, err
	})
}

// transferOut leaves the box with those who stay: both movements are audited and sum to zero.
func transferOut(ctx context.Context, tx pgx.Tx, c LeavePoolCommand, accounts []string, now time.Time) error {
	amount, err := accountBalance(ctx, tx, c.AccountID)
	if err != nil || amount == 0 {
		return err
	}
	remaining := ""
	for _, account := range accounts {
		if account != c.AccountID {
			remaining = account
			break
		}
	}
	if remaining == "" {
		return ErrConflict
	}
	for _, leg := range []struct {
		account   string
		quantity  domain.Quantity
		operation string
	}{{c.AccountID, -amount, c.OperationID}, {remaining, amount, derivedOperation(c.OperationID, remaining)}} {
		var treatment string
		if err = tx.QueryRow(ctx, `SELECT treatment_id::text FROM inventory_accounts WHERE id=$1`, leg.account).Scan(&treatment); err != nil {
			return err
		}
		if _, err = movement(ctx, tx, Mutation{ActorID: c.ActorID, OperationID: leg.operation}, leg.account, treatment, leg.quantity, "pool_transfer", nil, nil, now); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) PoolCandidates(ctx context.Context, actor, account string) ([]PoolCandidate, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, actor, accountTarget(account), ScopeInventory); err != nil {
		return nil, err
	}
	base, err := scanPoolAccount(tx.QueryRow(ctx, poolAccountQuery+` WHERE a.id=$1`, account))
	if err != nil {
		return nil, translate(err)
	}
	out := []PoolCandidate{}
	var live int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM inventory_pool_members WHERE account_id=$1 AND status IN ('pending','accepted')`, account).Scan(&live); err != nil {
		return nil, err
	}
	if live > 0 || base.archived != nil {
		return out, tx.Commit(ctx)
	}
	rows, err := tx.Query(ctx, `SELECT a.id::text,a.patient_user_id::text,m.name,m.strength_label,m.form,a.unit,t.archived_at,a.low_stock_days_threshold,t.id::text,CASE WHEN u.profile_completed_at IS NOT NULL THEN u.display_name END FROM inventory_accounts a JOIN treatments t ON t.id=a.treatment_id JOIN medications m ON m.id=t.medication_id JOIN users u ON u.id=a.patient_user_id WHERE a.id<>$1 AND t.archived_at IS NULL AND (a.patient_user_id=$2 OR EXISTS (SELECT 1 FROM caregiver_links l WHERE l.patient_user_id=a.patient_user_id AND l.caregiver_user_id=$2 AND l.status='active' AND 'inventory'=ANY(l.scopes))) AND NOT EXISTS (SELECT 1 FROM inventory_pool_members o WHERE o.account_id=a.id AND o.status IN ('pending','accepted')) ORDER BY a.id LIMIT 500`, account, actor)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var a poolAccount
		var v PoolCandidate
		if err = rows.Scan(&a.id, &a.patient, &a.name, &a.strength, &a.form, &a.unit, &a.archived, &a.threshold, &v.TreatmentID, &v.PatientDisplayName); err != nil {
			rows.Close()
			return nil, err
		}
		if base.sameMedication(a) {
			v.AccountID, v.PatientID, v.You = a.id, a.patient, strings.EqualFold(a.patient, actor)
			out = append(out, v)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}

// poolView applies the privacy table on the server. Members consented to share with each
// other, so they see names; a caregiver only sees those of patients linked to them.
func poolView(ctx context.Context, tx pgx.Tx, actor, account string) (*PoolView, error) {
	var view PoolView
	err := tx.QueryRow(ctx, `SELECT p.id::text,p.status FROM inventory_pool_members m JOIN inventory_pools p ON p.id=m.pool_id WHERE m.account_id=$1 AND m.status IN ('pending','accepted')`, account).Scan(&view.PoolID, &view.Status)
	if err == pgx.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, `SELECT CASE WHEN u.profile_completed_at IS NOT NULL THEN u.display_name END,m.patient_user_id=$2,m.account_id=$3,m.status,m.patient_user_id=$2 OR EXISTS (SELECT 1 FROM inventory_pool_members o WHERE o.pool_id=m.pool_id AND o.patient_user_id=$2 AND o.status IN ('pending','accepted')) OR EXISTS (SELECT 1 FROM caregiver_links l WHERE l.patient_user_id=m.patient_user_id AND l.caregiver_user_id=$2 AND l.status='active' AND 'read'=ANY(l.scopes)) FROM inventory_pool_members m JOIN users u ON u.id=m.patient_user_id WHERE m.pool_id=$1 AND m.status IN ('pending','accepted') ORDER BY m.account_id`, view.PoolID, actor, account)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	unknown := UnknownPoolMember
	for rows.Next() {
		var member PoolMember
		var visible bool
		if err = rows.Scan(&member.PatientDisplayName, &member.You, &member.Current, &member.Status, &visible); err != nil {
			return nil, err
		}
		if !visible {
			member.PatientDisplayName = &unknown
		}
		view.Members = append(view.Members, member)
	}
	return &view, rows.Err()
}

func (s *Service) InventoryMovements(ctx context.Context, actor, account, cursor string) ([]MovementView, string, error) {
	if !validCursor(cursor) {
		return nil, "", ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, actor, accountTarget(account), ScopeRead); err != nil {
		return nil, "", err
	}
	// Del resto de miembros sólo se ve lo ocurrido desde que todos consintieron.
	rows, err := tx.Query(ctx, `SELECT m.id::text,m.quantity_delta::text,m.reason,COALESCE(c.reason,''),m.actor_user_id::text,m.created_at,a.id<>$1,CASE WHEN u.profile_completed_at IS NOT NULL THEN u.display_name END,a.patient_user_id=$3 OR EXISTS (SELECT 1 FROM caregiver_links l WHERE l.patient_user_id=a.patient_user_id AND l.caregiver_user_id=$3 AND l.status='active' AND 'read'=ANY(l.scopes)) FROM inventory_movements m JOIN inventory_accounts a ON a.id=m.inventory_account_id JOIN users u ON u.id=a.patient_user_id LEFT JOIN inventory_counts c ON c.movement_id=m.id WHERE m.id>$2::uuid AND (m.inventory_account_id=$1 OR EXISTS (SELECT 1 FROM inventory_pool_members own JOIN inventory_pools p ON p.id=own.pool_id AND p.status='active' JOIN inventory_pool_members other ON other.pool_id=p.id AND other.status='accepted' WHERE own.account_id=$1 AND own.status='accepted' AND other.account_id=m.inventory_account_id AND m.created_at>=p.activated_at)) ORDER BY m.id LIMIT 101`, account, cursorValue(cursor), actor)
	if err != nil {
		return nil, "", err
	}
	out := []MovementView{}
	for rows.Next() {
		var v MovementView
		var name *string
		var visible bool
		if err = rows.Scan(&v.ID, &v.Quantity, &v.Reason, &v.Note, &v.ActorID, &v.CreatedAt, &v.Shared, &name, &visible); err != nil {
			rows.Close()
			return nil, "", err
		}
		if v.Shared && visible {
			v.PatientDisplayName = name
		}
		if v.Shared && !visible {
			v.Reason, v.Note, v.ActorID, v.PatientDisplayName = "shared_activity", "", "", nil
			v.CreatedAt = v.CreatedAt.UTC().Truncate(24 * time.Hour)
		}
		out = append(out, v)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, "", err
	}
	next := ""
	if len(out) > PageSize {
		out = out[:PageSize]
		next = out[PageSize-1].ID
	}
	return out, next, tx.Commit(ctx)
}
