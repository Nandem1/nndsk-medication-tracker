//go:build integration

package httpapi

import (
	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
	"testing"
	"time"
)

func TestPortalHTTPPermissions(t *testing.T) {
	f := newAPIFixture(t)
	family := f.family("organizer")
	var invite application.Invitation
	f.request("organizer", "POST", "/v1/families/"+family+"/invitations", FamilyInvitationRequest{OperationID: domain.NewID(), Role: application.RolePatient}, 201, &invite)
	var preview application.FamilyInvitationPreview
	f.request("patient", "POST", "/v1/family-invitations/preview", PreviewInvitationRequest{invite.Token}, 200, &preview)
	if preview.Role != application.RolePatient || len(preview.Members) != 1 {
		t.Fatal(preview)
	}
	f.request("patient", "POST", "/v1/family-invitations/accept", AcceptInvitationRequest{domain.NewID(), invite.Token}, 200, nil)
	f.join("organizer", "caregiver", family, application.RoleObserver)
	link := familyLink{FamilyID: family}
	var families Page[application.Family]
	f.request("patient", "GET", "/v1/families", nil, 200, &families)
	if len(families.Items) != 1 || len(families.Items[0].Members) != 3 {
		t.Fatal(families)
	}
	var tr TreatmentResponse
	f.request("patient", "POST", "/v1/patients/"+f.patient+"/treatments", CreateTreatmentRequest{OperationID: domain.NewID(), Name: "Synthetic portal", Unit: "tablet", InitialStock: "5.000", StartsOn: "2026-11-01", Schedule: Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []Slot{{Time: "08:00", Quantity: "0.5"}}}}, 201, &tr)
	count := PhysicalCountRequest{domain.NewID(), "4.5", "5.000", "Synthetic count"}
	f.request("caregiver", "POST", "/v1/inventory/"+tr.AccountID+"/counts", count, 404, nil)
	f.request("caregiver", "PATCH", "/v1/treatments/"+tr.TreatmentID, UpdateTreatmentRequest{OperationID: domain.NewID(), ExpectedVersion: 1, Name: "Denied"}, 404, nil)
	f.request("caregiver", "POST", "/v1/treatments/"+tr.TreatmentID+"/archive", ArchiveTreatmentRequest{domain.NewID(), 1, "Denied"}, 404, nil)
	f.request("patient", "POST", "/v1/inventory/"+tr.AccountID+"/counts", count, 200, nil)
	f.request("patient", "POST", "/v1/inventory/"+tr.AccountID+"/counts", count, 200, nil)
	var movements Page[application.MovementView]
	f.request("caregiver", "GET", "/v1/inventory/"+tr.AccountID+"/movements", nil, 200, &movements)
	if len(movements.Items) != 2 {
		t.Fatal(movements)
	}
	f.leave(link)
	f.request("caregiver", "GET", "/v1/inventory/"+tr.AccountID+"/movements", nil, 404, nil)
	f.request("stranger", "GET", "/v1/families", nil, 200, &families)
	if len(families.Items) != 0 {
		t.Fatal(families)
	}
}
