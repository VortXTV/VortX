// 10-foot remote-input layer for the LG webOS + Samsung Tizen TV packages. This is ADDITIVE and inert
// on the browser build: initTvPlatform() no-ops unless isTvPlatform() is true (a webOS/Tizen user agent,
// the tizen/webOS globals, or an explicit `?tv=1` / localStorage override for desktop testing). So
// web.vortx.tv behaves exactly as before; only a real TV (or a forced test session) turns this on.
//
// What it adds on a TV:
//   - D-pad (arrow keys) spatial focus over the EXISTING focusable elements (the poster anchors, tabbar
//     tabs, detail buttons, settings controls). Nothing in the views changes: every card is already an
//     <a>/<button>, so a geometry-based "nearest focusable in the pressed direction" walk drives them.
//   - OK / Enter activates the focused element (synthesizes a click, which the app's delegated body click
//     handler + native anchors already handle).
//   - BACK (webOS keyCode 461, Tizen 10009) is context-aware: close the player, else leave Detail, else
//     head to Home, else exit the app to the launcher. Mirrors the app's own Escape handling in main.ts.
//   - A `tv` class on <html> so tv.css applies the overscan-safe, 10-foot presentation.
//
// The HTML5 <video> + hls.js playback path is untouched: while the player overlay is open this layer
// yields the arrow / OK keys to the player's own keyboard handler (Space/seek/volume in player.ts) and
// only keeps BACK, so playback on the TV works through the same socketless path as the browser.

import { el } from "./dom";
import { isPlayerOpen, close as closePlayer } from "./player";
import { navigate, parseRoute } from "./router";

// TV remote key codes that are not the standard arrows/Enter. webOS and Tizen each send their own BACK.
const KEY_BACK_WEBOS = 461;
const KEY_BACK_TIZEN = 10009;

type Dir = "up" | "down" | "left" | "right";

interface TizenApp {
  getCurrentApplication(): { exit(): void };
}
interface TvGlobals {
  tizen?: { application?: TizenApp };
  webOS?: { platformBack?: () => void };
  webOSSystem?: unknown;
}

let active = false;

/** Whether we are running as a TV app (or a forced test session). Kept liberal on purpose: a false
 *  positive only means the TV focus layer turns on, which degrades gracefully with a mouse anyway. */
export function isTvPlatform(): boolean {
  try {
    const ua = navigator.userAgent || "";
    if (/web0s|webos|tizen|smart-?tv|netcast|nettv|hbbtv/i.test(ua)) return true;
    const w = window as unknown as TvGlobals;
    if (w.tizen || w.webOS || w.webOSSystem) return true;
    const q = new URLSearchParams(location.search);
    if (q.get("tv") === "1") return true;
    if (localStorage.getItem("vortx.tv.force") === "1") return true;
  } catch {
    /* non-browser globals missing; treat as not-TV */
  }
  return false;
}

/** True for elements that consume typed characters (an on-screen keyboard field): we must not hijack
 *  their Left/Right (caret) or Enter (submit / IME), only let Up/Down move focus out of the field. */
function isTextInput(node: EventTarget | null): boolean {
  if (!(node instanceof HTMLElement)) return false;
  if (node.tagName === "TEXTAREA") return true;
  if (node.tagName === "INPUT") {
    const type = (node as HTMLInputElement).type;
    return !["button", "checkbox", "radio", "range", "submit", "reset", "color", "file"].includes(type);
  }
  return node.isContentEditable;
}

/** The focus scope for the current surface. Player open -> [] (yield entirely). Detail overlay active ->
 *  just the overlay (so the D-pad can't wander onto the surface behind it). Otherwise the persistent
 *  shell: brand, main content, and the tabbar. */
function scopeRoots(): HTMLElement[] {
  if (isPlayerOpen()) return [];
  const detail = el("detail-host");
  if (detail && detail.classList.contains("active")) return [detail];
  const roots: HTMLElement[] = [];
  const brand = document.querySelector<HTMLElement>(".brandbar");
  const main = el("main");
  const tabbar = document.querySelector<HTMLElement>(".tabbar");
  if (brand) roots.push(brand);
  if (main) roots.push(main);
  if (tabbar) roots.push(tabbar);
  return roots;
}

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** Is `node` laid out and not hidden? Rect-based so it also works for the position:fixed tabbar/brandbar
 *  (which have no offsetParent). Off-screen-but-scrollable rail cards intentionally still count. */
function isDisplayed(node: HTMLElement): boolean {
  if (node.hidden || node.closest("[hidden]")) return false;
  const r = node.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) return false;
  return getComputedStyle(node).visibility !== "hidden";
}

function focusablesIn(roots: HTMLElement[]): HTMLElement[] {
  const out: HTMLElement[] = [];
  for (const root of roots) {
    if (root.matches(FOCUSABLE) && isDisplayed(root)) out.push(root);
    root.querySelectorAll<HTMLElement>(FOCUSABLE).forEach((node) => {
      if (isDisplayed(node)) out.push(node);
    });
  }
  return out;
}

/** 1-D overlap length between [aMin,aMax] and [bMin,bMax] (0 when disjoint). */
function overlap(aMin: number, aMax: number, bMin: number, bMax: number): number {
  return Math.max(0, Math.min(aMax, bMax) - Math.max(aMin, bMin));
}

/** Directional cost from `a` to `b`: primary = center distance along the travel axis (must be positive
 *  in the pressed direction, else Infinity); cross = misalignment on the other axis, weighted so an
 *  in-row / in-column candidate always beats a diagonal one. Lowest cost wins. */
function cost(a: DOMRect, b: DOMRect, dir: Dir): number {
  const acx = a.left + a.width / 2;
  const acy = a.top + a.height / 2;
  const bcx = b.left + b.width / 2;
  const bcy = b.top + b.height / 2;
  const EPS = 1;
  if (dir === "left" || dir === "right") {
    const primary = dir === "right" ? bcx - acx : acx - bcx;
    if (primary <= EPS) return Infinity;
    const cross = overlap(a.top, a.bottom, b.top, b.bottom) > 0 ? 0 : Math.abs(bcy - acy);
    return primary + cross * 4;
  }
  const primary = dir === "down" ? bcy - acy : acy - bcy;
  if (primary <= EPS) return Infinity;
  const cross = overlap(a.left, a.right, b.left, b.right) > 0 ? 0 : Math.abs(bcx - acx);
  return primary + cross * 4;
}

/** Focus without the browser's abrupt default scroll, then bring the target fully into view (tv.css sets
 *  scroll-margin so it clears the fixed brand/tab bars). */
function focusEl(node: HTMLElement): void {
  node.focus({ preventScroll: true });
  node.scrollIntoView({ block: "nearest", inline: "nearest" });
}

/** A provisional seat is one we only land on because nothing better exists yet (the brand wordmark on the
 *  empty first-paint shell). queueReseat upgrades off it as soon as real content renders. */
function isProvisional(node: HTMLElement | null): boolean {
  return !!node && node.classList.contains("brand");
}

/** The element to seat focus on when nothing valid is focused. Prefers a natural 10-foot entry point -
 *  the featured hero Play, else the first real poster, else the active tab - over the first raw focusable
 *  (which would be a rail's hide-x). Falls back to any focusable, brand wordmark last. */
function preferredFocus(roots: HTMLElement[]): HTMLElement | null {
  const pick = (sel: string): HTMLElement | null => {
    for (const root of roots) {
      const found = root.querySelectorAll<HTMLElement>(sel);
      for (const node of found) if (isDisplayed(node)) return node;
    }
    return null;
  };
  const detailActive = el("detail-host")?.classList.contains("active");
  if (!detailActive) {
    const entry = pick(".featured .btn-primary") ?? pick("a.poster");
    if (entry) return entry;
  }
  const activeTab = document.querySelector<HTMLElement>(".tab.active");
  if (activeTab && isDisplayed(activeTab)) return activeTab;
  return focusablesIn(roots)[0] ?? null;
}

/** Ensure a sane focus target exists inside the current scope (so the first D-pad press lands somewhere).
 *  Returns the currently focused element when it is still valid. */
function ensureSeated(roots: HTMLElement[]): HTMLElement | null {
  const ae = document.activeElement as HTMLElement | null;
  if (ae && ae !== document.body && roots.some((r) => r.contains(ae)) && isDisplayed(ae)) return ae;
  const target = preferredFocus(roots);
  if (target) focusEl(target);
  return target;
}

/** Move focus one step in `dir` to the lowest-cost candidate in scope. */
function move(dir: Dir): void {
  const roots = scopeRoots();
  if (!roots.length) return;
  const current = ensureSeated(roots);
  if (!current) return;
  const from = current.getBoundingClientRect();
  const candidates = focusablesIn(roots);
  let best: HTMLElement | null = null;
  let bestCost = Infinity;
  for (const cand of candidates) {
    if (cand === current) continue;
    const c = cost(from, cand.getBoundingClientRect(), dir);
    if (c < bestCost) {
      bestCost = c;
      best = cand;
    }
  }
  if (best) focusEl(best);
}

/** BACK: close the player, else leave Detail, else head to Home, else exit to the launcher. Mirrors the
 *  Escape handling in main.ts, extended with the top-level exit a TV Back button needs. */
function back(): void {
  if (isPlayerOpen()) {
    closePlayer();
    return;
  }
  const detail = el("detail-host");
  if (detail && detail.classList.contains("active")) {
    navigate({ name: "home" });
    return;
  }
  if (parseRoute().name !== "home") {
    navigate({ name: "home" });
    return;
  }
  exitApp();
}

/** Return to the platform launcher from Home. Each TV exposes its own exit; window.close() is the webOS
 *  web-app fallback. */
function exitApp(): void {
  try {
    const w = window as unknown as TvGlobals;
    if (w.tizen?.application) {
      w.tizen.application.getCurrentApplication().exit();
      return;
    }
    if (w.webOS?.platformBack) {
      w.webOS.platformBack();
      return;
    }
    window.close();
  } catch {
    /* no launcher hook available (e.g. a forced desktop test session): stay in the app */
  }
}

function onKeydown(e: KeyboardEvent): void {
  if (!active) return;
  const editing = isTextInput(document.activeElement);

  // BACK first, on every surface (including over the player).
  if (
    e.keyCode === KEY_BACK_WEBOS ||
    e.keyCode === KEY_BACK_TIZEN ||
    e.key === "XF86Back" ||
    e.key === "GoBack" ||
    e.key === "BrowserBack" ||
    (e.key === "Backspace" && !editing) // desktop-test affordance
  ) {
    e.preventDefault();
    e.stopPropagation();
    back();
    return;
  }

  // While the player is open it owns the arrows / OK (seek, volume, play-pause); we only kept BACK above.
  if (isPlayerOpen()) return;

  switch (e.key) {
    case "ArrowUp":
    case "ArrowDown":
      e.preventDefault();
      e.stopPropagation();
      move(e.key === "ArrowUp" ? "up" : "down");
      return;
    case "ArrowLeft":
    case "ArrowRight":
      if (editing) return; // caret movement inside the field
      e.preventDefault();
      e.stopPropagation();
      move(e.key === "ArrowLeft" ? "left" : "right");
      return;
    case "Enter":
      if (editing) return; // native submit / on-screen keyboard
      e.preventDefault();
      e.stopPropagation();
      (document.activeElement as HTMLElement | null)?.click();
      return;
    default:
      return;
  }
}

/** Re-seat focus after a surface re-render tore the focused node out of the DOM. Debounced to a frame so
 *  a burst of mutations (a route paint, then its async rails) settles first. */
let reseatQueued = false;
function queueReseat(): void {
  if (reseatQueued) return;
  reseatQueued = true;
  requestAnimationFrame(() => {
    reseatQueued = false;
    const roots = scopeRoots();
    if (!roots.length) return; // player owns focus
    const ae = document.activeElement as HTMLElement | null;
    const valid = ae && ae !== document.body && ae.isConnected && roots.some((r) => r.contains(ae)) && isDisplayed(ae);
    // Keep a user-chosen focus, but upgrade off a provisional brand seat once real content has rendered.
    if (valid && !isProvisional(ae)) return;
    const target = preferredFocus(roots);
    if (target && target !== ae) focusEl(target);
  });
}

/** Turn on the TV remote-input layer. Idempotent, and a no-op off-TV so the browser build is unchanged. */
export function initTvPlatform(): void {
  if (active || !isTvPlatform()) return;
  active = true;
  document.documentElement.classList.add("tv");

  // Capture phase so we can claim the D-pad before the page scrolls and before the app's own document
  // keydown handlers (player shortcuts, the Escape handler) see keys we fully handle.
  document.addEventListener("keydown", onKeydown, true);

  // Re-seat focus when a surface repaints (route change) or the Detail overlay opens/closes.
  const observed = [el("main"), el("detail-host")].filter((n): n is HTMLElement => !!n);
  const mo = new MutationObserver(queueReseat);
  for (const node of observed) mo.observe(node, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  window.addEventListener("hashchange", queueReseat);

  // Seat an initial focus once the shell has painted.
  queueReseat();
}
