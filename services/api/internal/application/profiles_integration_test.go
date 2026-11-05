//go:build integration

package application

import (
	"context"
	"errors"
	"sync"
	"testing"

	"medication-tracker/services/api/internal/domain"
)

func TestProfileConcurrentEditsAndReplayAuthorization(t *testing.T) {
	s, p, patient := fixture(t)
	caregiver, err := s.ResolveUser(context.Background(), domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	family, _ := grant(t, s, caregiver, patient, RoleAdmin)
	cmd := UpdateProfileCommand{Mutation: mutation(caregiver), PatientID: patient, ExpectedVersion: 1, DisplayName: "Persona"}
	results := make(chan error, 2)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; _, err := s.UpdateProfile(context.Background(), cmd); results <- err }()
	}
	close(start)
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	if countRows(t, p, "SELECT count(*) FROM user_profile_changes WHERE user_id=$1", patient) != 1 {
		t.Fatal("replay duplicated audit")
	}
	changed := cmd
	changed.DisplayName = "Otra"
	if _, err := s.UpdateProfile(context.Background(), changed); !errors.Is(err, ErrConflict) {
		t.Fatal("key reuse accepted", err)
	}
	setRole(t, s, family, caregiver, RoleObserver)
	if _, err = s.UpdateProfile(context.Background(), cmd); !errors.Is(err, ErrForbidden) {
		t.Fatal("replay bypassed scope downgrade", err)
	}
	if err = s.RemoveFamilyMember(context.Background(), caregiver, family, caregiver); err != nil {
		t.Fatal(err)
	}
	if _, err = s.UpdateProfile(context.Background(), cmd); !errors.Is(err, ErrNotFound) {
		t.Fatal("replay bypassed revocation", err)
	}
}

func TestProfileHintRacingExplicitEdit(t *testing.T) {
	s, p, patient := fixture(t)
	caregiver, err := s.ResolveUser(context.Background(), domain.NewID())
	if err != nil {
		t.Fatal(err)
	}
	hint := "Sugerido"
	family, err := s.CreateFamily(context.Background(), CreateFamilyCommand{Mutation: mutation(caregiver), Name: "Familia"})
	if err != nil {
		t.Fatal(err)
	}
	invitation, err := s.InviteToFamily(context.Background(), InviteToFamilyCommand{Mutation: mutation(caregiver), FamilyID: family.ID, Role: RolePatient, PatientNameHint: &hint})
	if err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	edits := make(chan error, 1)
	accepts := make(chan error, 1)
	go func() {
		<-start
		_, err := s.UpdateProfile(context.Background(), UpdateProfileCommand{Mutation: mutation(patient), PatientID: patient, ExpectedVersion: 1, DisplayName: "Elegido"})
		edits <- err
	}()
	go func() {
		<-start
		_, err := s.AcceptFamilyInvitation(context.Background(), AcceptFamilyInvitationCommand{Mutation: mutation(patient), Token: invitation.Token})
		accepts <- err
	}()
	close(start)
	editErr := <-edits
	if err := <-accepts; err != nil {
		t.Fatal(err)
	}
	profile, err := s.Profile(context.Background(), patient)
	if err != nil {
		t.Fatal(err)
	}
	if editErr == nil {
		if profile.DisplayName == nil || *profile.DisplayName != "Elegido" || profile.ProfileVersion != 2 {
			t.Fatal("hint overwrote completed profile")
		}
	} else if errors.Is(editErr, ErrConflict) {
		if profile.DisplayName == nil || *profile.DisplayName != hint || profile.ProfileVersion != 2 {
			t.Fatal("conflict lost hint")
		}
	} else {
		t.Fatal(editErr)
	}
	if countRows(t, p, "SELECT count(*) FROM user_profile_changes WHERE user_id=$1", patient) != 1 {
		t.Fatal("race duplicated audit")
	}
}

func TestConcurrentProfileVersions(t *testing.T) {
	s, p, patient := fixture(t)
	start := make(chan struct{})
	results := make(chan error, 2)
	for _, name := range []string{"Primero", "Segundo"} {
		go func(name string) {
			<-start
			_, err := s.UpdateProfile(context.Background(), UpdateProfileCommand{Mutation: mutation(patient), PatientID: patient, ExpectedVersion: 1, DisplayName: name})
			results <- err
		}(name)
	}
	close(start)
	success, conflict := 0, 0
	for i := 0; i < 2; i++ {
		err := <-results
		if err == nil {
			success++
		} else if errors.Is(err, ErrConflict) {
			conflict++
		} else {
			t.Fatal(err)
		}
	}
	if success != 1 || conflict != 1 || countRows(t, p, "SELECT count(*) FROM user_profile_changes WHERE user_id=$1", patient) != 1 {
		t.Fatal("version race", success, conflict)
	}
}
