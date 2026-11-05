import type { Scope } from "./api/contracts";
export const invitationPresets: { value: string; label: string; description: string; scopes: Scope[] }[] = [
  { value: "read", label: "Sólo mirar", description: "Ves su agenda, historial e inventario. No cambias nada.", scopes: ["read"] },
  { value: "record", label: "Ayudar a registrar", description: "Además, registras y corriges sus tomas.", scopes: ["read", "doses"] },
  { value: "manage", label: "Administrar todo", description: "Además, administras sus tratamientos e inventario.", scopes: ["read", "treatments", "doses", "inventory"] },
];
export function invitationToken(message: string) {
  const tokens = message.match(/(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/g);
  if (tokens?.length !== 1) throw new Error("Pega un único código de invitación o el mensaje completo.");
  return tokens[0];
}
export function invitationMessage(token: string) {
  return "Hola, te invito a Mis tomas. Abre la app, entra en Ajustes › Acceso de cuidadores y pega este código: " + token + ". Vence en 24 horas.";
}
