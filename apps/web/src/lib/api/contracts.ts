import { z } from "zod";
export const scope = z.enum(["read", "treatments", "doses", "inventory"]);
export const patient = z.object({
  patient_id: z.string(),
  link_id: z.string().nullable(),
  scopes: z.array(scope),
});
export const me = z.object({ user_id: z.string() });
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
export const projection = z.object({
  account_id: z.string(),
  treatment_id: z.string(),
  balance: z.string(),
  unit: z.string(),
  from: z.string(),
  through: z.string(),
  first_uncovered_at: z.string().nullable(),
  scheduled_quantity: z.string(),
});
export const movement = z.object({
  movement_id: z.string(),
  quantity_delta: z.string(),
  reason: z.string(),
  note: z.string(),
  actor_id: z.string(),
  created_at: z.string(),
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
  caregiver_id: z.string(),
  scopes: z.array(scope),
  expires_at: z.string(),
});
export const link = z.object({
  link_id: z.string(),
  patient_id: z.string(),
  caregiver_id: z.string(),
  scopes: z.array(scope),
  status: z.string(),
});
export type Treatment = z.infer<typeof treatment>;
export type Patient = z.infer<typeof patient>;
export type Projection = z.infer<typeof projection>;
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
