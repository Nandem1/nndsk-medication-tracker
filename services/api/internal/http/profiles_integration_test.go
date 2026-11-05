//go:build integration

package httpapi

import (
	"context"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"testing"

	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
)

func TestProfilesAndInvitationNames(t *testing.T) {
	f := newAPIFixture(t)
	var me MeResponse
	f.request("patient", "GET", "/v1/me", nil, 200, &me)
	if me.DisplayName != nil || me.ProfileComplete || me.ProfileVersion != 1 {
		t.Fatal("new profile must be unnamed")
	}
	var exported application.AccountExport
	f.request("patient", "GET", "/v1/me/export", nil, 200, &exported)
	if exported.Profile.DisplayName != nil {
		t.Fatal("export exposed placeholder name")
	}
	update := map[string]any{"client_operation_id": domain.NewID(), "expected_version": 1, "display_name": "  Mamá  "}
	var profile application.Profile
	f.request("patient", "PUT", "/v1/me/profile", update, 200, &profile)
	if profile.DisplayName == nil || *profile.DisplayName != "Mamá" || profile.ProfileVersion != 2 || !profile.ProfileComplete {
		t.Fatal("profile not completed")
	}
	f.request("patient", "PUT", "/v1/me/profile", update, 200, &profile)
	if profile.ProfileVersion != 2 {
		t.Fatal("replay changed version")
	}
	update["client_operation_id"] = domain.NewID()
	f.request("patient", "PUT", "/v1/me/profile", update, 409, nil)
	update["expected_version"] = 2
	f.request("stranger", "PUT", "/v1/patients/"+f.patient+"/profile", update, 404, nil)
	link := f.invite([]application.Scope{application.ScopeRead})
	f.request("caregiver", "PUT", "/v1/patients/"+f.patient+"/profile", update, 403, nil)
	f.request("caregiver", "DELETE", "/v1/families/"+link.FamilyID+"/members/"+f.caregiver, nil, 204, nil)
	f.invite([]application.Scope{application.ScopeRead, application.ScopeTreatments})
	update["display_name"] = "Madre"
	f.request("caregiver", "PUT", "/v1/patients/"+f.patient+"/profile", update, 200, &profile)
	if profile.ProfileVersion != 3 || *profile.DisplayName != "Madre" {
		t.Fatal("caregiver update failed")
	}
	var page Page[application.PatientAccess]
	f.request("caregiver", "GET", "/v1/patients", nil, 200, &page)
	found := false
	for _, p := range page.Items {
		if p.PatientID == f.patient {
			found = p.DisplayName != nil && *p.DisplayName == "Madre" && p.ProfileVersion == 3
		}
	}
	if !found {
		t.Fatal("patient name missing")
	}
	var families Page[application.Family]
	f.request("caregiver", "GET", "/v1/families", nil, 200, &families)
	named := false
	for _, family := range families.Items {
		for _, m := range family.Members {
			named = named || m.UserID == f.patient && m.DisplayName != nil && *m.DisplayName == "Madre"
		}
	}
	if !named {
		t.Fatal("member name missing")
	}
	for _, name := range []string{"", "   ", "a\nb", "a\rb", "a\u2028b", "a\u2029b", strings.Repeat("ñ", 61)} {
		f.request("patient", "PUT", "/v1/me/profile", map[string]any{"client_operation_id": domain.NewID(), "expected_version": 3, "display_name": name}, 422, nil)
	}
	var count int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM user_profile_changes WHERE user_id=$1", f.patient).Scan(&count); err != nil || count != 2 {
		t.Fatal("audit count", count, err)
	}
}

func TestInvitationHintOnlyCompletesUnnamedProfile(t *testing.T) {
	f := newAPIFixture(t)
	f.request("caregiver", "PUT", "/v1/me/profile", map[string]any{"client_operation_id": domain.NewID(), "expected_version": 1, "display_name": "Cuidadora"}, 200, nil)
	for i := 0; i < 2; i++ {
		var invitation application.Invitation
		f.request("caregiver", "POST", "/v1/families/"+f.family("caregiver")+"/invitations", map[string]any{"client_operation_id": domain.NewID(), "role": "patient", "patient_name_hint": "Papá"}, 201, &invitation)
		if !regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`).MatchString(invitation.Token) {
			t.Fatal("unexpected token format")
		}
		var preview application.FamilyInvitationPreview
		f.request("patient", "POST", "/v1/family-invitations/preview", map[string]string{"token": invitation.Token}, 200, &preview)
		if preview.InviterDisplayName == nil || *preview.InviterDisplayName != "Cuidadora" || preview.PatientNameHint == nil || *preview.PatientNameHint != "Papá" {
			t.Fatal("preview names missing")
		}
		accept := AcceptInvitationRequest{domain.NewID(), invitation.Token}
		f.request("patient", "POST", "/v1/family-invitations/accept", accept, 200, nil)
		f.request("patient", "POST", "/v1/family-invitations/accept", accept, 200, nil)
		var me MeResponse
		f.request("patient", "GET", "/v1/me", nil, 200, &me)
		want := "Papá"
		if i == 1 {
			want = "Padre"
		}
		if me.DisplayName == nil || *me.DisplayName != want {
			t.Fatal("hint overwrote profile")
		}
		if i == 0 {
			f.request("patient", "PUT", "/v1/me/profile", map[string]any{"client_operation_id": domain.NewID(), "expected_version": me.ProfileVersion, "display_name": "Padre"}, 200, nil)
		}
	}
	var count int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM user_profile_changes WHERE user_id=$1", f.patient).Scan(&count); err != nil || count != 2 {
		t.Fatal("hint duplicated audit", count, err)
	}
}

func TestConcurrentMaterializingGETs(t *testing.T) {
	f := newAPIFixture(t)
	f.treatment("patient")
	f.invite([]application.Scope{application.ScopeRead})
	start := make(chan struct{})
	results := make(chan int, 16)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			path := "/doses"
			if i%2 == 0 {
				path = "/adherence"
			}
			req, err := http.NewRequest("GET", f.server.URL+"/v1/patients/"+f.patient+path+"?from=2027-01-01&to=2027-02-01", nil)
			if err != nil {
				results <- 0
				return
			}
			actor := "patient"
			if i%3 == 0 {
				actor = "caregiver"
			}
			req.Header.Set("Authorization", "Bearer "+actor)
			<-start
			response, err := f.server.Client().Do(req)
			if err != nil {
				results <- 0
				return
			}
			defer response.Body.Close()
			results <- response.StatusCode
		}(i)
	}
	close(start)
	wg.Wait()
	close(results)
	for status := range results {
		if status != 200 {
			t.Errorf("concurrent GET returned %d", status)
		}
	}
}

// Quien sale de la familia deja de ver a sus miembros y sus nombres.
func TestLeavingDoesNotRevealCurrentNames(t *testing.T) {
	f := newAPIFixture(t)
	link := f.invite([]application.Scope{application.ScopeRead})
	f.leave(link)
	f.request("caregiver", "PUT", "/v1/me/profile", map[string]any{"client_operation_id": domain.NewID(), "expected_version": 1, "display_name": "Nombre privado"}, 200, nil)
	var families Page[application.Family]
	f.request("patient", "GET", "/v1/families", nil, 200, &families)
	if len(families.Items) != 0 {
		t.Fatal("left family still visible", families)
	}
}

func TestProfileAndInvitationRejectNullCharacter(t *testing.T) {
	f := newAPIFixture(t)
	f.request("patient", "PUT", "/v1/me/profile", map[string]any{"client_operation_id": domain.NewID(), "expected_version": 1, "display_name": "a\x00b"}, 422, nil)
	f.request("caregiver", "POST", "/v1/families/"+f.family("caregiver")+"/invitations", map[string]any{"client_operation_id": domain.NewID(), "role": "patient", "patient_name_hint": "a\x00b"}, 422, nil)
	f.request("caregiver", "POST", "/v1/families", map[string]any{"client_operation_id": domain.NewID(), "name": "a\nb"}, 422, nil)
}

func TestPatientAccessExposesProfileTimezone(t *testing.T) {
	f := newAPIFixture(t)
	if _, err := f.pool.Exec(context.Background(), "UPDATE users SET timezone='Pacific/Auckland' WHERE id=$1", f.patient); err != nil {
		t.Fatal(err)
	}
	f.invite([]application.Scope{application.ScopeRead})
	var page Page[application.PatientAccess]
	f.request("caregiver", "GET", "/v1/patients", nil, 200, &page)
	for _, patient := range page.Items {
		if patient.PatientID == f.patient {
			if patient.Timezone != "Pacific/Auckland" {
				t.Fatal("patient timezone does not match profile")
			}
			return
		}
	}
	t.Fatal("patient missing")
}
