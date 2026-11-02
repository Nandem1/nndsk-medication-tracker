-- +goose Up
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_provider_uid TEXT NOT NULL UNIQUE CHECK (length(btrim(auth_provider_uid)) > 0),
    display_name TEXT NOT NULL CHECK (length(btrim(display_name)) > 0),
    timezone TEXT NOT NULL DEFAULT 'America/Santiago' CHECK (length(btrim(timezone)) > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE users;
