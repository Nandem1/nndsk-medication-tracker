import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "tests",
  testMatch: "**/*.e2e.ts",
  fullyParallel: false,
  workers: 1,
  timeout: 45000,
  use: {
    baseURL: "http://127.0.0.1:5173",
    headless: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: [
    {
      command: "go run -tags=e2e ./cmd/e2e",
      cwd: "../../services/api",
      url: "http://127.0.0.1:18083/healthz",
      reuseExistingServer: false,
      timeout: 60000,
    },
    {
      command: "pnpm exec vite --mode e2e",
      url: "http://127.0.0.1:5173",
      reuseExistingServer: false,
      timeout: 60000,
    },
  ],
});
