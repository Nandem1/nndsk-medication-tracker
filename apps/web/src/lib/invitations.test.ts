import { describe, expect, it } from "vitest";
import { initials, invitationLink, invitationMessage, invitationToken, isNewMember, roles } from "./invitations";

const token = "a".repeat(20) + "-_" + "B".repeat(21);

describe("invitaciones a la familia", () => {
  it("extrae el código del mensaje, del enlace o del código solo", () => {
    expect(invitationToken(invitationMessage(token, "Familia"))).toBe(token);
    expect(invitationToken(invitationLink(token))).toBe(token);
    expect(invitationToken(" " + token + " ")).toBe(token);
  });
  it("rechaza códigos distintos, largos o ausentes", () => {
    expect(() => invitationToken("A".repeat(44))).toThrow();
    expect(() => invitationToken(token + " " + "c".repeat(43))).toThrow();
    expect(() => invitationToken("sin código")).toThrow();
  });
  it("lleva el código en el fragmento del enlace", () => {
    expect(invitationLink(token)).toBe("mistomas://unirse#" + token);
  });
  it("ofrece los cuatro roles, con paciente primero", () => {
    expect(roles.map((role) => role.value)).toEqual(["patient", "caregiver", "observer", "admin"]);
  });
});

describe("miembros", () => {
  it("usa iniciales y nunca un identificador", () => {
    expect(initials("Mamá")).toBe("M");
    expect(initials("  ana  maría   pérez ")).toBe("AP");
    expect(initials(null)).toBe("?");
  });
  it("marca como nuevo durante una semana, salvo a uno mismo", () => {
    const now = Date.parse("2026-11-10T12:00:00Z");
    expect(isNewMember({ joined_at: "2026-11-05T12:00:00Z", you: false }, now)).toBe(true);
    expect(isNewMember({ joined_at: "2026-11-02T12:00:00Z", you: false }, now)).toBe(false);
    expect(isNewMember({ joined_at: "2026-11-09T12:00:00Z", you: true }, now)).toBe(false);
  });
});
