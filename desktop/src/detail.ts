import type { Ctx, MetaDetails, MetaItem, Stream, Video } from "./engine";
import {
  defaultSeason,
  dispatch,
  episodesForSeason,
  getState,
  isSeries,
  readyMeta,
  seasonsOf,
  streamLoadProgress,
} from "./engine";
import {
  best,
  rankedGroups,
  sourceTagList,
  streamGroups,
  tiers,
  variantOptions,
  watchLabel,
  type StreamSourceGroup,
} from "./streamRanking";
import { isTorrent, prepareTorrent, resolveUrl, status as serverStatus, torrentsAvailable } from "./server";
import { icon } from "./icons";

// The detail overlay: a full-bleed backdrop with a gradient scrim, a logo/title hero, a meta row
// (rating · year · runtime · genres), a primary Watch button that plays the best ranked source, a
// quality selector and an "all sources" toggle revealing the per-add-on stream list, and trailer
// support (a YouTube embed) when the meta carries one. Mirrors the tvOS DetailView + CoreStreamList.

const TRAILER_HOST = "https://www.youtube-nocookie.com";

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string,
  );
}
function httpUrl(value: string | undefined): string {
  return value && /^https?:\/\//i.test(value) ? value : "";
}
function el(id: string): HTMLElement | null {
  return document.getElementById(id);
}

// ---- Open / close state --------------------------------------------------------------------

interface DetailState {
  type: string;
  id: string;
  showAllSources: boolean;
  sourceFilter: string | null; // addon transport base, or null for "All"
  pickerOpen: boolean; // quality picker revealed
  pickerTier: string | null; // selected tier (level 2 = its flavor variants), or null for level 1
  // Series-only: which season's episodes are listed, and which episode (if any) is open with its
  // own streams. selectedSeason === null until the meta resolves and we pick the default season.
  selectedSeason: number | null;
  openEpisode: Video | null; // the episode whose streams are loaded + shown, or null = episode list
}

let state: DetailState | null = null;
let onPlay: ((url: string) => void) | null = null;

// The backend's last-known reason the embedded server isn't usable (failed/disabled), so the
// empty-state can say WHY torrents aren't available. null once the server is up. Refreshed on each
// repaint so a server that finishes booting clears the message.
let serverDownReason: string | null = null;

export function isDetailOpen(): boolean {
  return state !== null;
}

export function setPlayHandler(handler: (url: string) => void): void {
  onPlay = handler;
}

export async function openDetail(type: string, id: string): Promise<void> {
  state = {
    type,
    id,
    showAllSources: false,
    sourceFilter: null,
    pickerOpen: false,
    pickerTier: null,
    selectedSeason: null,
    openEpisode: null,
  };
  const overlay = el("detail");
  if (overlay) {
    overlay.classList.remove("hidden");
    overlay.innerHTML = `<div class="detail-loading">Loading…</div>`;
  }
  // For a movie this loads the title + its own streams (streamPath null = guess from the meta). For
  // a series we still load the meta here (no stream path yet) so we get the episode list; an
  // episode's streams are loaded later via loadEpisodeStreams() when one is opened.
  await loadMeta(type, id, null);
  await refresh();
}

/**
 * Dispatch the engine's MetaDetails Load, the one transport the movie page already uses. `streamPath`
 * scopes which streams the engine fetches: null guesses from the meta (movie / the show's own id),
 * an episode's `{ resource:"stream", type, id }` fetches THAT episode's sources (same as tvOS
 * CoreBridge.loadMeta with streamType/streamId).
 */
async function loadMeta(
  type: string,
  id: string,
  streamPath: { resource: string; type: string; id: string; extra: [] } | null,
): Promise<void> {
  await dispatch("meta_details", {
    action: "Load",
    args: {
      model: "MetaDetails",
      args: { metaPath: { resource: "meta", type, id, extra: [] }, guessStream: true, streamPath },
    },
  });
}

/** Open one episode and load its streams (re-uses the show's meta, scopes streams to the episode id). */
async function loadEpisodeStreams(episode: Video): Promise<void> {
  if (!state) return;
  // A new episode resets the stream-list UI (picker / filter / all-sources) so it doesn't carry the
  // previous episode's selections.
  state.openEpisode = episode;
  state.showAllSources = false;
  state.sourceFilter = null;
  state.pickerOpen = false;
  state.pickerTier = null;
  await loadMeta(state.type, state.id, {
    resource: "stream",
    type: state.type,
    id: episode.id,
    extra: [],
  });
  await refresh();
}

/** Close the open episode and return to the season's episode list (re-loads the show's own meta). */
async function closeEpisode(): Promise<void> {
  if (!state) return;
  state.openEpisode = null;
  state.showAllSources = false;
  state.sourceFilter = null;
  state.pickerOpen = false;
  state.pickerTier = null;
  await loadMeta(state.type, state.id, null);
  await refresh();
}

export function closeDetail(): void {
  closeTrailer();
  state = null;
  el("detail")?.classList.add("hidden");
  void dispatch("meta_details", { action: "Unload" });
}

/** Re-read meta_details + ctx from the engine and repaint the overlay. Called on every core-event. */
export async function refresh(): Promise<void> {
  if (!state) return;
  // Resolve why the server is down (for the empty state) only when torrents aren't yet available, so
  // a booted server clears the message without an extra round-trip on the hot path.
  if (torrentsAvailable()) {
    serverDownReason = null;
  } else {
    try {
      const s = await serverStatus();
      serverDownReason = s.state === "running" ? null : s.reason ?? "the streaming server is not running";
    } catch {
      serverDownReason = "the streaming server is not running";
    }
  }
  const [md, ctx] = await Promise.all([getState<MetaDetails>("meta_details"), getState<Ctx>("ctx")]);
  render(md, ctx);
}

// ---- Genres / rating from links ----------------------------------------------------------------

function genres(meta: MetaItem): string[] {
  return (meta.links ?? [])
    .filter((l) => l.category.toLowerCase() === "genre")
    .map((l) => l.name);
}
function imdbRating(meta: MetaItem): string | undefined {
  return (meta.links ?? []).find((l) => l.category.toLowerCase() === "imdb")?.name;
}

/** People from the meta's typed links by category (cast/directors/writers). Category strings mirror the
 *  Apple app's CoreModels.credits(), proven against real Cinemeta data. */
function credits(meta: MetaItem, categories: string[]): string[] {
  const set = new Set(categories);
  return (meta.links ?? []).filter((l) => set.has(l.category.toLowerCase())).map((l) => l.name);
}
/** Cast / Director / Writer lines under the synopsis, capped, each shown only when present. */
function creditsRow(meta: MetaItem): string {
  const line = (role: string, names: string[]): string =>
    names.length
      ? `<div class="credit"><span class="credit-role">${role}</span><span class="credit-names">${escapeHtml(names.join(", "))}</span></div>`
      : "";
  const html =
    line("Cast", credits(meta, ["cast", "actors", "actor"]).slice(0, 5)) +
    line("Director", credits(meta, ["director", "directors"]).slice(0, 3)) +
    line("Writer", credits(meta, ["writer", "writers"]).slice(0, 3));
  return html ? `<div class="credits">${html}</div>` : "";
}

/** The first trailer's YouTube id, from trailerStreams (ytId) or a "Trailer" link, if present. */
function trailerYouTubeID(meta: MetaItem): string | undefined {
  const fromStreams = (meta.trailerStreams ?? []).map((s) => s.ytId).find((id) => id && id.length);
  if (fromStreams) return fromStreams;
  const link = (meta.links ?? []).find((l) => l.category.toLowerCase() === "trailer");
  return link ? youTubeID(link.name) : undefined;
}

function youTubeID(value: string): string | undefined {
  const trimmed = value.trim();
  try {
    const url = new URL(trimmed);
    const host = url.host.toLowerCase();
    if (host.includes("youtu.be")) return url.pathname.slice(1) || undefined;
    if (host.includes("youtube.com")) {
      const v = url.searchParams.get("v");
      if (v) return v;
      const last = url.pathname.split("/").filter(Boolean).pop();
      return last || undefined;
    }
  } catch {
    // not a URL, fall through to the bare-id check
  }
  return /^[A-Za-z0-9_-]{11}$/.test(trimmed) ? trimmed : undefined;
}

// ---- Render ------------------------------------------------------------------------------------

function render(md: MetaDetails | null, ctx: Ctx | null): void {
  const overlay = el("detail");
  if (!overlay || !state) return;
  const meta = readyMeta(md);
  if (!meta) return;

  if (isSeries(state.type, meta)) {
    renderSeries(overlay, meta, md, ctx);
    return;
  }
  renderMovie(overlay, meta, md, ctx);
}

/** Movie page (unchanged): hero + meta + description + the ranked source list + trailer. */
function renderMovie(overlay: HTMLElement, meta: MetaItem, md: MetaDetails | null, ctx: Ctx | null): void {
  const groups = rankedGroups(streamGroups(md, ctx));
  const progress = streamLoadProgress(md);
  const bg = httpUrl(meta.background) || httpUrl(meta.poster);
  const logo = httpUrl(meta.logo);
  const trailer = trailerYouTubeID(meta);

  overlay.innerHTML = `
    <div class="detail-bg"${bg ? ` style="background-image:url('${escapeHtml(bg)}')"` : ""}></div>
    <div class="detail-scrim"></div>
    <button class="back" data-action="close-detail">${icon("back")}<span>Back</span></button>
    <div class="detail-body">
      ${heroHead(meta, logo)}
      ${metaRow(meta)}
      ${streamSection(groups, progress)}
      ${trailer ? trailerButton() : ""}
      ${meta.description ? `<p class="desc">${escapeHtml(meta.description)}</p>` : ""}
      ${creditsRow(meta)}
    </div>`;
}

/**
 * Series page: hero + meta, then either the season selector + episode list, or, once an episode is
 * opened, that episode's own ranked source list (the same UI the movie page shows). Mirrors
 * DetailView.swift's seriesPage / CoreSeasonedEpisodes / CoreEpisodeStreams.
 */
function renderSeries(overlay: HTMLElement, meta: MetaItem, md: MetaDetails | null, ctx: Ctx | null): void {
  if (!state) return;
  const videos = meta.videos ?? [];
  const seasons = seasonsOf(videos);
  if (state.selectedSeason === null || !seasons.includes(state.selectedSeason)) {
    state.selectedSeason = defaultSeason(seasons);
  }

  const open = state.openEpisode;
  // When an episode is open, the backdrop prefers the episode thumbnail (matches CoreEpisodeStreams).
  const bg =
    (open ? httpUrl(open.thumbnail) : "") || httpUrl(meta.background) || httpUrl(meta.poster);
  const logo = httpUrl(meta.logo);
  const trailer = trailerYouTubeID(meta);

  const body = open
    ? episodeStreamView(open, meta, md, ctx)
    : `${heroHead(meta, logo)}${metaRow(meta)}${
        meta.description ? `<p class="desc">${escapeHtml(meta.description)}</p>` : ""
      }${creditsRow(meta)}${seasonSelector(seasons)}${episodeList(videos, state.selectedSeason)}${
        trailer ? trailerButton() : ""
      }`;

  overlay.innerHTML = `
    <div class="detail-bg"${bg ? ` style="background-image:url('${escapeHtml(bg)}')"` : ""}></div>
    <div class="detail-scrim"></div>
    <button class="back" data-action="close-detail">${icon("back")}<span>Back</span></button>
    <div class="detail-body">${body}</div>`;
}

// ---- Series: season selector + episode list ----------------------------------------------------

function seasonLabel(season: number): string {
  return season === 0 ? "Specials" : `Season ${season}`;
}

/** Ember chip row of the seasons present, the selected one highlighted (mirrors the tvOS chips). */
function seasonSelector(seasons: number[]): string {
  if (!state || seasons.length === 0) return "";
  const chips = seasons
    .map(
      (s) =>
        `<button class="chip${state!.selectedSeason === s ? " selected" : ""}" data-action="select-season" data-season="${s}">${escapeHtml(
          seasonLabel(s),
        )}</button>`,
    )
    .join("");
  return `<div class="season-selector">${chips}</div>`;
}

/** The selected season's episodes: thumbnail + S#E# + title + overview + air date, in tvOS order. */
function episodeList(videos: Video[], season: number): string {
  const episodes = episodesForSeason(videos, season);
  const eyebrow = `${episodes.length} episode${episodes.length === 1 ? "" : "s"}`;
  if (!episodes.length) {
    return `<div class="episodes-section"><span class="episodes-eyebrow">${eyebrow}</span></div>`;
  }
  const rows = episodes.map((v) => episodeRow(v)).join("");
  return `<div class="episodes-section">
      <span class="episodes-eyebrow">${eyebrow}</span>
      <div class="episodes">${rows}</div>
    </div>`;
}

function episodeRow(v: Video): string {
  const epNum = v.episode ?? 0;
  const season = v.season ?? 0;
  const code = `S${season}E${epNum}`;
  const title = v.title && v.title.length ? v.title : `Episode ${epNum}`;
  const thumb = httpUrl(v.thumbnail);
  const art = thumb
    ? `<img class="episode-thumb" loading="lazy" src="${escapeHtml(thumb)}" alt="${escapeHtml(title)}" />`
    : `<div class="episode-thumb episode-thumb-empty">${icon("play")}</div>`;
  const date = v.released && v.released.length >= 10 ? v.released.slice(0, 10) : "";
  const meta = [code, date].filter(Boolean).join(" · ");
  const overview = v.overview ? `<div class="episode-overview">${escapeHtml(v.overview)}</div>` : "";
  return `
    <button class="episode" data-action="open-episode" data-video-id="${escapeHtml(v.id)}">
      ${art}
      <span class="episode-text">
        <span class="episode-meta">${escapeHtml(meta)}</span>
        <span class="episode-title">${escapeHtml(title)}</span>
        ${overview}
      </span>
    </button>`;
}

/**
 * The open episode's page: an eyebrow (show name) + episode title + episode meta row, then the SAME
 * grouped/ranked source list, two-level quality picker and all-sources toggle the movie page uses.
 */
function episodeStreamView(
  episode: Video,
  meta: MetaItem,
  md: MetaDetails | null,
  ctx: Ctx | null,
): string {
  const groups = rankedGroups(streamGroups(md, ctx));
  const progress = streamLoadProgress(md);
  const epNum = episode.episode ?? 0;
  const season = episode.season ?? 0;
  const title = episode.title && episode.title.length ? episode.title : `Episode ${epNum}`;
  const date = episode.released && episode.released.length >= 10 ? episode.released.slice(0, 10) : "";

  const metaParts: string[] = [`S${season} · E${epNum}`];
  if (date) metaParts.push(date);
  if (meta.runtime) metaParts.push(meta.runtime);
  const rating = imdbRating(meta);
  if (rating) metaParts.unshift(`★ ${rating}`);

  return `
    <button class="chip episode-back" data-action="close-episode">${icon("back")}<span>Episodes</span></button>
    <span class="episode-eyebrow">${escapeHtml(meta.name)}</span>
    <h1 class="episode-screen-title">${escapeHtml(title)}</h1>
    <div class="meta-row">${metaParts.map((p) => `<span>${escapeHtml(p)}</span>`).join("")}</div>
    ${streamSection(groups, progress)}
    ${episode.overview ? `<p class="desc">${escapeHtml(episode.overview)}</p>` : ""}`;
}

function heroHead(meta: MetaItem, logo: string): string {
  if (logo) {
    return `<img class="detail-logo" src="${escapeHtml(logo)}" alt="${escapeHtml(meta.name)}" />`;
  }
  return `<h1 class="detail-title">${escapeHtml(meta.name)}</h1>`;
}

function metaRow(meta: MetaItem): string {
  const parts: string[] = [];
  const imdb = imdbRating(meta);
  if (imdb) parts.push(`<span class="rating">★ ${escapeHtml(imdb)}</span>`);
  if (meta.releaseInfo) parts.push(`<span>${escapeHtml(meta.releaseInfo)}</span>`);
  if (meta.runtime) parts.push(`<span>${escapeHtml(meta.runtime)}</span>`);
  const g = genres(meta).slice(0, 3);
  if (g.length) parts.push(`<span>${escapeHtml(g.join(" · "))}</span>`);
  if (!parts.length) return "";
  return `<div class="meta-row">${parts.join("")}</div>`;
}

function streamSection(
  groups: StreamSourceGroup[],
  progress: { loaded: number; total: number },
): string {
  if (!state) return "";
  const streamCount = groups.reduce((n, g) => n + g.streams.length, 0);
  const loading = progress.total === 0 || progress.loaded < progress.total;
  const top = best(groups);

  // Done, nothing playable: a greyed button + an explanation. The wording depends on WHY, if the
  // embedded streaming server failed to start, torrents were filtered out and that's the likely
  // cause; otherwise the add-ons simply returned nothing usable.
  if (!top && !loading) {
    const explain = serverDownReason
      ? `The embedded streaming server isn't available (${escapeHtml(serverDownReason)}), so torrent
         sources are hidden. Restart the app, or install a stream add-on (e.g. Torrentio) with a
         debrid service for direct links.`
      : `None of your ${progress.total} add-on${progress.total === 1 ? "" : "s"} returned a playable
         source for this title. Install a stream add-on like Torrentio (optionally with a debrid
         service) and try again.`;
    return `
      <div class="stream-section">
        <button class="watch disabled" disabled>${icon("play")}<span>No playable sources</span></button>
        <p class="muted">${explain}</p>
      </div>`;
  }

  // Still searching, no source yet: a loading primary button.
  if (!top) {
    const label = progress.total > 0 ? `Finding sources…  ${progress.loaded}/${progress.total}` : "Finding sources…";
    return `
      <div class="stream-section">
        <button class="watch loading" disabled><span class="spinner"></span>${escapeHtml(label)}</button>
      </div>`;
  }

  // Watch-Now first: one press plays the best source; the quality picker + all-sources reveal sit
  // beside it. The full ranked list stays tucked behind "All sources".
  const controls = `
    <div class="stream-controls">
      <button class="watch" data-action="play-best">${icon("play")}<span>Watch in ${escapeHtml(watchLabel(top))}</span></button>
      <button class="chip" data-action="toggle-picker">${icon("quality")}<span>Quality</span></button>
      <button class="chip${state.showAllSources ? " selected" : ""}" data-action="toggle-sources">${icon("sources")}<span>${
        state.showAllSources ? "Hide sources" : `All sources · ${streamCount}`
      }</span></button>
    </div>`;

  const stillLoading =
    loading && progress.total > 0
      ? `<p class="muted small">Still finding more · ${progress.loaded}/${progress.total} add-ons</p>`
      : "";

  const picker = qualityPicker(groups);
  const list = state.showAllSources ? sourceList(groups, streamCount) : "";

  return `<div class="stream-section">${controls}${stillLoading}${picker}${list}</div>`;
}

// Two-level picker rendered inline, shown only while open. Level 1: resolution tiers. Level 2:
// flavor variants inside the selected tier.
function qualityPicker(groups: StreamSourceGroup[]): string {
  if (!state?.pickerOpen) return "";
  if (state.pickerTier) {
    const variants = variantOptions(groups, state.pickerTier);
    const back = `<button class="chip" data-action="picker-back">${icon("back")}<span>${escapeHtml(state.pickerTier)}</span></button>`;
    const opts = variants
      .map(
        (v, i) =>
          `<button class="quality-variant" data-action="play-variant" data-tier="${escapeHtml(
            state!.pickerTier as string,
          )}" data-index="${i}">${escapeHtml(v.label)}</button>`,
      )
      .join("");
    return `<div class="quality-panel">${back}<div class="quality-variants">${opts}</div></div>`;
  }
  const chips = tiers(groups)
    .map((t) => `<button class="chip" data-action="picker-tier" data-tier="${escapeHtml(t)}">${escapeHtml(t)}</button>`)
    .join("");
  return `<div class="quality-panel"><span class="quality-eyebrow">Pick a quality</span><div class="quality-tiers">${chips}</div></div>`;
}

function sourceList(groups: StreamSourceGroup[], total: number): string {
  if (!state) return "";
  const filterBar =
    groups.length > 1
      ? `<div class="source-filter">
          <button class="chip${state.sourceFilter === null ? " selected" : ""}" data-action="filter" data-base="">All (${total})</button>
          ${groups
            .map(
              (g) =>
                `<button class="chip${state!.sourceFilter === g.base ? " selected" : ""}" data-action="filter" data-base="${escapeHtml(
                  g.base,
                )}">${escapeHtml(g.addon)} (${g.streams.length})</button>`,
            )
            .join("")}
        </div>`
      : "";

  const visible = groups.filter((g) => state!.sourceFilter === null || g.base === state!.sourceFilter);
  // Each row carries its add-on base + the stream's index within that group, so the click handler
  // can look the exact Stream back up (it may be a torrent with no url, resolved on click). This is
  // the same "re-read state, find by key" pattern the quality-variant rows use.
  const rows = visible
    .map((group) => group.streams.map((s, i) => streamRow(group, s, i)).join(""))
    .join("");
  return `${filterBar}<div class="streams">${rows}</div>`;
}

/** Classify a quality tag for chip coloring (resolution / source / HDR / audio / cached). */
function qtagKind(tag: string): string {
  if (tag === "Cached") return "cached";
  if (tag === "DV" || tag === "HDR") return "hdr";
  if (tag === "Remux" || tag === "BluRay" || tag === "WEB") return "src";
  if (tag === "Atmos" || tag === "DTS-HD" || tag === "DTS") return "audio";
  return "res";
}

function streamRow(group: StreamSourceGroup, stream: Stream, index: number): string {
  const badges = `<span class="badge">${escapeHtml(group.addon.toUpperCase())}</span>`;
  const torrentBadge = isTorrent(stream) ? `<span class="badge badge-torrent">TORRENT</span>` : "";
  const tags = sourceTagList(stream)
    .map((tag) => `<span class="qtag qtag-${qtagKind(tag)}">${escapeHtml(tag)}</span>`)
    .join("");
  const name = stream.name ? `<div class="stream-name">${escapeHtml(stream.name)}</div>` : "";
  const desc = stream.description ? `<div class="stream-desc">${escapeHtml(stream.description)}</div>` : "";
  return `
    <button class="stream" data-action="play-stream" data-base="${escapeHtml(group.base)}" data-index="${index}">
      <span class="stream-icon">${icon("play")}</span>
      <span class="stream-text">
        <span class="stream-meta">${badges}${torrentBadge}${tags}</span>
        ${name}${desc}
      </span>
    </button>`;
}

function trailerButton(): string {
  return `<button class="chip trailer-chip" data-action="play-trailer">${icon("trailer")}<span>Trailer</span></button>`;
}

// ---- Trailer (YouTube embed in the webview) ----------------------------------------------------

function openTrailer(youtubeId: string): void {
  const overlay = el("detail");
  if (!overlay) return;
  let frame = overlay.querySelector<HTMLDivElement>(".trailer-overlay");
  if (!frame) {
    frame = document.createElement("div");
    frame.className = "trailer-overlay";
    overlay.appendChild(frame);
  }
  const src = `${TRAILER_HOST}/embed/${encodeURIComponent(youtubeId)}?autoplay=1&rel=0`;
  frame.innerHTML = `
    <button class="back trailer-close" data-action="close-trailer">${icon("back")}<span>Close</span></button>
    <iframe class="trailer-frame" src="${src}" allow="autoplay; encrypted-media; fullscreen"
            allowfullscreen referrerpolicy="strict-origin"></iframe>`;
}

function closeTrailer(): void {
  el("detail")?.querySelector(".trailer-overlay")?.remove();
}

// ---- Click wiring --------------------------------------------------------------------------

/** Handle a click inside the detail overlay. Returns true if it consumed the event. */
export async function handleDetailClick(target: HTMLElement): Promise<boolean> {
  if (!state) return false;
  const action = target.closest<HTMLElement>("[data-action]")?.dataset.action;

  switch (action) {
    case "play-stream":
      return await playStreamRow(target);
    case "close-detail":
      closeDetail();
      return true;
    case "close-trailer":
      closeTrailer();
      return true;
    case "select-season":
      return await selectSeason(target);
    case "open-episode":
      return await openEpisode(target);
    case "close-episode":
      await closeEpisode();
      return true;
    case "toggle-sources":
      state.showAllSources = !state.showAllSources;
      await refresh();
      return true;
    case "toggle-picker":
      state.pickerOpen = !state.pickerOpen;
      state.pickerTier = null;
      await refresh();
      return true;
    case "picker-tier":
      state.pickerTier = target.closest<HTMLElement>("[data-tier]")?.dataset.tier ?? null;
      await refresh();
      return true;
    case "picker-back":
      state.pickerTier = null;
      await refresh();
      return true;
    case "filter":
      state.sourceFilter = target.closest<HTMLElement>("[data-base]")?.dataset.base || null;
      await refresh();
      return true;
    case "play-best":
      return await playBest();
    case "play-variant":
      return await playVariant(target);
    case "play-trailer":
      return await playTrailer();
    default:
      return false;
  }
}

/**
 * Prime (if a torrent) and play one stream. Direct/debrid URLs play immediately; torrents first POST
 * `<base>/<infohash>/create` so the server starts fetching peers (with the TCP/TLS trackers injected),
 * then play the `<base>/<infohash>/<fileIdx>` file endpoint, which blocks until the first pieces land.
 * Mirrors the Apple prepareTorrent-then-play flow (iOSDetailView / StremioServer).
 */
async function playStream(stream: Stream): Promise<void> {
  if (isTorrent(stream)) await prepareTorrent(stream);
  const url = await resolveUrl(stream);
  if (url) onPlay?.(url);
}

async function playBest(): Promise<boolean> {
  const [md, ctx] = await Promise.all([getState<MetaDetails>("meta_details"), getState<Ctx>("ctx")]);
  const top = best(rankedGroups(streamGroups(md, ctx)));
  if (top) await playStream(top);
  return true;
}

async function playVariant(target: HTMLElement): Promise<boolean> {
  const node = target.closest<HTMLElement>("[data-tier][data-index]");
  if (!node) return true;
  const [md, ctx] = await Promise.all([getState<MetaDetails>("meta_details"), getState<Ctx>("ctx")]);
  const groups = rankedGroups(streamGroups(md, ctx));
  const variants = variantOptions(groups, node.dataset.tier as string);
  const stream = variants[Number(node.dataset.index)]?.stream;
  if (stream) await playStream(stream);
  return true;
}

/** A clicked source row: look the exact Stream back up by add-on base + index, then prime + play it. */
async function playStreamRow(target: HTMLElement): Promise<boolean> {
  const node = target.closest<HTMLElement>("[data-base][data-index]");
  if (!node) return true;
  const base = node.dataset.base;
  const index = Number(node.dataset.index);
  const [md, ctx] = await Promise.all([getState<MetaDetails>("meta_details"), getState<Ctx>("ctx")]);
  const groups = rankedGroups(streamGroups(md, ctx));
  const group = groups.find((g) => g.base === base);
  const stream = group?.streams[index];
  if (stream) await playStream(stream);
  return true;
}

async function playTrailer(): Promise<boolean> {
  const md = await getState<MetaDetails>("meta_details");
  const meta = readyMeta(md);
  const id = meta ? trailerYouTubeID(meta) : undefined;
  if (id) openTrailer(id);
  return true;
}

async function selectSeason(target: HTMLElement): Promise<boolean> {
  if (!state) return true;
  const raw = target.closest<HTMLElement>("[data-season]")?.dataset.season;
  if (raw === undefined) return true;
  state.selectedSeason = Number(raw);
  await refresh();
  return true;
}

/** Open the clicked episode and load its streams. Looks the video up in the (already loaded) meta. */
async function openEpisode(target: HTMLElement): Promise<boolean> {
  if (!state) return true;
  const videoId = target.closest<HTMLElement>("[data-video-id]")?.dataset.videoId;
  if (!videoId) return true;
  const md = await getState<MetaDetails>("meta_details");
  const meta = readyMeta(md);
  const episode = meta?.videos?.find((v) => v.id === videoId);
  if (episode) await loadEpisodeStreams(episode);
  return true;
}
