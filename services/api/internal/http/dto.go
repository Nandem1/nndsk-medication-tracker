package httpapi

import (
	"time"

	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/domain"
)

type Schedule struct {
	Timezone string           `json:"timezone"`
	Policy   domain.DSTPolicy `json:"dst_policy"`
	Weekdays []time.Weekday   `json:"weekdays"`
	Slots    []Slot           `json:"slots"`
}
type Slot struct {
	Time     string `json:"time"`
	Quantity string `json:"quantity"`
}

func (s Schedule) domain() (domain.Schedule, error) {
	out := domain.Schedule{Timezone: s.Timezone, Policy: s.Policy, Weekdays: s.Weekdays}
	for _, slot := range s.Slots {
		q, err := domain.ParseQuantity(slot.Quantity)
		if err != nil {
			return out, err
		}
		out.Slots = append(out.Slots, domain.Slot{Time: slot.Time, Quantity: q})
	}
	return out, out.Validate()
}
func scheduleDTO(s domain.Schedule) Schedule {
	out := Schedule{Timezone: s.Timezone, Policy: s.Policy, Weekdays: s.Weekdays, Slots: []Slot{}}
	for _, slot := range s.Slots {
		out.Slots = append(out.Slots, Slot{Time: slot.Time, Quantity: slot.Quantity.String()})
	}
	return out
}

type CreateTreatmentRequest struct {
	OperationID   string   `json:"client_operation_id"`
	Name          string   `json:"name"`
	StrengthLabel string   `json:"strength_label"`
	Form          string   `json:"form"`
	PackageLabel  string   `json:"package_label"`
	Instructions  string   `json:"instructions"`
	Unit          string   `json:"unit"`
	InitialStock  string   `json:"initial_stock"`
	StartsOn      string   `json:"starts_on"`
	EndsOn        string   `json:"ends_on,omitempty"`
	Schedule      Schedule `json:"schedule"`
}
type TreatmentResponse struct {
	TreatmentID string `json:"treatment_id"`
	RevisionID  string `json:"revision_id"`
	AccountID   string `json:"account_id"`
	Version     int64  `json:"version"`
}

func treatmentResponse(r application.TreatmentResult) TreatmentResponse {
	return TreatmentResponse{r.TreatmentID, r.RevisionID, r.AccountID, r.Version}
}

type Treatment struct {
	ArchivedAt *time.Time `json:"archived_at"`
	TreatmentResponse
	MedicationID  string   `json:"medication_id"`
	Name          string   `json:"name"`
	StrengthLabel string   `json:"strength_label"`
	Form          string   `json:"form"`
	PackageLabel  string   `json:"package_label"`
	Instructions  string   `json:"instructions"`
	StartsOn      string   `json:"starts_on"`
	EndsOn        *string  `json:"ends_on"`
	Unit          string   `json:"unit"`
	Schedule      Schedule `json:"schedule"`
}
type ReviseScheduleRequest struct {
	OperationID     string    `json:"client_operation_id"`
	ExpectedVersion int64     `json:"expected_version"`
	EffectiveFrom   time.Time `json:"effective_from"`
	Schedule        Schedule  `json:"schedule"`
}
type DoseEventRequest struct {
	OperationID     string           `json:"client_operation_id"`
	ExpectedVersion int64            `json:"expected_version"`
	EventType       domain.DoseState `json:"event_type"`
	OccurredAt      *time.Time       `json:"occurred_at,omitempty"`
}
type CorrectionRequest struct {
	DoseEventRequest
	CorrectsEventID string `json:"corrects_event_id"`
	Reason          string `json:"reason"`
}
type DoseResponse struct {
	DoseID  string           `json:"dose_id"`
	EventID string           `json:"event_id"`
	Version int64            `json:"version"`
	State   domain.DoseState `json:"state"`
	Balance string           `json:"balance"`
}

func doseResponse(r application.DoseResult) DoseResponse {
	return DoseResponse{r.DoseID, r.EventID, r.Version, r.State, r.Balance.String()}
}

type ReplenishRequest struct {
	OperationID string `json:"client_operation_id"`
	Quantity    string `json:"quantity"`
}
type InventoryResponse struct {
	MovementID string `json:"movement_id"`
	Balance    string `json:"balance"`
}
type Projection struct {
	AccountID             string     `json:"account_id"`
	TreatmentID           string     `json:"treatment_id"`
	Balance               string     `json:"balance"`
	Unit                  string     `json:"unit"`
	From                  time.Time  `json:"from"`
	Through               time.Time  `json:"through"`
	FirstUncoveredAt      *time.Time `json:"first_uncovered_at"`
	ScheduledQuantity     string     `json:"scheduled_quantity"`
	LowStockDaysThreshold int        `json:"low_stock_days_threshold"`
	Timezone              string     `json:"timezone"`
	ReplenishOn           *string    `json:"replenish_on"`
	LowStock              bool       `json:"low_stock"`
}
type Page[T any] struct {
	Items      []T    `json:"items"`
	NextCursor string `json:"next_cursor"`
}
type InvitationRequest struct {
	OperationID string              `json:"client_operation_id"`
	Scopes      []application.Scope `json:"scopes"`
}
type AcceptInvitationRequest struct {
	OperationID string `json:"client_operation_id"`
	Token       string `json:"token"`
}
type MeResponse struct {
	NextCursor string                      `json:"next_cursor"`
	UserID     string                      `json:"user_id"`
	Patients   []application.PatientAccess `json:"patients"`
}
type ErrorResponse struct {
	Code      string            `json:"code"`
	Message   string            `json:"message"`
	RequestID string            `json:"request_id"`
	Details   map[string]string `json:"details"`
}

type UpdateTreatmentRequest struct {
	OperationID     string `json:"client_operation_id"`
	ExpectedVersion int64  `json:"expected_version"`
	Name            string `json:"name"`
	StrengthLabel   string `json:"strength_label"`
	Form            string `json:"form"`
	PackageLabel    string `json:"package_label"`
	Instructions    string `json:"instructions"`
}
type ArchiveTreatmentRequest struct {
	OperationID     string `json:"client_operation_id"`
	ExpectedVersion int64  `json:"expected_version"`
	Reason          string `json:"reason"`
}
type PhysicalCountRequest struct {
	OperationID     string `json:"client_operation_id"`
	CountedQuantity string `json:"counted_quantity"`
	ExpectedBalance string `json:"expected_balance"`
	Reason          string `json:"reason"`
}
type PreviewInvitationRequest struct {
	Token string `json:"token"`
}

type PhysicalCountResponse struct {
	CountID    string  `json:"count_id"`
	MovementID *string `json:"movement_id"`
	Balance    string  `json:"balance"`
}
