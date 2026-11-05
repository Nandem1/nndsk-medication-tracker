package httpapi

import (
	"net/http"

	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
)

func (a *API) poolCandidates(w http.ResponseWriter, r *http.Request) {
	items, err := a.service.PoolCandidates(r.Context(), actor(r), r.PathValue("accountId"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, Page[application.PoolCandidate]{items, ""})
}
func (a *API) createPool(w http.ResponseWriter, r *http.Request) {
	var req CreatePoolRequest
	if !decode(w, r, &req) {
		return
	}
	counted, err := domain.ParseQuantity(req.CountedQuantity)
	if err != nil {
		resultError(w, r, err)
		return
	}
	out, err := a.service.CreateInventoryPool(r.Context(), application.CreatePoolCommand{Mutation: mutation(r, req.OperationID), AccountIDs: req.AccountIDs, CountedAccountID: req.CountedAccountID, CountedQuantity: counted})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
func (a *API) leavePool(w http.ResponseWriter, r *http.Request) {
	var req LeavePoolRequest
	if !decode(w, r, &req) {
		return
	}
	out, err := a.service.LeaveInventoryPool(r.Context(), application.LeavePoolCommand{Mutation: mutation(r, req.OperationID), PoolID: r.PathValue("poolId"), AccountID: req.AccountID})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
