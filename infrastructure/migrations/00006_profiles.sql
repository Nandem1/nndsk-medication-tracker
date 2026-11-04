-- +goose Up
ALTER TABLE users ADD COLUMN profile_completed_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN profile_version BIGINT NOT NULL DEFAULT 1 CHECK (profile_version > 0);
CREATE TABLE user_profile_changes (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
 client_operation_id UUID NOT NULL,
 previous_name TEXT,
 new_name TEXT NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX user_profile_changes_operation ON user_profile_changes(actor_user_id, client_operation_id);
CREATE TRIGGER user_profile_changes_append_only BEFORE UPDATE OR DELETE ON user_profile_changes FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
ALTER TABLE invitations ADD COLUMN patient_name_hint TEXT
 CHECK (patient_name_hint IS NULL OR length(btrim(patient_name_hint)) BETWEEN 1 AND 60);

-- +goose Down
ALTER TABLE invitations DROP COLUMN patient_name_hint;
DROP TABLE user_profile_changes;
ALTER TABLE users DROP COLUMN profile_version;
ALTER TABLE users DROP COLUMN profile_completed_at;
