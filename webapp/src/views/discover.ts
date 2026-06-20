import type { Addon, MetaItem } from "../lib/types";
import { catalogRefs, fetchCatalog, type CatalogRef } from "../lib/addon";
import { escapeHtml, httpUrl } from "../lib/dom";
import { hashFor } from "../lib/router";
import { mountFeatured, posterCard } from "./board";

// Discover: browse ONE catalog at a time, matching the app. A featured hero, a content-type switch, the
// catalogs of that type as selectable chips, then the selected catalog's poster grid with Load more.
// (The old version merged every catalog of a type into one grid; the apps pick a single catalog.)

/** The distinct content types present across installed add-on catalogs, for the type switch. */
export function discoverTypes(addons: Addon[]): string[] {
  const types = new Set<string>();
  for (const ref of catalogRefs(addons)) types.add(ref.def.type);
  const order = ["movie", "series", "channel", "tv"];
  return Array.from(types).sort((a, b) => {
    const ia = order.indexOf(a);
    const ib = order.indexOf(b);
    if (ia !== -1 || ib !== -1) return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
    return a < b ? -1 : 1;
  });
}

function catalogsForType(addons: Addon[], type: string): CatalogRef[] {
  return catalogRefs(addons).filter((r) => r.def.type === type);
}

/** A stable id for a catalog (unique across add-ons), used as the chip key + selection state. */
function catalogKey(ref: CatalogRef): string {
  return `${ref.addon.transportUrl}|${ref.def.type}|${ref.def.id}`;
}

function catalogLabel(ref: CatalogRef): string {
  return ref.def.name?.trim() || `${ref.def.id} ${ref.def.type}`.trim();
}

// Module state: the active type + selected catalog + that catalog's pagination. The selected catalog
// persists across renders when it is still valid (so switching type, then back, keeps your place).
let curAddons: Addon[] = [];
let curType = "";
let curKey = "";
let reqToken = 0;

interface CatState {
  ref: CatalogRef;
  skip: number;
  done: boolean;
  loading: boolean;
  lastFirstId?: string;
  seen: Set<string>;
  token: number;
}
let cat: CatState | null = null;

/** Render the Discover shell: featured hero + type chips + catalog chips + an empty grid. */
export function renderDiscoverShell(host: HTMLElement, addons: Addon[], type: string): void {
  curAddons = addons;
  curType = type;
  const refs = catalogsForType(addons, type);
  if (!refs.some((r) => catalogKey(r) === curKey)) curKey = refs[0] ? catalogKey(refs[0]) : "";

  const typeTabs = discoverTypes(addons)
    .map(
      (t) =>
        `<a class="chip${t === type ? " selected" : ""}" href="${escapeHtml(hashFor({ name: "discover", type: t }))}">${escapeHtml(
          titleCase(t),
        )}</a>`,
    )
    .join("");
  const catChips = refs
    .map(
      (r) =>
        `<button class="chip${catalogKey(r) === curKey ? " selected" : ""}" data-action="discover-catalog" data-key="${escapeHtml(
          catalogKey(r),
        )}">${escapeHtml(catalogLabel(r))}</button>`,
    )
    .join("");

  host.innerHTML = `
    <div class="discover">
      <section class="featured" id="featured" aria-label="Featured" hidden></section>
      <div class="discover-head">
        <h1 class="page-title">Discover</h1>
        <div class="type-switch" role="tablist" aria-label="Content type">${typeTabs}</div>
      </div>
      ${catChips ? `<div class="catalog-switch" aria-label="Catalogs">${catChips}</div>` : ""}
      <div class="grid" id="discover-grid" role="list">${gridSkeleton()}</div>
      <div class="discover-more-wrap" id="discover-more-wrap"></div>
    </div>`;
}

/** Load the selected catalog (defaulting to the first of the type) for `type`. */
export async function loadDiscover(addons: Addon[], type: string): Promise<void> {
  curAddons = addons;
  curType = type;
  const refs = catalogsForType(addons, type);
  if (!refs.some((r) => catalogKey(r) === curKey)) curKey = refs[0] ? catalogKey(refs[0]) : "";
  await loadSelectedCatalog();
}

/** Fetch the selected catalog's first page into the grid (+ featured hero + Load more). */
async function loadSelectedCatalog(): Promise<void> {
  const token = ++reqToken;
  const refs = catalogsForType(curAddons, curType);
  const ref = refs.find((r) => catalogKey(r) === curKey) ?? refs[0];
  const grid = document.getElementById("discover-grid");
  const wrap = document.getElementById("discover-more-wrap");
  if (!ref) {
    if (grid) grid.innerHTML = `<p class="muted">No catalogs for this type. Add a catalog add-on.</p>`;
    if (wrap) wrap.innerHTML = "";
    return;
  }
  const state: CatState = { ref, skip: 0, done: false, loading: false, seen: new Set<string>(), token };
  cat = state;
  const metas = await fetchCatalog(ref, 0);
  if (token !== reqToken || !grid) return; // a newer type/catalog selection superseded this load
  const fresh = dedupe(metas, state);
  state.skip = metas.length;
  state.lastFirstId = metas[0]?.id;
  if (!metas.length) state.done = true;
  if (!fresh.length) {
    grid.innerHTML = `<p class="muted">No titles in this catalog yet.</p>`;
    if (wrap) wrap.innerHTML = "";
    return;
  }
  grid.innerHTML = fresh.map((m) => posterCard(m)).join("");
  if (wrap) wrap.innerHTML = state.done ? "" : moreButton();
  mountFeatured(fresh.filter((m) => Boolean(httpUrl(m.background) || httpUrl(m.poster))).slice(0, 5));
}

/** Select a catalog chip (no route change): update the selection + reload its grid. */
export async function selectDiscoverCatalog(key: string): Promise<void> {
  if (!key || key === curKey) return;
  curKey = key;
  document
    .querySelectorAll<HTMLElement>(".catalog-switch .chip")
    .forEach((c) => c.classList.toggle("selected", c.dataset.key === key));
  const grid = document.getElementById("discover-grid");
  if (grid) grid.innerHTML = gridSkeleton();
  await loadSelectedCatalog();
}

/** Append the selected catalog's next page (the Load more click handler). */
export async function loadMoreDiscover(): Promise<void> {
  const state = cat;
  if (!state || state.loading || state.done || state.token !== reqToken) return;
  state.loading = true;
  const metas = await fetchCatalog(state.ref, state.skip);
  state.loading = false;
  if (state !== cat || state.token !== reqToken) return; // superseded
  const firstId = metas[0]?.id;
  // Exhausted when a page is empty or repeats its first item (a skip-ignoring add-on).
  if (!metas.length || (firstId !== undefined && firstId === state.lastFirstId)) {
    state.done = true;
    const wrap = document.getElementById("discover-more-wrap");
    if (wrap) wrap.innerHTML = "";
    return;
  }
  state.lastFirstId = firstId;
  state.skip += metas.length;
  const fresh = dedupe(metas, state);
  const grid = document.getElementById("discover-grid");
  if (grid && fresh.length) grid.insertAdjacentHTML("beforeend", fresh.map((m) => posterCard(m)).join(""));
  const wrap = document.getElementById("discover-more-wrap");
  if (wrap) wrap.innerHTML = state.done ? "" : moreButton();
}

/** Keep only items not already shown for this catalog. */
function dedupe(metas: MetaItem[], state: CatState): MetaItem[] {
  const fresh: MetaItem[] = [];
  for (const m of metas) {
    if (state.seen.has(m.id)) continue;
    state.seen.add(m.id);
    fresh.push(m);
  }
  return fresh;
}

function moreButton(): string {
  return `<button class="chip discover-more" data-action="discover-more">Load more</button>`;
}

function titleCase(value: string): string {
  return value.length ? value[0].toUpperCase() + value.slice(1) : value;
}

function gridSkeleton(): string {
  return Array.from({ length: 18 })
    .map(() => `<div class="poster poster-skeleton" aria-hidden="true"><div class="poster-art"></div></div>`)
    .join("");
}
