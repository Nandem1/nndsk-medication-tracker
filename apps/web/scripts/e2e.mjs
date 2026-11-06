import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

// Una sola API y un solo Vite para toda la suite. Cada prueba usa identidades propias, así que
// pueden correr en paralelo; el límite de solicitudes del servidor E2E ya no obliga a aislarlas.
const require = createRequire(import.meta.url);
const cli = require.resolve("@playwright/test/cli");
const result = spawnSync(process.execPath, [cli, "test", ...process.argv.slice(2)], { stdio: "inherit" });
process.exit(result.status ?? 1);
