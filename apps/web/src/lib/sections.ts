import type { Patient } from "./api/contracts";

export const sections = [
  { id: "dashboard", label: "Seguimiento" },
  { id: "treatments", label: "Tratamientos" },
  { id: "inventory", label: "Inventario" },
  { id: "agenda", label: "Agenda" },
] as const;
export type Section = (typeof sections)[number]["id"];

export function parseSection(value: unknown): Section {
  return sections.find((item) => item.id === value)?.id ?? "treatments";
}

/** La API no entrega nombres: se usa la misma etiqueta en tarjetas y pestañas. */
export function patientLabel(item: Patient, index: number) {
  return item.link_id ? "Paciente vinculado " + (index + 1) : "Mi registro";
}
