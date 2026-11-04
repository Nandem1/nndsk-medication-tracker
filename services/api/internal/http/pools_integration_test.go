//go:build integration

package httpapi

import (
	"testing"

	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
)

// El contrato HTTP completo y el acceso de un ajeno en cada ruta.
func TestInventoryPoolRoutes(t *testing.T) {
	f := newAPIFixture(t)
	first := f.treatment("patient")
	second := f.treatment("patient")
	var candidates Page[application.PoolCandidate]
	f.request("patient", "GET", "/v1/inventory/"+first.AccountID+"/pool-candidates", nil, 200, &candidates)
	if len(candidates.Items) != 1 || candidates.Items[0].AccountID != second.AccountID || !candidates.Items[0].You {
		t.Fatal(candidates)
	}
	create := map[string]any{"client_operation_id": domain.NewID(), "account_ids": []string{first.AccountID, second.AccountID}}
	var pool application.PoolResult
	f.request("stranger", "POST", "/v1/inventory-pools", create, 404, nil)
	f.request("patient", "POST", "/v1/inventory-pools", map[string]any{"client_operation_id": domain.NewID(), "account_ids": []string{first.AccountID}}, 422, nil)
	f.request("patient", "POST", "/v1/inventory-pools", create, 200, &pool)
	if pool.Status != "active" {
		t.Fatal(pool)
	}
	var page Page[Projection]
	f.request("patient", "GET", "/v1/patients/"+f.patient+"/inventory", nil, 200, &page)
	if len(page.Items) != 2 || page.Items[0].Pool == nil || page.Items[0].Pool.Status != "active" || page.Items[0].Balance != page.Items[1].Balance {
		t.Fatal(page)
	}
	f.request("stranger", "GET", "/v1/patients/"+f.patient+"/inventory", nil, 404, nil)
	f.request("stranger", "GET", "/v1/inventory/"+first.AccountID+"/movements", nil, 404, nil)
	f.request("stranger", "GET", "/v1/inventory/"+first.AccountID+"/pool-candidates", nil, 404, nil)
	f.request("stranger", "POST", "/v1/inventory-pools/"+pool.PoolID+"/decision", map[string]any{"client_operation_id": domain.NewID(), "decision": "decline"}, 404, nil)
	f.request("stranger", "POST", "/v1/inventory-pools/"+pool.PoolID+"/leave", map[string]any{"client_operation_id": domain.NewID(), "account_id": first.AccountID}, 404, nil)
	var pending Page[application.PendingPool]
	f.request("stranger", "GET", "/v1/inventory-pools/pending", nil, 200, &pending)
	if len(pending.Items) != 0 {
		t.Fatal(pending)
	}
	var movements Page[application.MovementView]
	f.request("patient", "GET", "/v1/inventory/"+first.AccountID+"/movements", nil, 200, &movements)
	if len(movements.Items) == 0 {
		t.Fatal(movements)
	}
	leave := map[string]any{"client_operation_id": domain.NewID(), "account_id": first.AccountID}
	var left application.PoolResult
	f.request("patient", "POST", "/v1/inventory-pools/"+pool.PoolID+"/leave", leave, 200, &left)
	if left.Status != "dissolved" {
		t.Fatal(left)
	}
	f.request("patient", "POST", "/v1/inventory-pools/"+pool.PoolID+"/leave", leave, 200, &left)
}
