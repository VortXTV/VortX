import "./styles/app.css";

import type { Addon } from "./lib/types";
import { loadInstalledAddons } from "./lib/store";
import { actionOf, el } from "./lib/dom";
import { clearProgress, removeFromLibrary, hideRail, clearHiddenRails, hiddenRailCount } from "./lib/store";
import { navigate, onRouteChange, parseRoute, type Route } from "./lib/router";
import { close as closePlayer, isPlayerOpen } from "./lib/player";
import { icon } from "./lib/icons";
import { initCardMenu } from "./lib/cardmenu";
import { disposeFeatured, loadBoard, renderBoardShell } from "./views/board";
import {
  discoverTypes,
  loadDiscover,
  loadMoreDiscover,
  renderDiscoverShell,
  selectDiscoverCatalog,
} from "./views/discover";
import { loadMoreSearch, loadSearch, renderSearchShell } from "./views/search";
import { renderAddons, wireAddons } from "./views/addons";
import { renderLibrary } from "./views/library";
import { loadLive, renderLive } from "./views/live";
import { closeDetail, handleDetailClick, openDetail } from "./views/detail";
import { handleSettingsClick, renderSettings } from "./views/settings";
import { handleLoginClick, renderLogin } from "./views/login";
import { applySettings } from "./lib/settings";
import { ensureValidSession } from "./lib/account";

// VortX web client entry point. Flow: load installed add-ons (Cinemeta + user stream add-ons) ->
// hash-routed surfaces (Home board, Discover grid, Search, Detail, Add-ons). Detail resolves streams
// straight from the add-on protocol and plays direct/debrid/HLS sources in an HTML5 <video> (hls.js
// for .m3u8). This is the browser-only counterpart to the native apps + the Tauri desktop shell - no
// engine, no streaming server, so it is direct/debrid/HLS-first by design (see README).

let addons: Addon[] = [];

const APP_SHELL = `
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="brandbar">
    <a class="brand" href="#/" aria-label="VortX home">Vort<svg class="brand-mark" viewBox="-8 -8 116 116" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><defs><linearGradient id="bm-b" x1="0" y1="0" x2="0.25" y2="1"><stop offset="0" stop-color="#fbbf24"/><stop offset="0.5" stop-color="#f59e0b"/><stop offset="1" stop-color="#d97706"/></linearGradient><linearGradient id="bm-d" x1="0" y1="0" x2="0.25" y2="1"><stop offset="0" stop-color="#b45309"/><stop offset="1" stop-color="#7c2d12"/></linearGradient></defs><path d="M9.2,4 C43.3,29.2 56.7,70.8 90.8,96" stroke="url(#bm-d)" stroke-width="18" stroke-linecap="round" fill="none"/><path d="M90.8,4 C56.7,29.2 43.3,70.8 9.2,96" stroke="url(#bm-b)" stroke-width="18" stroke-linecap="round" fill="none"/><circle cx="50" cy="50" r="7.2" fill="#fdf6e3"/></svg></a>
  </header>
  <main class="content" id="main"></main>
  <div class="overlay detail-overlay" id="detail-host"></div>
  <div class="overlay player-overlay hidden" id="player" aria-hidden="true"></div>
  <nav class="tabbar" aria-label="Primary">
    <a class="tab" data-nav="home" href="#/">${icon("home")}<span>Home</span></a>
    <a class="tab" data-nav="discover" href="#/discover/movie">${icon("discover")}<span>Discover</span></a>
    <a class="tab" data-nav="live" href="#/live">${icon("live")}<span>Live</span></a>
    <a class="tab" data-nav="library" href="#/library">${icon("library")}<span>Library</span></a>
    <a class="tab" data-nav="search" href="#/search/">${icon("search")}<span>Search</span></a>
    <a class="tab" data-nav="addons" href="#/addons">${icon("addons")}<span>Add-ons</span></a>
    <a class="tab" data-nav="settings" href="#/settings">${icon("settings")}<span>Settings</span></a>
  </nav>`;

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
            : route.name === "live"
              ? "live"
              : route.name === "settings"
                ? "settings"
                : route.name === "home"
                  ? "home"
                  : "";
  document.querySelectorAll<HTMLElement>(".tab").forEach((link) => {
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
  // A route change (e.g. browser back/forward) while the player overlay is open means the user navigated
  // away from playback, so tear the player down: otherwise it stays on top of the new route, the video
  // keeps playing audio, and its global key handler keeps capturing keystrokes.
  if (isPlayerOpen()) closePlayer();

  markActiveNav(route);
  document.title = pageTitle(route);

  // Leaving Detail for any non-detail route tears the overlay down.
  if (route.name !== "detail") setDetailVisible(false);

  // Stop the Home featured-hero rotation before painting any route; the Home case re-arms it. Without
  // this the rotation interval keeps firing against a detached DOM after the user navigates away.
  disposeFeatured();

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
    case "live": {
      // Live TV: its own page (channels grid, or a clean empty state when no live add-on is installed).
      const host = mainHost();
      renderLive(host, addons);
      await loadLive(addons);
      return;
    }
    case "settings": {
      renderSettings(mainHost());
      return;
    }
    case "login": {
      renderLogin(mainHost());
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
    if (hit?.action === "hide-rail") {
      // The × on a Home rail header: hide that catalog row (persisted) and yank the section from the DOM,
      // then surface the "Show N hidden rows" control without a full re-render.
      ev.preventDefault();
      const key = hit.node.dataset.railKey;
      if (key) {
        hideRail(key);
        hit.node.closest(".rail-section")?.remove();
        const btn = document.getElementById("rail-unhide");
        if (btn) {
          const n = hiddenRailCount();
          btn.textContent = `Show ${n} hidden row${n === 1 ? "" : "s"}`;
          btn.hidden = n === 0;
        }
      }
      return;
    }
    if (hit?.action === "show-hidden") {
      // Restore every hidden rail and re-render Home.
      ev.preventDefault();
      clearHiddenRails();
      void renderRoute(parseRoute());
      return;
    }
    if (hit?.action === "discover-more") {
      // The Discover "Load more" control: append the selected catalog's next page.
      ev.preventDefault();
      void loadMoreDiscover();
      return;
    }
    if (hit?.action === "discover-catalog") {
      // A Discover catalog chip: switch the shown catalog (no route change).
      ev.preventDefault();
      const key = hit.node.dataset.key;
      if (key) void selectDiscoverCatalog(key);
      return;
    }
    if (hit?.action === "search-more") {
      // The Search "Load more" control: append the next page across the active query's catalogs.
      ev.preventDefault();
      void loadMoreSearch();
      return;
    }
    if (hit?.action === "nav-home") {
      // Anchor already sets the hash; nothing extra needed, but stop the Detail handler eating it.
      return;
    }
    // Settings + Login are normal content routes (not overlays), so route their action clicks by route.
    if (parseRoute().name === "settings" && handleSettingsClick(ev.target)) {
      ev.preventDefault();
      return;
    }
    if (parseRoute().name === "login" && handleLoginClick(ev.target)) {
      ev.preventDefault();
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

/** Dismiss the branded splash (in index.html, painted before any JS). Mirrors the website's
 *  Splash.astro: the CSS `splashOut` keyframe lifts it on its own (~2.25s), so JS only gates it to
 *  once per session and removes the node after the animation; reduced motion / a repeat load skip it. */
function dismissSplash(): void {
  const splash = document.getElementById("splash");
  if (!splash) return;
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced || sessionStorage.getItem("vx-splash")) {
    splash.remove();
    return;
  }
  sessionStorage.setItem("vx-splash", "1");
  window.setTimeout(() => splash.remove(), 3000);
}

async function start(): Promise<void> {
  const app = el("app");
  if (!app) return;
  applySettings(); // theme + text size live before first paint (overrides the default :root tokens)
  dismissSplash();
  app.innerHTML = APP_SHELL;
  wireGlobalClicks();
  initCardMenu(); // right-click / long-press context menu on poster cards

  void ensureValidSession(); // clear a revoked token in the background; never blocks first paint
  addons = await loadInstalledAddons();
  onRouteChange((route) => void renderRoute(route));
  // Account hydration (on sign-in) merges synced add-ons into storage; reload + re-render so they appear.
  window.addEventListener("vortx:addons-changed", () => void reloadAddonsAndRender());
}

void start();
