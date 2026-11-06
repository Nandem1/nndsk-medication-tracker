import { describe, expect, it } from "vitest";
import { coverageDays, coverageLabel, coveredShare, dateTimeLabel, movementDate, poolOthers, quantityLabel, subtractDecimal } from "./inventory";

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

describe("cantidades para mostrar en es-CL", () => {
  it("no deja ceros que se lean como miles", () => {
    expect(quantityLabel("19.000")).toBe("19");
    expect(quantityLabel("1000.000")).toBe("1000");
  });
  it("usa coma decimal y conserva cada decimal exacto", () => {
    expect(quantityLabel("-0.500")).toBe("-0,5");
    expect(quantityLabel("4.125")).toBe("4,125");
    expect(quantityLabel("123456789.001")).toBe("123456789,001");
  });
  it("no muestra un cero negativo", () => {
    expect(quantityLabel("0.000")).toBe("0");
    expect(quantityLabel("-0.000")).toBe("0");
  });
  it("rechaza lo que no es decimal", () => {
    expect(() => quantityLabel("1,5")).toThrow();
  });
  it("muestra fecha y hora sin segundos ni doble punto", () => {
    expect(dateTimeLabel("2026-11-05T12:43:18Z")).not.toMatch(/:18|\.\.$/);
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
  const member = (name: string | null, current: boolean) => ({ patient_display_name: name, you: false, current, status: "accepted" as const });
  it("nombra sólo a los demás miembros", () => {
    const pool = { pool_id: "p", status: "active" as const, members: [member("Mamá", true), member("Papá", false), member(null, false)] };
    expect(poolOthers(pool)).toBe("Papá, Paciente sin nombre");
  });
  it("muestra la actividad ajena sólo con fecha y sin cambiar de día", () => {
    expect(movementDate({ created_at: "2026-11-02T00:00:00Z", reason: "shared_activity" })).toBe("02-11-2026");
  });
});
