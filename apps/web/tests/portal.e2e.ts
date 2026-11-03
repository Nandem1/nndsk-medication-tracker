import { test, expect, type Page } from "@playwright/test";
import { localDate, nextDate } from "../src/lib/forms";
async function login(page: Page, name: string) {
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(name + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page
    .getByRole("button", { name: "Iniciar sesión", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Personas a tu cuidado" }),
  ).toBeVisible();
}
test("caregiver consent, treatment, agenda, inventory, archive and revocation through real API", async ({
  browser,
  request,
}) => {
  const suffix = Date.now().toString();
  const caregiver = "caregiver-" + suffix;
  const patient = "patient-" + suffix;
  const c = await browser.newContext();
  const p = await browser.newContext();
  const cp = await c.newPage();
  const pp = await p.newPage();
  await login(cp, caregiver);
  await cp.getByRole("link", { name: "Invitaciones y consentimiento" }).click();
  await cp.getByRole("button", { name: "Crear invitación" }).click();
  const code = await cp.getByLabel("Código de invitación").inputValue();
  await login(pp, patient);
  await pp.getByRole("link", { name: "Invitaciones y consentimiento" }).click();
  await pp.getByLabel("Código recibido").fill(code);
  await pp.getByRole("button", { name: "Revisar invitación" }).click();
  await expect(
    pp.getByRole("heading", { name: "Revisa antes de aceptar" }),
  ).toBeVisible();
  await pp.getByLabel("Entiendo los permisos").check();
  await pp.getByRole("button", { name: "Acepto y autorizo el acceso" }).click();
  await expect(
    pp.getByText("Acceso autorizado", { exact: false }),
  ).toBeVisible();
  await cp.getByRole("link", { name: "Pacientes", exact: true }).click();
  const patientCard = cp
    .getByRole("link")
    .filter({ has: cp.getByRole("heading", { name: /Paciente vinculado/ }) });
  await expect(patientCard).toHaveCount(1);
  await patientCard.click();
  const patientId = new URL(cp.url()).pathname.split("/").pop()!;
  await cp.getByRole("button", { name: "Nuevo tratamiento" }).click();
  await cp
    .getByLabel("Nombre del medicamento")
    .fill("Tratamiento sintético F3");
  await cp.getByLabel("Cantidad de la toma 1").fill("0,5");
  await cp.getByLabel("Stock inicial").fill("3");
  await cp.getByRole("button", { name: "Guardar tratamiento" }).click();
  await expect(
    cp.getByRole("heading", { name: "Tratamiento sintético F3", exact: true }),
  ).toBeVisible();
  const response = await request.get(
    "http://127.0.0.1:18083/v1/patients/" +
      patientId +
      "/doses?from=" +
      localDate() +
      "&to=" +
      nextDate(localDate()),
    { headers: { Authorization: "Bearer synthetic-" + caregiver } },
  );
  expect(response.status()).toBe(200);
  const agenda = await response.json();
  expect(agenda.items).toHaveLength(1);
  expect(agenda.items[0].quantity).toBe("0.500");
  await cp.getByRole("button", { name: "Agenda", exact: true }).click();
  await expect(
    cp.getByRole("heading", { name: "Tratamiento sintético F3", exact: true }),
  ).toBeVisible();
  await expect(
    cp.getByRole("button", { name: "Agenda", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await cp
    .getByRole("button", { name: "Agenda", exact: true })
    .evaluate(async (element) => {
      await Promise.all(
        element.getAnimations().map((animation) => animation.finished),
      );
    });
  expect(
    await cp
      .getByRole("button", { name: "Agenda", exact: true })
      .evaluate((element) => getComputedStyle(element).opacity),
  ).toBe("1");
  await cp.screenshot({
    path: "/private/tmp/medication-f3-agenda.png",
    fullPage: true,
  });
  await cp.getByRole("button", { name: "Inventario", exact: true }).click();
  await expect(cp.locator(".balance")).toContainText("3.000");
  const operations: string[] = [];
  await cp.route("**/v1/inventory/*/movements", async (route) => {
    if (route.request().method() !== "POST") {
      await route.continue();
      return;
    }
    operations.push(route.request().postDataJSON().client_operation_id);
    if (operations.length === 1) {
      await route.fetch();
      await route.abort("failed");
    } else await route.continue();
  });
  await cp.getByLabel("Cantidad recibida").fill("2.25");
  await cp.getByRole("button", { name: "Agregar reposición" }).click();
  await expect(cp.getByRole("alert")).toContainText("No hay conexión");
  await cp.getByRole("button", { name: "Agregar reposición" }).click();
  await expect(cp.locator(".balance")).toContainText("5.250");
  expect(operations).toHaveLength(2);
  expect(operations[0]).toBe(operations[1]);
  await cp.unroute("**/v1/inventory/*/movements");
  await cp.getByLabel("Cantidad contada").fill("4.125");
  await cp.getByLabel("Motivo del ajuste").fill("Conteo sintético");
  await cp.getByRole("button", { name: "Guardar conteo" }).click();
  await expect(cp.locator(".balance")).toContainText("4.125");
  await cp.getByText("Historial de movimientos", { exact: true }).click();
  await expect(cp.getByText(/Ajuste por conteo físico/)).toContainText(
    "-1.125",
  );
  await cp.getByRole("button", { name: "Tratamientos", exact: true }).click();
  await cp.getByRole("button", { name: "Editar datos" }).click();
  await cp
    .getByLabel("Nombre del medicamento")
    .fill("Tratamiento sintético editado");
  await cp.getByRole("button", { name: "Guardar datos" }).click();
  await expect(
    cp.getByRole("heading", { name: "Tratamiento sintético editado" }),
  ).toBeVisible();
  await cp.getByRole("button", { name: "Archivar tratamiento" }).click();
  await cp.getByLabel("Motivo del archivo").fill("Fin sintético");
  await cp.getByRole("button", { name: "Confirmar archivo" }).click();
  await expect(cp.getByText("Archivado", { exact: true })).toBeVisible();
  pp.on("dialog", (d) => d.accept());
  await pp.getByRole("button", { name: "Revocar acceso" }).click();
  await expect(pp.getByText("Acceso revocado", { exact: false })).toBeVisible();
  await cp.getByRole("button", { name: "Inventario", exact: true }).click();
  await expect(cp.getByRole("alert")).toContainText("No tienes permiso");
  await expect(
    cp.getByRole("heading", { name: "Tratamiento sintético editado" }),
  ).toHaveCount(0);
  await expect(cp.getByLabel("Correo electrónico")).toBeVisible();
  await c.close();
  await p.close();
});
test("network loading, empty, error and permission states", async ({
  page,
}) => {
  await page.route("**/v1/patients?**", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 500));
    await route.fulfill({ json: { items: [], next_cursor: "" } });
  });
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill("network@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page
    .getByRole("button", { name: "Iniciar sesión", exact: true })
    .click();
  await expect(page.getByRole("status")).toContainText("Cargando");
  await expect(
    page.getByText("No tienes pacientes vinculados.", { exact: false }),
  ).toBeVisible();
  await page.unroute("**/v1/patients?**");
  await page.route("**/v1/patients?**", (route) =>
    route.fulfill({ status: 500, json: {} }),
  );
  await page
    .getByRole("link", { name: "Invitaciones y consentimiento" })
    .click();
  await page.getByRole("link", { name: "Pacientes", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("No se pudo completar");
  await page.unroute("**/v1/patients?**");
  await page.route("**/v1/patients?**", (route) =>
    route.fulfill({ status: 404, json: {} }),
  );
  await page.getByRole("button", { name: "Volver a intentar" }).click();
  await expect(page.getByRole("alert")).toContainText("No tienes permiso");
});

test("a lost invitation response can be replaced by a new invitation", async ({
  page,
}) => {
  await login(page, "lost-invitation-" + Date.now());
  await page
    .getByRole("link", { name: "Invitaciones y consentimiento" })
    .click();
  const operations: string[] = [];
  await page.route("**/v1/invitations", async (route) => {
    operations.push(route.request().postDataJSON().client_operation_id);
    if (operations.length === 1) {
      const response = await route.fetch();
      expect(response.status()).toBe(201);
      await route.abort("failed");
    } else await route.continue();
  });
  await page.getByRole("button", { name: "Crear invitación" }).click();
  await expect(page.getByRole("alert")).toContainText("No hay conexión");
  await page.getByRole("button", { name: "Crear invitación" }).click();
  await expect(page.getByLabel("Código de invitación")).toHaveValue(
    /^[\w-]{43}$/,
  );
  expect(operations).toHaveLength(2);
  expect(operations[0]).not.toBe(operations[1]);
});

test("an open editor retains its version after a background update", async ({
  page,
  request,
}) => {
  const name = "concurrent-editor-" + Date.now();
  const headers = { Authorization: "Bearer synthetic-" + name };
  await login(page, name);
  await page
    .getByRole("link")
    .filter({ has: page.getByRole("heading", { name: "Mi registro" }) })
    .click();
  const patientId = new URL(page.url()).pathname.split("/").pop();
  await page.getByRole("button", { name: "Nuevo tratamiento" }).click();
  await page.getByLabel("Nombre del medicamento").fill("Synthetic original");
  await page.getByRole("button", { name: "Guardar tratamiento" }).click();
  await expect(
    page.getByRole("heading", { name: "Synthetic original", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Editar datos" }).click();
  await page.getByLabel("Nombre del medicamento").fill("Synthetic stale draft");
  const listURL =
    "http://127.0.0.1:18083/v1/patients/" + patientId + "/treatments";
  const initial = await request.get(listURL, { headers });
  const treatment = (await initial.json()).items[0];
  const update = await request.patch(
    "http://127.0.0.1:18083/v1/treatments/" + treatment.treatment_id,
    {
      headers,
      data: {
        client_operation_id: crypto.randomUUID(),
        expected_version: treatment.version,
        name: "Synthetic concurrent update",
        strength_label: "",
        form: "",
        package_label: "",
        instructions: "",
      },
    },
  );
  expect(update.status()).toBe(200);
  await page.evaluate(() =>
    window.dispatchEvent(new Event("visibilitychange")),
  );
  await expect(
    page.getByRole("heading", {
      name: "Synthetic concurrent update",
      exact: true,
    }),
  ).toBeVisible();
  await expect(page.getByLabel("Nombre del medicamento")).toHaveValue(
    "Synthetic stale draft",
  );
  await page.getByRole("button", { name: "Guardar datos" }).click();
  await expect(page.getByRole("alert")).toContainText("La información cambió");
  const current = await request.get(listURL, { headers });
  expect((await current.json()).items[0].name).toBe(
    "Synthetic concurrent update",
  );
  await page.getByRole("button", { name: "Cancelar edición" }).click();
  await page.getByRole("button", { name: "Editar datos" }).click();
  await expect(page.getByLabel("Nombre del medicamento")).toHaveValue(
    "Synthetic concurrent update",
  );
});
