import type { Addon, MetaItem, Stream, Video } from "../lib/types";
import { fetchMeta, fetchStreams, fetchSubtitles, type StreamGroup } from "../lib/addon";
import {
  best,
  hasOnlyUnplayable,
  isTorrent,
  rankedGroups,
  sourceTags,
  tiers,
  variantOptions,
  watchLabel,
  type RankedGroup,
} from "../lib/streamRanking";
import { defaultSeason, episodesForSeason, isSeries, seasonsOf } from "../lib/series";
import { actionOf, escapeHtml, httpUrl } from "../lib/dom";
import { play } from "../lib/player";
import { cwPosition, cwProgress, inLibrary, toggleLibrary } from "../lib/store";

// The Detail page: a full-bleed backdrop with a gradient scrim, a logo/title hero, a meta row
// (rating, year, runtime, genres), a primary Watch button that plays the best ranked source, a
// two-level quality picker and an "all sources" toggle revealing the per-add-on stream list, plus
// series season/episode handling and a YouTube trailer embed. A web port of desktop/src/detail.ts -
// the structure and ranking are the same; the transport is the add-on protocol (addon.ts) and the
// player is the HTML5 <video>/hls.js sink (player.ts), not the Tauri/mpv path.

const TRAILER_HOST = "https://www.youtube-nocookie.com";

interface DetailState {
  type: string;
  id: string;
  meta: MetaItem | null;
  groups: StreamGroup[]; // streams for the current movie / open episode
  streamsLoading: boolean;
  showAllSources: boolean;
  sourceFilter: string | null; // addon transport base, or null for "All"
  pickerOpen: boolean;
  pickerTier: string | null;
  selectedSeason: number | null;
  openEpisode: Video | null;
}

let state: DetailState | null = null;
let addons: Addon[] = [];
let hostEl: HTMLElement | null = null;
// Monotonic guard for in-flight stream fetches: only the latest request may apply its results. Without
// it, a slower earlier fetch (e.g. episode A) can resolve after a newer one (episode B) and clobber the
// open episode's streams - so "Watch" would play the wrong episode's source. Latest request wins.
let streamReqToken = 0;

/** Open the Detail surface for a title. Loads meta first (so the page paints), then streams. */
export async function openDetail(host: HTMLElement, installed: Addon[], type: string, id: string): Promise<void> {
  addons = installed;
  hostEl = host;
  streamReqToken++; // navigating to a new title invalidates any prior in-flight stream fetch
  state = {
    type,
    id,
    meta: null,
    groups: [],
    streamsLoading: false,
    showAllSources: false,
    sourceFilter: null,
    pickerOpen: false,
    pickerTier: null,
    selectedSeason: null,
    openEpisode: null,
  };
  host.innerHTML = `<div class="detail"><div class="detail-loading">Loading…</div></div>`;

  const meta = await fetchMeta(addons, type, id);
  if (!state) return; // navigated away while loading
  state.meta = meta;
  if (!meta) {
    host.innerHTML = `<div class="detail"><div class="detail-loading">Could not load this title.</div></div>`;
    return;
  }

  // A movie loads its streams immediately; a series waits until an episode is opened.
  if (!isSeries(type, meta)) {
    void loadStreams(type, id);
  }
  render();
}

/** Fetch streams for a movie or episode id, repainting when each add-on group resolves. */
async function loadStreams(type: string, id: string): Promise<void> {
  if (!state) return;
  const token = ++streamReqToken;
  state.streamsLoading = true;
  state.groups = [];
  render();
  const groups = await fetchStreams(addons, type, id);
  if (!state || token !== streamReqToken) return; // navigated away, or a newer fetch superseded this one
  state.groups = groups;
  state.streamsLoading = false;
  render();
}

/** Tear down the Detail surface (called by the router when leaving the route). */
export function closeDetail(): void {
  state = null;
  addons = [];
  hostEl = null;
}

/** Handle a click inside the Detail surface. Returns true if it consumed the event. */
export async function handleDetailClick(target: EventTarget | null): Promise<boolean> {
  if (!state) return false;
  const hit = actionOf(target);
  if (!hit) return false;

  switch (hit.action) {
    case "play-best":
      return playBest();
    case "play-variant":
      return playVariant(hit.node);
    case "play-stream":
      return playStreamRow(hit.node);
    case "play-trailer":
      return playTrailer();
    case "close-trailer":
      closeTrailer();
      return true;
    case "toggle-sources":
      state.showAllSources = !state.showAllSources;
      render();
      return true;
    case "toggle-picker":
      state.pickerOpen = !state.pickerOpen;
      state.pickerTier = null;
      render();
      return true;
    case "picker-tier":
      state.pickerTier = hit.node.dataset.tier ?? null;
      render();
      return true;
    case "picker-back":
      state.pickerTier = null;
      render();
      return true;
    case "filter":
      state.sourceFilter = hit.node.dataset.base || null;
      render();
      return true;
    case "select-season":
      return selectSeason(hit.node);
    case "open-episode":
      return openEpisode(hit.node);
    case "close-episode":
      return closeEpisode();
    case "toggle-library":
      if (state.meta) {
        toggleLibrary(state.meta);
        render();
      }
      return true;
    default:
      return false;
  }
}

// ---- Render ------------------------------------------------------------------------------------

function render(): void {
  if (!hostEl || !state?.meta) return;
  document.title = `${state.meta.name} · VortX`;
  if (isSeries(state.type, state.meta)) {
    renderSeries(hostEl, state.meta);
    return;
  }
  renderMovie(hostEl, state.meta);
}

function renderMovie(host: HTMLElement, meta: MetaItem): void {
  if (!state) return;
  const groups = rankedGroups(state.groups);
  const bg = httpUrl(meta.background) || httpUrl(meta.poster);
  const logo = httpUrl(meta.logo);
  const trailer = trailerYouTubeID(meta);
  host.innerHTML = `
    <div class="detail">
      <div class="detail-bg"${bg ? ` style="background-image:url('${escapeHtml(bg)}')"` : ""}></div>
      <div class="detail-scrim"></div>
      <a class="back" href="#/" data-action="nav-home">‹ Home</a>
      <div class="detail-body">
        ${heroHead(meta, logo)}
        ${metaRow(meta)}
        ${meta.description ? `<p class="desc">${escapeHtml(meta.description)}</p>` : ""}
        ${creditsRow(meta)}
        ${streamSection(groups)}
        ${libraryButton(meta)}${trailer ? trailerButton() : ""}
      </div>
    </div>`;
}

function renderSeries(host: HTMLElement, meta: MetaItem): void {
  if (!state) return;
  const videos = meta.videos ?? [];
  const seasons = seasonsOf(videos);
  if (state.selectedSeason === null || !seasons.includes(state.selectedSeason)) {
    state.selectedSeason = defaultSeason(seasons);
  }
  const open = state.openEpisode;
  const bg = (open ? httpUrl(open.thumbnail) : "") || httpUrl(meta.background) || httpUrl(meta.poster);
  const logo = httpUrl(meta.logo);
  const trailer = trailerYouTubeID(meta);

  const body = open
    ? episodeStreamView(open, meta)
    : `${heroHead(meta, logo)}${metaRow(meta)}${
        meta.description ? `<p class="desc">${escapeHtml(meta.description)}</p>` : ""
      }${creditsRow(meta)}${seasonSelector(seasons)}${episodeList(videos, state.selectedSeason)}${libraryButton(meta)}${trailer ? trailerButton() : ""}`;

  host.innerHTML = `
    <div class="detail">
      <div class="detail-bg"${bg ? ` style="background-image:url('${escapeHtml(bg)}')"` : ""}></div>
      <div class="detail-scrim"></div>
      <a class="back" href="#/" data-action="nav-home">‹ Home</a>
      <div class="detail-body">${body}</div>
    </div>`;
}

function heroHead(meta: MetaItem, logo: string): string {
  if (logo) return `<img class="detail-logo" src="${escapeHtml(logo)}" alt="${escapeHtml(meta.name)}" />`;
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

// ---- Stream section (movie + episode share this) -----------------------------------------------

function streamSection(groups: RankedGroup[]): string {
  if (!state) return "";
  const streamCount = groups.reduce((n, g) => n + g.streams.length, 0);
  const top = best(groups);

  // Done loading, nothing playable.
  if (!top && !state.streamsLoading) {
    const onlyTorrents = hasOnlyUnplayable(state.groups);
    const explain = onlyTorrents
      ? `The only sources found for this title are torrents, which the web app cannot play (it has no
         streaming server). Use a debrid service (RealDebrid, AllDebrid, Premiumize) with a stream
         add-on for direct links, or open this title in the VortX app.`
      : `None of your add-ons returned a playable source. Add a stream add-on that serves direct or
         debrid links - the web app plays HTTP(S) and HLS sources only.`;
    return `
      <div class="stream-section">
        <button class="watch disabled" disabled>
          <span class="play-icon" aria-hidden="true">▷</span> No playable sources
        </button>
        <p class="muted">${explain}</p>
        <a class="chip" href="#/addons" data-action="nav-addons">Manage add-ons</a>
      </div>`;
  }

  // Still loading, no source yet.
  if (!top) {
    return `
      <div class="stream-section">
        <button class="watch loading" disabled><span class="spinner" aria-hidden="true"></span>Finding sources…</button>
      </div>`;
  }

  // If this title/episode has a saved resume position, label the button "Resume … · 12:34" (playback
  // already seeks to it; this just makes the affordance visible). resumeId is the played id.
  const resumeId = state.openEpisode?.id ?? state.meta?.id;
  const resumePos = resumeId ? cwPosition(resumeId) : 0;
  const watchInner =
    resumePos > 0
      ? `<span class="play-icon" aria-hidden="true">▷</span> Resume ${escapeHtml(watchLabel(top))} · ${formatTime(resumePos)}`
      : `<span class="play-icon" aria-hidden="true">▷</span> Watch in ${escapeHtml(watchLabel(top))}`;
  const controls = `
    <div class="stream-controls">
      <button class="watch" data-action="play-best">
        ${watchInner}
      </button>
      <button class="chip" data-action="toggle-picker" aria-expanded="${state.pickerOpen}">Quality ⌄</button>
      <button class="chip${state.showAllSources ? " selected" : ""}" data-action="toggle-sources">
        ${state.showAllSources ? "Hide sources" : `All sources · ${streamCount}`}
      </button>
    </div>`;

  const stillLoading = state.streamsLoading
    ? `<p class="muted small">Still finding more sources…</p>`
    : "";

  return `<div class="stream-section">${controls}${stillLoading}${qualityPicker(groups)}${
    state.showAllSources ? sourceList(groups, streamCount) : ""
  }</div>`;
}

function qualityPicker(groups: RankedGroup[]): string {
  if (!state?.pickerOpen) return "";
  if (state.pickerTier) {
    const variants = variantOptions(groups, state.pickerTier);
    const back = `<button class="chip" data-action="picker-back">‹ ${escapeHtml(state.pickerTier)}</button>`;
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

function sourceList(groups: RankedGroup[], total: number): string {
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
  const rows = visible.map((group) => group.streams.map((s, i) => streamRow(group, s, i)).join("")).join("");
  return `${filterBar}<div class="streams">${rows}</div>`;
}

function streamRow(group: RankedGroup, stream: Stream, index: number): string {
  const badge = `<span class="badge">${escapeHtml(group.addon.toUpperCase())}</span>`;
  const torrentBadge = isTorrent(stream) ? `<span class="badge badge-torrent">TORRENT</span>` : "";
  const tags = `<span class="stream-tags">${escapeHtml(sourceTags(stream))}</span>`;
  const label = stream.name || stream.title;
  const name = label ? `<div class="stream-name">${escapeHtml(label)}</div>` : "";
  const desc = stream.description ? `<div class="stream-desc">${escapeHtml(stream.description)}</div>` : "";
  return `
    <button class="stream" data-action="play-stream" data-base="${escapeHtml(group.base)}" data-index="${index}">
      <span class="stream-icon" aria-hidden="true">▷</span>
      <span class="stream-text">
        <span class="stream-meta">${badge}${torrentBadge}${tags}</span>
        ${name}${desc}
      </span>
    </button>`;
}

// ---- Series: season selector + episode list ----------------------------------------------------

function seasonLabel(season: number): string {
  return season === 0 ? "Specials" : `Season ${season}`;
}

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

function episodeList(videos: Video[], season: number): string {
  const episodes = episodesForSeason(videos, season);
  const eyebrow = `${episodes.length} episode${episodes.length === 1 ? "" : "s"}`;
  if (!episodes.length) {
    return `<div class="episodes-section"><span class="episodes-eyebrow">${eyebrow}</span></div>`;
  }
  const rows = episodes.map(episodeRow).join("");
  return `<div class="episodes-section">
      <span class="episodes-eyebrow">${eyebrow}</span>
      <div class="episodes">${rows}</div>
    </div>`;
}

function episodeRow(v: Video): string {
  const epNum = v.episode ?? 0;
  const season = v.season ?? 0;
  const code = `S${season}E${epNum}`;
  const title = v.title || v.name || `Episode ${epNum}`;
  const thumb = httpUrl(v.thumbnail);
  const art = thumb
    ? `<img class="episode-thumb" loading="lazy" src="${escapeHtml(thumb)}" alt="${escapeHtml(title)}" />`
    : `<div class="episode-thumb episode-thumb-empty" aria-hidden="true">▷</div>`;
  const date = v.released && v.released.length >= 10 ? v.released.slice(0, 10) : "";
  const meta = [code, date].filter(Boolean).join(" · ");
  const overview = v.overview || v.description;
  const overviewHtml = overview ? `<div class="episode-overview">${escapeHtml(overview)}</div>` : "";
  // A watched-progress track for an episode that has been started (keyed by the episode video id).
  const prog = cwProgress(v.id);
  const bar =
    prog > 0
      ? `<span class="cw-progress" aria-hidden="true"><span style="width:${Math.min(100, Math.round(prog * 100))}%"></span></span>`
      : "";
  return `
    <button class="episode" data-action="open-episode" data-video-id="${escapeHtml(v.id)}">
      ${art}
      <span class="episode-text">
        <span class="episode-meta">${escapeHtml(meta)}</span>
        <span class="episode-title">${escapeHtml(title)}</span>
        ${overviewHtml}${bar}
      </span>
    </button>`;
}

function episodeStreamView(episode: Video, meta: MetaItem): string {
  if (!state) return "";
  const groups = rankedGroups(state.groups);
  const epNum = episode.episode ?? 0;
  const season = episode.season ?? 0;
  const title = episode.title || episode.name || `Episode ${epNum}`;
  const date = episode.released && episode.released.length >= 10 ? episode.released.slice(0, 10) : "";

  const metaParts: string[] = [`S${season} · E${epNum}`];
  if (date) metaParts.push(date);
  if (meta.runtime) metaParts.push(meta.runtime);
  const rating = imdbRating(meta);
  if (rating) metaParts.unshift(`★ ${rating}`);
  const overview = episode.overview || episode.description;

  return `
    <button class="chip episode-back" data-action="close-episode">‹ Episodes</button>
    <span class="episode-eyebrow">${escapeHtml(meta.name)}</span>
    <h1 class="episode-screen-title">${escapeHtml(title)}</h1>
    <div class="meta-row">${metaParts.map((p) => `<span>${escapeHtml(p)}</span>`).join("")}</div>
    ${overview ? `<p class="desc">${escapeHtml(overview)}</p>` : ""}
    ${streamSection(groups)}`;
}

// ---- Links / rating / trailer helpers ----------------------------------------------------------

/** Seconds to a compact timecode: "M:SS" under an hour, "H:MM:SS" past it. */
function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

function genres(meta: MetaItem): string[] {
  if (meta.genres?.length) return meta.genres;
  return (meta.links ?? []).filter((l) => l.category.toLowerCase() === "genre").map((l) => l.name);
}

/** People from the meta's typed links by category, e.g. cast or directors. Category strings mirror the
 *  Apple app's CoreModels.credits(), which is proven against real Cinemeta data. */
function credits(meta: MetaItem, categories: string[]): string[] {
  const set = new Set(categories);
  return (meta.links ?? []).filter((l) => set.has(l.category.toLowerCase())).map((l) => l.name);
}

/** Cast / Director / Writer lines under the synopsis, each shown only when present and name-capped so a
 *  long IMDb cast list doesn't push the action row away (mirrors iOSDetailView's credit lines). */
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

function imdbRating(meta: MetaItem): string | undefined {
  if (meta.imdbRating) return meta.imdbRating;
  return (meta.links ?? []).find((l) => l.category.toLowerCase() === "imdb")?.name;
}

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
      return url.pathname.split("/").filter(Boolean).pop() || undefined;
    }
  } catch {
    // not a URL - fall through to the bare-id check
  }
  return /^[A-Za-z0-9_-]{11}$/.test(trimmed) ? trimmed : undefined;
}

function trailerButton(): string {
  return `<button class="chip trailer-chip" data-action="play-trailer">▶ Trailer</button>`;
}

/** Save/Saved toggle that adds the current title to the local Library (see store.ts). */
function libraryButton(meta: MetaItem): string {
  const saved = inLibrary(meta.id);
  return `<button class="chip lib-chip${saved ? " saved" : ""}" data-action="toggle-library" aria-pressed="${saved}">${saved ? "✓ Saved" : "+ Save"}</button>`;
}

function openTrailer(youtubeId: string): void {
  if (!hostEl) return;
  const overlay = hostEl.querySelector<HTMLElement>(".detail");
  if (!overlay) return;
  let frame = overlay.querySelector<HTMLDivElement>(".trailer-overlay");
  if (!frame) {
    frame = document.createElement("div");
    frame.className = "trailer-overlay";
    overlay.appendChild(frame);
  }
  const src = `${TRAILER_HOST}/embed/${encodeURIComponent(youtubeId)}?autoplay=1&rel=0`;
  frame.innerHTML = `
    <button class="back trailer-close" data-action="close-trailer">‹ Close</button>
    <iframe class="trailer-frame" src="${escapeHtml(src)}" allow="autoplay; encrypted-media; fullscreen"
            allowfullscreen referrerpolicy="strict-origin"></iframe>`;
}

function closeTrailer(): void {
  hostEl?.querySelector(".trailer-overlay")?.remove();
}

// ---- Playback wiring ---------------------------------------------------------------------------

/** Play a stream: direct/debrid urls go straight to the player. Torrents are not playable on web. */
async function playStream(stream: Stream): Promise<void> {
  if (!stream.url || !/^https?:\/\//i.test(stream.url)) return;
  const title = state?.openEpisode
    ? `${state.meta?.name ?? ""} · S${state.openEpisode.season ?? 0}E${state.openEpisode.episode ?? 0}`
    : state?.meta?.name ?? "VortX";
  await play(
    stream.url,
    title,
    state?.meta
      ? {
          id: state.meta.id,
          type: state.meta.type,
          name: state.meta.name,
          poster: state.meta.poster,
          resumeId: state.openEpisode?.id ?? state.meta.id,
        }
      : undefined,
    state?.meta
      ? fetchSubtitles(addons, state.meta.type, state.openEpisode?.id ?? state.meta.id)
      : undefined,
  );
}

async function playBest(): Promise<boolean> {
  if (!state) return true;
  const top = best(rankedGroups(state.groups));
  if (top) await playStream(top);
  return true;
}

async function playVariant(node: HTMLElement): Promise<boolean> {
  if (!state) return true;
  const tier = node.dataset.tier;
  const index = Number(node.dataset.index);
  if (!tier || Number.isNaN(index)) return true;
  const variants = variantOptions(rankedGroups(state.groups), tier);
  const stream = variants[index]?.stream;
  if (stream) await playStream(stream);
  return true;
}

async function playStreamRow(node: HTMLElement): Promise<boolean> {
  if (!state) return true;
  const base = node.dataset.base;
  const index = Number(node.dataset.index);
  if (Number.isNaN(index)) return true;
  const groups = rankedGroups(state.groups);
  const group = groups.find((g) => g.base === base);
  const stream = group?.streams[index];
  if (stream) await playStream(stream);
  return true;
}

async function playTrailer(): Promise<boolean> {
  if (!state?.meta) return true;
  const id = trailerYouTubeID(state.meta);
  if (id) openTrailer(id);
  return true;
}

function selectSeason(node: HTMLElement): boolean {
  if (!state) return true;
  const raw = node.dataset.season;
  if (raw === undefined) return true;
  state.selectedSeason = Number(raw);
  render();
  return true;
}

async function openEpisode(node: HTMLElement): Promise<boolean> {
  if (!state?.meta) return true;
  const videoId = node.dataset.videoId;
  if (!videoId) return true;
  const episode = state.meta.videos?.find((v) => v.id === videoId);
  if (!episode) return true;
  state.openEpisode = episode;
  state.showAllSources = false;
  state.sourceFilter = null;
  state.pickerOpen = false;
  state.pickerTier = null;
  render();
  await loadStreams(state.type, episode.id);
  return true;
}

async function closeEpisode(): Promise<boolean> {
  if (!state) return true;
  state.openEpisode = null;
  state.groups = [];
  state.showAllSources = false;
  state.sourceFilter = null;
  state.pickerOpen = false;
  state.pickerTier = null;
  render();
  return true;
}
