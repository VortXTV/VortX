import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// The frontend drives the embedded stremio-core engine through the Tauri commands wired in lib.rs:
// dispatch actions, read model fields back as JSON, and re-render when the engine emits a NewState
// `core-event`. This renders the Home board (every catalog of every installed add-on) as poster
// rails from real add-on data (Cinemeta etc.), the same engine the iOS and Apple TV apps use.

interface MetaItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
}
interface Loadable {
  type: string; // "Ready" | "Loading" | "Err"
  content?: MetaItem[];
}
interface CatalogPage {
  request?: { path?: { id?: string; type?: string } };
  content?: Loadable;
}
interface Board {
  catalogs?: CatalogPage[][];
}

async function dispatch(field: string, action: unknown): Promise<void> {
  await invoke("engine_dispatch", { actionJson: JSON.stringify({ field, action }) });
}

async function getState<T>(field: string): Promise<T | null> {
  const json = await invoke<string>("engine_get_state", { fieldJson: JSON.stringify(field) });
  try {
    return JSON.parse(json) as T;
  } catch {
    return null;
  }
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string,
  );
}

function setStatus(text: string): void {
  const el = document.getElementById("status");
  if (el) el.textContent = text;
}

/// One rail per catalog group whose first page is loaded, titled by the catalog id + type.
function renderBoard(board: Board | null): void {
  const content = document.getElementById("content");
  if (!content || !board?.catalogs) return;

  const rails: string[] = [];
  for (const group of board.catalogs) {
    const page = group.find((p) => p.content?.type === "Ready" && (p.content.content?.length ?? 0) > 0);
    if (!page || !page.content?.content) continue;
    const id = page.request?.path?.id ?? "Catalog";
    const type = page.request?.path?.type ?? "";
    const title = escapeHtml(`${id} ${type}`.trim());
    const cards = page.content.content
      .slice(0, 30)
      .map((item) => {
        const name = escapeHtml(item.name ?? "");
        // Only trust http(s) image URLs (escaped), so no javascript:/data: scheme can sneak in.
        const posterUrl = item.poster && /^https?:\/\//i.test(item.poster) ? item.poster : "";
        const art = posterUrl
          ? `<img class="art" loading="lazy" src="${escapeHtml(posterUrl)}" alt="${name}" />`
          : `<div class="art"></div>`;
        return `<div class="poster" title="${name}">${art}<div class="name">${name}</div></div>`;
      })
      .join("");
    rails.push(`<section><h2 class="rail-title">${title}</h2><div class="rail">${cards}</div></section>`);
  }

  if (rails.length) {
    content.innerHTML = rails.join("");
    setStatus("");
  }
}

async function start(): Promise<void> {
  // Re-render whenever the engine reports new state (catalog fetches complete asynchronously).
  await listen("core-event", () => {
    void getState<Board>("board").then(renderBoard);
  });

  // Load every catalog of every installed add-on, then fetch the first rows (the Apple app's flow).
  await dispatch("board", { action: "Load", args: { model: "CatalogsWithExtra", args: { type: null, extra: [] } } });
  await dispatch("board", {
    action: "CatalogsWithExtra",
    args: { action: "LoadRange", args: { start: 0, end: 30 } },
  });

  // Initial paint + a few fallback polls in case some NewState events land before the listener.
  for (let i = 0; i < 8; i++) {
    setTimeout(() => void getState<Board>("board").then(renderBoard), i * 700);
  }
}

void start();
