import type { Addon } from "../lib/types";
import { CINEMETA_URL } from "../lib/addon";
import { addAddon, removeAddon } from "../lib/store";
import { actionOf, escapeHtml, httpUrl } from "../lib/dom";

// The Add-ons surface: list installed add-ons, add new ones by transport URL, and HEALTH-CHECK each one
// (the web twin of the Apple app's add-on status). The web client has no account, so this is the only way
// to bring in stream sources. Adding validates the manifest before persisting (see store.addAddon).

let onChanged: (() => void) | null = null;

const PROBE_TIMEOUT_MS = 6000;
const SLOW_THRESHOLD_MS = 2500;

type Health = "checking" | "online" | "slow" | "unreachable";
const HEALTH_LABEL: Record<Health, string> = {
  checking: "Checking…",
  online: "Online",
  slow: "Slow",
  unreachable: "Unreachable",
};

/** Render the add-ons manager. `onChange` is called after a successful add/remove to reload state. */
export function renderAddons(host: HTMLElement, addons: Addon[], onChange: () => void): void {
  onChanged = onChange;
  const rows = addons.map(addonRow).join("");
  host.innerHTML = `
    <div class="addons">
      <div class="addons-head">
        <h1 class="page-title">Add-ons</h1>
        <button class="chip" data-action="recheck-health">Re-check all</button>
      </div>
      <p class="addon-intro">
        VortX web plays two kinds of source: <strong>direct HTTPS</strong> streams and
        <strong>debrid</strong> (RealDebrid, AllDebrid, Premiumize, TorBox). Both play instantly in the
        browser. Plain torrents are listed but cannot play here yet, the web client has no streaming
        server, so debrid is how you turn torrents into playable links on the web.
      </p>
      <p class="addon-intro muted">
        For debrid: install a debrid-backed stream add-on (Torrentio, Comet, MediaFusion and similar)
        configured with your own debrid key. The key lives inside the add-on's manifest URL, never in
        VortX, so paste the personal manifest URL its configure page gives you into the field below.
      </p>
      <form class="addon-form" id="addon-form">
        <input class="search-input" id="addon-url" type="url" inputmode="url" autocomplete="off"
               placeholder="https://your-addon.example/manifest.json" aria-label="Add-on manifest URL" />
        <button class="chip" type="submit">Install</button>
      </form>
      <p class="addon-error" id="addon-error" role="alert" hidden></p>
      <div class="addon-list">${rows}</div>
    </div>`;
  void runHealthChecks(host);
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
        <div class="addon-name">
          ${escapeHtml(manifest.name ?? "Add-on")}
          <span class="addon-health checking" data-health-url="${escapeHtml(transportUrl)}" role="status">${HEALTH_LABEL.checking}</span>
        </div>
        <div class="addon-desc">${escapeHtml(manifest.description ?? "")}</div>
        ${types ? `<div class="addon-types">${escapeHtml(types)}</div>` : ""}
      </div>
      ${removeBtn}
    </div>`;
}

/** Fetch a manifest with a timeout, classifying the add-on as online / slow / unreachable by latency.
 *  CORS-restricted manifests can read as unreachable even when live; that is a browser limitation. */
async function probeAddon(url: string): Promise<{ status: Health; ms: number }> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), PROBE_TIMEOUT_MS);
  const start = performance.now();
  try {
    const res = await fetch(url, { signal: ctrl.signal, mode: "cors", cache: "no-store" });
    clearTimeout(timer);
    if (!res.ok) return { status: "unreachable", ms: 0 };
    await res.text(); // drain the body so the timing reflects a full fetch
    const ms = Math.round(performance.now() - start);
    return { status: ms > SLOW_THRESHOLD_MS ? "slow" : "online", ms };
  } catch {
    clearTimeout(timer);
    return { status: "unreachable", ms: 0 };
  }
}

/** Probe every add-on badge in the DOM concurrently and paint its status. DOM-driven (reads
 *  data-health-url) so it works for both the initial render and the Re-check button. */
async function runHealthChecks(host: HTMLElement): Promise<void> {
  const badges = [...host.querySelectorAll<HTMLElement>("[data-health-url]")];
  await Promise.all(
    badges.map(async (badge) => {
      const url = badge.dataset.healthUrl;
      if (!url) return;
      const { status, ms } = await probeAddon(url);
      paintHealth(badge, status, ms);
    }),
  );
}

function paintHealth(badge: HTMLElement, status: Health, ms: number): void {
  badge.classList.remove("checking", "online", "slow", "unreachable");
  badge.classList.add(status);
  badge.textContent = HEALTH_LABEL[status];
  badge.title =
    status === "unreachable"
      ? "No response (the add-on may be down, or block cross-origin requests from the browser)."
      : status === "checking"
        ? "Checking availability…"
        : `Responded in ${ms} ms`;
}

/** Wire the install form, remove buttons, and the Re-check control. Called once per render by main.ts. */
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
    if (!hit) return;
    if (hit.action === "remove-addon") {
      const url = hit.node.dataset.url;
      if (url) {
        removeAddon(url);
        onChanged?.();
      }
    } else if (hit.action === "recheck-health") {
      host.querySelectorAll<HTMLElement>("[data-health-url]").forEach((b) => paintHealth(b, "checking", 0));
      void runHealthChecks(host);
    }
  });
}
