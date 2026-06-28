import type { Addon, MetaItem } from "../lib/types";
import { fetchSearchPage, searchableRefs, type CatalogRef } from "../lib/addon";
import { discoverTypes } from "./discover";
import { escapeHtml } from "../lib/dom";
import { posterCard } from "./board";
import { addRecentSearch, recentSearches } from "../lib/store";

// Search: query the searchable catalogs across installed add-ons and show a merged poster grid. The
// query lives in the URL (#/search/<q>) so a search is shareable and survives a refresh.

/** Render the search shell with the query reflected in the input; loadSearch fills the grid. */
export function renderSearchShell(host: HTMLElement, query: string): void {
  host.innerHTML = `
    <div class="discover">
      <div class="discover-head">
        <h1 class="page-title">Search</h1>
      </div>
      <div class="search-bar">
        <form class="search-form" id="search-form" role="search">
          <input class="search-input" id="search-input" type="search" name="q" autocomplete="off"
                 placeholder="Search movies and series" value="${escapeHtml(query)}" aria-label="Search"
                 role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="search-suggest" />
          <button class="chip" type="submit">Search</button>
        </form>
        <div class="search-suggest" id="search-suggest" role="listbox" aria-label="Suggestions" hidden></div>
      </div>
      <div class="grid" id="search-grid" role="list">${query ? "" : recentChips()}</div>
      <div class="search-more-wrap" id="search-more-wrap"></div>
    </div>`;
}

// Paging across the searchable catalogs for the active query, mirroring views/discover: each catalog
// advances its own skip (so there are no gaps regardless of page size), a catalog is exhausted on an
// empty page OR when it returns the same first item as its previous page (a search add-on that ignores
// `skip` would otherwise loop), `seen` de-dupes across pages + catalogs, and a new query (or any new
// loadSearch) bumps the token + replaces the object so a stale in-flight page is discarded.
let searchReqToken = 0;
interface SearchRefPage {
  ref: CatalogRef;
  skip: number;
  done: boolean;
  lastFirstId?: string;
}
interface SearchPaging {
  token: number;
  query: string;
  refs: SearchRefPage[];
  seen: Set<string>;
  loading: boolean;
}
let paging: SearchPaging | null = null;

/** Fetch the next page from every not-yet-exhausted searchable catalog; return only the fresh metas. */
async function fetchPage(p: SearchPaging): Promise<MetaItem[]> {
  const active = p.refs.filter((r) => !r.done);
  const results = await Promise.all(
    active.map(async (r) => ({ r, metas: await fetchSearchPage(r.ref, p.query, r.skip) })),
  );
  if (p !== paging || p.token !== searchReqToken) return []; // superseded by a newer query
  const fresh: MetaItem[] = [];
  for (const { r, metas } of results) {
    const firstId = metas[0]?.id;
    if (!metas.length || (firstId !== undefined && firstId === r.lastFirstId)) {
      r.done = true;
      continue;
    }
    r.lastFirstId = firstId;
    r.skip += metas.length;
    for (const m of metas) {
      if (p.seen.has(m.id)) continue;
      p.seen.add(m.id);
      fresh.push(m);
    }
  }
  return fresh;
}

/** A "Load more" button while any searchable catalog still has pages; empty once all are exhausted. */
function moreButton(p: SearchPaging): string {
  return p.refs.some((r) => !r.done)
    ? `<button class="chip search-more" data-action="search-more">Load more</button>`
    : "";
}

/** Run the search and STREAM merged results in as each catalog responds (fast add-ons like Cinemeta
 *  paint in well under a second instead of waiting on the slowest one), with Load more. `record` adds
 *  the query to recent searches; the debounced as-you-type path passes false so it doesn't spam them. */
export async function loadSearch(addons: Addon[], query: string, record = true): Promise<void> {
  const token = ++searchReqToken;
  const grid = document.getElementById("search-grid");
  const wrap = document.getElementById("search-more-wrap");
  if (!grid || !query) return;
  if (record) addRecentSearch(query);
  grid.innerHTML = `<p class="muted">Searching for “${escapeHtml(query)}”…</p>`;
  if (wrap) wrap.innerHTML = "";
  const types = discoverTypes(addons);
  const refs = searchableRefs(addons, types.length ? types : ["movie", "series"]);
  const p: SearchPaging = {
    token,
    query,
    refs: refs.map((ref) => ({ ref, skip: 0, done: false })),
    seen: new Set<string>(),
    loading: false,
  };
  paging = p;
  if (!refs.length) {
    grid.innerHTML = `<p class="muted">No search-capable add-on is installed yet. Add one on the Add-ons page.</p>`;
    return;
  }
  // Fire every searchable catalog at once and append each one's fresh results AS IT RESOLVES, so the page
  // is not held hostage by the slowest add-on (the old Promise.all-then-render could take ~30s).
  let painted = false;
  let settled = 0;
  await Promise.all(
    p.refs.map(async (r) => {
      let metas: MetaItem[] = [];
      try {
        metas = await fetchSearchPage(r.ref, p.query, 0);
      } catch {
        metas = [];
      }
      if (p !== paging || token !== searchReqToken) return; // a newer query superseded this one
      if (!metas.length) r.done = true;
      else {
        r.lastFirstId = metas[0]?.id;
        r.skip += metas.length;
      }
      const fresh = metas.filter((m) => !p.seen.has(m.id));
      fresh.forEach((m) => p.seen.add(m.id));
      if (fresh.length) {
        if (!painted) {
          painted = true;
          grid.innerHTML = "";
        }
        grid.insertAdjacentHTML("beforeend", fresh.map(posterCard).join(""));
      }
      settled++;
      if (settled === p.refs.length && !painted) {
        grid.innerHTML = `<p class="muted">No results for “${escapeHtml(query)}”.</p>`;
      }
      if (wrap) wrap.innerHTML = moreButton(p);
    }),
  );
}

/** Append the next page across the active query's catalogs (the Load more click handler). */
export async function loadMoreSearch(): Promise<void> {
  const p = paging;
  if (!p || p.loading || p.token !== searchReqToken) return;
  p.loading = true;
  const fresh = await fetchPage(p);
  p.loading = false;
  if (p !== paging || p.token !== searchReqToken) return; // a new query superseded this page
  const grid = document.getElementById("search-grid");
  if (grid && fresh.length) grid.insertAdjacentHTML("beforeend", fresh.map(posterCard).join(""));
  const wrap = document.getElementById("search-more-wrap");
  if (wrap) wrap.innerHTML = moreButton(p);
}

// --- As-you-type suggestions --------------------------------------------------------------------
// A lightweight typeahead under the search box: matching RECENT searches (instant, local) plus the top
// few TITLE matches from a quick single-catalog lookup. Distinct from the full streaming results in the
// grid below: this lets you jump straight to a title's Detail or repeat a recent query while typing.

let suggestToken = 0;

/** Top title suggestions for `query` from the first one or two searchable catalogs (fast; suggestions do
 *  not need every source). De-duped by id, capped at `limit`. [] on any failure. */
async function fetchSuggestions(addons: Addon[], query: string, limit = 6): Promise<MetaItem[]> {
  const types = discoverTypes(addons);
  const refs = searchableRefs(addons, types.length ? types : ["movie", "series"]);
  if (!refs.length) return [];
  const seen = new Set<string>();
  const out: MetaItem[] = [];
  for (const ref of refs.slice(0, 2)) {
    let metas: MetaItem[] = [];
    try {
      metas = await fetchSearchPage(ref, query, 0);
    } catch {
      metas = [];
    }
    for (const m of metas) {
      if (seen.has(m.id)) continue;
      seen.add(m.id);
      out.push(m);
      if (out.length >= limit) return out;
    }
  }
  return out;
}

function recentRow(q: string): string {
  return `<a class="suggest-row suggest-recent" role="option" href="#/search/${encodeURIComponent(q)}">
    <span class="suggest-ico" aria-hidden="true">↩</span><span class="suggest-name">${escapeHtml(q)}</span></a>`;
}
function titleRow(m: MetaItem): string {
  const thumb =
    typeof m.poster === "string" && /^https:\/\//i.test(m.poster)
      ? `<img class="suggest-thumb" src="${escapeHtml(m.poster)}" alt="" loading="lazy" />`
      : `<span class="suggest-thumb suggest-thumb-empty" aria-hidden="true"></span>`;
  const year = (m as { year?: string | number }).year;
  const meta = year ? `<span class="suggest-year">${escapeHtml(String(year))}</span>` : "";
  return `<a class="suggest-row" role="option" href="#/detail/${encodeURIComponent(m.type)}/${encodeURIComponent(m.id)}">
    ${thumb}<span class="suggest-name">${escapeHtml(m.name)}</span>${meta}</a>`;
}

function paintSuggest(html: string): void {
  const panel = document.getElementById("search-suggest");
  if (!panel) return;
  panel.innerHTML = html;
  const open = html.trim().length > 0;
  panel.hidden = !open;
  document.getElementById("search-input")?.setAttribute("aria-expanded", String(open));
}

/** Hide + clear the suggestions panel (on submit, escape, blur, or navigation). */
export function hideSuggestions(): void {
  paintSuggest("");
}

/** Update the typeahead for the current input value: matching recents paint immediately, title
 *  suggestions append once the quick lookup resolves (token-guarded against stale responses). Empty
 *  query shows recent searches only. The caller debounces calls so we do not fetch on every keystroke. */
export async function updateSearchSuggestions(addons: Addon[], query: string): Promise<void> {
  const q = query.trim();
  const token = ++suggestToken;
  const recents = recentSearches().filter(
    (r) => r.toLowerCase() !== q.toLowerCase() && (!q || r.toLowerCase().includes(q.toLowerCase())),
  );
  const recentHtml = recents.slice(0, 5).map(recentRow).join("");
  paintSuggest(recentHtml); // instant: recents first
  if (!q) return;
  const titles = await fetchSuggestions(addons, q);
  if (token !== suggestToken) return; // a newer keystroke superseded this lookup
  paintSuggest(recentHtml + titles.map(titleRow).join(""));
}

function prompt(): string {
  return `<p class="muted">Type a title to search across your installed catalog add-ons.</p>`;
}

/** Recent-search chips (one-tap repeat), or the prompt when there is no history. */
function recentChips(): string {
  const recents = recentSearches();
  if (!recents.length) return prompt();
  const chips = recents
    .map((q) => `<a class="chip recent-chip" href="#/search/${encodeURIComponent(q)}">${escapeHtml(q)}</a>`)
    .join("");
  return `<div class="recent-searches"><span class="muted">Recent</span>${chips}</div>`;
}
