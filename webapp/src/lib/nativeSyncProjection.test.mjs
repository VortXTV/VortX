import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { projectNativeSync, nativeAddonIdentity } from "./nativeSyncProjection.ts";

const fixture = JSON.parse(readFileSync(new URL("./fixtures/native-sync-carrier.json", import.meta.url), "utf8"));

test("public native projection matches actual Apple/Android CABI playback exports", () => {
  assert.equal(fixture.provenance.kind, "Actual Apple and Android native carrier fixture exports");
  assert.match(fixture.provenance.nativeLibrarySHA256, /^[a-f0-9]{64}$/);
  for (const sample of [...fixture.cases, ...fixture.ownSlotCases, ...fixture.edgeCases]) {
    const original = structuredClone(sample.document);
    const projected = projectNativeSync(sample.document, sample.document.nativeSync.scope);
    const profile = sample.playback.profileId.toUpperCase();
    assert.deepEqual((projected.continueByProfile[profile] ?? []).map((row) => [row.id, row.name, row.t, row.d]),
      sample.playback.continueWatching.map((row) => [row.metaId, row.name, row.offsetMs, row.durationMs]), sample.source);
    assert.deepEqual(sample.document, original, "projection never changes native clocks, receipts, opaque or legacy fields");
    if (sample.installedAddons) assert.deepEqual(Array.isArray(sample.installedAddons) ? projected.ownerAddonOrder : projected.addonOrderByProfile[profile],
      Array.isArray(sample.installedAddons) ? sample.installedAddons : sample.installedAddons.addons.map((addon) => addon.transportUrl), sample.source);
  }
});

test("active own slots, pending-own emptiness and authoritative library removal match the actual native exports", () => {
  for (const sample of fixture.ownSlotCases) {
    const projected = projectNativeSync(sample.document);
    const profile = sample.playback.profileId.toUpperCase();
    const expected = sample.source.includes("own-A") ? ["tt-own-a-only"] : sample.source.includes("own-B") ? ["tt-own-b-only"] : [];
    assert.deepEqual(projected.libraryByProfile[profile].map((row) => row.id), expected, sample.source);
    assert.deepEqual(projected.libraryByProfile[projected.ownerProfileId].map((row) => row.id), ["tt-owner-only"]);
  }
  const document = structuredClone(fixture.cases[0].document), owner = document.nativeSync.ownerProfileId;
  document.nativeSync.libraries[owner] = { records: {}, order: { ids: [], updatedAt: 0 } };
  document.vortx = { library: [{ id: "stale-legacy", type: "movie", name: "Stale" }] };
  assert.deepEqual(projectNativeSync(document).libraryByProfile[owner], []);
});

test("native-valid zero offset, unknown duration and high progress are not browser heuristic completions", () => {
  const sample = fixture.edgeCases.find((sample) => sample.source.startsWith("01-zero"));
  const document = structuredClone(sample.document), owner = document.nativeSync.ownerProfileId;
  assert.equal(projectNativeSync(document).continueByProfile[owner][0].t, 0);
  const watch = document.nativeSync.watches[owner];
  for (const context of Object.values(watch.contexts)) context.durationMs = 0;
  assert.equal(projectNativeSync(document).continueByProfile[owner].length, 1);
  for (const context of Object.values(watch.contexts)) context.durationMs = 100;
  for (const state of Object.values(watch.log)) state.resume_ms = 99;
  assert.equal(projectNativeSync(document).continueByProfile[owner].length, 1);
});

test("native schema-5 source ties retain native/add/removal causal semantics", () => {
  const document = { nativeSync: structuredClone(fixture.websiteAddonGolden.nativeSync) };
  const projected = projectNativeSync(document), owner = projected.ownerProfileId;
  const bucket = document.nativeSync.addons[owner], key = Object.keys(bucket.records)[0], record = bucket.records[key];
  record.addedAt = record.removedAt = Math.max(record.addedAt, record.removedAt, 1);
  record.webSources = {};
  assert.equal(projectNativeSync(document).ownerAddons.find((row) => row.identity === key).live, false, "exact native tie retains removal");
  const source = { schemaVersion: 1, counter: "9007199254740993", eventId: "0".repeat(32), fingerprint: "a".repeat(64), observedClock: 1 };
  record.webSources.removedAt = source;
  assert.equal(projectNativeSync(document).ownerAddons.find((row) => row.identity === key).live, true, "native beats a web source on a clock tie");
  record.webSources.addedAt = { ...source, counter: "9007199254740994" };
  assert.equal(projectNativeSync(document).ownerAddons.find((row) => row.identity === key).live, true, "decimal UInt64 comparison does not round JS numbers");
});

test("known native/host schema, authenticated scope, unique owner and exact active binding fail closed", () => {
  const sample = fixture.ownSlotCases[0], document = sample.document;
  for (const corrupt of [
    (doc) => { doc.nativeSync.schemaVersion = 99; },
    (doc) => { doc.nativeSync.scope = "account.other-account"; },
    (doc) => { doc.nativeHostPreferences = { schemaVersion: 1, scope: "account.foreign", ownerProfileId: doc.nativeSync.ownerProfileId }; },
    (doc) => { doc.nativeSync.profiles[doc.nativeSync.ownerProfileId].profile.deleted = true; },
    (doc) => { doc.nativeSync.accountSlots[sample.playback.profileId].activeBinding.transactionId = null; },
    (doc) => { doc.nativeSync.accountSlots[sample.playback.profileId].slots = {}; },
    (doc) => { delete doc.nativeSync.accountSlots[sample.playback.profileId].activeBinding.revision; },
    (doc) => { doc.nativeSync.profiles[doc.nativeSync.ownerProfileId].profile.pin = 12; },
    (doc) => { doc.nativeSync.profiles[doc.nativeSync.ownerProfileId].profile.parental = { kids: "false" }; },
    (doc) => { doc.nativeSync.profiles[doc.nativeSync.ownerProfileId].profile.parental = { familyEdit: {} }; },
  ]) {
    const candidate = structuredClone(document); corrupt(candidate);
    assert.throws(() => projectNativeSync(candidate, document.nativeSync.scope));
  }
  assert.equal(projectNativeSync({ vortx: {} }), null);
  assert.equal(nativeAddonIdentity("HTTPS://User:Pass@HOST.test:443/Path?Key=Case#Fragment"), "https://User:Pass@host.test:443/Path?Key=Case#Fragment");
  const hostDocument = structuredClone(fixture.cases[0].document);
  const register = Object.values(hostDocument.nativeHostPreferences.profiles)[0].fields;
  delete Object.values(register)[0].clock;
  assert.throws(() => projectNativeSync(hostDocument));
});
