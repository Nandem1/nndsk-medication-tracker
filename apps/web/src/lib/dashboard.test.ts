import { describe, expect, it } from "vitest";
import { percent, reportPeriod, shiftDate, validReportRange } from "./dashboard";
describe("report periods", () => {
  it("keeps complete months and leap years", () => {
    expect(reportPeriod("2026-10-15", "month")).toEqual({ from: "2026-10-01", until: "2026-10-31" });
    expect(reportPeriod("2024-02-29", "month")).toEqual({ from: "2024-02-01", until: "2024-02-29" });
    expect(reportPeriod("2026-12-15", "month")).toEqual({ from: "2026-12-01", until: "2026-12-31" });
  });
  it("uses Monday through Sunday across year boundaries", () => {
    expect(reportPeriod("2027-01-03", "week")).toEqual({ from: "2026-12-28", until: "2027-01-03" });
  });
  it("keeps date arithmetic independent of DST", () => {
    expect(shiftDate("2026-09-05", 1)).toBe("2026-09-06");
    expect(shiftDate("2026-09-06", 1)).toBe("2026-09-07");
  });
  it("rejects inverted and excessive ranges", () => {
    expect(validReportRange("2024-01-01", "2024-12-31")).toBe(true);
    expect(validReportRange("2024-01-01", "2025-01-01")).toBe(false);
    expect(validReportRange("2026-11-02", "2026-11-01")).toBe(false);
    expect(validReportRange("", "2026-11-01")).toBe(false);
  });
  it("never presents empty denominators as zero percent", () => {
    expect(percent(null)).toBe("Sin datos evaluables");
    expect(percent(0)).toContain("0");
    expect(percent(0.5)).toContain("50");
  });
});
