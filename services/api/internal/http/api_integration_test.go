//go:build integration

package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
)

type apiFixture struct {
	t                            *testing.T
	service                      *application.Service
	pool                         *pgxpool.Pool
	server                       *httptest.Server
	patient, caregiver, stranger string
}

func newAPIFixture(t *testing.T) *apiFixture {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Fatal("TEST_DATABASE_URL required")
	}
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal("cannot configure test pool")
	}
	t.Cleanup(pool.Close)
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	service := application.New(pool, func() time.Time { return now })
	identities := testVerifier{}
	ids := []string{}
	for _, name := range []string{"patient", "caregiver", "stranger"} {
		uid := domain.NewID()
		identities[name] = uid
		id, err := service.ResolveUser(context.Background(), uid)
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	server := httptest.NewServer(NewAPI(pool.Ping, service, identities, nil))
	t.Cleanup(server.Close)
	return &apiFixture{t, service, pool, server, ids[0], ids[1], ids[2]}
}
func (f *apiFixture) request(actor, method, path string, body any, want int, out any) {
	f.t.Helper()
	var encoded []byte
	if body != nil {
		var err error
		encoded, err = json.Marshal(body)
		if err != nil {
			f.t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, f.server.URL+path, bytes.NewReader(encoded))
	if err != nil {
		f.t.Fatal(err)
	}
	if actor != "" {
		req.Header.Set("Authorization", "Bearer "+actor)
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := f.server.Client().Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		f.t.Fatal(err)
	}
	if response.StatusCode != want {
		f.t.Fatalf("%s %s actor=%s: got %d want %d body=%s", method, path, actor, response.StatusCode, want, data)
	}
	if out != nil {
		if err = json.Unmarshal(data, out); err != nil {
			f.t.Fatal(err)
		}
	}
}
func (f *apiFixture) invite(scopes []application.Scope) application.Link {
	var invite application.Invitation
	f.request("caregiver", "POST", "/v1/invitations", InvitationRequest{domain.NewID(), scopes}, 201, &invite)
	var link application.Link
	request := AcceptInvitationRequest{domain.NewID(), invite.Token}
	f.request("patient", "POST", "/v1/invitations/accept", request, 200, &link)
	f.request("patient", "POST", "/v1/invitations/accept", request, 200, nil)
	f.request("stranger", "POST", "/v1/invitations/accept", AcceptInvitationRequest{domain.NewID(), invite.Token}, 409, nil)
	return link
}
func (f *apiFixture) treatment(actor string) TreatmentResponse {
	req := CreateTreatmentRequest{OperationID: domain.NewID(), Name: "Synthetic medication", Unit: "tablet", InitialStock: "10.000", StartsOn: "2026-11-01", Schedule: Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []Slot{{"08:00", "0.500"}}}}
	var out TreatmentResponse
	f.request(actor, "POST", "/v1/patients/"+f.patient+"/treatments", req, 201, &out)
	f.request(actor, "POST", "/v1/patients/"+f.patient+"/treatments", req, 201, nil)
	return out
}
func (f *apiFixture) dose() application.DoseView {
	var page Page[application.DoseView]
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/doses?from=2026-11-01&to=2026-11-02", nil, 200, &page)
	if len(page.Items) != 1 {
		f.t.Fatal(page)
	}
	if page.Items[0].State != "unconfirmed" || page.Items[0].Quantity != "0.500" {
		f.t.Fatal(page.Items[0])
	}
	return page.Items[0]
}
func TestAPIPatientCaregiverScopesAndRevocation(t *testing.T) {
	f := newAPIFixture(t)
	tr := f.treatment("patient")
	dose := f.dose()
	f.request("", "GET", "/v1/me", nil, 401, nil)
	var me MeResponse
	f.request("patient", "GET", "/v1/me", nil, 200, &me)
	if me.UserID != f.patient || len(me.Patients) != 1 {
		t.Fatal(me)
	}
	f.request("caregiver", "GET", "/v1/patients/"+f.patient+"/treatments", nil, 404, nil)
	link := f.invite([]application.Scope{application.ScopeRead})
	f.request("caregiver", "GET", "/v1/patients/"+f.patient+"/treatments", nil, 200, nil)
	event := DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EventType: domain.Taken}
	f.request("caregiver", "POST", "/v1/doses/"+dose.ID+"/events", event, 404, nil)
	f.request("caregiver", "POST", "/v1/inventory/"+tr.AccountID+"/movements", ReplenishRequest{domain.NewID(), "1.000"}, 404, nil)
	f.request("stranger", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 404, nil)
	f.request("patient", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 204, nil)
	f.request("patient", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 204, nil)
	link = f.invite([]application.Scope{application.ScopeRead, application.ScopeDoses})
	var result DoseResponse
	f.request("caregiver", "POST", "/v1/doses/"+dose.ID+"/events", event, 200, &result)
	if result.Balance != "9.500" || result.State != domain.Taken {
		t.Fatal(result)
	}
	f.request("caregiver", "POST", "/v1/doses/"+dose.ID+"/events", event, 200, nil)
	correction := CorrectionRequest{DoseEventRequest: DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 2, EventType: domain.Skipped}, CorrectsEventID: result.EventID, Reason: "Synthetic correction"}
	f.request("patient", "POST", "/v1/doses/"+dose.ID+"/corrections", correction, 200, &result)
	if result.Balance != "10.000" {
		t.Fatal(result)
	}
	f.request("patient", "DELETE", "/v1/caregiver-links/"+link.ID, nil, 204, nil)
	f.request("caregiver", "POST", "/v1/doses/"+dose.ID+"/events", event, 404, nil)
	for _, suffix := range []string{"treatments", "doses?from=2026-11-01&to=2026-11-02", "inventory"} {
		f.request("caregiver", "GET", "/v1/patients/"+f.patient+"/"+suffix, nil, 404, nil)
		f.request("stranger", "GET", "/v1/patients/"+f.patient+"/"+suffix, nil, 404, nil)
	}
	f.invite([]application.Scope{application.ScopeRead, application.ScopeInventory})
	f.request("caregiver", "POST", "/v1/inventory/"+tr.AccountID+"/movements", ReplenishRequest{domain.NewID(), "0.125"}, 200, nil)
	var stock Page[Projection]
	f.request("caregiver", "GET", "/v1/patients/"+f.patient+"/inventory", nil, 200, &stock)
	if len(stock.Items) != 1 || stock.Items[0].Balance != "10.125" {
		t.Fatal(stock)
	}
}
func TestAPIBOLAAndValidation(t *testing.T) {
	f := newAPIFixture(t)
	tr := f.treatment("patient")
	dose := f.dose()
	f.request("stranger", "POST", "/v1/doses/"+dose.ID+"/events", DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EventType: domain.Skipped}, 404, nil)
	f.request("stranger", "POST", "/v1/doses/"+dose.ID+"/corrections", CorrectionRequest{DoseEventRequest: DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EventType: domain.Skipped}, CorrectsEventID: domain.NewID(), Reason: "Synthetic"}, 404, nil)
	f.request("stranger", "POST", "/v1/inventory/"+tr.AccountID+"/movements", ReplenishRequest{domain.NewID(), "1.000"}, 404, nil)
	f.request("stranger", "POST", "/v1/treatments/"+tr.TreatmentID+"/schedule-revisions", ReviseScheduleRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), Schedule: Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{1}, Slots: []Slot{{"08:00", "0.500"}}}}, 404, nil)
	f.request("patient", "POST", "/v1/doses/"+dose.ID+"/events", map[string]any{"actor_id": f.stranger}, 400, nil)
	f.request("patient", "POST", "/v1/inventory/"+tr.AccountID+"/movements", ReplenishRequest{domain.NewID(), "0.0001"}, 422, nil)
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/doses?from=2026-11-01&to=2027-11-02", nil, 422, nil)
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/treatments?cursor=invalid", nil, 422, nil)
	f.request("patient", "GET", "/v1/patients/not-a-uuid/inventory", nil, 422, nil)
	f.request("caregiver", "POST", "/v1/invitations", InvitationRequest{domain.NewID(), []application.Scope{application.ScopeDoses}}, 422, nil)
	f.invite([]application.Scope{application.ScopeRead, application.ScopeTreatments})
	f.treatment("caregiver")
}
func TestAPIConcurrentAcceptanceAndExpiry(t *testing.T) {
	f := newAPIFixture(t)
	ctx := context.Background()
	invite, err := f.service.CreateInvitation(ctx, application.Mutation{ActorID: f.caregiver, OperationID: domain.NewID()}, []application.Scope{application.ScopeRead})
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for _, actor := range []string{"patient", "stranger"} {
		wg.Add(1)
		go func(actor string) {
			defer wg.Done()
			body, _ := json.Marshal(AcceptInvitationRequest{domain.NewID(), invite.Token})
			req, _ := http.NewRequest("POST", f.server.URL+"/v1/invitations/accept", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+actor)
			req.Header.Set("Content-Type", "application/json")
			response, e := f.server.Client().Do(req)
			if e != nil {
				t.Error(e)
				return
			}
			defer response.Body.Close()
			codes <- response.StatusCode
		}(actor)
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatal(counts)
	}
	expired, err := f.service.CreateInvitation(ctx, application.Mutation{ActorID: f.caregiver, OperationID: domain.NewID()}, []application.Scope{application.ScopeRead})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.pool.Exec(ctx, `UPDATE invitations SET created_at=created_at-interval '2 days',expires_at=expires_at-interval '2 days' WHERE id=$1`, expired.ID); err != nil {
		t.Fatal(err)
	}
	f.request("patient", "POST", "/v1/invitations/accept", AcceptInvitationRequest{domain.NewID(), expired.Token}, 409, nil)
	self, err := f.service.CreateInvitation(ctx, application.Mutation{ActorID: f.caregiver, OperationID: domain.NewID()}, []application.Scope{application.ScopeRead})
	if err != nil {
		t.Fatal(err)
	}
	f.request("caregiver", "POST", "/v1/invitations/accept", AcceptInvitationRequest{domain.NewID(), self.Token}, 409, nil)
}
func TestAPIPaginationAndDoseRetries(t *testing.T) {
	f := newAPIFixture(t)
	tr := f.treatment("patient")
	ctx := context.Background()
	schedule := domain.Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []domain.Slot{{Time: "01:00", Quantity: 500}, {Time: "02:00", Quantity: 500}, {Time: "03:00", Quantity: 500}, {Time: "04:00", Quantity: 500}}}
	_, err := f.service.ReviseSchedule(ctx, application.ReviseScheduleCommand{Mutation: application.Mutation{ActorID: f.patient, OperationID: domain.NewID()}, TreatmentID: tr.TreatmentID, ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), Schedule: schedule})
	if err != nil {
		t.Fatal(err)
	}
	var page Page[application.DoseView]
	path := "/v1/patients/" + f.patient + "/doses?from=2026-11-03&to=2026-12-03"
	f.request("patient", "GET", path, nil, 200, &page)
	if len(page.Items) != 100 || page.NextCursor == "" {
		t.Fatal(len(page.Items), page.NextCursor)
	}
	seen := map[string]bool{}
	for _, d := range page.Items {
		seen[d.ID] = true
	}
	f.request("patient", "GET", path+"&cursor="+page.NextCursor, nil, 200, &page)
	if len(page.Items) != 20 || page.NextCursor != "" {
		t.Fatal(len(page.Items), page.NextCursor)
	}
	for _, d := range page.Items {
		if seen[d.ID] {
			t.Fatal("duplicate page item")
		}
	}
	var first Page[application.DoseView]
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/doses?from=2026-11-01&to=2026-11-02", nil, 200, &first)
	id := first.Items[0].ID
	command := DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EventType: domain.Taken}
	var results [8]DoseResponse
	var wg sync.WaitGroup
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			f.request("patient", "POST", "/v1/doses/"+id+"/events", command, 200, &results[i])
		}(i)
	}
	wg.Wait()
	for _, r := range results {
		if r != results[0] || r.Balance != "9.500" {
			t.Fatal(results)
		}
	}
}

func TestHTTPWriteScopeBindingsAndDeniedWrites(t *testing.T) {
	f := newAPIFixture(t)
	tr := f.treatment("patient")
	dose := f.dose()
	ctx := context.Background()
	req := CreateTreatmentRequest{OperationID: domain.NewID(), Name: "Synthetic", Unit: "tablet", InitialStock: "0", StartsOn: "2026-11-01", Schedule: Schedule{Timezone: "UTC", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []Slot{{"08:00", "0.500"}}}}
	f.request("stranger", "POST", "/v1/patients/"+f.patient+"/treatments", req, 404, nil)
	f.invite([]application.Scope{application.ScopeRead})
	f.request("caregiver", "POST", "/v1/patients/"+f.patient+"/treatments", req, 404, nil)
	f.request("caregiver", "POST", "/v1/doses/"+dose.ID+"/events", DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EventType: domain.Taken}, 404, nil)
	f.request("caregiver", "POST", "/v1/inventory/"+tr.AccountID+"/movements", ReplenishRequest{domain.NewID(), "2.000"}, 404, nil)
	var count int
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM dose_events WHERE dose_occurrence_id=$1`, dose.ID).Scan(&count); err != nil || count != 0 {
		t.Fatal(count, err)
	}
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM inventory_movements WHERE inventory_account_id=$1`, tr.AccountID).Scan(&count); err != nil || count != 1 {
		t.Fatal(count, err)
	}
	f.invite([]application.Scope{application.ScopeRead, application.ScopeTreatments, application.ScopeDoses})
	revision := ReviseScheduleRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EffectiveFrom: time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), Schedule: req.Schedule}
	var revised TreatmentResponse
	f.request("caregiver", "POST", "/v1/treatments/"+tr.TreatmentID+"/schedule-revisions", revision, 201, &revised)
	if revised.Version != 2 {
		t.Fatal(revised)
	}
	var result DoseResponse
	f.request("patient", "POST", "/v1/doses/"+dose.ID+"/events", DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 1, EventType: domain.Taken}, 200, &result)
	correction := CorrectionRequest{DoseEventRequest: DoseEventRequest{OperationID: domain.NewID(), ExpectedVersion: 2, EventType: domain.Skipped}, CorrectsEventID: result.EventID, Reason: "Synthetic correction"}
	f.request("caregiver", "POST", "/v1/doses/"+dose.ID+"/corrections", correction, 200, &result)
	if result.Balance != "10.000" || result.Version != 3 {
		t.Fatal(result)
	}
}

func TestAgendaRejectDSTOnlyInsideRequestedRange(t *testing.T) {
	f := newAPIFixture(t)
	req := CreateTreatmentRequest{OperationID: domain.NewID(), Name: "Synthetic DST", Unit: "tablet", InitialStock: "0", StartsOn: "2026-09-01", Schedule: Schedule{Timezone: "America/Santiago", Policy: domain.RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []Slot{{"00:30", "0.500"}}}}
	f.request("patient", "POST", "/v1/patients/"+f.patient+"/treatments", req, 201, nil)
	var page Page[application.DoseView]
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/doses?from=2026-09-01&to=2026-09-02", nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].LocalDate != "2026-09-01" {
		t.Fatal(page)
	}
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/doses?from=2026-09-06&to=2026-09-07", nil, 422, nil)
}
