import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { registerHooks } from "node:module";
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
      const candidate = new URL(specifier + ".ts", context.parentURL);
      if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});
// Direct Node execution uses the same extensionless-relative resolver as the other webapp tests.
const {
  HOST_MAX_CLOCK,
  hostSettingField,
  watchlistField,
  watchlistValue,
  createHostIntent,
  applyHostIntent,
} = await import("./nativeHostEdits.ts");
const { projectNativeSync } = await import("./nativeSyncProjection.ts");

const fixture = JSON.parse(readFileSync(new URL("./fixtures/native-sync-carrier.json", import.meta.url), "utf8"));
const fixtureDocument = fixture.ownSlotCases.find((sample) => sample.source.startsWith("07-own-A-return-schema4")).document;
const fixtureScope = fixtureDocument.nativeSync.scope;
const fixtureProjection = projectNativeSync(fixtureDocument, fixtureScope);
const fixtureOwner = fixtureProjection.ownerProfileId;
const fixtureProfile = fixtureProjection.profiles.find((profile) => !profile.main && !profile.pending).id;
const fixtureBinding = fixtureProjection.profiles.find((profile) => profile.id === fixtureProfile).binding;
const ACTOR = "00000000-0000-4000-8000-000000000001";
const OTHER_ACTOR = "00000000-0000-4000-8000-000000000002";
const LETTER_ACTOR = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OWNER = "10000000-0000-0000-0000-000000000001";
const PROFILE_A = "10000000-0000-0000-0000-000000000002";
const PROFILE_B = "10000000-0000-0000-0000-000000000003";
const SCOPE = "account.synthetic-host-edits";
const BINDING_A = JSON.stringify({ account: { kind: "own", value: "synthetic-a" }, revision: 3, transactionId: "tx-a" });
const BINDING_B = JSON.stringify({ account: { kind: "own", value: "synthetic-b" }, revision: 4, transactionId: "tx-b" });
const OWNER_BINDING = JSON.stringify({ account: { kind: "local_only" }, revision: 0, transactionId: null });

function profile(account, { pin = null, kids = false, pending = false } = {}) {
  return {
    profile: {
      id: account,
      name: account,
      owner: account === OWNER,
      deleted: false,
      ...(pin !== null ? { pin } : {}),
      account: pending ? { kind: "pending_own" } : { kind: "own", value: account === PROFILE_A ? "synthetic-a" : "synthetic-b" },
      parental: { pin, kids, familyEdit: false },
    },
  };
}

function ownSlotKey(value) {
  return `own:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`;
}

function syntheticDocument({ activeProfile = PROFILE_A, binding = BINDING_A, ...options } = {}) {
  const profiles = {
    [OWNER]: { profile: { id: OWNER, name: "Owner", owner: true, deleted: false, account: { kind: "local_only" }, parental: { pin: null, kids: false, familyEdit: false } } },
    [PROFILE_A]: profile(PROFILE_A),
    [PROFILE_B]: profile(PROFILE_B),
  };
  if (options.pin || options.kids || options.pending) profiles[activeProfile] = profile(activeProfile, options);
  const activeAccount = profiles[activeProfile].profile.account;
  const activeSlot = {
    account: activeAccount,
    addons: { records: {}, order: { ids: [], updatedAt: 0 } },
    library: { records: {}, order: { ids: [], updatedAt: 0 } },
    watch: { contexts: {}, log: {} },
  };
  const activeBinding = options.pending
    ? JSON.stringify({ account: { kind: "pending_own" }, revision: 4, transactionId: "tx-pending" })
    : binding;
  return {
    nativeSync: {
      schemaVersion: 4,
      scope: SCOPE,
      ownerProfileId: OWNER,
      profiles,
      accountSlots: {
        [activeProfile]: {
          activeBinding: JSON.parse(activeBinding),
          slots: activeAccount.kind === "own" ? { [ownSlotKey(activeAccount.value)]: activeSlot } : { pending: activeSlot },
        },
      },
    },
    nativeHostPreferences: {
      schemaVersion: 1,
      scope: SCOPE,
      ownerProfileId: OWNER,
      profiles: {},
      globals: { fields: {} },
    },
  };
}

function target({ profileId = PROFILE_A, binding = BINDING_A, scope = SCOPE, ownerProfileId = OWNER } = {}) {
  return { scope, ownerProfileId, profileId, binding };
}

function apply(doc, fields, opts = {}) {
  const intent = createHostIntent(target(opts), fields, Boolean(opts.global), ACTOR);
  const result = applyHostIntent(doc, intent, opts.counter ?? 0);
  return { intent, result };
}

function profileFields(doc, profileId = PROFILE_A) {
  return doc.nativeHostPreferences.profiles[profileId]?.fields ?? {};
}

test("host field admission is exact and watchlist values preserve the public wire shape", () => {
  assert.equal(hostSettingField("autoplayTrailers"), "stremiox.autoplayTrailers");
  assert.equal(hostSettingField("directLinksOnly"), "stremiox.directLinksOnly");
  assert.equal(hostSettingField("performance"), "stremiox.performanceMode");
  for (const unknown of ["oled", "accent", "playback", "", "autoplay_trailers", "autoplayTrailers.extra"]) assert.equal(hostSettingField(unknown), null);

  assert.equal(watchlistField("tt-hello", "movie"), "watchlist.movie.dHQtaGVsbG8");
  assert.equal(watchlistField("tmdb:123", "series"), "watchlist.series.dG1kYjoxMjM");
  assert.equal(watchlistField(`tt${"a".repeat(510)}`, "movie").startsWith("watchlist.movie."), true);
  assert.throws(() => watchlistField(`tt${"a".repeat(511)}`, "movie"));
  for (const bad of [["tt-x", "show"], ["", "movie"], ["tt x", "movie"], ["tt-x", "Movie"]]) assert.throws(() => watchlistField(...bad));

  assert.deepEqual(watchlistValue({ id: "tt-hello", type: "movie", name: "Watch later", poster: "https://img.invalid/p.jpg" }, 123.5), {
    id: "tt-hello", type: "movie", addedAt: 123.5, name: "Watch later", poster: "https://img.invalid/p.jpg",
  });
  assert.throws(() => watchlistValue({ id: "tt-x", type: "movie" }, -1));
  assert.ok(watchlistValue({ id: "tt-x", type: "movie" }, Number.MAX_SAFE_INTEGER));
  assert.throws(() => watchlistValue({ id: "tt-x", type: "movie" }, Number.MAX_SAFE_INTEGER + 1));
  assert.throws(() => watchlistValue({ id: "tt-x", type: "movie" }, Infinity));
  assert.throws(() => watchlistValue({ id: "tt-x", type: "movie", name: "x".repeat(4097) }, 1));
  assert.throws(() => watchlistValue({ id: "tt-x", type: "movie", poster: "x".repeat(8193) }, 1));
});
test("fixture scope and binding accept a bounded profile watchlist intent; unknown channels are rejected", () => {
  const document = structuredClone(fixtureDocument);
  const before = structuredClone(document.nativeHostPreferences);
  const intent = createHostIntent(target({ scope: fixtureScope, ownerProfileId: fixtureOwner, profileId: fixtureProfile, binding: fixtureBinding }), {
    [watchlistField("tt-host-fixture", "movie")]: watchlistValue({ id: "tt-host-fixture", type: "movie", name: "Fixture watch" }, 1720000000),
  }, false, ACTOR);
  const result = applyHostIntent(document, intent, 10);
  assert.equal(result.alreadyApplied, false);
  assert.equal(result.counter, 11);
  assert.equal(document.nativeHostPreferences.profiles[fixtureProfile].fields[watchlistField("tt-host-fixture", "movie")].value.id, "tt-host-fixture");
  assert.deepEqual(document.nativeHostPreferences.globals, before.globals);
  assert.equal(intent.registers[watchlistField("tt-host-fixture", "movie")].clock, 11);
  const unchanged = structuredClone(document.nativeHostPreferences);
  assert.throws(() => createHostIntent(target({ scope: fixtureScope, ownerProfileId: fixtureOwner, profileId: fixtureProfile, binding: fixtureBinding }), { "unknown.channel": "must-not-be-written" }, false, ACTOR));
  assert.deepEqual(document.nativeHostPreferences, unchanged);
});
test("global host edits, removals, re-additions, and profile-local values use stable Lamport registers", () => {
  const document = syntheticDocument();
  const opaque = { clock: 2, actor: OTHER_ACTOR, value: { future: "native-only" } };
  document.nativeHostPreferences.globals.fields["stremiox.futureChannel"] = opaque;
  const first = apply(document, {
    [hostSettingField("autoplayTrailers")]: false,
    [hostSettingField("directLinksOnly")]: true,
  }, { global: true, profileId: OWNER, binding: OWNER_BINDING, counter: 4 });
  assert.equal(first.result.counter, 6);
  assert.equal(document.nativeHostPreferences.globals.fields[hostSettingField("autoplayTrailers")].value, false);
  assert.equal(document.nativeHostPreferences.globals.fields[hostSettingField("directLinksOnly")].value, true);
  assert.deepEqual(document.nativeHostPreferences.globals.fields["stremiox.futureChannel"], opaque);

  const watchKey = watchlistField("tt-readd", "movie");
  const add = apply(document, { [watchKey]: watchlistValue({ id: "tt-readd", type: "movie" }, 20) });
  assert.equal(profileFields(document)[watchKey].value.id, "tt-readd");
  const remove = apply(document, { [watchKey]: null }, { counter: add.result.counter });
  assert.equal(profileFields(document)[watchKey].value, null);
  assert.ok(remove.intent.registers[watchKey].clock > add.intent.registers[watchKey].clock);
  const readd = apply(document, { [watchKey]: watchlistValue({ id: "tt-readd", type: "movie", name: "Again" }, 22) }, { counter: remove.result.counter });
  assert.equal(profileFields(document)[watchKey].value.name, "Again");
  assert.ok(readd.intent.registers[watchKey].clock > remove.intent.registers[watchKey].clock);

  const snapshot = structuredClone(document.nativeHostPreferences);
  const duplicate = applyHostIntent(document, readd.intent, readd.result.counter);
  assert.equal(duplicate.alreadyApplied, true);
  assert.deepEqual(document.nativeHostPreferences, snapshot);
});
test("profile fencing rejects wrong scope, owner, binding, and protected or pending profiles without mutation", () => {
  const cases = [
    { scope: "account.other", label: "scope" },
    { ownerProfileId: PROFILE_B, label: "owner" },
    { profileId: PROFILE_B, binding: BINDING_A, label: "profile" },
    { binding: BINDING_B, label: "binding" },
  ];
  for (const change of cases) {
    const document = syntheticDocument();
    const before = structuredClone(document.nativeHostPreferences);
    const intent = createHostIntent(target(change), { [watchlistField("tt-fence", "movie")]: watchlistValue({ id: "tt-fence", type: "movie" }, 1) }, false, ACTOR);
    assert.throws(() => applyHostIntent(document, intent, 0), change.label);
    assert.deepEqual(document.nativeHostPreferences, before, `${change.label} rejection is atomic`);
  }
  for (const options of [{ pin: "1234" }, { kids: true }, { pending: true }]) {
    const document = syntheticDocument(options);
    const before = structuredClone(document.nativeHostPreferences);
    const intent = createHostIntent(target(), { [watchlistField("tt-protected", "movie")]: watchlistValue({ id: "tt-protected", type: "movie" }, 1) }, false, ACTOR);
    assert.throws(() => applyHostIntent(document, intent, 0));
    assert.deepEqual(document.nativeHostPreferences, before);
  }
});
test("register validation rejects malformed actors/clocks, overflow, equal-pair conflicts, and ambiguous peers", () => {
  assert.equal(HOST_MAX_CLOCK, Number.MAX_SAFE_INTEGER);
  const actorField = watchlistField("tt-actor", "movie");
  for (const actor of ["NOT-A-UUID", LETTER_ACTOR.toUpperCase(), `${ACTOR} `, [ACTOR], { toString: () => ACTOR }]) {
    assert.throws(() => createHostIntent(target(), { [actorField]: null }, false, actor), "actor must be a canonical UUID string, never a coercible value");
  }
  const corrupted = createHostIntent(target(), { [actorField]: null }, false, ACTOR);
  corrupted.actor = [ACTOR];
  assert.throws(() => applyHostIntent(syntheticDocument(), corrupted, 0), "a corrupted restored actor cannot become a mutation");

  const document = syntheticDocument();
  const initial = apply(document, { [hostSettingField("autoplayTrailers")]: true }, { global: true, profileId: OWNER, binding: OWNER_BINDING, counter: HOST_MAX_CLOCK - 1 });
  assert.equal(initial.result.counter, HOST_MAX_CLOCK);
  assert.equal(document.nativeHostPreferences.globals.fields[hostSettingField("autoplayTrailers")].clock, HOST_MAX_CLOCK);
  assert.throws(() => applyHostIntent(document, createHostIntent(target({ profileId: OWNER, binding: OWNER_BINDING }), { [hostSettingField("directLinksOnly")]: true }, true, ACTOR), HOST_MAX_CLOCK));

  const equalPair = syntheticDocument();
  const samePairDifferentValue = createHostIntent(target({ profileId: OWNER, binding: OWNER_BINDING }), { [hostSettingField("autoplayTrailers")]: false }, true, ACTOR);
  const firstPlan = applyHostIntent(equalPair, samePairDifferentValue, 0);
  equalPair.nativeHostPreferences.globals.fields[hostSettingField("autoplayTrailers")].value = true;
  assert.throws(() => applyHostIntent(equalPair, samePairDifferentValue, firstPlan.counter));

  const ambiguous = syntheticDocument();
  const planned = createHostIntent(target({ profileId: OWNER, binding: OWNER_BINDING }), { [hostSettingField("autoplayTrailers")]: false }, true, ACTOR);
  const plannedResult = applyHostIntent(ambiguous, planned, 0);
  ambiguous.nativeHostPreferences.globals.fields[hostSettingField("autoplayTrailers")] = { clock: plannedResult.counter + 1, actor: OTHER_ACTOR, value: true };
  assert.throws(() => applyHostIntent(ambiguous, planned, 0));

  const peer = syntheticDocument();
  peer.nativeHostPreferences.globals.fields[hostSettingField("autoplayTrailers")] = { clock: 8, actor: OTHER_ACTOR, value: true };
  const unplanned = createHostIntent(target({ profileId: OWNER, binding: OWNER_BINDING }), { [hostSettingField("autoplayTrailers")]: false }, true, ACTOR);
  const peerResult = applyHostIntent(peer, unplanned, 0);
  assert.equal(peerResult.counter, 9);
  assert.equal(peer.nativeHostPreferences.globals.fields[hostSettingField("autoplayTrailers")].clock, 9);
  const namedGlobal = syntheticDocument();
  namedGlobal.nativeHostPreferences.profiles.global = { fields: {
    [watchlistField("tt-malformed", "movie")]: { clock: 3, actor: ACTOR, value: { id: "tt-wrong", type: "movie", addedAt: 1 } },
  } };
  const beforeMalformed = structuredClone(namedGlobal);
  assert.throws(() => applyHostIntent(namedGlobal, createHostIntent(target({ profileId: OWNER, binding: OWNER_BINDING }), {
    [hostSettingField("directLinksOnly")]: true,
  }, true, ACTOR), 0), "all profile Watchlist branches validate, including a profile key literally named global");
  assert.deepEqual(namedGlobal, beforeMalformed, "invalid inherited known field cannot become a mutation base");
});

test("watchlist live cap is 1000 and exact name/poster byte limits are enforced", () => {
  const document = syntheticDocument();
  const fields = {};
  for (let index = 0; index < 1000; index += 1) {
    const id = `tt-cap-${index}`;
    fields[watchlistField(id, "movie")] = watchlistValue({ id, type: "movie" }, index + 1);
  }
  const applied = apply(document, fields);
  assert.equal(Object.values(profileFields(document)).filter((register) => register.value !== null).length, 1000);
  const overflow = syntheticDocument();
  const overflowFields = { ...fields, [watchlistField("tt-cap-overflow", "movie")]: watchlistValue({ id: "tt-cap-overflow", type: "movie" }, 2000) };
  assert.throws(() => apply(overflow, overflowFields));
  assert.equal(Object.keys(profileFields(overflow)).length, 0, "cap rejection is atomic");

  assert.throws(() => watchlistValue({ id: "tt-emoji", type: "movie", name: "🙂".repeat(2049) }, 1));
  assert.throws(() => watchlistValue({ id: "tt-emoji", type: "movie", poster: "🙂".repeat(2049) }, 1));
  assert.ok(watchlistValue({ id: "tt-emoji", type: "movie", name: "🙂".repeat(1024), poster: "🙂".repeat(2048) }, 1));
});
// Direct Node execution uses the same extensionless-relative resolver as the other webapp tests.
