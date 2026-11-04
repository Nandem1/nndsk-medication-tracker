export function shiftDate(date: string, days: number) {
  const value = new Date(date + "T12:00:00Z");
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}
export function reportPeriod(date: string, period: "week" | "month") {
  const value = new Date(date + "T12:00:00Z");
  if (period === "week") {
    const from = shiftDate(date, -((value.getUTCDay() + 6) % 7));
    return { from, until: shiftDate(from, 6) };
  }
  const from = date.slice(0, 8) + "01";
  value.setUTCMonth(value.getUTCMonth() + 1, 0);
  return { from, until: value.toISOString().slice(0, 10) };
}
export function validReportRange(from: string, until: string) {
  const start = Date.parse(from + "T12:00:00Z");
  const end = Date.parse(until + "T12:00:00Z");
  return Number.isFinite(start) && Number.isFinite(end) && end >= start && end - start < 366 * 86400000;
}
export function percent(value: number | null) {
  return value === null ? "Sin datos evaluables" : new Intl.NumberFormat("es-CL", { style: "percent", maximumFractionDigits: 1 }).format(value);
}

export function patientDate(timezone: string, instant = new Date()) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(instant);
}
