package httpapi

import (
	"net/http"

	"medication-tracker/services/api/internal/application"
)

func (a *API) families(w http.ResponseWriter, r *http.Request) {
	items, err := a.service.Families(r.Context(), actor(r))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, Page[application.Family]{items, ""})
}
func (a *API) createFamily(w http.ResponseWriter, r *http.Request) {
	var req CreateFamilyRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.CreateFamily(r.Context(), application.CreateFamilyCommand{Mutation: mutation(r, req.OperationID), Name: req.Name})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 201, out)
}
func (a *API) inviteToFamily(w http.ResponseWriter, r *http.Request) {
	var req FamilyInvitationRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.InviteToFamily(r.Context(), application.InviteToFamilyCommand{Mutation: mutation(r, req.OperationID), FamilyID: r.PathValue("familyId"), Role: req.Role, PatientNameHint: req.PatientNameHint})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 201, out)
}
func (a *API) removeFamilyMember(w http.ResponseWriter, r *http.Request) {
	if err := a.service.RemoveFamilyMember(r.Context(), actor(r), r.PathValue("familyId"), r.PathValue("userId")); err != nil {
		resultError(w, r, err)
		return
	}
	w.WriteHeader(204)
}
func (a *API) previewFamilyInvitation(w http.ResponseWriter, r *http.Request) {
	var req PreviewInvitationRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.PreviewFamilyInvitation(r.Context(), actor(r), req.Token)
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
func (a *API) acceptFamilyInvitation(w http.ResponseWriter, r *http.Request) {
	var req AcceptInvitationRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.AcceptFamilyInvitation(r.Context(), application.AcceptFamilyInvitationCommand{Mutation: mutation(r, req.OperationID), Token: req.Token})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
