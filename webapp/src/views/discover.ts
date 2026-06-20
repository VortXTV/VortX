import type { Addon, MetaItem } from "../lib/types";
import { catalogRefs, fetchCatalog } from "../lib/addon";
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
    </div>`;
}

// Monotonic guard: switching Discover type fires a new loadDiscover while the previous one may still be
// in flight. Both write the fixed `#discover-grid`, so without this a slower earlier type's fetch could
// resolve last and paint the wrong type's posters. Latest request wins.
let discoverReqToken = 0;

/** Merge every catalog of `type` into one de-duped grid. */
export async function loadDiscover(addons: Addon[], type: string): Promise<void> {
  const token = ++discoverReqToken;
  const refs = catalogRefs(addons).filter((r) => r.def.type === type);
  const pages = await Promise.all(refs.map((ref) => fetchCatalog(ref)));
  if (token !== discoverReqToken) return; // a newer type switch superseded this load
  const seen = new Set<string>();
  const metas: MetaItem[] = [];
  for (const meta of pages.flat()) {
    if (seen.has(meta.id)) continue;
    seen.add(meta.id);
    metas.push(meta);
  }
  const grid = document.getElementById("discover-grid");
  if (!grid) return;
  grid.innerHTML = metas.length
    ? metas.map(posterCard).join("")
    : `<p class="muted">No titles found for this type. Add a catalog add-on that serves ${escapeHtml(type)}.</p>`;
}

function titleCase(value: string): string {
  return value.length ? value[0].toUpperCase() + value.slice(1) : value;
}

function gridSkeleton(): string {
  return Array.from({ length: 18 })
    .map(() => `<div class="poster poster-skeleton" aria-hidden="true"><div class="poster-art"></div></div>`)
    .join("");
}
