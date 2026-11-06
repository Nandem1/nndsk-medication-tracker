import { expect, type APIRequestContext } from "@playwright/test";
import { e2eApiURL } from "../e2e-ports";

export const headers = (name: string) => ({ Authorization: "Bearer synthetic-" + name });

export async function call(request: APIRequestContext, name: string, method: "get" | "post" | "put" | "delete", path: string, data?: unknown) {
  const response = await request[method](e2eApiURL + "/v1" + path, { headers: headers(name), data: data as object });
  expect(response.status(), method + " " + path).toBeLessThan(300);
  return response.status() === 204 ? null : response.json();
}

/** Crea una familia administrada por admin y devuelve su id. */
export async function createFamily(request: APIRequestContext, admin: string, name = "Familia sintética") {
  const created = await call(request, admin, "post", "/families", { client_operation_id: crypto.randomUUID(), name });
  return created.family_id as string;
}

/** Une a member con el rol indicado, por el mismo flujo de invitación que usa la interfaz. */
export async function joinFamily(request: APIRequestContext, admin: string, member: string, family: string, role: "admin" | "caregiver" | "observer" | "patient") {
  const invitation = await call(request, admin, "post", "/families/" + family + "/invitations", { client_operation_id: crypto.randomUUID(), role });
  await call(request, member, "post", "/family-invitations/accept", { client_operation_id: crypto.randomUUID(), token: invitation.token });
}
