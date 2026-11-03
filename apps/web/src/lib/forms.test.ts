import { describe, it, expect } from "vitest";
import { decimal, parseSchedule, nextDate } from "./forms";
describe("exact form quantities", () => {
  it("normalizes comma without floating-point arithmetic", () => {
    expect(decimal("0,125")).toBe("0.125");
    expect(decimal("999999999.999")).toBe("999999999.999");
  });
  it.each(["-1", "1.1234", "1e2", "1000000000", ""])("rejects %s", (value) =>
    expect(() => decimal(value)).toThrow(),
  );
  it("rejects zero dose", () => expect(() => decimal("0.000", true)).toThrow());
});
it("rejects repeated or invalid schedule slots and missing weekdays", () => {
  const f = new FormData();
  f.set("timezone", "America/Santiago");
  f.append("time", "08:00");
  f.append("time", "08:00");
  f.set("dose_quantity", "0.5");
  f.set("dst_policy", "reject");
  f.append("weekday", "1");
  expect(() => parseSchedule(f)).toThrow();
  f.set("time", "08:00");
  expect(parseSchedule(f).slots[0].quantity).toBe("0.5");
  f.delete("weekday");
  expect(() => parseSchedule(f)).toThrow();
});
it("advances local dates without DST arithmetic", () => {
  expect(nextDate("2026-09-06")).toBe("2026-09-07");
  expect(nextDate("2026-12-31")).toBe("2027-01-01");
});
it("preserves a different exact quantity at each time", () => {
  const f = new FormData();
  f.set("timezone", "America/Santiago");
  f.set("dst_policy", "reject");
  f.append("weekday", "1");
  f.append("time", "08:00");
  f.append("dose_quantity", "0.5");
  f.append("time", "20:00");
  f.append("dose_quantity", "1.25");
  expect(parseSchedule(f).slots).toEqual([
    { time: "08:00", quantity: "0.5" },
    { time: "20:00", quantity: "1.25" },
  ]);
});
