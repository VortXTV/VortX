import type { Addon, MetaItem } from "../lib/types";
import { catalogRefs, fetchCatalog, type CatalogRef } from "../lib/addon";
import { escapeHtml, httpUrl } from "../lib/dom";
import { hashFor } from "../lib/router";
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
  host.innerHTML = `<div class="board">${continueWatchingRail()}${rails}</div>`;
}

/** A "Continue Watching" rail of in-progress titles, shown at the top of Home. Empty when nothing is
 *  in progress. Cards reuse posterCard and link to Detail (where re-playing resumes from the saved spot). */
function continueWatchingRail(): string {
  const cw = continueWatching();
  if (!cw.length) return "";
  return `
    <section class="rail-section" aria-labelledby="rail-cw">
      <h2 class="rail-title" id="rail-cw">Continue Watching</h2>
      <div class="rail" role="list">${cw.map((item) => removableCard(item, "cw", "Remove from Continue Watching")).join("")}</div>
    </section>`;
}

/** Fetch each catalog and paint its rail; bad add-ons leave an empty rail rather than failing Home. */
export async function loadBoard(addons: Addon[]): Promise<void> {
  const refs = catalogRefs(addons);
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
      body.innerHTML = metas.slice(0, 30).map(posterCard).join("");
    }),
  );
}

/** A single poster card linking to the detail route (an anchor, so it is keyboard-focusable). */
export function posterCard(item: MetaItem): string {
  const name = escapeHtml(item.name ?? "");
  const art = httpUrl(item.poster);
  const href = hashFor({ name: "detail", type: item.type, id: item.id });
  const inner = art
    ? `<img class="poster-art" loading="lazy" src="${escapeHtml(art)}" alt="${name}" />`
    : `<div class="poster-art poster-art-empty" aria-hidden="true">${name.slice(0, 1)}</div>`;
  return `
    <a class="poster" role="listitem" href="${escapeHtml(href)}" title="${name}">
      ${inner}
      <span class="poster-name">${name}</span>
    </a>`;
}

/** A poster card wrapped with a remove (×) control, for the Continue Watching + Library rails. The button
 *  is a SIBLING of the card anchor (not nested) so clicking it removes rather than navigating. */
export function removableCard(item: MetaItem, kind: "cw" | "lib", label: string): string {
  return `<div class="card-wrap">${posterCard(item)}<button class="card-remove" type="button" data-action="remove-saved" data-id="${escapeHtml(item.id)}" data-kind="${kind}" aria-label="${escapeHtml(label)}">×</button></div>`;
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
