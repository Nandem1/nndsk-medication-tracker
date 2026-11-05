//go:build integration

package httpapi

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"

	"medication-tracker/services/api/internal/domain"
)

type failingRemover struct{ testVerifier }

func (failingRemover) DeleteUser(context.Context, string) error {
	return errors.New("synthetic failure")
}

func TestDeleteAccountRoute(t *testing.T) {
	f := newAPIFixture(t)
	f.treatment("patient")
	f.request("patient", "DELETE", "/v1/me", map[string]any{"client_operation_id": domain.NewID(), "confirm": "no"}, 422, nil)
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/treatments", nil, 200, nil)
	// El verificador de prueba no quita la identidad: los datos se borran y se informa el pendiente.
	var out AccountDeletionResponse
	body := map[string]any{"client_operation_id": domain.NewID(), "confirm": "BORRAR"}
	f.request("patient", "DELETE", "/v1/me", body, 200, &out)
	if out.IdentityRemoved {
		t.Fatal("sin quitar la identidad no se informa éxito")
	}
	// Misma identidad: encuentra una cuenta vacía y el reintento no falla.
	f.request("patient", "DELETE", "/v1/me", body, 200, &out)
	var page struct {
		Items []any `json:"items"`
	}
	f.request("patient", "GET", "/v1/patients", nil, 200, &page)
	if len(page.Items) > 1 {
		t.Fatal(page)
	}
}

func TestDeleteAccountReportsIdentityFailure(t *testing.T) {
	f := newAPIFixture(t)
	verifier := failingRemover{testVerifier{"patient": domain.NewID()}}
	failing := httptest.NewServer(NewAPI(f.pool.Ping, f.service, verifier, nil))
	defer failing.Close()
	original := f.server
	f.server = failing
	defer func() { f.server = original }()
	var out AccountDeletionResponse
	f.request("patient", "DELETE", "/v1/me", map[string]any{"client_operation_id": domain.NewID(), "confirm": "BORRAR"}, 200, &out)
	if out.IdentityRemoved {
		t.Fatal("el fallo del proveedor debe informarse")
	}
}
