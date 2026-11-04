package application

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

type Scope string

const (
	ScopeRead       Scope = "read"
	ScopeTreatments Scope = "treatments"
	ScopeDoses      Scope = "doses"
	ScopeInventory  Scope = "inventory"
)

type accessTarget struct{ kind, id string }

func patientTarget(id string) accessTarget   { return accessTarget{"patient", id} }
func treatmentTarget(id string) accessTarget { return accessTarget{"treatment", id} }
func doseTarget(id string) accessTarget      { return accessTarget{"dose", id} }
func accountTarget(id string) accessTarget   { return accessTarget{"account", id} }

func authorize(ctx context.Context, tx pgx.Tx, actor string, target accessTarget, scope Scope) error {
	return translate(authorizeTx(ctx, tx, actor, target, scope))
}

func authorizeTx(ctx context.Context, tx pgx.Tx, actor string, target accessTarget, scope Scope) error {
	if !domain.ValidID(actor) || !domain.ValidID(target.id) {
		return ErrInvalid
	}
	var patient string
	var query string
	switch target.kind {
	case "patient", "profile":
		query = "SELECT id::text FROM users WHERE id=$1"
	case "treatment":
		query = "SELECT patient_user_id::text FROM treatments WHERE id=$1"
	case "dose":
		query = "SELECT t.patient_user_id::text FROM dose_occurrences d JOIN treatments t ON t.id=d.treatment_id WHERE d.id=$1"
	case "account":
		query = "SELECT patient_user_id::text FROM inventory_accounts WHERE id=$1"
	default:
		return ErrInvalid
	}
	if err := tx.QueryRow(ctx, query, target.id).Scan(&patient); err != nil {
		return err
	}
	if strings.EqualFold(actor, patient) {
		return nil
	}
	var id string
	// The shared lock makes revocation wait for already authorized operations.
	err := tx.QueryRow(ctx, `SELECT id::text FROM caregiver_links WHERE patient_user_id=$1 AND caregiver_user_id=$2 AND status='active' AND 'read'=ANY(scopes) AND $3=ANY(scopes) FOR SHARE`, patient, actor, string(scope)).Scan(&id)
	if err == pgx.ErrNoRows && target.kind == "profile" {
		var visible string
		readErr := tx.QueryRow(ctx, `SELECT id::text FROM caregiver_links WHERE patient_user_id=$1 AND caregiver_user_id=$2 AND status='active' AND 'read'=ANY(scopes) FOR SHARE`, patient, actor).Scan(&visible)
		if readErr == nil {
			return ErrForbidden
		}
		return readErr
	}
	return err
}

func (s *Service) ResolveUser(ctx context.Context, uid string) (string, error) {
	if strings.TrimSpace(uid) == "" || len(uid) > 128 {
		return "", ErrInvalid
	}
	var id string
	err := s.pool.QueryRow(ctx, `INSERT INTO users(auth_provider_uid,display_name) VALUES($1,'User') ON CONFLICT(auth_provider_uid) DO UPDATE SET auth_provider_uid=excluded.auth_provider_uid RETURNING id::text`, uid).Scan(&id)
	return id, translate(err)
}

type PatientAccess struct {
	DisplayName    *string `json:"display_name"`
	ProfileVersion int64   `json:"profile_version"`
	PatientID      string  `json:"patient_id"`
	LinkID         *string `json:"link_id"`
	Scopes         []Scope `json:"scopes"`
}

func (s *Service) Patients(ctx context.Context, actor, cursor string) ([]PatientAccess, string, error) {
	if !domain.ValidID(actor) || !validCursor(cursor) {
		return nil, "", ErrInvalid
	}
	rows, err := s.pool.Query(ctx, `SELECT accessible.*,CASE WHEN u.profile_completed_at IS NOT NULL THEN u.display_name END,u.profile_version FROM (SELECT id::text AS patient,NULL::text AS link,ARRAY['read','treatments','doses','inventory']::text[] AS scopes FROM users WHERE id=$1 UNION ALL SELECT patient_user_id::text,id::text,scopes FROM caregiver_links WHERE caregiver_user_id=$1 AND status='active' AND 'read'=ANY(scopes)) accessible JOIN users u ON u.id=patient::uuid WHERE patient::uuid>$2::uuid ORDER BY patient LIMIT 101`, actor, cursorValue(cursor))
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	result := []PatientAccess{}
	for rows.Next() {
		var p PatientAccess
		var scopes []string
		if err = rows.Scan(&p.PatientID, &p.LinkID, &scopes, &p.DisplayName, &p.ProfileVersion); err != nil {
			return nil, "", err
		}
		for _, scope := range scopes {
			p.Scopes = append(p.Scopes, Scope(scope))
		}
		result = append(result, p)
	}
	if err = rows.Err(); err != nil {
		return nil, "", err
	}
	next := ""
	if len(result) > PageSize {
		result = result[:PageSize]
		next = result[PageSize-1].PatientID
	}
	return result, next, nil
}
