import type { Addon, MetaItem, Stream, Video } from "../lib/types";
import { fetchMeta, fetchSimilar, fetchStreams, fetchSubtitles, type StreamGroup } from "../lib/addon";
import { posterCard } from "./board";
import {
  applyStreamFilters,
  best,
  hasOnlyUnplayable,
  isTorrent,
  pickPreferred,
  playbackFallbacks,
  rankedGroups,
  sourceTagList,
  tiers,
  variantOptions,
  watchLabel,
  type RankedGroup,
} from "../lib/streamRanking";
import { fetchSkipSegments } from "../lib/skip";
import { defaultSeason, episodesForSeason, isSeries, seasonsOf, sortedVideos } from "../lib/series";
import { actionOf, escapeHtml, httpUrl } from "../lib/dom";
import { icon } from "../lib/icons";
import { play } from "../lib/player";
import { cwPosition, cwProgress, cwResumeId, inLibrary, toggleLibrary } from "../lib/store";
import { getSettings } from "../lib/settings";
import { fetchRatings, ratingsText, type Ratings } from "../lib/mdblist";
import { resolveBackendTrailer, userTrailerLang } from "../lib/trailer";

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
  ratings: Ratings | null; // MDBList IMDb/RT/TMDB, fetched async when an MDBList key is set
  similar: MetaItem[]; // "More Like This" - keyless Cinemeta genre catalog, fetched async
  trailerUrl: string | null; // resolved backend full-trailer mp4 url (trailer.vortx.tv), null until/if resolved
}

// Aborts the in-flight backend-trailer probe when the user navigates to another title.
let trailerAbort: AbortController | null = null;

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
    ratings: null,
    similar: [],
    trailerUrl: null,
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
  void loadRatings(meta); // IMDb/RT/TMDB, only when an MDBList key is set; repaints when it lands
  void loadSimilar(meta); // "More Like This" rail; keyless, repaints when it lands
  void loadTrailer(meta); // full trailer via trailer.vortx.tv; repaints when it resolves (fail-soft)
  render();
}

/** Resolve the FULL trailer for this title from the VortX trailer backend (the same /yt resolver the native
 *  apps use). On success the Trailer button plays the progressive mp4 in the web player; on 404/error the
 *  backend url stays null and the button falls back to the YouTube iframe embed (or hides if neither works).
 *  Fail-soft, aborted on navigation, repaints on arrival. */
async function loadTrailer(meta: MetaItem): Promise<void> {
  trailerAbort?.abort();
  trailerAbort = new AbortController();
  const lang = userTrailerLang(getSettings().audioLang);
  const url = await resolveBackendTrailer(meta.id, meta.type, lang, trailerAbort.signal);
  // Staleness is title identity only: the trailer is tied to the title, not to a stream fetch, so it must
  // NOT be gated on streamReqToken (a same-title stream refetch - e.g. opening an episode - bumps that and
  // would wrongly drop a valid trailer). Navigating away is covered by the meta.id check plus trailerAbort.
  if (!state || state.meta?.id !== meta.id) return; // navigated away
  if (!url) return; // no backend trailer - keep whatever the iframe fallback offers
  state.trailerUrl = url;
  render();
}

/** Fetch keyless "More Like This" titles (Cinemeta genre catalog). Fail-soft; repaints on arrival. */
async function loadSimilar(meta: MetaItem): Promise<void> {
  const token = streamReqToken; // tie to the current title; a new openDetail bumps this
  const similar = await fetchSimilar(meta);
  if (!state || state.meta?.id !== meta.id || token !== streamReqToken) return; // navigated away
  if (!similar.length) return;
  state.similar = similar;
  render();
}

/** Fetch MDBList ratings for this title (no-op without a key / imdb id). Fail-soft; repaints on arrival. */
async function loadRatings(meta: MetaItem): Promise<void> {
  const key = getSettings().mdblistKey;
  const imdb = imdbId(meta);
  if (!key || !imdb) return;
  const token = streamReqToken; // tie to the current title; a new openDetail bumps this
  const r = await fetchRatings(imdb, meta.type, key);
  if (!state || state.meta?.id !== meta.id || token !== streamReqToken) return; // navigated away
  state.ratings = r;
  render();
}

/** The IMDb id for a title (Cinemeta ids are already tt...; otherwise none). */
function imdbId(meta: MetaItem): string | undefined {
  return meta.id.startsWith("tt") ? meta.id : undefined;
}

/** state.groups after the user's Streams filters (Hide/Require/Safety/HDR-only/Max-quality/size/...). */
function filteredGroups(): StreamGroup[] {
  return state ? applyStreamFilters(state.groups, getSettings()) : [];
}

/** The filtered groups, ranked - honoring the "Use add-on ranking order" setting. Every stream list,
 *  the auto-pick, and the quality picker route through this so settings apply everywhere consistently. */
function rankedFiltered(): RankedGroup[] {
  return rankedGroups(filteredGroups(), getSettings().useAddonOrder);
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
  trailerAbort?.abort();
  trailerAbort = null;
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
    case "share":
      return shareTitle();
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
  const groups = rankedFiltered();
  const bg = httpUrl(meta.background) || httpUrl(meta.poster);
  const logo = httpUrl(meta.logo);
  const extra = `${hasTrailer(meta) ? trailerButton() : ""}${libraryButton(meta)}${shareButton()}`;
  host.innerHTML = detailShell(
    bg,
    "",
    `${titleBlock(meta, logo)}
     ${heroActions(groups, extra)}
     ${streamStatusNote(groups)}
     ${meta.description ? `<p class="desc t-body">${escapeHtml(meta.description)}</p>` : ""}
     ${streamPanel(groups)}
     ${creditsRow(meta)}
     ${moreLikeThis()}`,
  );
}

function renderSeries(host: HTMLElement, meta: MetaItem): void {
  if (!state) return;
  const videos = meta.videos ?? [];
  const seasons = seasonsOf(videos);
  if (state.selectedSeason === null || !seasons.includes(state.selectedSeason)) {
    state.selectedSeason = defaultSeason(seasons);
  }
  const open = state.openEpisode;
  const logo = httpUrl(meta.logo);

  if (open) {
    const bg = httpUrl(open.thumbnail) || httpUrl(meta.background) || httpUrl(meta.poster);
    const groups = rankedFiltered();
    const overview = open.overview || open.description;
    host.innerHTML = detailShell(
      bg,
      `<button class="back" data-action="close-episode">${icon("back")}<span>Episodes</span></button>`,
      `${titleBlock(meta, logo, open)}
       ${heroActions(groups, "")}
       ${streamStatusNote(groups)}
       ${overview ? `<p class="desc t-body">${escapeHtml(overview)}</p>` : ""}
       ${streamPanel(groups)}`,
    );
    return;
  }
  const bg = httpUrl(meta.background) || httpUrl(meta.poster);
  const extra = `${hasTrailer(meta) ? trailerButton() : ""}${libraryButton(meta)}${shareButton()}`;
  host.innerHTML = detailShell(
    bg,
    "",
    `${titleBlock(meta, logo)}
     <div class="hero-actions">${seriesPrimaryButton(videos)}${extra}</div>
     ${meta.description ? `<p class="desc t-body">${escapeHtml(meta.description)}</p>` : ""}
     ${creditsRow(meta)}
     ${seasonSelector(seasons)}
     ${episodeList(videos, state.selectedSeason)}
     ${moreLikeThis()}`,
  );
}

/** The "More Like This" rail: keyless genre-similar posters, reusing the board's poster card + rail. */
function moreLikeThis(): string {
  if (!state || !state.similar.length) return "";
  const cards = state.similar.map((m) => posterCard(m)).join("");
  return `
    <section class="rail-section detail-rail" aria-labelledby="rail-more">
      <div class="rail-head"><h2 class="rail-title" id="rail-more">More Like This</h2></div>
      <div class="rail" role="list">${cards}</div>
    </section>`;
}

/** The immersive detail shell: a tall full-bleed backdrop + dual scrim filling the first screen, with
 *  the content block (`body`) overlaid bottom-left over the backdrop and flowing onto the canvas below
 *  (the scrim fades the backdrop into the canvas so the seam is invisible). Mirrors the Mac app, where
 *  the title / meta / actions / synopsis all sit over one immersive backdrop, not a short banner. */
function detailShell(bg: string, back: string, body: string): string {
  return `
    <div class="detail detail-immersive">
      <div class="detail-bg"${bg ? ` style="background-image:url('${escapeHtml(bg)}')"` : ""}></div>
      <div class="detail-scrim"></div>
      ${back}
      <div class="detail-body">${body}</div>
    </div>`;
}

/** The title block: logo-or-serif-title (with a series eyebrow for an open episode) + the meta row. */
function titleBlock(meta: MetaItem, logo: string, episode?: Video): string {
  const epTitle = episode ? episode.title || episode.name || `Episode ${episode.episode ?? 0}` : "";
  const titleHtml = episode
    ? `<span class="detail-eyebrow t-eyebrow">${escapeHtml(meta.name)}</span><h1 class="detail-title t-hero">${escapeHtml(epTitle)}</h1>`
    : logo
      ? `<img class="detail-logo" src="${escapeHtml(logo)}" alt="${escapeHtml(meta.name)}" />`
      : `<h1 class="detail-title t-hero">${escapeHtml(meta.name)}</h1>`;
  return `<div class="detail-titleblock">${titleHtml}${episode ? episodeMetaRow(episode, meta) : metaRow(meta)}${ratingsRow()}</div>`;
}

/** Cross-provider ratings line (IMDb / RT / TMDB), shown only once MDBList ratings have loaded. */
function ratingsRow(): string {
  if (!state?.ratings) return "";
  const text = ratingsText(state.ratings);
  return text ? `<div class="ratings-row t-label">${escapeHtml(text)}</div>` : "";
}

/** Single-line meta row (rating star + year/runtime/genres joined), so it never forces the hero wider. */
function metaRow(meta: MetaItem): string {
  const facts: string[] = [];
  if (meta.releaseInfo) facts.push(meta.releaseInfo);
  if (meta.runtime) facts.push(formatRuntime(meta.runtime));
  const g = genres(meta).slice(0, 3);
  if (g.length) facts.push(g.join(" · "));
  const imdb = imdbRating(meta);
  const star = imdb ? `<span class="rating">★ ${escapeHtml(imdb)}</span>` : "";
  const line = facts.length ? `<span class="meta-facts">${escapeHtml(facts.join("  ·  "))}</span>` : "";
  if (!star && !line) return "";
  return `<div class="meta-row t-label">${star}${line}</div>`;
}

function episodeMetaRow(episode: Video, meta: MetaItem): string {
  const facts: string[] = [`S${episode.season ?? 0} · E${episode.episode ?? 0}`];
  const date = episode.released && episode.released.length >= 10 ? episode.released.slice(0, 10) : "";
  if (date) facts.push(date);
  if (meta.runtime) facts.push(formatRuntime(meta.runtime));
  const imdb = imdbRating(meta);
  const star = imdb ? `<span class="rating">★ ${escapeHtml(imdb)}</span>` : "";
  return `<div class="meta-row t-label">${star}<span class="meta-facts">${escapeHtml(facts.join("  ·  "))}</span></div>`;
}

// ---- Stream section (movie + episode share this) -----------------------------------------------
// The action cluster, the status note, and the sources panel are rendered separately so they slot into
// the immersive hero body in the app's order: title -> actions -> note -> synopsis -> panel.

/** The action cluster: the one primary CTA (Watch / Resume / loading / no-source) + Quality + Sources +
 *  the extra chips (Save / Share / Trailer), all one wrapping, equal-height row. */
function heroActions(groups: RankedGroup[], extraActions: string): string {
  if (!state) return "";
  const streamCount = groups.reduce((n, g) => n + g.streams.length, 0);
  const top = best(groups);

  if (!top && !state.streamsLoading) {
    return `<div class="hero-actions">
      <button class="btn-primary is-disabled" disabled>${icon("play")}<span>No playable sources</span></button>
      ${extraActions}</div>`;
  }
  if (!top) {
    return `<div class="hero-actions">
      <button class="btn-primary is-disabled" disabled><span class="spinner" aria-hidden="true"></span><span>Finding the best source…</span></button>
      ${extraActions}</div>`;
  }

  // Saved resume position -> the primary reads "Resume · 12:34" (playback already seeks to it).
  const resumeId = state.openEpisode?.id ?? state.meta?.id;
  const resumePos = resumeId ? cwPosition(resumeId) : 0;
  const watchText =
    resumePos > 0 ? `Resume · ${formatTime(resumePos)}` : `Watch · ${escapeHtml(watchLabel(top))}`;
  return `<div class="hero-actions">
    <button class="btn-primary" data-action="play-best">${icon("play")}<span>${watchText}</span></button>
    <button class="chip" data-action="toggle-picker" aria-expanded="${state.pickerOpen}">${icon("quality")}<span>Quality</span></button>
    <button class="chip${state.showAllSources ? " selected" : ""}" data-action="toggle-sources">${icon("sources")}<span>${
      state.showAllSources ? "Hide sources" : `Sources · ${streamCount}`
    }</span></button>
    ${extraActions}</div>`;
}

/** A slim status line under the actions: the "no playable web source" explainer, or "still finding more". */
function streamStatusNote(groups: RankedGroup[]): string {
  if (!state) return "";
  const top = best(groups);
  if (!top && !state.streamsLoading) {
    const onlyTorrents = hasOnlyUnplayable(filteredGroups());
    const explain = onlyTorrents
      ? `The only sources found are torrents, which the web app can't play on its own (no streaming
         server). Use a debrid service (RealDebrid, AllDebrid, Premiumize, TorBox) with a stream add-on
         for instant direct links, or open this title in the VortX app.`
      : `None of your add-ons returned a playable source. Add a stream add-on that serves direct or
         debrid links. The web app plays HTTP(S) and HLS sources.`;
    return `<p class="stream-note">${explain} <a class="inline-link" href="#/addons" data-action="nav-addons">Manage add-ons</a></p>`;
  }
  if (top && state.streamsLoading) return `<p class="muted small">Still finding more sources…</p>`;
  return "";
}

/** The elevated panel holding the quality picker + the all-sources list, shown only when toggled open. */
function streamPanel(groups: RankedGroup[]): string {
  if (!state || !(state.pickerOpen || state.showAllSources)) return "";
  const streamCount = groups.reduce((n, g) => n + g.streams.length, 0);
  return `<div class="surface-card stream-panel">${qualityPicker(groups)}${
    state.showAllSources ? sourceList(groups, streamCount) : ""
  }</div>`;
}

function qualityPicker(groups: RankedGroup[]): string {
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

/** Classify a quality tag for chip coloring (resolution / source / HDR / audio / cached). */
function qtagKind(tag: string): string {
  if (tag === "Cached") return "cached";
  if (tag === "DV" || tag === "HDR") return "hdr";
  if (tag === "Remux" || tag === "BluRay" || tag === "WEB") return "src";
  if (tag === "Atmos" || tag === "DTS-HD" || tag === "DTS") return "audio";
  return "res";
}

function streamRow(group: RankedGroup, stream: Stream, index: number): string {
  const badge = `<span class="badge">${escapeHtml(group.addon.toUpperCase())}</span>`;
  const torrentBadge = isTorrent(stream) ? `<span class="badge badge-torrent">TORRENT</span>` : "";
  const tags = sourceTagList(stream)
    .map((tag) => `<span class="qtag qtag-${qtagKind(tag)}">${escapeHtml(tag)}</span>`)
    .join("");
  const label = stream.name || stream.title;
  const name = label ? `<div class="stream-name">${escapeHtml(label)}</div>` : "";
  const desc = stream.description ? `<div class="stream-desc">${escapeHtml(stream.description)}</div>` : "";
  return `
    <button class="stream" data-action="play-stream" data-base="${escapeHtml(group.base)}" data-index="${index}">
      <span class="stream-icon">${icon("play")}</span>
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

/** The series hero primary action: Resume the last-watched episode, else Play the first. Reuses the
 *  open-episode handler (the episode view then plays). Empty when the title has no episodes. */
function seriesPrimaryButton(videos: Video[]): string {
  const pick = seriesPrimaryEpisode(videos);
  if (!pick) return "";
  return `<button class="btn-primary" data-action="open-episode" data-video-id="${escapeHtml(pick.video.id)}">${icon("play")}<span>${escapeHtml(pick.label)}</span></button>`;
}

/** Pick the episode the hero action should target: the series' in-progress episode (Resume), else the
 *  first episode (Play). */
function seriesPrimaryEpisode(videos: Video[]): { video: Video; label: string } | null {
  const eps = videos.filter((v) => v.episode !== undefined || v.season !== undefined);
  if (!eps.length) return null;
  const rid = state?.meta ? cwResumeId(state.meta.id) : null;
  if (rid) {
    const v = eps.find((e) => e.id === rid);
    if (v) return { video: v, label: `Resume S${v.season ?? 0}E${v.episode ?? 0}` };
  }
  // First episode of the DEFAULT season (skips season-0 specials, matching the episode list), not the
  // globally-first video - otherwise a Special would be labelled S0E1.
  const first = episodesForSeason(eps, defaultSeason(seasonsOf(eps)))[0];
  if (!first) return null;
  return { video: first, label: `Play S${first.season ?? 0}E${first.episode ?? 0}` };
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
    : `<div class="episode-thumb episode-thumb-empty" aria-hidden="true">${icon("play")}</div>`;
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

/** Runtime to the app's "2h 28min" form. Cinemeta gives "148 min"; we keep an already-formatted value
 *  (e.g. "2h 28min") or a non-numeric string as-is. */
function formatRuntime(runtime: string): string {
  const m = /^(\d+)\s*min/i.exec(runtime.trim());
  if (!m) return runtime;
  const mins = parseInt(m[1], 10);
  if (mins < 60) return `${mins}min`;
  const h = Math.floor(mins / 60);
  const rem = mins % 60;
  return rem ? `${h}h ${rem}min` : `${h}h`;
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
  // Validate against the exact 11-char YouTube id format so an add-on-supplied trailerStreams.ytId can't
  // smuggle anything into the iframe src (defense-in-depth on top of encodeURIComponent).
  const YT_ID = /^[A-Za-z0-9_-]{11}$/;
  const candidate =
    (meta.trailerStreams ?? []).map((s) => s.ytId).find((id) => id && YT_ID.test(id)) ??
    youTubeID((meta.links ?? []).find((l) => l.category.toLowerCase() === "trailer")?.name ?? "");
  return candidate && YT_ID.test(candidate) ? candidate : undefined;
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

/** Whether a Trailer affordance should show at all: a resolved backend full trailer, or a YouTube id we can
 *  embed as the fallback. When neither exists the button is hidden (fail-soft - never a broken player). */
function hasTrailer(meta: MetaItem): boolean {
  return !!state?.trailerUrl || !!trailerYouTubeID(meta);
}

function trailerButton(): string {
  return `<button class="chip trailer-chip" data-action="play-trailer">${icon("trailer")}<span>Trailer</span></button>`;
}

/** Add to Library / In Library toggle (the app's wording), adding the title to the local Library. */
function libraryButton(meta: MetaItem): string {
  const saved = inLibrary(meta.id);
  return `<button class="chip lib-chip${saved ? " selected" : ""}" data-action="toggle-library" aria-pressed="${saved}">${
    saved ? `${icon("bookmarkFill")}<span>In Library</span>` : `${icon("bookmark")}<span>Add to Library</span>`
  }</button>`;
}

/** Share the current title. The detail route already lives in the URL, so location.href is the link. */
function shareButton(): string {
  return `<button class="chip" data-action="share">${icon("share")}<span>Share</span></button>`;
}
async function shareTitle(): Promise<boolean> {
  if (!state?.meta) return true;
  const url = location.href; // the detail route (#/detail/type/id) is the shareable link
  try {
    if (navigator.share) {
      await navigator.share({ title: state.meta.name, url });
    } else if (navigator.clipboard) {
      await navigator.clipboard.writeText(url);
      flashShareCopied();
    }
  } catch {
    // User dismissed the share sheet, or clipboard write was denied - nothing to recover.
  }
  return true;
}
/** Brief "Link copied" confirmation on the Share button after a clipboard-fallback copy. */
function flashShareCopied(): void {
  // Swap only the label span, not the whole button - setting textContent would wipe the leading icon.
  const span = hostEl?.querySelector<HTMLElement>('[data-action="share"] span');
  if (!span) return;
  const prev = span.textContent ?? "Share";
  span.textContent = "Link copied";
  setTimeout(() => {
    if (span.textContent === "Link copied") span.textContent = prev;
  }, 1500);
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
    <button class="back trailer-close" data-action="close-trailer">${icon("back")}<span>Close</span></button>
    <iframe class="trailer-frame" src="${escapeHtml(src)}" allow="autoplay; encrypted-media; fullscreen"
            sandbox="allow-scripts allow-same-origin allow-presentation"
            allowfullscreen referrerpolicy="strict-origin"></iframe>`;
}

function closeTrailer(): void {
  hostEl?.querySelector(".trailer-overlay")?.remove();
}

// ---- Playback wiring ---------------------------------------------------------------------------

/** Play a stream: direct/debrid urls go straight to the player. Torrents are not playable on web. `stream`
 *  is the user's chosen source; the rest of the ranked pool becomes the ordered fallback chain the player
 *  auto-advances through on a decode / silent-audio failure (D6), with browser-decodable audio preferred. */
async function playStream(stream: Stream): Promise<void> {
  if (!stream.url || !/^https?:\/\//i.test(stream.url)) return;
  const episode = state?.openEpisode ?? undefined;
  const title = episode
    ? `${state?.meta?.name ?? ""} · S${episode.season ?? 0}E${episode.episode ?? 0}`
    : state?.meta?.name ?? "VortX";

  // Fallback chain: the chosen url first, then the decodable-audio-preferred pool (deduped). So an
  // undecodable-audio pick still starts where the user asked but can auto-advance to a source with sound.
  const pool = playbackFallbacks(rankedFiltered())
    .map((s) => s.url)
    .filter((u): u is string => !!u && /^https?:\/\//i.test(u));
  const fallbacks = [stream.url, ...pool.filter((u) => u !== stream.url)];

  // Skip segments + next-episode are series playback niceties; fetched fail-soft so playback never waits.
  const skipSegments = state?.meta
    ? await fetchSkipSegments(state.meta.id, episode?.season, episode?.episode).catch(() => [])
    : [];
  const next = episode ? nextEpisode(episode) : null;

  await play(stream.url, title, {
    item: state?.meta
      ? {
          id: state.meta.id,
          type: state.meta.type,
          name: state.meta.name,
          poster: state.meta.poster,
          resumeId: episode?.id ?? state.meta.id,
        }
      : undefined,
    subtitles: state?.meta
      ? fetchSubtitles(addons, state.meta.type, episode?.id ?? state.meta.id)
      : undefined,
    fallbacks,
    skipSegments,
    onNextEpisode: next ? () => void playEpisodeById(next.id) : undefined,
  });
}

/** The episode that follows `current` in play order (next episode this season, else first of the next
 *  season), or null when it's the last one. Drives the player's Next Episode button + binge auto-advance. */
function nextEpisode(current: Video): Video | null {
  const videos = state?.meta?.videos ?? [];
  const eps = videos.filter((v) => v.episode !== undefined || v.season !== undefined);
  // Drop season-0 specials from the binge chain so it never routes a special ahead of the real premiere
  // (season 0 would otherwise sort first), matching the "skip specials" order used elsewhere. Keep them
  // only when the currently-open item is itself a special, so Next still works from within the specials run.
  const isSpecial = (current.season ?? 0) <= 0;
  const ordered = sortedVideos(isSpecial ? eps : eps.filter((v) => (v.season ?? 0) > 0));
  const i = ordered.findIndex((v) => v.id === current.id);
  return i >= 0 && i < ordered.length - 1 ? ordered[i + 1] : null;
}

/** Open an episode by id and immediately play its best source (used by the player's Next Episode action).
 *  Mirrors openEpisode's state setup, then auto-picks like the Watch button so playback is continuous. */
async function playEpisodeById(videoId: string): Promise<void> {
  if (!state?.meta) return;
  const episode = state.meta.videos?.find((v) => v.id === videoId);
  if (!episode) return;
  state.openEpisode = episode;
  state.showAllSources = false;
  state.sourceFilter = null;
  state.pickerOpen = false;
  state.pickerTier = null;
  render();
  await loadStreams(state.type, episode.id);
  const top = pickPreferred(rankedFiltered(), getSettings().preferredQuality);
  if (top) await playStream(top);
}

async function playBest(): Promise<boolean> {
  if (!state) return true;
  // Honor the user's preferred-quality cap (Settings): the best stream at or under it, else the absolute best.
  const top = pickPreferred(rankedFiltered(), getSettings().preferredQuality);
  if (top) await playStream(top);
  return true;
}

async function playVariant(node: HTMLElement): Promise<boolean> {
  if (!state) return true;
  const tier = node.dataset.tier;
  const index = Number(node.dataset.index);
  if (!tier || Number.isNaN(index)) return true;
  const variants = variantOptions(rankedFiltered(), tier);
  const stream = variants[index]?.stream;
  if (stream) await playStream(stream);
  return true;
}

async function playStreamRow(node: HTMLElement): Promise<boolean> {
  if (!state) return true;
  const base = node.dataset.base;
  const index = Number(node.dataset.index);
  if (Number.isNaN(index)) return true;
  const groups = rankedFiltered();
  const group = groups.find((g) => g.base === base);
  const stream = group?.streams[index];
  if (stream) await playStream(stream);
  return true;
}

async function playTrailer(): Promise<boolean> {
  if (!state?.meta) return true;
  // PRIMARY: the backend full trailer (progressive mp4 via trailer.vortx.tv), played in the web player -
  // the same /yt resolver path the native apps use, so web stays consistent. It is NOT HLS, so play() hands
  // it straight to the <video> element (no hls.js). No CW item / subtitles: a trailer must not record
  // Continue Watching progress or pull subtitle tracks.
  if (state.trailerUrl) {
    await play(state.trailerUrl, `${state.meta.name} · Trailer`);
    return true;
  }
  // FALLBACK: the YouTube iframe embed, when the backend has no trailer but the meta carries a YouTube id.
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
