//go:build integration

package application

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"medication-tracker/services/api/internal/domain"
)

type poolFixture struct {
	s          *Service
	p          *pgxpool.Pool
	mama, papa string
}

type medication struct {
	name, strength, form, unit, zone, slot string
	quantity, stock                        domain.Quantity
}

func standardMedication() medication {
	return medication{name: "Losartán", strength: "50 mg", form: "comprimido", unit: "tablet", zone: "UTC", slot: "12:00", quantity: 500, stock: 10000}
}

func newPoolFixture(t *testing.T) *poolFixture {
	t.Helper()
	s, p, mama := fixture(t)
	return &poolFixture{s: s, p: p, mama: mama, papa: newUser(t, s)}
}

func newUser(t *testing.T, s *Service) string {
	t.Helper()
	id, err := s.ResolveUser(context.Background(), domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func (f *poolFixture) treatment(t *testing.T, patient string, m medication) TreatmentResult {
	t.Helper()
	ctx := context.Background()
	start := f.s.now().In(time.UTC).AddDate(0, 0, -1).Format("2006-01-02")
	r, err := f.s.CreateTreatment(ctx, CreateTreatmentCommand{Mutation: mutation(patient), PatientID: patient, Name: m.name, StrengthLabel: m.strength, Form: m.form, Unit: m.unit, InitialStock: m.stock, StartsOn: start, Schedule: domain.Schedule{Timezone: m.zone, Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: m.slot, Quantity: m.quantity}}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.s.GenerateOccurrences(ctx, patient, r.TreatmentID, start); err != nil {
		t.Fatal(err)
	}
	return r
}

func (f *poolFixture) link(t *testing.T, patient, caregiver string, scopes ...Scope) string {
	t.Helper()
	ctx := context.Background()
	invitation, err := f.s.CreateInvitation(ctx, mutation(caregiver), scopes, nil)
	if err != nil {
		t.Fatal(err)
	}
	link, err := f.s.AcceptInvitation(ctx, mutation(patient), invitation.Token)
	if err != nil {
		t.Fatal(err)
	}
	return link.ID
}

// El cuidador propone y cada paciente acepta por sí mismo.
func (f *poolFixture) active(t *testing.T, a, b TreatmentResult) string {
	t.Helper()
	ctx := context.Background()
	caregiver := newUser(t, f.s)
	f.link(t, f.mama, caregiver, ScopeRead, ScopeInventory)
	f.link(t, f.papa, caregiver, ScopeRead, ScopeInventory)
	created, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(caregiver), AccountIDs: []string{a.AccountID, b.AccountID}})
	if err != nil {
		t.Fatal(err)
	}
	var decided PoolResult
	for _, patient := range []string{f.mama, f.papa} {
		if decided, err = f.s.DecideInventoryPool(ctx, PoolDecisionCommand{Mutation: mutation(patient), PoolID: created.PoolID, Decision: "accept"}); err != nil {
			t.Fatal(err)
		}
	}
	if decided.Status != "active" {
		t.Fatal(decided)
	}
	return created.PoolID
}

func (f *poolFixture) balance(t *testing.T, patient, account string) domain.Quantity {
	t.Helper()
	projection, err := f.s.GetInventoryProjection(context.Background(), patient, account, f.s.now())
	if err != nil {
		t.Fatal(err)
	}
	return projection.Balance
}

func (f *poolFixture) ledger(t *testing.T, account string) domain.Quantity {
	t.Helper()
	var value string
	if err := f.p.QueryRow(context.Background(), `SELECT COALESCE(sum(quantity_delta),0)::text FROM inventory_movements WHERE inventory_account_id=$1`, account).Scan(&value); err != nil {
		t.Fatal(err)
	}
	q, err := domain.ParseQuantity(value)
	if err != nil {
		t.Fatal(err)
	}
	return q
}

func (f *poolFixture) due(t *testing.T, tr TreatmentResult) string {
	t.Helper()
	var id string
	if err := f.p.QueryRow(context.Background(), `SELECT id::text FROM dose_occurrences WHERE treatment_id=$1 AND scheduled_at<=$2 AND status='pending' ORDER BY scheduled_at DESC LIMIT 1`, tr.TreatmentID, f.s.now()).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func (f *poolFixture) take(patient, dose string) (DoseResult, error) {
	return f.s.RecordDoseEvent(context.Background(), RecordDoseEventCommand{Mutation: mutation(patient), DoseID: dose, ExpectedVersion: 1, State: domain.Taken})
}

func denied(err error) bool { return errors.Is(err, ErrForbidden) || errors.Is(err, ErrNotFound) }

// 1. Dos pacientes declaran a la vez con el saldo justo: un consumo por dosis y saldo exacto.
func TestPoolRaceConsumesOncePerDoseWithExactBalance(t *testing.T) {
	f := newPoolFixture(t)
	m := standardMedication()
	m.stock = 500
	a, b := f.treatment(t, f.mama, m), f.treatment(t, f.papa, m)
	f.active(t, a, b)
	if got := f.balance(t, f.mama, a.AccountID); got != 1000 {
		t.Fatal("el saldo se suma al activar", got)
	}
	doseA, doseB := f.due(t, a), f.due(t, b)
	var wg sync.WaitGroup
	results := make([]DoseResult, 2)
	errs := make([]error, 2)
	wg.Add(2)
	go func() { defer wg.Done(); results[0], errs[0] = f.take(f.mama, doseA) }()
	go func() { defer wg.Done(); results[1], errs[1] = f.take(f.papa, doseB) }()
	wg.Wait()
	if errs[0] != nil || errs[1] != nil {
		t.Fatal(errs)
	}
	if got := f.balance(t, f.papa, b.AccountID); got != 0 {
		t.Fatal(got)
	}
	if results[0].Balance+results[1].Balance != 500 {
		t.Fatal("el saldo devuelto es el común y serializado", results)
	}
	for _, tr := range []TreatmentResult{a, b} {
		if n := countRows(t, f.p, `SELECT count(*) FROM inventory_movements WHERE treatment_id=$1 AND reason='consumption'`, tr.TreatmentID); n != 1 {
			t.Fatal(n)
		}
	}
}

// 2. Un reintento simultáneo repite la operación sin consumir dos veces.
func TestPoolRetriesAreIdempotent(t *testing.T) {
	f := newPoolFixture(t)
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	caregiver := newUser(t, f.s)
	f.link(t, f.mama, caregiver, ScopeRead, ScopeInventory)
	f.link(t, f.papa, caregiver, ScopeRead, ScopeInventory)
	create := CreatePoolCommand{Mutation: mutation(caregiver), AccountIDs: []string{a.AccountID, b.AccountID}}
	first, err := f.s.CreateInventoryPool(context.Background(), create)
	if err != nil {
		t.Fatal(err)
	}
	again, err := f.s.CreateInventoryPool(context.Background(), create)
	if err != nil || again.PoolID != first.PoolID {
		t.Fatal(again, err)
	}
	if _, err = f.s.DecideInventoryPool(context.Background(), PoolDecisionCommand{Mutation: mutation(f.mama), PoolID: first.PoolID, Decision: "accept"}); err != nil {
		t.Fatal(err)
	}
	decide := PoolDecisionCommand{Mutation: mutation(f.papa), PoolID: first.PoolID, Decision: "accept"}
	for range 2 {
		if decided, e := f.s.DecideInventoryPool(context.Background(), decide); e != nil || decided.Status != "active" {
			t.Fatal(decided, e)
		}
	}
	command := RecordDoseEventCommand{Mutation: mutation(f.mama), DoseID: f.due(t, a), ExpectedVersion: 1, State: domain.Taken}
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := f.s.RecordDoseEvent(context.Background(), command); e != nil {
				t.Error(e)
			}
		}()
	}
	wg.Wait()
	if got := f.balance(t, f.mama, a.AccountID); got != 19500 {
		t.Fatal(got)
	}
	leave := LeavePoolCommand{Mutation: mutation(f.papa), PoolID: first.PoolID, AccountID: b.AccountID}
	for range 2 {
		if _, e := f.s.LeaveInventoryPool(context.Background(), leave); e != nil {
			t.Fatal(e)
		}
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM inventory_movements WHERE inventory_account_id=$1 AND reason='pool_transfer'`, b.AccountID); n != 1 {
		t.Fatal(n)
	}
}

// 3. 0,5 + 0,25 descuenta exacto del saldo común.
func TestPoolKeepsExactDecimals(t *testing.T) {
	f := newPoolFixture(t)
	half, quarter := standardMedication(), standardMedication()
	half.stock, quarter.stock, quarter.quantity = 500, 500, 250
	a, b := f.treatment(t, f.mama, half), f.treatment(t, f.papa, quarter)
	f.active(t, a, b)
	if _, err := f.take(f.mama, f.due(t, a)); err != nil {
		t.Fatal(err)
	}
	last, err := f.take(f.papa, f.due(t, b))
	if err != nil || last.Balance != 250 || last.Balance.String() != "0.250" {
		t.Fatal(last, err)
	}
	if f.ledger(t, a.AccountID) != 0 || f.ledger(t, b.AccountID) != 250 {
		t.Fatal("cada consumo descuenta de su propia cuenta")
	}
}

// 4 y corrección tras salir: la reversa vuelve a la cuenta de la dosis.
func TestPoolCorrectionRestoresCommonBalanceAndOwnAccount(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	pool := f.active(t, a, b)
	id := f.due(t, a)
	taken, err := f.take(f.mama, id)
	if err != nil || taken.Balance != 19500 {
		t.Fatal(taken, err)
	}
	fixed, err := f.s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(f.mama), DoseID: id, ExpectedVersion: taken.Version, CorrectsEventID: taken.EventID, State: domain.Skipped, Reason: "Registro sintético"})
	if err != nil || fixed.Balance != 20000 {
		t.Fatal(fixed, err)
	}
	again, err := f.s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(f.mama), DoseID: id, ExpectedVersion: fixed.Version, CorrectsEventID: fixed.EventID, State: domain.Taken, Reason: "Registro sintético"})
	if err != nil || again.Balance != 19500 {
		t.Fatal(again, err)
	}
	if _, err = f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: pool, AccountID: a.AccountID}); err != nil {
		t.Fatal(err)
	}
	if f.ledger(t, a.AccountID) != 0 || f.ledger(t, b.AccountID) != 19500 {
		t.Fatal(f.ledger(t, a.AccountID), f.ledger(t, b.AccountID))
	}
	after, err := f.s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(f.mama), DoseID: id, ExpectedVersion: again.Version, CorrectsEventID: again.EventID, State: domain.Skipped, Reason: "Registro sintético"})
	if err != nil {
		t.Fatal(err)
	}
	if after.Balance != 500 || f.ledger(t, a.AccountID) != 500 || f.ledger(t, b.AccountID) != 19500 {
		t.Fatal("la reversa va a la cuenta de la dosis", after, f.ledger(t, b.AccountID))
	}
}

// 5. Dos zonas y la misma hora: declarar una dosis no oculta la del otro paciente.
func TestPoolProjectionCombinesZonesAndDistinguishesSameInstant(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	utc, santiago := standardMedication(), standardMedication()
	santiago.zone, santiago.slot, santiago.quantity = "America/Santiago", "09:00", 250
	a, b := f.treatment(t, f.mama, utc), f.treatment(t, f.papa, santiago)
	from := f.s.now().Add(-time.Hour)
	soloA, err := f.s.GetInventoryProjection(ctx, f.mama, a.AccountID, from)
	if err != nil {
		t.Fatal(err)
	}
	soloB, err := f.s.GetInventoryProjection(ctx, f.papa, b.AccountID, from)
	if err != nil {
		t.Fatal(err)
	}
	f.active(t, a, b)
	combined, err := f.s.GetInventoryProjection(ctx, f.mama, a.AccountID, from)
	if err != nil {
		t.Fatal(err)
	}
	if combined.ScheduledQuantity != soloA.ScheduledQuantity+soloB.ScheduledQuantity || combined.Balance != 20000 {
		t.Fatal(combined, soloA.ScheduledQuantity, soloB.ScheduledQuantity)
	}
	if _, err = f.take(f.mama, f.due(t, a)); err != nil {
		t.Fatal(err)
	}
	after, err := f.s.GetInventoryProjection(ctx, f.mama, a.AccountID, from)
	if err != nil {
		t.Fatal(err)
	}
	if after.ScheduledQuantity != combined.ScheduledQuantity-utc.quantity {
		t.Fatal("la exclusión debe usar tratamiento e instante", after.ScheduledQuantity, combined.ScheduledQuantity)
	}
}

// 6. El cambio de hora de America/Santiago no duplica ni pierde dosis combinadas.
func TestPoolProjectionAcrossSantiagoDST(t *testing.T) {
	f := newPoolFixture(t)
	f.s.now = func() time.Time { return time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC) }
	half, quarter := standardMedication(), standardMedication()
	half.zone, half.slot = "America/Santiago", "08:00"
	quarter.zone, quarter.slot, quarter.quantity = "America/Santiago", "08:00", 250
	a, b := f.treatment(t, f.mama, half), f.treatment(t, f.papa, quarter)
	f.active(t, a, b)
	projection, err := f.s.GetInventoryProjection(context.Background(), f.mama, a.AccountID, f.s.now())
	if err != nil {
		t.Fatal(err)
	}
	if projection.Through.Sub(time.Date(2026, 9, 2, 4, 0, 0, 0, time.UTC)) != 30*24*time.Hour-time.Hour {
		t.Fatal(projection.Through)
	}
	// Del 2 de septiembre, a la hora consultada, al 1 de octubre: 30 días locales.
	if projection.ScheduledQuantity != 30*750 {
		t.Fatal(projection.ScheduledQuantity)
	}
}

// 7. Un cuidador no acepta por el paciente; pendiente mantiene saldos separados; rechazar disuelve.
func TestPoolConsentIsPersonal(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	caregiver := newUser(t, f.s)
	all := []Scope{ScopeRead, ScopeInventory, ScopeDoses}
	f.link(t, f.mama, caregiver, all...)
	f.link(t, f.papa, caregiver, all...)
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	created, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(caregiver), AccountIDs: []string{a.AccountID, b.AccountID}})
	if err != nil || created.Status != "pending" {
		t.Fatal(created, err)
	}
	if _, err = f.s.DecideInventoryPool(ctx, PoolDecisionCommand{Mutation: mutation(caregiver), PoolID: created.PoolID, Decision: "accept"}); !denied(err) {
		t.Fatal("un cuidador no puede aceptar por el paciente", err)
	}
	if got := f.balance(t, f.mama, a.AccountID); got != 10000 {
		t.Fatal("pendiente mantiene saldos separados", got)
	}
	pending, err := f.s.PendingInventoryPools(ctx, f.mama)
	if err != nil || len(pending) != 1 || pending[0].PoolID != created.PoolID || pending[0].MedicationName != "Losartán" {
		t.Fatal(pending, err)
	}
	if none, e := f.s.PendingInventoryPools(ctx, caregiver); e != nil || len(none) != 0 {
		t.Fatal("el cuidador no recibe decisiones", none, e)
	}
	decided, err := f.s.DecideInventoryPool(ctx, PoolDecisionCommand{Mutation: mutation(f.mama), PoolID: created.PoolID, Decision: "accept"})
	if err != nil || decided.Status != "pending" {
		t.Fatal(decided, err)
	}
	if got := f.balance(t, f.mama, a.AccountID); got != 10000 {
		t.Fatal(got)
	}
	decided, err = f.s.DecideInventoryPool(ctx, PoolDecisionCommand{Mutation: mutation(f.papa), PoolID: created.PoolID, Decision: "decline"})
	if err != nil || decided.Status != "dissolved" {
		t.Fatal(decided, err)
	}
	// Disolver libera las cuentas para una propuesta nueva.
	if pool := f.active(t, a, b); pool == created.PoolID {
		t.Fatal(pool)
	}
	if got := f.balance(t, f.mama, a.AccountID); got != 20000 {
		t.Fatal(got)
	}
	var threshold int
	if err = f.p.QueryRow(ctx, `SELECT low_stock_days_threshold FROM inventory_pools p JOIN inventory_pool_members m ON m.pool_id=p.id WHERE m.account_id=$1 AND p.status='active'`, a.AccountID).Scan(&threshold); err != nil || threshold != 5 {
		t.Fatal(threshold, err)
	}
}

// Dos tratamientos del mismo paciente necesitan un único consentimiento.
func TestPoolSamePatientUsesSingleConsent(t *testing.T) {
	f := newPoolFixture(t)
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.mama, standardMedication())
	created, err := f.s.CreateInventoryPool(context.Background(), CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{a.AccountID, b.AccountID}})
	if err != nil || created.Status != "active" {
		t.Fatal(created, err)
	}
}

// 8. Sólo el mismo medicamento: sin coincidencia aproximada ni quitar acentos.
func TestPoolValidatesSameMedication(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	base := f.treatment(t, f.mama, standardMedication())
	strength, unit, accent, spacing := standardMedication(), standardMedication(), standardMedication(), standardMedication()
	strength.strength, unit.unit, accent.name = "100 mg", "capsule", "Losartan"
	spacing.name, spacing.strength, spacing.form = "  LOSARTÁN ", "50   MG", "Comprimido"
	for _, m := range []medication{strength, unit, accent} {
		other := f.treatment(t, f.papa, m)
		if _, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{base.AccountID, other.AccountID}}); !denied(err) {
			// La propuesta de otro paciente sin vínculo se deniega antes de comparar.
			t.Fatal(err)
		}
		own := f.treatment(t, f.mama, m)
		if _, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{base.AccountID, own.AccountID}}); !errors.Is(err, ErrInvalid) {
			t.Fatal(m.name, err)
		}
	}
	if _, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{base.AccountID, base.AccountID}}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	same := f.treatment(t, f.mama, spacing)
	candidates, err := f.s.PoolCandidates(ctx, f.mama, base.AccountID)
	if err != nil || len(candidates) != 1 || candidates[0].AccountID != same.AccountID {
		t.Fatal(candidates, err)
	}
	if _, err = f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{base.AccountID, same.AccountID}}); err != nil {
		t.Fatal(err)
	}
	third := f.treatment(t, f.mama, standardMedication())
	if _, err = f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{base.AccountID, third.AccountID}}); !errors.Is(err, ErrConflict) {
		t.Fatal("una cuenta sólo puede estar en un inventario vivo", err)
	}
}

// 9. La caja se queda con quienes permanecen, la suma se conserva y queda auditada.
func TestPoolLeaveTransfersAndDissolves(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	a, b, c := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.mama, standardMedication())
	created, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{a.AccountID, b.AccountID, c.AccountID}})
	if err != nil || created.Status != "active" {
		t.Fatal(created, err)
	}
	left, err := f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: created.PoolID, AccountID: a.AccountID})
	if err != nil || left.Status != "active" {
		t.Fatal(left, err)
	}
	if f.ledger(t, a.AccountID) != 0 || f.balance(t, f.mama, a.AccountID) != 0 {
		t.Fatal("quien sale queda en cero", f.ledger(t, a.AccountID))
	}
	if f.ledger(t, b.AccountID)+f.ledger(t, c.AccountID) != 30000 || f.balance(t, f.mama, b.AccountID) != 30000 {
		t.Fatal("la suma se conserva")
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM inventory_movements WHERE inventory_account_id=ANY($1::uuid[]) AND reason='pool_transfer'`, []string{a.AccountID, b.AccountID, c.AccountID}); n != 2 {
		t.Fatal(n)
	}
	left, err = f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: created.PoolID, AccountID: b.AccountID})
	if err != nil || left.Status != "dissolved" {
		t.Fatal(left, err)
	}
	remaining := f.balance(t, f.mama, c.AccountID)
	if remaining != 30000 || f.balance(t, f.mama, b.AccountID) != 0 {
		t.Fatal(remaining)
	}
	report, err := f.s.Reconcile(ctx)
	if err != nil || report.PoolMembershipMismatches != 0 {
		t.Fatal(report, err)
	}
}

// Salir con saldo cero no crea movimientos; y salir de un pendiente no traspasa.
func TestPoolLeaveSkipsEmptyAndPendingTransfers(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	empty, full := standardMedication(), standardMedication()
	empty.stock = 0
	a, b := f.treatment(t, f.mama, empty), f.treatment(t, f.papa, full)
	pool := f.active(t, a, b)
	if _, err := f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: pool, AccountID: a.AccountID}); err != nil {
		t.Fatal(err)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM inventory_movements WHERE treatment_id=$1 AND reason='pool_transfer'`, a.TreatmentID); n != 0 {
		t.Fatal(n)
	}
	caregiver := newUser(t, f.s)
	f.link(t, f.mama, caregiver, ScopeRead, ScopeInventory)
	f.link(t, f.papa, caregiver, ScopeRead, ScopeInventory)
	c, d := f.treatment(t, f.mama, full), f.treatment(t, f.papa, full)
	pending, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(caregiver), AccountIDs: []string{c.AccountID, d.AccountID}})
	if err != nil {
		t.Fatal(err)
	}
	left, err := f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(caregiver), PoolID: pending.PoolID, AccountID: c.AccountID})
	if err != nil || left.Status != "dissolved" || f.ledger(t, c.AccountID) != 10000 {
		t.Fatal(left, err)
	}
}

// 10. Sin acceso al otro paciente: cantidad y fecha, sin autor, hora, nota ni tratamiento.
func TestPoolPrivacyForPartialCaregiver(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	partial, both := newUser(t, f.s), newUser(t, f.s)
	f.link(t, f.mama, partial, ScopeRead)
	f.link(t, f.mama, both, ScopeRead)
	f.link(t, f.papa, both, ScopeRead)
	name := "Papá sintético"
	if _, err := f.s.UpdateProfile(ctx, UpdateProfileCommand{Mutation: mutation(f.papa), PatientID: f.papa, ExpectedVersion: 1, DisplayName: name}); err != nil {
		t.Fatal(err)
	}
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	start := f.s.now()
	f.s.now = func() time.Time { return start.Add(time.Hour) }
	f.active(t, a, b)
	f.s.now = func() time.Time { return start.Add(2 * time.Hour) }
	if _, err := f.s.RecordPhysicalCount(ctx, PhysicalCountCommand{Mutation: mutation(f.papa), AccountID: b.AccountID, CountedQuantity: 15250, ExpectedBalance: 20000, Reason: "Nota privada sintética"}); err != nil {
		t.Fatal(err)
	}
	rows, _, err := f.s.InventoryMovements(ctx, partial, a.AccountID, "")
	if err != nil {
		t.Fatal(err)
	}
	shared := 0
	for _, row := range rows {
		if !row.Shared {
			continue
		}
		shared++
		if row.Reason != "shared_activity" || row.Note != "" || row.ActorID != "" || row.PatientDisplayName != nil || !row.CreatedAt.Equal(row.CreatedAt.Truncate(24*time.Hour)) {
			t.Fatal("filtra datos del otro paciente", row)
		}
	}
	if shared != 1 {
		t.Fatal("sólo desde la activación", shared, rows)
	}
	views, _, err := f.s.Inventory(ctx, partial, f.mama, "")
	if err != nil || len(views) != 1 || views[0].Pool == nil || views[0].Projection.Balance != 15250 {
		t.Fatal(views, err)
	}
	hidden := 0
	for _, member := range views[0].Pool.Members {
		if member.PatientDisplayName != nil && *member.PatientDisplayName == name {
			t.Fatal("nombre sin acceso", member)
		}
		if member.PatientDisplayName != nil && *member.PatientDisplayName == UnknownPoolMember {
			hidden++
		}
	}
	if hidden != 1 {
		t.Fatal(views[0].Pool)
	}
	rows, _, err = f.s.InventoryMovements(ctx, both, a.AccountID, "")
	if err != nil {
		t.Fatal(err)
	}
	complete := false
	for _, row := range rows {
		if row.Shared && row.Reason == "manual_adjustment" && row.Note == "Nota privada sintética" && row.ActorID == f.papa && row.PatientDisplayName != nil && *row.PatientDisplayName == name {
			complete = true
		}
	}
	if !complete {
		t.Fatal("con acceso a ambos se ve completo", rows)
	}
	rows, _, err = f.s.InventoryMovements(ctx, f.mama, a.AccountID, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Shared && row.Reason != "shared_activity" {
			t.Fatal("otro paciente no ve el detalle ajeno", row)
		}
	}
	views, _, err = f.s.Inventory(ctx, f.mama, f.mama, "")
	if err != nil || views[0].Pool == nil {
		t.Fatal(views, err)
	}
	named := false
	for _, member := range views[0].Pool.Members {
		named = named || (member.PatientDisplayName != nil && *member.PatientDisplayName == name)
	}
	if !named {
		t.Fatal("quien comparte ve el nombre con quien aceptó compartir", views[0].Pool)
	}
	export, err := f.s.ExportAccount(ctx, f.mama)
	if err != nil {
		t.Fatal(err)
	}
	if len(export.InventoryMovements) != 1 {
		t.Fatal("la exportación incluye sólo movimientos propios", len(export.InventoryMovements))
	}
}

// 11. Conteo y consumo concurrentes: el conteo compara el saldo común bajo bloqueo.
func TestPoolCountRacesConsumption(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	f.active(t, a, b)
	dose := f.due(t, b)
	var wg sync.WaitGroup
	var countErr, doseErr error
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, countErr = f.s.RecordPhysicalCount(ctx, PhysicalCountCommand{Mutation: mutation(f.mama), AccountID: a.AccountID, CountedQuantity: 12000, ExpectedBalance: 20000, Reason: "Conteo sintético"})
	}()
	go func() { defer wg.Done(); _, doseErr = f.take(f.papa, dose) }()
	wg.Wait()
	if doseErr != nil {
		t.Fatal(doseErr)
	}
	got := f.balance(t, f.mama, a.AccountID)
	switch {
	case countErr == nil && got == 11500:
	case errors.Is(countErr, ErrConflict) && got == 19500:
	default:
		t.Fatal(countErr, got)
	}
	if got != f.ledger(t, a.AccountID)+f.ledger(t, b.AccountID) {
		t.Fatal("el saldo común es la suma del ledger")
	}
}

// 12. Crear, salir y declarar en carrera termina sin interbloqueo: un 40P01 sería 409 en una declaración.
func TestPoolNoDeadlockCreatingLeavingAndDeclaring(t *testing.T) {
	f := newPoolFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	m := standardMedication()
	a, b := f.treatment(t, f.mama, m), f.treatment(t, f.mama, m)
	doses := []string{}
	rows, err := f.p.Query(ctx, `SELECT id::text FROM dose_occurrences WHERE treatment_id=ANY($1::uuid[]) AND scheduled_at<=$2 AND status='pending'`, []string{a.TreatmentID, b.TreatmentID}, f.s.now())
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		doses = append(doses, id)
	}
	rows.Close()
	if len(doses) < 4 {
		t.Fatal(len(doses))
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for range 12 {
			created, e := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{a.AccountID, b.AccountID}})
			if e != nil {
				t.Error("crear", e)
				return
			}
			if _, e = f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: created.PoolID, AccountID: b.AccountID}); e != nil {
				t.Error("salir", e)
				return
			}
		}
	}()
	for _, id := range doses {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := f.s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: mutation(f.mama), DoseID: id, ExpectedVersion: 1, State: domain.Taken}); e != nil {
				t.Error("declarar", e)
			}
		}()
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := f.s.ReplenishInventory(ctx, ReplenishInventoryCommand{Mutation: mutation(f.mama), AccountID: a.AccountID, Quantity: 250}); e != nil {
				t.Error("reponer", e)
			}
		}()
	}
	wg.Wait()
	if ctx.Err() != nil {
		t.Fatal("la carrera no terminó", ctx.Err())
	}
	want := domain.Quantity(20000) + domain.Quantity(len(doses))*250 - domain.Quantity(len(doses))*m.quantity
	if got := f.ledger(t, a.AccountID) + f.ledger(t, b.AccountID); got != want {
		t.Fatal(got, want)
	}
}

// 13. Un ajeno recibe 403/404 en todas las rutas.
func TestPoolDeniesStrangers(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	stranger, reader := newUser(t, f.s), newUser(t, f.s)
	f.link(t, f.mama, reader, ScopeRead)
	f.link(t, f.papa, reader, ScopeRead)
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	if _, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(reader), AccountIDs: []string{a.AccountID, b.AccountID}}); !denied(err) {
		t.Fatal("sin alcance inventory", err)
	}
	if _, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{a.AccountID, b.AccountID}}); !denied(err) {
		t.Fatal("la cuenta del otro paciente exige alcance", err)
	}
	pool := f.active(t, a, b)
	for name, err := range map[string]error{
		"crear": func() error {
			_, e := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(stranger), AccountIDs: []string{a.AccountID, b.AccountID}})
			return e
		}(),
		"decidir": func() error {
			_, e := f.s.DecideInventoryPool(ctx, PoolDecisionCommand{Mutation: mutation(stranger), PoolID: pool, Decision: "decline"})
			return e
		}(),
		"salir": func() error {
			_, e := f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(stranger), PoolID: pool, AccountID: a.AccountID})
			return e
		}(),
		"lector": func() error {
			_, e := f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(reader), PoolID: pool, AccountID: a.AccountID})
			return e
		}(),
		"ajena": func() error {
			_, e := f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: pool, AccountID: b.AccountID})
			return e
		}(),
		"candidatos":  func() error { _, e := f.s.PoolCandidates(ctx, stranger, a.AccountID); return e }(),
		"lectura":     func() error { _, e := f.s.PoolCandidates(ctx, reader, a.AccountID); return e }(),
		"movimientos": func() error { _, _, e := f.s.InventoryMovements(ctx, stranger, a.AccountID, ""); return e }(),
		"umbral": func() error {
			_, e := f.s.SetStockThreshold(ctx, SetStockThresholdCommand{Mutation: mutation(stranger), AccountID: a.AccountID, ExpectedDays: 5, Days: 3})
			return e
		}(),
	} {
		if !denied(err) {
			t.Fatal(name, err)
		}
	}
	if pending, err := f.s.PendingInventoryPools(ctx, stranger); err != nil || len(pending) != 0 {
		t.Fatal(pending, err)
	}
}

// 14. Una alerta de stock por inventario y cuidador, también si sigue a un solo paciente.
func TestPoolStockAlertIsUniquePerPool(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	both, single := newUser(t, f.s), newUser(t, f.s)
	links := map[string][]string{both: {f.link(t, f.mama, both, ScopeRead), f.link(t, f.papa, both, ScopeRead)}, single: {f.link(t, f.papa, single, ScopeRead)}}
	for caregiver, ids := range links {
		id := domain.NewID()
		if _, err := f.s.RegisterDevice(ctx, caregiver, DeviceInput{ID: id, Platform: "fcm", Token: "synthetic-" + id, Permission: "granted"}); err != nil {
			t.Fatal(err)
		}
		for _, link := range ids {
			if _, err := f.s.SetAlertPreferences(ctx, caregiver, link, AlertPreferences{StockEnabled: true, MinIntervalMinutes: 15, Timezone: "UTC"}); err != nil {
				t.Fatal(err)
			}
		}
	}
	low := standardMedication()
	low.stock = 1000
	a, b := f.treatment(t, f.mama, low), f.treatment(t, f.papa, low)
	pool := f.active(t, a, b)
	t.Cleanup(func() {
		for _, ids := range links {
			for _, link := range ids {
				// Sin esto, el planificador global volvería a avisar en otras pruebas.
				if _, e := f.p.Exec(ctx, `UPDATE caregiver_alert_preferences SET stock_enabled=false WHERE link_id=$1`, link); e != nil {
					t.Error(e)
				}
				if _, e := f.p.Exec(ctx, `DELETE FROM notification_outbox WHERE link_id=$1`, link); e != nil {
					t.Error(e)
				}
			}
		}
	})
	for range 2 {
		if _, err := f.s.PlanAlerts(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM notification_outbox WHERE kind='low_stock' AND link_id=ANY($1::uuid[])`, links[both]); n != 1 {
		t.Fatal("una vez por inventario", n)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM notification_outbox WHERE kind='low_stock' AND link_id=ANY($1::uuid[])`, links[single]); n != 1 {
		t.Fatal("quien sigue a un solo paciente también recibe la alerta", n)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM inventory_pools WHERE id=$1 AND status='active'`, pool); n != 1 {
		t.Fatal(n)
	}
}

// Reposición en la cuenta que registra, conteo contra el saldo común y umbral común.
func TestPoolReplenishCountAndThresholdShareState(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	f.active(t, a, b)
	replenished, err := f.s.ReplenishInventory(ctx, ReplenishInventoryCommand{Mutation: mutation(f.mama), AccountID: a.AccountID, Quantity: 2500})
	if err != nil || replenished.Balance != 22500 || f.ledger(t, a.AccountID) != 12500 || f.ledger(t, b.AccountID) != 10000 {
		t.Fatal(replenished, err)
	}
	if _, err = f.s.RecordPhysicalCount(ctx, PhysicalCountCommand{Mutation: mutation(f.papa), AccountID: b.AccountID, CountedQuantity: 20000, ExpectedBalance: 12500, Reason: "Conteo sintético"}); !errors.Is(err, ErrConflict) {
		t.Fatal("el conteo compara el saldo común", err)
	}
	counted, err := f.s.RecordPhysicalCount(ctx, PhysicalCountCommand{Mutation: mutation(f.papa), AccountID: b.AccountID, CountedQuantity: 20000, ExpectedBalance: 22500, Reason: "Conteo sintético"})
	if err != nil || counted.Balance != 20000 || f.ledger(t, b.AccountID) != 7500 || f.ledger(t, a.AccountID) != 12500 {
		t.Fatal(counted, err)
	}
	if _, err = f.s.SetStockThreshold(ctx, SetStockThresholdCommand{Mutation: mutation(f.mama), AccountID: a.AccountID, ExpectedDays: 5, Days: 9}); err != nil {
		t.Fatal(err)
	}
	if projection, e := f.s.GetInventoryProjection(ctx, f.papa, b.AccountID, f.s.now()); e != nil || projection.LowStockDaysThreshold != 9 {
		t.Fatal(projection, e)
	}
}
