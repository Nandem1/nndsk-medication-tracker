import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import { call, createFamily, joinFamily } from "./families";

const op = () => crypto.randomUUID();

async function person(request: APIRequestContext, name: string, display: string) {
  const me = await call(request, name, "get", "/me");
  await call(request, name, "put", "/me/profile", { client_operation_id: op(), expected_version: me.profile_version, display_name: display });
  return me.user_id as string;
}
async function link(request: APIRequestContext, family: string, caregiver: string, patient: string) {
  await joinFamily(request, caregiver, patient, family, "patient");
}
// La pauta usa la zona de los pacientes: el informe de hoy también la usa.
const zone = "America/Santiago";
function clock(at: Date) {
  return new Intl.DateTimeFormat("en-GB", { timeZone: zone, hour: "2-digit", minute: "2-digit", hour12: false }).format(at);
}
function localDay(at: Date) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" }).format(at);
}
function nextDay(day: string) {
  return new Date(Date.parse(day + "T12:00:00Z") + 86400000).toISOString().slice(0, 10);
}
async function treatment(request: APIRequestContext, caregiver: string, patient: string) {
  const now = new Date();
  const day = localDay(now);
  const passed = new Date(now.getTime() - 120000);
  return call(request, caregiver, "post", "/patients/" + patient + "/treatments", {
    client_operation_id: op(), name: "Losartán", strength_label: "50 mg", form: "comprimido", instructions: "Texto sintético.", unit: "tablet", initial_stock: "10.000", starts_on: day, ends_on: day,
    schedule: { timezone: zone, dst_policy: "next_valid_earliest", weekdays: [0, 1, 2, 3, 4, 5, 6], slots: [{ time: clock(passed), quantity: "0.500" }] },
  });
}
async function consume(request: APIRequestContext, name: string, patient: string) {
  const today = localDay(new Date());
  const page = await call(request, name, "get", "/patients/" + patient + "/doses?from=" + today + "&to=" + nextDay(today));
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

test.skip(clock(new Date()) < "00:03", "La dosis vencida necesita un día ya empezado en la zona de los pacientes");

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
  const family = await createFamily(request, care);
  await link(request, family, care, mamaUser);
  await link(request, family, care, papaUser);
  await treatment(request, care, mama);
  await treatment(request, care, papa);

  await page.getByRole("link", { name: "Mi perfil", exact: true }).click();
  await page.getByRole("link", { name: "Pacientes", exact: true }).click();
  await expect(page.getByText("1 sin confirmar", { exact: true })).toHaveCount(2);
  await page.screenshot({ path: test.info().outputPath("familia-ux-pacientes.png"), fullPage: true });
  await openInventory(page, "Mamá");
  await expect(page.locator(".balance")).toHaveText("10 comprimidos");
  await page.screenshot({ path: test.info().outputPath("familia-p5-candidatos.png"), fullPage: true });
  // Dos stocks iniciales de 10 eran la misma caja: al contarla quedan 10, no 20.
  await page.getByRole("button", { name: "Misma caja que Papá", exact: true }).click();
  await page.getByLabel("¿Cuántos comprimidos hay en la caja?").fill("10");
  await page.getByRole("button", { name: "Compartir la caja", exact: true }).click();
  await expect(page.getByText("Misma caja que Papá", { exact: true })).toBeVisible();
  await expect(page.locator(".balance")).toHaveText("10 comprimidos");
  await page.screenshot({ path: test.info().outputPath("familia-p5-esperando.png"), fullPage: true });
  await consume(request, mamaUser, mama);
  await consume(request, papaUser, papa);
  await openInventory(page, "Mamá");
  await expect(page.locator(".balance")).toHaveText("9 comprimidos");
  await expect(page.getByRole("heading", { name: "Saldo común confirmado" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Consumo declarado" })).toHaveCount(2);
  await expect(page.getByRole("columnheader", { name: "Persona" })).toBeVisible();
  await expect(page.getByRole("row", { name: /Consumo declarado.*Papá/ })).toContainText("-0,5");
  await expect(page.getByRole("cell", { name: "Actividad compartida" })).toHaveCount(0);
  await page.screenshot({ path: test.info().outputPath("familia-p5-compartido.png"), fullPage: true });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByText("Registrar reposición", { exact: true }).click();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: test.info().outputPath("familia-ux-inventario-mobile-dark.png"), fullPage: true });
  await page.emulateMedia({ colorScheme: "light" });
  await page.setViewportSize({ width: 1280, height: 720 });
  await openInventory(page, "Papá");
  await expect(page.getByText("Misma caja que Mamá", { exact: true })).toBeVisible();
  await expect(page.locator(".balance")).toHaveText("9 comprimidos");

  await page.getByRole("button", { name: "Dejar de compartir", exact: true }).click();
  await expect(page.getByText("El saldo se queda con Mamá.", { exact: false })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath("familia-p5-salir.png"), fullPage: true });
  await page.getByRole("button", { name: "Confirmar", exact: true }).click();
  await expect(page.locator(".balance")).toHaveText("0 comprimidos");
  await expect(page.getByRole("cell", { name: "Traspaso por inventario compartido" })).toBeVisible();
  await openInventory(page, "Mamá");
  await expect(page.locator(".balance")).toHaveText("9 comprimidos");
  // Ya no comparten: no hay distintivo, y vuelve a ofrecerse la opción de compartir.
  await expect(page.locator(".shared-inventory .badge")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Misma caja que Papá", exact: true })).toBeVisible();
});
