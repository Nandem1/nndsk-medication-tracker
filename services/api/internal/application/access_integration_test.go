//go:build integration

package application

import (
	"context"
	"errors"
	"testing"
	"time"

	"medication-tracker/services/api/internal/domain"
)

func TestConsentReplayGenerationAndRevocationLock(t *testing.T) {
	_, pool, patient := fixture(t)
	s := New(pool, nil)
	ctx := context.Background()
	caregiver, err := s.ResolveUser(ctx, domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	invite, err := s.CreateInvitation(ctx, mutation(caregiver), []Scope{ScopeRead, ScopeDoses})
	if err != nil {
		t.Fatal(err)
	}
	accept := mutation(patient)
	link, err := s.AcceptInvitation(ctx, accept, invite.Token)
	if err != nil {
		t.Fatal(err)
	}
	replay, err := s.AcceptInvitation(ctx, accept, invite.Token)
	if err != nil || replay.ID != link.ID {
		t.Fatal(replay, err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if err = authorize(ctx, tx, caregiver, patientTarget(patient), ScopeRead); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	done := make(chan error, 1)
	go func() { close(started); done <- s.RevokeLink(ctx, patient, link.ID) }()
	<-started
	select {
	case err = <-done:
		t.Fatal("revocation did not wait for authorized transaction", err)
	case <-time.After(30 * time.Millisecond):
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
		t.Fatal("revocation blocked")
	}
	if _, err = s.AcceptInvitation(ctx, accept, invite.Token); !errors.Is(err, ErrNotFound) {
		t.Fatal("revoked replay", err)
	}
	newInvite, err := s.CreateInvitation(ctx, mutation(caregiver), []Scope{ScopeRead})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptInvitation(ctx, mutation(patient), newInvite.Token); err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptInvitation(ctx, accept, invite.Token); !errors.Is(err, ErrNotFound) {
		t.Fatal("old acceptance replay after reactivation", err)
	}
}
func TestInvitationOperationReuseDoesNotActivateLink(t *testing.T) {
	s, p, patient := fixture(t)
	ctx := context.Background()
	caregiver, err := s.ResolveUser(ctx, domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	inv, err := s.CreateInvitation(ctx, mutation(caregiver), []Scope{ScopeRead})
	if err != nil {
		t.Fatal(err)
	}
	used := mutation(patient)
	if _, err = s.CreateInvitation(ctx, used, []Scope{ScopeRead}); err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptInvitation(ctx, used, inv.Token); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	var count int
	if err = p.QueryRow(ctx, `SELECT count(*) FROM caregiver_links WHERE patient_user_id=$1 AND caregiver_user_id=$2`, patient, caregiver).Scan(&count); err != nil || count != 0 {
		t.Fatal(count, err)
	}
}
