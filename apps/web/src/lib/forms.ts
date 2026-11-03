import type { Schedule } from "./api/contracts";
export function decimal(value: string, positive = false): string {
  const normalized = value.trim().replace(",", ".");
  if (!/^\d{1,9}(\.\d{1,3})?$/.test(normalized))
    throw new Error("Usa una cantidad con hasta tres decimales.");
  if (positive && !/[1-9]/.test(normalized))
    throw new Error("La cantidad debe ser mayor que cero.");
  return normalized;
}
export function parseSchedule(form: FormData): Schedule {
  const timezone = String(form.get("timezone") ?? "");
  try {
    new Intl.DateTimeFormat("es-CL", { timeZone: timezone }).format();
  } catch {
    throw new Error("Selecciona una zona horaria IANA válida.");
  }
  const times = form.getAll("time").map((x) => String(x).trim());
  if (
    times.length < 1 ||
    times.length > 24 ||
    times.some((t) => !/^([01]\d|2[0-3]):[0-5]\d$/.test(t)) ||
    new Set(times).size !== times.length
  )
    throw new Error(
      "Escribe horarios distintos en formato HH:mm.",
    );
  const weekdays = form.getAll("weekday").map(Number);
  if (!weekdays.length) throw new Error("Selecciona al menos un día.");
  const policy = form.get("dst_policy");
  if (policy !== "reject" && policy !== "next_valid_earliest")
    throw new Error("Selecciona una política de cambio de hora.");
  const quantities = form
    .getAll("dose_quantity")
    .map((x) => decimal(String(x), true));
  if (quantities.length !== times.length)
    throw new Error("Cada horario necesita su cantidad.");
  return {
    timezone,
    dst_policy: policy,
    weekdays,
    slots: times.map((time, i) => ({ time, quantity: quantities[i] })),
  };
}
export function nextDate(date: string): string {
  const day = new Date(date + "T12:00:00Z");
  day.setUTCDate(day.getUTCDate() + 1);
  return day.toISOString().slice(0, 10);
}
export function localDate(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Santiago",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}
