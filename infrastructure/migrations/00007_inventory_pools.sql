-- +goose Up
CREATE TABLE inventory_pools (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 status TEXT NOT NULL CHECK (status IN ('pending','active','dissolved')),
 low_stock_days_threshold INTEGER NOT NULL DEFAULT 5 CHECK (low_stock_days_threshold BETWEEN 0 AND 30),
 created_by UUID REFERENCES users(id) ON DELETE SET NULL,
 client_operation_id UUID NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 activated_at TIMESTAMPTZ,
 dissolved_at TIMESTAMPTZ,
 UNIQUE (created_by, client_operation_id)
);
CREATE TABLE inventory_pool_members (
 pool_id UUID NOT NULL REFERENCES inventory_pools(id) ON DELETE CASCADE,
 account_id UUID NOT NULL REFERENCES inventory_accounts(id) ON DELETE CASCADE,
 patient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 status TEXT NOT NULL CHECK (status IN ('pending','accepted','declined','left')),
 decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
 decided_at TIMESTAMPTZ,
 PRIMARY KEY (pool_id, account_id)
);
-- Una cuenta está como máximo en un inventario vivo.
CREATE UNIQUE INDEX inventory_pool_members_live ON inventory_pool_members(account_id) WHERE status IN ('pending','accepted');
CREATE INDEX inventory_pool_members_patient ON inventory_pool_members(patient_user_id) WHERE status='pending';
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_sign_check;
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_reason_check;
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_reason_check CHECK (reason IN ('initial','consumption','replenishment','reversal','manual_adjustment','pool_transfer'));
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_sign_check CHECK ((reason='consumption' AND quantity_delta<0) OR (reason IN ('manual_adjustment','pool_transfer') AND quantity_delta<>0) OR (reason IN ('initial','replenishment','reversal') AND quantity_delta>0));

-- +goose Down
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_sign_check;
ALTER TABLE inventory_movements DROP CONSTRAINT inventory_movements_reason_check;
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_reason_check CHECK (reason IN ('initial','consumption','replenishment','reversal','manual_adjustment'));
ALTER TABLE inventory_movements ADD CONSTRAINT inventory_movements_sign_check CHECK ((reason='consumption' AND quantity_delta<0) OR reason='manual_adjustment' OR (reason IN ('initial','replenishment','reversal') AND quantity_delta>0));
DROP TABLE inventory_pool_members;
DROP TABLE inventory_pools;
