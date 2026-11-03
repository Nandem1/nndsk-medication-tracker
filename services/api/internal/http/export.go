package httpapi

import (
	"errors"
	"net/http"

	"medication-tracker/services/api/internal/application"
)

func (a *API) exportAccount(w http.ResponseWriter, r *http.Request) {
	if r.URL.RawQuery != "" {
		fail(w, r, 400, "invalid_input", "Account export does not accept query parameters")
		return
	}
	select {
	case a.exportSlots <- struct{}{}:
		defer func() { <-a.exportSlots }()
	default:
		w.Header().Set("Retry-After", "5")
		fail(w, r, 429, "rate_limited", "Another export is in progress; retry later")
		return
	}
	out, err := a.service.ExportAccount(r.Context(), actor(r))
	if errors.Is(err, application.ErrExportTooLarge) {
		fail(w, r, 422, "export_too_large", "Account exceeds the synchronous export limit; request an assisted export")
		return
	}
	if err != nil {
		resultError(w, r, err)
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="medication-account.json"`)
	writeJSON(w, 200, out)
}
