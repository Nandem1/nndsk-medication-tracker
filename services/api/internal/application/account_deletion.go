package application

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"medication-tracker/services/api/internal/domain"
)

// DeletedAccountName replaces the name of an author kept for another patient's history.
const DeletedAccountName = "Cuenta eliminada"

type DeleteAccountCommand struct {
	Mutation
	Confirm string
}

// DeleteAccount removes the actor's own history in one transaction and keeps other patients'
// history intact. It stores no replay row, which would keep data of the account being removed:
// a retry finds an empty account and succeeds again, so the effect stays idempotent.
func (s *Service) DeleteAccount(ctx context.Context, c DeleteAccountCommand) error {
	if !domain.ValidID(c.ActorID) || !domain.ValidID(c.OperationID) || c.Confirm != "BORRAR" {
		return ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SET LOCAL app.account_deletion='on'`); err != nil {
		return err
	}
	if err = closePoolGate(ctx, tx); err != nil {
		return err
	}
	err = tx.QueryRow(ctx, `SELECT id::text FROM users WHERE id=$1 FOR UPDATE`, c.ActorID).Scan(new(string))
	if errors.Is(err, pgx.ErrNoRows) {
		// A concurrent retry already finished.
		return nil
	}
	if err != nil {
		return err
	}
	if err = s.leaveAllPools(ctx, tx, c); err != nil {
		return translate(err)
	}
	if err = leaveFamilies(ctx, tx, c.ActorID, s.now().UTC()); err != nil {
		return translate(err)
	}
	if err = s.revokeCaregiving(ctx, tx, c.ActorID); err != nil {
		return translate(err)
	}
	if err = removeOwnHistory(ctx, tx, c.ActorID); err != nil {
		return translate(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE users SET display_name=$2,auth_provider_uid='deleted-'||gen_random_uuid()::text,profile_completed_at=$3,profile_version=profile_version+1 WHERE id=$1`, c.ActorID, DeletedAccountName, s.now().UTC()); err != nil {
		return err
	}
	// Foreign history restricts this row. If it is referenced, the anonymized author stays.
	nested, err := tx.Begin(ctx)
	if err != nil {
		return err
	}
	if _, err = nested.Exec(ctx, `DELETE FROM users WHERE id=$1`, c.ActorID); err != nil {
		var pg *pgconn.PgError
		if !errors.As(err, &pg) || (pg.Code != "23503" && pg.Code != "23001") {
			_ = nested.Rollback(ctx)
			return err
		}
		if err = nested.Rollback(ctx); err != nil {
			return err
		}
	} else if err = nested.Commit(ctx); err != nil {
		return err
	}
	return translate(tx.Commit(ctx))
}

// ForgetIdentity removes a row recreated by a request that arrived between the deletion and the
// removal of the login. If history references it, the row stays and holds nothing else.
func (s *Service) ForgetIdentity(ctx context.Context, uid string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM users WHERE auth_provider_uid=$1`, uid)
	return err
}

func (s *Service) leaveAllPools(ctx context.Context, tx pgx.Tx, c DeleteAccountCommand) error {
	rows, err := tx.Query(ctx, `SELECT pool_id::text,account_id::text FROM inventory_pool_members WHERE patient_user_id=$1 AND status IN ('pending','accepted') ORDER BY pool_id,account_id`, c.ActorID)
	if err != nil {
		return err
	}
	type member struct{ pool, account string }
	members := []member{}
	for rows.Next() {
		var m member
		if err = rows.Scan(&m.pool, &m.account); err != nil {
			rows.Close()
			return err
		}
		members = append(members, m)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	now := s.now().UTC()
	for _, m := range members {
		var status string
		if err = tx.QueryRow(ctx, `SELECT status FROM inventory_pools WHERE id=$1 FOR UPDATE`, m.pool).Scan(&status); err != nil {
			return err
		}
		accounts, e := poolAccounts(ctx, tx, m.pool)
		if e != nil {
			return e
		}
		if err = lockAccounts(ctx, tx, append(accounts, m.account)); err != nil {
			return err
		}
		if status == "active" {
			leave := LeavePoolCommand{Mutation: Mutation{ActorID: c.ActorID, OperationID: derivedOperation(c.OperationID, "leave/"+m.account)}, PoolID: m.pool, AccountID: m.account}
			if err = transferOut(ctx, tx, leave, accounts, now); err != nil {
				return err
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE inventory_pool_members SET status='left',decided_by=$3,decided_at=$4 WHERE pool_id=$1 AND account_id=$2`, m.pool, m.account, c.ActorID, now); err != nil {
			return err
		}
		if _, err = settlePool(ctx, tx, m.pool, now); err != nil {
			return err
		}
	}
	return nil
}

// revokeCaregiving ends this person's access to others. Those links belong to the other
// patients' consent history, so they are revoked and audited, not removed.
func (s *Service) revokeCaregiving(ctx context.Context, tx pgx.Tx, actor string) error {
	now := s.now().UTC()
	if _, err := tx.Exec(ctx, `INSERT INTO caregiver_link_events(link_id,actor_user_id,action,scopes,created_at) SELECT id,$1,'revoked',scopes,$2 FROM caregiver_links WHERE caregiver_user_id=$1 AND status<>'revoked'`, actor, now); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE caregiver_links SET status='revoked',revoked_at=$2 WHERE caregiver_user_id=$1 AND status<>'revoked'`, actor, now)
	return err
}

func removeOwnHistory(ctx context.Context, tx pgx.Tx, actor string) error {
	const own = `(SELECT id FROM treatments WHERE patient_user_id=$1)`
	const ownAccounts = `(SELECT id FROM inventory_accounts WHERE patient_user_id=$1)`
	const links = `(SELECT id FROM caregiver_links WHERE patient_user_id=$1 OR caregiver_user_id=$1)`
	for _, statement := range []string{
		// Replay responses of other people name this person or their records, so they go too.
		`DELETE FROM operations o USING user_profile_changes c WHERE c.user_id=$1 AND c.actor_user_id=o.actor_user_id AND c.client_operation_id=o.client_operation_id`,
		`DELETE FROM operations WHERE (response->>'patient_id')::uuid=$1 OR (response->>'caregiver_id')::uuid=$1 OR response->>'CountID' IN (SELECT id::text FROM inventory_counts WHERE inventory_account_id IN ` + ownAccounts + `) OR response->>'DoseID' IN (SELECT id::text FROM dose_occurrences WHERE treatment_id IN ` + own + `) OR response->>'TreatmentID' IN (SELECT id::text FROM treatments WHERE patient_user_id=$1) OR response->>'AccountID' IN (SELECT id::text FROM inventory_accounts WHERE patient_user_id=$1) OR response->>'MovementID' IN (SELECT id::text FROM inventory_movements WHERE inventory_account_id IN ` + ownAccounts + `)`,
		`DELETE FROM operations WHERE actor_user_id=$1`,
		`DELETE FROM notification_outbox WHERE link_id IN ` + links + ` OR device_id IN (SELECT id FROM device_registrations WHERE user_id=$1) OR account_id IN ` + ownAccounts + ` OR dose_id IN (SELECT id FROM dose_occurrences WHERE treatment_id IN ` + own + `)`,
		`DELETE FROM caregiver_alert_preferences WHERE link_id IN ` + links,
		`DELETE FROM notification_frequency WHERE user_id=$1`,
		`DELETE FROM device_registrations WHERE user_id=$1`,
		`DELETE FROM active_consumptions WHERE treatment_id IN ` + own,
		`UPDATE dose_occurrences SET current_event_id=NULL,status='pending',cancelled_at=NULL WHERE treatment_id IN ` + own,
		`DELETE FROM inventory_counts WHERE inventory_account_id IN ` + ownAccounts,
		`DELETE FROM inventory_movements WHERE inventory_account_id IN ` + ownAccounts,
		`DELETE FROM dose_events WHERE treatment_id IN ` + own,
		`DELETE FROM dose_occurrences WHERE treatment_id IN ` + own,
		`DELETE FROM schedule_revisions WHERE treatment_id IN ` + own,
		`DELETE FROM inventory_accounts WHERE patient_user_id=$1`,
		`DELETE FROM treatment_changes WHERE treatment_id IN ` + own,
		`DELETE FROM treatments WHERE patient_user_id=$1`,
		`DELETE FROM medications WHERE patient_user_id=$1`,
		`DELETE FROM caregiver_link_events WHERE link_id IN (SELECT id FROM caregiver_links WHERE patient_user_id=$1)`,
		`DELETE FROM caregiver_links WHERE patient_user_id=$1`,
		// Los vínculos de otras personas pueden nacer de la invitación que esta persona aceptó.
		`DELETE FROM caregiver_alert_preferences WHERE consent_id IN (SELECT id FROM invitations WHERE consumed_by=$1 OR (inviter_user_id=$1 AND consumed_at IS NULL))`,
		`UPDATE caregiver_links SET accepted_invitation_id=NULL WHERE accepted_invitation_id IN (SELECT id FROM invitations WHERE consumed_by=$1 OR (inviter_user_id=$1 AND consumed_at IS NULL))`,
		`DELETE FROM invitations WHERE consumed_by=$1 OR (inviter_user_id=$1 AND consumed_at IS NULL)`,
		`DELETE FROM patients WHERE user_id=$1`,
		`DELETE FROM user_profile_changes WHERE user_id=$1`,
		`DELETE FROM inventory_pool_members WHERE patient_user_id=$1`,
	} {
		if _, err := tx.Exec(ctx, statement, actor); err != nil {
			return err
		}
	}
	return nil
}
