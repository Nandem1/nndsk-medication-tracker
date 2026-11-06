import { test, expect } from "@playwright/test";
import { e2eApiURL } from "../e2e-ports";
import { invitationMessage } from "../src/lib/invitations";
import { createFamily, joinFamily } from "./families";

test("create account, create a family, invite with link and see names on both sides", async ({ browser }) => {
  const suffix = Date.now();
  const caregiver = await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const patient = await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const cp = await caregiver.newPage();
  const pp = await patient.newPage();
  for (const [page, account, name] of [[cp, "caregiver", "Hermana"], [pp, "patient", "Mamá"]] as const) {
    await page.goto("/");
    await page.getByRole("button", { name: "Crear cuenta", exact: true }).click();
    if (account === "caregiver") await page.screenshot({ path: test.info().outputPath("familia-p2-account.png"), fullPage: true });
    await page.getByLabel("Correo electrónico").fill(`family-${account}-${suffix}@example.test`);
    await page.getByLabel("Contraseña").fill("test-only");
    await page.getByRole("button", { name: "Crear mi cuenta", exact: true }).click();
    await expect(page.getByRole("heading", { name: "¿Cómo te llamas?" })).toBeVisible();
    await expect(page.getByRole("navigation")).toHaveCount(0);
    if (account === "caregiver") await page.screenshot({ path: test.info().outputPath("familia-p2-onboarding.png"), fullPage: true });
    await page.getByLabel("Nombre visible").fill(name);
    await page.getByRole("button", { name: "Continuar", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Personas a tu cuidado" })).toBeVisible();
  }
  await cp.getByRole("link", { name: "Invitar a la familia" }).click();
  await cp.getByLabel("Nombre de la familia").fill("Familia Vicente");
  await cp.getByRole("button", { name: "Crear familia", exact: true }).click();
  await expect(cp.getByRole("heading", { name: "Familia Vicente" })).toBeVisible();
  await expect(cp.getByLabel("Paciente", { exact: true })).toBeChecked();
  await cp.getByLabel("¿Cómo se llama? (opcional)").fill("Mamá");
  await cp.getByRole("button", { name: "Crear invitación", exact: true }).click();
  await expect(cp.getByRole("img", { name: "QR para unirse a Familia Vicente" })).toBeVisible();
  const token = await cp.getByLabel("Código de invitación").inputValue();
  await cp.getByRole("button", { name: "Copiar mensaje", exact: true }).click();
  await expect(cp.getByText("Mensaje copiado.", { exact: true })).toBeVisible();
  const message = await cp.evaluate(() => navigator.clipboard.readText());
  expect(message).toBe(invitationMessage(token, "Familia Vicente"));
  expect(message).toContain("mistomas://unirse#" + token);
  await cp.screenshot({ path: test.info().outputPath("familia-p2-invitation.png"), fullPage: true });
  await pp.getByRole("link", { name: "Familia", exact: true }).click();
  await pp.getByRole("link", { name: "Únete con un código" }).click();
  await pp.evaluate((text) => navigator.clipboard.writeText(text), message);
  await pp.getByRole("button", { name: "Pegar código", exact: true }).click();
  await expect(pp.getByRole("heading", { name: "Familia Vicente" })).toBeVisible();
  await expect(pp.getByText("Nombre sugerido: Mamá", { exact: true })).toBeVisible();
  await expect(pp.locator(".member-name").filter({ hasText: "Hermana" })).toBeVisible();
  await pp.screenshot({ path: test.info().outputPath("familia-ux-consent.png"), fullPage: true });
  await pp.getByLabel("Entiendo quiénes podrán ver mi información.").check();
  await pp.getByRole("button", { name: "Unirme a la familia" }).click();
  await expect(pp.getByRole("heading", { name: "Familia Vicente" })).toBeVisible();
  await expect(pp.locator(".member").filter({ hasText: "Hermana" }).getByText("Nuevo", { exact: true })).toBeVisible();
  await cp.getByRole("link", { name: "Pacientes", exact: true }).click();
  await expect(cp.getByRole("heading", { name: "Mamá", exact: true })).toBeVisible();
  await expect(cp.getByText("0 de 0 registradas", { exact: true })).toHaveCount(2);
  await cp.screenshot({ path: test.info().outputPath("familia-p2-patients.png"), fullPage: true });
  expect(await cp.locator("main").innerText()).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  await cp.getByRole("link").filter({ has: cp.getByRole("heading", { name: "Mamá", exact: true }) }).click();
  await cp.getByRole("button", { name: "Cambiar nombre", exact: true }).click();
  await cp.getByLabel("Nombre visible").fill("Madre");
  await cp.getByRole("button", { name: "Guardar nombre", exact: true }).click();
  await expect(cp.getByRole("heading", { name: "Madre", exact: true })).toBeVisible();
  await pp.getByRole("link", { name: "Mi perfil", exact: true }).click();
  await expect(pp.getByRole("heading", { name: "Madre", exact: true })).toBeVisible();
  await cp.setViewportSize({ width: 390, height: 844 });
  await cp.getByRole("link", { name: "Pacientes", exact: true }).click();
  expect(await cp.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await cp.screenshot({ path: test.info().outputPath("familia-p2-patients-mobile.png"), fullPage: true });
  await cp.emulateMedia({ colorScheme: "dark" });
  await cp.screenshot({ path: test.info().outputPath("familia-ux-patients-dark.png"), fullPage: true });
  await cp.getByRole("link", { name: "Familia", exact: true }).click();
  await cp.addStyleTag({ content: ":root { font-size: 200% !important; }" });
  expect(await cp.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await cp.screenshot({ path: test.info().outputPath("familia-ux-family-dark-large.png"), fullPage: true });
  await caregiver.close(); await patient.close();
});

test("password reset uses the same generic result for either account", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "¿Olvidaste tu contraseña?" }).click();
  for (const email of ["existing@example.test", "absent@example.test"]) {
    await page.getByLabel("Correo electrónico").fill(email);
    await page.getByRole("button", { name: "Enviar instrucciones" }).click();
    await expect(page.getByRole("status")).toHaveText("Si existe una cuenta con ese correo, recibirás instrucciones para recuperar tu contraseña.");
  }
});

test("profile editor keeps operation after response loss and rejects a stale version", async ({ page, request }) => {
  const name = "profile-" + Date.now();
  const headers = { Authorization: "Bearer synthetic-" + name };
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(name + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByLabel("Nombre visible").fill("Nombre inicial");
  const operations: string[] = [];
  await page.route("**/v1/me/profile", async (route) => {
    operations.push(route.request().postDataJSON().client_operation_id);
    if (operations.length === 1) { await route.fetch(); await route.abort(); }
    else await route.continue();
  });
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("No hay conexión");
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Personas a tu cuidado" })).toBeVisible();
  expect(operations).toHaveLength(2); expect(operations[0]).toBe(operations[1]);
  await page.unroute("**/v1/me/profile");
  await page.getByRole("link", { name: "Mi perfil", exact: true }).click();
  await page.getByRole("button", { name: "Cambiar nombre", exact: true }).click();
  await page.getByLabel("Nombre visible").fill("Borrador");
  const update = await request.put(e2eApiURL + "/v1/me/profile", { headers, data: { client_operation_id: crypto.randomUUID(), expected_version: 2, display_name: "Nombre remoto" } });
  expect(update.status()).toBe(200);
  await page.evaluate(() => window.dispatchEvent(new Event("visibilitychange")));
  await page.getByRole("button", { name: "Guardar nombre", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("La información cambió");
  await expect(page.getByLabel("Nombre visible")).toHaveValue("Borrador");
});

test("onboarding can close a failed session and reload a concurrent profile", async ({ page, request }) => {
  const name = "onboarding-" + Date.now();
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(name + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await expect(page.getByRole("heading", { name: "¿Cómo te llamas?" })).toBeVisible();
  const remote = await request.put(e2eApiURL + "/v1/me/profile", {
    headers: { Authorization: "Bearer synthetic-" + name },
    data: { client_operation_id: crypto.randomUUID(), expected_version: 1, display_name: "Nombre confirmado" },
  });
  expect(remote.status()).toBe(200);
  await page.getByLabel("Nombre visible").fill("Borrador local");
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("La información cambió");
  await page.getByRole("button", { name: "Recargar perfil", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Personas a tu cuidado" })).toBeVisible();
  await page.getByRole("button", { name: "Cerrar sesión", exact: true }).click();
  await page.route("**/v1/me", (route) => route.fulfill({ status: 500, json: {} }));
  await page.getByLabel("Correo electrónico").fill(name + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("No se pudo completar");
  await page.getByRole("button", { name: "Cerrar sesión", exact: true }).click();
  await expect(page.getByLabel("Correo electrónico")).toBeVisible();
});

test("delete account asks to confirm, closes the session and removes caregiver access", async ({ page, request }) => {
  const suffix = Date.now();
  const name = "borrar-" + suffix;
  const caregiverName = "cuida-" + suffix;
  const caregiver = { Authorization: "Bearer synthetic-" + caregiverName };
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(name + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByLabel("Nombre visible").fill("Persona que se va");
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Personas a tu cuidado" })).toBeVisible();
  const headers = { Authorization: "Bearer synthetic-" + name };
  const me = await (await request.get(e2eApiURL + "/v1/me", { headers })).json();
  await joinFamily(request, caregiverName, name, await createFamily(request, caregiverName), "patient");
  expect((await request.get(e2eApiURL + "/v1/patients/" + me.user_id + "/inventory", { headers: caregiver })).status()).toBe(200);

  await page.getByRole("link", { name: "Mi perfil", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Eliminar mi cuenta" })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath("familia-p6-eliminar.png"), fullPage: true });
  await page.getByLabel("Escribe BORRAR").fill("borrar");
  await page.getByRole("button", { name: "Eliminar definitivamente", exact: true }).click();
  await expect(page.getByText("Escribe BORRAR para confirmar.")).toBeVisible();
  expect((await request.get(e2eApiURL + "/v1/patients/" + me.user_id + "/inventory", { headers: caregiver })).status()).toBe(200);
  await page.getByLabel("Escribe BORRAR").fill("BORRAR");
  await page.getByRole("button", { name: "Eliminar definitivamente", exact: true }).click();
  await expect(page.getByRole("button", { name: "Iniciar sesión", exact: true })).toBeVisible();
  expect((await request.get(e2eApiURL + "/v1/patients/" + me.user_id + "/inventory", { headers: caregiver })).status()).toBe(404);
});
