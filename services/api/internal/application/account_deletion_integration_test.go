//go:build integration

package application

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"medication-tracker/services/api/internal/domain"
)

func deleteCommand(actor string) DeleteAccountCommand {
	return DeleteAccountCommand{Mutation: mutation(actor), Confirm: "BORRAR"}
}

func (f *poolFixture) patientRows(t *testing.T, patient string) int {
	t.Helper()
	return countRows(t, f.p, `SELECT (SELECT count(*) FROM treatments WHERE patient_user_id=$1)+(SELECT count(*) FROM medications WHERE patient_user_id=$1)+(SELECT count(*) FROM inventory_accounts WHERE patient_user_id=$1)+(SELECT count(*) FROM caregiver_links WHERE patient_user_id=$1)+(SELECT count(*) FROM patients WHERE user_id=$1)+(SELECT count(*) FROM operations WHERE actor_user_id=$1)+(SELECT count(*) FROM device_registrations WHERE user_id=$1)+(SELECT count(*) FROM user_profile_changes WHERE user_id=$1)+(SELECT count(*) FROM inventory_pool_members WHERE patient_user_id=$1)`, patient)
}

func TestDeleteAccountRequiresExplicitConfirmation(t *testing.T) {
	f := newPoolFixture(t)
	f.treatment(t, f.mama, standardMedication())
	for _, confirm := range []string{"", "borrar", "SI"} {
		if err := f.s.DeleteAccount(context.Background(), DeleteAccountCommand{Mutation: mutation(f.mama), Confirm: confirm}); !errors.Is(err, ErrInvalid) {
			t.Fatal(confirm, err)
		}
	}
	if f.patientRows(t, f.mama) == 0 {
		t.Fatal("no debe borrar sin confirmación")
	}
}

// La caja se queda con quien permanece, y la historia del otro paciente no cambia.
func TestDeleteAccountLeavesPoolsAndKeepsOtherPatientsHistory(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	before, err := f.s.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	caregiver := newUser(t, f.s)
	f.link(t, f.mama, caregiver, ScopeRead, ScopeDoses, ScopeInventory)
	f.link(t, f.papa, caregiver, ScopeRead, ScopeDoses, ScopeInventory)
	if _, err = f.s.UpdateProfile(ctx, UpdateProfileCommand{Mutation: mutation(f.mama), PatientID: f.mama, ExpectedVersion: 1, DisplayName: "Mamá sintética"}); err != nil {
		t.Fatal(err)
	}
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication())
	pool := f.active(t, a, b)
	own := f.due(t, a)
	taken, err := f.take(f.mama, own)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.s.CorrectDoseEvent(ctx, CorrectDoseEventCommand{Mutation: mutation(f.mama), DoseID: own, ExpectedVersion: taken.Version, CorrectsEventID: taken.EventID, State: domain.Skipped, Reason: "Registro sintético"}); err != nil {
		t.Fatal(err)
	}
	// El cuidador declara por Mamá: su operación guarda la dosis y debe desaparecer con ella.
	other := f.due(t, a)
	byCaregiver := mutation(caregiver)
	if _, err = f.s.RecordDoseEvent(ctx, RecordDoseEventCommand{Mutation: byCaregiver, DoseID: other, ExpectedVersion: 1, State: domain.Taken}); err != nil {
		t.Fatal(err)
	}
	// Mamá también es autora en la historia de Papá.
	f.link(t, f.papa, f.mama, ScopeRead, ScopeDoses)
	authored, err := f.take(f.mama, f.due(t, b))
	if err != nil {
		t.Fatal(err)
	}
	id := domain.NewID()
	if _, err = f.s.RegisterDevice(ctx, f.mama, DeviceInput{ID: id, Platform: "fcm", Token: "synthetic-" + id, Permission: "granted"}); err != nil {
		t.Fatal(err)
	}
	common := f.balance(t, f.papa, b.AccountID)
	papaEvents := countRows(t, f.p, `SELECT count(*) FROM dose_events WHERE treatment_id=$1`, b.TreatmentID)

	if err = f.s.DeleteAccount(ctx, deleteCommand(f.mama)); err != nil {
		t.Fatal(err)
	}

	if n := f.patientRows(t, f.mama); n != 0 {
		t.Fatal("queda historia propia", n)
	}
	for _, table := range []string{"dose_occurrences", "dose_events", "inventory_movements", "schedule_revisions", "treatment_changes"} {
		if n := countRows(t, f.p, `SELECT count(*) FROM `+table+` WHERE treatment_id=$1`, a.TreatmentID); n != 0 {
			t.Fatal(table, n)
		}
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM operations WHERE actor_user_id=$1 AND client_operation_id=$2`, caregiver, byCaregiver.OperationID); n != 0 {
		t.Fatal("la operación del cuidador conserva datos de la dosis borrada")
	}
	if got := f.balance(t, f.papa, b.AccountID); got != common {
		t.Fatal("la caja se queda con quien permanece", got, common)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM dose_events WHERE treatment_id=$1`, b.TreatmentID); n != papaEvents {
		t.Fatal("cambió la historia de otro paciente", n)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM dose_events WHERE id=$1 AND actor_user_id=$2`, authored.EventID, f.mama); n != 1 {
		t.Fatal("se perdió el autor")
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM inventory_pools WHERE id=$1 AND status='dissolved'`, pool); n != 1 {
		t.Fatal("una cuenta restante disuelve el inventario")
	}
	var name, uid string
	if err = f.p.QueryRow(ctx, `SELECT display_name,auth_provider_uid FROM users WHERE id=$1`, f.mama).Scan(&name, &uid); err != nil {
		t.Fatal(err)
	}
	if name != DeletedAccountName || uid == "" {
		t.Fatal("autor sin anonimizar", name)
	}
	if links := countRows(t, f.p, `SELECT count(*) FROM caregiver_links WHERE caregiver_user_id=$1 AND status='active'`, f.mama); links != 0 {
		t.Fatal("sigue como cuidador", links)
	}
	if !denied(func() error { _, _, e := f.s.Inventory(ctx, caregiver, f.mama, ""); return e }()) {
		t.Fatal("el cuidador sigue viendo a la persona borrada")
	}
	after, err := f.s.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.DoseStateMismatches != before.DoseStateMismatches || after.ConsumptionMismatches != before.ConsumptionMismatches || after.LedgerMismatches != before.LedgerMismatches || after.AgendaMismatches != before.AgendaMismatches || after.PoolMembershipMismatches != before.PoolMembershipMismatches {
		t.Fatal("el ledger debe reconciliar", before, after)
	}
}

// Sin autoría en historia ajena, no queda fila de usuario. Un reintento vuelve a funcionar.
func TestDeleteAccountRemovesUserWithoutForeignAuthorshipAndCanRetry(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	f.treatment(t, f.mama, standardMedication())
	if err := f.s.DeleteAccount(ctx, deleteCommand(f.mama)); err != nil {
		t.Fatal(err)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM users WHERE id=$1`, f.mama); n != 0 {
		t.Fatal("el usuario sin autoría debe desaparecer", n)
	}
	// Un reintento con la misma identidad resuelve un usuario nuevo y vacío.
	fresh := newUser(t, f.s)
	for range 2 {
		if err := f.s.DeleteAccount(ctx, deleteCommand(fresh)); err != nil {
			t.Fatal(err)
		}
	}
}

// Un cuidador que se va deja intacta la historia del paciente y queda como autor anónimo.
func TestDeleteCaregiverKeepsPatientHistoryAndRevokesLinks(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	caregiver := newUser(t, f.s)
	link := f.link(t, f.mama, caregiver, ScopeRead, ScopeDoses, ScopeInventory)
	a := f.treatment(t, f.mama, standardMedication())
	dose := f.due(t, a)
	result, err := f.take(caregiver, dose)
	if err != nil {
		t.Fatal(err)
	}
	own, err := f.s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(caregiver), Name: "Otra familia"})
	if err != nil {
		t.Fatal(err)
	}
	unused, err := f.s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(caregiver), FamilyID: own.ID, Role: RolePatient})
	if err != nil {
		t.Fatal(err)
	}
	if err = f.s.DeleteAccount(ctx, deleteCommand(caregiver)); err != nil {
		t.Fatal(err)
	}
	if got := f.balance(t, f.mama, a.AccountID); got != 9500 {
		t.Fatal(got)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM dose_events WHERE id=$1`, result.EventID); n != 1 {
		t.Fatal("la declaración del paciente no se borra")
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM caregiver_links WHERE id=$1 AND status='revoked'`, link); n != 1 {
		t.Fatal("el vínculo se revoca, no se borra")
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM caregiver_link_events WHERE link_id=$1 AND action='revoked'`, link); n != 1 {
		t.Fatal("la revocación queda auditada")
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM invitations WHERE inviter_user_id=$1 AND consumed_at IS NULL`, caregiver); n != 0 {
		t.Fatal("una invitación sin usar no debe sobrevivir", unused.Token == "")
	}
}

// La historia sigue siendo append-only fuera del borrado de cuenta.
func TestHistoryStaysAppendOnlyOutsideAccountDeletion(t *testing.T) {
	f := newPoolFixture(t)
	a := f.treatment(t, f.mama, standardMedication())
	if _, err := f.p.Exec(context.Background(), `DELETE FROM inventory_movements WHERE treatment_id=$1`, a.TreatmentID); err == nil {
		t.Fatal("un borrado fuera de la transacción de cuenta debe fallar")
	}
}

// Una petición entre el borrado y la baja del acceso no deja el identificador guardado.
func TestForgetIdentityRemovesRecreatedRow(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	uid := domain.NewID()
	if _, err := f.s.ResolveUser(ctx, uid); err != nil {
		t.Fatal(err)
	}
	if err := f.s.ForgetIdentity(ctx, uid); err != nil {
		t.Fatal(err)
	}
	if n := countRows(t, f.p, `SELECT count(*) FROM users WHERE auth_provider_uid=$1`, uid); n != 0 {
		t.Fatal(n)
	}
}

// Las respuestas guardadas para reintentos no pueden conservar datos de la persona eliminada.
func TestDeleteAccountRemovesThirdPartyReplayData(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	caregiver, leaving := newUser(t, f.s), newUser(t, f.s)
	f.link(t, f.mama, caregiver, ScopeRead, ScopeTreatments, ScopeInventory)
	a := f.treatment(t, f.mama, standardMedication())
	rename, count := mutation(caregiver), mutation(caregiver)
	if _, err := f.s.UpdateProfile(ctx, UpdateProfileCommand{Mutation: rename, PatientID: f.mama, ExpectedVersion: 1, DisplayName: "Nombre de la persona borrada"}); err != nil {
		t.Fatal(err)
	}
	// Un conteo sin diferencia no deja movimiento, sólo la operación y su registro.
	if _, err := f.s.RecordPhysicalCount(ctx, PhysicalCountCommand{Mutation: count, AccountID: a.AccountID, CountedQuantity: 10000, ExpectedBalance: 10000, Reason: "Conteo sintético"}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.UpdateProfile(ctx, UpdateProfileCommand{Mutation: mutation(leaving), PatientID: leaving, ExpectedVersion: 1, DisplayName: "Cuidador que se va"}); err != nil {
		t.Fatal(err)
	}
	family, err := f.s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(leaving), Name: "Familia"})
	if err != nil {
		t.Fatal(err)
	}
	invitation, err := f.s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(leaving), FamilyID: family.ID, Role: RolePatient})
	if err != nil {
		t.Fatal(err)
	}
	accept := mutation(f.papa)
	if _, err = f.s.AcceptFamilyInvitation(ctx, AcceptFamilyInvitationCommand{Mutation: accept, Token: invitation.Token}); err != nil {
		t.Fatal(err)
	}
	for _, person := range []string{f.mama, leaving} {
		if err = f.s.DeleteAccount(ctx, deleteCommand(person)); err != nil {
			t.Fatal(err)
		}
	}
	// La aceptación de Papá no guarda datos de quien se fue: un reintento lee la familia actual.
	for name, m := range map[string]Mutation{"cambio de nombre": rename, "conteo": count} {
		if n := countRows(t, f.p, `SELECT count(*) FROM operations WHERE actor_user_id=$1 AND client_operation_id=$2`, m.ActorID, m.OperationID); n != 0 {
			t.Fatal("queda replay con datos de la cuenta borrada:", name)
		}
	}
}

// Una declaración que coincide con el borrado termina limpia: nunca un conflicto espurio.
func TestDeleteAccountRacingDeclarationsDoNotDeadlock(t *testing.T) {
	for range 5 {
		f := newPoolFixture(t)
		ctx := context.Background()
		caregiver := newUser(t, f.s)
		f.link(t, f.mama, caregiver, ScopeRead, ScopeDoses)
		a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.mama, standardMedication())
		doses := []string{f.due(t, a), f.due(t, b)}
		var wg sync.WaitGroup
		errs := make(chan error, len(doses)+1)
		for _, id := range doses {
			wg.Add(1)
			go func() { defer wg.Done(); _, e := f.take(caregiver, id); errs <- e }()
		}
		wg.Add(1)
		go func() { defer wg.Done(); errs <- f.s.DeleteAccount(ctx, deleteCommand(f.mama)) }()
		wg.Wait()
		close(errs)
		for e := range errs {
			if e != nil && !denied(e) {
				t.Fatal("la carrera debe terminar en éxito o sin acceso", e)
			}
		}
		if n := f.patientRows(t, f.mama); n != 0 {
			t.Fatal(n)
		}
	}
}

// Un identificador en mayúsculas sigue siendo la misma cuenta al traspasar.
func TestLeavePoolTreatsAccountIDCaseInsensitively(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	a, b := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.mama, standardMedication())
	created, err := f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{strings.ToUpper(a.AccountID), b.AccountID}, CountedAccountID: b.AccountID, CountedQuantity: 20000})
	if err != nil || created.Status != "active" {
		t.Fatal(created, err)
	}
	for _, account := range []string{a.AccountID, b.AccountID} {
		if _, err = f.s.CreateInventoryPool(ctx, CreatePoolCommand{Mutation: mutation(f.mama), AccountIDs: []string{strings.ToUpper(account), account}, CountedAccountID: account, CountedQuantity: 0}); !errors.Is(err, ErrInvalid) {
			t.Fatal("una cuenta repetida en otra capitalización", err)
		}
	}
	first := a.AccountID
	if b.AccountID < first {
		first = b.AccountID
	}
	if _, err = f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: created.PoolID, AccountID: strings.ToUpper(first)}); err != nil {
		t.Fatal(err)
	}
	if got := f.ledger(t, first); got != 0 {
		t.Fatal("quien sale queda en cero", got)
	}
}

// Quien salió ya no tiene motivo para ver nombres de un inventario posterior.
func TestPoolViewIgnoresPastMembershipForNames(t *testing.T) {
	f := newPoolFixture(t)
	ctx := context.Background()
	caregiver := newUser(t, f.s)
	third := newUser(t, f.s)
	for _, patient := range []string{f.mama, f.papa, third} {
		f.link(t, patient, caregiver, ScopeRead, ScopeInventory)
	}
	name := "Nombre privado"
	if _, err := f.s.UpdateProfile(ctx, UpdateProfileCommand{Mutation: mutation(f.papa), PatientID: f.papa, ExpectedVersion: 1, DisplayName: name}); err != nil {
		t.Fatal(err)
	}
	a, b, c := f.treatment(t, f.mama, standardMedication()), f.treatment(t, f.papa, standardMedication()), f.treatment(t, third, standardMedication())
	created, err := f.share(t, caregiver, a.AccountID, b.AccountID, c.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	// Mamá sale y Papá sigue: el inventario continúa sin ella.
	if _, err = f.s.LeaveInventoryPool(ctx, LeavePoolCommand{Mutation: mutation(f.mama), PoolID: created.PoolID, AccountID: a.AccountID}); err != nil {
		t.Fatal(err)
	}
	f.link(t, third, f.mama, ScopeRead)
	views, _, err := f.s.Inventory(ctx, f.mama, third, "")
	if err != nil || len(views) != 1 || views[0].Pool == nil {
		t.Fatal(views, err)
	}
	for _, member := range views[0].Pool.Members {
		if member.PatientDisplayName != nil && *member.PatientDisplayName == name {
			t.Fatal("salir no da acceso al nombre", member)
		}
	}
}
