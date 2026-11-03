package httpapi

import (
	"medication-tracker/services/api/internal/application"
	"net/http"
	"strconv"
)

func (a *API) adherence(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	window := 60
	if q.Has("window_minutes") {
		var err error
		window, err = strconv.Atoi(q.Get("window_minutes"))
		if err != nil {
			resultError(w, r, application.ErrInvalid)
			return
		}
	}
	out, err := a.service.Adherence(r.Context(), actor(r), r.PathValue("patientId"), q.Get("from"), q.Get("to"), q.Get("treatment_id"), window)
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}

type StockThresholdRequest struct {
	OperationID  string `json:"client_operation_id"`
	ExpectedDays *int   `json:"expected_days"`
	Days         *int   `json:"days"`
}

func (a *API) stockThreshold(w http.ResponseWriter, r *http.Request) {
	var req StockThresholdRequest
	if !decode(w, r, &req) {
		return
	}
	if req.ExpectedDays == nil || req.Days == nil {
		resultError(w, r, application.ErrInvalid)
		return
	}
	out, err := a.service.SetStockThreshold(r.Context(), application.SetStockThresholdCommand{Mutation: mutation(r, req.OperationID), AccountID: r.PathValue("accountId"), ExpectedDays: *req.ExpectedDays, Days: *req.Days})
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
