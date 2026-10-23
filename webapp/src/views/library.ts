import { libraryItems, browserLibraryItems, nativeLibraryItems, nativeWatchlistItems, hasNativeAccountProjection } from "../lib/store";
import { removableCard, posterCard } from "./board";

// The Library surface: titles the user saved from a Detail page, newest first. localStorage-backed and
// separate from the native apps' account library (the web client has no account sync). Reuses the Home
// poster card + rail markup so it looks identical to the catalog rails.

/** Render the Library grid (or an empty state) into the main host. */
export function renderLibrary(host: HTMLElement): void {
  if (hasNativeAccountProjection()) {
    const watchlist = nativeWatchlistItems(), library = nativeLibraryItems(), saved = browserLibraryItems();
    const rail = (id: string, label: string, items: ReturnType<typeof libraryItems>, local = false): string =>
      `<section class="rail-section" aria-labelledby="${id}"><h2 class="rail-title" id="${id}">${label}</h2>` +
      (items.length ? `<div class="rail" role="list">${items.map((item) => local ? removableCard(item, "lib", "Remove browser save") : id === "rail-watchlist" ? removableCard(item, "watchlist", "Remove from Account Watchlist") : posterCard(item)).join("")}</div>` : `<p>No titles in this profile.</p>`) + `</section>`;
    host.innerHTML = `<div class="board">${rail("rail-watchlist", "Account Watchlist", watchlist)}${rail("rail-library", "Account Library", library)}${rail("rail-browser-saved", "Saved in this browser", saved, true)}<p>Account Watchlist changes sync automatically and stay queued offline. Save keeps a separate browser-local bookmark; native Account Library membership is managed in VortX.</p></div>`;
    return;
  }
  const items = libraryItems();
  if (!items.length) {
    host.innerHTML = `
      <div class="board">
        <div class="empty-state">
          <h2>Your Library is empty</h2>
          <p>Open any title and tap Save to keep it here. The web Library lives in this browser; your
            account library on the apps is separate.</p>
        </div>
      </div>`;
    return;
  }
  host.innerHTML = `
    <div class="board">
      <section class="rail-section" aria-labelledby="rail-library">
        <h2 class="rail-title" id="rail-library">Library</h2>
        <div class="rail" role="list">${items.map((item) => removableCard(item, "lib", "Remove from Library")).join("")}</div>
      </section>
    </div>`;
}
