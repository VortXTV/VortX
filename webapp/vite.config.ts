import { defineConfig } from "vite";

// web.vortx.tv is a small static SPA deployed to Cloudflare Pages. No native shell, no fixed
// Tauri port: a normal Vite dev server and an ES2021 build that ships only hls.js as a real
// dependency. hls.js is dynamically imported in src/lib/player.ts, so the bundler already emits it as
// its own lazily-loaded chunk - the Board and Detail surfaces never pay for the player library until
// the user actually plays something. No manual chunking needed.
export default defineConfig({
  build: {
    target: "es2021",
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
  },
});
