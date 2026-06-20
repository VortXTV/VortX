import type { Addon } from "../lib/types";
import { search } from "../lib/addon";
import { discoverTypes } from "./discover";
import { escapeHtml } from "../lib/dom";
import { posterCard } from "./board";

// Search: query the searchable catalogs across installed add-ons and show a merged poster grid. The
// query lives in the URL (#/search/<q>) so a search is shareable and survives a refresh.

/** Render the search shell with the query reflected in the input; loadSearch fills the grid. */
export function renderSearchShell(host: HTMLElement, query: string): void {
  host.innerHTML = `
    <div class="discover">
      <div class="discover-head">
        <h1 class="page-title">Search</h1>
      </div>
      <form class="search-form" id="search-form" role="search">
        <input class="search-input" id="search-input" type="search" name="q" autocomplete="off"
               placeholder="Search movies and series" value="${escapeHtml(query)}" aria-label="Search" />
        <button class="chip" type="submit">Search</button>
      </form>
      <div class="grid" id="search-grid" role="list">${query ? "" : prompt()}</div>
    </div>`;
}

/** Run the search and paint results (or an empty message). */
export async function loadSearch(addons: Addon[], query: string): Promise<void> {
  const grid = document.getElementById("search-grid");
  if (!grid || !query) return;
  grid.innerHTML = `<p class="muted">Searching for “${escapeHtml(query)}”…</p>`;
  const types = discoverTypes(addons);
  const results = await search(addons, query, types.length ? types : ["movie", "series"]);
  grid.innerHTML = results.length
    ? results.map(posterCard).join("")
    : `<p class="muted">No results for “${escapeHtml(query)}”.</p>`;
}

function prompt(): string {
  return `<p class="muted">Type a title to search across your installed catalog add-ons.</p>`;
}
