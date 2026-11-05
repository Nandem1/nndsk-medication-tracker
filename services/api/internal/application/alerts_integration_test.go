//go:build integration

package application

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"medication-tracker/services/api/internal/domain"
	"medication-tracker/services/api/internal/push"
)

type alertFixture struct {
	s                                *Service
	p                                *pgxpool.Pool
	patient, caregiver, link, device string
	family                           string
	tr                               TreatmentResult
	now                              *time.Time
}

func alertsFixture(t *testing.T) *alertFixture {
	t.Helper()
	s, p, patient := fixture(t)
	now := s.now()
	s.now = func() time.Time { return now }
	ctx := context.Background()
	caregiver, err := s.ResolveUser(ctx, domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	family, linkID := grant(t, s, caregiver, patient, RoleObserver)
	link := struct{ ID string }{linkID}
	id := domain.NewID()
	if _, err = s.RegisterDevice(ctx, caregiver, DeviceInput{ID: id, Platform: "fcm", Token: "synthetic-" + id, Permission: "granted"}); err != nil {
		t.Fatal(err)
	}
	delay := 30
	if _, err = s.SetAlertPreferences(ctx, caregiver, link.ID, AlertPreferences{UnconfirmedDelayMinutes: &delay, MinIntervalMinutes: 15, Timezone: "UTC"}); err != nil {
		t.Fatal(err)
	}
	tr, err := s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(patient), PatientID: patient, Name: "Synthetic F6", Unit: "tablet", InitialStock: 10000, StartsOn: "2026-11-02", Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, e := p.Exec(ctx, `DELETE FROM notification_outbox WHERE link_id=$1`, link.ID)
		if e != nil {
			t.Error(e)
		}
		_, _ = p.Exec(ctx, `DELETE FROM caregiver_alert_preferences WHERE link_id=$1`, link.ID)
		_, _ = p.Exec(ctx, `DELETE FROM notification_frequency WHERE user_id=$1`, caregiver)
		_, _ = p.Exec(ctx, `DELETE FROM device_registrations WHERE user_id=$1`, caregiver)
	})
	return &alertFixture{s, p, patient, caregiver, link.ID, id, family, tr, &now}
}

type testPush struct {
	calls  atomic.Int64
	result push.Result
}

func (p *testPush) Send(_ context.Context, m push.Message) push.Result {
	p.calls.Add(1)
	return p.result
}
func (f *alertFixture) state(t *testing.T) string {
	t.Helper()
	var state string
	if err := f.p.QueryRow(context.Background(), `SELECT state FROM notification_outbox WHERE link_id=$1 ORDER BY created_at LIMIT 1`, f.link).Scan(&state); err != nil {
		t.Fatal(err)
	}
	return state
}
func (f *alertFixture) plan(t *testing.T) {
	t.Helper()
	if _, err := f.s.PlanAlerts(context.Background()); err != nil {
		t.Fatal(err)
	}
}
func (f *alertFixture) deliver(t *testing.T, p push.Sender) {
	t.Helper()
	if _, err := f.s.DeliverAlerts(context.Background(), p, 100); err != nil {
		t.Fatal(err)
	}
}
func TestF6ConcurrentPlanningDeliveryNeverConsumes(t *testing.T) {
	f := alertsFixture(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.s.PlanAlerts(ctx); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	var n int
	if err := f.p.QueryRow(ctx, `SELECT count(*) FROM notification_outbox WHERE link_id=$1`, f.link).Scan(&n); err != nil || n != 1 {
		t.Fatalf("logical delivery count=%d err=%v", n, err)
	}
	sender := &testPush{result: push.Result{Outcome: push.Accepted}}
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.s.DeliverAlerts(ctx, sender, 20); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if sender.calls.Load() != 1 || f.state(t) != "sent" {
		t.Fatal("duplicate/missing provider call", sender.calls.Load(), f.state(t))
	}
	for i := 0; i < 3; i++ {
		f.plan(t)
		f.deliver(t, sender)
	}
	if sender.calls.Load() != 1 {
		t.Fatal("tick replayed sent delivery")
	}
	projection, err := f.s.GetInventoryProjection(ctx, f.patient, f.tr.AccountID, *f.now)
	if err != nil || projection.Balance != 10000 {
		t.Fatal("worker changed stock", projection, err)
	}
	var events int
	_ = f.p.QueryRow(ctx, `SELECT count(*) FROM dose_events WHERE treatment_id=$1`, f.tr.TreatmentID).Scan(&events)
	if events != 0 {
		t.Fatal("worker declared doses", events)
	}
}
func TestF6AmbiguousAndAbandonedAttemptsNeverReplay(t *testing.T) {
	for _, mode := range []string{"unknown", "crash"} {
		t.Run(mode, func(t *testing.T) {
			f := alertsFixture(t)
			f.plan(t)
			sender := &testPush{result: push.Result{Outcome: push.Unknown}}
			if mode == "crash" {
				item, processed, err := f.s.claimAlert(context.Background())
				if err != nil || !processed || item == nil {
					t.Fatal(item, processed, err)
				}
				*f.now = f.now.Add(3 * time.Minute)
			} else {
				f.deliver(t, sender)
			}
			f.deliver(t, sender)
			f.plan(t)
			f.deliver(t, sender)
			if f.state(t) != "uncertain" {
				t.Fatal(f.state(t))
			}
			want := int64(1)
			if mode == "crash" {
				want = 0
			}
			if sender.calls.Load() != want {
				t.Fatal("ambiguous replay", sender.calls.Load())
			}
		})
	}
}
func TestF6ExplicitRetryBackoffAndFrequency(t *testing.T) {
	f := alertsFixture(t)
	f.plan(t)
	sender := &testPush{result: push.Result{Outcome: push.Retry, RetryAfter: 20 * time.Minute}}
	f.deliver(t, sender)
	if f.state(t) != "retry" {
		t.Fatal(f.state(t))
	}
	*f.now = f.now.Add(19 * time.Minute)
	f.deliver(t, sender)
	if sender.calls.Load() != 1 {
		t.Fatal("retried before Retry-After")
	}
	*f.now = f.now.Add(time.Minute)
	sender.result.Outcome = push.Accepted
	f.deliver(t, sender)
	if sender.calls.Load() != 2 || f.state(t) != "sent" {
		t.Fatal(sender.calls.Load(), f.state(t))
	}
}
func TestF6SuppressesStaleConditionsAndDevices(t *testing.T) {
	for _, reason := range []string{"revoked", "rotated", "denied", "confirmed", "preferences", "expired"} {
		t.Run(reason, func(t *testing.T) {
			f := alertsFixture(t)
			f.plan(t)
			ctx := context.Background()
			switch reason {
			case "revoked":
				if err := f.s.RemoveFamilyMember(ctx, f.patient, f.family, f.patient); err != nil {
					t.Fatal(err)
				}
			case "rotated":
				if _, err := f.s.RegisterDevice(ctx, f.caregiver, DeviceInput{ID: f.device, Platform: "fcm", Token: "replacement-" + f.device, Permission: "granted"}); err != nil {
					t.Fatal(err)
				}
			case "denied":
				if _, err := f.s.RegisterDevice(ctx, f.caregiver, DeviceInput{ID: f.device, Platform: "fcm", Permission: "denied"}); err != nil {
					t.Fatal(err)
				}
			case "confirmed":
				id := dose(t, f.p, f.tr.TreatmentID, "2026-11-02")
				if _, err := f.s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(f.patient), DoseID: id, ExpectedVersion: 1, State: domain.Skipped}); err != nil {
					t.Fatal(err)
				}
			case "preferences":
				if _, err := f.s.SetAlertPreferences(ctx, f.caregiver, f.link, AlertPreferences{MinIntervalMinutes: 15, Timezone: "UTC"}); err != nil {
					t.Fatal(err)
				}
			case "expired":
				*f.now = f.now.Add(3 * 24 * time.Hour)
			}
			sender := &testPush{result: push.Result{Outcome: push.Accepted}}
			f.deliver(t, sender)
			if sender.calls.Load() != 0 || f.state(t) != "suppressed" {
				t.Fatal(sender.calls.Load(), f.state(t))
			}
		})
	}
}
func TestF6QuietHoursAndRecipientThrottle(t *testing.T) {
	f := alertsFixture(t)
	ctx := context.Background()
	delay, start, end := 30, 11*60, 13*60
	_, err := f.s.SetAlertPreferences(ctx, f.caregiver, f.link, AlertPreferences{UnconfirmedDelayMinutes: &delay, MinIntervalMinutes: 15, Timezone: "UTC", QuietStartMinute: &start, QuietEndMinute: &end})
	if err != nil {
		t.Fatal(err)
	}
	second := domain.NewID()
	_, err = f.s.RegisterDevice(ctx, f.caregiver, DeviceInput{ID: second, Platform: "fcm", Token: "synthetic-" + second, Permission: "granted"})
	if err != nil {
		t.Fatal(err)
	}
	f.plan(t)
	sender := &testPush{result: push.Result{Outcome: push.Accepted}}
	f.deliver(t, sender)
	if sender.calls.Load() != 0 {
		t.Fatal("sent during quiet hours")
	}
	*f.now = f.now.Add(time.Hour)
	f.deliver(t, sender)
	if sender.calls.Load() != 1 {
		t.Fatal("recipient frequency not enforced", sender.calls.Load())
	}
	*f.now = f.now.Add(15 * time.Minute)
	f.deliver(t, sender)
	if sender.calls.Load() != 2 {
		t.Fatal("deferred device did not send", sender.calls.Load())
	}
}
func TestF6LowStockUsesCalendarAndRechecksReplenishment(t *testing.T) {
	f := alertsFixture(t)
	ctx := context.Background()
	_, err := f.s.SetAlertPreferences(ctx, f.caregiver, f.link, AlertPreferences{StockEnabled: true, MinIntervalMinutes: 15, Timezone: "UTC"})
	if err != nil {
		t.Fatal(err)
	}
	// The 10-unit fixture covers 20 days, so a five-day threshold produces no alert.
	f.plan(t)
	var count int
	_ = f.p.QueryRow(ctx, `SELECT count(*) FROM notification_outbox WHERE link_id=$1`, f.link).Scan(&count)
	if count != 0 {
		t.Fatal("stock average or threshold wrong", count)
	}
	_, err = f.p.Exec(ctx, `UPDATE inventory_accounts SET low_stock_days_threshold=25 WHERE id=$1`, f.tr.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	f.plan(t)
	f.plan(t)
	_ = f.p.QueryRow(ctx, `SELECT count(*) FROM notification_outbox WHERE link_id=$1`, f.link).Scan(&count)
	if count != 1 {
		t.Fatal("stock daily dedup", count)
	}
	if _, err = f.s.ReplenishInventory(ctx, ReplenishInventoryCommand{Mutation: mutation(f.patient), AccountID: f.tr.AccountID, Quantity: 100000}); err != nil {
		t.Fatal(err)
	}
	sender := &testPush{result: push.Result{Outcome: push.Accepted}}
	f.deliver(t, sender)
	if sender.calls.Load() != 0 || f.state(t) != "suppressed" {
		t.Fatal("stale stock sent")
	}
}
func TestF6DeviceOwnershipAndConsentGeneration(t *testing.T) {
	f := alertsFixture(t)
	ctx := context.Background()
	in := DeviceInput{ID: f.device, Platform: "fcm", Token: "synthetic-" + f.device, Permission: "granted"}
	if _, err := f.s.RegisterDevice(ctx, f.patient, in); !errors.Is(err, ErrNotFound) {
		t.Fatal("device takeover", err)
	}
	if err := f.s.DeleteDevice(ctx, f.patient, f.device); !errors.Is(err, ErrNotFound) {
		t.Fatal("device delete IDOR", err)
	}
	f.plan(t)
	if _, err := f.s.RegisterDevice(ctx, f.caregiver, in); err != nil {
		t.Fatal(err)
	}
	if err := f.s.RemoveFamilyMember(ctx, f.patient, f.family, f.patient); err != nil {
		t.Fatal(err)
	}
	// Volver a unirse es un consentimiento nuevo: las preferencias anteriores no sobreviven.
	join(t, f.s, f.caregiver, f.patient, f.family, RolePatient)
	setRole(t, f.s, f.family, f.caregiver, RoleObserver)
	prefs, err := f.s.GetAlertPreferences(ctx, f.caregiver, f.link)
	if err != nil || prefs.UnconfirmedDelayMinutes != nil || prefs.StockEnabled {
		t.Fatal("old consent preferences survived", prefs, err)
	}
	sender := &testPush{result: push.Result{Outcome: push.Accepted}}
	f.deliver(t, sender)
	if sender.calls.Load() != 0 {
		t.Fatal("old consent alert sent")
	}
}
func TestF6ReconciliationDetectsProjectionCorruption(t *testing.T) {
	f := alertsFixture(t)
	f.plan(t)
	ctx := context.Background()
	before, err := f.s.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	id := dose(t, f.p, f.tr.TreatmentID, "2026-11-02")
	_, err = f.p.Exec(ctx, `UPDATE dose_occurrences SET version=version+1 WHERE id=$1`, id)
	if err != nil {
		t.Fatal(err)
	}
	after, err := f.s.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.DoseStateMismatches != before.DoseStateMismatches+1 {
		t.Fatal("missed corrupt projection", before, after)
	}
	_, err = f.p.Exec(ctx, `UPDATE dose_occurrences SET version=version-1 WHERE id=$1`, id)
	if err != nil {
		t.Fatal(err)
	}
}

func TestF6RetriesAreBoundedAndInvalidTokensAreRetired(t *testing.T) {
	for _, outcome := range []push.Outcome{push.Retry, push.InvalidToken} {
		t.Run(string(outcome), func(t *testing.T) {
			f := alertsFixture(t)
			f.plan(t)
			sender := &testPush{result: push.Result{Outcome: outcome}}
			for i := 0; i < 7; i++ {
				f.deliver(t, sender)
				*f.now = f.now.Add(30 * time.Minute)
			}
			want := int64(5)
			if outcome == push.InvalidToken {
				want = 1
				var permission string
				if err := f.p.QueryRow(context.Background(), `SELECT permission FROM device_registrations WHERE id=$1`, f.device).Scan(&permission); err != nil || permission != "denied" {
					t.Fatal(permission, err)
				}
			}
			if sender.calls.Load() != want || f.state(t) != "failed" {
				t.Fatal("unbounded retries", sender.calls.Load(), f.state(t))
			}
		})
	}
}

func TestF6RevocationSerializesBeforeDeliveryClaim(t *testing.T) {
	f := alertsFixture(t)
	f.plan(t)
	ctx := context.Background()
	tx, err := f.p.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `UPDATE caregiver_links SET status='revoked',revoked_at=$2 WHERE id=$1`, f.link, *f.now); err != nil {
		t.Fatal(err)
	}
	sender := &testPush{result: push.Result{Outcome: push.Accepted}}
	done := make(chan error, 1)
	go func() { _, e := f.s.DeliverAlerts(ctx, sender, 10); done <- e }()
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	if sender.calls.Load() != 0 || f.state(t) != "suppressed" {
		t.Fatal("revocation did not win before claim", sender.calls.Load(), f.state(t))
	}
}

func TestF6ExpiredTokenCanRegisterAgainWithoutTakingActiveDevice(t *testing.T) {
	f := alertsFixture(t)
	ctx := context.Background()
	newID := domain.NewID()
	in := DeviceInput{ID: newID, Platform: "fcm", Token: "synthetic-" + f.device, Permission: "granted"}
	if _, err := f.s.RegisterDevice(ctx, f.patient, in); !errors.Is(err, ErrConflict) {
		t.Fatal("active token takeover", err)
	}
	*f.now = f.now.Add(31 * 24 * time.Hour)
	if _, err := f.s.RegisterDevice(ctx, f.patient, in); err != nil {
		t.Fatal("expired token stranded", err)
	}
	var permission string
	if err := f.p.QueryRow(ctx, `SELECT permission FROM device_registrations WHERE id=$1`, f.device).Scan(&permission); err != nil || permission != "denied" {
		t.Fatal(permission, err)
	}
	if err := f.s.DeleteDevice(ctx, f.patient, newID); err != nil {
		t.Fatal(err)
	}
}

func TestF6TokenRotationRecoversOnlyUnattemptedAlerts(t *testing.T) {
	for _, attempted := range []bool{false, true} {
		t.Run(map[bool]string{false: "pending", true: "uncertain"}[attempted], func(t *testing.T) {
			f := alertsFixture(t)
			f.plan(t)
			sender := &testPush{result: push.Result{Outcome: push.Unknown}}
			if attempted {
				f.deliver(t, sender)
			}
			_, err := f.s.RegisterDevice(context.Background(), f.caregiver, DeviceInput{ID: f.device, Platform: "fcm", Token: "rotated-" + f.device, Permission: "granted"})
			if err != nil {
				t.Fatal(err)
			}
			f.deliver(t, sender)
			f.plan(t)
			sender.result = push.Result{Outcome: push.Accepted}
			f.deliver(t, sender)
			if attempted {
				if sender.calls.Load() != 1 || f.state(t) != "uncertain" {
					t.Fatal("rotation replayed attempted delivery", sender.calls.Load(), f.state(t))
				}
			} else if sender.calls.Load() != 1 || f.state(t) != "sent" {
				t.Fatal("rotation lost pending alert", sender.calls.Load(), f.state(t))
			}
		})
	}
}
