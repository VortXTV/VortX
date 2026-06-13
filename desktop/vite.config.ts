import { defineConfig } from "vite";

// Tauri expects a fixed port and serves the built frontend from ../dist (see tauri.conf.json).
// 1420 is the Tauri convention; failing hard if it is taken keeps dev and the shell in sync.
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
  },
  build: {
    target: "es2021",
    outDir: "dist",
    emptyOutDir: true,
  },
});
