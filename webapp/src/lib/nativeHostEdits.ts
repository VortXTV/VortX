// Public host-register writer, not a nativeSync/kernel-clock writer. Wire contract:
// SourcesShared/VortxNativeHostPreferences.swift and VortxNativeWatchlist.swift.
import { projectNativeSync } from "./nativeSyncProjection";
import { authenticatedRosterHostValue } from "./nativeProfileEvents";
import { canonicalProfileID } from "./nativeProfileEditTypes";

export const HOST_MAX_CLOCK = Number.MAX_SAFE_INTEGER;
export interface HostTarget { scope: string; ownerProfileId: string; profileId: string; binding: string }
interface HostRegister { clock: number; actor: string; value: unknown }
export interface HostIntent {
  target: HostTarget; fields: Record<string, unknown>; global: boolean; actor: string;
  registers?: Record<string, HostRegister>; accepted?: boolean;
}
const object = (value: unknown): Record<string, any> | null => value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : null;
const fail = (): never => { throw new Error("This account edit needs a compatible profile and a fresh sync receipt; intent remains queued."); };
const actorOK = (actor: unknown): actor is string => typeof actor === "string" && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(actor);
const clockOK = (clock: unknown): clock is number => typeof clock === "number" && Number.isSafeInteger(clock) && clock >= 0;
const bytes = (value: string): number => new TextEncoder().encode(value).length;
function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  return "{" + Object.keys(value).sort().map((key) => JSON.stringify(key) + ":" + canonical((value as Record<string, unknown>)[key])).join(",") + "}";
}
export function hostSettingField(key: string): string | null {
  return ({ autoplayTrailers: "stremiox.autoplayTrailers", directLinksOnly: "stremiox.directLinksOnly", performance: "stremiox.performanceMode" } as Record<string, string>)[key] ?? null;
}
export function watchlistField(id: string, type: string): string {
  if (!["movie", "series"].includes(type) || !/^(?:tt|tmdb)[A-Za-z0-9:._-]*$/.test(id) || bytes(id) > 512) fail();
  return `watchlist.${type}.${btoa(id).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
}
export function watchlistValue(item: { id: string; type?: string; name?: string; poster?: string }, atSecs: number): Record<string, unknown> {
  const field = watchlistField(item.id, item.type ?? "");
  const value: Record<string, unknown> = { id: item.id, type: item.type, addedAt: atSecs };
  if (item.name !== undefined) value.name = item.name;
  if (item.poster !== undefined) value.poster = item.poster;
  validateWatchlist(field, value);
  return value;
}
function validateWatchlist(field: string, raw: unknown): void {
  const match = /^watchlist\.(movie|series)\.([A-Za-z0-9_-]+)$/.exec(field);
  if (!match) fail();
  let id: string;
  try { const token = match![2].replace(/-/g, "+").replace(/_/g, "/"); id = atob(token + "=".repeat((4 - token.length % 4) % 4)); } catch { fail(); }
  if (watchlistField(id!, match![1]) !== field) fail();
  if (raw === null) return;
  const value = object(raw) ?? fail();
  if (Object.keys(value).some((key) => !["id", "type", "name", "poster", "addedAt"].includes(key)) || value.id !== id! || value.type !== match![1] ||
    typeof value.addedAt !== "number" || !Number.isFinite(value.addedAt) || value.addedAt < 0 || value.addedAt > HOST_MAX_CLOCK ||
    (value.name != null && (typeof value.name !== "string" || bytes(value.name) > 4096)) ||
    (value.poster != null && (typeof value.poster !== "string" || bytes(value.poster) > 8192))) fail();
}
function validateEdit(field: string, value: unknown, global: boolean): void {
  if (!global && field === "playback") { validatePlaybackPatch(value); return; }
  if (!global) { validateWatchlist(field, value); return; }
  if (field === "stremiox.autoplayTrailers" || field === "stremiox.directLinksOnly") { if (typeof value !== "boolean") fail(); }
  else if (field === "stremiox.performanceMode") { if (!["auto", "full", "reduced"].includes(value as string)) fail(); }
  else fail(); // Author only the browser-supported slice; preserve other fetched fields opaquely.
}
// Author only controls actually modeled by the browser. Full registers preserve every fetched
// sibling, including future fields. Both public hosts decode this complete presentation DTO.
export function validatePlaybackPatch(raw: unknown): void {
  const value = object(raw) ?? fail();
  if (!Object.keys(value).length) fail();
  const strings = ["audioLang", "subtitleLang", "forcedPolicy", "subFont", "subColor", "subBackground", "safetyMode", "excludeKeywords", "includeKeywords"];
  const bools = ["useAddonOrder", "instantOnly", "hideDeadTorrents", "hdrOnly", "excludeAV1"];
  for (const [key, entry] of Object.entries(value)) {
    if (strings.includes(key)) { if (typeof entry !== "string" || bytes(entry) > 8192) fail(); }
    else if (bools.includes(key)) { if (typeof entry !== "boolean") fail(); }
    else if (key === "sourceTypeOrder") { if (!Array.isArray(entry) || new Set(entry).size !== entry.length || entry.some((v) => !["debrid", "torrent", "usenet", "direct"].includes(v))) fail(); }
    else if (key === "subSizeScale") { if (typeof entry !== "number" || !Number.isFinite(entry) || entry < 0.6 || entry > 1.8) fail(); }
    else if (key === "maxFileSizeGB") { if (typeof entry !== "number" || !Number.isFinite(entry) || entry < 0 || entry > 100000) fail(); }
    else if (key === "maxResolution") { if (![0, 720, 1080, 2160, 4000].includes(entry as number)) fail(); }
    else fail();
  }
}
function fullPlayback(doc: Record<string, unknown>, profileId: string, old: unknown, patch: unknown): Record<string, unknown> {
  const prior = old === undefined ? authenticatedRosterHostValue(doc, profileId, "playback") : register(old).value;
  const base = object(prior) ?? fail();
  const result = { ...base, ...(object(patch) ?? fail()) };
  validateFullPlayback(result);
  return result;
}
function validateFullPlayback(raw: unknown): void {
  const result = object(raw) ?? fail();
  for (const key of ["audioLang", "subtitleLang", "forcedPolicy", "subFont", "subSize", "subColor", "subBackground"]) {
    if (typeof result[key] !== "string") fail();
  }
  for (const key of ["subBrightness", "safetyMode", "excludeKeywords", "includeKeywords", "preferKeywords", "avoidBehavior"]) if (result[key] != null && typeof result[key] !== "string") fail();
  for (const key of ["useAddonOrder", "instantOnly", "hideDeadTorrents", "hdrOnly", "excludeAV1", "keywordsAreRegex", "hideUnknownResolution", "preferredAudioOnly", "autoPickBest"]) if (result[key] != null && typeof result[key] !== "boolean") fail();
  for (const key of ["subSizeScale", "maxFileSizeGB"]) if (result[key] != null && (typeof result[key] !== "number" || !Number.isFinite(result[key]))) fail();
  for (const key of ["maxResolution", "minResolution"]) if (result[key] != null && (typeof result[key] !== "number" || !Number.isInteger(result[key]) || result[key] < -2147483648 || result[key] > 2147483647)) fail();
  if (result.sourceTypeOrder != null && (!Array.isArray(result.sourceTypeOrder) || result.sourceTypeOrder.some((entry) => typeof entry !== "string"))) fail();
}
export function createHostIntent(target: HostTarget, fields: Record<string, unknown>, global: boolean, actor: string): HostIntent {
  if (!actorOK(actor) || !target.scope || !target.ownerProfileId || !target.profileId || typeof target.binding !== "string" || !Object.keys(fields).length) fail();
  for (const [field, value] of Object.entries(fields)) validateEdit(field, value, global);
  return { target: { ...target }, fields: JSON.parse(JSON.stringify(fields)), global, actor };
}
function compare(a: HostRegister, b: HostRegister): number { return a.clock - b.clock || (a.actor < b.actor ? -1 : a.actor > b.actor ? 1 : 0); }
function register(raw: unknown): HostRegister {
  const value = object(raw) ?? fail();
  if (Object.keys(value).length !== 3 || !["clock", "actor", "value"].every((key) => key in value) || !clockOK(value.clock) || !actorOK(value.actor)) fail();
  return value as HostRegister;
}

/** Plan once before PUT and persist that plan. An uncertain PUT must retry this exact causal
 * identity, never manufacture a newer edit that could overwrite a concurrent native choice. */
export function applyHostIntent(doc: Record<string, unknown>, intent: HostIntent, counter: number): { counter: number; alreadyApplied: boolean } {
  if (!clockOK(counter) || !actorOK(intent.actor)) fail();
  const view = projectNativeSync(doc, intent.target.scope) ?? fail();
  const profile = view.profiles.find((profile) => profile.id === intent.target.profileId) ?? fail();
  if (view.ownerProfileId !== intent.target.ownerProfileId || profile.binding !== intent.target.binding || profile.pending || profile.locked || profile.kids ||
    (intent.global && !profile.main)) fail();
  for (const [field, value] of Object.entries(intent.fields)) validateEdit(field, value, intent.global);
  const source = doc.nativeHostPreferences === undefined ? {
    schemaVersion: 1, scope: view.scope, ownerProfileId: view.ownerProfileId, profiles: {}, globals: { fields: {} },
  } : object(doc.nativeHostPreferences) ?? fail();
  if (Object.keys(source).length !== 5 || !["schemaVersion", "scope", "ownerProfileId", "profiles", "globals"].every((key) => key in source) ||
    source.schemaVersion !== 1 || source.scope !== view.scope || source.ownerProfileId !== view.ownerProfileId) fail();
  const profiles = object(source.profiles) ?? fail(), globals = object(source.globals) ?? fail();
  if (Object.keys(profiles).some((id) => !id)) fail();
  let maximum = counter;
  for (const { group, global } of [...Object.values(profiles).map((group) => ({ group, global: false })), { group: globals, global: true }]) {
    const wrapper = object(group) ?? fail(), fields = object(wrapper.fields) ?? fail();
    if (Object.keys(wrapper).length !== 1) fail();
    for (const [name, raw] of Object.entries(fields)) {
      const entry = register(raw); maximum = Math.max(maximum, entry.clock);
      if (!global && name.startsWith("watchlist.")) validateWatchlist(name, entry.value);
    }
  }
  const profileKeys = Object.keys(profiles).filter((key) => canonicalProfileID(key) === profile.id);
  if (profileKeys.length > 1) fail();
  const profileKey = profileKeys[0] ?? profile.id;
  const oldFields = intent.global ? globals.fields : object(profiles[profileKey])?.fields ?? {};
  const names = Object.keys(intent.fields).sort();
  if (intent.registers) {
    if (canonical(Object.keys(intent.registers).sort()) !== canonical(names)) fail();
    let witnessed = true;
    for (const name of names) {
      const planned = register(intent.registers[name]);
      if (planned.actor !== intent.actor) fail();
      if (name === "playback" && !intent.global) {
        validateFullPlayback(planned.value); // Validate frozen bytes, never repair/re-clock uncertain source.
        const value = object(planned.value) ?? fail();
        if (Object.entries(object(intent.fields[name]) ?? fail()).some(([key, patch]) => canonical(value[key]) !== canonical(patch))) fail();
      } else if (canonical(planned.value) !== canonical(intent.fields[name])) fail();
      maximum = Math.max(maximum, planned.clock);
      const old = oldFields[name] === undefined ? null : register(oldFields[name]);
      if (old && compare(old, planned) === 0 && canonical(old.value) !== canonical(planned.value)) fail();
      if (old && compare(old, planned) > 0 && !intent.accepted) fail(); // Ambiguous outcome: never silently re-clock.
      witnessed &&= !!old && (compare(old, planned) === 0 || (intent.accepted === true && compare(old, planned) > 0));
    }
    if (witnessed) return { counter: maximum, alreadyApplied: true };
    if (intent.accepted) fail(); // A confirmed stored edit cannot be absent from a valid newer receipt.
  }
  const candidate = JSON.parse(JSON.stringify(source));
  const fields = intent.global ? candidate.globals.fields : (candidate.profiles[profileKey] ??= { fields: {} }).fields;
  const planned = intent.registers ?? Object.fromEntries(names.map((name) => {
    if (maximum >= HOST_MAX_CLOCK) fail();
    return [name, { clock: ++maximum, actor: intent.actor, value: name === "playback" && !intent.global
      ? fullPlayback(doc, profile.id, oldFields[name], intent.fields[name]) : intent.fields[name] }];
  }));
  for (const name of names) {
    const old = fields[name] === undefined ? null : register(fields[name]);
    if (!old || compare(old, planned[name]) <= 0) fields[name] = planned[name];
  }
  if (!intent.global && Object.entries(fields).filter(([name, raw]) => name.startsWith("watchlist.") && register(raw).value !== null).length > 1000) fail();
  intent.registers = planned;
  doc.nativeHostPreferences = candidate;
  return { counter: maximum, alreadyApplied: false };
}
