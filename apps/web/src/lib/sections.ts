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

export function patientLabel(item: Patient) {
  return item.display_name ?? "Paciente sin nombre";
}
