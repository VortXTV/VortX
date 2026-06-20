// Card context menu: right-click (desktop) or long-press (touch) any poster card to act on it without
// opening the detail page first - Open, add/remove Library, Copy link. A competitor-parity navigation
// speed win (Weyd ships long-press action menus on every list). One global listener, reused across every
// surface that renders posterCard (Home rails, Discover, Search, Library), deriving the item straight from
// the card's existing DOM (href -> type/id, title -> name, .poster-art -> poster) so no card markup changes.

import { icon } from "./icons";
import { toggleLibrary, inLibrary } from "./store";
import type { MetaItem } from "./types";

const LONG_PRESS_MS = 450;

interface CardRef {
  href: string;
  type: string;
  id: string;
  item: MetaItem;
}

/** Pull the item identity out of a `.poster` anchor's existing DOM (no data attributes needed). */
function readCard(poster: HTMLElement): CardRef | null {
  const href = poster.getAttribute("href") ?? "";
  const m = href.match(/^#\/detail\/([^/]+)\/(.+)$/);
  if (!m) return null;
  const type = decodeURIComponent(m[1]);
  const id = decodeURIComponent(m[2]);
  const name = poster.getAttribute("title") ?? "";
  const poster_art = poster.querySelector<HTMLImageElement>(".poster-art");
  const poster_url = poster_art?.getAttribute("src") ?? undefined;
  return { href, type, id, item: { id, type, name, poster: poster_url } };
}

let openMenuEl: HTMLElement | null = null;

function closeMenu(): void {
  openMenuEl?.remove();
  openMenuEl = null;
}

function buildItem(label: string, ico: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "ctx-item";
  b.innerHTML = `${icon(ico)}<span>${label}</span>`;
  b.addEventListener("click", (ev) => {
    ev.stopPropagation();
    closeMenu();
    onClick();
  });
  return b;
}

function openMenu(card: CardRef, x: number, y: number): void {
  closeMenu();
  const menu = document.createElement("nav");
  menu.className = "ctx-menu";
  menu.setAttribute("role", "menu");

  menu.append(
    buildItem("Open", "play", () => {
      location.hash = card.href.replace(/^#/, "");
    }),
    buildItem(inLibrary(card.id) ? "Remove from Library" : "Add to Library", "bookmark", () => {
      toggleLibrary(card.item);
    }),
    buildItem("Copy link", "share", () => {
      const url = location.origin + location.pathname + card.href;
      void navigator.clipboard?.writeText(url).catch(() => {});
    }),
  );

  // Append off-screen first to measure, then clamp into the viewport so it never spills off an edge.
  menu.style.visibility = "hidden";
  document.body.appendChild(menu);
  const rect = menu.getBoundingClientRect();
  const left = Math.min(x, window.innerWidth - rect.width - 8);
  const top = Math.min(y, window.innerHeight - rect.height - 8);
  menu.style.left = `${Math.max(8, left)}px`;
  menu.style.top = `${Math.max(8, top)}px`;
  menu.style.visibility = "visible";
  openMenuEl = menu;
}

/** Attach the global context-menu behavior once, at app start. */
export function initCardMenu(): void {
  document.addEventListener("contextmenu", (ev) => {
    const poster = (ev.target as HTMLElement | null)?.closest<HTMLElement>(".poster");
    if (!poster) return;
    const card = readCard(poster);
    if (!card) return;
    ev.preventDefault();
    openMenu(card, ev.clientX, ev.clientY);
  });

  // Touch long-press. A move or early release cancels; otherwise open at the touch point.
  let pressTimer: number | undefined;
  let pressPoster: HTMLElement | null = null;
  const cancelPress = (): void => {
    if (pressTimer !== undefined) window.clearTimeout(pressTimer);
    pressTimer = undefined;
    pressPoster = null;
  };
  document.addEventListener(
    "touchstart",
    (ev) => {
      const poster = (ev.target as HTMLElement | null)?.closest<HTMLElement>(".poster");
      if (!poster) return;
      pressPoster = poster;
      const t = ev.touches[0];
      pressTimer = window.setTimeout(() => {
        if (!pressPoster) return;
        const card = readCard(pressPoster);
        if (card) openMenu(card, t.clientX, t.clientY);
        cancelPress();
      }, LONG_PRESS_MS);
    },
    { passive: true },
  );
  document.addEventListener("touchmove", cancelPress, { passive: true });
  document.addEventListener("touchend", cancelPress, { passive: true });

  // Dismiss on any outside interaction.
  document.addEventListener("click", (ev) => {
    if (openMenuEl && !(ev.target as HTMLElement).closest(".ctx-menu")) closeMenu();
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") closeMenu();
  });
  window.addEventListener("scroll", closeMenu, { passive: true });
}
