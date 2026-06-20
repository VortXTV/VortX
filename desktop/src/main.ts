import { listen } from "@tauri-apps/api/event";

import type { Board, MetaItem } from "./engine";
import { dispatch, getState } from "./engine";
import {
  closeDetail,
  handleDetailClick,
  isDetailOpen,
  openDetail,
  refresh as refreshDetail,
  setPlayHandler,
} from "./detail";
import { primeAvailability } from "./server";
import { close as closePlayer, play as openPlayer } from "./player";
import { icon, type IconName } from "./icons";

// VortX desktop frontend. Flow: Home board (poster rails) -> click a poster -> the detail overlay
// (backdrop, hero, meta, per-add-on streams + quality selector, trailer) -> click a stream / Watch ->
// play in mpv (libmpv, via the player.ts sink), with a webview <video> fallback for plain H.264/AAC.
// The detail page lives in detail.ts; the player sink lives in player.ts; this file owns the board +
// top-level wiring, and re-renders the visible surface whenever the engine emits a `core-event`.

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string,
  );
}
function httpUrl(value: string | undefined): string {
  return value && /^https?:\/\//i.test(value) ? value : "";
}
function setStatus(text: string): void {
  const el = document.getElementById("status");
  if (el) el.textContent = text;
}
function el(id: string): HTMLElement | null {
  return document.getElementById(id);
}

// ---- Home board ----------------------------------------------------------

function renderBoard(board: Board | null): void {
  const content = el("content");
  if (!content || !board?.catalogs) return;
  const rails: string[] = [];
  for (const group of board.catalogs) {
    const page = group.find((p) => p.content?.type === "Ready" && (p.content.content?.length ?? 0) > 0);
    if (!page?.content?.content) continue;
    const id = page.request?.path?.id ?? "Catalog";
    const type = page.request?.path?.type ?? "";
    const title = escapeHtml(`${id} ${type}`.trim());
    const cards = page.content.content
      .slice(0, 30)
      .map((item: MetaItem) => {
        const name = escapeHtml(item.name ?? "");
        const art = httpUrl(item.poster);
        const inner = art
          ? `<img class="art" loading="lazy" src="${escapeHtml(art)}" alt="${name}" />`
          : `<div class="art"></div>`;
        return `<div class="poster" data-type="${escapeHtml(item.type)}" data-id="${escapeHtml(item.id)}" title="${name}">${inner}<div class="name">${name}</div></div>`;
      })
      .join("");
    rails.push(`<section><h2 class="rail-title">${title}</h2><div class="rail">${cards}</div></section>`);
  }
  if (rails.length) {
    content.innerHTML = boardFeatured(board) + rails.join("");
    setStatus("");
  }
}

/** The featured hero atop the board: the first art-bearing item of the first ready catalog, rendered as
 *  a full-bleed billboard (matching the webapp Home hero). Empty string when no art-bearing item. */
function boardFeatured(board: Board): string {
  for (const group of board.catalogs ?? []) {
    const page = group.find((p) => p.content?.type === "Ready" && (p.content.content?.length ?? 0) > 0);
    const item = page?.content?.content?.find((m: MetaItem) => httpUrl(m.background) || httpUrl(m.poster));
    if (item) return featuredHeroHtml(item);
  }
  return "";
}

function featuredHeroHtml(item: MetaItem): string {
  const name = escapeHtml(item.name ?? "");
  const bg = httpUrl(item.background) || httpUrl(item.poster);
  const logo = httpUrl(item.logo);
  const title = logo
    ? `<img class="featured-logo" src="${escapeHtml(logo)}" alt="${name}" />`
    : `<h2 class="featured-title">${name}</h2>`;
  const facts: string[] = [];
  if (item.releaseInfo) facts.push(escapeHtml(item.releaseInfo));
  if (item.runtime) facts.push(escapeHtml(item.runtime));
  const g = (item.links ?? []).filter((l) => l.category.toLowerCase() === "genre").map((l) => l.name).slice(0, 3);
  if (g.length) facts.push(escapeHtml(g.join(" · ")));
  const meta = facts.length ? `<div class="featured-meta">${facts.join("  ·  ")}</div>` : "";
  const desc = item.description ? `<p class="featured-synopsis">${escapeHtml(item.description)}</p>` : "";
  return `
    <section class="featured" data-type="${escapeHtml(item.type)}" data-id="${escapeHtml(item.id)}">
      <div class="featured-bg" style="background-image:url('${escapeHtml(bg)}')"></div>
      <div class="featured-scrim"></div>
      <div class="featured-content">
        ${title}
        ${meta}
        <div class="featured-actions"><button class="watch" data-action="board-play">${icon("play")}<span>Play</span></button></div>
        ${desc}
      </div>
    </section>`;
}

// ---- Bottom tab nav + router ---------------------------------------------
// A floating pill bottom bar (matching the webapp) + a hash router. Home renders the engine board;
// the other tabs are screens (filled in over subsequent ticks; placeholders for now). The core-event
// listener only repaints the board while Home is the active route.

interface NavTab {
  id: string;
  label: string;
  icon: IconName;
  hash: string;
}
const NAV: NavTab[] = [
  { id: "home", label: "Home", icon: "home", hash: "#/" },
  { id: "discover", label: "Discover", icon: "discover", hash: "#/discover" },
  { id: "live", label: "Live", icon: "live", hash: "#/live" },
  { id: "library", label: "Library", icon: "library", hash: "#/library" },
  { id: "search", label: "Search", icon: "search", hash: "#/search" },
  { id: "addons", label: "Add-ons", icon: "addons", hash: "#/addons" },
  { id: "settings", label: "Settings", icon: "settings", hash: "#/settings" },
];

let currentRoute = "home";

function renderNav(active: string): void {
  const bar = el("tabbar");
  if (!bar) return;
  bar.innerHTML = NAV.map(
    (t) =>
      `<a class="tab${t.id === active ? " active" : ""}" data-nav="${t.id}" href="${t.hash}">${icon(t.icon)}<span>${t.label}</span></a>`,
  ).join("");
}

function routeFromHash(): string {
  const seg = location.hash.replace(/^#\/?/, "").split("/")[0];
  return NAV.some((t) => t.id === seg) ? seg : "home";
}

function renderRoute(): void {
  // A nav change while the detail overlay is open means leaving detail.
  if (isDetailOpen()) closeDetail();
  currentRoute = routeFromHash();
  renderNav(currentRoute);
  if (currentRoute === "home") {
    void getState<Board>("board").then(renderBoard);
  } else {
    renderScreenPlaceholder(currentRoute);
  }
}

/** Honest placeholder for a screen not yet ported to the desktop (the web app has them today). */
function renderScreenPlaceholder(route: string): void {
  const content = el("content");
  if (!content) return;
  const label = NAV.find((t) => t.id === route)?.label ?? route;
  content.innerHTML = `<div class="screen-msg"><h2>${escapeHtml(label)}</h2><p>This screen is coming to the desktop app.</p></div>`;
  setStatus("");
}

// ---- Player --------------------------------------------------------------
// The player sink lives in player.ts (mpv via the Rust mpv_play command, webview <video> fallback).
// openPlayer / closePlayer are imported from there; this file only routes clicks to them.

// ---- Wiring --------------------------------------------------------------

function wireClicks(): void {
  document.body.addEventListener("click", (ev) => {
    const target = ev.target as HTMLElement;

    // The detail overlay owns its own clicks (streams, Watch, quality, sources, trailer, back).
    if (isDetailOpen()) {
      void handleDetailClick(target);
      return;
    }

    const action = target.closest<HTMLElement>("[data-action]")?.dataset.action;
    if (action === "close-player") {
      void closePlayer();
      return;
    }

    // A poster card or the featured hero (both carry data-type/data-id) opens the detail.
    const card = target.closest<HTMLElement>(".poster, .featured");
    if (card?.dataset.id && card.dataset.type) {
      void openDetail(card.dataset.type, card.dataset.id);
    }
  });
}

/**
 * Poll the embedded streaming server until it answers on loopback (it spawns + boots asynchronously
 * in the Rust backend). Once available, torrent streams stop being filtered out and the detail page
 * picks them up on its next repaint. Bounded so a server that never starts doesn't poll forever.
 */
async function awaitServer(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    if (await primeAvailability()) {
      // Repaint the open detail (if any) so torrent sources appear the moment the server is ready.
      if (isDetailOpen()) void refreshDetail();
      return;
    }
    await new Promise((r) => setTimeout(r, 750));
  }
}

async function start(): Promise<void> {
  wireClicks();
  setPlayHandler((url) => {
    closeDetail();
    void openPlayer(url);
  });

  // Paint the nav + route up front, BEFORE any engine call, so the UI never depends on the engine
  // booting (and a screen route renders even while the board is still loading).
  window.addEventListener("hashchange", renderRoute);
  renderRoute();

  void awaitServer();

  // Re-render the board whenever the engine reports new state, but only while Home is active (otherwise
  // an engine event would clobber whatever screen the router painted).
  await listen("core-event", () => {
    if (isDetailOpen()) void refreshDetail();
    else if (currentRoute === "home") void getState<Board>("board").then(renderBoard);
  });

  await dispatch("board", { action: "Load", args: { model: "CatalogsWithExtra", args: { type: null, extra: [] } } });
  await dispatch("board", {
    action: "CatalogsWithExtra",
    args: { action: "LoadRange", args: { start: 0, end: 30 } },
  });

  for (let i = 0; i < 8; i++) {
    setTimeout(() => {
      if (!isDetailOpen() && currentRoute === "home") void getState<Board>("board").then(renderBoard);
    }, i * 700);
  }
}

void start();
