import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const cli = require.resolve("@playwright/test/cli");
const args = process.argv.slice(2);
const listing = spawnSync(process.execPath, [cli, "test", "--list", "--reporter=json", ...args], { encoding: "utf8" });
if (listing.status !== 0) {
  process.stderr.write(listing.stderr);
  process.exit(listing.status ?? 1);
}
const report = JSON.parse(listing.stdout);
const cases = [];
function collect(suite) {
  for (const spec of suite.specs ?? []) cases.push(`${spec.file}:${spec.line}`);
  for (const child of suite.suites ?? []) collect(child);
}
for (const suite of report.suites) collect(suite);
if (cases.length === 0) throw new Error("No se encontraron pruebas E2E.");
let failed = 0;
for (const [index, location] of cases.entries()) {
  const result = spawnSync(process.execPath, [cli, "test", location, "--output", `test-results/case-${index + 1}`, ...args], { stdio: "inherit" });
  if (result.status !== 0) failed++;
}
console.log(`E2E con servidores aislados: ${cases.length - failed}/${cases.length} casos aprobados.`);
process.exit(failed ? 1 : 0);
