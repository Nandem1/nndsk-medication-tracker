-- +goose Up
CREATE TABLE families (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60),
 created_by UUID REFERENCES users(id) ON DELETE SET NULL,
 client_operation_id UUID NOT NULL,
 created_at TIMESTAMPTZ NOT NULL,
 UNIQUE (created_by, client_operation_id)
);
CREATE TABLE family_members (
 family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
 user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
 role TEXT NOT NULL CHECK (role IN ('admin','caregiver','observer','patient')),
 joined_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY (family_id, user_id)
);
CREATE INDEX family_members_user ON family_members(user_id);
-- Toda invitación nueva es a una familia y con un rol.
ALTER TABLE invitations ADD COLUMN family_id UUID REFERENCES families(id) ON DELETE RESTRICT;
ALTER TABLE invitations ADD COLUMN role TEXT CHECK (role IN ('admin','caregiver','observer','patient'));
ALTER TABLE invitations ADD CONSTRAINT invitations_family_role CHECK ((family_id IS NULL) = (role IS NULL));
-- Datos de prueba: los vínculos sin familia y las propuestas pendientes no sobreviven al modelo nuevo.
INSERT INTO caregiver_link_events(link_id,actor_user_id,action,scopes,created_at)
 SELECT id,caregiver_user_id,'revoked',scopes,now() FROM caregiver_links WHERE status='active';
UPDATE caregiver_links SET status='revoked',revoked_at=now() WHERE status='active';
UPDATE inventory_pool_members SET status='left',decided_at=now() WHERE pool_id IN (SELECT id FROM inventory_pools WHERE status='pending') AND status IN ('pending','accepted');
UPDATE inventory_pools SET status='dissolved',dissolved_at=now() WHERE status='pending';

-- +goose Down
ALTER TABLE invitations DROP CONSTRAINT invitations_family_role;
ALTER TABLE invitations DROP COLUMN role;
ALTER TABLE invitations DROP COLUMN family_id;
DROP TABLE family_members;
DROP TABLE families;
