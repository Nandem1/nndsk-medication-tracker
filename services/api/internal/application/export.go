package application

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

var ErrExportTooLarge = errors.New("account export exceeds synchronous limit")

const (
	ExportMaxRows  = 100000
	ExportMaxBytes = 20 * 1024 * 1024
)

type ExportProfile struct {
	UserID      string    `json:"user_id"`
	DisplayName *string   `json:"display_name"`
	Timezone    string    `json:"timezone"`
	CreatedAt   time.Time `json:"created_at"`
}

type AccountExport struct {
	SchemaVersion      int               `json:"schema_version"`
	ExportedAt         time.Time         `json:"exported_at"`
	Profile            ExportProfile     `json:"profile"`
	Medications        []json.RawMessage `json:"medications"`
	Treatments         []json.RawMessage `json:"treatments"`
	ScheduleRevisions  []json.RawMessage `json:"schedule_revisions"`
	Doses              []json.RawMessage `json:"doses"`
	DoseEvents         []json.RawMessage `json:"dose_events"`
	InventoryAccounts  []json.RawMessage `json:"inventory_accounts"`
	InventoryMovements []json.RawMessage `json:"inventory_movements"`
	InventoryCounts    []json.RawMessage `json:"inventory_counts"`
	TreatmentChanges   []json.RawMessage `json:"treatment_changes"`
	CaregiverLinks     []json.RawMessage `json:"caregiver_links"`
	ConsentEvents      []json.RawMessage `json:"consent_events"`
	Invitations        []json.RawMessage `json:"invitations"`
	AlertPreferences   []json.RawMessage `json:"alert_preferences"`
	Devices            []json.RawMessage `json:"devices"`
}

// ExportAccount exports only the actor's health history, even when they care for other patients.
func (s *Service) ExportAccount(ctx context.Context, actor string) (AccountExport, error) {
	return s.exportAccount(ctx, actor, ExportMaxRows, ExportMaxBytes)
}

func (s *Service) exportAccount(ctx context.Context, actor string, maxRows, maxBytes int) (AccountExport, error) {
	var out AccountExport
	if !domain.ValidID(actor) {
		return out, ErrInvalid
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	out.SchemaVersion = 1
	err = tx.QueryRow(ctx, `SELECT id::text,CASE WHEN profile_completed_at IS NOT NULL THEN display_name END,timezone,created_at,transaction_timestamp() FROM users WHERE id=$1`, actor).Scan(&out.Profile.UserID, &out.Profile.DisplayName, &out.Profile.Timezone, &out.Profile.CreatedAt, &out.ExportedAt)
	if err != nil {
		return AccountExport{}, translate(err)
	}
	// Each projection is an allowlist. New database columns must not silently enter exports.
	sections := []struct {
		target *[]json.RawMessage
		query  string
	}{
		{&out.Medications, `SELECT id,name,strength_label,form,package_label,created_at FROM medications WHERE patient_user_id=$1 ORDER BY id`},
		{&out.Treatments, `SELECT id,medication_id,instructions_text,starts_on::text,ends_on::text,version,created_at,archived_at FROM treatments WHERE patient_user_id=$1 ORDER BY id`},
		{&out.ScheduleRevisions, `SELECT r.id,r.treatment_id,r.revision_number,r.timezone,jsonb_build_object('timezone',r.rules_json->'Timezone','dst_policy',r.rules_json->'Policy','weekdays',r.rules_json->'Weekdays','slots',(SELECT jsonb_agg(jsonb_build_object('time',slot->'Time','quantity',((slot->>'Quantity')::numeric/1000)::numeric(12,3)::text) ORDER BY ordinal) FROM jsonb_array_elements(r.rules_json->'Slots') WITH ORDINALITY AS s(slot,ordinal))) AS schedule,r.effective_from,r.created_by,r.created_at FROM schedule_revisions r JOIN treatments t ON t.id=r.treatment_id WHERE t.patient_user_id=$1 ORDER BY r.id`},
		{&out.Doses, `SELECT d.id,d.treatment_id,d.schedule_revision_id,d.scheduled_at,d.scheduled_local_date::text,d.scheduled_local_time::text,d.dst_adjusted,d.dose_quantity::text,d.status,d.version,d.current_event_id,d.cancelled_at,d.created_at FROM dose_occurrences d JOIN treatments t ON t.id=d.treatment_id WHERE t.patient_user_id=$1 ORDER BY d.id`},
		{&out.DoseEvents, `SELECT e.id,e.dose_occurrence_id,e.treatment_id,e.actor_user_id,e.event_type,e.resulting_state,e.version,e.occurred_at,e.recorded_at,e.correction_of_event_id,e.reason FROM dose_events e JOIN treatments t ON t.id=e.treatment_id WHERE t.patient_user_id=$1 ORDER BY e.id`},
		{&out.InventoryAccounts, `SELECT id,treatment_id,unit,low_stock_days_threshold,created_at FROM inventory_accounts WHERE patient_user_id=$1 ORDER BY id`},
		{&out.InventoryMovements, `SELECT m.id,m.inventory_account_id,m.treatment_id,m.quantity_delta::text,m.reason,m.source_dose_event_id,m.dose_occurrence_id,m.actor_user_id,m.created_at FROM inventory_movements m JOIN treatments t ON t.id=m.treatment_id WHERE t.patient_user_id=$1 ORDER BY m.id`},
		{&out.InventoryCounts, `SELECT c.id,c.inventory_account_id,c.actor_user_id,c.previous_balance::text,c.counted_quantity::text,c.reason,c.movement_id,c.created_at FROM inventory_counts c JOIN inventory_accounts a ON a.id=c.inventory_account_id WHERE a.patient_user_id=$1 ORDER BY c.id`},
		{&out.TreatmentChanges, `SELECT c.id,c.treatment_id,c.actor_user_id,c.kind,
		 jsonb_build_object('name',c.previous_data->'medication'->'name','strength_label',c.previous_data->'medication'->'strength_label','form',c.previous_data->'medication'->'form','package_label',c.previous_data->'medication'->'package_label','instructions_text',c.previous_data->'treatment'->'instructions_text','starts_on',c.previous_data->'treatment'->'starts_on','ends_on',c.previous_data->'treatment'->'ends_on','version',c.previous_data->'treatment'->'version','archived_at',c.previous_data->'treatment'->'archived_at') AS previous_data,
		 c.reason,c.created_at FROM treatment_changes c JOIN treatments t ON t.id=c.treatment_id WHERE t.patient_user_id=$1 ORDER BY c.id`},
		{&out.CaregiverLinks, `SELECT id,patient_user_id,caregiver_user_id,status,scopes,created_at,accepted_at,revoked_at,accepted_invitation_id FROM caregiver_links WHERE patient_user_id=$1 OR caregiver_user_id=$1 ORDER BY id`},
		{&out.ConsentEvents, `SELECT e.id,e.link_id,e.actor_user_id,e.action,e.scopes,e.created_at FROM caregiver_link_events e JOIN caregiver_links l ON l.id=e.link_id WHERE l.patient_user_id=$1 OR l.caregiver_user_id=$1 ORDER BY e.id`},
		{&out.Invitations, `SELECT id,inviter_user_id,scopes,expires_at,created_at,consumed_at,consumed_by FROM invitations WHERE inviter_user_id=$1 OR consumed_by=$1 ORDER BY id`},
		{&out.AlertPreferences, `SELECT p.link_id,p.consent_id,p.unconfirmed_delay_minutes,p.stock_enabled,p.min_interval_minutes,p.timezone,p.quiet_start_minute,p.quiet_end_minute FROM caregiver_alert_preferences p JOIN caregiver_links l ON l.id=p.link_id WHERE l.caregiver_user_id=$1 ORDER BY p.link_id`},
		{&out.Devices, `SELECT id,platform,permission,expires_at,revoked_at,updated_at FROM device_registrations WHERE user_id=$1 ORDER BY id`},
	}
	rowCount, byteCount := 0, 0
	for _, section := range sections {
		*section.target = []json.RawMessage{}
		rows, queryErr := tx.Query(ctx, "SELECT to_jsonb(export_record) FROM ("+section.query+" LIMIT $2) export_record", actor, maxRows-rowCount+1)
		if queryErr != nil {
			return AccountExport{}, queryErr
		}
		for rows.Next() {
			var record json.RawMessage
			if err = rows.Scan(&record); err != nil {
				rows.Close()
				return AccountExport{}, err
			}
			rowCount++
			byteCount += len(record)
			if rowCount > maxRows || byteCount > maxBytes {
				rows.Close()
				return AccountExport{}, ErrExportTooLarge
			}
			*section.target = append(*section.target, record)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return AccountExport{}, err
		}
	}
	encoded, err := json.Marshal(out)
	if err != nil {
		return AccountExport{}, err
	}
	if len(encoded) > maxBytes {
		return AccountExport{}, ErrExportTooLarge
	}
	if err = tx.Commit(ctx); err != nil {
		return AccountExport{}, translate(err)
	}
	return out, nil
}
