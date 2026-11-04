import { describe, expect, it } from "vitest";
import { invitationMessage, invitationToken, invitationPresets } from "./invitations";
describe("invitaciones", () => {
  it("extrae un solo código del mensaje sin aceptar fragmentos", () => {
    const token = "A".repeat(43);
    expect(invitationToken(invitationMessage(token))).toBe(token);
    expect(() => invitationToken("A".repeat(44))).toThrow();
    expect(() => invitationToken(token + " " + token)).toThrow();
    expect(() => invitationToken("sin código")).toThrow();
  });
  it("mantiene read en cada preset y permisos explícitos", () => {
    expect(invitationPresets.map((preset) => preset.scopes)).toEqual([["read"], ["read", "doses"], ["read", "treatments", "doses", "inventory"]]);
  });
});
