import type { Addon } from "../lib/types";
import { CINEMETA_URL } from "../lib/addon";
import { addAddon, removeAddon } from "../lib/store";
import { actionOf, escapeHtml, httpUrl } from "../lib/dom";

// The Add-ons surface: list installed add-ons and add new ones by transport URL. The web client has no
// account, so this is the only way to bring in stream sources. Adding validates the manifest before
// persisting (see store.addAddon).

let onChanged: (() => void) | null = null;

/** Render the add-ons manager. `onChange` is called after a successful add/remove to reload state. */
export function renderAddons(host: HTMLElement, addons: Addon[], onChange: () => void): void {
  onChanged = onChange;
  const rows = addons.map(addonRow).join("");
  host.innerHTML = `
    <div class="addons">
      <h1 class="page-title">Add-ons</h1>
      <p class="muted">
        VortX web plays direct and debrid (HTTP/HLS) sources. To get playable streams, add a stream
        add-on that returns direct links, typically one backed by a debrid service. Torrent-only
        add-ons will list sources but the web app cannot play them (no streaming server).
      </p>
      <form class="addon-form" id="addon-form">
        <input class="search-input" id="addon-url" type="url" inputmode="url" autocomplete="off"
               placeholder="https://your-addon.example/manifest.json" aria-label="Add-on manifest URL" />
        <button class="chip" type="submit">Install</button>
      </form>
      <p class="addon-error" id="addon-error" role="alert" hidden></p>
      <div class="addon-list">${rows}</div>
    </div>`;
}

function addonRow(addon: Addon): string {
  const { manifest, transportUrl } = addon;
  const logo = httpUrl(manifest.logo);
  const art = logo
    ? `<img class="addon-logo" src="${escapeHtml(logo)}" alt="" />`
    : `<div class="addon-logo addon-logo-empty" aria-hidden="true">${escapeHtml((manifest.name ?? "?").slice(0, 1))}</div>`;
  const types = (manifest.types ?? []).join(", ");
  const isCinemeta = transportUrl === CINEMETA_URL;
  const removeBtn = isCinemeta
    ? `<span class="chip chip-static">Default</span>`
    : `<button class="chip" data-action="remove-addon" data-url="${escapeHtml(transportUrl)}">Remove</button>`;
  return `
    <div class="addon-card">
      ${art}
      <div class="addon-text">
        <div class="addon-name">${escapeHtml(manifest.name ?? "Add-on")}</div>
        <div class="addon-desc">${escapeHtml(manifest.description ?? "")}</div>
        ${types ? `<div class="addon-types">${escapeHtml(types)}</div>` : ""}
      </div>
      ${removeBtn}
    </div>`;
}

/** Wire the install form + remove buttons. Called once per render by main.ts. */
export function wireAddons(host: HTMLElement): void {
  const form = host.querySelector<HTMLFormElement>("#addon-form");
  form?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const input = host.querySelector<HTMLInputElement>("#addon-url");
    const errorEl = host.querySelector<HTMLElement>("#addon-error");
    const url = input?.value.trim();
    if (!url || !errorEl) return;
    errorEl.hidden = true;
    try {
      await addAddon(url);
      onChanged?.();
    } catch {
      errorEl.textContent = "That URL is not a valid Stremio add-on manifest. Check the link and try again.";
      errorEl.hidden = false;
    }
  });

  host.addEventListener("click", (ev) => {
    const hit = actionOf(ev.target);
    if (hit?.action === "remove-addon") {
      const url = hit.node.dataset.url;
      if (url) {
        removeAddon(url);
        onChanged?.();
      }
    }
  });
}
