//go:build integration

package application

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"medication-tracker/services/api/internal/domain"
)

func TestAccountExportOwnHistoryAndNoSecrets(t *testing.T) {
	s, pool, owner := fixture(t)
	ctx := context.Background()
	own := treatment(t, s, owner)
	other, err := s.ResolveUser(ctx, domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	foreign := treatment(t, s, other)
	inv, err := s.CreateInvitation(ctx, mutation(owner), []Scope{ScopeRead, ScopeDoses}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptInvitation(ctx, mutation(other), inv.Token); err != nil {
		t.Fatal(err)
	}
	// The exporter is an authorized caregiver of another person, including an event they authored there.
	foreignDose := dose(t, pool, foreign.TreatmentID, "2026-11-01")
	if _, err = s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(owner), DoseID: foreignDose, ExpectedVersion: 1, State: domain.Skipped}); err != nil {
		t.Fatal(err)
	}
	ownDose := dose(t, pool, own.TreatmentID, "2026-11-01")
	taken, err := s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(owner), DoseID: ownDose, ExpectedVersion: 1, State: domain.Taken})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(owner), DoseID: ownDose, ExpectedVersion: 2, CorrectsEventID: taken.EventID, State: domain.Skipped, Reason: "Synthetic correction"}); err != nil {
		t.Fatal(err)
	}
	if _, err = s.RecordPhysicalCount(ctx, PhysicalCountCommand{Mutation: mutation(owner), AccountID: own.AccountID, ExpectedBalance: 10000, CountedQuantity: 9750, Reason: "Synthetic count"}); err != nil {
		t.Fatal(err)
	}
	if _, err = s.UpdateTreatment(ctx, UpdateTreatmentCommand{Mutation: mutation(owner), TreatmentID: own.TreatmentID, ExpectedVersion: 1, Name: "Synthetic renamed", Instructions: "Synthetic instruction"}); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ArchiveTreatment(ctx, ArchiveTreatmentCommand{Mutation: mutation(owner), TreatmentID: own.TreatmentID, ExpectedVersion: 2, Reason: "Synthetic archive"}); err != nil {
		t.Fatal(err)
	}
	token := "synthetic-push-" + domain.NewID()
	if _, err = s.RegisterDevice(ctx, owner, DeviceInput{ID: domain.NewID(), Platform: "fcm", Permission: "granted", Token: token}); err != nil {
		t.Fatal(err)
	}
	out, err := s.ExportAccount(ctx, owner)
	if err != nil {
		t.Fatal(err)
	}
	if out.SchemaVersion != 1 || out.Profile.UserID != owner || len(out.Treatments) != 1 || len(out.DoseEvents) != 2 || len(out.InventoryMovements) != 4 || len(out.InventoryCounts) != 1 || len(out.TreatmentChanges) != 2 || len(out.Devices) != 1 || len(out.Invitations) != 1 || len(out.CaregiverLinks) != 1 || len(out.ConsentEvents) != 1 {
		t.Fatalf("incomplete export: %+v", out)
	}
	data, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{foreign.TreatmentID, foreignDose, token, inv.Token, "auth_provider_uid", "token_hash", "client_operation_id", "fingerprint"} {
		if strings.Contains(string(data), forbidden) {
			t.Fatalf("export contains forbidden field or value %q", forbidden)
		}
	}
	var eventStates = map[string]bool{}
	for _, record := range out.DoseEvents {
		var event struct {
			State string `json:"resulting_state"`
		}
		if err = json.Unmarshal(record, &event); err != nil {
			t.Fatal(err)
		}
		eventStates[event.State] = true
	}
	if !eventStates["taken"] || !eventStates["skipped"] {
		t.Fatal("correction history missing", eventStates)
	}
	var cancelled bool
	for _, record := range out.Doses {
		var d struct {
			Cancelled *string `json:"cancelled_at"`
			Quantity  string  `json:"dose_quantity"`
		}
		if err = json.Unmarshal(record, &d); err != nil {
			t.Fatal(err)
		}
		if d.Quantity != "0.500" {
			t.Fatal("inexact dose", d.Quantity)
		}
		cancelled = cancelled || d.Cancelled != nil
	}
	if !cancelled {
		t.Fatal("cancelled occurrences missing")
	}
	if !strings.Contains(string(data), `"quantity_delta":"-0.500"`) || !strings.Contains(string(data), `"counted_quantity":"9.750"`) || !strings.Contains(string(data), `"quantity":"0.500"`) {
		t.Fatal("exact decimal strings missing")
	}
	// Every failure returns no partial clinical data.
	for _, limits := range [][2]int{{1, ExportMaxBytes}, {ExportMaxRows, 1}} {
		partial, limitErr := s.exportAccount(ctx, owner, limits[0], limits[1])
		if !errors.Is(limitErr, ErrExportTooLarge) || partial.SchemaVersion != 0 || partial.Profile.UserID != "" {
			t.Fatal("partial export or missing bound", limitErr)
		}
	}
	empty, err := s.ExportAccount(ctx, domain.NewID())
	if !errors.Is(err, ErrNotFound) || empty.SchemaVersion != 0 {
		t.Fatal("unknown actor accepted", err)
	}
}

func TestAccountExportKeepsOneSnapshotAcrossSections(t *testing.T) {
	s, pool, owner := fixture(t)
	tr := treatment(t, s, owner)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	lock, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback(context.Background())
	if _, err = lock.Exec(ctx, "LOCK TABLE inventory_movements IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal(err)
	}
	config := pool.Config()
	name := "export-snapshot-" + domain.NewID()
	config.ConnConfig.RuntimeParams["application_name"] = name
	exportPool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer exportPool.Close()
	type result struct {
		value AccountExport
		err   error
	}
	done := make(chan result, 1)
	go func() {
		value, exportErr := New(exportPool, nil).ExportAccount(ctx, owner)
		done <- result{value, exportErr}
	}()
	for {
		var waiting bool
		err = pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock')`, name).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("export did not reach held ledger lock")
		case <-time.After(5 * time.Millisecond):
		}
	}
	if _, err = s.UpdateTreatment(ctx, UpdateTreatmentCommand{Mutation: mutation(owner), TreatmentID: tr.TreatmentID, ExpectedVersion: 1, Name: "Synthetic changed during export", Instructions: "Synthetic newer instruction"}); err != nil {
		t.Fatal(err)
	}
	if err = lock.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	got := <-done
	if got.err != nil {
		t.Fatal(got.err)
	}
	if len(got.value.TreatmentChanges) != 0 {
		t.Fatal("export mixed a later audit entry into its earlier snapshot")
	}
	later, err := s.ExportAccount(ctx, owner)
	if err != nil {
		t.Fatal(err)
	}
	if len(later.TreatmentChanges) != 1 {
		t.Fatal("fixture mutation missing from later snapshot")
	}
}
