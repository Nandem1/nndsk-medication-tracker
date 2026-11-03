//go:build integration

package httpapi

import (
	"context"
	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
	"testing"
	"time"
)

func TestF7ReportingHTTPAuthorizationAndThreshold(t *testing.T) {
	f := newAPIFixture(t)
	link := f.invite([]application.Scope{application.ScopeRead})
	tr, err := f.service.CreateTreatment(context.Background(), application.CreateTreatmentCommand{Mutation: application.Mutation{ActorID: f.patient, OperationID: domain.NewID()}, PatientID: f.patient, Name: "Synthetic F7", Unit: "tablet", StartsOn: "2026-11-01", Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}}}})
	if err != nil {
		t.Fatal(err)
	}
	path := "/v1/patients/" + f.patient + "/adherence?from=2026-11-01&to=2026-12-02"
	f.request("", "GET", path, nil, 401, nil)
	f.request("stranger", "GET", path, nil, 404, nil)
	var report application.AdherenceReport
	f.request("caregiver", "GET", path, nil, 200, &report)
	if report.Summary.Evaluable != 2 || report.Summary.Unconfirmed != 2 || len(report.Days) != 31 || report.WindowMinutes != 60 {
		t.Fatal(report)
	}
	for _, suffix := range []string{"&window_minutes=-1", "&window_minutes=abc", "&window_minutes=1441", "&treatment_id=invalid"} {
		f.request("patient", "GET", path+suffix, nil, 422, nil)
	}
	f.request("patient", "GET", path+"&treatment_id="+domain.NewID(), nil, 404, nil)
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/doses?from=2026-11-01&to=2026-12-02&treatment_id="+tr.TreatmentID, nil, 200, nil)
	thresholdPath := "/v1/inventory/" + tr.AccountID + "/threshold"
	body := map[string]any{"client_operation_id": domain.NewID(), "expected_days": 5, "days": 10}
	f.request("caregiver", "POST", thresholdPath, body, 404, nil)
	f.request("stranger", "POST", thresholdPath, body, 404, nil)
	f.request("patient", "POST", thresholdPath, body, 200, nil)
	f.request("patient", "POST", thresholdPath, body, 200, nil)
	body["client_operation_id"] = domain.NewID()
	f.request("patient", "POST", thresholdPath, body, 409, nil)
	f.request("patient", "POST", thresholdPath, map[string]any{"client_operation_id": domain.NewID(), "days": 1}, 422, nil)
	f.request("patient", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 204, nil)
	f.request("caregiver", "GET", path, nil, 404, nil)
}

func TestF7ForeignTreatmentAndRevokedThresholdReplay(t *testing.T) {
	f := newAPIFixture(t)
	link := f.invite([]application.Scope{application.ScopeRead, application.ScopeInventory})
	owned := f.treatment("patient")
	foreign, err := f.service.CreateTreatment(context.Background(), application.CreateTreatmentCommand{
		Mutation:  application.Mutation{ActorID: f.stranger, OperationID: domain.NewID()},
		PatientID: f.stranger, Name: "Synthetic foreign treatment", Unit: "tablet", StartsOn: "2026-11-01",
		Schedule: domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "08:00", Quantity: 500}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, resource := range []string{"adherence", "doses"} {
		path := "/v1/patients/" + f.patient + "/" + resource + "?from=2026-11-01&to=2026-11-03&treatment_id=" + foreign.TreatmentID
		f.request("patient", "GET", path, nil, 404, nil)
		f.request("caregiver", "GET", path, nil, 404, nil)
	}
	path := "/v1/inventory/" + owned.AccountID + "/threshold"
	body := map[string]any{"client_operation_id": domain.NewID(), "expected_days": 5, "days": 10}
	f.request("caregiver", "POST", path, body, 200, nil)
	f.request("patient", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 204, nil)
	f.request("caregiver", "POST", path, body, 404, nil)
}
