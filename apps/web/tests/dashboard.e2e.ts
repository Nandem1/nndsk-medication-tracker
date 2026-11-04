import { e2eApiURL } from "../e2e-ports";
import { test, expect } from "@playwright/test";
import { localDate } from "../src/lib/forms";
import { shiftDate } from "../src/lib/dashboard";

test("F7 dashboard, honest response calendar, history filters and persisted stock threshold", async ({ page, request }) => {
  const actor = "dashboard-" + Date.now();
  const headers = { Authorization: "Bearer synthetic-" + actor };
  const base = e2eApiURL + "/v1";
  const me = await request.get(base + "/me", { headers });
  expect(me.status()).toBe(200);
  const patientId: string = (await me.json()).user_id;
  const day = shiftDate(localDate(), -1);
  async function create(name: string, hours: string[], historical = true) {
    const response = await request.post(base + "/patients/" + patientId + "/treatments", { headers, data: {
      client_operation_id: crypto.randomUUID(), name, strength_label: "", form: "", package_label: "", instructions: "", unit: "tablet", initial_stock: "3.000", starts_on: day, ends_on: historical ? day : "",
      schedule: { timezone: "UTC", dst_policy: "reject", weekdays: [0, 1, 2, 3, 4, 5, 6], slots: hours.map((time) => ({ time, quantity: "0.500" })) },
    } });
    expect(response.status()).toBe(201);
    return response.json();
  }
  const treatment = await create("Registro sintético F7", ["08:00", "09:00", "10:00", "11:00"]);
  await create("Otro registro sintético F7", ["12:00"]);
  const inventory = await create("Reposición sintética F7", ["18:00"], false);
  const doseResponse = await request.get(base + "/patients/" + patientId + "/doses?from=" + day + "&to=" + shiftDate(day, 1) + "&treatment_id=" + treatment.treatment_id, { headers });
  expect(doseResponse.status()).toBe(200);
  const doses = (await doseResponse.json()).items.toSorted((a: { scheduled_at: string }, b: { scheduled_at: string }) => a.scheduled_at.localeCompare(b.scheduled_at));
  for (const [index, state] of ["taken", "taken_late", "skipped"].entries()) {
    const item = doses[index];
    const response = await request.post(base + "/doses/" + item.dose_id + "/events", { headers, data: {
      client_operation_id: crypto.randomUUID(), expected_version: 1, event_type: state,
      ...(state === "skipped" ? {} : { occurred_at: item.scheduled_at }),
    } });
    expect(response.status()).toBe(200);
  }
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(actor + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByLabel("Nombre visible").fill(actor);
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await page.getByRole("link").filter({ has: page.getByRole("heading", { name: actor }) }).click();
  await page.getByRole("link", { name: "Seguimiento", exact: true }).click();
  await page.getByLabel("Desde", { exact: true }).fill(shiftDate(day, -6));
  await page.getByLabel("Hasta, incluido").fill(day);
  await page.getByLabel("Tratamiento del informe").selectOption(treatment.treatment_id);
  await expect(page.getByText("2 tomadas / 4 evaluables", { exact: true })).toBeVisible();
  await expect(page.getByText("3 respuestas / 4 evaluables", { exact: true })).toBeVisible();
  await expect(page.getByText("1 dentro de ± 60 min / 2 tomadas", { exact: true })).toBeVisible();
  await expect(page.getByRole("list", { name: "Calendario de respuestas" }).getByText("3 de 4 respuestas")).toBeVisible();
  await expect(page.getByRole("list", { name: "Calendario de respuestas" }).getByText("1 sin confirmar · 1 omitidas declaradas")).toBeVisible();
  await expect(page.locator(".report-history li")).toHaveCount(4);
  await expect(page.locator(".report-history").getByText("Declarada omitida", { exact: true })).toBeVisible();
  const chart = page.getByRole("img", { name: /Dosis evaluables por día/ });
  await expect(chart).toHaveAttribute("aria-label", /1 declaradas tomadas, 1 declaradas tomadas tarde, 1 declaradas omitidas y 1 sin confirmar, de 4 evaluables/);
  await expect(page.locator(".chart-stack .series-unconfirmed")).toHaveCount(1);
  expect(await page.locator(".chart-stack .series-unconfirmed").evaluate((e) => getComputedStyle(e).backgroundImage)).toContain("repeating-linear-gradient");
  await expect(page.getByRole("list", { name: "Leyenda" }).getByRole("listitem")).toHaveText(["Tomada", "Tomada tarde", "Omitida", "Sin confirmar"]);
  await page.getByText("Ver como tabla", { exact: true }).click();
  await expect(page.getByRole("row", { name: day }).getByRole("cell")).toHaveText(["1", "1", "1", "1", "4"]);
  await page.screenshot({ path: test.info().outputPath("medication-f7-dashboard.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: test.info().outputPath("medication-f7-dashboard-mobile.png"), fullPage: true });
  await page.getByLabel("Tratamiento del informe").selectOption("");
  await expect(page.locator(".report-history li")).toHaveCount(6);
  await page.getByRole("button", { name: "Este mes", exact: true }).click();
  await expect(page.getByLabel("Desde", { exact: true })).toHaveValue(localDate().slice(0, 8) + "01");
  await expect(page.getByRole("region", { name: "Alertas" })).toBeVisible();
  await page.getByRole("link", { name: "Inventario", exact: true }).click();
  const selectAccount = () => page.getByRole("list", { name: "Cuentas de inventario" }).getByRole("button", { name: /Reposición sintética F7/ }).click();
  await selectAccount();
  const account = page.getByRole("article").filter({ has: page.getByRole("heading", { name: "Reposición sintética F7", exact: true }) });
  await account.getByLabel("Días de antelación").fill("10");
  await account.getByRole("button", { name: "Guardar antelación" }).click();
  await expect(account.getByText("Antelación configurada: 10 días.")).toBeVisible();
  const stock = await request.get(base + "/patients/" + patientId + "/inventory", { headers });
  expect((await stock.json()).items.find((item: { account_id: string }) => item.account_id === inventory.account_id).low_stock_days_threshold).toBe(10);
  await page.reload();
  await page.getByLabel("Correo electrónico").fill(actor + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByRole("link", { name: "Inventario", exact: true }).click();
  await selectAccount();
  await expect(account.getByLabel("Días de antelación")).toHaveValue("10");
  await expect(account.locator(".balance")).toContainText("3.000");
  await expect(account.locator(".is-estimate")).toHaveCSS("border-top-style", "dashed");
  await expect(account.getByRole("img", { name: /Según la agenda/ })).toBeVisible();
});

test("F7 read-only caregiver can view dashboard but cannot configure stock", async ({ page, request }) => {
  const suffix = Date.now();
  const base = e2eApiURL + "/v1";
  const caregiver = "f7-read-" + suffix;
  const patient = "f7-owner-" + suffix;
  const c = { Authorization: "Bearer synthetic-" + caregiver };
  const p = { Authorization: "Bearer synthetic-" + patient };
  const invitation = await request.post(base + "/invitations", { headers: c, data: { client_operation_id: crypto.randomUUID(), scopes: ["read"] } });
  expect(invitation.status()).toBe(201);
  const accept = await request.post(base + "/invitations/accept", { headers: p, data: { client_operation_id: crypto.randomUUID(), token: (await invitation.json()).token } });
  expect(accept.status()).toBe(200);
  const link = await accept.json();
  const created = await request.post(base + "/patients/" + link.patient_id + "/treatments", {
    headers: p,
    data: {
      client_operation_id: crypto.randomUUID(), name: "Inventario sólo lectura F7",
      strength_label: "", form: "", package_label: "", instructions: "", unit: "tablet",
      initial_stock: "3.000", starts_on: shiftDate(localDate(), 1), ends_on: "",
      schedule: { timezone: "UTC", dst_policy: "reject", weekdays: [0, 1, 2, 3, 4, 5, 6], slots: [{ time: "08:00", quantity: "0.500" }] },
    },
  });
  expect(created.status()).toBe(201);
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(caregiver + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByLabel("Nombre visible").fill(caregiver);
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await page.getByRole("link").filter({ has: page.getByRole("heading", { name: "Paciente sin nombre" }) }).click();
  await page.getByRole("link", { name: "Seguimiento", exact: true }).click();
  await expect(page.getByText("0 tomadas / 0 evaluables", { exact: true })).toBeVisible();
  await page.getByRole("link", { name: "Inventario", exact: true }).click();
  await expect(page.getByText("Tu acceso no permite cambiar el inventario.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Inventario sólo lectura F7", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Guardar antelación" })).toHaveCount(0);
  const revoke = await request.delete(base + "/caregiver-links/" + link.link_id, { headers: p });
  expect(revoke.status()).toBe(204);
  await page.getByRole("link", { name: "Seguimiento", exact: true }).click();
  await expect(page.getByLabel("Correo electrónico")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Seguimiento declarado" })).toHaveCount(0);
});

test("a patient without materialized doses opens Seguimiento without a conflict", async ({ page, request }) => {
  const actor = "fresh-report-" + Date.now();
  const headers = { Authorization: "Bearer synthetic-" + actor };
  const base = e2eApiURL + "/v1";
  const patientId = (await (await request.get(base + "/me", { headers })).json()).user_id;
  const created = await request.post(base + "/patients/" + patientId + "/treatments", { headers, data: {
    client_operation_id: crypto.randomUUID(), name: "Sin materializar", strength_label: "", form: "", package_label: "", instructions: "", unit: "tablet", initial_stock: "3.000", starts_on: shiftDate(localDate(), -5), ends_on: "",
    schedule: { timezone: "UTC", dst_policy: "reject", weekdays: [0, 1, 2, 3, 4, 5, 6], slots: [{ time: "00:00", quantity: "0.500" }] },
  } });
  expect(created.status()).toBe(201);
  await page.goto("/");
  await page.getByLabel("Correo electrónico").fill(actor + "@example.test");
  await page.getByLabel("Contraseña").fill("test-only");
  await page.getByRole("button", { name: "Iniciar sesión", exact: true }).click();
  await page.getByLabel("Nombre visible").fill(actor);
  await page.getByRole("button", { name: "Continuar", exact: true }).click();
  await page.getByRole("link").filter({ has: page.getByRole("heading", { name: actor }) }).click();
  await page.getByRole("link", { name: "Seguimiento", exact: true }).click();
  await expect(page.getByRole("img", { name: /Dosis evaluables por día/ })).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
});
