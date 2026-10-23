// Public read-only native carrier DTO adapter, aligned with vortx-site/nativeSyncProjection.
// Verified by actual Apple/Android CABI exports; no private engine implementation.
// Read-only projection of the native account carrier. Legacy JSON is an import baseline, not a
// mirror of later native edits. This module never advances clocks or changes either carrier.



type ObjectValue = Record<string, any>;
export interface NativeMediaItem { id: string; type?: string; name: string; poster?: string; t?: number; d?: number; resumeId?: string; updatedAt?: number; source: string; }
export interface NativeAddonMember { identity: string; addon: ObjectValue | null; live: boolean; addedAt: number; removedAt: number; }
export interface NativeSyncProjection {
  scope: string;
  globals: ObjectValue;
  profiles: { id: string; name: string; main: boolean; avatar?: string; settings: ObjectValue; binding: string; pending: boolean; locked: boolean; kids: boolean }[];
  addonsByProfile: Record<string, NativeAddonMember[]>;
  addonOrderByProfile: Record<string, string[]>;
  watchlistByProfile: Record<string, NativeMediaItem[]>;
  watchBasisByProfile: Record<string, string>;
  watchRemovalsByProfile: Record<string, { id: string; type: string; resumeId: string; removedAt: number; aliases: string[] }[]>;
  unsupported: boolean;
  ownerProfileId: string;
  libraryByProfile: Record<string, NativeMediaItem[]>;
  continueByProfile: Record<string, NativeMediaItem[]>;
  ownerAddons: NativeAddonMember[];
  ownerAddonOrder: string[];
  ownerAddonMembership: ObjectValue;
  ownerAccountBinding: ProfileAccountBindingRevision | null;
}

const object = (value: unknown): ObjectValue | null => value !== null && typeof value === "object" && !Array.isArray(value) ? value as ObjectValue : null;
const id = (value: string): string => canonicalProfileID(value) ?? value;
const error = (): never => { throw new Error("Could not read this account's native sync data. Update VortX or retry after syncing a device."); };
function map(value: unknown): ObjectValue { if (value === undefined) return {}; return object(value) ?? error(); }
function clock(value: unknown): number { if (value === undefined) return 0; return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : error(); }
function keyed(values: ObjectValue, profileId: string): any {
  const keys = Object.keys(values).filter((key) => id(key) === profileId);
  if (keys.length > 1) error();
  return keys.length ? values[keys[0]] : undefined;
}

/** Known manifest wire fields only. Omitted defaults and documented nulls are admitted; unknown
 *  extensions remain untouched for raw event fingerprints and forward-compatible native decoding. */
export function isNativeAddonManifest(value: unknown): boolean {
  const manifest = object(value);
  if (!manifest || [manifest.id, manifest.name, manifest.version].some((field) => typeof field !== "string")) return false;
  const strings = (field: unknown): boolean => Array.isArray(field) && field.every((item) => typeof item === "string");
  const optional = (field: unknown, check: (field: any) => boolean, nullable = false): boolean => field === undefined || (nullable && field === null) || check(field);
  const extra = (field: unknown): boolean => {
    const item = object(field);
    return !!item && typeof item.name === "string" && optional(item.isRequired, (flag) => typeof flag === "boolean")
      && optional(item.options, strings, true) && optional(item.optionsLimit, (limit) => Number.isInteger(limit) && limit >= 0 && limit <= 4294967295, true);
  };
  const catalog = (field: unknown): boolean => {
    const item = object(field);
    return !!item && typeof item.type === "string" && typeof item.id === "string" && optional(item.name, (name) => typeof name === "string", true)
      && optional(item.extra, (items) => Array.isArray(items) && items.every(extra))
      && optional(item.extraSupported, strings, true) && optional(item.extraRequired, strings, true);
  };
  const resource = (field: unknown): boolean => {
    if (typeof field === "string") return true;
    const item = object(field);
    return !!item && typeof item.name === "string" && optional(item.types, strings) && optional(item.idPrefixes, strings, true);
  };
  return optional(manifest.types, strings)
    && optional(manifest.resources, (items) => Array.isArray(items) && items.every(resource))
    && optional(manifest.catalogs, (items) => Array.isArray(items) && items.every(catalog))
    && optional(manifest.addonCatalogs, (items) => Array.isArray(items) && items.every(catalog))
    && optional(manifest.idPrefixes, strings, true)
    && [manifest.description, manifest.background, manifest.logo, manifest.contactEmail].every((field) => optional(field, (text) => typeof text === "string", true))
    && optional(manifest.behaviorHints, (field) => {
      const hints = object(field);
      return !!hints && [hints.adult, hints.p2p, hints.configurable, hints.configurationRequired].every((flag) => optional(flag, (entry) => typeof entry === "boolean"));
    }, true);
}

function sourceKey(value: unknown): [number, bigint, string, string] {
  if (value === undefined) return [1, 0n, "", ""]; // Native edits win a causal-clock tie.
  const source = object(value) ?? error();
  if (source.schemaVersion !== 1 || typeof source.counter !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(source.counter)
    || BigInt(source.counter) >= 18446744073709551615n || typeof source.eventId !== "string" || !/^[0-9a-f]{32}$/.test(source.eventId)
    || typeof source.fingerprint !== "string" || !/^[0-9a-f]{64}$/.test(source.fingerprint)) error();
  clock(source.observedClock);
  return [0, BigInt(source.counter), source.eventId, source.fingerprint];
}
function sourceWins(left: unknown, right: unknown): boolean {
  const a = sourceKey(left), b = sourceKey(right);
  for (let index = 0; index < a.length; index++) { if (a[index] !== b[index]) return a[index] > b[index]; }
  return false; // Removal retains the exact tie.
}

function members(raw: unknown, kind: "addon" | "library"): { entries: NativeAddonMember[]; order: string[] } {
  const bucket = map(raw), records = map(bucket.records), order = map(bucket.order);
  if (order.ids !== undefined && (!Array.isArray(order.ids) || order.ids.some((key: unknown) => typeof key !== "string"))) error();
  clock(order.updatedAt);
  const entries = Object.entries(records).map(([identity, rawRecord]) => {
    const record = object(rawRecord) ?? error();
    const addedAt = clock(record.addedAt), removedAt = clock(record.removedAt); clock(record.valueAt);
    const sources = map(record.webSources);
    for (const field of ["addedAt", "removedAt", "valueAt"]) if (sources[field] !== undefined) sourceKey(sources[field]);
    const value = record.value === null ? null : object(record.value) ?? error();
    if (value && kind === "library") {
      if (typeof value.id !== "string" || typeof value.name !== "string" || !["standard", "native_magnet", "torrent_playlist"].includes(value.kind)
        || identity !== `${value.kind === "standard" ? value.type : value.kind}:${value.id}` || (value.poster != null && typeof value.poster !== "string")) error();
      if (value.kind === "standard" && typeof value.type !== "string") error();
      if (value.kind === "native_magnet" && (typeof value.infohash !== "string" || (value.fileIdx != null && (!Number.isInteger(value.fileIdx) || value.fileIdx < 0 || value.fileIdx > 4294967295))
        || (value.trackers !== undefined && (!Array.isArray(value.trackers) || value.trackers.some((item: unknown) => typeof item !== "string"))))) error();
      if (value.kind === "torrent_playlist" && value.entries !== undefined && (!Array.isArray(value.entries) || value.entries.some((item: unknown) => typeof item !== "string"))) error();
    }
    if (value && kind === "addon") {
      const manifest = object(value.manifest), flags = value.flags === undefined ? {} : object(value.flags);
      if (typeof value.transportUrl !== "string" || nativeAddonIdentity(value.transportUrl) !== identity || !manifest || !flags
        || !isNativeAddonManifest(manifest)
        || [flags.official, flags.protected].some((field) => field !== undefined && typeof field !== "boolean")) error();
    }
    return { identity, addon: value, live: value !== null && (addedAt > removedAt || (addedAt === removedAt && sourceWins(sources.addedAt, sources.removedAt))), addedAt, removedAt };
  });
  const byKey = new Map(entries.map((entry) => [entry.identity, entry]));
  const ordered = [...new Set((order.ids ?? []) as string[])].filter((key) => byKey.get(key)?.live);
  const explicitlyOrdered = new Set(ordered);
  ordered.push(...entries.filter((entry) => entry.live && !explicitlyOrdered.has(entry.identity))
    .sort((a, b) => a.addedAt - b.addedAt || nativeStringCompare(a.identity, b.identity)).map((entry) => entry.identity));
  return { entries, order: ordered };
}

// Kernel membership preserves configured path/query case; only scheme and authority are folded.
export function nativeAddonIdentity(value: string): string {
  const match = /^(https?):\/\/([^/?#]+)(.*)$/i.exec(value.trim());
  if (!match) error();
  const authority = match![2], offset = authority.lastIndexOf("@") + 1;
  const host = authority.slice(offset);
  if (!host || /\s/.test(host)) error();
  return `${match![1].toLowerCase()}://${authority.slice(0, offset)}${host.replace(/[A-Z]/g, (letter) => letter.toLowerCase())}${match![3]}`;
}

function profileBuckets(doc: ObjectValue, native: ObjectValue, profileId: string, profile: ObjectValue): { addons: any; library: any; watch: any; pending: boolean } {
  const retainedSlot = keyed(map(native.accountSlots), profileId);
  if (retainedSlot !== undefined && !object(retainedSlot)) error();
  const state = nativeProfileAccountBindingState(doc, profileId);
  if (state.current && canonicalJSON(state.current.account) !== canonicalJSON(profile.account)) error();
  if (state.transitioned) {
    const slotState = object(keyed(map(native.accountSlots), profileId)) ?? error();
    const account = state.current!.account;
    const slotKey = account.kind === "own" ? `own:${canonicalJSONHashSync(account.value)}` : account.kind === "pending_own" ? "pending" : "shared";
    const slot = object(map(slotState.slots)[slotKey]) ?? error();
    // Account identity selects exactly one retained slot. Never use the root's stale projection or
    // another retained account when the selected account's bucket is missing or malformed.
    if (canonicalJSON(slot.account) !== canonicalJSON(account)) error();
    if (account.kind === "pending_own") {
      members(slot.addons, "addon"); members(slot.library, "library"); playback(slot.watch, []);
      return { addons: undefined, library: undefined, watch: undefined, pending: true };
    }
    return { addons: slot.addons, library: slot.library, watch: slot.watch, pending: false };
  }
  if (state.current?.account.kind === "pending_own") return { addons: undefined, library: undefined, watch: undefined, pending: true };
  return { addons: keyed(map(native.addons), profileId), library: keyed(map(native.libraries), profileId), watch: keyed(map(native.watches), profileId), pending: false };
}

type WatchUnit = { key: string; state: ObjectValue; context: ObjectValue };
function nativeStringCompare(a: string, b: string): number {
  const left = new TextEncoder().encode(a), right = new TextEncoder().encode(b);
  for (let index = 0; index < Math.min(left.length, right.length); index++) if (left[index] !== right[index]) return left[index] - right[index];
  return left.length - right.length;
}
function contextKey(context: ObjectValue): string {
  // Native WatchContext's serialized DTO order is the accepted metadata tie-break, not sorted-key JSON.
  return JSON.stringify({ metaId: context.metaId, ...(context.videoId != null ? { videoId: context.videoId } : {}), name: context.name ?? "",
    ...(context.type != null ? { type: context.type } : {}), ...(context.poster != null ? { poster: context.poster } : {}),
    durationMs: clock(context.durationMs), updatedAt: clock(context.updatedAt) });
}
function contextCompare(a: ObjectValue, b: ObjectValue): number { return clock(a.updatedAt) - clock(b.updatedAt) || nativeStringCompare(contextKey(a), contextKey(b)); }
function identityParts(raw: string): [string, string] {
  const token = raw.trim(), separator = token.indexOf(":");
  if (separator < 0) return [/^tt[0-9]+$/.test(token) ? "imdb" : "id", token];
  const namespace = token.slice(0, separator).toLowerCase();
  const aliases: Record<string, string> = { themoviedb: "tmdb", thetvdb: "tvdb", myanimelist: "mal" };
  return [aliases[namespace] ?? namespace, token.slice(separator + 1)];
}
function playback(raw: unknown, saved: NativeMediaItem[]): NativeMediaItem[] {
  const watch = map(raw), log = map(watch.log), contexts = map(watch.contexts);
  const aliases = new Map<string, string>();
  if (watch.identityLinks !== undefined && !Array.isArray(watch.identityLinks)) error();
  const groups: Set<string>[] = [];
  for (const row of watch.identityLinks ?? []) {
    if (!Array.isArray(row) || row.some((value) => typeof value !== "string" || !value)) error();
    const group = new Set<string>(row.flatMap((raw: string) => { const [namespace, value] = identityParts(raw); return [raw, namespace === "imdb" || namespace === "id" ? value : `${namespace}:${value}`]; }));
    for (let index = groups.length - 1; index >= 0; index--) if ([...group].some((value) => groups[index].has(value))) {
      for (const value of groups.splice(index, 1)[0]) group.add(value);
    }
    groups.push(group);
  }
  for (const group of groups) {
    const values = [...group].sort(nativeStringCompare), namespaces = new Map<string, string>();
    for (const raw of values) { const [namespace, value] = identityParts(raw), prior = namespaces.get(namespace); if (prior === undefined || nativeStringCompare(value, prior) < 0) namespaces.set(namespace, value); }
    const namespace = ["imdb", "tmdb", "tvdb", "anilist", "kitsu", "mal", "trakt", "simkl"].find((key) => namespaces.has(key)) ?? [...namespaces.keys()].sort(nativeStringCompare)[0];
    const canonical = namespace === "imdb" || namespace === "id" ? namespaces.get(namespace)! : `${namespace}:${namespaces.get(namespace)!}`;
    for (const value of values) aliases.set(value, canonical);
  }
  const canonical = (rawId: string): string => {
    if (aliases.has(rawId)) return aliases.get(rawId)!;
    const episode = /^(.*)(:\d+:\d+)$/.exec(rawId);
    return episode && aliases.has(episode[1]) ? aliases.get(episode[1])! + episode[2] : rawId;
  };
  // Index lookups once while preserving entry order and lazy validation of unused contexts.
  const contextGroups = new Map<string, unknown[]>(), resolvedContexts = new Map<string, ObjectValue | null>();
  for (const [key, value] of Object.entries(contexts)) {
    const canonicalKey = canonical(key), group = contextGroups.get(canonicalKey);
    if (group) group.push(value); else contextGroups.set(canonicalKey, [value]);
  }
  const savedIds = new Set(saved.map((item) => item.id)), savedByCanonical = new Map<string, NativeMediaItem>();
  for (const item of saved) {
    const canonicalId = canonical(item.id);
    if (!savedByCanonical.has(canonicalId)) savedByCanonical.set(canonicalId, item);
  }
  const savedIdLengths = new Set<number>();
  let maximumSavedIdLength = 0;
  for (const item of saved) {
    savedIdLengths.add(item.id.length);
    maximumSavedIdLength = Math.max(maximumSavedIdLength, item.id.length);
  }
  const savedTitle = (key: string): string | undefined => {
    if (!savedIds.size) return undefined;
    // Colon-heavy identifiers must not cause hashing of every ever-longer prefix.
    // Candidate lengths come only from saved IDs, bounding hashed bytes by saved input.
    for (let separator = key.lastIndexOf(":", maximumSavedIdLength); separator >= 0; separator = key.lastIndexOf(":", separator - 1)) {
      if (savedIdLengths.has(separator) && savedIds.has(key.slice(0, separator))) return key.slice(0, separator);
      if (separator === 0) break;
    }
    return undefined;
  };
  const units = new Map<string, WatchUnit>();
  for (const [key, rawState] of Object.entries(log)) {
    const state = object(rawState) ?? error();
    const values: ObjectValue = {};
    for (const field of ["resume_ms", "resume_at", "watched_at", "times_watched", "reset_at", "removed_at"]) values[field] = clock(state[field]);
    let context = object(contexts[key]);
    if (!context) {
      const unitKey = canonical(key);
      if (!resolvedContexts.has(unitKey)) {
        const candidates = (contextGroups.get(unitKey) ?? []).map((value) => object(value) ?? error());
        resolvedContexts.set(unitKey, candidates.sort((a, b) => contextCompare(b, a))[0] ?? null);
      }
      context = resolvedContexts.get(unitKey)!;
    }
    if (!context) {
      const title = savedTitle(key)
        ?? (/^(tt\d+):\d+:\d+$/.exec(key)?.[1]) ?? (/^(kitsu:\d+):\d+$/.exec(key)?.[1]) ?? key;
      const descriptor = savedByCanonical.get(canonical(title));
      context = { metaId: title, name: descriptor?.name ?? title, ...(descriptor?.type ? { type: descriptor.type } : {}), ...(descriptor?.poster ? { poster: descriptor.poster } : {}), durationMs: 0, updatedAt: 0 };
    }
    if (typeof context.metaId !== "string" || !context.metaId || (context.name !== undefined && typeof context.name !== "string")
      || ["videoId", "type", "poster"].some((field) => context![field] != null && typeof context![field] !== "string")) error();
    clock(context.durationMs); clock(context.updatedAt);
    const unitKey = canonical(key), previous = units.get(unitKey);
    if (previous) {
      const previousState = previous.state;
      const newerResume = values.resume_at > previousState.resume_at || (values.resume_at === previousState.resume_at && values.resume_ms > previousState.resume_ms);
      if (newerResume) { previousState.resume_at = values.resume_at; previousState.resume_ms = values.resume_ms; }
      for (const field of ["watched_at", "times_watched", "reset_at", "removed_at"]) previousState[field] = Math.max(previousState[field], values[field]);
      if (contextCompare(context, previous.context) > 0) previous.context = context;
    } else units.set(unitKey, { key: unitKey, state: values, context });
  }
  const titles = new Map<string, WatchUnit[]>();
  for (const unit of units.values()) {
    const title = canonical(unit.context.metaId), group = titles.get(title);
    if (group) group.push(unit); else titles.set(title, [unit]);
  }
  const rows: (NativeMediaItem & { updatedAt: number })[] = [];
  const watched = (state: ObjectValue) => state.watched_at > 0 && state.watched_at >= state.reset_at;
  for (const [title, values] of titles) {
    values.sort((a, b) => Math.max(b.state.resume_at, b.state.watched_at, b.state.reset_at) - Math.max(a.state.resume_at, a.state.watched_at, a.state.reset_at) || nativeStringCompare(b.key, a.key));
    const latest = values[0], state = latest.state, context = latest.context;
    let activity = 0;
    for (const unit of values) activity = Math.max(activity, unit.state.resume_at, unit.state.watched_at);
    const whole = values.find((unit) => unit.key === title);
    if (whole && (watched(whole.state) || whole.state.removed_at > activity)) continue;
    if (watched(state) || state.removed_at > Math.max(state.resume_at, state.watched_at) || (state.reset_at > 0 && state.reset_at >= state.resume_at) || state.resume_at <= 0) continue;
    // Finished/reset/removal evidence decides visibility. Unknown duration is still a real resume;
    // percentage heuristics must not overrule the kernel's accepted watch state.
    rows.push({ id: context.metaId, type: context.type, name: context.name || context.metaId, poster: context.poster, t: state.resume_ms, d: clock(context.durationMs), source: "vortx", resumeId: context.videoId || latest.key, updatedAt: state.resume_at });
  }
  rows.sort((a, b) => b.updatedAt - a.updatedAt || nativeStringCompare(a.id, b.id));
  return rows.slice(0, 30);
}

export function projectNativeSync(doc: ObjectValue, expectedScope?: string): NativeSyncProjection | null {
  if (!Object.prototype.hasOwnProperty.call(doc, "nativeSync")) return null;
  const native = object(doc.nativeSync) ?? error();
  if (![1, 2, 3, 4, 5].includes(native.schemaVersion) || typeof native.scope !== "string" || !native.scope || typeof native.ownerProfileId !== "string") error();
  if (expectedScope !== undefined && native.scope !== expectedScope) error();
  const profiles = map(native.profiles ?? object(native.roster)?.profiles);
  const canonicalIds = Object.keys(profiles).map(id);
  if (new Set(canonicalIds).size !== canonicalIds.length) error();
  const liveOwners = Object.values(profiles).filter((raw) => {
    const record = object(raw) ?? error(), profile = object(record.profile) ?? record;
    return profile.deleted !== true && (profile.owner === true || profile.isOwner === true);
  });
  if (liveOwners.length !== 1) error();
  const ownerProfileId = id(native.ownerProfileId), ownerRecord = object(keyed(profiles, ownerProfileId));
  const owner = object(ownerRecord?.profile) ?? ownerRecord;
  if (!owner || owner.deleted === true || (owner.owner !== true && owner.isOwner !== true)) error();
  const libraryByProfile: Record<string, NativeMediaItem[]> = {}, continueByProfile: Record<string, NativeMediaItem[]> = {};
  let ownerAddons: NativeAddonMember[] = [], ownerAddonOrder: string[] = [];
  let ownerAddonMembership: ObjectValue = { records: {}, order: { updatedAt: 0, ids: [] } };
  const projectedProfiles: NativeSyncProjection["profiles"] = [];
  const addonsByProfile: NativeSyncProjection["addonsByProfile"] = {}, addonOrderByProfile: Record<string, string[]> = {};
  const watchlistByProfile: Record<string, NativeMediaItem[]> = {}, watchBasisByProfile: Record<string, string> = {};
  const watchRemovalsByProfile: NativeSyncProjection["watchRemovalsByProfile"] = {};
  let unsupported = false;
  const host = hostCarrier(doc.nativeHostPreferences, native.scope, ownerProfileId);
  const globals: ObjectValue = {};
  const globalFields = map(host?.globals?.fields);
  for (const [field, key] of [["stremiox.autoplayTrailers", "autoplayTrailers"], ["stremiox.directLinksOnly", "directLinksOnly"]]) {
    if (globalFields[field] === undefined) continue;
    const value = register(globalFields[field]).value;
    if (value !== null && typeof value !== "boolean") error();
    globals[key] = value === null ? key === "autoplayTrailers" : value;
  }
  if (globalFields["stremiox.performanceMode"] !== undefined) {
    const value = register(globalFields["stremiox.performanceMode"]).value;
    if (value !== null && typeof value !== "string") error();
    if (value === null || ["auto", "full", "reduced"].includes(value)) globals.performance = value ?? "auto";
    else unsupported = true;
  }
  for (const [rawId, rawRecord] of Object.entries(profiles)) {
    const record = object(rawRecord) ?? error(), profile = object(record.profile) ?? record, profileId = id(rawId);
    if (!rawId || (profile.id !== undefined && (typeof profile.id !== "string" || id(profile.id) !== profileId))
      || (profile.deleted !== undefined && typeof profile.deleted !== "boolean")) error();
    if (profile.deleted === true) continue;
    const buckets = profileBuckets(doc, native, profileId, profile);
    const hostFields = map(object(keyed(map(host?.profiles), profileId))?.fields);
    const settings: ObjectValue = { accent: "ember", oled: false, textScale: 1000, disabledAddons: [], ...map(profile.settings) };
    if (settings.accent === null) settings.accent = "ember";
    if (typeof settings.accent !== "string" || typeof settings.oled !== "boolean") error();
    if (!Array.isArray(settings.disabledAddons) || !settings.disabledAddons.every((url: unknown) => typeof url === "string")) error();
    settings.textScale = clock(settings.textScale) / 1000;
    if (hostFields.playback !== undefined) {
      const value = register(hostFields.playback).value;
      settings.playback = value === null ? {} : object(value) ?? error();
    }
    const avatarValue = hostFields.avatar === undefined ? undefined : register(hostFields.avatar).value;
    if (avatarValue != null && typeof avatarValue !== "string") error();
    if (typeof profile.name !== "string" || !profile.name || (profile.owner !== undefined && typeof profile.owner !== "boolean")) error();
    if (profile.pin != null && typeof profile.pin !== "string") error();
    const parental = profile.parental === undefined ? {} : object(profile.parental) ?? error();
    for (const key of ["kids", "familyEdit"]) if (parental[key] !== undefined && typeof parental[key] !== "boolean") error();
    const bound = nativeProfileAccountBindingState(doc, profileId).current;
    projectedProfiles.push({ id: profileId, name: profile.name, main: profileId === ownerProfileId,
      avatar: avatarValue === null ? "🍿" : avatarValue, settings,
      binding: canonicalJSON(bound), pending: buckets.pending, locked: typeof profile.pin === "string" && !!profile.pin,
      kids: parental.kids === true });
    if (projectedProfiles[projectedProfiles.length - 1].locked || projectedProfiles[projectedProfiles.length - 1].kids) unsupported = true;
    watchlistByProfile[profileId] = hostWatchlist(hostFields);
    watchBasisByProfile[profileId] = canonicalJSONHashSync(buckets.watch ?? {});
    const watch = map(buckets.watch), contexts = map(watch.contexts);
    watchRemovalsByProfile[profileId] = Object.entries(map(watch.log)).flatMap(([key, raw]) => {
      const state = object(raw) ?? error(), context = object(contexts[key]);
      const removed = Math.max(clock(state.removed_at),
        clock(state.watched_at) > 0 && clock(state.watched_at) >= clock(state.reset_at) ? Math.max(clock(state.watched_at), clock(state.resume_at)) : 0,
        clock(state.reset_at) >= clock(state.resume_at) ? clock(state.reset_at) : 0);
      return removed > 0 ? [{ id: context?.metaId ?? key, type: context?.type ?? "", resumeId: key,
        removedAt: removed * 1000, aliases: (watch.identityLinks ?? []).filter((group: string[]) => group.includes(key) || group.includes(context?.metaId)).flat() }] : [];
    });
    const addonBucket = members(buckets.addons, "addon");
    addonsByProfile[profileId] = addonBucket.entries;
    addonOrderByProfile[profileId] = addonBucket.order;
    if (addonBucket.entries.some((entry) => entry.live && typeof entry.addon?.transportUrl === "string" && !/^https:\/\//i.test(entry.addon.transportUrl))) unsupported = true;
    const membership = members(buckets.library, "library");
    const membershipById = new Map(membership.entries.map((entry) => [entry.identity, entry]));
    const saved = membership.order.map((key) => membershipById.get(key)!)
      .map((entry) => ({ id: entry.addon!.id, type: entry.addon!.kind === "standard" ? entry.addon!.type : entry.addon!.kind,
        name: entry.addon!.name ?? entry.addon!.id, poster: entry.addon!.poster, source: "vortx" }));
    if (saved.some((item) => item.type === "native_magnet" || item.type === "torrent_playlist")) unsupported = true;
    libraryByProfile[profileId] = saved;
    const watching = playback(buckets.watch, saved);
    continueByProfile[profileId] = watching;
    if (profileId === ownerProfileId) {
      const addons = members(buckets.addons, "addon"); ownerAddons = addons.entries; ownerAddonOrder = addons.order;
      ownerAddonMembership = buckets.addons === undefined ? ownerAddonMembership : object(buckets.addons) ?? error();
    }
  }
  if (projectedProfiles.filter((profile) => profile.main).length !== 1) error();
  for (const profile of projectedProfiles) {
    const record = object(keyed(profiles, profile.id))!;
    const value = object(record.profile) ?? record;
    if (!profile.pending && profile.id !== ownerProfileId && value.addons === "share_primary") {
      addonsByProfile[profile.id] = ownerAddons;
      addonOrderByProfile[profile.id] = ownerAddonOrder;
    }
  }
  return { scope: native.scope, globals, profiles: projectedProfiles, addonsByProfile, addonOrderByProfile, watchlistByProfile, watchBasisByProfile, watchRemovalsByProfile, unsupported,
    ownerProfileId, libraryByProfile, continueByProfile, ownerAddons, ownerAddonOrder,
    ownerAddonMembership, ownerAccountBinding: nativeProfileAccountBindingState(doc, ownerProfileId).current };
}

interface ProfileAccountBindingRevision { account: ObjectValue; revision: number; transactionId: string | null }
function register(raw: unknown): ObjectValue {
  const value = object(raw) ?? error();
  if (Object.keys(value).length !== 3 || !["clock", "actor", "value"].every((key) => key in value)) error();
  clock(value.clock);
  if (typeof value.actor !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value.actor) || !("value" in value)) error();
  return value;
}
function hostCarrier(raw: unknown, scope: string, owner: string): ObjectValue | null {
  if (raw === undefined) return null;
  const value = object(raw) ?? error();
  if (value.schemaVersion !== 1 || value.scope !== scope || typeof value.ownerProfileId !== "string" || id(value.ownerProfileId) !== owner) error();
  for (const group of [...Object.values(map(value.profiles)), value.globals]) {
    for (const raw of Object.values(map((object(group) ?? error()).fields))) register(raw);
  }
  return value;
}
function hostWatchlist(fields: ObjectValue): NativeMediaItem[] {
  const rows: (NativeMediaItem & { addedAt: number })[] = [];
  for (const [field, raw] of Object.entries(fields)) {
    if (!field.startsWith("watchlist.")) continue;
    const match = /^watchlist\.(movie|series)\.([A-Za-z0-9_-]+)$/.exec(field);
    if (!match) error();
    const token = match![2].replace(/-/g, "+").replace(/_/g, "/");
    let decoded: string;
    try { decoded = atob(token + "=".repeat((4 - token.length % 4) % 4)); } catch { error(); }
    if (!/^(tt|tmdb)[A-Za-z0-9:._-]*$/.test(decoded!) || decoded!.length > 512 ||
      btoa(decoded!).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") !== match![2]) error();
    const value = register(raw).value;
    if (value === null) continue;
    const entry = object(value) ?? error();
    if (Object.keys(entry).some((key) => !["id", "type", "name", "poster", "addedAt"].includes(key)) ||
      entry.id !== decoded! || entry.type !== match![1] || typeof entry.addedAt !== "number" ||
      !Number.isFinite(entry.addedAt) || entry.addedAt < 0 || entry.addedAt > Number.MAX_SAFE_INTEGER ||
      (entry.name != null && (typeof entry.name !== "string" || new TextEncoder().encode(entry.name).length > 4096)) ||
      (entry.poster != null && (typeof entry.poster !== "string" || new TextEncoder().encode(entry.poster).length > 8192))) error();
    rows.push({ id: entry.id, type: entry.type, name: entry.name || entry.id, poster: entry.poster, addedAt: entry.addedAt, source: "vortx" });
  }
  return rows.sort((a, b) => b.addedAt - a.addedAt || nativeStringCompare(a.type!, b.type!) || nativeStringCompare(a.id, b.id));
}
function canonicalProfileID(value: string): string | null {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value) ? value.toUpperCase() : null;
}
function canonicalJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON).join(",") + "]";
  return "{" + Object.keys(value).sort().map((key) => JSON.stringify(key) + ":" + canonicalJSON((value as ObjectValue)[key])).join(",") + "}";
}
function canonicalJSONHashSync(value: unknown): string { return sha256Sync(new TextEncoder().encode(canonicalJSON(value))); }
function binding(value: unknown): ProfileAccountBindingRevision {
  const raw = object(value) ?? error(), account = object(raw.account) ?? error();
  if (!["local_only", "pending_own", "shared", "own"].includes(account.kind) ||
    (["shared", "own"].includes(account.kind) && (typeof account.value !== "string" || !account.value || account.value.trim() !== account.value)) ||
    (["local_only", "pending_own"].includes(account.kind) && Object.keys(account).length !== 1) ||
    (["shared", "own"].includes(account.kind) && (Object.keys(account).length !== 2 || Object.keys(account).some((key) => key !== "kind" && key !== "value"))) ||
    Object.keys(raw).length !== 3 || Object.keys(raw).some((key) => !["account", "revision", "transactionId"].includes(key))) error();
  clock(raw.revision);
  if ((raw.revision === 0) !== (raw.transactionId === null) ||
    (raw.transactionId !== null && (typeof raw.transactionId !== "string" || !raw.transactionId))) error();
  return raw as ProfileAccountBindingRevision;
}
function nativeProfileAccountBindingState(doc: ObjectValue, profileId: string): { current: ProfileAccountBindingRevision | null; transitioned: boolean } {
  const native = object(doc.nativeSync) ?? error();
  const slot = keyed(map(native.accountSlots), profileId);
  if (slot !== undefined) return { current: binding((object(slot) ?? error()).activeBinding), transitioned: true };
  const record = object(keyed(map(native.profiles ?? object(native.roster)?.profiles), profileId)) ?? error();
  const profile = object(record.profile) ?? record;
  return { current: profile.account === undefined ? null : binding({ account: profile.account, revision: 0, transactionId: null }), transitioned: false };
}
function sha256Sync(bytes: Uint8Array): string {
  const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);
  const state = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const bitLength = bytes.length * 8;
  const paddedLength = ((bytes.length + 9 + 63) >> 6) << 6;
  const padded = new Uint8Array(paddedLength);
  padded.set(bytes); padded[bytes.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLength - 4, bitLength >>> 0);
  view.setUint32(paddedLength - 8, Math.floor(bitLength / 0x100000000) >>> 0);
  const w = new Uint32Array(64);
  const rotr = (value: number, bits: number) => (value >>> bits) | (value << (32 - bits));
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let i = 0; i < 64; i++) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const choice = (e & f) ^ (~e & g);
      const temp1 = (h + s1 + choice + K[i] + w[i]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + majority) >>> 0;
      h = g; g = f; f = e; e = (d + temp1) >>> 0;
      d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
    }
    state[0] = (state[0] + a) >>> 0; state[1] = (state[1] + b) >>> 0;
    state[2] = (state[2] + c) >>> 0; state[3] = (state[3] + d) >>> 0;
    state[4] = (state[4] + e) >>> 0; state[5] = (state[5] + f) >>> 0;
    state[6] = (state[6] + g) >>> 0; state[7] = (state[7] + h) >>> 0;
  }
  return [...state].map((word) => word.toString(16).padStart(8, "0")).join("");
}
