import type { Addon, MetaItem } from "../lib/types";
import { catalogRefs, fetchCatalog, type CatalogRef } from "../lib/addon";
import { escapeHtml, httpUrl } from "../lib/dom";
import { hashFor } from "../lib/router";
import { icon } from "../lib/icons";
import { continueWatching } from "../lib/store";

// The Home board: one poster rail per loadable catalog across the installed add-ons (the same shape as
// desktop/src/main.ts renderBoard, but fetched directly from the add-on protocol instead of read from
// the engine's `board` model). Rails stream in as their fetches resolve so the page fills progressively.

/** Render the static Home shell; rails are filled in by loadBoard as catalogs resolve. */
export function renderBoardShell(host: HTMLElement, addons: Addon[]): void {
  const refs = catalogRefs(addons);
  if (!refs.length) {
    host.innerHTML = emptyBoard();
    return;
  }
  const rails = refs
    .map(
      (ref, i) => `
      <section class="rail-section" aria-labelledby="rail-${i}">
        <h2 class="rail-title" id="rail-${i}">${escapeHtml(railTitle(ref))}</h2>
        <div class="rail" id="rail-body-${i}" role="list">${railSkeleton()}</div>
      </section>`,
    )
    .join("");
  host.innerHTML = `<div class="board"><section class="featured" id="featured" aria-label="Featured" hidden></section>${continueWatchingRail()}${rails}</div>`;
}

/** A "Continue Watching" rail of in-progress titles, shown at the top of Home. Empty when nothing is
 *  in progress. Cards reuse posterCard and link to Detail (where re-playing resumes from the saved spot). */
function continueWatchingRail(): string {
  const cw = continueWatching();
  if (!cw.length) return "";
  return `
    <section class="rail-section" aria-labelledby="rail-cw">
      <h2 class="rail-title" id="rail-cw">Continue Watching</h2>
      <div class="rail" role="list">${cw
        .map((item) =>
          removableCard(
            item,
            "cw",
            "Remove from Continue Watching",
            item.duration > 0 ? item.position / item.duration : undefined,
          ),
        )
        .join("")}</div>
    </section>`;
}

/** Fetch each catalog and paint its rail; bad add-ons leave an empty rail rather than failing Home. */
export async function loadBoard(addons: Addon[]): Promise<void> {
  const refs = catalogRefs(addons);
  let heroSeeded = false;
  await Promise.all(
    refs.map(async (ref, i) => {
      const metas = await fetchCatalog(ref);
      const body = document.getElementById(`rail-body-${i}`);
      if (!body) return;
      const section = body.closest(".rail-section");
      if (!metas.length) {
        section?.classList.add("rail-empty");
        body.innerHTML = "";
        return;
      }
      // Wrap posterCard so map's index isn't passed as the `progress` arg (which would draw a full
      // progress track under every poster but the first).
      body.innerHTML = metas.slice(0, 30).map((m) => posterCard(m)).join("");
      // Seed the featured hero from the first catalog that returns art-bearing items (usually the first
      // rail, Cinemeta's popular). Top items become the rotation pool, mirroring the Apple home hero.
      if (!heroSeeded) {
        const pool = metas.filter((m) => Boolean(httpUrl(m.background) || httpUrl(m.poster))).slice(0, 5);
        if (pool.length) {
          heroSeeded = true;
          mountFeatured(pool);
        }
      }
    }),
  );
}

// ---- Featured hero (the Home billboard) ----
// A faithful port of the Apple `FeaturedHeroView`: a full-bleed `background` still with the dual scrim,
// a logo-or-serif-title, the ★rating · year · runtime · genres meta row, a Play action, and a 3-line
// synopsis (max-width 760, like the app). It rotates through a small pool of top items with an ambient
// cross-fade, pausing on hover and when the tab is hidden; reduced-motion shows a single static item.

const HERO_ROTATE_MS = 6000; // matches FeaturedHeroModel's ~6s ambient rotation
const HERO_FADE_MS = 280; // cross-fade out before swapping art + overlay, then fade back in

let heroPool: MetaItem[] = [];
let heroIndex = 0;
let heroTimer: number | undefined;

/** One featured item's billboard markup (art layer + scrim + bottom-left content block). */
function featuredHero(item: MetaItem): string {
  const name = escapeHtml(item.name ?? "");
  const bg = httpUrl(item.background) || httpUrl(item.poster);
  const logo = httpUrl(item.logo);
  const href = hashFor({ name: "detail", type: item.type, id: item.id });
  const title = logo
    ? `<img class="featured-logo" src="${escapeHtml(logo)}" alt="${name}" />`
    : `<h2 class="featured-title t-hero">${name}</h2>`;
  const synopsis = item.description
    ? `<p class="featured-synopsis">${escapeHtml(item.description)}</p>`
    : "";
  return `
    <div class="featured-bg" style="background-image:url('${escapeHtml(bg)}')"></div>
    <div class="featured-scrim" aria-hidden="true"></div>
    <div class="featured-content">
      ${title}
      ${featuredMeta(item)}
      <div class="featured-actions">
        <a class="btn-primary" href="${escapeHtml(href)}">${icon("play")}<span>Play</span></a>
      </div>
      ${synopsis}
    </div>`;
}

/** ★ imdb · year · runtime · genres(3) — same order + tokens as the app's hero meta row. */
function featuredMeta(item: MetaItem): string {
  const star = item.imdbRating
    ? `<span class="featured-rating">${icon("star")}${escapeHtml(item.imdbRating)}</span>`
    : "";
  const facts: string[] = [];
  if (item.releaseInfo) facts.push(escapeHtml(item.releaseInfo));
  if (item.runtime) facts.push(escapeHtml(item.runtime));
  const genres = (item.genres ?? []).slice(0, 3).join(" · ");
  if (genres) facts.push(escapeHtml(genres));
  if (!star && !facts.length) return "";
  const factSpan = facts.length ? `<span>${facts.join("  ·  ")}</span>` : "";
  return `<div class="featured-meta">${star}${factSpan}</div>`;
}

/** Paint the featured hero from a pool of top items and start the ambient rotation. */
function mountFeatured(pool: MetaItem[]): void {
  const host = document.getElementById("featured");
  if (!host || !pool.length) return;
  heroPool = pool;
  heroIndex = 0;
  host.hidden = false;
  host.innerHTML = featuredHero(pool[0]);
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced || pool.length < 2) return;
  host.addEventListener("mouseenter", stopHeroTimer);
  host.addEventListener("mouseleave", startHeroTimer);
  startHeroTimer();
}

function startHeroTimer(): void {
  stopHeroTimer();
  heroTimer = window.setInterval(() => {
    if (document.hidden) return; // pause while the tab is backgrounded
    const host = document.getElementById("featured");
    if (!host || heroPool.length < 2) {
      disposeFeatured();
      return;
    }
    heroIndex = (heroIndex + 1) % heroPool.length;
    host.classList.add("is-swapping");
    window.setTimeout(() => {
      const live = document.getElementById("featured");
      if (!live) return;
      live.innerHTML = featuredHero(heroPool[heroIndex]);
      live.classList.remove("is-swapping");
    }, HERO_FADE_MS);
  }, HERO_ROTATE_MS);
}

function stopHeroTimer(): void {
  if (heroTimer !== undefined) {
    window.clearInterval(heroTimer);
    heroTimer = undefined;
  }
}

/** Stop the rotation and drop references. The router calls this before leaving Home so the interval
 *  never fires against a detached DOM. */
export function disposeFeatured(): void {
  stopHeroTimer();
  heroPool = [];
  heroIndex = 0;
}

/** A single poster card linking to the detail route (an anchor, so it is keyboard-focusable). When a
 *  `progress` fraction (0..1) is given, a thin watched-progress track is drawn under the art (used by
 *  the Continue Watching rail); omitted everywhere else, so other grids are unchanged. */
export function posterCard(item: MetaItem, progress?: number): string {
  const name = escapeHtml(item.name ?? "");
  const art = httpUrl(item.poster);
  const href = hashFor({ name: "detail", type: item.type, id: item.id });
  const inner = art
    ? `<img class="poster-art" loading="lazy" src="${escapeHtml(art)}" alt="${name}" />`
    : `<div class="poster-art poster-art-empty" aria-hidden="true">${name.slice(0, 1)}</div>`;
  const bar =
    progress !== undefined && progress > 0
      ? `<span class="cw-progress" aria-hidden="true"><span style="width:${Math.min(100, Math.round(progress * 100))}%"></span></span>`
      : "";
  return `
    <a class="poster" role="listitem" href="${escapeHtml(href)}" title="${name}">
      ${inner}${bar}
      <span class="poster-name">${name}</span>
    </a>`;
}

/** A poster card wrapped with a remove (×) control, for the Continue Watching + Library rails. The button
 *  is a SIBLING of the card anchor (not nested) so clicking it removes rather than navigating. */
export function removableCard(item: MetaItem, kind: "cw" | "lib", label: string, progress?: number): string {
  return `<div class="card-wrap">${posterCard(item, progress)}<button class="card-remove" type="button" data-action="remove-saved" data-id="${escapeHtml(item.id)}" data-kind="${kind}" aria-label="${escapeHtml(label)}">×</button></div>`;
}

function railTitle(ref: CatalogRef): string {
  const label = ref.def.name?.trim() || `${ref.def.id} ${ref.def.type}`.trim();
  // Many add-ons repeat their own name in the catalog name; keep it but add the add-on as a quiet
  // suffix only when it adds information.
  return label;
}

function railSkeleton(): string {
  return Array.from({ length: 8 })
    .map(() => `<div class="poster poster-skeleton" aria-hidden="true"><div class="poster-art"></div></div>`)
    .join("");
}

function emptyBoard(): string {
  return `
    <div class="empty-state">
      <h2>No catalogs yet</h2>
      <p>Add a catalog or stream add-on to start browsing. Cinemeta should load by default - if you see
        this, the network blocked it. Check your connection and reload.</p>
    </div>`;
}
