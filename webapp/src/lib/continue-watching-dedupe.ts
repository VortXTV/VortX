/** Provider-backed identity supplied by a Continue Watching surface. */
export interface ContinueWatchingIdentity {
  id: string;
  type: string;
  aliases?: string[];
  freshness?: number;
  hasValidProgress?: boolean;
  removed?: boolean;
}

interface Candidate<T> {
  item: T;
  identity: ContinueWatchingIdentity;
  keys: Set<string>;
  sourceIndex: number;
}

interface Group<T> {
  candidates: Candidate<T>[];
  keys: Set<string>;
  firstIndex: number;
}

/**
 * Collapse a Continue Watching list by canonical provider identity while preserving first-component order.
 * Mutable names and poster URLs never participate. Alias overlap is transitive; freshest valid progress or an
 * explicit tombstone wins inside each component, with original input order as the deterministic final tie-break.
 */
export function foldContinueWatching<T>(
  items: T[],
  identityOf: (item: T) => ContinueWatchingIdentity,
): T[] {
  const groups: Group<T>[] = [];
  items.forEach((item, sourceIndex) => {
    const identity = identityOf(item);
    const keys = continueWatchingIdentityKeys(identity);
    if (!keys.size) return;
    const candidate: Candidate<T> = { item, identity, keys, sourceIndex };
    const matches = groups.map((group, index) => (intersects(group.keys, keys) ? index : -1)).filter((i) => i >= 0);
    if (!matches.length) {
      groups.push({ candidates: [candidate], keys, firstIndex: sourceIndex });
      return;
    }

    const target = matches[0];
    groups[target].candidates.push(candidate);
    keys.forEach((key) => groups[target].keys.add(key));
    for (const index of matches.slice(1).reverse()) {
      groups[target].candidates.push(...groups[index].candidates);
      groups[index].keys.forEach((key) => groups[target].keys.add(key));
      groups.splice(index, 1);
    }
  });

  return groups
    .sort((a, b) => a.firstIndex - b.firstIndex)
    .flatMap((group) => {
      const eligible = group.candidates.filter(
        (candidate) => candidate.identity.removed || candidate.identity.hasValidProgress !== false,
      );
      let winner = eligible[0] ?? group.candidates[0];
      if (!winner) return [];
      for (const candidate of eligible.slice(1)) {
        if (preferred(candidate, winner)) winner = candidate;
      }
      return winner.identity.removed ? [] : [winner.item];
    });
}

/** Canonical title-level keys for display id plus every independently carried alias. */
export function continueWatchingIdentityKeys(identity: ContinueWatchingIdentity): Set<string> {
  const type = normalizeType(identity.type);
  if (!type) return new Set();
  const keys = new Set<string>();
  for (const raw of [identity.id, ...(identity.aliases ?? [])]) {
    const canonical = canonicalProviderId(raw, type, type === "series", type !== "series");
    if (canonical) keys.add(`${type}\u001f${canonical}`);
  }
  return keys;
}

/** Exact played-id identity for per-episode progress storage. Unlike title keys, this retains S/E. */
export function canonicalPlaybackIdentity(id: string, type: string): string | null {
  const normalizedType = normalizeType(type);
  const canonical = canonicalProviderId(id, normalizedType, false);
  return canonical ? `${normalizedType}\u001f${canonical}` : null;
}

export function identityKeysIntersect(lhs: Set<string>, rhs: Set<string>): boolean {
  return intersects(lhs, rhs);
}

function preferred<T>(candidate: Candidate<T>, incumbent: Candidate<T>): boolean {
  const lhs = Number.isFinite(candidate.identity.freshness) ? candidate.identity.freshness : undefined;
  const rhs = Number.isFinite(incumbent.identity.freshness) ? incumbent.identity.freshness : undefined;
  if (lhs !== undefined && rhs !== undefined && lhs !== rhs) return lhs > rhs;
  if (lhs !== undefined && rhs === undefined) return true;
  if (lhs === undefined && rhs !== undefined) return false;
  if (lhs === undefined && rhs === undefined) return candidate.sourceIndex < incumbent.sourceIndex;
  if (Boolean(candidate.identity.removed) !== Boolean(incumbent.identity.removed)) {
    return Boolean(candidate.identity.removed);
  }
  return candidate.sourceIndex < incumbent.sourceIndex;
}

function intersects(lhs: Set<string>, rhs: Set<string>): boolean {
  for (const value of lhs) if (rhs.has(value)) return true;
  return false;
}

function normalizeType(value: string): string {
  const type = value.trim().toLowerCase();
  if (type === "show" || type === "tv" || type === "series") return "series";
  if (type === "film" || type === "movie") return "movie";
  return type;
}

function canonicalProviderId(
  value: string,
  type: string,
  reduceEpisode: boolean,
  preserveOpaqueEpisode = false,
): string | null {
  const raw = value.trim().toLowerCase();
  if (!raw) return null;

  const imdb = /^(?:imdb:)?(tt[0-9]{1,10})(:[0-9]{1,4}:[0-9]{1,4})?$/.exec(raw);
  if (imdb?.[2] && preserveOpaqueEpisode) return raw;
  if (imdb) return `imdb:${imdb[1]}${reduceEpisode ? "" : (imdb[2] ?? "")}`;

  const tmdb = /^tmdb:(?:(movie|tv|series|show):)?([0-9]{1,10})(:[0-9]{1,4}:[0-9]{1,4})?$/.exec(raw);
  if (tmdb) {
    if (tmdb[3] && preserveOpaqueEpisode) return raw;
    const namespace = tmdb[1] === "movie" ? "movie" : tmdb[1] ? "series" : type;
    return `tmdb:${namespace}:${tmdb[2]}${reduceEpisode ? "" : (tmdb[3] ?? "")}`;
  }

  const anime = /^(kitsu|anilist|mal|anidb):([0-9]{1,10})(:[0-9]{1,4}:[0-9]{1,4})?$/.exec(raw);
  if (anime?.[3] && preserveOpaqueEpisode) return raw;
  if (anime) return `${anime[1]}:${anime[2]}${reduceEpisode ? "" : (anime[3] ?? "")}`;

  return raw;
}
