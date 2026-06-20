import type { Addon, MetaItem } from "../lib/types";
import { catalogRefs, fetchCatalog, type CatalogRef } from "../lib/addon";
import { escapeHtml } from "../lib/dom";
import { hashFor } from "../lib/router";
import { posterCard } from "./board";

// Discover: a single dense poster grid for one content type, merged across every catalog of that type.
// Where the Board is editorial (rails), Discover is a library-style grid for browsing one type deeply.

/** The distinct content types present across installed add-on catalogs, for the type switcher. */
export function discoverTypes(addons: Addon[]): string[] {
  const types = new Set<string>();
  for (const ref of catalogRefs(addons)) types.add(ref.def.type);
  // Stable, sensible order with the common types first.
  const order = ["movie", "series", "channel", "tv"];
  return Array.from(types).sort((a, b) => {
    const ia = order.indexOf(a);
    const ib = order.indexOf(b);
    if (ia !== -1 || ib !== -1) return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
    return a < b ? -1 : 1;
  });
}

/** Render the Discover shell (type switcher + an empty grid) for `type`; loadDiscover fills the grid. */
export function renderDiscoverShell(host: HTMLElement, addons: Addon[], type: string): void {
  const types = discoverTypes(addons);
  const tabs = types
    .map(
      (t) =>
        `<a class="chip${t === type ? " selected" : ""}" href="${escapeHtml(
          hashFor({ name: "discover", type: t }),
        )}">${escapeHtml(titleCase(t))}</a>`,
    )
    .join("");
  host.innerHTML = `
    <div class="discover">
      <div class="discover-head">
        <h1 class="page-title">Discover</h1>
        <div class="type-switch" role="tablist" aria-label="Content type">${tabs}</div>
      </div>
      <div class="grid" id="discover-grid" role="list">${gridSkeleton()}</div>
      <div class="discover-more-wrap" id="discover-more-wrap"></div>
    </div>`;
}

// Monotonic guard: switching Discover type fires a new loadDiscover while the previous one may still be
// in flight. Both write the fixed `#discover-grid`, so without this a slower earlier type's fetch could
// resolve last and paint the wrong type's posters. Latest request wins.
let discoverReqToken = 0;

// Pagination state for the active type. Each catalog of the type advances its OWN skip by the count it
// actually returned (so there are no gaps regardless of a catalog's page size); `done` is set when a
// catalog returns an empty page. `seen` de-dupes across pages and across catalogs. A type switch (or any
// new loadDiscover) replaces this object and bumps the token, so a stale in-flight page is discarded.
interface RefPage {
  ref: CatalogRef;
  skip: number;
  done: boolean;
}
interface DiscoverPaging {
  token: number;
  refs: RefPage[];
  seen: Set<string>;
  loading: boolean;
}
let paging: DiscoverPaging | null = null;

/** Fetch the next page from every not-yet-exhausted catalog, advance each ref's skip, de-dupe against
 *  what is already shown, and return only the fresh metas. Bails to [] if a newer load superseded `p`. */
async function fetchPage(p: DiscoverPaging): Promise<MetaItem[]> {
  const active = p.refs.filter((r) => !r.done);
  const results = await Promise.all(active.map(async (r) => ({ r, metas: await fetchCatalog(r.ref, r.skip) })));
  if (p !== paging || p.token !== discoverReqToken) return []; // superseded by a newer type load
  const fresh: MetaItem[] = [];
  for (const { r, metas } of results) {
    if (!metas.length) {
      r.done = true; // an empty page means this catalog is exhausted
      continue;
    }
    r.skip += metas.length;
    for (const m of metas) {
      if (p.seen.has(m.id)) continue;
      p.seen.add(m.id);
      fresh.push(m);
    }
  }
  return fresh;
}

/** A "Load more" button while any catalog still has pages; empty once every catalog is exhausted. */
function moreButton(p: DiscoverPaging): string {
  return p.refs.some((r) => !r.done)
    ? `<button class="chip discover-more" data-action="discover-more">Load more</button>`
    : "";
}

/** Merge the first page of every catalog of `type` into one de-duped grid, with a Load more control. */
export async function loadDiscover(addons: Addon[], type: string): Promise<void> {
  const token = ++discoverReqToken;
  const refs = catalogRefs(addons).filter((r) => r.def.type === type);
  const p: DiscoverPaging = {
    token,
    refs: refs.map((ref) => ({ ref, skip: 0, done: false })),
    seen: new Set<string>(),
    loading: false,
  };
  paging = p;
  const fresh = await fetchPage(p);
  if (p !== paging || token !== discoverReqToken) return; // a newer type switch superseded this load
  const grid = document.getElementById("discover-grid");
  const wrap = document.getElementById("discover-more-wrap");
  if (!grid) return;
  if (!fresh.length) {
    grid.innerHTML = `<p class="muted">No titles found for this type. Add a catalog add-on that serves ${escapeHtml(type)}.</p>`;
    if (wrap) wrap.innerHTML = "";
    return;
  }
  grid.innerHTML = fresh.map(posterCard).join("");
  if (wrap) wrap.innerHTML = moreButton(p);
}

/** Append the next page across the active type's catalogs (the Load more click handler). */
export async function loadMoreDiscover(): Promise<void> {
  const p = paging;
  if (!p || p.loading || p.token !== discoverReqToken) return;
  p.loading = true;
  const fresh = await fetchPage(p);
  p.loading = false;
  if (p !== paging || p.token !== discoverReqToken) return; // a type switch superseded this page
  const grid = document.getElementById("discover-grid");
  if (grid && fresh.length) grid.insertAdjacentHTML("beforeend", fresh.map(posterCard).join(""));
  const wrap = document.getElementById("discover-more-wrap");
  if (wrap) wrap.innerHTML = moreButton(p); // removes the button once every catalog is exhausted
}

function titleCase(value: string): string {
  return value.length ? value[0].toUpperCase() + value.slice(1) : value;
}

function gridSkeleton(): string {
  return Array.from({ length: 18 })
    .map(() => `<div class="poster poster-skeleton" aria-hidden="true"><div class="poster-art"></div></div>`)
    .join("");
}
