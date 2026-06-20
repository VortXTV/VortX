import type { Addon, MetaItem } from "../lib/types";
import { catalogRefs, fetchCatalog } from "../lib/addon";
import { posterCard } from "./board";

// Live TV: catalogs whose type is tv / channel. Most installs have none (Cinemeta serves movie + series
// only), so this is usually a clean empty state pointing at Add-ons; when a live/channels add-on is
// installed, its channels show as a grid. (Previously the Live tab wrongly rendered the Discover view
// forced to "tv", which showed a "Discover" heading + Movie/Series chips + "No catalogs for this type".)

const LIVE_TYPES = new Set(["tv", "channel"]);

function liveRefs(addons: Addon[]) {
  return catalogRefs(addons).filter((r) => LIVE_TYPES.has(r.def.type));
}

/** Render the Live shell: a "Live" heading + either a channels grid (filled by loadLive) or, when no
 *  live add-on is installed, a clean empty state. */
export function renderLive(host: HTMLElement, addons: Addon[]): void {
  if (!liveRefs(addons).length) {
    host.innerHTML = `
      <div class="discover">
        <div class="discover-head"><h1 class="page-title">Live</h1></div>
        <div class="empty-state">
          <h2>No live channels yet</h2>
          <p>Live TV needs a channels add-on. Install one from Add-ons (any catalog that serves tv or
             channel content) and your channels will appear here.</p>
          <a class="chip" href="#/addons">Manage add-ons</a>
        </div>
      </div>`;
    return;
  }
  host.innerHTML = `
    <div class="discover">
      <div class="discover-head"><h1 class="page-title">Live</h1></div>
      <div class="grid" id="live-grid" role="list">${skeleton()}</div>
    </div>`;
}

/** Fetch the live catalogs and paint the channels grid (de-duped across catalogs). */
export async function loadLive(addons: Addon[]): Promise<void> {
  const refs = liveRefs(addons);
  const grid = document.getElementById("live-grid");
  if (!refs.length || !grid) return;
  const pages = await Promise.all(refs.map((r) => fetchCatalog(r, 0)));
  const seen = new Set<string>();
  const items: MetaItem[] = [];
  for (const page of pages) {
    for (const m of page) {
      if (seen.has(m.id)) continue;
      seen.add(m.id);
      items.push(m);
    }
  }
  grid.innerHTML = items.length
    ? items.map((m) => posterCard(m)).join("")
    : `<p class="muted">No live channels available right now.</p>`;
}

function skeleton(): string {
  return Array.from({ length: 12 })
    .map(() => `<div class="poster poster-skeleton" aria-hidden="true"><div class="poster-art"></div></div>`)
    .join("");
}
