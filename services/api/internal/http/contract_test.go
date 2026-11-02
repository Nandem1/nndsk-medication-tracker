package httpapi

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"

	"medication-tracker/services/api/internal/application"
)

func TestOpenAPIManualAdapterFields(t *testing.T) {
	data, err := os.ReadFile("../../../../packages/contracts/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var contract struct {
		OpenAPI    string `json:"openapi"`
		Components struct {
			Schemas map[string]struct {
				Properties map[string]json.RawMessage `json:"properties"`
			} `json:"schemas"`
		} `json:"components"`
	}
	if err = json.Unmarshal(data, &contract); err != nil {
		t.Fatal(err)
	}
	if contract.OpenAPI != "3.1.0" {
		t.Fatal(contract.OpenAPI)
	}
	cases := map[string]any{"Schedule": Schedule{}, "Slot": Slot{}, "CreateTreatment": CreateTreatmentRequest{}, "TreatmentResult": TreatmentResponse{}, "Treatment": Treatment{}, "ReviseSchedule": ReviseScheduleRequest{}, "DoseEvent": DoseEventRequest{}, "Correction": CorrectionRequest{}, "DoseResult": DoseResponse{}, "Replenish": ReplenishRequest{}, "InventoryResult": InventoryResponse{}, "Projection": Projection{}, "CreateInvitation": InvitationRequest{}, "AcceptInvitation": AcceptInvitationRequest{}, "Me": MeResponse{}, "Error": ErrorResponse{}, "Invitation": application.Invitation{}, "Link": application.Link{}, "PatientAccess": application.PatientAccess{}, "Dose": application.DoseView{}, "TreatmentPage": Page[Treatment]{}, "DosePage": Page[application.DoseView]{}, "ProjectionPage": Page[Projection]{}, "PatientAccessPage": Page[application.PatientAccess]{}}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			properties := contract.Components.Schemas[name].Properties
			fields := map[string]bool{}
			var visit func(reflect.Type)
			visit = func(typ reflect.Type) {
				for i := 0; i < typ.NumField(); i++ {
					field := typ.Field(i)
					if field.Anonymous {
						visit(field.Type)
						continue
					}
					tag := strings.Split(field.Tag.Get("json"), ",")[0]
					if tag == "" || tag == "-" {
						t.Fatalf("untagged field %s", field.Name)
					}
					fields[tag] = true
					if _, ok := properties[tag]; !ok {
						t.Fatalf("field %s absent from OpenAPI", tag)
					}
				}
			}
			visit(reflect.TypeOf(value))
			for key := range properties {
				if !fields[key] {
					t.Fatalf("schema field %s absent from typed adapter", key)
				}
			}
		})
	}
}
