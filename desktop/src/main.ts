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

// StremioX desktop frontend. Flow: Home board (poster rails) -> click a poster -> the detail overlay
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
    content.innerHTML = rails.join("");
    setStatus("");
  }
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

    const poster = target.closest<HTMLElement>(".poster");
    if (poster?.dataset.id && poster.dataset.type) {
      void openDetail(poster.dataset.type, poster.dataset.id);
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

  void awaitServer();

  // Re-render the visible surface whenever the engine reports new state.
  await listen("core-event", () => {
    if (isDetailOpen()) void refreshDetail();
    else void getState<Board>("board").then(renderBoard);
  });

  await dispatch("board", { action: "Load", args: { model: "CatalogsWithExtra", args: { type: null, extra: [] } } });
  await dispatch("board", {
    action: "CatalogsWithExtra",
    args: { action: "LoadRange", args: { start: 0, end: 30 } },
  });

  for (let i = 0; i < 8; i++) {
    setTimeout(() => {
      if (!isDetailOpen()) void getState<Board>("board").then(renderBoard);
    }, i * 700);
  }
}

void start();
