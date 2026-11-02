//go:build integration

package application

import (
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"medication-tracker/services/api/internal/domain"
)

func fixture(t *testing.T) (*Service, *pgxpool.Pool, string) {
	t.Helper()
	ctx := context.Background()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Fatal("TEST_DATABASE_URL required")
	}
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal("cannot configure test pool")
	}
	t.Cleanup(pool.Close)
	var actor string
	if err = pool.QueryRow(ctx, "INSERT INTO users(auth_provider_uid,display_name) VALUES(gen_random_uuid()::text,'Synthetic test') RETURNING id::text").Scan(&actor); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	return New(pool, func() time.Time { return now }), pool, actor
}
func mutation(actor string) Mutation { return Mutation{ActorID: actor, OperationID: domain.NewID()} }
func treatment(t *testing.T, s *Service, actor string) TreatmentResult {
	t.Helper()
	r, err := s.CreateTreatment(context.Background(), CreateTreatmentCommand{Mutation: mutation(actor), PatientID: actor, Name: "Synthetic medication", Unit: "tablet", InitialStock: 10000, StartsOn: "2026-11-01", Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.GenerateOccurrences(context.Background(), r.TreatmentID, "2026-11-01"); err != nil {
		t.Fatal(err)
	}
	return r
}
func dose(t *testing.T, p *pgxpool.Pool, tr string, date string) string {
	t.Helper()
	var id string
	if err := p.QueryRow(context.Background(), "SELECT id::text FROM dose_occurrences WHERE treatment_id=$1 AND scheduled_local_date=$2::date AND cancelled_at IS NULL", tr, date).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}
func TestDoseIdempotencyCorrectionsAndDecimal(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	id := dose(t, p, tr.TreatmentID, "2026-11-01")
	cmd := RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken}
	first, err := s.RecordDoseEvent(ctx, cmd)
	if err != nil {
		t.Fatal(err)
	}
	if first.Balance != 9500 || first.Version != 2 {
		t.Fatal(first)
	}
	for i := 0; i < 3; i++ {
		got, err := s.RecordDoseEvent(ctx, cmd)
		if err != nil || got != first {
			t.Fatal(got, err)
		}
	}
	changed := cmd
	changed.State = domain.Skipped
	if _, err = s.RecordDoseEvent(ctx, changed); !errors.Is(err, ErrConflict) {
		t.Fatal("key reuse", err)
	}
	correction := CorrectDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 2, CorrectsEventID: first.EventID, State: domain.Skipped, Reason: "Synthetic correction"}
	skipped, err := s.CorrectDoseEvent(ctx, correction)
	if err != nil || skipped.Balance != 10000 {
		t.Fatal(skipped, err)
	}
	correction.Mutation = mutation(a)
	correction.ExpectedVersion = 3
	correction.CorrectsEventID = skipped.EventID
	correction.State = domain.TakenLate
	if _, err = s.CorrectDoseEvent(ctx, correction); !errors.Is(err, ErrInvalid) {
		t.Fatal("late time required", err)
	}
	effective := time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	correction.OccurredAt = &effective
	late, err := s.CorrectDoseEvent(ctx, correction)
	if err != nil || late.Balance != 9500 {
		t.Fatal(late, err)
	}
	replay, err := s.RecordDoseEvent(ctx, cmd)
	if err != nil || replay != first {
		t.Fatal("stored original response", replay, err)
	}
	events := countRows(t, p, "SELECT count(*) FROM dose_events WHERE dose_occurrence_id=$1", id)
	movements := countRows(t, p, "SELECT count(*) FROM inventory_movements WHERE inventory_account_id=$1", tr.AccountID)
	active := countRows(t, p, "SELECT count(*) FROM active_consumptions WHERE dose_occurrence_id=$1", id)
	if events != 3 || movements != 4 || active != 1 {
		t.Fatal(events, movements, active)
	}
	if _, err = p.Exec(ctx, "DELETE FROM dose_events WHERE dose_occurrence_id=$1", id); err == nil {
		t.Fatal("history delete accepted")
	}
	projection, err := s.GetInventoryProjection(ctx, tr.AccountID, time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC))
	if err != nil || projection.Balance != 9500 || projection.FirstUncoveredAt == nil {
		t.Fatal(projection, err)
	}
}
func TestConcurrentCommandsAndReplenishment(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	id := dose(t, p, tr.TreatmentID, "2026-11-01")
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	start := make(chan struct{})
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken})
			errs <- err
		}()
	}
	close(start)
	wg.Wait()
	close(errs)
	successes := 0
	for err := range errs {
		if err == nil {
			successes++
		} else if !errors.Is(err, ErrConflict) {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatal(successes)
	}
	cmd := ReplenishInventoryCommand{Mutation: mutation(a), AccountID: tr.AccountID, Quantity: 100}
	errs = make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := s.ReplenishInventory(ctx, cmd); errs <- err }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.GetInventoryProjection(ctx, tr.AccountID, time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC))
	if err != nil || got.Balance != 9600 {
		t.Fatal(got, err)
	}
}
func TestSkippedPendingAndRevisionHistory(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	past := dose(t, p, tr.TreatmentID, "2026-11-01")
	future := dose(t, p, tr.TreatmentID, "2026-11-03")
	_, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: past, ExpectedVersion: 1, State: domain.Skipped})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.ReviseSchedule(ctx, ReviseScheduleCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "09:00", Quantity: 1000}}}})
	if err != nil || r.Version != 2 {
		t.Fatal(r, err)
	}
	for i := 0; i < 2; i++ {
		if _, err = s.GenerateOccurrences(ctx, tr.TreatmentID, "2026-11-01"); err != nil {
			t.Fatal(err)
		}
	}
	if dose(t, p, tr.TreatmentID, "2026-11-01") != past {
		t.Fatal("past identity changed")
	}
	if dose(t, p, tr.TreatmentID, "2026-11-03") == future {
		t.Fatal("future not replaced")
	}
	if _, err = s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: future, ExpectedVersion: 1, State: domain.Taken}); !errors.Is(err, ErrConflict) {
		t.Fatal("cancelled dose", err)
	}
	got, err := s.GetInventoryProjection(ctx, tr.AccountID, time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC))
	if err != nil || got.Balance != 10000 {
		t.Fatal(got, err)
	}
	count := countRows(t, p, "SELECT count(*) FROM dose_occurrences WHERE treatment_id=$1 AND cancelled_at IS NULL", tr.TreatmentID)
	if count != 30 {
		t.Fatal(count)
	}
}

func countRows(t *testing.T, p *pgxpool.Pool, query string, args ...any) int {
	t.Helper()
	var n int
	if err := p.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
func TestConcurrentSameOperationAndCorrection(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	id := dose(t, p, tr.TreatmentID, "2026-11-01")
	c := RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken}
	results := make(chan DoseResult, 10)
	errs := make(chan error, 10)
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); r, e := s.RecordDoseEvent(ctx, c); results <- r; errs <- e }()
	}
	wg.Wait()
	close(results)
	close(errs)
	var first DoseResult
	for r := range results {
		if first.EventID == "" {
			first = r
		}
		if r != first {
			t.Fatal("retry response changed", r, first)
		}
	}
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	correction := CorrectDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 2, CorrectsEventID: first.EventID, State: domain.Skipped, Reason: "Synthetic correction"}
	results = make(chan DoseResult, 10)
	errs = make(chan error, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); r, e := s.CorrectDoseEvent(ctx, correction); results <- r; errs <- e }()
	}
	wg.Wait()
	close(results)
	close(errs)
	var corrected DoseResult
	for r := range results {
		if corrected.EventID == "" {
			corrected = r
		}
		if r != corrected || r.Balance != 10000 {
			t.Fatal(r)
		}
	}
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	correction.Mutation = mutation(a)
	correction.ExpectedVersion = 3
	if _, e := s.CorrectDoseEvent(ctx, correction); !errors.Is(e, ErrConflict) {
		t.Fatal("stale event accepted", e)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_events WHERE dose_occurrence_id=$1", id); n != 2 {
		t.Fatal(n)
	}
}
func TestReplenishmentAndDifferentDosesRace(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	ids := []string{dose(t, p, tr.TreatmentID, "2026-11-01"), dose(t, p, tr.TreatmentID, "2026-11-02")}
	start := make(chan struct{})
	errs := make(chan error, 22)
	var wg sync.WaitGroup
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			<-start
			_, e := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken})
			errs <- e
		}(id)
	}
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, e := s.ReplenishInventory(ctx, ReplenishInventoryCommand{Mutation: mutation(a), AccountID: tr.AccountID, Quantity: 100})
			errs <- e
		}()
	}
	close(start)
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	projection, e := s.GetInventoryProjection(ctx, tr.AccountID, s.now())
	if e != nil || projection.Balance != 11000 {
		t.Fatal(projection, e)
	}
	if n := countRows(t, p, "SELECT count(*) FROM active_consumptions WHERE treatment_id=$1", tr.TreatmentID); n != 2 {
		t.Fatal(n)
	}
}
func TestTransactionRollsBackEventAndOperation(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	id := dose(t, p, tr.TreatmentID, "2026-11-01")
	_, err := p.Exec(ctx, "CREATE FUNCTION test_reject_movement() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.actor_user_id='"+a+"'::uuid AND NEW.reason='consumption' THEN RAISE EXCEPTION 'synthetic write failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER test_reject BEFORE INSERT ON inventory_movements FOR EACH ROW EXECUTE FUNCTION test_reject_movement()")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, e := p.Exec(ctx, "DROP TRIGGER IF EXISTS test_reject ON inventory_movements; DROP FUNCTION IF EXISTS test_reject_movement()"); e != nil {
			t.Error(e)
		}
	})
	cmd := RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken}
	if _, err = s.RecordDoseEvent(ctx, cmd); err == nil {
		t.Fatal("injected failure ignored")
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_events WHERE dose_occurrence_id=$1", id); n != 0 {
		t.Fatal("partial event", n)
	}
	if n := countRows(t, p, "SELECT count(*) FROM operations WHERE actor_user_id=$1 AND client_operation_id=$2", a, cmd.OperationID); n != 0 {
		t.Fatal("partial operation", n)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_occurrences WHERE id=$1 AND status='pending' AND version=1", id); n != 1 {
		t.Fatal("partial state", n)
	}
	if _, err = p.Exec(ctx, "DROP TRIGGER test_reject ON inventory_movements; DROP FUNCTION test_reject_movement()"); err != nil {
		t.Fatal(err)
	}
	if r, e := s.RecordDoseEvent(ctx, cmd); e != nil || r.Balance != 9500 {
		t.Fatal("retry after rollback", r, e)
	}
}
func TestProjectionDoesNotDependOnMaterialization(t *testing.T) {
	s, _, a := fixture(t)
	ctx := context.Background()
	tr, err := s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(a), PatientID: a, Name: "Synthetic", Unit: "ml", InitialStock: 3000, StartsOn: "2026-11-01", Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 1000}, {Time: "20:00", Quantity: 1000}}}})
	if err != nil {
		t.Fatal(err)
	}
	from := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	projection, err := s.GetInventoryProjection(ctx, tr.AccountID, from)
	want := time.Date(2026, 11, 3, 20, 0, 0, 0, time.UTC)
	if err != nil || projection.ScheduledQuantity != 60000 || projection.FirstUncoveredAt == nil || !projection.FirstUncoveredAt.Equal(want) || !projection.Through.Equal(time.Date(2026, 12, 2, 0, 0, 0, 0, time.UTC)) {
		t.Fatal(projection, err)
	}
	replenish := ReplenishInventoryCommand{Mutation: mutation(a), AccountID: tr.AccountID, Quantity: 100000}
	if _, err = s.ReplenishInventory(ctx, replenish); err != nil {
		t.Fatal(err)
	}
	projection, err = s.GetInventoryProjection(ctx, tr.AccountID, from)
	if err != nil || projection.FirstUncoveredAt != nil {
		t.Fatal(projection, err)
	}
}
func TestUnknownIDsAndFutureDeclaration(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	for _, id := range []string{"invalid", domain.NewID()} {
		_, e := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken})
		if !errors.Is(e, ErrInvalid) && !errors.Is(e, ErrNotFound) {
			t.Fatal(e)
		}
	}
	future := dose(t, p, tr.TreatmentID, "2026-11-03")
	if _, e := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: future, ExpectedVersion: 1, State: domain.Taken}); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
}

func TestNegativeBalanceAndCorrectionWithoutExtraConsumption(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr, err := s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(a), PatientID: a, Name: "Synthetic", Unit: "tablet", StartsOn: "2026-11-01", Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.GenerateOccurrences(ctx, tr.TreatmentID, "2026-11-01"); err != nil {
		t.Fatal(err)
	}
	id := dose(t, p, tr.TreatmentID, "2026-11-01")
	original, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken})
	if err != nil || original.Balance != -500 {
		t.Fatal(original, err)
	}
	at := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	c := CorrectDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 2, CorrectsEventID: original.EventID, State: domain.TakenLate, OccurredAt: &at, Reason: "Synthetic time correction"}
	corrected, err := s.CorrectDoseEvent(ctx, c)
	if err != nil || corrected.Balance != -500 {
		t.Fatal(corrected, err)
	}
	again, err := s.CorrectDoseEvent(ctx, c)
	if err != nil || again != corrected {
		t.Fatal(again, err)
	}
	if n := countRows(t, p, "SELECT count(*) FROM inventory_movements WHERE inventory_account_id=$1", tr.AccountID); n != 1 {
		t.Fatal(n)
	}
	if n := countRows(t, p, "SELECT count(*) FROM active_consumptions WHERE dose_occurrence_id=$1", id); n != 1 {
		t.Fatal(n)
	}
}
func TestRevisionKeepsPastPendingAndConcurrentGeneration(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	past := dose(t, p, tr.TreatmentID, "2026-11-01")
	errs := make(chan error, 2)
	start := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		_, e := s.GenerateOccurrences(ctx, tr.TreatmentID, "2026-11-01")
		errs <- e
	}()
	go func() {
		defer wg.Done()
		<-start
		_, e := s.ReviseSchedule(ctx, ReviseScheduleCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), Schedule: domain.Schedule{Timezone: "America/Santiago", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "09:00", Quantity: 1000}}}})
		errs <- e
	}()
	close(start)
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	if _, e := s.GenerateOccurrences(ctx, tr.TreatmentID, "2026-11-01"); e != nil {
		t.Fatal(e)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_occurrences WHERE id=$1 AND status='pending' AND version=1 AND cancelled_at IS NULL", past); n != 1 {
		t.Fatal(n)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_occurrences WHERE treatment_id=$1 AND cancelled_at IS NULL", tr.TreatmentID); n != 30 {
		t.Fatal(n)
	}
}
func TestExpiredRevisionDSTAndBoundedSchedule(t *testing.T) {
	s, p, a := fixture(t)
	s.now = func() time.Time { return time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC) }
	ctx := context.Background()
	tr, err := s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(a), PatientID: a, Name: "Synthetic", Unit: "tablet", StartsOn: "2026-09-01", EndsOn: "2026-09-10", Schedule: domain.Schedule{Timezone: "America/Santiago", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "00:30", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.ReviseSchedule(ctx, ReviseScheduleCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC), Schedule: domain.Schedule{Timezone: "America/Santiago", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.GenerateOccurrences(ctx, tr.TreatmentID, "2026-09-01"); err != nil {
		t.Fatal(err)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_occurrences WHERE treatment_id=$1 AND cancelled_at IS NULL", tr.TreatmentID); n != 10 {
		t.Fatal(n)
	}
	projection, err := s.GetInventoryProjection(ctx, tr.AccountID, s.now())
	if err != nil || projection.Through.Sub(time.Date(2026, 9, 2, 4, 0, 0, 0, time.UTC)) != 30*24*time.Hour-time.Hour {
		t.Fatal(projection, err)
	}
}
func TestDatabaseOwnershipAndAppendOnlyConstraints(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	var other string
	if err := p.QueryRow(ctx, "INSERT INTO users(auth_provider_uid,display_name) VALUES(gen_random_uuid()::text,'Synthetic other') RETURNING id::text").Scan(&other); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Exec(ctx, "INSERT INTO patients(user_id) VALUES($1)", other); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Exec(ctx, "UPDATE inventory_accounts SET patient_user_id=$2 WHERE id=$1", tr.AccountID, other); err == nil {
		t.Fatal("cross-patient account accepted")
	}
	if _, err := p.Exec(ctx, "UPDATE treatments SET patient_user_id=$2 WHERE id=$1", tr.TreatmentID, other); err == nil {
		t.Fatal("cross-patient medication accepted")
	}
	id := dose(t, p, tr.TreatmentID, "2026-11-01")
	record, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: id, ExpectedVersion: 1, State: domain.Taken})
	if err != nil {
		t.Fatal(err)
	}
	checks := []struct {
		query string
		arg   string
	}{
		{"UPDATE dose_events SET resulting_state='skipped',occurred_at=NULL WHERE id=$1", record.EventID},
		{"UPDATE inventory_movements SET quantity_delta=123 WHERE inventory_account_id=$1", tr.AccountID},
		{"DELETE FROM inventory_movements WHERE inventory_account_id=$1", tr.AccountID},
		{"UPDATE schedule_revisions SET timezone='UTC' WHERE id=$1", tr.RevisionID},
	}
	for _, c := range checks {
		if _, err := p.Exec(ctx, c.query, c.arg); err == nil {
			t.Fatal("audit mutation accepted")
		}
	}
	if _, err := p.Exec(ctx, "INSERT INTO dose_events(dose_occurrence_id,treatment_id,actor_user_id,client_operation_id,event_type,resulting_state,version,recorded_at,correction_of_event_id) VALUES($1,$2,$3,gen_random_uuid(),'corrected','skipped',3,now(),$4)", id, tr.TreatmentID, a, record.EventID); err == nil {
		t.Fatal("NULL correction reason accepted")
	}
}
