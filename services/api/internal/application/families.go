package application

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

type FamilyRole string

const (
	RoleAdmin     FamilyRole = "admin"
	RoleCaregiver FamilyRole = "caregiver"
	RoleObserver  FamilyRole = "observer"
	RolePatient   FamilyRole = "patient"
)

// familyInvitationTTL deja tiempo para configurar en persona el teléfono de un adulto mayor.
const familyInvitationTTL = 7 * 24 * time.Hour

// roleScopes es lo que un rol puede hacer con cada paciente de la familia.
func roleScopes(role FamilyRole) []Scope {
	switch role {
	case RoleAdmin:
		return []Scope{ScopeRead, ScopeTreatments, ScopeDoses, ScopeInventory}
	case RoleCaregiver:
		return []Scope{ScopeRead, ScopeDoses, ScopeInventory}
	case RoleObserver, RolePatient:
		return []Scope{ScopeRead}
	}
	return nil
}

func validRole(role FamilyRole) bool { return roleScopes(role) != nil }

type FamilyMember struct {
	UserID      string     `json:"user_id"`
	DisplayName *string    `json:"display_name"`
	Role        FamilyRole `json:"role"`
	JoinedAt    time.Time  `json:"joined_at"`
	You         bool       `json:"you"`
}
type Family struct {
	ID      string         `json:"family_id"`
	Name    string         `json:"name"`
	Role    FamilyRole     `json:"role"`
	Members []FamilyMember `json:"members"`
}
type FamilyInvitationPreview struct {
	FamilyName         string         `json:"family_name"`
	InviterDisplayName *string        `json:"inviter_display_name"`
	Role               FamilyRole     `json:"role"`
	PatientNameHint    *string        `json:"patient_name_hint"`
	Members            []FamilyMember `json:"members"`
	ExpiresAt          time.Time      `json:"expires_at"`
}

func familyName(value string) (string, error) {
	name := strings.TrimSpace(value)
	if len([]rune(name)) < 1 || len([]rune(name)) > 60 || strings.ContainsAny(name, "\r\n") {
		return "", ErrInvalid
	}
	return name, nil
}

type CreateFamilyCommand struct {
	Mutation
	Name string
}

func (s *Service) CreateFamily(ctx context.Context, c CreateFamilyCommand) (Family, error) {
	name, err := familyName(c.Name)
	if err != nil {
		return Family{}, err
	}
	return transact(ctx, s, c.Mutation, patientTarget(c.ActorID), ScopeRead, "create_family", c, func(tx pgx.Tx) (Family, error) {
		id := domain.NewID()
		now := s.now().UTC()
		if _, err := tx.Exec(ctx, `INSERT INTO families(id,name,created_by,client_operation_id,created_at) VALUES($1,$2,$3,$4,$5)`, id, name, c.ActorID, c.OperationID, now); err != nil {
			return Family{}, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO family_members(family_id,user_id,role,joined_at) VALUES($1,$2,'admin',$3)`, id, c.ActorID, now); err != nil {
			return Family{}, err
		}
		return loadFamily(ctx, tx, c.ActorID, id)
	})
}

func (s *Service) Families(ctx context.Context, actor string) ([]Family, error) {
	if !domain.ValidID(actor) {
		return nil, ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `SELECT f.id::text FROM family_members m JOIN families f ON f.id=m.family_id WHERE m.user_id=$1 ORDER BY f.created_at,f.id`, actor)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	out := []Family{}
	for _, id := range ids {
		family, err := loadFamily(ctx, tx, actor, id)
		if err != nil {
			return nil, err
		}
		out = append(out, family)
	}
	return out, tx.Commit(ctx)
}

// loadFamily devuelve la familia sólo a sus miembros: para cualquier otra persona no existe.
func loadFamily(ctx context.Context, tx pgx.Tx, actor, id string) (Family, error) {
	out := Family{ID: id}
	if err := tx.QueryRow(ctx, `SELECT f.name,m.role FROM families f JOIN family_members m ON m.family_id=f.id AND m.user_id=$2 WHERE f.id=$1`, id, actor).Scan(&out.Name, &out.Role); err != nil {
		return out, translate(err)
	}
	members, err := familyMembers(ctx, tx, actor, id)
	out.Members = members
	return out, err
}

func familyMembers(ctx context.Context, tx pgx.Tx, actor, id string) ([]FamilyMember, error) {
	rows, err := tx.Query(ctx, `SELECT u.id::text,CASE WHEN u.profile_completed_at IS NOT NULL THEN u.display_name END,m.role,m.joined_at,u.id=$2 FROM family_members m JOIN users u ON u.id=m.user_id WHERE m.family_id=$1 ORDER BY m.joined_at,u.id`, id, actor)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (FamilyMember, error) {
		var v FamilyMember
		err := row.Scan(&v.UserID, &v.DisplayName, &v.Role, &v.JoinedAt, &v.You)
		return v, err
	})
}

// memberRole lee el rol del actor y bloquea la familia: los cambios de pertenencia de una
// misma familia se aplican de a uno.
func memberRole(ctx context.Context, tx pgx.Tx, family, actor string) (FamilyRole, error) {
	if _, err := tx.Exec(ctx, `SELECT id FROM families WHERE id=$1 FOR UPDATE`, family); err != nil {
		return "", err
	}
	var role FamilyRole
	err := tx.QueryRow(ctx, `SELECT role FROM family_members WHERE family_id=$1 AND user_id=$2`, family, actor).Scan(&role)
	return role, translate(err)
}

type InviteToFamilyCommand struct {
	Mutation
	FamilyID        string
	Role            FamilyRole
	PatientNameHint *string
}

func (s *Service) InviteToFamily(ctx context.Context, c InviteToFamilyCommand) (Invitation, error) {
	var out Invitation
	if c.PatientNameHint != nil {
		name, err := profileName(*c.PatientNameHint)
		if err != nil || c.Role != RolePatient {
			return out, ErrInvalid
		}
		c.PatientNameHint = &name
	}
	if !domain.ValidID(c.ActorID) || !domain.ValidID(c.OperationID) || !domain.ValidID(c.FamilyID) || !validRole(c.Role) {
		return out, ErrInvalid
	}
	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		return out, err
	}
	now := s.now().UTC()
	out = Invitation{ID: domain.NewID(), Token: base64.RawURLEncoding.EncodeToString(token), ExpiresAt: now.Add(familyInvitationTTL)}
	hash := sha256.Sum256([]byte(out.Token))
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Invitation{}, err
	}
	defer tx.Rollback(ctx)
	role, err := memberRole(ctx, tx, c.FamilyID, c.ActorID)
	if err != nil {
		return Invitation{}, err
	}
	if role != RoleAdmin {
		return Invitation{}, ErrForbidden
	}
	// Cada envío crea otra invitación: el token no se puede recuperar si se pierde la respuesta.
	if _, err = tx.Exec(ctx, `INSERT INTO operations(actor_user_id,client_operation_id,kind,fingerprint,response) VALUES($1,$2,'create_invitation',$3,'{}')`, c.ActorID, c.OperationID, hash[:]); err != nil {
		return Invitation{}, translate(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO invitations(id,inviter_user_id,client_operation_id,token_hash,scopes,expires_at,created_at,patient_name_hint,family_id,role) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		out.ID, c.ActorID, c.OperationID, hash[:], scopeNames(roleScopes(c.Role)), out.ExpiresAt, now, c.PatientNameHint, c.FamilyID, c.Role)
	if err != nil {
		return Invitation{}, translate(err)
	}
	return out, tx.Commit(ctx)
}

func scopeNames(scopes []Scope) []string {
	names := make([]string, len(scopes))
	for i, scope := range scopes {
		names[i] = string(scope)
	}
	return names
}

type pendingInvitation struct {
	id, family, inviter string
	role                FamilyRole
	expires             time.Time
	consumed            *time.Time
	hint                *string
}

func (s *Service) PreviewFamilyInvitation(ctx context.Context, actor, token string) (FamilyInvitationPreview, error) {
	var out FamilyInvitationPreview
	if !domain.ValidID(actor) || len(token) != 43 {
		return out, ErrInvalid
	}
	hash := sha256.Sum256([]byte(token))
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	var family string
	err = tx.QueryRow(ctx, `SELECT i.family_id::text,f.name,i.role,i.expires_at,i.patient_name_hint,CASE WHEN u.profile_completed_at IS NOT NULL THEN u.display_name END FROM invitations i JOIN families f ON f.id=i.family_id JOIN users u ON u.id=i.inviter_user_id WHERE i.token_hash=$1 AND i.consumed_at IS NULL AND i.expires_at>$2`, hash[:], s.now()).
		Scan(&family, &out.FamilyName, &out.Role, &out.ExpiresAt, &out.PatientNameHint, &out.InviterDisplayName)
	if err != nil {
		return out, translate(err)
	}
	// Quien recibe la invitación ve a quién le dará acceso antes de aceptar.
	if out.Members, err = familyMembers(ctx, tx, actor, family); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

type AcceptFamilyInvitationCommand struct {
	Mutation
	Token string
}

func (s *Service) AcceptFamilyInvitation(ctx context.Context, c AcceptFamilyInvitationCommand) (Family, error) {
	var out Family
	if !domain.ValidID(c.ActorID) || !domain.ValidID(c.OperationID) || len(c.Token) != 43 {
		return out, ErrInvalid
	}
	hash := sha256.Sum256([]byte(c.Token))
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", strings.ToLower(c.ActorID+"/"+c.OperationID)); err != nil {
		return out, err
	}
	var inv pendingInvitation
	err = tx.QueryRow(ctx, `SELECT id::text,family_id::text,inviter_user_id::text,role,expires_at,consumed_at,patient_name_hint FROM invitations WHERE token_hash=$1 AND family_id IS NOT NULL FOR UPDATE`, hash[:]).
		Scan(&inv.id, &inv.family, &inv.inviter, &inv.role, &inv.expires, &inv.consumed, &inv.hint)
	if err != nil {
		return out, translate(err)
	}
	if inv.consumed != nil {
		// Un reintento de la misma operación recibe la familia actual, si sigue siendo miembro.
		var kind string
		var fingerprint []byte
		if err = tx.QueryRow(ctx, `SELECT kind,fingerprint FROM operations WHERE actor_user_id=$1 AND client_operation_id=$2`, c.ActorID, c.OperationID).Scan(&kind, &fingerprint); err != nil {
			return out, ErrConflict
		}
		if kind != "accept_family_invitation" || !bytes.Equal(fingerprint, hash[:]) {
			return out, ErrConflict
		}
		if out, err = loadFamily(ctx, tx, c.ActorID, inv.family); err != nil {
			return out, err
		}
		return out, tx.Commit(ctx)
	}
	now := s.now().UTC()
	if !now.Before(inv.expires) {
		return out, ErrConflict
	}
	if _, err = memberRole(ctx, tx, inv.family, c.ActorID); err == nil {
		return out, ErrConflict
	} else if err != ErrNotFound {
		return out, err
	}
	if inv.role == RolePatient {
		if _, err = tx.Exec(ctx, `INSERT INTO patients(user_id) VALUES($1) ON CONFLICT DO NOTHING`, c.ActorID); err != nil {
			return out, err
		}
		if inv.hint != nil {
			if _, err = s.changeProfile(ctx, tx, c.Mutation, c.ActorID, *inv.hint, 0, true); err != nil {
				return out, translate(err)
			}
		}
	}
	if _, err = tx.Exec(ctx, `INSERT INTO family_members(family_id,user_id,role,joined_at) VALUES($1,$2,$3,$4)`, inv.family, c.ActorID, inv.role, now); err != nil {
		return out, err
	}
	if _, err = tx.Exec(ctx, `UPDATE invitations SET consumed_at=$2,consumed_by=$3 WHERE id=$1`, inv.id, now, c.ActorID); err != nil {
		return out, err
	}
	if err = syncLinks(ctx, tx, c.ActorID, c.ActorID, &inv.id, now); err != nil {
		return out, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO operations(actor_user_id,client_operation_id,kind,fingerprint,response) VALUES($1,$2,'accept_family_invitation',$3,'{}')`, c.ActorID, c.OperationID, hash[:]); err != nil {
		return out, translate(err)
	}
	if out, err = loadFamily(ctx, tx, c.ActorID, inv.family); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

// RemoveFamilyMember sirve para salir de una familia y, a quien administra, para quitar a otra persona.
func (s *Service) RemoveFamilyMember(ctx context.Context, actor, family, member string) error {
	if !domain.ValidID(actor) || !domain.ValidID(family) || !domain.ValidID(member) {
		return ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = removeMember(ctx, tx, actor, family, member, s.now().UTC()); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func removeMember(ctx context.Context, tx pgx.Tx, actor, family, member string, now time.Time) error {
	role, err := memberRole(ctx, tx, family, actor)
	if err != nil {
		return err
	}
	if !strings.EqualFold(actor, member) && role != RoleAdmin {
		return ErrForbidden
	}
	tag, err := tx.Exec(ctx, `DELETE FROM family_members WHERE family_id=$1 AND user_id=$2`, family, member)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	affected := []string{member}
	// La familia no queda sin administración mientras tenga cuidadores: asume el cuidador más
	// antiguo y, si no hay, quien sólo mira.
	var promoted string
	err = tx.QueryRow(ctx, `UPDATE family_members SET role='admin' WHERE (family_id,user_id)=(SELECT family_id,user_id FROM family_members WHERE family_id=$1 AND role IN ('caregiver','observer') AND NOT EXISTS (SELECT 1 FROM family_members WHERE family_id=$1 AND role='admin') ORDER BY role='observer',joined_at,user_id LIMIT 1) RETURNING user_id::text`, family).Scan(&promoted)
	if err == nil {
		affected = append(affected, promoted)
	} else if err != pgx.ErrNoRows {
		return err
	}
	for _, user := range affected {
		if err = syncLinks(ctx, tx, actor, user, nil, now); err != nil {
			return err
		}
	}
	return nil
}

// leaveFamilies saca a una persona de todas sus familias, como al borrar su cuenta.
func leaveFamilies(ctx context.Context, tx pgx.Tx, actor string, now time.Time) error {
	rows, err := tx.Query(ctx, `SELECT family_id::text FROM family_members WHERE user_id=$1 ORDER BY family_id`, actor)
	if err != nil {
		return err
	}
	families, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, family := range families {
		if err = removeMember(ctx, tx, actor, family, actor, now); err != nil {
			return err
		}
	}
	return nil
}

type link struct {
	patient, caregiver string
	scopes             []string
}

// syncLinks recalcula los vínculos de cada par en que participa user. Un par existe si comparten
// una familia en la que uno es paciente y el otro no; sus alcances son la unión de los roles.
// Es la única forma de crear, cambiar o revocar un vínculo, y siempre en la transacción del cambio.
func syncLinks(ctx context.Context, tx pgx.Tx, actor, user string, invitation *string, now time.Time) error {
	rows, err := tx.Query(ctx, `SELECT p.user_id::text,c.user_id::text,array_agg(DISTINCT c.role) FROM family_members p JOIN family_members c ON c.family_id=p.family_id AND c.user_id<>p.user_id AND c.role<>'patient' WHERE p.role='patient' AND (p.user_id=$1 OR c.user_id=$1) GROUP BY 1,2 ORDER BY 1,2`, user)
	if err != nil {
		return err
	}
	desired, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (link, error) {
		var l link
		var roles []string
		if err := row.Scan(&l.patient, &l.caregiver, &roles); err != nil {
			return l, err
		}
		for _, role := range roles {
			l.scopes = append(l.scopes, scopeNames(roleScopes(FamilyRole(role)))...)
		}
		slices.Sort(l.scopes)
		l.scopes = slices.Compact(l.scopes)
		return l, nil
	})
	if err != nil {
		return err
	}
	keep := []string{}
	for _, l := range desired {
		var id, status string
		var scopes []string
		err := tx.QueryRow(ctx, `SELECT id::text,status,scopes FROM caregiver_links WHERE patient_user_id=$1 AND caregiver_user_id=$2 FOR UPDATE`, l.patient, l.caregiver).Scan(&id, &status, &scopes)
		if err != nil && err != pgx.ErrNoRows {
			return err
		}
		slices.Sort(scopes)
		if err == nil && status == "active" && slices.Equal(scopes, l.scopes) {
			keep = append(keep, id)
			continue
		}
		if err = tx.QueryRow(ctx, `INSERT INTO caregiver_links(patient_user_id,caregiver_user_id,status,scopes,accepted_at,accepted_invitation_id) VALUES($1,$2,'active',$3,$4,$5) ON CONFLICT(patient_user_id,caregiver_user_id) DO UPDATE SET status='active',scopes=excluded.scopes,accepted_at=excluded.accepted_at,revoked_at=NULL,accepted_invitation_id=COALESCE(excluded.accepted_invitation_id,caregiver_links.accepted_invitation_id) RETURNING id::text`, l.patient, l.caregiver, l.scopes, now, invitation).Scan(&id); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO caregiver_link_events(link_id,actor_user_id,action,scopes,created_at) VALUES($1,$2,'accepted',$3,$4)`, id, actor, l.scopes, now); err != nil {
			return err
		}
		keep = append(keep, id)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO caregiver_link_events(link_id,actor_user_id,action,scopes,created_at) SELECT id,$2,'revoked',scopes,$3 FROM caregiver_links WHERE (patient_user_id=$1 OR caregiver_user_id=$1) AND status='active' AND NOT (id::text=ANY($4))`, user, actor, now, keep); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE caregiver_links SET status='revoked',revoked_at=$2 WHERE (patient_user_id=$1 OR caregiver_user_id=$1) AND status='active' AND NOT (id::text=ANY($3))`, user, now, keep)
	return err
}
