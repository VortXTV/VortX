import { libraryItems } from "../lib/store";
import { removableCard } from "./board";

// The Library surface: titles the user saved from a Detail page, newest first. localStorage-backed and
// separate from the native apps' account library (the web client has no account sync). Reuses the Home
// poster card + rail markup so it looks identical to the catalog rails.

/** Render the Library grid (or an empty state) into the main host. */
export function renderLibrary(host: HTMLElement): void {
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
