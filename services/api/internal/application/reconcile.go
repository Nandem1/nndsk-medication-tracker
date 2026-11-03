package application

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

type Reconciliation struct {
	DoseStateMismatches   int64 `json:"dose_state_mismatches"`
	ConsumptionMismatches int64 `json:"consumption_mismatches"`
	LedgerMismatches      int64 `json:"ledger_mismatches"`
	AgendaMismatches      int64 `json:"agenda_mismatches"`
	StaleDeliveries       int64 `json:"stale_deliveries"`
	ExpiredDevices        int64 `json:"expired_devices"`
}

func (s *Service) Reconcile(ctx context.Context) (Reconciliation, error) {
	var out Reconciliation
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	checks := []struct {
		query string
		dst   *int64
	}{
		{`SELECT count(*) FROM dose_occurrences d LEFT JOIN LATERAL (SELECT id,resulting_state,version FROM dose_events WHERE dose_occurrence_id=d.id ORDER BY version DESC LIMIT 1) e ON true WHERE d.current_event_id IS DISTINCT FROM e.id OR d.status<>COALESCE(e.resulting_state,'pending') OR d.version<>COALESCE(e.version,CASE WHEN d.cancelled_at IS NULL THEN 1 ELSE 2 END)`, &out.DoseStateMismatches},
		{`SELECT count(*) FROM dose_occurrences d LEFT JOIN active_consumptions c ON c.dose_occurrence_id=d.id LEFT JOIN inventory_movements m ON m.id=c.movement_id WHERE (d.status IN ('taken','taken_late'))<>(c.dose_occurrence_id IS NOT NULL) OR (c.dose_occurrence_id IS NOT NULL AND (m.quantity_delta<>-d.dose_quantity OR m.reason<>'consumption'))`, &out.ConsumptionMismatches},
		{`SELECT count(*) FROM dose_occurrences d LEFT JOIN LATERAL (SELECT COALESCE(sum(quantity_delta),0) AS amount FROM inventory_movements WHERE dose_occurrence_id=d.id) m ON true WHERE m.amount<>CASE WHEN d.status IN ('taken','taken_late') THEN -d.dose_quantity ELSE 0 END`, &out.LedgerMismatches},
		{`SELECT count(*) FROM notification_outbox o JOIN caregiver_links l ON l.id=o.link_id JOIN device_registrations d ON d.id=o.device_id LEFT JOIN caregiver_alert_preferences p ON p.link_id=o.link_id AND p.consent_id=o.consent_id LEFT JOIN dose_occurrences dose ON dose.id=o.dose_id WHERE o.state IN ('pending','retry') AND (o.expires_at<=$1 OR l.status<>'active' OR NOT ('read'=ANY(l.scopes)) OR l.accepted_invitation_id IS DISTINCT FROM o.consent_id OR d.user_id<>l.caregiver_user_id OR d.revision<>o.device_revision OR d.revoked_at IS NOT NULL OR d.permission<>'granted' OR d.expires_at<=$1 OR p.link_id IS NULL OR (o.kind='unconfirmed' AND (p.unconfirmed_delay_minutes IS NULL OR dose.status<>'pending' OR dose.cancelled_at IS NOT NULL)) OR (o.kind='low_stock' AND NOT p.stock_enabled))`, &out.StaleDeliveries},
		{`SELECT count(*) FROM device_registrations WHERE revoked_at IS NULL AND permission='granted' AND expires_at<=$1`, &out.ExpiredDevices},
	}
	for _, c := range checks {
		var args []any
		if strings.Contains(c.query, "$1") {
			args = []any{s.now().UTC()}
		}
		if err = tx.QueryRow(ctx, c.query, args...).Scan(c.dst); err != nil {
			return out, err
		}
	}

	stockRows, err := tx.Query(ctx, `SELECT o.account_id::text,p.timezone,a.low_stock_days_threshold FROM notification_outbox o JOIN caregiver_links l ON l.id=o.link_id JOIN device_registrations d ON d.id=o.device_id JOIN caregiver_alert_preferences p ON p.link_id=o.link_id AND p.consent_id=o.consent_id JOIN inventory_accounts a ON a.id=o.account_id WHERE o.state IN ('pending','retry') AND o.kind='low_stock' AND o.expires_at>$1 AND l.status='active' AND 'read'=ANY(l.scopes) AND l.accepted_invitation_id=o.consent_id AND d.user_id=l.caregiver_user_id AND d.revision=o.device_revision AND d.revoked_at IS NULL AND d.permission='granted' AND d.expires_at>$1 AND p.stock_enabled`, s.now().UTC())
	if err != nil {
		return out, err
	}
	type stockCheck struct {
		account, timezone string
		days              int
	}
	stockChecks := []stockCheck{}
	for stockRows.Next() {
		var c stockCheck
		if err = stockRows.Scan(&c.account, &c.timezone, &c.days); err != nil {
			stockRows.Close()
			return out, err
		}
		stockChecks = append(stockChecks, c)
	}
	err = stockRows.Err()
	stockRows.Close()
	if err != nil {
		return out, err
	}
	for _, c := range stockChecks {
		projection, e := inventoryProjection(ctx, tx, c.account, s.now().UTC())
		if e != nil {
			return out, e
		}
		loc, e := time.LoadLocation(c.timezone)
		if e != nil {
			return out, e
		}
		if projection.FirstUncoveredAt == nil || projection.FirstUncoveredAt.After(s.now().In(loc).AddDate(0, 0, c.days)) {
			out.StaleDeliveries++
		}
	}
	rows, err := tx.Query(ctx, `SELECT id::text,starts_on,ends_on,archived_at FROM treatments ORDER BY id`)
	if err != nil {
		return out, err
	}
	type treatmentWindow struct {
		id             string
		starts         time.Time
		ends, archived *time.Time
	}
	trs := []treatmentWindow{}
	for rows.Next() {
		var t treatmentWindow
		if err = rows.Scan(&t.id, &t.starts, &t.ends, &t.archived); err != nil {
			rows.Close()
			return out, err
		}
		trs = append(trs, t)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return out, err
	}
	for _, t := range trs {
		revs, e := revisions(ctx, tx, t.id)
		if e != nil {
			return out, e
		}
		for _, r := range revs {
			loc, e := time.LoadLocation(r.schedule.Timezone)
			if e != nil {
				return out, e
			}
			date := s.now().In(loc).AddDate(0, 0, -2).Format("2006-01-02")
			window := revisionWindow(r, t.starts, t.ends)
			if t.archived != nil && (window.Until == nil || t.archived.Before(*window.Until)) {
				window.Until = t.archived
			}
			if window.Until != nil && !window.From.Before(*window.Until) {
				continue
			}
			expected, e := r.schedule.OccurrencesInWindow(date, domain.HorizonDays, window)
			if e != nil {
				return out, e
			}
			want := map[int64]domain.Quantity{}
			for _, o := range expected {
				want[o.At.Unix()] = o.Quantity
			}
			from, e := domain.StartOfDay(date, loc)
			if e != nil {
				return out, e
			}
			day, _ := domain.ParseDate(date)
			through, e := domain.StartOfDay(day.AddDate(0, 0, domain.HorizonDays).Format("2006-01-02"), loc)
			if e != nil {
				return out, e
			}
			rows, e = tx.Query(ctx, `SELECT scheduled_at,dose_quantity::text FROM dose_occurrences WHERE schedule_revision_id=$1 AND cancelled_at IS NULL AND scheduled_at>=$2 AND scheduled_at<$3`, r.id, from, through)
			if e != nil {
				return out, e
			}
			for rows.Next() {
				var at time.Time
				var q string
				if e = rows.Scan(&at, &q); e != nil {
					rows.Close()
					return out, e
				}
				quantity, e := domain.ParseQuantity(q)
				if e != nil {
					rows.Close()
					return out, e
				}
				if v, ok := want[at.Unix()]; !ok || v != quantity {
					out.AgendaMismatches++
				}
				delete(want, at.Unix())
			}
			e = rows.Err()
			rows.Close()
			if e != nil {
				return out, e
			}
			out.AgendaMismatches += int64(len(want))
		}
	}
	return out, tx.Commit(ctx)
}
