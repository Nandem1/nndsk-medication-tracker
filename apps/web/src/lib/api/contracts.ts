import { z } from "zod";
export const scope = z.enum(["read", "treatments", "doses", "inventory"]);
export const patient = z.object({
  timezone: z.string(),
  display_name: z.string().nullable(),
  profile_version: z.number().int().positive(),
  patient_id: z.string(),
  link_id: z.string().nullable(),
  scopes: z.array(scope),
});
export const profile = z.object({
  display_name: z.string().nullable(),
  profile_version: z.number().int().positive(),
  profile_complete: z.boolean(),
});
export const me = profile.extend({ user_id: z.string() });
export type Profile = z.infer<typeof profile>;
export const schedule = z.object({
  timezone: z.string(),
  dst_policy: z.enum(["reject", "next_valid_earliest"]),
  weekdays: z.array(z.number()),
  slots: z.array(z.object({ time: z.string(), quantity: z.string() })),
});
export const treatment = z.object({
  treatment_id: z.string(),
  revision_id: z.string(),
  account_id: z.string(),
  version: z.number(),
  medication_id: z.string(),
  name: z.string(),
  strength_label: z.string(),
  form: z.string(),
  package_label: z.string(),
  instructions: z.string(),
  starts_on: z.string(),
  ends_on: z.string().nullable(),
  archived_at: z.string().nullable(),
  unit: z.enum(["tablet", "capsule", "ml", "dose", "other"]),
  schedule,
});
export const pool = z.object({
  pool_id: z.string(),
  status: z.enum(["pending", "active"]),
  members: z.array(z.object({
    patient_display_name: z.string().nullable(),
    you: z.boolean(),
    current: z.boolean(),
    status: z.enum(["pending", "accepted"]),
  })),
});
export const poolCandidate = z.object({
  account_id: z.string(),
  treatment_id: z.string(),
  patient_id: z.string(),
  patient_display_name: z.string().nullable(),
  you: z.boolean(),
});
export const poolResult = z.object({ pool_id: z.string(), status: z.enum(["pending", "active", "dissolved"]) });
export const projection = z.object({
  account_id: z.string(),
  treatment_id: z.string(),
  balance: z.string(),
  unit: z.string(),
  from: z.string(),
  through: z.string(),
  first_uncovered_at: z.string().nullable(),
  scheduled_quantity: z.string(),
  low_stock_days_threshold: z.number().int().nonnegative(),
  timezone: z.string(),
  replenish_on: z.string().nullable(),
  low_stock: z.boolean(),
  pool: pool.nullable(),
});
export const movement = z.object({
  movement_id: z.string(),
  quantity_delta: z.string(),
  reason: z.string(),
  note: z.string(),
  actor_id: z.string(),
  created_at: z.string(),
  shared: z.boolean(),
  patient_display_name: z.string().nullable().optional(),
});
export const dose = z.object({
  dose_id: z.string(),
  treatment_id: z.string(),
  scheduled_at: z.string(),
  local_date: z.string(),
  local_time: z.string(),
  timezone: z.string(),
  dst_adjusted: z.boolean(),
  quantity: z.string(),
  state: z.enum(["pending", "unconfirmed", "taken", "taken_late", "skipped"]),
});
export const invitation = z.object({
  invitation_id: z.string(),
  token: z.string(),
  expires_at: z.string(),
});
export const preview = z.object({
  caregiver_display_name: z.string().nullable(),
  patient_name_hint: z.string().nullable(),
  caregiver_id: z.string(),
  scopes: z.array(scope),
  expires_at: z.string(),
});
export const link = z.object({
  patient_display_name: z.string().nullable(),
  caregiver_display_name: z.string().nullable(),
  link_id: z.string(),
  patient_id: z.string(),
  caregiver_id: z.string(),
  scopes: z.array(scope),
  status: z.string(),
});
export type Treatment = z.infer<typeof treatment>;
export type Patient = z.infer<typeof patient>;
export type Projection = z.infer<typeof projection>;
export type Movement = z.infer<typeof movement>;
export type Pool = z.infer<typeof pool>;
export type Schedule = z.infer<typeof schedule>;
export type Scope = z.infer<typeof scope>;
export const scopeLabels: Record<Scope, string> = {
  read: "Consultar información",
  treatments: "Administrar tratamientos",
  inventory: "Administrar inventario",
  doses: "Registrar y corregir declaraciones",
};
export const unitLabels = {
  tablet: "comprimidos",
  capsule: "cápsulas",
  ml: "ml",
  dose: "dosis",
  other: "unidades",
};
export const stateLabels = {
  pending: "Programada",
  unconfirmed: "Sin confirmar",
  taken: "Declarada tomada",
  taken_late: "Declarada tomada tarde",
  skipped: "Declarada omitida",
};
export const adherenceCounts = z.object({
  evaluable: z.number().int().nonnegative(),
  taken: z.number().int().nonnegative(),
  taken_late: z.number().int().nonnegative(),
  skipped: z.number().int().nonnegative(),
  unconfirmed: z.number().int().nonnegative(),
  confirmed: z.number().int().nonnegative(),
  punctual: z.number().int().nonnegative(),
  adherence_rate: z.number().min(0).max(1).nullable(),
  confirmation_rate: z.number().min(0).max(1).nullable(),
  punctuality_rate: z.number().min(0).max(1).nullable(),
  unconfirmed_rate: z.number().min(0).max(1).nullable(),
});
export const adherence = z.object({
  from: z.string(),
  to: z.string(),
  as_of: z.string(),
  window_minutes: z.number().int(),
  summary: adherenceCounts,
  days: z.array(adherenceCounts.extend({ date: z.string() })),
});
