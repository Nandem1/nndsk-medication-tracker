-- +goose Up
CREATE TABLE invitations (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 inviter_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
 client_operation_id UUID NOT NULL,
 token_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(token_hash)=32),
 scopes TEXT[] NOT NULL CHECK ('read'=ANY(scopes) AND scopes <@ ARRAY['read','treatments','doses','inventory']::text[]),
 expires_at TIMESTAMPTZ NOT NULL,
 created_at TIMESTAMPTZ NOT NULL,
 consumed_at TIMESTAMPTZ,
 consumed_by UUID REFERENCES users(id) ON DELETE RESTRICT,
 CHECK ((consumed_at IS NULL)=(consumed_by IS NULL)),
 CHECK (expires_at>created_at),
 UNIQUE(inviter_user_id,client_operation_id)
);
ALTER TABLE caregiver_links ADD COLUMN accepted_invitation_id UUID REFERENCES invitations(id) ON DELETE RESTRICT;
CREATE TABLE caregiver_link_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 link_id UUID NOT NULL REFERENCES caregiver_links(id) ON DELETE RESTRICT,
 actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
 action TEXT NOT NULL CHECK (action IN ('accepted','revoked')),
 scopes TEXT[] NOT NULL,
 created_at TIMESTAMPTZ NOT NULL
);
CREATE TRIGGER link_events_append_only BEFORE UPDATE OR DELETE ON caregiver_link_events FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
-- +goose Down
DROP TABLE caregiver_link_events;
ALTER TABLE caregiver_links DROP COLUMN accepted_invitation_id;
DROP TABLE invitations;
