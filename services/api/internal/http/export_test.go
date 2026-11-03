package httpapi

import (
	"net/http/httptest"
	"testing"
)

func TestExportRejectsWorkWhenCapacityIsOccupied(t *testing.T) {
	api := &API{exportSlots: make(chan struct{}, 2)}
	api.exportSlots <- struct{}{}
	api.exportSlots <- struct{}{}
	response := httptest.NewRecorder()
	api.exportAccount(response, httptest.NewRequest("GET", "/v1/me/export", nil))
	if response.Code != 429 || response.Header().Get("Retry-After") != "5" || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal(response.Code, response.Header())
	}
	if len(api.exportSlots) != 2 {
		t.Fatal("capacity changed on rejected request")
	}
}
