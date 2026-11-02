package application

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

func (s *Service) CreateTreatment(ctx context.Context, c CreateTreatmentCommand) (TreatmentResult, error) {
	return transact(ctx, s, c.Mutation, "create_treatment", c, func(tx pgx.Tx) (TreatmentResult, error) {
		var zero TreatmentResult
		start, err := domain.ParseDate(c.StartsOn)
		if err != nil || !domain.ValidID(c.PatientID) || strings.TrimSpace(c.Name) == "" || len(c.Name) > 200 || c.InitialStock < 0 || !c.InitialStock.Valid() {
			return zero, ErrInvalid
		}
		var end *time.Time
		if c.EndsOn != "" {
			d, e := domain.ParseDate(c.EndsOn)
			if e != nil || d.Before(start) {
				return zero, ErrInvalid
			}
			end = &d
		}
		switch c.Unit {
		case "tablet", "capsule", "ml", "dose", "other":
		default:
			return zero, ErrInvalid
		}
		if err = c.Schedule.Validate(); err != nil {
			return zero, err
		}
		if _, err = tx.Exec(ctx, "INSERT INTO patients(user_id) VALUES($1) ON CONFLICT DO NOTHING", c.PatientID); err != nil {
			return zero, err
		}
		med := domain.NewID()
		if _, err = tx.Exec(ctx, "INSERT INTO medications(id,patient_user_id,name,strength_label,form,package_label) VALUES($1,$2,$3,$4,$5,$6)", med, c.PatientID, c.Name, c.StrengthLabel, c.Form, c.PackageLabel); err != nil {
			return zero, err
		}
		r := TreatmentResult{TreatmentID: domain.NewID(), RevisionID: domain.NewID(), AccountID: domain.NewID(), Version: 1}
		if _, err = tx.Exec(ctx, "INSERT INTO treatments(id,patient_user_id,medication_id,instructions_text,starts_on,ends_on) VALUES($1,$2,$3,$4,$5,$6)", r.TreatmentID, c.PatientID, med, c.Instructions, start, end); err != nil {
			return zero, err
		}
		loc, _ := time.LoadLocation(c.Schedule.Timezone)
		effective, err := domain.StartOfDay(c.StartsOn, loc)
		if err != nil {
			return zero, err
		}
		if err = insertRevision(ctx, tx, r, c.Schedule, effective, c.ActorID); err != nil {
			return zero, err
		}
		if _, err = tx.Exec(ctx, "INSERT INTO inventory_accounts(id,treatment_id,patient_user_id,unit) VALUES($1,$2,$3,$4)", r.AccountID, r.TreatmentID, c.PatientID, c.Unit); err != nil {
			return zero, err
		}
		if c.InitialStock > 0 {
			if _, err = movement(ctx, tx, c.Mutation, r.AccountID, r.TreatmentID, c.InitialStock, "initial", nil, nil, s.now().UTC()); err != nil {
				return zero, err
			}
		}
		return r, nil
	})
}
func insertRevision(ctx context.Context, tx pgx.Tx, r TreatmentResult, schedule domain.Schedule, effective time.Time, actor string) error {
	data, err := json.Marshal(schedule)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, "INSERT INTO schedule_revisions(id,treatment_id,revision_number,timezone,rules_json,effective_from,created_by) VALUES($1,$2,$3,$4,$5,$6,$7)", r.RevisionID, r.TreatmentID, r.Version, schedule.Timezone, data, effective, actor)
	return err
}
func (s *Service) ReviseSchedule(ctx context.Context, c ReviseScheduleCommand) (TreatmentResult, error) {
	return transact(ctx, s, c.Mutation, "revise_schedule", c, func(tx pgx.Tx) (TreatmentResult, error) {
		var r TreatmentResult
		if !domain.ValidID(c.TreatmentID) || c.ExpectedVersion < 1 || c.EffectiveFrom.Before(s.now()) || c.EffectiveFrom.IsZero() {
			return r, ErrInvalid
		}
		if err := c.Schedule.Validate(); err != nil {
			return r, err
		}
		var version int64
		if err := tx.QueryRow(ctx, "SELECT version FROM treatments WHERE id=$1 FOR UPDATE", c.TreatmentID).Scan(&version); err != nil {
			return r, err
		}
		if version != c.ExpectedVersion {
			return r, ErrConflict
		}
		var latest time.Time
		if err := tx.QueryRow(ctx, "SELECT max(effective_from) FROM schedule_revisions WHERE treatment_id=$1", c.TreatmentID).Scan(&latest); err != nil {
			return r, err
		}
		if !c.EffectiveFrom.After(latest) {
			return r, ErrConflict
		}
		var declared bool
		if err := tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM dose_occurrences WHERE treatment_id=$1 AND scheduled_at >= $2 AND status<>'pending')", c.TreatmentID, c.EffectiveFrom).Scan(&declared); err != nil {
			return r, err
		}
		if declared {
			return r, ErrConflict
		}
		r = TreatmentResult{TreatmentID: c.TreatmentID, RevisionID: domain.NewID(), Version: version + 1}
		if err := tx.QueryRow(ctx, "SELECT id::text FROM inventory_accounts WHERE treatment_id=$1", c.TreatmentID).Scan(&r.AccountID); err != nil {
			return r, err
		}
		if err := insertRevision(ctx, tx, r, c.Schedule, c.EffectiveFrom, c.ActorID); err != nil {
			return r, err
		}
		if _, err := tx.Exec(ctx, "UPDATE dose_occurrences SET cancelled_at=$2,version=version+1 WHERE treatment_id=$1 AND scheduled_at >= $3 AND status='pending' AND cancelled_at IS NULL", c.TreatmentID, s.now().UTC(), c.EffectiveFrom); err != nil {
			return r, err
		}
		if _, err := tx.Exec(ctx, "UPDATE treatments SET version=$2 WHERE id=$1", c.TreatmentID, r.Version); err != nil {
			return r, err
		}
		return r, nil
	})
}

type revision struct {
	id       string
	schedule domain.Schedule
	from     time.Time
	until    *time.Time
}

func revisions(ctx context.Context, tx pgx.Tx, tr string) ([]revision, error) {
	rows, err := tx.Query(ctx, "SELECT id::text,rules_json,effective_from,lead(effective_from) OVER(ORDER BY effective_from) FROM schedule_revisions WHERE treatment_id=$1 ORDER BY effective_from", tr)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []revision
	for rows.Next() {
		var r revision
		var data []byte
		if err = rows.Scan(&r.id, &data, &r.from, &r.until); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(data, &r.schedule); err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	return result, rows.Err()
}
func (s *Service) GenerateOccurrences(ctx context.Context, treatmentID, from string) (int, error) {
	if !domain.ValidID(treatmentID) {
		return 0, ErrInvalid
	}
	if _, err := domain.ParseDate(from); err != nil {
		return 0, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	var starts time.Time
	var ends *time.Time
	if err = tx.QueryRow(ctx, "SELECT starts_on,ends_on FROM treatments WHERE id=$1 FOR UPDATE", treatmentID).Scan(&starts, &ends); err != nil {
		return 0, translate(err)
	}
	revs, err := revisions(ctx, tx, treatmentID)
	if err != nil {
		return 0, err
	}
	count := 0
	for _, r := range revs {
		occurrences, err := r.schedule.OccurrencesInWindow(from, domain.HorizonDays, revisionWindow(r, starts, ends))
		if err != nil {
			return 0, err
		}
		for _, o := range occurrences {
			if o.Date < starts.Format("2006-01-02") || (ends != nil && o.Date > ends.Format("2006-01-02")) || o.At.Before(r.from) || (r.until != nil && !o.At.Before(*r.until)) {
				continue
			}
			tag, err := tx.Exec(ctx, "INSERT INTO dose_occurrences(treatment_id,schedule_revision_id,scheduled_at,scheduled_local_date,scheduled_local_time,dst_adjusted,dose_quantity) VALUES($1,$2,$3,$4::date,$5::time,$6,$7::numeric) ON CONFLICT(schedule_revision_id,scheduled_at) DO NOTHING", treatmentID, r.id, o.At, o.Date, o.LocalTime, o.Adjusted, o.Quantity.String())
			if err != nil {
				return 0, translate(err)
			}
			count += int(tag.RowsAffected())
		}
	}
	return count, tx.Commit(ctx)
}

func revisionWindow(r revision, starts time.Time, ends *time.Time) domain.ScheduleWindow {
	w := domain.ScheduleWindow{StartsOn: starts.Format("2006-01-02"), From: r.from, Until: r.until}
	if ends != nil {
		w.EndsOn = ends.Format("2006-01-02")
	}
	return w
}
