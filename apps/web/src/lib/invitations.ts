import type { FamilyMember, FamilyRole } from "./api/contracts";

export const roles: { value: FamilyRole; label: string; description: string }[] = [
  { value: "patient", label: "Paciente", description: "Registra sus propias tomas. Quienes cuidan en la familia verán su agenda." },
  { value: "caregiver", label: "Cuidar", description: "Ve a cada paciente, registra tomas y repone stock." },
  { value: "observer", label: "Sólo mirar", description: "Ve agendas, historial e inventario. No cambia nada." },
  { value: "admin", label: "Administrar", description: "Todo lo anterior, más tratamientos e invitar o quitar personas." },
];
export const roleLabels = Object.fromEntries(roles.map((role) => [role.value, role.label])) as Record<FamilyRole, string>;

/** El enlace abre la app. El token va en el fragmento: ningún servidor lo recibe por la URL. */
export function invitationLink(token: string) {
  return "mistomas://unirse#" + token;
}

/** Extrae el código aunque se pegue el mensaje o el enlace completo. */
export function invitationToken(message: string) {
  const tokens = new Set(message.match(/(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/g));
  if (tokens.size !== 1) throw new Error("Pega un único código de invitación o el mensaje completo.");
  return [...tokens][0];
}

export function invitationMessage(token: string, familyName: string) {
  // El enlace va solo en su línea: un punto pegado lo rompería al tocarlo.
  return "Hola, te invito a «" + familyName + "» en Mis tomas. En tu teléfono, toca este enlace:\n\n" + invitationLink(token) +
    "\n\nSi no se abre, entra en la app, ve a Ajustes › Familia y pega este código: " + token + "\n\nVence en 7 días.";
}

/** Iniciales para el avatar: nunca se muestra un identificador. */
export function initials(name: string | null) {
  const words = (name ?? "").trim().split(/\s+/).filter(Boolean);
  if (!words.length) return "?";
  return (words[0][0] + (words.length > 1 ? words[words.length - 1][0] : "")).toLocaleUpperCase("es-CL");
}

export function memberName(member: Pick<FamilyMember, "display_name">) {
  return member.display_name ?? "Persona sin nombre";
}

const weekMs = 7 * 86400000;
/** Un miembro es nuevo durante su primera semana, para que el paciente sepa quién se unió. */
export function isNewMember(member: Pick<FamilyMember, "joined_at" | "you">, now = Date.now()) {
  return !member.you && now - Date.parse(member.joined_at) < weekMs;
}
