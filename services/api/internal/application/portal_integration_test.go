//go:build integration

package application

import (
	"context"
	"errors"
	"medication-tracker/services/api/internal/domain"
	"testing"
	"time"
)

func TestPortalCountAndArchive(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	count := PhysicalCountCommand{Mutation: mutation(a), AccountID: tr.AccountID, CountedQuantity: 7250, ExpectedBalance: 10000, Reason: "Synthetic count"}
	got, err := s.RecordPhysicalCount(ctx, count)
	if err != nil || got.Balance != 7250 {
		t.Fatal(got, err)
	}
	replay, err := s.RecordPhysicalCount(ctx, count)
	if err != nil || replay.CountID != got.CountID || replay.Balance != got.Balance {
		t.Fatal(replay, err)
	}
	count.Mutation = mutation(a)
	if _, err = s.RecordPhysicalCount(ctx, count); !errors.Is(err, ErrConflict) {
		t.Fatal("stale count", err)
	}
	count.ExpectedBalance = 7250
	zero, err := s.RecordPhysicalCount(ctx, count)
	if err != nil || zero.MovementID != nil {
		t.Fatal(zero, err)
	}
	if n := countRows(t, p, "SELECT count(*) FROM inventory_counts WHERE inventory_account_id=$1", tr.AccountID); n != 2 {
		t.Fatal(n)
	}
	if _, err = p.Exec(ctx, "DELETE FROM inventory_counts WHERE inventory_account_id=$1", tr.AccountID); err == nil {
		t.Fatal("audit deleted")
	}
	update := UpdateTreatmentCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, Name: "Synthetic updated", Instructions: "Synthetic instructions"}
	edited, err := s.UpdateTreatment(ctx, update)
	if err != nil || edited.Version != 2 {
		t.Fatal(edited, err)
	}
	revised, err := s.ReviseSchedule(ctx, ReviseScheduleCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 2, EffectiveFrom: s.now().Add(time.Hour), Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "09:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	archived, err := s.ArchiveTreatment(ctx, ArchiveTreatmentCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: revised.Version, Reason: "Synthetic archive"})
	if err != nil || archived.Version != 4 {
		t.Fatal(archived, err)
	}
	if _, err = s.GenerateOccurrences(ctx, a, tr.TreatmentID, "2026-11-03"); err != nil {
		t.Fatal(err)
	}
	rows, _, err := s.Agenda(ctx, a, a, "2026-11-01", "2026-11-05", "")
	if err != nil || len(rows) != 2 {
		t.Fatal(len(rows), err)
	}
	projection, err := s.GetInventoryProjection(ctx, a, tr.AccountID, s.now())
	if err != nil || projection.ScheduledQuantity != 0 {
		t.Fatal(projection, err)
	}
	_, _, other := fixture(t)
	if _, _, err = s.InventoryMovements(ctx, other, tr.AccountID, ""); !errors.Is(err, ErrNotFound) {
		t.Fatal("IDOR", err)
	}
}

func TestPhysicalCountConcurrentReplenishmentAndReplay(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	cmd := PhysicalCountCommand{Mutation: mutation(a), AccountID: tr.AccountID, CountedQuantity: 7000, ExpectedBalance: 10000, Reason: "Synthetic concurrent count"}
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() { _, err := s.RecordPhysicalCount(ctx, cmd); results <- err }()
	}
	for i := 0; i < 8; i++ {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if n := countRows(t, p, "SELECT count(*) FROM inventory_counts WHERE inventory_account_id=$1", tr.AccountID); n != 1 {
		t.Fatal(n)
	}
	cmd.Mutation = mutation(a)
	cmd.ExpectedBalance = 7000
	cmd.CountedQuantity = 6000
	go func() { _, err := s.RecordPhysicalCount(ctx, cmd); results <- err }()
	go func() {
		_, err := s.ReplenishInventory(ctx, ReplenishInventoryCommand{Mutation: mutation(a), AccountID: tr.AccountID, Quantity: 1000})
		results <- err
	}()
	conflicts := 0
	for i := 0; i < 2; i++ {
		err := <-results
		if errors.Is(err, ErrConflict) {
			conflicts++
		} else if err != nil {
			t.Fatal(err)
		}
	}
	projection, err := s.GetInventoryProjection(ctx, a, tr.AccountID, s.now())
	if err != nil {
		t.Fatal(err)
	}
	if (conflicts == 0 && projection.Balance != 7000) || (conflicts == 1 && projection.Balance != 8000) {
		t.Fatal(conflicts, projection.Balance)
	}
	for _, q := range []domain.Quantity{-1, domain.MaxQuantity + 1} {
		bad := cmd
		bad.Mutation = mutation(a)
		bad.CountedQuantity = q
		if _, err = s.RecordPhysicalCount(ctx, bad); !errors.Is(err, ErrInvalid) {
			t.Fatal("invalid quantity accepted", err)
		}
	}
}

func TestArchivePreservesDeclarationAndReplay(t *testing.T) {
	s, p, a := fixture(t)
	ctx := context.Background()
	tr := treatment(t, s, a)
	old := dose(t, p, tr.TreatmentID, "2026-11-01")
	if _, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(a), DoseID: old, ExpectedVersion: 1, State: domain.Taken}); err != nil {
		t.Fatal(err)
	}
	cmd := ArchiveTreatmentCommand{Mutation: mutation(a), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, Reason: "Synthetic archive"}
	first, err := s.ArchiveTreatment(ctx, cmd)
	if err != nil {
		t.Fatal(err)
	}
	replay, err := s.ArchiveTreatment(ctx, cmd)
	if err != nil || replay != first {
		t.Fatal(replay, err)
	}
	cmd.Mutation = mutation(a)
	if _, err = s.ArchiveTreatment(ctx, cmd); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_events WHERE dose_occurrence_id=$1", old); n != 1 {
		t.Fatal(n)
	}
	if n := countRows(t, p, "SELECT count(*) FROM dose_occurrences WHERE treatment_id=$1 AND scheduled_at >= '2026-11-02T12:00:00Z' AND cancelled_at IS NULL", tr.TreatmentID); n != 0 {
		t.Fatal(n)
	}
}
