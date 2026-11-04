import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import { e2eApiURL } from "../e2e-ports";

const op = () => crypto.randomUUID();
const headers = (name: string) => ({ Authorization: "Bearer synthetic-" + name });

async function call(request: APIRequestContext, name: string, method: "get" | "post" | "put", path: string, data?: unknown) {
  const response = await request[method](e2eApiURL + "/v1" + path, { headers: headers(name), data: data as object });
  expect(response.status(), method + " " + path).toBeLessThan(300);
  return response.json();
}
async function person(request: APIRequestContext, name: string, display: string) {
  const me = await call(request, name, "get", "/me");
  await call(request, name, "put", "/me/profile", { client_operation_id: op(), expected_version: me.profile_version, display_name: display });
  return me.user_id as string;
}
async function link(request: APIRequestContext, caregiver: string, patient: string) {
  const invitation = await call(request, caregiver, "post", "/invitations", { client_operation_id: op(), scopes: ["read", "doses", "treatments", "inventory"] });
  await call(request, patient, "post", "/invitations/accept", { client_operation_id: op(), token: invitation.token });
}
function clock(at: Date) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", hour: "2-digit", minute: "2-digit", hour12: false }).format(at);
}
async function treatment(request: APIRequestContext, caregiver: string, patient: string) {
  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  const passed = new Date(Math.max(now.getTime() - 120000, Date.parse(day + "T00:00:00Z")));
  return call(request, caregiver, "post", "/patients/" + patient + "/treatments", {
    client_operation_id: op(), name: "Losartán", strength_label: "50 mg", form: "comprimido", instructions: "Texto sintético.", unit: "tablet", initial_stock: "10.000", starts_on: day, ends_on: day,
    schedule: { timezone: "UTC", dst_policy: "next_valid_earliest", weekdays: [0, 1, 2, 3, 4, 5, 6], slots: [{ time: clock(passed), quantity: "0.500" }] },
  });
}
async function consume(request: APIRequestContext, name: string, patient: string) {
  const today = new Date().toISOString().slice(0, 10);
  const next = new Date(Date.parse(today) + 86400000).toISOString().slice(0, 10);
  const page = await call(request, name, "get", "/patients/" + patient + "/doses?from=" + today + "&to=" + next);
  const due = page.items.find((dose: { state: string }) => dose.state === "unconfirmed");
  await call(request, name, "post", "/doses/" + due.dose_id + "/events", { client_operation_id: op(), event_type: "taken", expected_version: due.version ?? 1 });
}
// La identidad sintética vive en memoria: recargar cerraría la sesión, así que se navega por la app.
async function openInventory(page: Page, displayName: string) {
  await page.getByRole("link", { name: "Mi perfil", exact: true }).click();
  await page.getByRole("link", { name: "Pacientes", exact: true }).click();
  await page.getByRole("link", { name: displayName, exact: true }).first().click();
  await page.getByRole("link", { name: "Inventario", exact: true }).click();
}

test.skip(new Date().getUTCHours() === 0 && new Date().getUTCMinutes() < 3, "La dosis vencida necesita un día UTC ya empezado");

test("propose, consent, shared balance and leave across two patients", async ({ page, request }) => {
  const suffix = Date.now();
  const [care, mamaUser, papaUser] = ["cuida", "mama", "papa"].map((n) => n + "-" + suffix);
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(care + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByLabel("Nombre visible").fill("Cuidadora");
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Personas a tu cuidado" })).toBeVisible();
  const mama = await person(request, mamaUser, "Mamá");
  const papa = await person(request, papaUser, "Papá");
  await link(request, care, mamaUser);
  await link(request, care, papaUser);
  await treatment(request, care, mama);
  await treatment(request, care, papa);

  await openInventory(page, "Mamá");
  await expect(page.locator(".balance")).toContainText("10.000");
  await page.screenshot({ path: test.info().outputPath("familia-p5-candidatos.png"), fullPage: true });
  await page.getByRole("button", { name: "Compartir con Papá", exact: true }).click();
  await expect(page.getByText("Esperando a Mamá, Papá").or(page.getByText("Esperando a Papá"))).toBeVisible();
  await expect(page.locator(".balance")).toContainText("10.000");
  await page.screenshot({ path: test.info().outputPath("familia-p5-esperando.png"), fullPage: true });

  for (const name of [mamaUser, papaUser]) {
    const pending = await call(request, name, "get", "/inventory-pools/pending");
    expect(pending.items).toHaveLength(1);
    expect(pending.items[0].medication_name).toBe("Losartán");
    await call(request, name, "post", "/inventory-pools/" + pending.items[0].pool_id + "/decision", { client_operation_id: op(), decision: "accept" });
  }
  await openInventory(page, "Mamá");
  await expect(page.getByText("Compartido con Papá", { exact: true })).toBeVisible();
  await expect(page.locator(".balance")).toContainText("20.000");

  await consume(request, mamaUser, mama);
  await consume(request, papaUser, papa);
  await openInventory(page, "Mamá");
  await expect(page.locator(".balance")).toContainText("19.000");
  await expect(page.getByRole("cell", { name: "Consumo declarado" })).toHaveCount(2);
  await expect(page.getByRole("cell", { name: "Actividad compartida" })).toHaveCount(0);
  await page.screenshot({ path: test.info().outputPath("familia-p5-compartido.png"), fullPage: true });
  await openInventory(page, "Papá");
  await expect(page.getByText("Compartido con Mamá", { exact: true })).toBeVisible();
  await expect(page.locator(".balance")).toContainText("19.000");

  await page.getByRole("button", { name: "Dejar de compartir", exact: true }).click();
  await expect(page.getByText("El saldo se queda con Mamá.", { exact: false })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath("familia-p5-salir.png"), fullPage: true });
  await page.getByRole("button", { name: "Confirmar", exact: true }).click();
  await expect(page.locator(".balance")).toContainText("0.000");
  await expect(page.getByRole("cell", { name: "Traspaso por inventario compartido" })).toBeVisible();
  await openInventory(page, "Mamá");
  await expect(page.locator(".balance")).toContainText("19.000");
  await expect(page.getByText("Compartido con", { exact: false })).toHaveCount(0);
});
