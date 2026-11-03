package httpapi

import (
	"net/http"

	"medication-tracker/services/api/internal/application"
)

func (a *API) registerDevice(w http.ResponseWriter, r *http.Request) {
	var in application.DeviceInput
	if !decode(w, r, &in) {
		return
	}
	out, err := a.service.RegisterDevice(r.Context(), actor(r), in)
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
func (a *API) deleteDevice(w http.ResponseWriter, r *http.Request) {
	if err := a.service.DeleteDevice(r.Context(), actor(r), r.PathValue("deviceId")); err != nil {
		resultError(w, r, err)
		return
	}
	w.WriteHeader(204)
}
func (a *API) getAlertPreferences(w http.ResponseWriter, r *http.Request) {
	out, err := a.service.GetAlertPreferences(r.Context(), actor(r), r.PathValue("linkId"))
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
func (a *API) setAlertPreferences(w http.ResponseWriter, r *http.Request) {
	var in application.AlertPreferences
	if !decode(w, r, &in) {
		return
	}
	out, err := a.service.SetAlertPreferences(r.Context(), actor(r), r.PathValue("linkId"), in)
	if err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}
