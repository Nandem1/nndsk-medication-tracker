package application

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

const MaxReportDays = 366

type AdherenceCounts struct {
	Evaluable        int      `json:"evaluable"`
	Taken            int      `json:"taken"`
	TakenLate        int      `json:"taken_late"`
	Skipped          int      `json:"skipped"`
	Unconfirmed      int      `json:"unconfirmed"`
	Confirmed        int      `json:"confirmed"`
	Punctual         int      `json:"punctual"`
	AdherenceRate    *float64 `json:"adherence_rate"`
	ConfirmationRate *float64 `json:"confirmation_rate"`
	PunctualityRate  *float64 `json:"punctuality_rate"`
	UnconfirmedRate  *float64 `json:"unconfirmed_rate"`
}
type AdherenceDay struct {
	Date string `json:"date"`
	AdherenceCounts
}
type AdherenceReport struct {
	From          string          `json:"from"`
	To            string          `json:"to"`
	AsOf          time.Time       `json:"as_of"`
	WindowMinutes int             `json:"window_minutes"`
	Summary       AdherenceCounts `json:"summary"`
	Days          []AdherenceDay  `json:"days"`
}

func ratio(n, d int) *float64 {
	if d == 0 {
		return nil
	}
	v := float64(n) / float64(d)
	return &v
}
func (c *AdherenceCounts) rates() {
	c.Confirmed = c.Taken + c.TakenLate + c.Skipped
	c.AdherenceRate = ratio(c.Taken+c.TakenLate, c.Evaluable)
	c.ConfirmationRate = ratio(c.Confirmed, c.Evaluable)
	c.PunctualityRate = ratio(c.Punctual, c.Taken+c.TakenLate)
	c.UnconfirmedRate = ratio(c.Unconfirmed, c.Evaluable)
}
func reportRange(from, to string) (time.Time, time.Time, error) {
	start, err := domain.ParseDate(from)
	if err != nil {
		return time.Time{}, time.Time{}, ErrInvalid
	}
	end, err := domain.ParseDate(to)
	if err != nil || !end.After(start) || end.Sub(start) > MaxReportDays*24*time.Hour {
		return time.Time{}, time.Time{}, ErrInvalid
	}
	return start, end, nil
}
func materializeReport(ctx context.Context, tx pgx.Tx, patient, treatment string, start, end time.Time) error {
	if treatment != "" && !domain.ValidID(treatment) {
		return ErrInvalid
	}
	rows, err := tx.Query(ctx, `SELECT id::text FROM treatments WHERE patient_user_id=$1 AND ($2::text='' OR id=NULLIF($2,'')::uuid) ORDER BY id FOR UPDATE`, patient, treatment)
	if err != nil {
		return materializationError{err}
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	if treatment != "" && len(ids) == 0 {
		return ErrNotFound
	}
	for _, id := range ids {
		for day := start; day.Before(end); day = day.AddDate(0, 0, domain.HorizonDays) {
			days := min(domain.HorizonDays, int(end.Sub(day)/(24*time.Hour)))
			if _, err = generateOccurrences(ctx, tx, id, day.Format("2006-01-02"), days); err != nil {
				return materializationError{err}
			}
		}
	}
	return nil
}
func (s *Service) Adherence(ctx context.Context, actor, patient, from, to, treatment string, windowMinutes int) (AdherenceReport, error) {
	return retryMaterializedRead(ctx, func() (AdherenceReport, error) {
		return s.adherence(ctx, actor, patient, from, to, treatment, windowMinutes)
	})
}

func (s *Service) adherence(ctx context.Context, actor, patient, from, to, treatment string, windowMinutes int) (AdherenceReport, error) {
	out := AdherenceReport{From: from, To: to, AsOf: s.now().UTC(), WindowMinutes: windowMinutes, Days: []AdherenceDay{}}
	start, end, err := reportRange(from, to)
	if err != nil || windowMinutes < 0 || windowMinutes > 1440 {
		return out, ErrInvalid
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if err = authorizeTx(ctx, tx, actor, patientTarget(patient), ScopeRead); err != nil {
		return out, err
	}
	if err = materializeReport(ctx, tx, patient, treatment, start, end); err != nil {
		return out, err
	}
	rows, err := tx.Query(ctx, `SELECT d.scheduled_local_date::text,count(*),
 count(*) FILTER(WHERE d.status='taken'),count(*) FILTER(WHERE d.status='taken_late'),
 count(*) FILTER(WHERE d.status='skipped'),count(*) FILTER(WHERE d.status='pending'),
 count(*) FILTER(WHERE d.status='taken' AND abs(extract(epoch FROM (e.occurred_at-d.scheduled_at))) <= $6::integer*60)
 FROM dose_occurrences d JOIN treatments t ON t.id=d.treatment_id LEFT JOIN dose_events e ON e.id=d.current_event_id
 WHERE t.patient_user_id=$1 AND d.cancelled_at IS NULL AND d.scheduled_local_date >= $2::date AND d.scheduled_local_date < $3::date
 AND d.scheduled_at < $4 AND ($5::text='' OR d.treatment_id=NULLIF($5,'')::uuid)
 GROUP BY d.scheduled_local_date ORDER BY d.scheduled_local_date`, patient, from, to, out.AsOf, treatment, windowMinutes)
	if err != nil {
		return out, err
	}
	byDate := map[string]AdherenceCounts{}
	for rows.Next() {
		var date string
		var c AdherenceCounts
		if err = rows.Scan(&date, &c.Evaluable, &c.Taken, &c.TakenLate, &c.Skipped, &c.Unconfirmed, &c.Punctual); err != nil {
			rows.Close()
			return out, err
		}
		c.rates()
		byDate[date] = c
		out.Summary.Evaluable += c.Evaluable
		out.Summary.Taken += c.Taken
		out.Summary.TakenLate += c.TakenLate
		out.Summary.Skipped += c.Skipped
		out.Summary.Unconfirmed += c.Unconfirmed
		out.Summary.Punctual += c.Punctual
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return out, err
	}
	for day := start; day.Before(end); day = day.AddDate(0, 0, 1) {
		date := day.Format("2006-01-02")
		out.Days = append(out.Days, AdherenceDay{date, byDate[date]})
	}
	out.Summary.rates()
	return out, tx.Commit(ctx)
}
