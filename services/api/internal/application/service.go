package application

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"medication-tracker/services/api/internal/domain"
)

var (
	ErrForbidden = errors.New("operation is not permitted")
	ErrInvalid   = domain.ErrInvalid
	ErrConflict  = errors.New("operation conflicts with current state")
	ErrNotFound  = errors.New("record not found")
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

func New(pool *pgxpool.Pool, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{pool: pool, now: now}
}

type Mutation struct {
	ActorID     string
	OperationID string
}
type CreateTreatmentCommand struct {
	Mutation
	PatientID     string
	Name          string
	StrengthLabel string
	Form          string
	PackageLabel  string
	Instructions  string
	Unit          string
	InitialStock  domain.Quantity
	StartsOn      string
	EndsOn        string
	Schedule      domain.Schedule
}
type TreatmentResult struct {
	TreatmentID string
	RevisionID  string
	AccountID   string
	Version     int64
}
type RecordDoseEventCommand struct {
	Mutation
	DoseID          string
	ExpectedVersion int64
	State           domain.DoseState
	OccurredAt      *time.Time
}
type CorrectDoseEventCommand struct {
	Mutation
	DoseID          string
	ExpectedVersion int64
	CorrectsEventID string
	State           domain.DoseState
	OccurredAt      *time.Time
	Reason          string
}
type DoseResult struct {
	DoseID  string
	EventID string
	Version int64
	State   domain.DoseState
	Balance domain.Quantity
}
type ReplenishInventoryCommand struct {
	Mutation
	AccountID string
	Quantity  domain.Quantity
}
type InventoryResult struct {
	MovementID string
	Balance    domain.Quantity
}
type ReviseScheduleCommand struct {
	Mutation
	TreatmentID     string
	ExpectedVersion int64
	EffectiveFrom   time.Time
	Schedule        domain.Schedule
}
type Projection struct {
	LowStockDaysThreshold int
	Timezone              string
	ReplenishOn           *string
	LowStock              bool
	Balance               domain.Quantity
	Unit                  string
	From                  time.Time
	Through               time.Time
	FirstUncoveredAt      *time.Time
	ScheduledQuantity     domain.Quantity
}

func transact[T any](ctx context.Context, s *Service, m Mutation, target accessTarget, scope Scope, kind string, payload any, work func(pgx.Tx) (T, error)) (T, error) {
	var zero T
	if !domain.ValidID(m.ActorID) || !domain.ValidID(m.OperationID) {
		return zero, ErrInvalid
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return zero, ErrInvalid
	}
	fingerprint := sha256.Sum256(data)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return zero, err
	}
	defer tx.Rollback(ctx)
	// Serializing the operation key makes simultaneous retries see the committed response.
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", strings.ToLower(m.ActorID+"/"+m.OperationID)); err != nil {
		return zero, err
	}
	if err = authorize(ctx, tx, m.ActorID, target, scope); err != nil {
		return zero, err
	}
	var storedKind string
	var storedHash, response []byte
	err = tx.QueryRow(ctx, "SELECT kind,fingerprint,response FROM operations WHERE actor_user_id=$1 AND client_operation_id=$2", m.ActorID, m.OperationID).Scan(&storedKind, &storedHash, &response)
	if err == nil {
		if storedKind != kind || !bytes.Equal(storedHash, fingerprint[:]) {
			return zero, ErrConflict
		}
		var result T
		if err = json.Unmarshal(response, &result); err != nil {
			return zero, err
		}
		return result, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return zero, err
	}
	result, err := work(tx)
	if err != nil {
		return zero, translate(err)
	}
	response, err = json.Marshal(result)
	if err != nil {
		return zero, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO operations(actor_user_id,client_operation_id,kind,fingerprint,response) VALUES($1,$2,$3,$4,$5)", m.ActorID, m.OperationID, kind, fingerprint[:], response); err != nil {
		return zero, translate(err)
	}
	if err = tx.Commit(ctx); err != nil {
		return zero, translate(err)
	}
	return result, nil
}
func translate(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "23505", "40001", "40P01":
			return ErrConflict
		case "23503", "23514", "22003", "22007", "22008", "22P02":
			return ErrInvalid
		}
	}
	return err
}
func balance(ctx context.Context, tx pgx.Tx, account string) (domain.Quantity, error) {
	var value string
	err := tx.QueryRow(ctx, "SELECT COALESCE(sum(quantity_delta),0)::text FROM inventory_movements WHERE inventory_account_id=$1", account).Scan(&value)
	if err != nil {
		return 0, err
	}
	return domain.ParseQuantity(value)
}
func accountLock(ctx context.Context, tx pgx.Tx, id string) (string, error) {
	var treatment string
	err := tx.QueryRow(ctx, "SELECT treatment_id::text FROM inventory_accounts WHERE id=$1 FOR UPDATE", id).Scan(&treatment)
	return treatment, translate(err)
}
func movement(ctx context.Context, tx pgx.Tx, m Mutation, account, treatment string, quantity domain.Quantity, reason string, event, dose *string, now time.Time) (string, error) {
	id := domain.NewID()
	_, err := tx.Exec(ctx, "INSERT INTO inventory_movements(id,inventory_account_id,treatment_id,quantity_delta,reason,source_dose_event_id,dose_occurrence_id,actor_user_id,client_operation_id,created_at) VALUES($1,$2,$3,$4::numeric,$5,$6,$7,$8,$9,$10)", id, account, treatment, quantity.String(), reason, event, dose, m.ActorID, m.OperationID, now)
	return id, err
}
