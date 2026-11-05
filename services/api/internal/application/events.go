package application

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

// clockSkewTolerance accepts ordinary phone clock drift; beyond it the time stays visibly rejected.
const clockSkewTolerance = 5 * time.Minute

func (s *Service) RecordDoseEvent(ctx context.Context, c RecordDoseEventCommand) (DoseResult, error) {
	return transact(ctx, s, c.Mutation, doseTarget(c.DoseID), ScopeDoses, "record_dose", c, func(tx pgx.Tx) (DoseResult, error) {
		return s.writeEvent(ctx, tx, c.Mutation, c.DoseID, c.ExpectedVersion, c.State, c.OccurredAt, "", "")
	})
}
func (s *Service) CorrectDoseEvent(ctx context.Context, c CorrectDoseEventCommand) (DoseResult, error) {
	return transact(ctx, s, c.Mutation, doseTarget(c.DoseID), ScopeDoses, "correct_dose", c, func(tx pgx.Tx) (DoseResult, error) {
		if !domain.ValidID(c.CorrectsEventID) || strings.TrimSpace(c.Reason) == "" || len(c.Reason) > 1000 {
			return DoseResult{}, ErrInvalid
		}
		return s.writeEvent(ctx, tx, c.Mutation, c.DoseID, c.ExpectedVersion, c.State, c.OccurredAt, c.CorrectsEventID, c.Reason)
	})
}
func (s *Service) writeEvent(ctx context.Context, tx pgx.Tx, m Mutation, id string, expected int64, state domain.DoseState, occurredAt *time.Time, corrects, reason string) (DoseResult, error) {
	var zero DoseResult
	now := s.now().UTC()
	if !domain.ValidID(id) || expected < 1 || !state.Declaration() {
		return zero, ErrInvalid
	}
	if state == domain.Skipped && occurredAt != nil {
		return zero, ErrInvalid
	}
	if state == domain.TakenLate && occurredAt == nil {
		return zero, ErrInvalid
	}
	if occurredAt != nil && (occurredAt.IsZero() || occurredAt.After(now.Add(clockSkewTolerance)) || occurredAt.Year() < 1) {
		return zero, ErrInvalid
	}
	// A phone clock slightly ahead is not a future dose: the instant is capped at the server's.
	if occurredAt != nil && occurredAt.After(now) {
		occurredAt = &now
	}
	if state == domain.Taken && occurredAt == nil {
		occurredAt = &now
	}
	var tr string
	if err := tx.QueryRow(ctx, "SELECT treatment_id::text FROM dose_occurrences WHERE id=$1", id).Scan(&tr); err != nil {
		return zero, err
	}
	if _, err := tx.Exec(ctx, "SELECT id FROM treatments WHERE id=$1 FOR UPDATE", tr); err != nil {
		return zero, err
	}
	var old domain.DoseState
	var version int64
	var current *string
	var cancelled *time.Time
	var scheduled time.Time
	var quantityText string
	if err := tx.QueryRow(ctx, "SELECT status,version,current_event_id::text,cancelled_at,scheduled_at,dose_quantity::text FROM dose_occurrences WHERE id=$1 FOR UPDATE", id).Scan(&old, &version, &current, &cancelled, &scheduled, &quantityText); err != nil {
		return zero, err
	}
	if cancelled != nil || version != expected || scheduled.After(now) {
		return zero, ErrConflict
	}
	if corrects == "" {
		if old != domain.Pending {
			return zero, ErrConflict
		}
	} else if current == nil || *current != corrects {
		return zero, ErrConflict
	}
	quantity, err := domain.ParseQuantity(quantityText)
	if err != nil {
		return zero, err
	}
	var account string
	if err = tx.QueryRow(ctx, "SELECT id::text FROM inventory_accounts WHERE treatment_id=$1", tr).Scan(&account); err != nil {
		return zero, err
	}
	if _, err = lockInventory(ctx, tx, account); err != nil {
		return zero, err
	}
	eventID := domain.NewID()
	eventType := string(state)
	var correction *string
	var why *string
	if corrects != "" {
		eventType = "corrected"
		correction = &corrects
		why = &reason
	}
	if _, err = tx.Exec(ctx, "INSERT INTO dose_events(id,dose_occurrence_id,treatment_id,actor_user_id,client_operation_id,event_type,resulting_state,version,occurred_at,recorded_at,correction_of_event_id,reason) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)", eventID, id, tr, m.ActorID, m.OperationID, eventType, state, version+1, occurredAt, now, correction, why); err != nil {
		return zero, err
	}
	if old.Consumes() != state.Consumes() {
		delta := quantity
		kind := "reversal"
		if state.Consumes() {
			delta = -quantity
			kind = "consumption"
		}
		movementID, err := movement(ctx, tx, m, account, tr, delta, kind, &eventID, &id, now)
		if err != nil {
			return zero, err
		}
		if state.Consumes() {
			if _, err = tx.Exec(ctx, "INSERT INTO active_consumptions(dose_occurrence_id,treatment_id,movement_id) VALUES($1,$2,$3)", id, tr, movementID); err != nil {
				return zero, err
			}
		} else {
			tag, err := tx.Exec(ctx, "DELETE FROM active_consumptions WHERE dose_occurrence_id=$1", id)
			if err != nil {
				return zero, err
			}
			if tag.RowsAffected() != 1 {
				return zero, ErrConflict
			}
		}
	}
	if _, err = tx.Exec(ctx, "UPDATE dose_occurrences SET status=$2,version=version+1,current_event_id=$3 WHERE id=$1", id, state, eventID); err != nil {
		return zero, err
	}
	stock, err := effectiveBalance(ctx, tx, account)
	if err != nil {
		return zero, err
	}
	return DoseResult{DoseID: id, EventID: eventID, Version: version + 1, State: state, Balance: stock}, nil
}
func (s *Service) ReplenishInventory(ctx context.Context, c ReplenishInventoryCommand) (InventoryResult, error) {
	return transact(ctx, s, c.Mutation, accountTarget(c.AccountID), ScopeInventory, "replenish_inventory", c, func(tx pgx.Tx) (InventoryResult, error) {
		var zero InventoryResult
		if !domain.ValidID(c.AccountID) || c.Quantity <= 0 || !c.Quantity.Valid() {
			return zero, ErrInvalid
		}
		tr, err := lockInventory(ctx, tx, c.AccountID)
		if err != nil {
			return zero, err
		}
		id, err := movement(ctx, tx, c.Mutation, c.AccountID, tr, c.Quantity, "replenishment", nil, nil, s.now().UTC())
		if err != nil {
			return zero, err
		}
		stock, err := effectiveBalance(ctx, tx, c.AccountID)
		if err != nil {
			return zero, err
		}
		return InventoryResult{MovementID: id, Balance: stock}, nil
	})
}
