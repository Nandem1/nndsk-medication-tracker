//go:build integration

package httpapi

import (
	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
	"testing"
)

func TestF6DeviceHTTPAuthorization(t *testing.T) {
	f := newAPIFixture(t)
	id := domain.NewID()
	body := application.DeviceInput{ID: id, Platform: "fcm", Token: "synthetic-" + id, Permission: "granted"}
	var out application.Device
	f.request("", "POST", "/v1/devices", body, 401, nil)
	f.request("caregiver", "POST", "/v1/devices", body, 200, &out)
	if out.ID != id || out.Permission != "granted" {
		t.Fatal(out)
	}
	f.request("caregiver", "POST", "/v1/devices", body, 200, nil)
	f.request("stranger", "POST", "/v1/devices", body, 404, nil)
	f.request("stranger", "DELETE", "/v1/devices/"+id, nil, 404, nil)
	f.request("caregiver", "DELETE", "/v1/devices/"+id, nil, 204, nil)
	f.request("caregiver", "DELETE", "/v1/devices/"+id, nil, 204, nil)
	f.request("caregiver", "PUT", "/v1/caregiver-links/"+domain.NewID()+"/alert-preferences", application.AlertPreferences{MinIntervalMinutes: 15, Timezone: "UTC"}, 404, nil)
}

func TestF6PreferenceHTTPConsent(t *testing.T) {
	f := newAPIFixture(t)
	var invitation application.Invitation
	var link application.Link
	f.request("caregiver", "POST", "/v1/invitations", map[string]any{"client_operation_id": domain.NewID(), "scopes": []string{"read"}}, 201, &invitation)
	f.request("patient", "POST", "/v1/invitations/accept", map[string]any{"client_operation_id": domain.NewID(), "token": invitation.Token}, 200, &link)
	path := "/v1/caregiver-links/" + link.ID + "/alert-preferences"
	var prefs application.AlertPreferences
	f.request("caregiver", "GET", path, nil, 200, &prefs)
	if prefs.UnconfirmedDelayMinutes != nil || prefs.StockEnabled {
		t.Fatal("alerts enabled without choice")
	}
	delay := 60
	prefs.UnconfirmedDelayMinutes = &delay
	prefs.Timezone = "America/Santiago"
	f.request("stranger", "PUT", path, prefs, 404, nil)
	f.request("patient", "PUT", path, prefs, 404, nil)
	f.request("caregiver", "PUT", path, prefs, 200, nil)
	var got application.AlertPreferences
	f.request("caregiver", "GET", path, nil, 200, &got)
	if got.UnconfirmedDelayMinutes == nil || *got.UnconfirmedDelayMinutes != 60 {
		t.Fatal(got)
	}
	f.request("patient", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 204, nil)
	f.request("caregiver", "GET", path, nil, 404, nil)
}
