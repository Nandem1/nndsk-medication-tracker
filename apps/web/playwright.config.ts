import { defineConfig } from "@playwright/test";
import { e2eApiURL, e2eWebURL } from "./e2e-ports.ts";
export default defineConfig({
  testDir: "tests",
  testMatch: "**/*.e2e.ts",
  fullyParallel: false,
  workers: 1,
  timeout: 45000,
  use: {
    baseURL: e2eWebURL,
    headless: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: [
    {
      command: "go run -tags=e2e ./cmd/e2e",
      cwd: "../../services/api",
      url: e2eApiURL + "/healthz",
      reuseExistingServer: false,
      timeout: 60000,
    },
    {
      command: "pnpm exec vite --mode e2e",
      url: e2eWebURL,
      reuseExistingServer: false,
      timeout: 60000,
    },
  ],
});
