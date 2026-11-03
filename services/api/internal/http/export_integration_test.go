//go:build integration

package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"

	"medication-tracker/services/api/internal/application"
)

func TestAccountExportHTTPBoundary(t *testing.T) {
	f := newAPIFixture(t)
	f.treatment("patient")
	f.invite([]application.Scope{application.ScopeRead})
	f.request("", "GET", "/v1/me/export", nil, 401, nil)
	f.request("caregiver", "GET", "/v1/me/export?patient_id="+f.patient, nil, 400, nil)
	f.request("caregiver", "GET", "/v1/patients/"+f.patient+"/export", nil, 404, nil)
	var out application.AccountExport
	f.request("caregiver", "GET", "/v1/me/export", nil, 200, &out)
	if out.Profile.UserID != f.caregiver || len(out.Treatments) != 0 || len(out.CaregiverLinks) != 1 {
		t.Fatal("caregiver exported patient health")
	}
	req, err := http.NewRequest("GET", f.server.URL+"/v1/me/export", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer patient")
	response, err := f.server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || response.Header.Get("Cache-Control") != "no-store" || response.Header.Get("Content-Disposition") != `attachment; filename="medication-account.json"` {
		t.Fatal(response.StatusCode, response.Header)
	}
	if err = json.NewDecoder(response.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Profile.UserID != f.patient || len(out.Treatments) != 1 {
		t.Fatal("own health missing")
	}
}
