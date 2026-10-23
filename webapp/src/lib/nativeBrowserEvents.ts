// Public website-event producers. No nativeSync/kernel registers are authored here.
import { projectNativeSync, isNativeAddonManifest } from "./nativeSyncProjection";
import type { HostTarget } from "./nativeHostEdits";
import { canonicalProfileID } from "./nativeProfileEditTypes";
import { appendProfileEditEventOrThrow, canonicalJSON, canonicalJSONHashSync, finalizeProfileEditEvent,
  makeProfileEditEvent, newProfileEditEventID, observedNativeProfileClock, profileEditEventFingerprintContext,
  profileEditEventReceiptsFromSyncDoc, profileEditHostEvidence, type ProfileEditEvent,
  validateProfileAccountBindingRevision, pruneAcknowledgedProfileEditEvents } from "./nativeProfileEvents";

const obj = (value: unknown): Record<string, any> | null => value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : null;
const fail = (): never => { throw new Error("Waiting for a compatible native edit receipt; intent remains queued."); };
const clone = <T>(value: T): T => JSON.parse(canonicalJSON(value));
const same = (a: unknown, b: unknown): boolean => canonicalJSON(a) === canonicalJSON(b);
export interface ProfileIntent { target: HostTarget; settings: Record<string, any>; event?: ProfileEditEvent }
export function createProfileIntent(target: HostTarget, settings: Record<string, any>): ProfileIntent {
  if (!Object.keys(settings).length || Object.keys(settings).some((key) => !["accent", "oled", "textScale", "playback"].includes(key))) fail();
  if (settings.accent !== undefined && typeof settings.accent !== "string") fail();
  if (settings.oled !== undefined && typeof settings.oled !== "boolean") fail();
  if (settings.textScale !== undefined && (typeof settings.textScale !== "number" || !Number.isFinite(settings.textScale) || settings.textScale <= 0 || settings.textScale > 3)) fail();
  if (settings.playback !== undefined) {
    const playback = obj(settings.playback) ?? fail();
    if (!Object.keys(playback).length) fail();
    for (const [key, value] of Object.entries(playback)) {
      if (!(["audioLang", "subtitleLang", "forced"].includes(key)) || typeof value !== "string") fail();
    }
  }
  return { target: { ...target }, settings: clone(settings) };
}
function targetProfile(doc: Record<string, any>, target: HostTarget) {
  const view = projectNativeSync(doc, target.scope) ?? fail();
  const profile = view.profiles.find((row) => row.id === target.profileId) ?? fail();
  if (view.ownerProfileId !== target.ownerProfileId || profile.binding !== target.binding || profile.pending || profile.locked || profile.kids) fail();
  return { view, profile };
}
function profileFingerprint(doc: Record<string, any>, event: ProfileEditEvent): string {
  const context = profileEditEventFingerprintContext(doc) ?? fail();
  // finalize's local hash is not wire authority; hash the immutable source again under this scope.
  return canonicalJSONHashSync({ scope: context.scope, ownerProfileId: context.ownerProfileId,
    profileEdits: Object.fromEntries(Object.entries(event).filter(([key]) => key !== "fingerprint")) });
}
function validateProfilePlan(intent: ProfileIntent): void {
  const event = intent.event;
  if (!event) return;
  const row = Array.isArray(event.roster) && event.roster.length === 1 ? obj(event.roster[0]) : null;
  if (typeof event.eventId !== "string" || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(event.eventId) || !row
    || Object.keys(row).length !== 2 || !Object.keys(row).every((key) => ["id", "settings"].includes(key))
    || !Number.isSafeInteger(event.editedAt) || !obj(event.libraryAdds)
    || event.roster[0].id !== intent.target.profileId || !same(event.roster[0].settings, intent.settings)
    || Object.keys(event.libraryAdds ?? {}).length || Object.keys(event).some((key) => !["eventId", "editedAt", "observedNativeClock", "roster", "libraryAdds", "observedHostClock", "hostBases", "fingerprint"].includes(key))) fail();
  const bases = obj(event.hostBases), playback = intent.settings.playback !== undefined;
  if (playback) {
    const profileKeys = bases ? Object.keys(bases).filter((key) => canonicalProfileID(key) === intent.target.profileId) : [];
    const fields = bases && profileKeys.length === 1 && obj(bases[profileKeys[0]]), base = fields && obj(fields.playback);
    if (!bases || profileKeys.length !== 1 || profileKeys[0] !== intent.target.profileId || Object.keys(bases).length !== 1 || !fields || Object.keys(fields).length !== 1 || !base
      || !same(Object.keys(base).sort(), (base.absent === true ? ["absent", "valueHash"] : ["actor", "clock", "valueHash"]).sort())) fail();
  } else if (event.hostBases !== undefined || event.observedHostClock !== undefined) fail();
  const normalized = makeProfileEditEvent(event.eventId, event.editedAt, event.observedNativeClock, event.roster, {}, {
    observedHostClock: event.observedHostClock, hostBases: event.hostBases });
  if (!same(normalized, Object.fromEntries(Object.entries(event).filter(([key]) => key !== "fingerprint")))) fail();
}
export function profileIntentAcknowledged(doc: Record<string, any>, intent: ProfileIntent): boolean {
  targetProfile(doc, intent.target);
  validateProfilePlan(intent);
  if (!intent.event) return false;
  const fingerprint = profileFingerprint(doc, intent.event);
  const raw = doc.nativeSync?.legacyProfileEditReceipts?.[fingerprint];
  return profileEditEventReceiptsFromSyncDoc(doc).some((receipt) => receipt.eventId === intent.event!.eventId && receipt.fingerprint === fingerprint)
    && raw?.source?.editedAtMs === intent.event.editedAt && raw?.source?.observedNativeClock === intent.event.observedNativeClock;
}
/** Build once from the authenticated CAS head, then retry exactly those source bytes. Native's
 * host/native transaction owns stale-base conflict resolution; never re-clock an uncertain edit. */
export async function applyProfileIntent(doc: Record<string, any>, intent: ProfileIntent): Promise<boolean> {
  targetProfile(doc, intent.target);
  if (profileIntentAcknowledged(doc, intent)) return false;
  if (!intent.event) {
    const observed = observedNativeProfileClock(doc), ceiling = Number.MAX_SAFE_INTEGER - 1;
    if (observed > Math.floor((ceiling - 1) / 1000)) fail();
    const priorTime = (Array.isArray(doc.profileEditEvents?.events) ? doc.profileEditEvents.events : []).reduce((maximum: number, event: any) =>
      Number.isSafeInteger(event?.editedAt) ? Math.max(maximum, event.editedAt) : fail(), 0);
    const editedAt = Math.max(Date.now(), observed * 1000 + 1, priorTime + 1, Number(doc.profileEdits?.editedAt) + 1 || 0, Number(doc.vortx?.updatedAt) + 1 || 0);
    if (!Number.isSafeInteger(editedAt) || editedAt > ceiling) fail();
    const evidence = await profileEditHostEvidence(doc, { id: intent.target.profileId, settings: intent.settings });
    // Public native admission indexes returned host-patch IDs exactly. A fetched case alias is
    // preserved by host-register transport but cannot authorize this paired sparse event.
    if (intent.settings.playback && Object.keys(evidence.hostBases).some((key) => key !== intent.target.profileId)) fail();
    intent.event = await finalizeProfileEditEvent(makeProfileEditEvent(newProfileEditEventID(), editedAt,
      observed, [evidence.eventPatch], {}, { observedHostClock: evidence.observedHostClock, hostBases: evidence.hostBases }),
      profileEditEventFingerprintContext(doc) ?? fail());
  }
  validateProfilePlan(intent);
  let current = doc.profileEditEvents;
  if (current !== undefined && (!obj(current) || current.schemaVersion !== 2 || !Array.isArray(current.events)
    || Object.keys(current).some((key) => !["schemaVersion", "events"].includes(key)))) fail();
  // Compact only proven receipts during a genuine append, never as a background cleanup PUT.
  const receipts = profileEditEventReceiptsFromSyncDoc(doc).filter((receipt) => {
    const event = current?.events.find((row: any) => row?.eventId === receipt.eventId), raw = doc.nativeSync?.legacyProfileEditReceipts?.[receipt.fingerprint];
    return event && raw?.source?.editedAtMs === event.editedAt && raw?.source?.observedNativeClock === event.observedNativeClock;
  });
  pruneAcknowledgedProfileEditEvents(doc, receipts, profileEditEventFingerprintContext(doc));
  current = doc.profileEditEvents;
  const prior = current?.events ?? [];
  const wire = Object.fromEntries(Object.entries(intent.event).filter(([key]) => key !== "fingerprint"));
  const existing = prior.find((row: any) => row?.eventId === intent.event!.eventId);
  if (existing) { if (!same(existing, wire)) fail(); return false; }
  if (prior.length >= 128 || new TextEncoder().encode(canonicalJSON([...prior, wire])).length > 2 * 1024 * 1024) fail();
  appendProfileEditEventOrThrow(doc, intent.event);
  return true;
}

export interface NativeAddonIntent { url: string; added: boolean; descriptor?: { transportUrl: string; name: string; manifest: unknown } }
export interface AddonEventIntent { target: HostTarget; mutations: NativeAddonIntent[]; event?: Record<string, any> }
export function addonIdentity(raw: string): string {
  const value = raw.trim(), match = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]+)([\s\S]*)$/i.exec(value);
  if (!match || !/^https?:/i.test(value)) return fail();
  const split = match[2].lastIndexOf("@"), credentials = split < 0 ? "" : match[2].slice(0, split + 1);
  return `${match[1].toLowerCase()}://${credentials}${match[2].slice(split + 1).toLowerCase()}${match[3]}`;
}
const addonHash = (event: Record<string, any>): string => canonicalJSONHashSync(event, "vortx.website-addon.v1\n");
const keys = (value: Record<string, any>, required: string[], optional: string[] = []): boolean =>
  required.every((key) => Object.prototype.hasOwnProperty.call(value, key)) && Object.keys(value).every((key) => required.includes(key) || optional.includes(key));
const addonClock = (value: unknown): boolean => typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER - 1;
const addonCounter = (value: unknown): value is string => typeof value === "string" && /^(0|[1-9][0-9]{0,19})$/.test(value) && BigInt(value) < 18446744073709551615n;
const addonID = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
function validateAddonURL(value: unknown): asserts value is string {
  const text = typeof value === "string" ? value : fail();
  if (text !== text.trim() || addonIdentity(text) !== text || /\s/.test(text)) fail();
  try { const url = new URL(text); if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash || text.includes("#")) fail(); }
  catch { fail(); }
}
function validateAddonSource(raw: unknown): void {
  const source = obj(raw) ?? fail();
  if (!keys(source, ["schemaVersion", "counter", "eventId", "fingerprint", "observedClock"]) || source.schemaVersion !== 1
    || !addonCounter(source.counter) || !addonID(source.eventId) || typeof source.fingerprint !== "string"
    || !/^[0-9a-f]{64}$/.test(source.fingerprint) || !addonClock(source.observedClock)) fail();
}
function validateAddonDescriptor(raw: unknown, url: string): void {
  const descriptor = obj(raw) ?? fail();
  if (!keys(descriptor, ["transportUrl", "manifest"], ["flags"]) || descriptor.transportUrl !== url || !isNativeAddonManifest(descriptor.manifest)) fail();
  if (descriptor.flags !== undefined) {
    const flags = obj(descriptor.flags) ?? fail();
    if (!keys(flags, [], ["official", "protected"]) || Object.values(flags).some((value) => typeof value !== "boolean")) fail();
  }
}
function validateAddonURLs(raw: unknown): void {
  if (!Array.isArray(raw) || new Set(raw).size !== raw.length) fail();
  for (const value of raw as unknown[]) validateAddonURL(value);
}
function validateAddonWire(raw: unknown, scope: string, ownerProfileId: string): Record<string, any> {
  const event = obj(raw) ?? fail();
  if (!keys(event, ["schemaVersion", "eventId", "counter", "wallTime", "scope", "ownerProfileId", "profileId", "expectedBinding", "observed", "mutations"], ["order"])
    || event.schemaVersion !== 1 || !addonID(event.eventId) || !addonCounter(event.counter) || !addonClock(event.wallTime)
    || event.wallTime > Date.now() + 48 * 60 * 60 * 1000 || event.scope !== scope || event.ownerProfileId !== ownerProfileId
    || typeof event.profileId !== "string" || !event.profileId.trim()) fail();
  validateProfileAccountBindingRevision(event.expectedBinding);
  const observed = obj(event.observed) ?? fail(), records = obj(observed.records) ?? fail(), order = obj(observed.order) ?? fail();
  if (!keys(observed, ["records", "order"]) || !keys(order, ["updatedAt", "ids"], ["webSource"]) || !addonClock(order.updatedAt)) fail();
  validateAddonURLs(order.ids);
  if (order.webSource !== undefined) validateAddonSource(order.webSource);
  for (const [url, rawRecord] of Object.entries(records)) {
    validateAddonURL(url); const record = obj(rawRecord) ?? fail();
    if (!keys(record, ["addedAt", "removedAt", "valueAt", "value"], ["webSources"])
      || ![record.addedAt, record.removedAt, record.valueAt].every(addonClock)) fail();
    if (record.value !== null) validateAddonDescriptor(record.value, url);
    if (record.webSources !== undefined) {
      const sources = obj(record.webSources) ?? fail();
      if (!keys(sources, [], ["addedAt", "removedAt", "valueAt"])) fail();
      for (const source of Object.values(sources)) validateAddonSource(source);
    }
  }
  if (!Array.isArray(event.mutations) || (!event.mutations.length && event.order === undefined)) fail();
  const seen = new Set<string>();
  for (const rawMutation of event.mutations) {
    const mutation = obj(rawMutation) ?? fail(); validateAddonURL(mutation.transportUrl);
    if (seen.has(mutation.transportUrl)) fail(); seen.add(mutation.transportUrl);
    if (mutation.state === "present") {
      if (!keys(mutation, ["transportUrl", "state", "addon"])) fail();
      validateAddonDescriptor(mutation.addon, mutation.transportUrl);
    } else if (mutation.state !== "removed" || !keys(mutation, ["transportUrl", "state"])) fail();
  }
  if (event.order !== undefined) validateAddonURLs(event.order);
  // Unknown noncredential manifest extensions remain hash-bound. Public native hosts reject
  // credential-named material rather than accepting a browser source they cannot consume.
  const credentialKeys = new Set(["auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey", "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials", "nativeprovidercredentials"]);
  let nodes = 0;
  const inspect = (value: unknown, depth: number): void => {
    if (depth > 64 || ++nodes > 100000) fail();
    if (Array.isArray(value)) { value.forEach((entry) => inspect(entry, depth + 1)); return; }
    const fields = obj(value); if (!fields) return;
    for (const [key, entry] of Object.entries(fields)) {
      if (!/^https?:\/\//i.test(key)) {
        const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");
        if (key.toLowerCase().startsWith("kcfallback.") || credentialKeys.has(normalized) || normalized.includes("secret")
          || normalized.includes("credential") || ["token", "password", "authkey", "apikey"].some((suffix) => normalized.endsWith(suffix))) fail();
      }
      inspect(entry, depth + 1);
    }
  };
  inspect(event, 0);
  if (new TextEncoder().encode(canonicalJSON(event)).length > 2 * 1024 * 1024) fail();
  return event;
}
function addonEvents(doc: Record<string, any>): Record<string, any>[] {
  if (doc.webAddonEdits === undefined) return [];
  const carrier = obj(doc.webAddonEdits) ?? fail();
  if (carrier.schemaVersion !== 1 || Object.keys(carrier).length !== 2 || !Array.isArray(carrier.events)
    || carrier.events.length > 128 || new TextEncoder().encode(canonicalJSON(carrier)).length > 2 * 1024 * 1024) fail();
  const ids = new Set<string>();
  for (const raw of carrier.events) {
    const event = validateAddonWire(raw, doc.nativeSync.scope, doc.nativeSync.ownerProfileId);
    if (ids.has(event.eventId)) fail();
    addonHash(event); ids.add(event.eventId);
  }
  return carrier.events;
}
function validateAddonPlan(intent: AddonEventIntent): void {
  const event = intent.event;
  if (!event) return;
  validateAddonWire(event, intent.target.scope, intent.target.ownerProfileId);
  if (event.profileId !== intent.target.profileId || event.mutations.length !== intent.mutations.length || event.order !== undefined) fail();
  if (canonicalJSON(event.expectedBinding) !== intent.target.binding) fail();
  for (let i = 0; i < intent.mutations.length; i++) {
    const captured = intent.mutations[i], mutation = event.mutations[i];
    if (mutation.transportUrl !== addonIdentity(captured.url) || mutation.state !== (captured.added ? "present" : "removed")
      || (captured.added && !same(mutation.addon?.manifest, captured.descriptor?.manifest))) fail();
    const priorFlags = event.observed.records[mutation.transportUrl]?.value?.flags;
    if (captured.added && !same(mutation.addon.flags, { official: priorFlags?.official === true, protected: priorFlags?.protected === true })) fail();
    if (!captured.added && priorFlags?.protected === true) fail();
  }
}
function addonWireAcknowledged(doc: Record<string, any>, event: Record<string, any>, view: NonNullable<ReturnType<typeof projectNativeSync>>): boolean {
  if (event.profileId !== view.ownerProfileId || event.ownerProfileId !== view.ownerProfileId || event.scope !== view.scope
    || !same(event.expectedBinding, view.ownerAccountBinding)) return false;
  const receipt = obj(doc.nativeSync?.websiteAddonReceipts?.[event.eventId]);
  const exactReceipt = !!receipt && keys(receipt, ["schemaVersion", "eventId", "counter", "fingerprint", "scope", "ownerProfileId", "profileId", "expectedBinding"])
    && receipt.schemaVersion === 1 && receipt.eventId === event.eventId && receipt.counter === event.counter
    && receipt.fingerprint === addonHash(event) && receipt.scope === event.scope && receipt.ownerProfileId === event.ownerProfileId
    && receipt.profileId === event.profileId && same(receipt.expectedBinding, event.expectedBinding);
  if (!exactReceipt) return false;
  // Public native adapters distinguish consideration from the materialized result. A newer native
  // uninstall/rebind is a conflict, not permission to ACK the install based on an old receipt alone.
  for (const mutation of event.mutations) {
    const member = view.ownerAddons.find((row) => row.identity === mutation.transportUrl);
    if (mutation.state === "removed") { if (member?.live) return false; }
    else {
      const sources = view.ownerAddonMembership.records?.[mutation.transportUrl]?.webSources;
      if (!member?.live || sources?.addedAt?.fingerprint !== receipt.fingerprint || sources?.valueAt?.fingerprint !== receipt.fingerprint) return false;
    }
  }
  if (event.order !== undefined && !same(event.order, view.ownerAddonOrder)) return false;
  return true;
}
export function addonEventAcknowledged(doc: Record<string, any>, intent: AddonEventIntent): boolean {
  const { view } = targetProfile(doc, intent.target);
  validateAddonPlan(intent);
  return !!intent.event && addonWireAcknowledged(doc, intent.event, view);
}
export function applyAddonEventIntent(doc: Record<string, any>, intent: AddonEventIntent): boolean {
  const { view, profile } = targetProfile(doc, intent.target);
  if (!profile.main || !view.ownerAccountBinding || view.ownerAccountBinding.account.kind === "pending_own") fail();
  if (addonEventAcknowledged(doc, intent)) return false;
  if (intent.event) {
    const receipt = obj(doc.nativeSync.websiteAddonReceipts?.[intent.event.eventId]);
    if (receipt?.fingerprint === addonHash(intent.event) && receipt.eventId === intent.event.eventId
      && receipt.counter === intent.event.counter && receipt.scope === intent.event.scope && receipt.profileId === intent.event.profileId
      && receipt.ownerProfileId === intent.event.ownerProfileId && same(receipt.expectedBinding, intent.event.expectedBinding)) fail();
  }
  const events = addonEvents(doc);
  if (!intent.event) {
    let counter = events.reduce((maximum, event) => maximum > BigInt(event.counter) ? maximum : BigInt(event.counter), 0n);
    for (const raw of Object.values(doc.nativeSync.websiteAddonReceipts ?? {})) {
      const receipt = obj(raw) ?? fail();
      if (receipt.schemaVersion !== 1 || !addonCounter(receipt.counter)) fail();
      counter = counter > BigInt(receipt.counter) ? counter : BigInt(receipt.counter);
    }
    if (counter >= 18446744073709551614n) fail();
    const mutations = intent.mutations.map((mutation) => {
      const transportUrl = addonIdentity(mutation.url), prior = view.ownerAddonMembership.records?.[transportUrl]?.value;
      if (!mutation.added) {
        if (prior?.flags?.protected === true) fail();
        return { transportUrl, state: "removed" };
      }
      const manifest = mutation.descriptor?.manifest;
      if (!isNativeAddonManifest(manifest)) fail();
      const addon = { transportUrl, manifest: clone(manifest), flags: { official: prior?.flags?.official === true, protected: prior?.flags?.protected === true } };
      return { transportUrl, state: "present", addon };
    });
    intent.event = { schemaVersion: 1, eventId: newProfileEditEventID().replace(/-/g, ""), counter: String(counter + 1n), wallTime: Date.now(),
      scope: view.scope, ownerProfileId: view.ownerProfileId, profileId: profile.id, expectedBinding: clone(view.ownerAccountBinding),
      observed: clone(view.ownerAddonMembership), mutations };
    addonHash(intent.event);
  }
  validateAddonPlan(intent); // Newly planned and restored source must pass the same public DTO.
  const prior = events.find((event) => event.eventId === intent.event!.eventId);
  if (prior) { if (!same(prior, intent.event)) fail(); return false; }
  const retained = events.filter((event) => !addonWireAcknowledged(doc, event, view));
  const carrier = { schemaVersion: 1, events: [...retained, intent.event] };
  if (carrier.events.length > 128 || new TextEncoder().encode(canonicalJSON(carrier)).length > 2 * 1024 * 1024) fail();
  doc.webAddonEdits = carrier;
  return true;
}
