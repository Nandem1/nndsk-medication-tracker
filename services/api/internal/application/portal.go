package application

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

type UpdateTreatmentCommand struct {
	Mutation
	TreatmentID                                           string
	ExpectedVersion                                       int64
	Name, StrengthLabel, Form, PackageLabel, Instructions string
}
type ArchiveTreatmentCommand struct {
	Mutation
	TreatmentID     string
	ExpectedVersion int64
	Reason          string
}

func lockedTreatment(ctx context.Context, tx pgx.Tx, id string, expected int64) (TreatmentResult, error) {
	var r TreatmentResult
	var archived *time.Time
	err := tx.QueryRow(ctx, `SELECT t.id::text,t.version,t.archived_at,a.id::text,r.id::text FROM treatments t JOIN inventory_accounts a ON a.treatment_id=t.id JOIN LATERAL (SELECT id FROM schedule_revisions WHERE treatment_id=t.id ORDER BY revision_number DESC LIMIT 1) r ON true WHERE t.id=$1 FOR UPDATE OF t`, id).Scan(&r.TreatmentID, &r.Version, &archived, &r.AccountID, &r.RevisionID)
	if err != nil {
		return r, err
	}
	if expected < 1 || r.Version != expected || archived != nil {
		return r, ErrConflict
	}
	return r, nil
}
func auditTreatment(ctx context.Context, tx pgx.Tx, m Mutation, id, kind, reason string, now time.Time) error {
	_, err := tx.Exec(ctx, `INSERT INTO treatment_changes(treatment_id,actor_user_id,client_operation_id,kind,previous_data,reason,created_at) SELECT t.id,$2,$3,$4,jsonb_build_object('treatment',to_jsonb(t),'medication',to_jsonb(m)),$5,$6 FROM treatments t JOIN medications m ON m.id=t.medication_id WHERE t.id=$1`, id, m.ActorID, m.OperationID, kind, reason, now)
	return err
}
func (s *Service) UpdateTreatment(ctx context.Context, c UpdateTreatmentCommand) (TreatmentResult, error) {
	return transact(ctx, s, c.Mutation, treatmentTarget(c.TreatmentID), ScopeTreatments, "update_treatment", c, func(tx pgx.Tx) (TreatmentResult, error) {
		var zero TreatmentResult
		if strings.TrimSpace(c.Name) == "" || len(c.Name) > 200 || len(c.StrengthLabel) > 200 || len(c.Form) > 200 || len(c.PackageLabel) > 200 || len(c.Instructions) > 4000 {
			return zero, ErrInvalid
		}
		r, err := lockedTreatment(ctx, tx, c.TreatmentID, c.ExpectedVersion)
		if err != nil {
			return r, err
		}
		if err = auditTreatment(ctx, tx, c.Mutation, c.TreatmentID, "metadata", "", s.now()); err != nil {
			return r, err
		}
		if _, err = tx.Exec(ctx, `UPDATE medications SET name=$2,strength_label=$3,form=$4,package_label=$5 WHERE id=(SELECT medication_id FROM treatments WHERE id=$1)`, c.TreatmentID, c.Name, c.StrengthLabel, c.Form, c.PackageLabel); err != nil {
			return r, err
		}
		r.Version++
		_, err = tx.Exec(ctx, `UPDATE treatments SET instructions_text=$2,version=$3 WHERE id=$1`, c.TreatmentID, c.Instructions, r.Version)
		return r, err
	})
}
func (s *Service) ArchiveTreatment(ctx context.Context, c ArchiveTreatmentCommand) (TreatmentResult, error) {
	return transact(ctx, s, c.Mutation, treatmentTarget(c.TreatmentID), ScopeTreatments, "archive_treatment", c, func(tx pgx.Tx) (TreatmentResult, error) {
		now := s.now().UTC()
		var zero TreatmentResult
		if strings.TrimSpace(c.Reason) == "" || len(c.Reason) > 1000 {
			return zero, ErrInvalid
		}
		r, err := lockedTreatment(ctx, tx, c.TreatmentID, c.ExpectedVersion)
		if err != nil {
			return r, err
		}
		if err = auditTreatment(ctx, tx, c.Mutation, c.TreatmentID, "archive", c.Reason, now); err != nil {
			return r, err
		}
		if _, err = tx.Exec(ctx, `UPDATE dose_occurrences SET cancelled_at=$2,version=version+1 WHERE treatment_id=$1 AND scheduled_at >= $2 AND status='pending' AND cancelled_at IS NULL`, c.TreatmentID, now); err != nil {
			return r, err
		}
		r.Version++
		_, err = tx.Exec(ctx, `UPDATE treatments SET archived_at=$2,version=$3 WHERE id=$1`, c.TreatmentID, now, r.Version)
		return r, err
	})
}

type PhysicalCountCommand struct {
	Mutation
	AccountID                        string
	CountedQuantity, ExpectedBalance domain.Quantity
	Reason                           string
}

type PhysicalCountResult struct {
	CountID    string
	MovementID *string
	Balance    domain.Quantity
}

func (s *Service) RecordPhysicalCount(ctx context.Context, c PhysicalCountCommand) (PhysicalCountResult, error) {
	return transact(ctx, s, c.Mutation, accountTarget(c.AccountID), ScopeInventory, "physical_count", c, func(tx pgx.Tx) (PhysicalCountResult, error) {
		var r PhysicalCountResult
		if c.CountedQuantity < 0 || !c.CountedQuantity.Valid() || !c.ExpectedBalance.Valid() || strings.TrimSpace(c.Reason) == "" || len(c.Reason) > 1000 {
			return r, ErrInvalid
		}
		tr, err := lockInventory(ctx, tx, c.AccountID)
		if err != nil {
			return r, err
		}
		current, err := effectiveBalance(ctx, tx, c.AccountID)
		if err != nil {
			return r, err
		}
		if current != c.ExpectedBalance {
			return r, ErrConflict
		}
		delta := c.CountedQuantity - current
		if !delta.Valid() {
			return r, ErrInvalid
		}
		var movementID *string
		if delta != 0 {
			id, moveErr := movement(ctx, tx, c.Mutation, c.AccountID, tr, delta, "manual_adjustment", nil, nil, s.now())
			if moveErr != nil {
				return r, moveErr
			}
			movementID = &id
			r.MovementID = movementID
		}
		r.CountID = domain.NewID()
		_, err = tx.Exec(ctx, `INSERT INTO inventory_counts(id,inventory_account_id,actor_user_id,client_operation_id,previous_balance,counted_quantity,reason,movement_id,created_at) VALUES($9,$1,$2,$3,$4::numeric,$5::numeric,$6,$7,$8)`, c.AccountID, c.ActorID, c.OperationID, current.String(), c.CountedQuantity.String(), c.Reason, movementID, s.now(), r.CountID)
		r.Balance = c.CountedQuantity
		return r, err
	})
}
