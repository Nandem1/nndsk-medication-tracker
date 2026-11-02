-- +goose Up
CREATE TABLE patients (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE caregiver_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_user_id UUID NOT NULL REFERENCES patients(user_id) ON DELETE RESTRICT,
    caregiver_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('pending','active','revoked')),
    scopes TEXT[] NOT NULL CHECK (cardinality(scopes)>0 AND scopes <@ ARRAY['read','treatments','doses','inventory']::text[]),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    CHECK (patient_user_id<>caregiver_user_id),
    CHECK ((status='pending' AND accepted_at IS NULL AND revoked_at IS NULL) OR
           (status='active' AND accepted_at IS NOT NULL AND revoked_at IS NULL) OR
           (status='revoked' AND revoked_at IS NOT NULL)),
    UNIQUE(patient_user_id,caregiver_user_id)
);
CREATE INDEX caregiver_links_caregiver ON caregiver_links(caregiver_user_id,status);
CREATE TABLE medications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_user_id UUID NOT NULL REFERENCES patients(user_id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    strength_label TEXT NOT NULL DEFAULT '',
    form TEXT NOT NULL DEFAULT '',
    package_label TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(id,patient_user_id)
);
CREATE TABLE treatments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_user_id UUID NOT NULL REFERENCES patients(user_id) ON DELETE RESTRICT,
    medication_id UUID NOT NULL,
    instructions_text TEXT NOT NULL DEFAULT '',
    starts_on DATE NOT NULL,
    ends_on DATE,
    version BIGINT NOT NULL DEFAULT 1 CHECK (version>0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ends_on IS NULL OR ends_on>=starts_on),
    FOREIGN KEY(medication_id,patient_user_id) REFERENCES medications(id,patient_user_id) ON DELETE RESTRICT,
    UNIQUE(id,patient_user_id)
);
CREATE INDEX treatments_patient ON treatments(patient_user_id);
CREATE TABLE schedule_revisions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_id UUID NOT NULL REFERENCES treatments(id) ON DELETE RESTRICT,
    revision_number BIGINT NOT NULL CHECK (revision_number>0),
    timezone TEXT NOT NULL CHECK (length(timezone)>0),
    rules_json JSONB NOT NULL CHECK (jsonb_typeof(rules_json)='object'),
    effective_from TIMESTAMPTZ NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(treatment_id,revision_number),
    UNIQUE(treatment_id,effective_from),
    UNIQUE(id,treatment_id)
);
CREATE TABLE dose_occurrences (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_id UUID NOT NULL REFERENCES treatments(id) ON DELETE RESTRICT,
    schedule_revision_id UUID NOT NULL,
    scheduled_at TIMESTAMPTZ NOT NULL,
    scheduled_local_date DATE NOT NULL,
    scheduled_local_time TIME NOT NULL,
    dst_adjusted BOOLEAN NOT NULL,
    dose_quantity NUMERIC(12,3) NOT NULL CHECK (dose_quantity>0),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','taken','taken_late','skipped')),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version>0),
    current_event_id UUID,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (cancelled_at IS NULL OR status='pending'),
    CHECK ((status='pending')=(current_event_id IS NULL)),
    FOREIGN KEY(schedule_revision_id,treatment_id) REFERENCES schedule_revisions(id,treatment_id) ON DELETE RESTRICT,
    UNIQUE(schedule_revision_id,scheduled_at),
    UNIQUE(id,treatment_id)
);
CREATE INDEX dose_occurrences_agenda ON dose_occurrences(treatment_id,scheduled_at) WHERE cancelled_at IS NULL;
CREATE TABLE inventory_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_id UUID NOT NULL UNIQUE,
    patient_user_id UUID NOT NULL,
    unit TEXT NOT NULL CHECK (unit IN ('tablet','capsule','ml','dose','other')),
    low_stock_days_threshold INTEGER NOT NULL DEFAULT 5 CHECK (low_stock_days_threshold>=0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY(treatment_id,patient_user_id) REFERENCES treatments(id,patient_user_id) ON DELETE RESTRICT,
    UNIQUE(id,treatment_id)
);
CREATE TABLE dose_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dose_occurrence_id UUID NOT NULL,
    treatment_id UUID NOT NULL,
    actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    client_operation_id UUID NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('taken','taken_late','skipped','corrected')),
    resulting_state TEXT NOT NULL CHECK (resulting_state IN ('taken','taken_late','skipped')),
    version BIGINT NOT NULL CHECK (version>=2),
    occurred_at TIMESTAMPTZ,
    recorded_at TIMESTAMPTZ NOT NULL,
    correction_of_event_id UUID,
    reason TEXT,
    CHECK ((resulting_state='skipped')=(occurred_at IS NULL)),
    CHECK (occurred_at IS NULL OR occurred_at<=recorded_at),
    CHECK ((event_type='corrected' AND correction_of_event_id IS NOT NULL AND reason IS NOT NULL AND length(btrim(reason))>0) OR
           (event_type=resulting_state AND correction_of_event_id IS NULL)),
    FOREIGN KEY(dose_occurrence_id,treatment_id) REFERENCES dose_occurrences(id,treatment_id) ON DELETE RESTRICT,
    UNIQUE(id,dose_occurrence_id,treatment_id),
    UNIQUE(actor_user_id,client_operation_id),
    UNIQUE(dose_occurrence_id,version),
    FOREIGN KEY(correction_of_event_id,dose_occurrence_id,treatment_id) REFERENCES dose_events(id,dose_occurrence_id,treatment_id) ON DELETE RESTRICT
);
ALTER TABLE dose_occurrences ADD CONSTRAINT current_event_fk FOREIGN KEY(current_event_id,id,treatment_id) REFERENCES dose_events(id,dose_occurrence_id,treatment_id) ON DELETE RESTRICT;
CREATE TABLE inventory_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inventory_account_id UUID NOT NULL,
    treatment_id UUID NOT NULL,
    quantity_delta NUMERIC(12,3) NOT NULL CHECK (quantity_delta<>0),
    reason TEXT NOT NULL CHECK (reason IN ('initial','consumption','replenishment','reversal')),
    source_dose_event_id UUID UNIQUE,
    dose_occurrence_id UUID,
    actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    client_operation_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CHECK ((reason IN ('consumption','reversal'))=(source_dose_event_id IS NOT NULL)),
    CHECK ((source_dose_event_id IS NULL)=(dose_occurrence_id IS NULL)),
    CHECK ((reason='consumption' AND quantity_delta<0) OR (reason<>'consumption' AND quantity_delta>0)),
    FOREIGN KEY(inventory_account_id,treatment_id) REFERENCES inventory_accounts(id,treatment_id) ON DELETE RESTRICT,
    FOREIGN KEY(source_dose_event_id,dose_occurrence_id,treatment_id) REFERENCES dose_events(id,dose_occurrence_id,treatment_id) ON DELETE RESTRICT,
    UNIQUE(actor_user_id,client_operation_id),
    UNIQUE(id,dose_occurrence_id,treatment_id)
);
CREATE INDEX inventory_movements_account ON inventory_movements(inventory_account_id,created_at);
CREATE TABLE active_consumptions (
    dose_occurrence_id UUID PRIMARY KEY,
    treatment_id UUID NOT NULL,
    movement_id UUID NOT NULL UNIQUE,
    FOREIGN KEY(movement_id,dose_occurrence_id,treatment_id) REFERENCES inventory_movements(id,dose_occurrence_id,treatment_id) ON DELETE RESTRICT
);
CREATE TABLE operations (
    actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    client_operation_id UUID NOT NULL,
    kind TEXT NOT NULL,
    fingerprint BYTEA NOT NULL,
    response JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(actor_user_id,client_operation_id)
);
-- +goose StatementBegin
CREATE FUNCTION reject_history_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'append-only record cannot be changed' USING ERRCODE='23514';
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER dose_events_append_only BEFORE UPDATE OR DELETE ON dose_events FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
CREATE TRIGGER inventory_movements_append_only BEFORE UPDATE OR DELETE ON inventory_movements FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
CREATE TRIGGER revisions_append_only BEFORE UPDATE OR DELETE ON schedule_revisions FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
CREATE TRIGGER operations_append_only BEFORE UPDATE OR DELETE ON operations FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();

-- +goose Down
DROP TABLE operations;
DROP TABLE active_consumptions;
DROP TABLE inventory_movements;
ALTER TABLE dose_occurrences DROP CONSTRAINT current_event_fk;
DROP TABLE dose_events;
DROP TABLE inventory_accounts;
DROP TABLE dose_occurrences;
DROP TABLE schedule_revisions;
DROP FUNCTION reject_history_mutation();
DROP TABLE treatments;
DROP TABLE medications;
DROP TABLE caregiver_links;
DROP TABLE patients;
