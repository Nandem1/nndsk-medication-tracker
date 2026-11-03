-- +goose Up
ALTER TABLE treatments ADD COLUMN archived_at TIMESTAMPTZ;
CREATE TABLE treatment_changes (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 treatment_id UUID NOT NULL REFERENCES treatments(id),
 actor_user_id UUID NOT NULL REFERENCES users(id),
 client_operation_id UUID NOT NULL,
 kind TEXT NOT NULL CHECK (kind IN ('metadata','archive')),
 previous_data JSONB NOT NULL,
 reason TEXT NOT NULL DEFAULT '',
 created_at TIMESTAMPTZ NOT NULL,
 UNIQUE(actor_user_id,client_operation_id)
);
CREATE TRIGGER treatment_changes_append_only BEFORE UPDATE OR DELETE ON treatment_changes FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_reason_check;
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_check2;
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_reason_check CHECK (reason IN ('initial','consumption','replenishment','reversal','manual_adjustment'));
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_sign_check CHECK ((reason='consumption' AND quantity_delta<0) OR reason='manual_adjustment' OR (reason IN ('initial','replenishment','reversal') AND quantity_delta>0));
CREATE TABLE inventory_counts (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 inventory_account_id UUID NOT NULL REFERENCES inventory_accounts(id),
 actor_user_id UUID NOT NULL REFERENCES users(id),
 client_operation_id UUID NOT NULL,
 previous_balance NUMERIC(12,3) NOT NULL,
 counted_quantity NUMERIC(12,3) NOT NULL CHECK(counted_quantity>=0),
 reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 1 AND 1000),
 movement_id UUID REFERENCES inventory_movements(id),
 created_at TIMESTAMPTZ NOT NULL,
 UNIQUE(actor_user_id,client_operation_id)
);
CREATE TRIGGER inventory_counts_append_only BEFORE UPDATE OR DELETE ON inventory_counts FOR EACH ROW EXECUTE FUNCTION reject_history_mutation();
-- +goose Down
DROP TABLE inventory_counts;
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_sign_check;
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_reason_check;
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_reason_check CHECK(reason IN ('initial','consumption','replenishment','reversal'));
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_check2 CHECK ((reason='consumption' AND quantity_delta<0) OR (reason<>'consumption' AND quantity_delta>0));
DROP TABLE treatment_changes;
ALTER TABLE treatments DROP COLUMN archived_at;
