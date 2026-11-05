package httpapi

import (
	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
	"net/http"
)

func (a *API) updateTreatment(w http.ResponseWriter, r *http.Request) {
	var req UpdateTreatmentRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.UpdateTreatment(r.Context(), application.UpdateTreatmentCommand{Mutation: mutation(r, req.OperationID), TreatmentID: r.PathValue("treatmentId"), ExpectedVersion: req.ExpectedVersion, Name: req.Name, StrengthLabel: req.StrengthLabel, Form: req.Form, PackageLabel: req.PackageLabel, Instructions: req.Instructions})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, treatmentResponse(out))
}
func (a *API) archiveTreatment(w http.ResponseWriter, r *http.Request) {
	var req ArchiveTreatmentRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.ArchiveTreatment(r.Context(), application.ArchiveTreatmentCommand{Mutation: mutation(r, req.OperationID), TreatmentID: r.PathValue("treatmentId"), ExpectedVersion: req.ExpectedVersion, Reason: req.Reason})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, treatmentResponse(out))
}
func (a *API) physicalCount(w http.ResponseWriter, r *http.Request) {
	var req PhysicalCountRequest
	if !decode(w, r, &req) {
		return
	}
	count, err := domain.ParseQuantity(req.CountedQuantity)
	if err != nil {
		resultError(w, r, err)
		return
	}
	expected, err := domain.ParseQuantity(req.ExpectedBalance)
	if err != nil {
		resultError(w, r, err)
		return
	}
	out, err := a.service.RecordPhysicalCount(r.Context(), application.PhysicalCountCommand{Mutation: mutation(r, req.OperationID), AccountID: r.PathValue("accountId"), CountedQuantity: count, ExpectedBalance: expected, Reason: req.Reason})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, PhysicalCountResponse{out.CountID, out.MovementID, out.Balance.String()})
}
func (a *API) movements(w http.ResponseWriter, r *http.Request) {
	items, next, err := a.service.InventoryMovements(r.Context(), actor(r), r.PathValue("accountId"), r.URL.Query().Get("cursor"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, Page[application.MovementView]{items, next})
}
