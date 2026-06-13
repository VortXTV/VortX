import { getVersion } from "@tauri-apps/api/app";

// Prove the Tauri bridge is live by reading the app version from the Rust backend. Wrapped so a
// permission or non-Tauri (plain browser preview) context never blanks the page.
async function showVersion(): Promise<void> {
  const el = document.getElementById("version");
  if (!el) return;
  try {
    el.textContent = `v${await getVersion()}`;
  } catch {
    el.textContent = "preview";
  }
}

void showVersion();
