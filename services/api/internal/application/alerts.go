package application

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
	"medication-tracker/services/api/internal/push"
)

func (s *Service) PlanAlerts(ctx context.Context) (int, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	var locked bool
	if err = tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock(681196,6)`).Scan(&locked); err != nil || !locked {
		return 0, err
	}
	now := s.now().UTC()
	rows, err := tx.Query(ctx, `SELECT id::text FROM treatments ORDER BY id`)
	if err != nil {
		return 0, err
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, id := range ids {
		revs, e := revisions(ctx, tx, id)
		if e != nil {
			return 0, e
		}
		seen := map[string]bool{}
		for _, r := range revs {
			loc, e := time.LoadLocation(r.schedule.Timezone)
			if e != nil {
				return 0, e
			}
			date := now.In(loc).AddDate(0, 0, -2).Format("2006-01-02")
			if seen[date] {
				continue
			}
			seen[date] = true
			if _, e = generateOccurrences(ctx, tx, id, date, domain.HorizonDays); e != nil {
				return 0, e
			}
		}
	}
	tag, err := tx.Exec(ctx, `INSERT INTO notification_outbox(link_id,consent_id,device_id,device_revision,kind,dose_id,dedup_key,created_at,expires_at,next_attempt_at)
 SELECT l.id,l.accepted_invitation_id,v.id,v.revision,'unconfirmed',d.id,
 'dose/'||l.accepted_invitation_id||'/'||d.id||'/'||v.id,$1,d.scheduled_at+interval '48 hours',$1
 FROM caregiver_links l JOIN caregiver_alert_preferences p ON p.link_id=l.id AND p.consent_id=l.accepted_invitation_id
 JOIN treatments t ON t.patient_user_id=l.patient_user_id JOIN dose_occurrences d ON d.treatment_id=t.id
 JOIN device_registrations v ON v.user_id=l.caregiver_user_id
 WHERE l.status='active' AND 'read'=ANY(l.scopes) AND p.unconfirmed_delay_minutes IS NOT NULL
 AND d.status='pending' AND d.cancelled_at IS NULL AND d.scheduled_at<= $1::timestamptz-make_interval(mins=>p.unconfirmed_delay_minutes) AND d.scheduled_at>$1::timestamptz-interval '48 hours'
 AND v.permission='granted' AND v.revoked_at IS NULL AND v.expires_at>$1
 ON CONFLICT(dedup_key) DO UPDATE SET device_revision=excluded.device_revision,state='pending',completed_at=NULL,next_attempt_at=excluded.next_attempt_at WHERE notification_outbox.attempts=0 AND notification_outbox.state IN ('pending','suppressed') AND notification_outbox.device_revision<>excluded.device_revision`, now)
	if err != nil {
		return 0, err
	}
	count := int(tag.RowsAffected())
	rows, err = tx.Query(ctx, `SELECT p.link_id::text,p.consent_id::text,p.timezone,a.id::text,a.low_stock_days_threshold FROM caregiver_alert_preferences p JOIN caregiver_links l ON l.id=p.link_id AND l.accepted_invitation_id=p.consent_id JOIN inventory_accounts a ON a.patient_user_id=l.patient_user_id WHERE l.status='active' AND 'read'=ANY(l.scopes) AND p.stock_enabled AND NOT EXISTS (SELECT 1 FROM inventory_pool_members m JOIN inventory_pools pool ON pool.id=m.pool_id AND pool.status='active' JOIN inventory_pool_members o ON o.pool_id=m.pool_id AND o.status='accepted' AND o.account_id<a.id JOIN inventory_accounts oa ON oa.id=o.account_id JOIN caregiver_links ol ON ol.patient_user_id=oa.patient_user_id AND ol.caregiver_user_id=l.caregiver_user_id AND ol.status='active' AND 'read'=ANY(ol.scopes) JOIN caregiver_alert_preferences op ON op.link_id=ol.id AND op.consent_id=ol.accepted_invitation_id AND op.stock_enabled WHERE m.account_id=a.id AND m.status='accepted') ORDER BY p.link_id,a.id`)
	if err != nil {
		return 0, err
	}
	type stockCandidate struct {
		link, consent, timezone, account string
		days                             int
	}
	stocks := []stockCandidate{}
	for rows.Next() {
		var c stockCandidate
		if err = rows.Scan(&c.link, &c.consent, &c.timezone, &c.account, &c.days); err != nil {
			rows.Close()
			return 0, err
		}
		stocks = append(stocks, c)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, c := range stocks {
		loc, e := time.LoadLocation(c.timezone)
		if e != nil {
			return 0, e
		}
		projection, e := inventoryProjection(ctx, tx, c.account, now)
		if e != nil {
			return 0, e
		}
		if projection.FirstUncoveredAt == nil || projection.FirstUncoveredAt.After(now.In(loc).AddDate(0, 0, projection.LowStockDaysThreshold)) {
			continue
		}
		key := "stock/" + c.consent + "/" + c.account + "/" + now.In(loc).Format("2006-01-02")
		tag, e = tx.Exec(ctx, `INSERT INTO notification_outbox(link_id,consent_id,device_id,device_revision,kind,account_id,dedup_key,created_at,expires_at,next_attempt_at)
 SELECT $1,$2,v.id,v.revision,'low_stock',$3,$4||'/'||v.id,$5,$5::timestamptz+interval '24 hours',$5 FROM device_registrations v JOIN caregiver_links l ON l.caregiver_user_id=v.user_id WHERE l.id=$1 AND v.permission='granted' AND v.revoked_at IS NULL AND v.expires_at>$5 ON CONFLICT(dedup_key) DO UPDATE SET device_revision=excluded.device_revision,state='pending',completed_at=NULL,next_attempt_at=excluded.next_attempt_at WHERE notification_outbox.attempts=0 AND notification_outbox.state IN ('pending','suppressed') AND notification_outbox.device_revision<>excluded.device_revision`, c.link, c.consent, c.account, key, now)
		if e != nil {
			return 0, e
		}
		count += int(tag.RowsAffected())
	}
	return count, tx.Commit(ctx)
}

type AlertDeliveryStats struct {
	Sent, Retry, Uncertain, Failed, Suppressed int
	DelaySeconds                               float64
}
type delivery struct {
	message       push.Message
	device, owner string
	revision      int64
	attempts      int
	created       time.Time
}

func (s *Service) DeliverAlerts(ctx context.Context, sender push.Sender, limit int) (AlertDeliveryStats, error) {
	var stats AlertDeliveryStats
	if limit < 1 || limit > 1000 || sender == nil {
		return stats, ErrInvalid
	}
	// An abandoned claim may already have reached a provider. Never replay it.
	tag, err := s.pool.Exec(ctx, `UPDATE notification_outbox SET state='uncertain',completed_at=$1 WHERE state='sending' AND attempted_at<$1::timestamptz-interval '2 minutes'`, s.now().UTC())
	if err != nil {
		return stats, err
	}
	stats.Uncertain = int(tag.RowsAffected())
	for i := 0; i < limit; i++ {
		item, processed, e := s.claimAlert(ctx)
		if e != nil {
			return stats, e
		}
		if !processed {
			break
		}
		if item == nil {
			stats.Suppressed++
			continue
		}
		sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		result := sender.Send(sendCtx, item.message)
		cancel()
		state := "uncertain"
		now := s.now().UTC()
		next := now
		switch result.Outcome {
		case push.Accepted:
			state = "sent"
			stats.Sent++
			stats.DelaySeconds += now.Sub(item.created).Seconds()
		case push.InvalidToken, push.Rejected:
			state = "failed"
			stats.Failed++
		case push.Retry:
			delay := time.Minute * time.Duration(1<<uint(item.attempts-1))
			if result.RetryAfter > delay {
				delay = result.RetryAfter
			}
			next = now.Add(delay)
			if item.attempts < 5 && next.Before(item.message.ExpiresAt) {
				state = "retry"
				stats.Retry++
			} else {
				state = "failed"
				stats.Failed++
			}
		default:
			stats.Uncertain++
		}
		tx, e := s.pool.Begin(ctx)
		if e != nil {
			return stats, e
		}
		_, e = tx.Exec(ctx, `UPDATE notification_outbox SET state=$2,next_attempt_at=$3,completed_at=CASE WHEN $2='retry' THEN NULL ELSE $4::timestamptz END WHERE id=$1 AND state='sending'`, item.message.ID, state, next, now)
		if e == nil && result.Outcome == push.InvalidToken {
			_, e = tx.Exec(ctx, `UPDATE device_registrations SET revoked_at=$3,token='',permission='denied',revision=revision+1 WHERE id=$1 AND revision=$2`, item.device, item.revision, now)
		}
		if e == nil {
			e = tx.Commit(ctx)
		} else {
			_ = tx.Rollback(ctx)
		}
		if e != nil {
			return stats, e
		}
	}
	return stats, nil
}
func (s *Service) claimAlert(ctx context.Context) (*delivery, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	now := s.now().UTC()
	var d delivery
	var link, consent, kind string
	var dose, account *string
	err = tx.QueryRow(ctx, `SELECT id::text,link_id::text,consent_id::text,device_id::text,device_revision,kind,dose_id::text,account_id::text,expires_at,attempts,created_at FROM notification_outbox WHERE state IN ('pending','retry') AND next_attempt_at<=$1 ORDER BY next_attempt_at,id FOR UPDATE SKIP LOCKED LIMIT 1`, now).Scan(&d.message.ID, &link, &consent, &d.device, &d.revision, &kind, &dose, &account, &d.message.ExpiresAt, &d.attempts, &d.created)
	if err == pgx.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	suppress := func() (*delivery, bool, error) {
		_, e := tx.Exec(ctx, `UPDATE notification_outbox SET state='suppressed',completed_at=$2 WHERE id=$1`, d.message.ID, now)
		if e == nil {
			e = tx.Commit(ctx)
		}
		return nil, true, e
	}
	if !now.Before(d.message.ExpiresAt) {
		return suppress()
	}
	var patient string
	err = tx.QueryRow(ctx, `SELECT caregiver_user_id::text,patient_user_id::text FROM caregiver_links WHERE id=$1 AND accepted_invitation_id=$2 AND status='active' AND 'read'=ANY(scopes) FOR SHARE`, link, consent).Scan(&d.owner, &patient)
	if err == pgx.ErrNoRows {
		return suppress()
	}
	if err != nil {
		return nil, false, err
	}
	var p AlertPreferences
	err = tx.QueryRow(ctx, `SELECT unconfirmed_delay_minutes,stock_enabled,min_interval_minutes,timezone,quiet_start_minute,quiet_end_minute FROM caregiver_alert_preferences WHERE link_id=$1 AND consent_id=$2 FOR SHARE`, link, consent).Scan(&p.UnconfirmedDelayMinutes, &p.StockEnabled, &p.MinIntervalMinutes, &p.Timezone, &p.QuietStartMinute, &p.QuietEndMinute)
	if err == pgx.ErrNoRows {
		return suppress()
	}
	if err != nil {
		return nil, false, err
	}
	err = tx.QueryRow(ctx, `SELECT platform,token FROM device_registrations WHERE id=$1 AND user_id=$2 AND revision=$3 AND permission='granted' AND revoked_at IS NULL AND expires_at>$4 FOR SHARE`, d.device, d.owner, d.revision, now).Scan(&d.message.Platform, &d.message.Token)
	if err == pgx.ErrNoRows {
		return suppress()
	}
	if err != nil {
		return nil, false, err
	}
	if kind == "unconfirmed" {
		if p.UnconfirmedDelayMinutes == nil {
			return suppress()
		}
		var valid bool
		err = tx.QueryRow(ctx, `SELECT status='pending' AND cancelled_at IS NULL AND scheduled_at<=$2::timestamptz-make_interval(mins=>$3) FROM dose_occurrences WHERE id=$1 FOR SHARE`, *dose, now, *p.UnconfirmedDelayMinutes).Scan(&valid)
		if err != nil {
			return nil, false, err
		}
		if !valid {
			return suppress()
		}
	} else {
		if !p.StockEnabled {
			return suppress()
		}
		if _, err = lockInventory(ctx, tx, *account); err != nil {
			return nil, false, err
		}
		projection, e := inventoryProjection(ctx, tx, *account, now)
		if e != nil {
			return nil, false, e
		}
		loc, e := time.LoadLocation(p.Timezone)
		if e != nil {
			return nil, false, e
		}
		if projection.FirstUncoveredAt == nil || projection.FirstUncoveredAt.After(now.In(loc).AddDate(0, 0, projection.LowStockDaysThreshold)) {
			return suppress()
		}
	}
	deferUntil := func(at time.Time) (*delivery, bool, error) {
		_, e := tx.Exec(ctx, `UPDATE notification_outbox SET next_attempt_at=$2 WHERE id=$1`, d.message.ID, at)
		if e == nil {
			e = tx.Commit(ctx)
		}
		return nil, true, e
	}
	if p.quiet(now) {
		return deferUntil(now.Add(time.Minute))
	}
	_, err = tx.Exec(ctx, `INSERT INTO notification_frequency(user_id,next_allowed_at) VALUES($1,$2) ON CONFLICT DO NOTHING`, d.owner, now)
	if err != nil {
		return nil, false, err
	}
	var allowed time.Time
	if err = tx.QueryRow(ctx, `SELECT next_allowed_at FROM notification_frequency WHERE user_id=$1 FOR UPDATE`, d.owner).Scan(&allowed); err != nil {
		return nil, false, err
	}
	if now.Before(allowed) {
		return deferUntil(allowed)
	}
	_, err = tx.Exec(ctx, `UPDATE notification_frequency SET next_allowed_at=$2 WHERE user_id=$1`, d.owner, now.Add(time.Duration(p.MinIntervalMinutes)*time.Minute))
	if err != nil {
		return nil, false, err
	}
	_, err = tx.Exec(ctx, `UPDATE notification_outbox SET state='sending',attempts=attempts+1,attempted_at=$2 WHERE id=$1`, d.message.ID, now)
	if err != nil {
		return nil, false, err
	}
	d.attempts++
	return &d, true, tx.Commit(ctx)
}

func (s AlertDeliveryStats) String() string {
	return fmt.Sprintf("sent=%d retry=%d uncertain=%d failed=%d deferred_or_suppressed=%d", s.Sent, s.Retry, s.Uncertain, s.Failed, s.Suppressed)
}
