package application

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

type TreatmentView struct {
	ID            string
	MedicationID  string
	Name          string
	StrengthLabel string
	Form          string
	PackageLabel  string
	Instructions  string
	StartsOn      string
	EndsOn        *string
	Version       int64
	AccountID     string
	Unit          string
	RevisionID    string
	Schedule      domain.Schedule
}
type DoseView struct {
	ID          string    `json:"dose_id"`
	TreatmentID string    `json:"treatment_id"`
	RevisionID  string    `json:"revision_id"`
	ScheduledAt time.Time `json:"scheduled_at"`
	LocalDate   string    `json:"local_date"`
	LocalTime   string    `json:"local_time"`
	Timezone    string    `json:"timezone"`
	DSTAdjusted bool      `json:"dst_adjusted"`
	Quantity    string    `json:"quantity"`
	State       string    `json:"state"`
	Version     int64     `json:"version"`
	EventID     *string   `json:"event_id"`
}
type InventoryView struct {
	AccountID   string
	TreatmentID string
	Projection  Projection
}

const PageSize = 100

func validCursor(cursor string) bool { return cursor == "" || domain.ValidID(cursor) }
func cursorValue(cursor string) string {
	if cursor == "" {
		return "00000000-0000-0000-0000-000000000000"
	}
	return cursor
}

func (s *Service) Treatments(ctx context.Context, actor, patient, cursor string) ([]TreatmentView, string, error) {
	if !validCursor(cursor) {
		return nil, "", ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, actor, patientTarget(patient), ScopeRead); err != nil {
		return nil, "", err
	}
	rows, err := tx.Query(ctx, `SELECT t.id::text,t.medication_id::text,m.name,m.strength_label,m.form,m.package_label,t.instructions_text,t.starts_on::text,t.ends_on::text,t.version,a.id::text,a.unit,r.id::text,r.rules_json FROM treatments t JOIN medications m ON m.id=t.medication_id JOIN inventory_accounts a ON a.treatment_id=t.id JOIN LATERAL (SELECT id,rules_json FROM schedule_revisions WHERE treatment_id=t.id ORDER BY revision_number DESC LIMIT 1) r ON true WHERE t.patient_user_id=$1 AND t.id>$2::uuid ORDER BY t.id LIMIT 101`, patient, cursorValue(cursor))
	if err != nil {
		return nil, "", err
	}
	out := []TreatmentView{}
	for rows.Next() {
		var v TreatmentView
		var rules []byte
		err = rows.Scan(&v.ID, &v.MedicationID, &v.Name, &v.StrengthLabel, &v.Form, &v.PackageLabel, &v.Instructions, &v.StartsOn, &v.EndsOn, &v.Version, &v.AccountID, &v.Unit, &v.RevisionID, &rules)
		if err == nil {
			err = json.Unmarshal(rules, &v.Schedule)
		}
		if err != nil {
			rows.Close()
			return nil, "", err
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
func (s *Service) Agenda(ctx context.Context, actor, patient, from, to, cursor string) ([]DoseView, string, error) {
	start, err := domain.ParseDate(from)
	if err != nil {
		return nil, "", ErrInvalid
	}
	end, err := domain.ParseDate(to)
	if err != nil || !end.After(start) || end.Sub(start) > domain.HorizonDays*24*time.Hour || !validCursor(cursor) {
		return nil, "", ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, actor, patientTarget(patient), ScopeRead); err != nil {
		return nil, "", err
	}
	rows, err := tx.Query(ctx, `SELECT id::text FROM treatments WHERE patient_user_id=$1 ORDER BY id`, patient)
	if err != nil {
		return nil, "", err
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return nil, "", err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, "", err
	}
	for _, id := range ids {
		if _, err = generateOccurrences(ctx, tx, id, from, int(end.Sub(start)/(24*time.Hour))); err != nil {
			return nil, "", err
		}
	}
	rows, err = tx.Query(ctx, `SELECT d.id::text,d.treatment_id::text,d.schedule_revision_id::text,d.scheduled_at,d.scheduled_local_date::text,to_char(d.scheduled_local_time,'HH24:MI'),r.timezone,d.dst_adjusted,d.dose_quantity::text,d.status,d.version,d.current_event_id::text FROM dose_occurrences d JOIN treatments t ON t.id=d.treatment_id JOIN schedule_revisions r ON r.id=d.schedule_revision_id WHERE t.patient_user_id=$1 AND d.cancelled_at IS NULL AND d.scheduled_local_date >= $2::date AND d.scheduled_local_date < $3::date AND d.id>$4::uuid ORDER BY d.id LIMIT 101`, patient, from, to, cursorValue(cursor))
	if err != nil {
		return nil, "", err
	}
	out := []DoseView{}
	for rows.Next() {
		var v DoseView
		if err = rows.Scan(&v.ID, &v.TreatmentID, &v.RevisionID, &v.ScheduledAt, &v.LocalDate, &v.LocalTime, &v.Timezone, &v.DSTAdjusted, &v.Quantity, &v.State, &v.Version, &v.EventID); err != nil {
			rows.Close()
			return nil, "", err
		}
		v.State = domain.DoseState(v.State).Display(v.ScheduledAt, s.now())
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
func (s *Service) Inventory(ctx context.Context, actor, patient, cursor string) ([]InventoryView, string, error) {
	if !validCursor(cursor) {
		return nil, "", ErrInvalid
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, actor, patientTarget(patient), ScopeRead); err != nil {
		return nil, "", err
	}
	rows, err := tx.Query(ctx, `SELECT id::text,treatment_id::text FROM inventory_accounts WHERE patient_user_id=$1 AND id>$2::uuid ORDER BY id LIMIT 101`, patient, cursorValue(cursor))
	if err != nil {
		return nil, "", err
	}
	out := []InventoryView{}
	for rows.Next() {
		var v InventoryView
		if err = rows.Scan(&v.AccountID, &v.TreatmentID); err != nil {
			rows.Close()
			return nil, "", err
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
		next = out[PageSize-1].AccountID
	}
	for i := range out {
		out[i].Projection, err = inventoryProjection(ctx, tx, out[i].AccountID, s.now())
		if err != nil {
			return nil, "", err
		}
	}
	return out, next, tx.Commit(ctx)
}
