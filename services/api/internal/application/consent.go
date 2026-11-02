package application

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"medication-tracker/services/api/internal/domain"
)

type Invitation struct {
	ID        string    `json:"invitation_id"`
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}
type Link struct {
	ID          string  `json:"link_id"`
	PatientID   string  `json:"patient_id"`
	CaregiverID string  `json:"caregiver_id"`
	Scopes      []Scope `json:"scopes"`
	Status      string  `json:"status"`
}

func validScopes(scopes []Scope) bool {
	seen := map[Scope]bool{}
	for _, scope := range scopes {
		if seen[scope] {
			return false
		}
		switch scope {
		case ScopeRead, ScopeTreatments, ScopeDoses, ScopeInventory:
			seen[scope] = true
		default:
			return false
		}
	}
	return seen[ScopeRead]
}
func (s *Service) CreateInvitation(ctx context.Context, m Mutation, scopes []Scope) (Invitation, error) {
	var out Invitation
	if !domain.ValidID(m.ActorID) || !domain.ValidID(m.OperationID) || !validScopes(scopes) {
		return out, ErrInvalid
	}
	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		return out, err
	}
	out = Invitation{ID: domain.NewID(), Token: base64.RawURLEncoding.EncodeToString(token), ExpiresAt: s.now().UTC().Add(24 * time.Hour)}
	hash := sha256.Sum256([]byte(out.Token))
	names := []string{}
	for _, scope := range scopes {
		names = append(names, string(scope))
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Invitation{}, err
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `INSERT INTO operations(actor_user_id,client_operation_id,kind,fingerprint,response) VALUES($1,$2,'create_invitation',$3,'{}')`, m.ActorID, m.OperationID, hash[:])
	if err != nil {
		return Invitation{}, translate(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO invitations(id,inviter_user_id,client_operation_id,token_hash,scopes,expires_at,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)`, out.ID, m.ActorID, m.OperationID, hash[:], names, out.ExpiresAt, s.now().UTC())
	if err != nil {
		return Invitation{}, translate(err)
	}
	return out, tx.Commit(ctx)
}
func (s *Service) AcceptInvitation(ctx context.Context, m Mutation, token string) (Link, error) {
	var out Link
	if !domain.ValidID(m.ActorID) || !domain.ValidID(m.OperationID) || len(token) != 43 {
		return out, ErrInvalid
	}
	hash := sha256.Sum256([]byte(token))
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", strings.ToLower(m.ActorID+"/"+m.OperationID)); err != nil {
		return out, err
	}
	var inviter, id string
	var expires time.Time
	var consumed *time.Time
	var scopes []string
	err = tx.QueryRow(ctx, `SELECT id::text,inviter_user_id::text,scopes,expires_at,consumed_at FROM invitations WHERE token_hash=$1 FOR UPDATE`, hash[:]).Scan(&id, &inviter, &scopes, &expires, &consumed)
	if err != nil {
		return out, translate(err)
	}
	if consumed != nil {
		var kind string
		var fingerprint, response []byte
		if err = tx.QueryRow(ctx, `SELECT kind,fingerprint,response FROM operations WHERE actor_user_id=$1 AND client_operation_id=$2`, m.ActorID, m.OperationID).Scan(&kind, &fingerprint, &response); err != nil {
			return out, ErrConflict
		}
		if kind != "accept_invitation" || !bytes.Equal(fingerprint, hash[:]) {
			return out, ErrConflict
		}
		if err = json.Unmarshal(response, &out); err != nil {
			return out, err
		}
		var linkID string
		if err = tx.QueryRow(ctx, `SELECT id::text FROM caregiver_links WHERE id=$1 AND status='active' AND accepted_invitation_id=$2 FOR SHARE`, out.ID, id).Scan(&linkID); err != nil {
			return Link{}, translate(err)
		}
		return out, tx.Commit(ctx)
	}
	if !s.now().Before(expires) || strings.EqualFold(inviter, m.ActorID) {
		return out, ErrConflict
	}
	if _, err = tx.Exec(ctx, `INSERT INTO patients(user_id) VALUES($1) ON CONFLICT DO NOTHING`, m.ActorID); err != nil {
		return out, err
	}
	out = Link{PatientID: m.ActorID, CaregiverID: inviter, Status: "active"}
	for _, v := range scopes {
		out.Scopes = append(out.Scopes, Scope(v))
	}
	err = tx.QueryRow(ctx, `INSERT INTO caregiver_links(patient_user_id,caregiver_user_id,status,scopes,accepted_at,accepted_invitation_id) VALUES($1,$2,'active',$3,$4,$5) ON CONFLICT(patient_user_id,caregiver_user_id) DO UPDATE SET status='active',scopes=excluded.scopes,accepted_at=excluded.accepted_at,revoked_at=NULL,accepted_invitation_id=excluded.accepted_invitation_id RETURNING id::text`, m.ActorID, inviter, scopes, s.now().UTC(), id).Scan(&out.ID)
	if err != nil {
		return out, translate(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE invitations SET consumed_at=$2,consumed_by=$3 WHERE id=$1`, id, s.now().UTC(), m.ActorID); err != nil {
		return out, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO caregiver_link_events(link_id,actor_user_id,action,scopes,created_at) VALUES($1,$2,'accepted',$3,$4)`, out.ID, m.ActorID, scopes, s.now().UTC()); err != nil {
		return out, err
	}
	response, err := json.Marshal(out)
	if err != nil {
		return out, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO operations(actor_user_id,client_operation_id,kind,fingerprint,response) VALUES($1,$2,'accept_invitation',$3,$4)`, m.ActorID, m.OperationID, hash[:], response); err != nil {
		return Link{}, translate(err)
	}
	return out, tx.Commit(ctx)
}
func (s *Service) RevokeLink(ctx context.Context, actor, id string) error {
	if !domain.ValidID(actor) || !domain.ValidID(id) {
		return ErrInvalid
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var status string
	var scopes []string
	if err = tx.QueryRow(ctx, `SELECT status,scopes FROM caregiver_links WHERE id=$1 AND (patient_user_id=$2 OR caregiver_user_id=$2) FOR UPDATE`, id, actor).Scan(&status, &scopes); err != nil {
		return translate(err)
	}
	if status != "revoked" {
		if _, err = tx.Exec(ctx, `UPDATE caregiver_links SET status='revoked',revoked_at=$2 WHERE id=$1`, id, s.now().UTC()); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO caregiver_link_events(link_id,actor_user_id,action,scopes,created_at) VALUES($1,$2,'revoked',$3,$4)`, id, actor, scopes, s.now().UTC()); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
