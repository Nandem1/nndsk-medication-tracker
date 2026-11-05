import type { Movement, Pool, Projection } from "./api/contracts";

function parts(value: string) {
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(value);
  if (!match) throw new Error("Cantidad decimal inválida");
  return { negative: match[1] === "-", whole: match[2], fraction: match[3] ?? "" };
}

/** Resta exacta de cantidades en texto: nunca pasa por float. */
export function subtractDecimal(a: string, b: string) {
  const x = parts(a);
  const y = parts(b);
  const scale = Math.max(x.fraction.length, y.fraction.length);
  const scaled = (p: typeof x) => {
    const value = BigInt(p.whole + p.fraction.padEnd(scale, "0"));
    return p.negative ? -value : value;
  };
  const result = scaled(x) - scaled(y);
  const digits = (result < 0n ? -result : result).toString().padStart(scale + 1, "0");
  const whole = digits.slice(0, digits.length - scale);
  const fraction = scale ? "." + digits.slice(-scale) : "";
  return (result < 0n ? "-" : "") + whole + fraction;
}

/** Cantidad para mostrar en es-CL, sólo con texto: «19.000» se leería como diecinueve mil. */
export function quantityLabel(value: string) {
  const { negative, whole, fraction } = parts(value);
  const integer = whole.replace(/^0+(?=\d)/, "");
  const decimals = fraction.replace(/0+$/, "");
  const zero = integer === "0" && !decimals;
  return (negative && !zero ? "-" : "") + integer + (decimals ? "," + decimals : "");
}

/** Fecha y hora sin segundos. Termina en «p. m.», así que no admite un punto final. */
export function dateTimeLabel(value: string) {
  return new Date(value).toLocaleString("es-CL", { day: "2-digit", month: "2-digit", year: "numeric", hour: "numeric", minute: "2-digit" });
}

const dayMs = 86400000;

/** Días completos cubiertos según la proyección del servidor; null si cubre toda la ventana. */
export function coverageDays(item: Pick<Projection, "from" | "first_uncovered_at">) {
  if (!item.first_uncovered_at) return null;
  return Math.max(0, Math.floor((Date.parse(item.first_uncovered_at) - Date.parse(item.from)) / dayMs));
}

export function windowDays(item: Pick<Projection, "from" | "through">) {
  return Math.round((Date.parse(item.through) - Date.parse(item.from)) / dayMs);
}

/** Parte cubierta de la ventana de proyección, entre 0 y 1. */
export function coveredShare(item: Pick<Projection, "from" | "through" | "first_uncovered_at">) {
  if (!item.first_uncovered_at) return 1;
  const start = Date.parse(item.from);
  const share = (Date.parse(item.first_uncovered_at) - start) / (Date.parse(item.through) - start);
  return Math.min(1, Math.max(0, share));
}

export function coverageLabel(item: Pick<Projection, "from" | "through" | "first_uncovered_at">) {
  const days = coverageDays(item);
  if (days === null) return windowDays(item) + " días o más";
  return days === 1 ? "1 día" : days + " días";
}

/** Los demás miembros del inventario, sin la persona dueña de esta cuenta. */
export function poolOthers(pool: Pool, status?: Pool["members"][number]["status"]) {
  const names = pool.members
    .filter((member) => !member.current && (!status || member.status === status))
    .map((member) => member.patient_display_name ?? "Paciente sin nombre");
  return [...new Set(names)].join(", ");
}

/** El servidor anula la hora de la actividad ajena: se muestra sólo la fecha, sin convertir de zona. */
export function movementDate(item: Pick<Movement, "created_at" | "reason">) {
  if (item.reason !== "shared_activity") return dateTimeLabel(item.created_at);
  const [year, month, day] = item.created_at.slice(0, 10).split("-");
  return `${day}-${month}-${year}`;
}
