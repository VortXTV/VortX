import { canonicalProfileID, type ProfileEdit } from "./nativeProfileEditTypes";

/** The additive, immutable dashboard profile-edit carrier understood by native v2 clients. */
export const PROFILE_EDIT_EVENTS_SCHEMA_VERSION = 2 as const;

export interface ProfileLibraryAddition {
  /** The profile that receives this one catalog item. */
  profileId: string;
  /** Public metadata only; this is intentionally not a watch/progress record. */
  item: Record<string, unknown>;
}

/** Wire shape required by the native WebsiteProfileEdits DTO. */
export type ProfileLibraryAdds = Record<string, Array<Record<string, unknown>>>;

/**
 * The native account-selection register captured by a website library intent.
 * `value` is present only for own/shared bindings; pending-own and local-only are
 * deliberately value-less native enum cases.
 */
export type ProfileAccountBinding =
  | { kind: "own"; value: string }
  | { kind: "shared"; value: string }
  | { kind: "pending_own" }
  | { kind: "local_only" };

export interface ProfileAccountBindingRevision {
  account: ProfileAccountBinding;
  revision: number;
  transactionId: string | null;
}

export type ProfileAccountBindings = Record<string, ProfileAccountBindingRevision>;

export interface ProfileEditEvent {
  eventId: string;
  editedAt: number;
  observedNativeClock: number;
  /** Lamport clock observed in the independent native host-preference carrier, when host fields change. */
  observedHostClock?: number;
  /** Exact host-preference register versions read before this event was authored. */
  hostBases?: HostPreferenceBases;
  roster: ProfileEdit[];
  libraryAdds: ProfileLibraryAdds;
  /** Authoring-time native account register for each profile receiving a new library item. */
  accountBindings?: ProfileAccountBindings;
  /** Ephemeral local receipt key; never serialized into the native event carrier. */
  fingerprint?: string;
}

export interface ProfileEditEventsEnvelope {
  schemaVersion: typeof PROFILE_EDIT_EVENTS_SCHEMA_VERSION;
  events: ProfileEditEvent[];
  [key: string]: unknown;
}

type JsonObject = Record<string, any>;

const HOST_PROFILE_FIELDS = new Set(["avatar", "playback"]);
// Rust's JSON-safe native ceiling is 9_007_199_254_740_990.  Host admission may
// mint one successor, so the observed host clock itself must stay strictly below
// the Swift host ceiling (Number.MAX_SAFE_INTEGER).
const WIRE_MAX_CLOCK = Number.MAX_SAFE_INTEGER - 1;
const HOST_MAX_CLOCK = Number.MAX_SAFE_INTEGER - 1;
const NATIVE_PROFILE_FIELDS = new Set(["name", "familyEdit", "pin", "deleted", "disabledAddons", "settings"]);
const NATIVE_SETTINGS_FIELDS = new Set(["accent", "oled", "textScale", "isKids", "avatar", "playback"]);
const SAFE_PLAYBACK_FIELDS = new Set([
  "audioLang", "subtitleLang", "forced", "subFont", "subSize", "subColor", "subBackground", "subSizeScale",
  "useAddonOrder", "sourceTypeOrder", "safetyMode", "instantOnly", "hideDeadTorrents", "hdrOnly", "excludeAV1",
  "keywordsAreRegex", "maxResolution", "maxFileSizeGB",
]);

export interface HostPreferenceRegisterBase {
  clock: number;
  actor: string;
  valueHash: string;
}

/**
 * A missing native host register still has a conditional-write base.  The hash is over the
 * authenticated, lossless roster value that native would project before applying a host register;
 * an omitted/unknown roster value is never replaced with a guessed default.
 */
export interface HostPreferenceExplicitAbsent {
  absent: true;
  valueHash: string;
}

export type HostPreferenceBase = HostPreferenceRegisterBase | HostPreferenceExplicitAbsent;

/**
 * Mirrors the native event contract: `hostBases[profileId][field]` identifies each top-level profile
 * register. Global preference registers are not authored by profile edits and therefore do not appear
 * in this carrier; `observedHostClock` still records the independent host Lamport ceiling.
 */
export type HostPreferenceBases = Record<string, Record<string, HostPreferenceBase>>;

export interface ProfileEditEventOptions {
  observedHostClock?: number;
  hostBases?: HostPreferenceBases;
  accountBindings?: ProfileAccountBindings;
  fingerprint?: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isObject(value: unknown): value is JsonObject {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function copyValue<T>(value: T): T {
  if (Array.isArray(value)) return value.map((entry) => copyValue(entry)) as T;
  if (isObject(value)) {
    const copy: JsonObject = {};
    for (const [key, child] of Object.entries(value)) {
      if (child !== undefined) Object.defineProperty(copy, key, { value: copyValue(child), enumerable: true, writable: true, configurable: true });
    }
    return copy as T;
  }
  return value;
}

const ACCOUNT_BINDING_KINDS = new Set(["own", "shared", "pending_own", "local_only"]);

function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}

function validAccountIdentity(value: unknown, maxBytes = 512): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.trim() === value
    && utf8ByteLength(value) <= maxBytes
    && !Array.from(value).some((character) => {
      const code = character.codePointAt(0) ?? 0;
      return code <= 0x1f || (code >= 0x7f && code <= 0x9f);
    });
}

/** Validate the exact serde shape used by native `AccountBindingRevision`. */
export function validateProfileAccountBindingRevision(
  value: unknown,
  path = "accountBindings",
): value is ProfileAccountBindingRevision {
  if (!isObject(value) || Object.keys(value).some((key) => !["account", "revision", "transactionId"].includes(key))) {
    throw new TypeError(`${path} must be an AccountBindingRevision.`);
  }
  const account = value.account;
  if (!isObject(account) || typeof account.kind !== "string" || !ACCOUNT_BINDING_KINDS.has(account.kind)) {
    throw new TypeError(`${path}.account has an unsupported binding kind.`);
  }
  const kind = account.kind;
  const accountKeys = Object.keys(account);
  if (kind === "own" || kind === "shared") {
    if (accountKeys.length !== 2 || !accountKeys.includes("value") || !validAccountIdentity(account.value, kind === "own" ? 256 : 512)) {
      throw new TypeError(`${path}.account.value is invalid.`);
    }
  } else if (accountKeys.length !== 1) {
    throw new TypeError(`${path}.account has an unexpected value.`);
  }
  if (!Number.isSafeInteger(value.revision) || value.revision < 0 || value.revision > Number.MAX_SAFE_INTEGER) {
    throw new TypeError(`${path}.revision is not a safe account revision.`);
  }
  if (value.transactionId !== null && !validAccountIdentity(value.transactionId, 128)) {
    throw new TypeError(`${path}.transactionId is invalid.`);
  }
  return true;
}

function accountBindingCopy(value: unknown, path: string): ProfileAccountBindingRevision {
  validateProfileAccountBindingRevision(value, path);
  return copyValue(value as ProfileAccountBindingRevision);
}

function nativeProfileRecords(doc: Record<string, any>): Record<string, any> | null {
  const native = isObject(doc?.nativeSync) ? doc.nativeSync : null;
  return isObject(native?.profiles)
    ? native.profiles
    : isObject(native?.roster) && isObject(native.roster.profiles)
      ? native.roster.profiles
      : null;
}

function nativeProfileRecord(doc: Record<string, any>, profileId: string): Record<string, any> | null {
  const records = nativeProfileRecords(doc);
  if (!records) return null;
  const key = Object.keys(records).find((candidate) => (canonicalProfileID(candidate) ?? candidate) === profileId);
  const raw = key ? records[key] : null;
  return isObject(raw) ? raw : null;
}

function nativeAccountSlot(doc: Record<string, any>, profileId: string): Record<string, any> | null {
  const native = isObject(doc?.nativeSync) ? doc.nativeSync : null;
  const slots = isObject(native?.accountSlots) ? native.accountSlots : null;
  if (!slots) return null;
  const key = Object.keys(slots).find((candidate) => (canonicalProfileID(candidate) ?? candidate) === profileId);
  const raw = key ? slots[key] : null;
  return isObject(raw) ? raw : null;
}

export interface NativeProfileAccountBindingState {
  /** Current active binding, or the schema-1/2/3 revision-0 profile account. */
  current: ProfileAccountBindingRevision | null;
  /** Whether native has retained account slots for this profile (schema 4 transition). */
  transitioned: boolean;
  /** Active plus retained receipt bindings accepted by native for delayed intents. */
  known: ProfileAccountBindingRevision[];
}

/**
 * Read native's authenticated authoring-time account register.  This is intentionally
 * fail-closed: no web aggregate/default account is a substitute for nativeSync evidence.
 */
export function nativeProfileAccountBindingState(
  doc: Record<string, any>,
  rawProfileId: string,
): NativeProfileAccountBindingState {
  if (!Object.prototype.hasOwnProperty.call(doc, "nativeSync")) {
    return { current: null, transitioned: false, known: [] };
  }
  const profileId = canonicalProfileID(rawProfileId) ?? rawProfileId;
  const rawRecord = nativeProfileRecord(doc, profileId);
  if (!rawRecord) {
    throw new TypeError(`Cannot read native account binding for ${profileId}: authenticated profile target unavailable.`);
  }
  const slot = nativeAccountSlot(doc, profileId);
  if (slot) {
    const active = accountBindingCopy(slot.activeBinding, `nativeSync.accountSlots[${profileId}].activeBinding`);
    const known = [active];
    const receipts = isObject(slot.receipts) ? slot.receipts : {};
    for (const [receiptID, rawReceipt] of Object.entries(receipts)) {
      if (!isObject(rawReceipt)) continue;
      for (const field of ["expectedBinding", "binding"]) {
        if (!Object.prototype.hasOwnProperty.call(rawReceipt, field)) continue;
        try {
          const candidate = accountBindingCopy(rawReceipt[field], `nativeSync.accountSlots[${profileId}].receipts.${receiptID}.${field}`);
          if (!known.some((existing) => canonicalJSON(existing) === canonicalJSON(candidate))) known.push(candidate);
        } catch {
          // A malformed retained receipt cannot authorize a website intent.  Keep the
          // active register usable for presentation, but do not expose the receipt.
        }
      }
    }
    return { current: active, transitioned: true, known };
  }

  const profile = isObject(rawRecord?.profile) ? rawRecord.profile : rawRecord;
  if (!isObject(profile) || !Object.prototype.hasOwnProperty.call(profile, "account")) {
    return { current: null, transitioned: false, known: [] };
  }
  const baseline: ProfileAccountBindingRevision = {
    account: profile.account as ProfileAccountBinding,
    revision: 0,
    transactionId: null,
  };
  validateProfileAccountBindingRevision(baseline, `nativeSync.profiles[${profileId}].profile.account`);
  return { current: baseline, transitioned: false, known: [baseline] };
}

/** Capture account evidence for exactly the new library additions in one website action. */
export function profileLibraryAccountBindings(
  doc: Record<string, any>,
  additions: ProfileLibraryAdds,
): ProfileAccountBindings | undefined {
  // Native is deliberately optional while the app's default sync mode remains
  // legacy.  A document with no nativeSync carrier can still author the older
  // profileEdits/libraryAdds channel; it has no authenticated account register
  // from which to manufacture accountBindings.  Presence of nativeSync, even if
  // malformed, is different: fail closed rather than silently downgrading.
  if (!Object.prototype.hasOwnProperty.call(doc, "nativeSync")) return undefined;
  const bindings: ProfileAccountBindings = {};
  for (const [rawProfileId, items] of Object.entries(additions)) {
    if (!Array.isArray(items) || items.length === 0) continue;
    const profileId = canonicalProfileID(rawProfileId) ?? rawProfileId;
    const state = nativeProfileAccountBindingState(doc, profileId);
    if (!state.current) {
      throw new TypeError(`Cannot author profile library intent for ${profileId}: native account binding unavailable.`);
    }
    bindings[profileId] = copyValue(state.current);
  }
  return bindings;
}

/**
 * JSON canonicalization shared by value hashes and event fingerprints.
 *
 * Swift's native writer uses JSONSerialization's sorted-key output with slash escaping disabled.  JS's
 * JSON.stringify already leaves slashes unescaped; sorting every object key recursively gives the same
 * public JSON byte sequence for the supported JSON DTO values.  Rejecting undefined/non-finite values is
 * intentional: hashing a value that native cannot decode would make a conditional write look safe.
 */
export function canonicalJSON(value: unknown): string {
  const normalize = (input: unknown): unknown => {
    if (input === null || typeof input === "string" || typeof input === "boolean") return input;
    if (typeof input === "number") {
      if (!Number.isFinite(input)) throw new TypeError("Canonical JSON cannot encode a non-finite number.");
      return Object.is(input, -0) ? 0 : input;
    }
    if (Array.isArray(input)) return input.map((entry) => normalize(entry));
    if (isObject(input)) {
      const object: JsonObject = {};
      for (const key of Object.keys(input).sort()) {
        if (input[key] === undefined) throw new TypeError("Canonical JSON cannot encode undefined.");
        Object.defineProperty(object, key, { value: normalize(input[key]), enumerable: true, writable: true, configurable: true });
      }
      return object;
    }
    throw new TypeError("Canonical JSON accepts only JSON-shaped values.");
  };
  return JSON.stringify(normalize(value));
}

/** Lowercase SHA-256 over UTF-8 canonical JSON, matching the native digest spelling. */
export async function canonicalJSONHash(value: unknown): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJSON(value)));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function randomUUIDFallback(): string {
  const bytes = new Uint8Array(16);
  globalThis.crypto.getRandomValues(bytes);
  // RFC 4122 version 4 / variant 1.  The browser's crypto.randomUUID is used
  // when available; this keeps the operation stable on older WebKit too.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Create once per user operation, before the CAS retry loop. */
export function newProfileEditEventID(): string {
  const randomUUID = globalThis.crypto?.randomUUID;
  return typeof randomUUID === "function" ? randomUUID.call(globalThis.crypto) : randomUUIDFallback();
}

function maxClock(value: unknown, current: number): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= WIRE_MAX_CLOCK
    ? Math.max(current, value) : current;
}

function membershipClock(group: unknown, current: number): number {
  if (!isObject(group)) return current;
  let maximum = maxClock(isObject(group.order) ? group.order.updatedAt : undefined, current);
  if (isObject(group.records)) {
    for (const record of Object.values(group.records)) {
      if (!isObject(record)) continue;
      for (const key of ["addedAt", "removedAt", "valueAt"]) maximum = maxClock(record[key], maximum);
    }
  }
  return maximum;
}

function watchClock(watch: unknown, current: number): number {
  if (!isObject(watch)) return current;
  let maximum = current;
  if (isObject(watch.log)) {
    for (const state of Object.values(watch.log)) {
      if (!isObject(state)) continue;
      // Public WatchState uses snake_case; retain the older mirror spellings as well.
      for (const key of ["resume_at", "watched_at", "reset_at", "removed_at", "resumeAt", "watchedAt", "resetAt", "removedAt"]) {
        maximum = maxClock(state[key], maximum);
      }
    }
  }
  if (isObject(watch.contexts)) {
    for (const context of Object.values(watch.contexts)) if (isObject(context)) maximum = maxClock(context.updatedAt, maximum);
  }
  return maximum;
}

/**
 * Read the authoring-time native logical watermark.  New native documents expose typed clocks in
 * `nativeSync`; the legacy roster watermark is an epoch-second fallback only when that carrier is
 * absent.  Do not use receipt time, updatedAt, or arbitrary profile setting numbers as causality.
 */
export function observedNativeProfileClock(doc: Record<string, any>): number {
  let maximum = 0;
  const native = isObject(doc?.nativeSync) ? doc.nativeSync : null;
  // Current NativeSyncDocument serializes profiles at the carrier root.  Keep the older
  // nested roster spelling readable while accounts transition between public mirrors.
  const profiles = isObject(native?.profiles)
    ? native.profiles
    : isObject(native?.roster?.profiles) ? native.roster.profiles : null;
  if (profiles) {
    for (const profile of Object.values(profiles)) {
      if (!isObject(profile)) continue;
      const fieldClocks = isObject(profile.fieldClocks) ? profile.fieldClocks : null;
      if (fieldClocks) for (const clock of Object.values(fieldClocks)) maximum = maxClock(clock, maximum);
    }
  }
  for (const groupName of ["addons", "libraries"]) {
    const groups = isObject(native?.[groupName]) ? native[groupName] : null;
    if (!groups) continue;
    for (const group of Object.values(groups)) maximum = membershipClock(group, maximum);
  }
  const watches = isObject(native?.watches) ? native.watches : null;
  if (watches) for (const watch of Object.values(watches)) maximum = watchClock(watch, maximum);
  const accountSlots = isObject(native?.accountSlots) ? native.accountSlots : null;
  if (accountSlots) {
    for (const account of Object.values(accountSlots)) {
      if (!isObject(account) || !isObject(account.slots)) continue;
      // Dormant slots are still observed causal state. Their binding revisions/source archives
      // are not clocks, and inspecting them must not change which account receives an intent.
      for (const slot of Object.values(account.slots)) {
        if (!isObject(slot)) continue;
        maximum = maxClock(slot.addonBindingClock, maximum);
        maximum = membershipClock(slot.addons, maximum);
        maximum = membershipClock(slot.library, maximum);
        maximum = watchClock(slot.watch, maximum);
      }
    }
  }
  const receipts = isObject(native?.legacyProfileEditReceipts) ? native.legacyProfileEditReceipts : null;
  if (receipts) {
    for (const receipt of Object.values(receipts)) {
      if (!isObject(receipt) || !isObject(receipt.source)) continue;
      maximum = maxClock(receipt.source.observedNativeClock, maximum);
    }
  }
  if (maximum > 0) return maximum;
  const value = doc?.vortx?.rosterModified;
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.min(Number.MAX_SAFE_INTEGER - 1, Math.floor(value)) : 0;
}

function validHostClock(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= HOST_MAX_CLOCK ? value : null;
}

function validHostActor(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value) && value === value.toLowerCase();
}

function hostDocument(doc: Record<string, any>): JsonObject | null {
  return isObject(doc?.nativeHostPreferences) ? doc.nativeHostPreferences : null;
}

function hostProfileKey(doc: Record<string, any>, profileId: string): string {
  const profiles = hostDocument(doc)?.profiles;
  if (isObject(profiles)) {
    const found = Object.keys(profiles).find((candidate) => canonicalProfileID(candidate) === profileId);
    if (found) return found;
  }
  // When the register is absent, use the exact canonical ProfileId spelling
  // carried by the roster/kernel (UUIDs are uppercase in this public DTO).  Do
  // not invent a lowercase host key merely because a native register is absent.
  return profileId;
}

function profileHostRegisters(doc: Record<string, any>, profileId: string): JsonObject | null {
  const profiles = hostDocument(doc)?.profiles;
  if (!isObject(profiles)) return null;
  const key = hostProfileKey(doc, profileId);
  const profile = profiles[key];
  if (profile === undefined) return null;
  if (!isObject(profile) || !isObject(profile.fields)) throw new TypeError(`Invalid native host profile at profiles.${key}.`);
  return profile.fields;
}

function hostRegister(doc: Record<string, any>, profileId: string, field: string): JsonObject | undefined {
  const registers = profileHostRegisters(doc, profileId);
  if (!registers || registers[field] === undefined) return undefined;
  if (!isObject(registers[field])) throw new TypeError(`Invalid native host register at profiles.${hostProfileKey(doc, profileId)}.fields.${field}.`);
  return registers[field];
}

function assertHostRegister(register: JsonObject, path: string): { clock: number; actor: string; value: unknown } {
  const clock = validHostClock(register.clock);
  if (clock === null || !validHostActor(register.actor) || !Object.prototype.hasOwnProperty.call(register, "value")) {
    throw new TypeError(`Invalid native host register at ${path}.`);
  }
  return { clock, actor: register.actor, value: register.value };
}

function hasOwn(value: JsonObject, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}

/**
 * Resolve the exact legacy value used as the native host baseline.  `vortx.profiles` is a lossy
 * dashboard summary (and intentionally strips playback during native roster resolution), so it is
 * not a safe source for an absent-register conditional write.  A missing or malformed full row is
 * an actionable conflict rather than permission to synthesize a popcorn/empty preference value.
 */
export function authenticatedRosterHostValue(doc: Record<string, any>, profileId: string, field: string): unknown {
  const rows = doc?.vortx?.roster;
  const row = Array.isArray(rows)
    ? rows.find((candidate) => isObject(candidate) && canonicalProfileID(candidate.id) === profileId)
    : undefined;
  if (!isObject(row)) {
    throw new TypeError(`Cannot author native host base for ${profileId}.${field}: authenticated full roster baseline unavailable.`);
  }

  if (field === "avatar") {
    if (!hasOwn(row, field) || typeof row[field] !== "string" || !row[field]) {
      throw new TypeError(`Cannot author native host base for ${profileId}.${field}: authenticated roster value unavailable.`);
    }
    return copyValue(row[field]);
  }

  // Codable optional fields decode a missing key as nil.  That nil is an authenticated baseline
  // value; it is different from inventing a default object and is represented canonically as null.
  const value = hasOwn(row, field) ? row[field] : null;
  if (value === undefined) {
    throw new TypeError(`Cannot author native host base for ${profileId}.${field}: authenticated roster value is invalid.`);
  }
  if (value !== null && ["email"].includes(field) && typeof value !== "string") {
    throw new TypeError(`Cannot author native host base for ${profileId}.${field}: authenticated roster value is invalid.`);
  }
  if (value !== null && ["playback", "discovery", "addonPreferences"].includes(field) && !isObject(value)) {
    throw new TypeError(`Cannot author native host base for ${profileId}.${field}: authenticated roster value is invalid.`);
  }
  return copyValue(value);
}

function emptyHostPreferenceBases(): HostPreferenceBases {
  return {};
}

function hostPreferenceRegisterEntries(doc: Record<string, any>): JsonObject[] {
  const host = hostDocument(doc);
  if (!host) return [];
  const result: JsonObject[] = [];
  const collect = (groups: unknown) => {
    if (!isObject(groups)) return;
    for (const group of Object.values(groups)) {
      if (!isObject(group) || !isObject(group.fields)) continue;
      for (const register of Object.values(group.fields)) if (isObject(register)) result.push(register);
    }
  };
  collect(host.profiles);
  if (isObject(host.globals) && isObject(host.globals.fields)) {
    for (const register of Object.values(host.globals.fields)) if (isObject(register)) result.push(register);
  }
  return result;
}

/** The maximum accepted host Lamport clock present in the fresh CAS document. */
export function observedHostPreferenceClock(doc: Record<string, any>): number {
  let maximum = 0;
  for (const register of hostPreferenceRegisterEntries(doc)) {
    const clock = validHostClock(register.clock);
    if (clock !== null) maximum = Math.max(maximum, clock);
  }
  return maximum;
}

function settingsObject(patch: ProfileEdit): JsonObject | null {
  return isObject(patch?.settings) ? patch.settings : null;
}

function hostFieldNames(patch: ProfileEdit): string[] {
  const settings = settingsObject(patch);
  if (!settings) return [];
  return Object.keys(settings)
    .filter((field) => HOST_PROFILE_FIELDS.has(field) && settings[field] !== undefined)
    .sort();
}

/**
 * Keep the native carrier within the reviewed WebsiteProfileEdits whitelist.  The legacy aggregate
 * still receives the caller's complete patch, so dashboard-only preferences remain recoverable for
 * old clients and in the sealed source while unknown native fields never poison a v2 event.
 */
export function nativeProfileEditPatch(patch: ProfileEdit): ProfileEdit {
  const source = sparseProfileEdit(patch) as JsonObject;
  const output: JsonObject = { id: source.id };
  for (const field of NATIVE_PROFILE_FIELDS) {
    if (field === "settings") continue;
    if (Object.prototype.hasOwnProperty.call(source, field)) output[field] = copyValue(source[field]);
  }
  const sourceSettings = isObject(source.settings) ? source.settings : null;
  if (sourceSettings) {
    const settings: JsonObject = {};
    for (const field of NATIVE_SETTINGS_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(sourceSettings, field)) continue;
      const value = sourceSettings[field];
      if (field !== "playback") {
        settings[field] = copyValue(value);
        continue;
      }
      if (!isObject(value)) {
        // Preserve malformed/null known fields so native can return its structured conflict rather
        // than silently claiming that a user action was applied.
        settings[field] = copyValue(value);
        continue;
      }
      const playback: JsonObject = {};
      for (const key of Object.keys(value)) {
        if (SAFE_PLAYBACK_FIELDS.has(key)) playback[key] = copyValue(value[key]);
      }
      if (Object.keys(playback).length) settings.playback = playback;
    }
    if (Object.keys(settings).length) output.settings = settings;
  }
  return output as ProfileEdit;
}

function validatePlaybackPatch(doc: Record<string, any>, patch: ProfileEdit): void {
  const settings = settingsObject(patch);
  if (!settings || !Object.prototype.hasOwnProperty.call(settings, "playback") || settings.playback === undefined) return;
  const incoming = settings.playback;
  if (!isObject(incoming)) return;
  const profileId = canonicalProfileID(patch.id) ?? String(patch.id);
  const register = hostRegister(doc, profileId, "playback");
  const prior = register === undefined
    ? authenticatedRosterHostValue(doc, profileId, "playback")
    : assertHostRegister(register, `profiles.${hostProfileKey(doc, profileId)}.fields.playback`).value;
  if (prior !== null && !isObject(prior)) {
    throw new TypeError(`Cannot validate native host playback for ${profileId}: baseline value is invalid.`);
  }
  // Validate that a native full-register merge can be formed, but do not put the inherited sibling
  // fields into the immutable event.  They remain owned by the authenticated baseline/register.
  canonicalJSON({ ...(isObject(prior) ? copyValue(prior) : {}), ...copyValue(incoming) });
}

/**
 * Build event-side host evidence from the fresh CAS document.  Every roster patch remains sparse;
 * playback's full-register merge is validation only, while hostBases carries the exact CAS base.
 */
export async function profileEditHostEvidence(
  doc: Record<string, any>,
  patch: ProfileEdit,
): Promise<{ eventPatch: ProfileEdit; observedHostClock: number; hostBases: HostPreferenceBases }> {
  const eventPatch = nativeProfileEditPatch(patch);
  validatePlaybackPatch(doc, eventPatch);
  const profileId = canonicalProfileID(eventPatch.id) ?? String(eventPatch.id);
  const key = hostProfileKey(doc, profileId);
  const fields = hostFieldNames(eventPatch);
  const bases = emptyHostPreferenceBases();
  if (fields.length) bases[key] = {};
  for (const field of fields) {
    const register = hostRegister(doc, profileId, field);
    if (register === undefined) {
      bases[key][field] = {
        absent: true,
        valueHash: await canonicalJSONHash(authenticatedRosterHostValue(doc, profileId, field)),
      };
      continue;
    }
    const current = assertHostRegister(register, `profiles.${key}.fields.${field}`);
    bases[key][field] = {
      clock: current.clock,
      actor: current.actor,
      valueHash: await canonicalJSONHash(current.value),
    };
  }
  return { eventPatch, observedHostClock: observedHostPreferenceClock(doc), hostBases: bases };
}

/** Keep a single action's sparse fields; never copy the merged pending roster into an event. */
export function sparseProfileEdit(patch: ProfileEdit): ProfileEdit {
  if (!isObject(patch)) throw new TypeError("A profile edit event requires an object patch.");
  const id = canonicalProfileID(patch.id);
  if (!id) throw new TypeError("A profile edit event target requires a non-empty id.");
  const result: JsonObject = { id };
  for (const [key, value] of Object.entries(patch)) {
    if (key === "id" || value === undefined) continue;
    result[key] = copyValue(value);
  }
  return result as ProfileEdit;
}

/** Flatten only this action's additions into the profile-keyed native wire map. */
function nativeLibraryItem(rawItem: JsonObject): JsonObject {
  const item: JsonObject = {};
  for (const field of ["id", "type", "name", "poster"]) {
    if (Object.prototype.hasOwnProperty.call(rawItem, field)) item[field] = copyValue(rawItem[field]);
  }
  return item;
}

export function profileLibraryAdditions(libraryAdds?: Record<string, any[]>): ProfileLibraryAdds {
  if (!isObject(libraryAdds)) return {};
  const additions: ProfileLibraryAdds = {};
  for (const [rawProfileID, rawItems] of Object.entries(libraryAdds)) {
    const profileId = canonicalProfileID(rawProfileID) ?? rawProfileID;
    if (!Array.isArray(rawItems)) continue;
    for (const rawItem of rawItems) {
      if (!isObject(rawItem)) continue;
      // The dashboard aggregate may retain richer imported metadata, but the native
      // intent DTO is deliberately only a saved-membership descriptor.  In particular,
      // never manufacture or replay watch/progress/CW fields from a library save.
      (additions[profileId] ??= []).push(nativeLibraryItem(rawItem));
    }
  }
  return additions;
}

export function oneProfileLibraryAddition(profileId: string, item: Record<string, unknown>): ProfileLibraryAddition {
  return {
    profileId: canonicalProfileID(profileId) ?? profileId,
    item: copyValue(item),
  };
}

function normalizedAccountBindings(raw: ProfileAccountBindings, libraryAdds: ProfileLibraryAdds): ProfileAccountBindings {
  if (!isObject(raw)) throw new TypeError("A profile edit accountBindings map must be an object.");
  const normalized: ProfileAccountBindings = {};
  for (const [rawProfileId, value] of Object.entries(raw)) {
    const profileId = canonicalProfileID(rawProfileId) ?? rawProfileId;
    if (!validAccountIdentity(profileId)) throw new TypeError(`Invalid accountBindings profile identity: ${rawProfileId}.`);
    if (Object.prototype.hasOwnProperty.call(normalized, profileId)) {
      throw new TypeError(`Duplicate accountBindings profile identity: ${profileId}.`);
    }
    normalized[profileId] = accountBindingCopy(value, `accountBindings[${profileId}]`);
  }
  const required = new Set(Object.entries(libraryAdds)
    .filter(([, items]) => Array.isArray(items) && items.length > 0)
    .map(([profileId]) => canonicalProfileID(profileId) ?? profileId));
  for (const profileId of required) {
    if (!Object.prototype.hasOwnProperty.call(normalized, profileId)) {
      throw new TypeError(`accountBindings.${profileId} is required for libraryAdds.`);
    }
  }
  for (const profileId of Object.keys(normalized)) {
    if (!required.has(profileId)) throw new TypeError(`accountBindings.${profileId} has no libraryAdds target.`);
  }
  return normalized;
}

export function makeProfileEditEvent(
  eventId: string,
  editedAt: number,
  observedNativeClock: number,
  roster: ProfileEdit[],
  libraryAdds: ProfileLibraryAdds | ProfileLibraryAddition[],
  options: ProfileEditEventOptions = {},
): ProfileEditEvent {
  if (typeof eventId !== "string" || !eventId.trim()) throw new TypeError("A profile edit event requires a non-empty eventId.");
  if (typeof editedAt !== "number" || !Number.isFinite(editedAt) || editedAt <= 0 || editedAt > WIRE_MAX_CLOCK) {
    throw new TypeError("A profile edit event requires a positive finite epoch-ms editedAt.");
  }
  if (!Number.isSafeInteger(observedNativeClock) || observedNativeClock < 0 || observedNativeClock >= WIRE_MAX_CLOCK) {
    throw new TypeError("A profile edit event requires a safe native clock.");
  }
  if (editedAt <= observedNativeClock * 1000) {
    throw new TypeError("A profile edit event timestamp must follow its authoring-time native watermark.");
  }
  const hostBases = options.hostBases ? copyValue(options.hostBases) : emptyHostPreferenceBases();
  const hasHostBases = Object.keys(hostBases).some((profile) => Object.keys(hostBases[profile] ?? {}).length > 0);
  const observedHostClock = options.observedHostClock;
  if (hasHostBases) {
    if (typeof observedHostClock !== "number" || !Number.isSafeInteger(observedHostClock) || observedHostClock < 0 || observedHostClock >= HOST_MAX_CLOCK) {
      throw new TypeError("A host preference event requires a safe authoring Lamport clock.");
    }
    if (!UUID_PATTERN.test(eventId) || eventId !== eventId.toLowerCase()) {
      throw new TypeError("A host preference event requires a canonical lowercase UUID eventId.");
    }
    for (const [profileId, fields] of Object.entries(hostBases)) {
      if (!isObject(fields)) throw new TypeError(`Invalid host base map for ${profileId}.`);
      for (const [field, rawBase] of Object.entries(fields)) {
        if (!HOST_PROFILE_FIELDS.has(field) || !isObject(rawBase)) throw new TypeError(`Invalid host base for ${profileId}.${field}.`);
        const valueHash = rawBase.valueHash;
        if (typeof valueHash !== "string" || !/^[0-9a-f]{64}$/.test(valueHash)) {
          throw new TypeError(`Invalid host base hash for ${profileId}.${field}.`);
        }
        const absent = "absent" in rawBase && rawBase.absent === true;
        const hasRegister = Object.prototype.hasOwnProperty.call(rawBase, "clock")
          || Object.prototype.hasOwnProperty.call(rawBase, "actor");
        if (absent) {
          if (hasRegister) throw new TypeError(`Absent host base cannot carry a register for ${profileId}.${field}.`);
        } else {
          if (Object.prototype.hasOwnProperty.call(rawBase, "absent")) {
            throw new TypeError(`Present host base cannot carry an absent marker for ${profileId}.${field}.`);
          }
          const clock = validHostClock("clock" in rawBase ? rawBase.clock : undefined);
          if (clock === null || clock > observedHostClock! || !validHostActor("actor" in rawBase ? rawBase.actor : undefined)) {
            throw new TypeError(`Host base clock or actor is invalid for ${profileId}.${field}.`);
          }
        }
      }
    }
  }
  const event: ProfileEditEvent = {
    eventId: UUID_PATTERN.test(eventId) ? eventId.toLowerCase() : eventId,
    editedAt,
    observedNativeClock,
    roster: roster == null ? [] : Array.isArray(roster) ? roster.map(sparseProfileEdit) : (() => {
      throw new TypeError("A profile edit event roster must be an array when supplied.");
    })(),
    libraryAdds: Array.isArray(libraryAdds)
      ? libraryAdds.reduce<ProfileLibraryAdds>((map, addition) => {
        if (!isObject(addition) || typeof addition.profileId !== "string" || !isObject(addition.item)) return map;
        const profileId = canonicalProfileID(addition.profileId) ?? addition.profileId;
        (map[profileId] ??= []).push(nativeLibraryItem(addition.item));
        return map;
      }, {})
      : profileLibraryAdditions(libraryAdds as ProfileLibraryAdds),
  };
  if (options.accountBindings !== undefined) {
    const accountBindings = normalizedAccountBindings(options.accountBindings, event.libraryAdds);
    if (Object.keys(accountBindings).length) event.accountBindings = accountBindings;
  }
  if (hasHostBases) { event.observedHostClock = observedHostClock; event.hostBases = hostBases; }
  if (options.fingerprint) event.fingerprint = options.fingerprint;
  return event;
}

export interface ProfileEditFingerprintContext {
  scope: string;
  ownerProfileId: string;
}

function fingerprintBody(event: ProfileEditEvent, context?: ProfileEditFingerprintContext): JsonObject {
  const body = copyValue(event) as JsonObject;
  delete body.fingerprint;
  if (!context) return body;
  return { scope: context.scope, ownerProfileId: context.ownerProfileId, profileEdits: body };
}

/** Fingerprint the exact native source tuple, excluding the ephemeral local receipt key. */
export async function profileEditEventFingerprint(event: ProfileEditEvent, context?: ProfileEditFingerprintContext): Promise<string> {
  return canonicalJSONHash(fingerprintBody(event, context));
}

/** Add the exact receipt key after host evidence and all event fields are finalized. */
export async function finalizeProfileEditEvent(event: ProfileEditEvent, context?: ProfileEditFingerprintContext): Promise<ProfileEditEvent> {
  return { ...event, fingerprint: await profileEditEventFingerprint(event, context) };
}

// Dashboard projection and CAS pruning are synchronous callers. Keep a small standards-compliant
// SHA-256 implementation beside the async WebCrypto path so receipt matching remains exact without
// turning every view-model render into an async operation.
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

export function profileEditEventFingerprintSync(event: ProfileEditEvent, context?: ProfileEditFingerprintContext): string {
  return sha256Sync(new TextEncoder().encode(canonicalJSON(fingerprintBody(event, context))));
}

/** Shared public digest for read-only account-slot lookup and versioned website carriers. */
// RFC 8785/JCS for the new add-on protocol. Serialize sorted keys explicitly: rebuilding an
// object and calling JSON.stringify would reorder numeric-looking keys, changing its digest.
export function canonicalJCS(value: unknown): string {
  if (typeof value === "string") {
    for (let index = 0; index < value.length; index++) {
      const unit = value.charCodeAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const low = value.charCodeAt(++index);
        if (!(low >= 0xdc00 && low <= 0xdfff)) throw new TypeError("Canonical JSON cannot encode invalid Unicode.");
      } else if (unit >= 0xdc00 && unit <= 0xdfff) throw new TypeError("Canonical JSON cannot encode invalid Unicode.");
    }
    return JSON.stringify(value);
  }
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonicalJCS).join(",") + "]";
  if (isObject(value)) return "{" + Object.keys(value).sort().map((key) => canonicalJCS(key) + ":" + canonicalJCS(value[key])).join(",") + "}";
  throw new TypeError("Canonical JSON accepts only finite JSON-shaped values.");
}

export function canonicalJSONHashSync(value: unknown, domain = ""): string {
  return sha256Sync(new TextEncoder().encode(domain + (domain ? canonicalJCS(value) : canonicalJSON(value))));
}

/** Resolve the authenticated scope/owner tuple used by native fingerprinting. */
export function profileEditEventFingerprintContext(doc: Record<string, any>, fallbackScope?: string): ProfileEditFingerprintContext | null {
  const native = isObject(doc?.nativeSync) ? doc.nativeSync : null;
  const scope = typeof native?.scope === "string" && native.scope.trim() ? native.scope : fallbackScope;
  let ownerProfileId = typeof native?.ownerProfileId === "string" && native.ownerProfileId.trim() ? native.ownerProfileId : null;
  if (!ownerProfileId) {
    const rows = Array.isArray(doc?.vortx?.roster) ? doc.vortx.roster : [];
    ownerProfileId = rows.find((row: any) => isObject(row) && (row.owner === true || row.isOwner === true || row.main === true))?.id ?? null;
  }
  if (!ownerProfileId) {
    const rows = Array.isArray(doc?.vortx?.profiles) ? doc.vortx.profiles : [];
    ownerProfileId = rows.find((row: any) => isObject(row) && row.main === true)?.id ?? null;
  }
  if (!ownerProfileId) {
    const records = isObject(native?.profiles)
      ? native.profiles
      : isObject(native?.roster?.profiles) ? native.roster.profiles : null;
    if (records) {
      for (const [rawID, rawRecord] of Object.entries(records)) {
        const profile = isObject(rawRecord) && isObject(rawRecord.profile) ? rawRecord.profile : rawRecord;
        if (isObject(profile) && (profile.owner === true || profile.isOwner === true || profile.main === true)) {
          ownerProfileId = typeof profile.id === "string" && profile.id.trim() ? profile.id : rawID;
          break;
        }
      }
    }
  }
  if (typeof scope !== "string" || !scope.trim() || typeof ownerProfileId !== "string" || !ownerProfileId.trim()) return null;
  return { scope, ownerProfileId };
}

export interface ProfileEditEventReceipt {
  eventId: string;
  fingerprint: string;
}

/** Read only the authenticated native receipt map named by the conformance contract. */
export function profileEditEventReceiptsFromSyncDoc(doc: Record<string, any>): ProfileEditEventReceipt[] {
  const native = isObject(doc?.nativeSync) ? doc.nativeSync : null;
  const map = isObject(native?.legacyProfileEditReceipts) ? native.legacyProfileEditReceipts : null;
  if (!map) return [];
  const receipts: ProfileEditEventReceipt[] = [];
  for (const [fingerprint, raw] of Object.entries(map)) {
    if (!/^[0-9a-f]{64}$/.test(fingerprint) || !isObject(raw) || raw.schemaVersion !== 1 || typeof raw.eventId !== "string") continue;
    const source = isObject(raw.source) ? raw.source : null;
    if (!source || source.fingerprint !== fingerprint) continue;
    receipts.push({ eventId: raw.eventId, fingerprint });
  }
  return receipts;
}

/**
 * Remove only events named by an exact `(eventId, fingerprint)` receipt.  There is deliberately no
 * timestamp fallback: a durable native acknowledgement for one retry must never clear a newer event.
 */
export function pruneAcknowledgedProfileEditEvents(
  doc: Record<string, any>,
  receipts: readonly ProfileEditEventReceipt[],
  context?: ProfileEditFingerprintContext | null,
): number {
  const envelope = isObject(doc.profileEditEvents) && Array.isArray(doc.profileEditEvents.events) ? doc.profileEditEvents : null;
  if (!envelope || !receipts.length) return 0;
  const acknowledged = new Set(receipts.filter((receipt) => (
    isObject(receipt) && typeof receipt.eventId === "string" && typeof receipt.fingerprint === "string"
  )).map((receipt) => `${receipt.eventId}\u0000${receipt.fingerprint}`));
  const prior = envelope.events as unknown[];
  const remaining = prior.filter((candidate) => {
    if (!isObject(candidate) || typeof candidate.eventId !== "string") return true;
    // A wire event's optional fingerprint is not authenticated source data.  Recompute it from
    // the bound native scope/owner, and fail closed when that binding is unavailable.
    const fingerprint = context ? profileEditEventFingerprintSync(candidate as ProfileEditEvent, context) : null;
    return !fingerprint || !acknowledged.has(`${candidate.eventId}\u0000${fingerprint}`);
  });
  const removed = prior.length - remaining.length;
  if (removed) doc.profileEditEvents = { ...envelope, events: remaining };
  return removed;
}

/**
 * Append without rewriting existing events.  Unknown envelope siblings survive.  A malformed or
 * foreign-version carrier is left untouched so an old client never loses opaque account data.  The
 * production writers use appendProfileEditEventOrThrow so they cannot publish a legacy-only action.
 */
export function appendProfileEditEvent(doc: Record<string, any>, event: ProfileEditEvent): boolean {
  const current = isObject(doc.profileEditEvents) ? doc.profileEditEvents : null;
  if (current && current.schemaVersion !== undefined && current.schemaVersion !== PROFILE_EDIT_EVENTS_SCHEMA_VERSION) return false;
  if (current && current.events !== undefined && !Array.isArray(current.events)) return false;
  const prior = current && Array.isArray(current.events) ? current.events : [];
  if (prior.some((candidate) => isObject(candidate) && candidate.eventId === event.eventId)) return false;
  const wireEvent = copyValue(event) as JsonObject;
  delete wireEvent.fingerprint;
  doc.profileEditEvents = {
    ...(current ?? {}),
    schemaVersion: PROFILE_EDIT_EVENTS_SCHEMA_VERSION,
    events: [...prior, wireEvent],
  } satisfies ProfileEditEventsEnvelope;
  return true;
}

/** Production writers must not fall back to legacy-only success when the v2 carrier is foreign. */
export function appendProfileEditEventOrThrow(doc: Record<string, any>, event: ProfileEditEvent): void {
  if (!appendProfileEditEvent(doc, event)) {
    throw new Error("Could not save profile edit: the native profile event carrier is incompatible.");
  }
}
