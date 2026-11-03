//go:build integration

package application

import (
	"context"
	"errors"
	"medication-tracker/services/api/internal/domain"
	"testing"
	"time"
)

func TestF7AdherenceCurrentEventsWindowAndFuture(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	first := dose(t, p, tr.TreatmentID, "2026-11-01")
	at := time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	event, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: first, ExpectedVersion: 1, State: domain.Taken, OccurredAt: &at})
	if err != nil {
		t.Fatal(err)
	}
	report, err := s.Adherence(ctx, a, a, "2026-11-01", "2026-12-02", "", 60)
	if err != nil || len(report.Days) != 31 || report.Summary.Evaluable != 2 || report.Summary.Taken != 1 || report.Summary.Unconfirmed != 1 || report.Summary.Punctual != 1 {
		t.Fatal(report, err)
	}
	narrow, err := s.Adherence(ctx, a, a, "2026-11-01", "2026-11-03", tr.TreatmentID, 59)
	if err != nil || narrow.Summary.Punctual != 0 || *narrow.Summary.PunctualityRate != 0 {
		t.Fatal(narrow, err)
	}
	_, err = s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(a), DoseID: first, ExpectedVersion: 2, CorrectsEventID: event.EventID, State: domain.TakenLate, OccurredAt: &at, Reason: "Synthetic correction"})
	if err != nil {
		t.Fatal(err)
	}
	corrected, err := s.Adherence(ctx, a, a, "2026-11-01", "2026-11-03", "", 60)
	if err != nil || corrected.Summary.Taken != 0 || corrected.Summary.TakenLate != 1 || corrected.Summary.Punctual != 0 || corrected.Summary.Confirmed != 1 {
		t.Fatal(corrected, err)
	}
	future, err := s.Adherence(ctx, a, a, "2026-11-03", "2026-11-05", "", 60)
	if err != nil || future.Summary.Evaluable != 0 || future.Summary.AdherenceRate != nil {
		t.Fatal(future, err)
	}
	s.now = func() time.Time { return time.Date(2026, 11, 2, 8, 0, 0, 0, time.UTC) }
	boundary, err := s.Adherence(ctx, a, a, "2026-11-02", "2026-11-03", "", 60)
	if err != nil || boundary.Summary.Evaluable != 0 {
		t.Fatal(boundary, err)
	}
}
func TestF7AdherenceCancellationRevisionsArchiveAndPagination(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	revised, err := s.ReviseSchedule(ctx, ReviseScheduleCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}, {Time: "09:00", Quantity: 500}, {Time: "10:00", Quantity: 500}, {Time: "11:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return time.Date(2026, 12, 1, 12, 0, 0, 0, time.UTC) }
	report, err := s.Adherence(ctx, a, a, "2026-11-01", "2026-12-01", "", 60)
	if err != nil || report.Summary.Evaluable != 114 || report.Summary.Unconfirmed != 114 {
		t.Fatal(report, err)
	}
	var cancelled int
	if err = p.QueryRow(ctx, `SELECT count(*) FROM dose_occurrences WHERE treatment_id=$1 AND cancelled_at IS NOT NULL`, tr.TreatmentID).Scan(&cancelled); err != nil || cancelled == 0 {
		t.Fatal(cancelled, err)
	}
	list, next, err := s.FilteredAgenda(ctx, a, a, "2026-11-01", "2026-12-01", "", tr.TreatmentID)
	if err != nil || len(list) != 100 || next == "" {
		t.Fatal(len(list), next, err)
	}
	rest, next, err := s.FilteredAgenda(ctx, a, a, "2026-11-01", "2026-12-01", next, tr.TreatmentID)
	if err != nil || len(rest) != 14 || next != "" {
		t.Fatal(len(rest), next, err)
	}
	_, err = s.ArchiveTreatment(ctx, ArchiveTreatmentCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: revised.Version, Reason: "Synthetic end"})
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return time.Date(2026, 12, 3, 12, 0, 0, 0, time.UTC) }
	archived, err := s.Adherence(ctx, a, a, "2026-11-01", "2026-12-04", "", 60)
	if err != nil || archived.Summary.Evaluable != 118 {
		t.Fatal(archived, err)
	}
	if _, err = s.Adherence(ctx, a, a, "2026-11-01", "2026-11-03", domain.NewID(), 60); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}
func TestF7StockThresholdIdempotencyConflictAndCalendar(t *testing.T) {
	s, _, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	cmd := SetStockThresholdCommand{Mutation: mutation(a), AccountID: tr.AccountID, ExpectedDays: 5, Days: 25}
	got, err := s.SetStockThreshold(ctx, cmd)
	if err != nil || got.Days != 25 {
		t.Fatal(got, err)
	}
	again, err := s.SetStockThreshold(ctx, cmd)
	if err != nil || again != got {
		t.Fatal(again, err)
	}
	stale := cmd
	stale.Mutation = mutation(a)
	stale.Days = 10
	if _, err = s.SetStockThreshold(ctx, stale); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	reused := cmd
	reused.Days = 10
	if _, err = s.SetStockThreshold(ctx, reused); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	bad := cmd
	bad.Mutation = mutation(a)
	bad.Days = 31
	if _, err = s.SetStockThreshold(ctx, bad); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	projection, err := s.GetInventoryProjection(ctx, a, tr.AccountID, s.now())
	if err != nil || projection.LowStockDaysThreshold != 25 || projection.Timezone != "UTC" || projection.ReplenishOn == nil || *projection.ReplenishOn != "2026-10-29" || !projection.LowStock {
		t.Fatal(projection, err)
	}
}
func TestF7AdherenceSantiagoDSTAndLocalDate(t *testing.T) {
	s, _, a := fixture(t)
	ctx := context.Background()
	tr, err := s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(a), PatientID: a, Name: "Synthetic DST", Unit: "tablet", StartsOn: "2026-09-05", Schedule: domain.Schedule{Timezone: "America/Santiago", Policy: domain.NextValidEarliest, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "00:30", Quantity: 500}, {Time: "23:30", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC) }
	report, err := s.Adherence(ctx, a, a, "2026-09-05", "2026-09-08", tr.TreatmentID, 60)
	if err != nil || report.Summary.Evaluable != 6 || len(report.Days) != 3 {
		t.Fatal(report, err)
	}
	for _, day := range report.Days {
		if day.Evaluable != 2 {
			t.Fatal(day)
		}
	}
	history, _, err := s.FilteredAgenda(ctx, a, a, "2026-09-06", "2026-09-07", "", tr.TreatmentID)
	if err != nil || len(history) != 2 {
		t.Fatal(history, err)
	}
	adjusted := 0
	for _, d := range history {
		if d.DSTAdjusted {
			adjusted++
		}
	}
	if adjusted != 1 {
		t.Fatal(history)
	}
}

func TestF7MixedDeclarationsCorrectionsAndEarlyBoundary(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	s.now = func() time.Time { return time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC) }
	states := []domain.DoseState{domain.Taken, domain.TakenLate, domain.Skipped}
	var first DoseResult
	for i, state := range states {
		date := time.Date(2026, 11, i+1, 7, 0, 0, 0, time.UTC)
		var occurred *time.Time
		if state != domain.Skipped {
			occurred = &date
		}
		got, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: dose(t, p, tr.TreatmentID, date.Format("2006-01-02")), ExpectedVersion: 1, State: state, OccurredAt: occurred})
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = got
		}
	}
	report, err := s.Adherence(ctx, a, a, "2026-11-01", "2026-11-05", "", 60)
	c := report.Summary
	if err != nil || c.Evaluable != 4 || c.Taken != 1 || c.TakenLate != 1 || c.Skipped != 1 || c.Unconfirmed != 1 || c.Punctual != 1 || *c.AdherenceRate != 0.5 || *c.ConfirmationRate != 0.75 || *c.UnconfirmedRate != 0.25 || *c.PunctualityRate != 0.5 {
		t.Fatal(report, err)
	}
	corrected, err := s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(a), DoseID: first.DoseID, ExpectedVersion: first.Version, CorrectsEventID: first.EventID, State: domain.Skipped, Reason: "Synthetic correction"})
	if err != nil {
		t.Fatal(err)
	}
	report, err = s.Adherence(ctx, a, a, "2026-11-01", "2026-11-02", "", 60)
	if err != nil || report.Summary.Skipped != 1 || report.Summary.Taken != 0 || report.Summary.PunctualityRate != nil || *report.Summary.ConfirmationRate != 1 {
		t.Fatal(report, err)
	}
	outside := time.Date(2026, 11, 1, 6, 59, 59, 0, time.UTC)
	_, err = s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(a), DoseID: first.DoseID, ExpectedVersion: corrected.Version, CorrectsEventID: corrected.EventID, State: domain.Taken, OccurredAt: &outside, Reason: "Synthetic corrected time"})
	if err != nil {
		t.Fatal(err)
	}
	report, err = s.Adherence(ctx, a, a, "2026-11-01", "2026-11-02", "", 60)
	if err != nil || report.Summary.Taken != 1 || report.Summary.Skipped != 0 || report.Summary.Punctual != 0 || *report.Summary.AdherenceRate != 1 {
		t.Fatal(report, err)
	}
}
func TestF7StockReviewDateAcrossSantiagoDST(t *testing.T) {
	s, _, a := fixture(t)
	ctx := context.Background()
	tr, err := s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(a), PatientID: a, Name: "Synthetic calendar stock", Unit: "tablet", InitialStock: 1000, StartsOn: "2026-09-05", Schedule: domain.Schedule{Timezone: "America/Santiago", Policy: domain.NextValidEarliest, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "00:30", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.SetStockThreshold(ctx, SetStockThresholdCommand{Mutation: mutation(a), AccountID: tr.AccountID, ExpectedDays: 5, Days: 2})
	if err != nil {
		t.Fatal(err)
	}
	from := time.Date(2026, 9, 5, 4, 0, 0, 0, time.UTC)
	projection, err := s.GetInventoryProjection(ctx, a, tr.AccountID, from)
	if err != nil || projection.FirstUncoveredAt == nil || !projection.FirstUncoveredAt.Equal(time.Date(2026, 9, 7, 3, 30, 0, 0, time.UTC)) || projection.ReplenishOn == nil || *projection.ReplenishOn != "2026-09-05" || !projection.LowStock {
		t.Fatal(projection, err)
	}
}
