package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"

	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/auth"
	"medication-tracker/services/api/internal/domain"
)

type contextKey int

const (
	actorKey contextKey = iota
	requestKey
	identityKey
)

type API struct {
	service     *application.Service
	verifier    auth.Verifier
	logger      *slog.Logger
	exportSlots chan struct{}
}

func NewAPI(ping func(context.Context) error, service *application.Service, verifier auth.Verifier, logger *slog.Logger) http.Handler {
	a := &API{service: service, verifier: verifier, logger: logger, exportSlots: make(chan struct{}, 2)}
	mux := http.NewServeMux()
	mux.Handle("GET /healthz", NewHandler(ping))
	mux.Handle("GET /readyz", NewHandler(ping))
	business := http.NewServeMux()
	business.HandleFunc("POST /v1/devices", a.registerDevice)
	business.HandleFunc("DELETE /v1/devices/{deviceId}", a.deleteDevice)
	business.HandleFunc("GET /v1/caregiver-links/{linkId}/alert-preferences", a.getAlertPreferences)
	business.HandleFunc("PUT /v1/caregiver-links/{linkId}/alert-preferences", a.setAlertPreferences)
	business.HandleFunc("GET /v1/me", a.me)
	business.HandleFunc("PUT /v1/me/profile", a.updateProfile)
	business.HandleFunc("PUT /v1/patients/{patientId}/profile", a.updateProfile)
	business.HandleFunc("GET /v1/me/export", a.exportAccount)
	business.HandleFunc("DELETE /v1/me", a.deleteAccount)
	business.HandleFunc("PATCH /v1/treatments/{treatmentId}", a.updateTreatment)
	business.HandleFunc("POST /v1/treatments/{treatmentId}/archive", a.archiveTreatment)
	business.HandleFunc("POST /v1/inventory/{accountId}/counts", a.physicalCount)
	business.HandleFunc("GET /v1/inventory/{accountId}/movements", a.movements)
	business.HandleFunc("GET /v1/inventory/{accountId}/pool-candidates", a.poolCandidates)
	business.HandleFunc("POST /v1/inventory-pools", a.createPool)
	business.HandleFunc("POST /v1/inventory-pools/{poolId}/leave", a.leavePool)
	business.HandleFunc("GET /v1/patients", a.patients)
	business.HandleFunc("GET /v1/families", a.families)
	business.HandleFunc("POST /v1/families", a.createFamily)
	business.HandleFunc("POST /v1/families/{familyId}/invitations", a.inviteToFamily)
	business.HandleFunc("DELETE /v1/families/{familyId}/members/{userId}", a.removeFamilyMember)
	business.HandleFunc("POST /v1/family-invitations/preview", a.previewFamilyInvitation)
	business.HandleFunc("POST /v1/family-invitations/accept", a.acceptFamilyInvitation)
	business.HandleFunc("GET /v1/patients/{patientId}/treatments", a.treatments)
	business.HandleFunc("POST /v1/patients/{patientId}/treatments", a.createTreatment)
	business.HandleFunc("POST /v1/treatments/{treatmentId}/schedule-revisions", a.reviseSchedule)
	business.HandleFunc("GET /v1/patients/{patientId}/adherence", a.adherence)
	business.HandleFunc("POST /v1/inventory/{accountId}/threshold", a.stockThreshold)
	business.HandleFunc("GET /v1/patients/{patientId}/doses", a.agenda)
	business.HandleFunc("POST /v1/doses/{doseId}/events", a.recordEvent)
	business.HandleFunc("POST /v1/doses/{doseId}/corrections", a.correctEvent)
	business.HandleFunc("GET /v1/patients/{patientId}/inventory", a.inventory)
	business.HandleFunc("POST /v1/inventory/{accountId}/movements", a.replenish)
	business.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fail(w, r, http.StatusNotFound, "not_found", "Resource not found")
	})
	mux.Handle("/v1/", a.authenticate(business))
	return a.middleware(mux)
}
func actor(r *http.Request) string { v, _ := r.Context().Value(actorKey).(string); return v }
func mutation(r *http.Request, id string) application.Mutation {
	return application.Mutation{ActorID: actor(r), OperationID: id}
}
func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func fail(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	id, _ := r.Context().Value(requestKey).(string)
	writeJSON(w, status, ErrorResponse{Code: code, Message: message, RequestID: id, Details: map[string]string{}})
}
func resultError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, application.ErrForbidden):
		fail(w, r, 403, "forbidden", "Operation is not permitted")
	case errors.Is(err, application.ErrInvalid):
		fail(w, r, 422, "invalid_input", "Input does not satisfy the contract")
	case errors.Is(err, application.ErrNotFound):
		fail(w, r, 404, "not_found", "Resource not found")
	case errors.Is(err, application.ErrConflict):
		fail(w, r, 409, "conflict", "Operation conflicts with current state")
	case errors.Is(err, context.DeadlineExceeded):
		fail(w, r, 504, "timeout", "Request timed out")
	default:
		fail(w, r, 500, "internal_error", "Request could not be completed")
	}
}
func decode(w http.ResponseWriter, r *http.Request, out any) bool {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		fail(w, r, 415, "unsupported_media_type", "Use application/json")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 65536)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			fail(w, r, 413, "payload_too_large", "Payload exceeds 65536 bytes")
		} else {
			fail(w, r, 400, "invalid_json", "Invalid JSON object")
		}
		return false
	}
	if len(strings.TrimSpace(string(data))) == 0 || strings.TrimSpace(string(data))[0] != '{' {
		fail(w, r, 400, "invalid_json", "Expected one JSON object")
		return false
	}
	d := json.NewDecoder(strings.NewReader(string(data)))
	d.DisallowUnknownFields()
	if err = d.Decode(out); err != nil {
		fail(w, r, 400, "invalid_json", "Invalid JSON object")
		return false
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		fail(w, r, 400, "invalid_json", "Expected one JSON object")
		return false
	}
	return true
}
func (a *API) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		values := r.Header.Values("Authorization")
		if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") || len(values[0]) > 16384 {
			fail(w, r, 401, "unauthenticated", "Valid bearer token required")
			return
		}
		raw := strings.TrimPrefix(values[0], "Bearer ")
		if raw == "" || strings.ContainsAny(raw, " \t\r\n") {
			fail(w, r, 401, "unauthenticated", "Valid bearer token required")
			return
		}
		uid, err := a.verifier.Verify(r.Context(), raw)
		if err != nil {
			fail(w, r, 401, "unauthenticated", "Valid bearer token required")
			return
		}
		id, err := a.service.ResolveUser(r.Context(), uid)
		if err != nil {
			resultError(w, r, err)
			return
		}
		ctx := context.WithValue(context.WithValue(r.Context(), actorKey, id), identityKey, uid)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
func (a *API) me(w http.ResponseWriter, r *http.Request) {
	items, next, err := a.service.Patients(r.Context(), actor(r), r.URL.Query().Get("cursor"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	profile, err := a.service.Profile(r.Context(), actor(r))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, MeResponse{Profile: profile, UserID: actor(r), Patients: items, NextCursor: next})
}
func (a *API) patients(w http.ResponseWriter, r *http.Request) {
	items, next, err := a.service.Patients(r.Context(), actor(r), r.URL.Query().Get("cursor"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, Page[application.PatientAccess]{Items: items, NextCursor: next})
}
func (a *API) treatments(w http.ResponseWriter, r *http.Request) {
	items, next, err := a.service.Treatments(r.Context(), actor(r), r.PathValue("patientId"), r.URL.Query().Get("cursor"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	out := []Treatment{}
	for _, v := range items {
		out = append(out, Treatment{TreatmentResponse: TreatmentResponse{v.ID, v.RevisionID, v.AccountID, v.Version}, ArchivedAt: v.ArchivedAt, MedicationID: v.MedicationID, Name: v.Name, StrengthLabel: v.StrengthLabel, Form: v.Form, PackageLabel: v.PackageLabel, Instructions: v.Instructions, StartsOn: v.StartsOn, EndsOn: v.EndsOn, Unit: v.Unit, Schedule: scheduleDTO(v.Schedule)})
	}
	writeJSON(w, 200, Page[Treatment]{out, next})
}
func (a *API) createTreatment(w http.ResponseWriter, r *http.Request) {
	var req CreateTreatmentRequest
	if !decode(w, r, &req) {
		return
	}
	schedule, err := req.Schedule.domain()
	if err != nil {
		resultError(w, r, err)
		return
	}
	quantity, err := domain.ParseQuantity(req.InitialStock)
	if err != nil {
		resultError(w, r, err)
		return
	}
	if len(req.StrengthLabel) > 200 || len(req.Form) > 200 || len(req.PackageLabel) > 200 || len(req.Instructions) > 4000 {
		resultError(w, r, application.ErrInvalid)
		return
	}
	out, err := a.service.CreateTreatment(r.Context(), application.CreateTreatmentCommand{Mutation: mutation(r, req.OperationID), PatientID: r.PathValue("patientId"), Name: req.Name, StrengthLabel: req.StrengthLabel, Form: req.Form, PackageLabel: req.PackageLabel, Instructions: req.Instructions, Unit: req.Unit, InitialStock: quantity, StartsOn: req.StartsOn, EndsOn: req.EndsOn, Schedule: schedule})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 201, treatmentResponse(out))
}
func (a *API) reviseSchedule(w http.ResponseWriter, r *http.Request) {
	var req ReviseScheduleRequest
	if !decode(w, r, &req) {
		return
	}
	schedule, err := req.Schedule.domain()
	if err != nil {
		resultError(w, r, err)
		return
	}
	out, err := a.service.ReviseSchedule(r.Context(), application.ReviseScheduleCommand{Mutation: mutation(r, req.OperationID), TreatmentID: r.PathValue("treatmentId"), ExpectedVersion: req.ExpectedVersion, EffectiveFrom: req.EffectiveFrom, Schedule: schedule})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 201, treatmentResponse(out))
}
func (a *API) agenda(w http.ResponseWriter, r *http.Request) {
	items, next, err := a.service.FilteredAgenda(r.Context(), actor(r), r.PathValue("patientId"), r.URL.Query().Get("from"), r.URL.Query().Get("to"), r.URL.Query().Get("cursor"), r.URL.Query().Get("treatment_id"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, Page[application.DoseView]{items, next})
}
func (a *API) recordEvent(w http.ResponseWriter, r *http.Request) {
	var req DoseEventRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.RecordDoseEvent(r.Context(), application.RecordDoseEventCommand{Mutation: mutation(r, req.OperationID), DoseID: r.PathValue("doseId"), ExpectedVersion: req.ExpectedVersion, State: req.EventType, OccurredAt: req.OccurredAt})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, doseResponse(out))
}
func (a *API) correctEvent(w http.ResponseWriter, r *http.Request) {
	var req CorrectionRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.CorrectDoseEvent(r.Context(), application.CorrectDoseEventCommand{Mutation: mutation(r, req.OperationID), DoseID: r.PathValue("doseId"), ExpectedVersion: req.ExpectedVersion, State: req.EventType, OccurredAt: req.OccurredAt, CorrectsEventID: req.CorrectsEventID, Reason: req.Reason})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, doseResponse(out))
}
func (a *API) inventory(w http.ResponseWriter, r *http.Request) {
	items, next, err := a.service.Inventory(r.Context(), actor(r), r.PathValue("patientId"), r.URL.Query().Get("cursor"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	out := []Projection{}
	for _, v := range items {
		p := v.Projection
		out = append(out, Projection{v.AccountID, v.TreatmentID, p.Balance.String(), p.Unit, p.From, p.Through, p.FirstUncoveredAt, p.ScheduledQuantity.String(), p.LowStockDaysThreshold, p.Timezone, p.ReplenishOn, p.LowStock, v.Pool})
	}
	writeJSON(w, 200, Page[Projection]{out, next})
}
func (a *API) replenish(w http.ResponseWriter, r *http.Request) {
	var req ReplenishRequest
	if !decode(w, r, &req) {
		return
	}
	q, err := domain.ParseQuantity(req.Quantity)
	if err != nil {
		resultError(w, r, err)
		return
	}
	out, err := a.service.ReplenishInventory(r.Context(), application.ReplenishInventoryCommand{Mutation: mutation(r, req.OperationID), AccountID: r.PathValue("accountId"), Quantity: q})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, InventoryResponse{out.MovementID, out.Balance.String()})
}

func (a *API) updateProfile(w http.ResponseWriter, r *http.Request) {
	var req UpdateProfileRequest
	if !decode(w, r, &req) {
		return
	}
	patient := r.PathValue("patientId")
	if patient == "" {
		patient = actor(r)
	}
	out, err := a.service.UpdateProfile(r.Context(), application.UpdateProfileCommand{Mutation: mutation(r, req.OperationID), PatientID: patient, ExpectedVersion: req.ExpectedVersion, DisplayName: req.DisplayName})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
