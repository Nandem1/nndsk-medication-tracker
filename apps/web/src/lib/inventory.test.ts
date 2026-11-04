import { describe, expect, it } from "vitest";
import { coverageDays, coverageLabel, coveredShare, movementDate, poolOthers, subtractDecimal } from "./inventory";

describe("exact decimal subtraction", () => {
  it("keeps thousandths without float error", () => {
    expect(subtractDecimal("0.300", "0.100")).toBe("0.200");
    expect(subtractDecimal("5.250", "1.125")).toBe("4.125");
  });
  it("handles negatives and different scales", () => {
    expect(subtractDecimal("1.000", "2.500")).toBe("-1.500");
    expect(subtractDecimal("-1.5", "0.25")).toBe("-1.75");
    expect(subtractDecimal("3", "3")).toBe("0");
  });
  it("rejects anything that is not a decimal", () => {
    expect(() => subtractDecimal("1,5", "1")).toThrow();
  });
});

describe("coverage from the server projection", () => {
  const window = { from: "2026-11-01T12:00:00Z", through: "2026-12-01T03:00:00Z" };
  it("reports the whole window when every planned dose is covered", () => {
    const item = { ...window, first_uncovered_at: null };
    expect(coverageDays(item)).toBeNull();
    expect(coverageLabel(item)).toBe("30 días o más");
    expect(coveredShare(item)).toBe(1);
  });
  it("counts complete days up to the first uncovered dose", () => {
    const item = { ...window, first_uncovered_at: "2026-11-04T08:00:00Z" };
    expect(coverageDays(item)).toBe(2);
    expect(coverageLabel(item)).toBe("2 días");
    expect(coveredShare(item)).toBeCloseTo(2.83 / 29.625, 2);
  });
  it("never goes below zero for an already uncovered dose", () => {
    expect(coverageDays({ ...window, first_uncovered_at: "2026-11-01T08:00:00Z" })).toBe(0);
    expect(coveredShare({ ...window, first_uncovered_at: "2026-11-01T08:00:00Z" })).toBe(0);
  });
});

describe("inventario compartido", () => {
  const member = (name: string | null, current: boolean, status: "pending" | "accepted" = "accepted") => ({ patient_display_name: name, you: false, current, status });
  it("nombra sólo a los demás miembros", () => {
    const pool = { pool_id: "p", status: "active" as const, members: [member("Mamá", true), member("Papá", false), member(null, false, "pending")] };
    expect(poolOthers(pool)).toBe("Papá, Paciente sin nombre");
    expect(poolOthers(pool, "pending")).toBe("Paciente sin nombre");
  });
  it("muestra la actividad ajena sólo con fecha y sin cambiar de día", () => {
    expect(movementDate({ created_at: "2026-11-02T00:00:00Z", reason: "shared_activity" })).toBe("02-11-2026");
  });
});
