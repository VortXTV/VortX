import "./styles/app.css";

import type { Addon } from "./lib/types";
import { loadInstalledAddons } from "./lib/store";
import { actionOf, el } from "./lib/dom";
import { clearProgress, removeFromLibrary } from "./lib/store";
import { navigate, onRouteChange, parseRoute, type Route } from "./lib/router";
import { close as closePlayer, isPlayerOpen } from "./lib/player";
import { loadBoard, renderBoardShell } from "./views/board";
import { discoverTypes, loadDiscover, renderDiscoverShell } from "./views/discover";
import { loadSearch, renderSearchShell } from "./views/search";
import { renderAddons, wireAddons } from "./views/addons";
import { renderLibrary } from "./views/library";
import { closeDetail, handleDetailClick, openDetail } from "./views/detail";

// VortX web client entry point. Flow: load installed add-ons (Cinemeta + user stream add-ons) ->
// hash-routed surfaces (Home board, Discover grid, Search, Detail, Add-ons). Detail resolves streams
// straight from the add-on protocol and plays direct/debrid/HLS sources in an HTML5 <video> (hls.js
// for .m3u8). This is the browser-only counterpart to the native apps + the Tauri desktop shell - no
// engine, no streaming server, so it is direct/debrid/HLS-first by design (see README).

let addons: Addon[] = [];

const APP_SHELL = `
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="topbar">
    <a class="wordmark" href="#/" aria-label="VortX home">Vort<span class="accent">X</span></a>
    <nav class="topnav" aria-label="Primary">
      <a class="topnav-link" data-nav="home" href="#/">Home</a>
      <a class="topnav-link" data-nav="discover" href="#/discover/movie">Discover</a>
      <a class="topnav-link" data-nav="search" href="#/search/">Search</a>
      <a class="topnav-link" data-nav="library" href="#/library">Library</a>
      <a class="topnav-link" data-nav="addons" href="#/addons">Add-ons</a>
    </nav>
  </header>
  <main class="content" id="main"></main>
  <div class="overlay detail-overlay" id="detail-host"></div>
  <div class="overlay player-overlay hidden" id="player" aria-hidden="true"></div>`;

/** The main content host (everything except the Detail + Player overlays). */
function mainHost(): HTMLElement {
  return el("main") as HTMLElement;
}

/** Highlight the active top-nav link for the current route. */
function markActiveNav(route: Route): void {
  const active =
    route.name === "discover"
      ? "discover"
      : route.name === "search"
        ? "search"
        : route.name === "addons"
          ? "addons"
          : route.name === "library"
            ? "library"
            : route.name === "home"
              ? "home"
              : "";
  document.querySelectorAll<HTMLElement>(".topnav-link").forEach((link) => {
    link.classList.toggle("active", link.dataset.nav === active);
  });
}

/** Show or hide the Detail overlay (Detail is an overlay so it sits over the current surface). */
function setDetailVisible(visible: boolean): void {
  const host = el("detail-host");
  if (!host) return;
  host.classList.toggle("active", visible);
  if (!visible) {
    host.innerHTML = "";
    closeDetail();
  }
}

/** The browser tab / history / shared-link title for a route. Detail sets its own (the title name) once
 *  the meta loads, so it falls through to the bare brand here. */
function pageTitle(route: Route): string {
  switch (route.name) {
    case "discover":
      return "Discover · VortX";
    case "search":
      return route.query ? `${route.query} · Search · VortX` : "Search · VortX";
    case "library":
      return "Library · VortX";
    case "addons":
      return "Add-ons · VortX";
    default:
      return "VortX";
  }
}

/** Render a route. Async surfaces paint a shell synchronously, then stream content in. */
async function renderRoute(route: Route): Promise<void> {
  markActiveNav(route);
  document.title = pageTitle(route);

  // Leaving Detail for any non-detail route tears the overlay down.
  if (route.name !== "detail") setDetailVisible(false);

  switch (route.name) {
    case "home": {
      renderBoardShell(mainHost(), addons);
      await loadBoard(addons);
      return;
    }
    case "discover": {
      const types = discoverTypes(addons);
      const type = types.includes(route.type) ? route.type : (types[0] ?? "movie");
      renderDiscoverShell(mainHost(), addons, type);
      await loadDiscover(addons, type);
      return;
    }
    case "search": {
      renderSearchShell(mainHost(), route.query);
      wireSearchForm();
      if (route.query) await loadSearch(addons, route.query);
      return;
    }
    case "addons": {
      const host = mainHost();
      renderAddons(host, addons, () => void reloadAddonsAndRender());
      wireAddons(host);
      return;
    }
    case "library": {
      renderLibrary(mainHost());
      return;
    }
    case "detail": {
      const host = el("detail-host");
      if (!host) return;
      setDetailVisible(true);
      await openDetail(host, addons, route.type, route.id);
      return;
    }
  }
}

/** Reload the installed add-ons (after an install/remove) and re-render the current route. */
async function reloadAddonsAndRender(): Promise<void> {
  addons = await loadInstalledAddons();
  await renderRoute(parseRoute());
}

/** Submit the search form by navigating to the shareable search route. */
function wireSearchForm(): void {
  const form = document.getElementById("search-form") as HTMLFormElement | null;
  form?.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const input = document.getElementById("search-input") as HTMLInputElement | null;
    const query = input?.value.trim() ?? "";
    navigate({ name: "search", query });
  });
}

/** Global click delegation: Detail overlay clicks, player close, Escape-like back affordances. */
function wireGlobalClicks(): void {
  document.body.addEventListener("click", (ev) => {
    // The player overlay owns its own close button.
    const hit = actionOf(ev.target);
    if (hit?.action === "close-player") {
      ev.preventDefault();
      closePlayer();
      return;
    }
    if (hit?.action === "remove-saved") {
      // The × on a Continue Watching / Library card: drop it from the store and yank the card from the DOM
      // (no full re-render, so the rest of the rail stays put).
      ev.preventDefault();
      const id = hit.node.dataset.id;
      if (id) {
        if (hit.node.dataset.kind === "cw") clearProgress(id);
        else removeFromLibrary(id);
        hit.node.closest(".card-wrap")?.remove();
      }
      return;
    }
    if (hit?.action === "nav-home") {
      // Anchor already sets the hash; nothing extra needed, but stop the Detail handler eating it.
      return;
    }
    // While the Detail overlay is active, route its action clicks to the Detail handler.
    if (el("detail-host")?.classList.contains("active")) {
      void handleDetailClick(ev.target);
    }
  });

  // Escape closes the player, then the detail overlay.
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape") return;
    if (isPlayerOpen()) {
      closePlayer();
      return;
    }
    if (el("detail-host")?.classList.contains("active")) {
      navigate({ name: "home" });
    }
  });
}

async function start(): Promise<void> {
  const app = el("app");
  if (!app) return;
  app.innerHTML = APP_SHELL;
  wireGlobalClicks();

  addons = await loadInstalledAddons();
  onRouteChange((route) => void renderRoute(route));
}

void start();
