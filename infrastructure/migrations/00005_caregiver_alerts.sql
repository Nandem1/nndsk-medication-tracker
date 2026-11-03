-- +goose Up
CREATE TABLE device_registrations (
 id UUID PRIMARY KEY,
 user_id UUID NOT NULL REFERENCES users(id),
 platform TEXT NOT NULL CHECK (platform IN ('apns','fcm')),
 token TEXT NOT NULL CHECK (length(token)<=4096),
 permission TEXT NOT NULL CHECK (permission IN ('granted','denied','unknown')),
 revision BIGINT NOT NULL DEFAULT 1,
 expires_at TIMESTAMPTZ NOT NULL,
 revoked_at TIMESTAMPTZ,
 updated_at TIMESTAMPTZ NOT NULL,
 CHECK (permission<>'granted' OR length(token)>0)
);
CREATE UNIQUE INDEX device_active_token ON device_registrations(platform,token) WHERE revoked_at IS NULL AND token<>'';
CREATE INDEX device_owner ON device_registrations(user_id);
CREATE TABLE caregiver_alert_preferences (
 link_id UUID PRIMARY KEY REFERENCES caregiver_links(id),
 consent_id UUID NOT NULL REFERENCES invitations(id),
 unconfirmed_delay_minutes INTEGER CHECK (unconfirmed_delay_minutes BETWEEN 1 AND 1440),
 stock_enabled BOOLEAN NOT NULL DEFAULT false,
 min_interval_minutes INTEGER NOT NULL DEFAULT 60 CHECK (min_interval_minutes BETWEEN 15 AND 1440),
 timezone TEXT NOT NULL,
 quiet_start_minute INTEGER CHECK (quiet_start_minute BETWEEN 0 AND 1439),
 quiet_end_minute INTEGER CHECK (quiet_end_minute BETWEEN 0 AND 1439),
 CHECK ((quiet_start_minute IS NULL)=(quiet_end_minute IS NULL)),
 CHECK (quiet_start_minute<>quiet_end_minute)
);
CREATE TABLE notification_outbox (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 link_id UUID NOT NULL REFERENCES caregiver_links(id),
 consent_id UUID NOT NULL REFERENCES invitations(id),
 device_id UUID NOT NULL REFERENCES device_registrations(id),
 device_revision BIGINT NOT NULL,
 kind TEXT NOT NULL CHECK (kind IN ('unconfirmed','low_stock')),
 dose_id UUID REFERENCES dose_occurrences(id),
 account_id UUID REFERENCES inventory_accounts(id),
 dedup_key TEXT NOT NULL UNIQUE,
 state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','sending','sent','retry','suppressed','uncertain','failed')),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
 created_at TIMESTAMPTZ NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 next_attempt_at TIMESTAMPTZ NOT NULL,
 attempted_at TIMESTAMPTZ,
 completed_at TIMESTAMPTZ,
 CHECK ((kind='unconfirmed' AND dose_id IS NOT NULL AND account_id IS NULL) OR (kind='low_stock' AND account_id IS NOT NULL AND dose_id IS NULL))
);
CREATE INDEX notification_ready ON notification_outbox(next_attempt_at) WHERE state IN ('pending','retry');
CREATE TABLE notification_frequency (
 user_id UUID PRIMARY KEY REFERENCES users(id),
 next_allowed_at TIMESTAMPTZ NOT NULL
);
-- +goose Down
DROP TABLE notification_frequency;
DROP TABLE notification_outbox;
DROP TABLE caregiver_alert_preferences;
DROP TABLE device_registrations;
