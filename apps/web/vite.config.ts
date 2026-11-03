import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath } from "node:url";
import { e2eApiURL, e2eWebPort } from "./e2e-ports.ts";
export default defineConfig(({ mode, command }) => {
  if (mode === "e2e" && command === "build")
    throw new Error("Test identity cannot be built for distribution");
  return {
    plugins: [tailwindcss()],
    resolve: {
      alias: {
        "@": fileURLToPath(new URL("./src", import.meta.url)),
        "@identity": fileURLToPath(
          new URL(
            mode === "e2e" ? "./tests/identity.ts" : "./src/app/firebase.ts",
            import.meta.url,
          ),
        ),
      },
    },
    server: {
      host: "127.0.0.1",
      port: mode === "e2e" ? e2eWebPort : 5173,
      strictPort: true,
      proxy: {
        "/v1": {
          target:
            mode === "e2e"
              ? e2eApiURL
              : "https://api-staging-a498.up.railway.app",
          changeOrigin: true,
        },
      },
    },
    build: { sourcemap: false },
  };
});
