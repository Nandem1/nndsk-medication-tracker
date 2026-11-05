-- +goose Up
-- +goose StatementBegin
-- La historia sigue siendo append-only. Sólo el borrado de cuenta, dentro de su transacción, la elimina.
CREATE OR REPLACE FUNCTION reject_history_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('app.account_deletion', true) = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'append-only record cannot be changed' USING ERRCODE='23514';
END;
$$;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION reject_history_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'append-only record cannot be changed' USING ERRCODE='23514';
END;
$$;
-- +goose StatementEnd
