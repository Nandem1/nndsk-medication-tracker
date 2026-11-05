//go:build integration

package application

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// roleFor elige el rol más pequeño que cubre los alcances que una prueba necesita.
func roleFor(scopes []Scope) FamilyRole {
	switch {
	case slices.Contains(scopes, ScopeTreatments):
		return RoleAdmin
	case slices.Contains(scopes, ScopeDoses), slices.Contains(scopes, ScopeInventory):
		return RoleCaregiver
	}
	return RoleObserver
}

// grant vincula a caregiver con patient por el flujo real de familia y devuelve familia y vínculo.
// Quien cuida crea la familia e invita al paciente; un rol distinto de admin se aplica después,
// como si otra persona administrara la familia.
func grant(t *testing.T, s *Service, caregiver, patient string, role FamilyRole) (string, string) {
	t.Helper()
	ctx := context.Background()
	family, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(caregiver), Name: "Familia sintética"})
	if err != nil {
		t.Fatal(err)
	}
	join(t, s, caregiver, patient, family.ID, RolePatient)
	if role != RoleAdmin {
		setRole(t, s, family.ID, caregiver, role)
	}
	return family.ID, linkID(t, s.pool, patient, caregiver)
}

// setRole cambia un rol directamente: el producto no lo ofrece, pero las pruebas lo necesitan
// para cubrir cada combinación de alcances con una sola familia.
func setRole(t *testing.T, s *Service, family, user string, role FamilyRole) {
	t.Helper()
	ctx := context.Background()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `UPDATE family_members SET role=$3 WHERE family_id=$1 AND user_id=$2`, family, user, role); err != nil {
		t.Fatal(err)
	}
	if err = syncLinks(ctx, tx, user, user, nil, s.now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
}

func join(t *testing.T, s *Service, admin, member, family string, role FamilyRole) {
	t.Helper()
	ctx := context.Background()
	invitation, err := s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(admin), FamilyID: family, Role: role})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptFamilyInvitation(ctx, AcceptFamilyInvitationCommand{Mutation: mutation(member), Token: invitation.Token}); err != nil {
		t.Fatal(err)
	}
}

func linkID(t *testing.T, p *pgxpool.Pool, patient, caregiver string) string {
	t.Helper()
	var id string
	if err := p.QueryRow(context.Background(), `SELECT id::text FROM caregiver_links WHERE patient_user_id=$1 AND caregiver_user_id=$2 AND status='active'`, patient, caregiver).Scan(&id); err != nil {
		t.Fatal("active link expected", err)
	}
	return id
}

func scopesOf(t *testing.T, p *pgxpool.Pool, patient, caregiver string) []string {
	t.Helper()
	var scopes []string
	err := p.QueryRow(context.Background(), `SELECT scopes FROM caregiver_links WHERE patient_user_id=$1 AND caregiver_user_id=$2 AND status='active'`, patient, caregiver).Scan(&scopes)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		t.Fatal(err)
	}
	slices.Sort(scopes)
	return scopes
}

func allowed(s *Service, actor, patient string, scope Scope) error {
	ctx := context.Background()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	return authorize(ctx, tx, actor, patientTarget(patient), scope)
}

// Una familia con dos pacientes y tres cuidadores: cada quien se une una vez.
func TestFamilyMembershipDerivesLinksForEveryPair(t *testing.T) {
	s, p, admin := fixture(t)
	ctx := context.Background()
	mama, papa, hermana, lectora := newUser(t, s), newUser(t, s), newUser(t, s), newUser(t, s)
	family, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(admin), Name: " Familia Vicente "})
	if err != nil || family.Name != "Familia Vicente" || family.Role != RoleAdmin {
		t.Fatal(family, err)
	}
	join(t, s, admin, mama, family.ID, RolePatient)
	join(t, s, admin, hermana, family.ID, RoleCaregiver)
	join(t, s, admin, papa, family.ID, RolePatient)
	join(t, s, admin, lectora, family.ID, RoleObserver)

	all := []string{"doses", "inventory", "read", "treatments"}
	for _, patient := range []string{mama, papa} {
		if got := scopesOf(t, p, patient, admin); !slices.Equal(got, all) {
			t.Fatal("admin scopes", got)
		}
		if got := scopesOf(t, p, patient, hermana); !slices.Equal(got, []string{"doses", "inventory", "read"}) {
			t.Fatal("caregiver scopes", got)
		}
		if got := scopesOf(t, p, patient, lectora); !slices.Equal(got, []string{"read"}) {
			t.Fatal("observer scopes", got)
		}
	}
	// Un paciente no ve a otro paciente de su familia.
	if err = allowed(s, mama, papa, ScopeRead); !errors.Is(err, ErrNotFound) {
		t.Fatal("patient reads another patient", err)
	}
	if err = allowed(s, lectora, mama, ScopeDoses); !errors.Is(err, ErrNotFound) {
		t.Fatal("observer records", err)
	}
	if err = allowed(s, hermana, papa, ScopeInventory); err != nil {
		t.Fatal(err)
	}
	families, err := s.Families(ctx, mama)
	if err != nil || len(families) != 1 || len(families[0].Members) != 5 || families[0].Role != RolePatient {
		t.Fatal(families, err)
	}
	var you int
	for _, m := range families[0].Members {
		if m.You {
			you++
		}
	}
	if you != 1 {
		t.Fatal("you marker", you)
	}
}

func TestOnlyAdminsInviteAndInvitationsAreSingleUse(t *testing.T) {
	s, _, admin := fixture(t)
	ctx := context.Background()
	patient, caregiver, stranger := newUser(t, s), newUser(t, s), newUser(t, s)
	family, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(admin), Name: "Familia"})
	if err != nil {
		t.Fatal(err)
	}
	join(t, s, admin, caregiver, family.ID, RoleCaregiver)
	if _, err = s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(caregiver), FamilyID: family.ID, Role: RolePatient}); !errors.Is(err, ErrForbidden) {
		t.Fatal("caregiver invited", err)
	}
	if _, err = s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(stranger), FamilyID: family.ID, Role: RolePatient}); !errors.Is(err, ErrNotFound) {
		t.Fatal("stranger invited", err)
	}
	hint := "Mamá"
	if _, err = s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(admin), FamilyID: family.ID, Role: RoleCaregiver, PatientNameHint: &hint}); !errors.Is(err, ErrInvalid) {
		t.Fatal("hint for a caregiver", err)
	}
	invitation, err := s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(admin), FamilyID: family.ID, Role: RolePatient, PatientNameHint: &hint})
	if err != nil || !invitation.ExpiresAt.Equal(s.now().UTC().Add(familyInvitationTTL)) {
		t.Fatal(invitation, err)
	}
	preview, err := s.PreviewFamilyInvitation(ctx, patient, invitation.Token)
	if err != nil || preview.FamilyName != "Familia" || preview.Role != RolePatient || len(preview.Members) != 2 || *preview.PatientNameHint != "Mamá" {
		t.Fatal(preview, err)
	}
	accept := AcceptFamilyInvitationCommand{Mutation: mutation(patient), Token: invitation.Token}
	first, err := s.AcceptFamilyInvitation(ctx, accept)
	if err != nil || first.Role != RolePatient {
		t.Fatal(first, err)
	}
	// El mismo reintento devuelve el mismo resultado; otra persona no puede reutilizarla.
	if replay, err := s.AcceptFamilyInvitation(ctx, accept); err != nil || replay.ID != first.ID || len(replay.Members) != 3 {
		t.Fatal(replay, err)
	}
	if _, err = s.AcceptFamilyInvitation(ctx, AcceptFamilyInvitationCommand{Mutation: mutation(stranger), Token: invitation.Token}); !errors.Is(err, ErrConflict) {
		t.Fatal("reused invitation", err)
	}
	if _, err = s.PreviewFamilyInvitation(ctx, stranger, invitation.Token); !errors.Is(err, ErrNotFound) {
		t.Fatal("consumed preview", err)
	}
	var name string
	if err = s.pool.QueryRow(ctx, `SELECT display_name FROM users WHERE id=$1`, patient).Scan(&name); err != nil || name != "Mamá" {
		t.Fatal("hint applied", name, err)
	}
	// Quien ya es miembro no puede aceptar otra invitación de la misma familia.
	again, err := s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(admin), FamilyID: family.ID, Role: RoleObserver})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptFamilyInvitation(ctx, AcceptFamilyInvitationCommand{Mutation: mutation(patient), Token: again.Token}); !errors.Is(err, ErrConflict) {
		t.Fatal("double membership", err)
	}
}

func TestExpiredFamilyInvitationIsRejected(t *testing.T) {
	_, pool, admin := fixture(t)
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	s := New(pool, func() time.Time { return now })
	ctx := context.Background()
	family, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(admin), Name: "Familia"})
	if err != nil {
		t.Fatal(err)
	}
	invitation, err := s.InviteToFamily(ctx, InviteToFamilyCommand{Mutation: mutation(admin), FamilyID: family.ID, Role: RolePatient})
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(familyInvitationTTL)
	if _, err = s.AcceptFamilyInvitation(ctx, AcceptFamilyInvitationCommand{Mutation: mutation(newUser(t, s)), Token: invitation.Token}); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
}

func TestLeavingAndRemovingRevokeAndPromoteTheOldestCaregiver(t *testing.T) {
	s, p, admin := fixture(t)
	ctx := context.Background()
	patient, first, second := newUser(t, s), newUser(t, s), newUser(t, s)
	family, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(admin), Name: "Familia"})
	if err != nil {
		t.Fatal(err)
	}
	join(t, s, admin, patient, family.ID, RolePatient)
	join(t, s, admin, first, family.ID, RoleCaregiver)
	join(t, s, admin, second, family.ID, RoleObserver)
	if err = s.RemoveFamilyMember(ctx, first, family.ID, second); !errors.Is(err, ErrForbidden) {
		t.Fatal("caregiver removed someone", err)
	}
	if err = s.RemoveFamilyMember(ctx, admin, family.ID, admin); err != nil {
		t.Fatal(err)
	}
	if got := scopesOf(t, p, patient, admin); got != nil {
		t.Fatal("admin kept access", got)
	}
	if got := scopesOf(t, p, patient, first); len(got) != 4 {
		t.Fatal("oldest caregiver not promoted", got)
	}
	if err = s.RemoveFamilyMember(ctx, first, family.ID, second); err != nil {
		t.Fatal(err)
	}
	if got := scopesOf(t, p, patient, second); got != nil {
		t.Fatal("removed member kept access", got)
	}
	// Al salir el paciente, nadie de la familia conserva acceso.
	if err = s.RemoveFamilyMember(ctx, patient, family.ID, patient); err != nil {
		t.Fatal(err)
	}
	if got := scopesOf(t, p, patient, first); got != nil {
		t.Fatal("patient left but access remains", got)
	}
	if err = s.RemoveFamilyMember(ctx, patient, family.ID, patient); !errors.Is(err, ErrNotFound) {
		t.Fatal("leaving twice", err)
	}
	var events int
	if err = p.QueryRow(ctx, `SELECT count(*) FROM caregiver_link_events e JOIN caregiver_links l ON l.id=e.link_id WHERE l.patient_user_id=$1 AND e.action='revoked'`, patient).Scan(&events); err != nil || events != 3 {
		t.Fatal("audited revocations", events, err)
	}
}

func TestTwoFamiliesUniteScopesAndStayIsolated(t *testing.T) {
	s, p, caregiver := fixture(t)
	ctx := context.Background()
	patient, otherAdmin, outsider := newUser(t, s), newUser(t, s), newUser(t, s)
	first, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(otherAdmin), Name: "Una"})
	if err != nil {
		t.Fatal(err)
	}
	join(t, s, otherAdmin, patient, first.ID, RolePatient)
	join(t, s, otherAdmin, caregiver, first.ID, RoleObserver)
	second, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(otherAdmin), Name: "Otra"})
	if err != nil {
		t.Fatal(err)
	}
	join(t, s, otherAdmin, patient, second.ID, RolePatient)
	join(t, s, otherAdmin, caregiver, second.ID, RoleCaregiver)
	if got := scopesOf(t, p, patient, caregiver); !slices.Equal(got, []string{"doses", "inventory", "read"}) {
		t.Fatal(got)
	}
	if err = s.RemoveFamilyMember(ctx, caregiver, second.ID, caregiver); err != nil {
		t.Fatal(err)
	}
	if got := scopesOf(t, p, patient, caregiver); !slices.Equal(got, []string{"read"}) {
		t.Fatal("scopes after leaving one family", got)
	}
	// Una familia ajena no existe para quien no es miembro.
	if err = s.RemoveFamilyMember(ctx, outsider, first.ID, patient); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if families, err := s.Families(ctx, outsider); err != nil || len(families) != 0 {
		t.Fatal(families, err)
	}
}

// Quitar a alguien espera a las operaciones ya autorizadas, como lo hacía revocar un vínculo.
func TestRemovalWaitsForAuthorizedTransaction(t *testing.T) {
	s, pool, patient := fixture(t)
	ctx := context.Background()
	caregiver := newUser(t, s)
	family, _ := grant(t, s, caregiver, patient, RoleCaregiver)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, caregiver, patientTarget(patient), ScopeDoses); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- s.RemoveFamilyMember(ctx, patient, family, patient) }()
	select {
	case err = <-done:
		t.Fatal("removal did not wait for authorized transaction", err)
	case <-time.After(50 * time.Millisecond):
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("removal blocked")
	}
	if err = allowed(s, caregiver, patient, ScopeRead); !errors.Is(err, ErrNotFound) {
		t.Fatal("access after removal", err)
	}
}

func TestFamilyCreationIsIdempotent(t *testing.T) {
	s, _, admin := fixture(t)
	ctx := context.Background()
	m := mutation(admin)
	first, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: m, Name: "Familia"})
	if err != nil {
		t.Fatal(err)
	}
	replay, err := s.CreateFamily(ctx, CreateFamilyCommand{Mutation: m, Name: "Familia"})
	if err != nil || replay.ID != first.ID {
		t.Fatal(replay, err)
	}
	if _, err = s.CreateFamily(ctx, CreateFamilyCommand{Mutation: m, Name: "Otra"}); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	if _, err = s.CreateFamily(ctx, CreateFamilyCommand{Mutation: mutation(admin), Name: " "}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	families, err := s.Families(ctx, admin)
	if err != nil || len(families) != 1 {
		t.Fatal(families, err)
	}
}
