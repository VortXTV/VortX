// Drift guard + legacy-shim test for the six SYNCED playback enums.
//
// WHY THIS FILE EXISTS. These six fields are written by the webapp into the account doc and read back RAW by
// the Apple app (syncSettings.mergeWebappSettingsIntoProfile -> doc.profileEdits...playback.* ->
// Profiles.playbackPrefs -> applyPlaybackPrefs -> live UserDefaults). Nothing in either toolchain links the
// two vocabularies: the app's ids are Swift string literals, the webapp's are TS string-literal unions, and
// TypeScript cannot see Swift. So the webapp drifted ("moderate", "on", "shadow", "none", "cyan", "mint",
// "mono") and every shipped web build silently corrupted real accounts, with nothing failing loudly. A
// one-time cleanup does not fix that; only a test that FAILS on the next drift does.
//
// So this exercises the REAL exported helpers (following vault.crypto.test.mjs, which imports vault.ts rather
// than re-implementing it) and PARSES the REAL Swift sources for the app's ids (following
// ExternalSyncToggleSyncTests.testShimMatchesRealEnum). The app is the source of truth in both directions:
// if someone adds a subtitle colour to SubtitleStyle.swift, or renames one, this test fails until the webapp
// follows. It is deliberately NOT a mirrored constant table: a table would drift the same way the code did.
//
// Run: `npm test` (wired into package.json) or `node --test src/lib/settings.vocab.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

// syncSettings.ts imports `./settings` WITHOUT an extension. Vite resolves that; Node's ESM resolver does
// not, so importing the real module would fail on the specifier alone. Teach the resolver the one rule Vite
// applies here (extensionless relative -> .ts) rather than rewriting app source to suit the test runner: the
// source is correct for its bundler, and the test exists to follow the code, not to reshape it.
// (vault.crypto.test.mjs never needed this because vault.ts has no relative imports.)
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
      const candidate = new URL(specifier + ".ts", context.parentURL);
      if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});

// settings.ts touches localStorage at module scope on first read; stub it BEFORE importing (same reason and
// shape as vault.crypto.test.mjs).
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
  clear: () => store.clear(),
};

const {
  SUB_MODE_IDS,
  SAFETY_IDS,
  SUB_FONT_IDS,
  SUB_COLOR_IDS,
  SUB_EDGE_IDS,
  SUB_MIN,
  SUB_MAX,
  canonSubMode,
  canonSafety,
  canonSubFont,
  canonSubColor,
  canonSubEdge,
  canonSubScale,
  canonicalizeSettings,
  getSettings,
} = await import("./settings.ts");

const { mergeWebappSettingsIntoProfile, settingsPatchFromDoc } = await import("./syncSettings.ts");

// MARK: - The app's vocabulary, read out of the real Swift sources.

const APP = join(import.meta.dirname, "..", "..", "..", "app");
const swift = (p) => readFileSync(join(APP, p), "utf8");
const SUBTITLE_STYLE = swift("Sources/Player/SubtitleStyle.swift");
const TRACK_PREFS = swift("Sources/Player/TrackPreferences.swift");
const SOURCE_PREFS = swift("SourcesShared/SourcePreferences.swift");

/** Ids from a `static let NAME: [(id: String, ...)] = [ ("id", "Label"...), ... ]` table: first string of
 *  each tuple. Anchored to the named declaration so an unrelated array cannot satisfy it. */
function swiftTupleIds(src, name) {
  const decl = new RegExp(`static let ${name}[^=]*=\\s*\\[([\\s\\S]*?)\\n\\s*\\]`).exec(src);
  assert.ok(decl, `could not find SubtitleStyle.${name} - did the declaration move or get renamed?`);
  return [...decl[1].matchAll(/\(\s*"([^"]+)"/g)].map((m) => m[1]);
}

/** Ids from a `static let NAME: [String] = ["a", "b"]` array. */
function swiftStringArray(src, name) {
  const decl = new RegExp(`static let ${name}\\s*:\\s*\\[String\\]\\s*=\\s*\\[([^\\]]*)\\]`).exec(src);
  assert.ok(decl, `could not find ${name} - did the declaration move or get renamed?`);
  return [...decl[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

/** Case names of a `enum NAME: String, ...` whose cases take the implicit raw value (case x -> "x"). */
function swiftEnumCases(src, name) {
  const decl = new RegExp(`enum ${name}\\s*:\\s*String[^{]*\\{([\\s\\S]*?)\\n\\s{4}\\}`).exec(src);
  assert.ok(decl, `could not find enum ${name} - did the declaration move or get renamed?`);
  return [...decl[1].matchAll(/^\s*case\s+([a-zA-Z]+)\s*(?:\/\/.*)?$/gm)].map((m) => m[1]);
}

test("parser actually found the app's ids (guards against a regex that silently matches nothing)", () => {
  // If a declaration is renamed, the helpers above assert. But a regex that matches an EMPTY list would let
  // every drift check below pass vacuously, so pin the shape: each list is non-empty and contains a value we
  // know is real. This is the test that keeps the other tests honest.
  assert.ok(swiftTupleIds(SUBTITLE_STYLE, "fonts").includes("modern"));
  assert.ok(swiftTupleIds(SUBTITLE_STYLE, "colors").includes("white"));
  assert.ok(swiftTupleIds(SUBTITLE_STYLE, "backgrounds").includes("outline"));
  assert.ok(swiftStringArray(SOURCE_PREFS, "safetyModes").includes("off"));
  assert.ok(swiftEnumCases(TRACK_PREFS, "ForcedPolicy").includes("forced"));
});

// MARK: - Drift guards. The webapp's vocabulary must EQUAL the app's, exactly.

test("subtitle font ids match SubtitleStyle.fonts", () => {
  assert.deepEqual([...SUB_FONT_IDS], swiftTupleIds(SUBTITLE_STYLE, "fonts"));
});

test("subtitle colour ids match SubtitleStyle.colors", () => {
  assert.deepEqual([...SUB_COLOR_IDS], swiftTupleIds(SUBTITLE_STYLE, "colors"));
});

test("subtitle background ids match SubtitleStyle.backgrounds", () => {
  assert.deepEqual([...SUB_EDGE_IDS], swiftTupleIds(SUBTITLE_STYLE, "backgrounds"));
});

test("safety filter ids match SourcePreferences.safetyModes", () => {
  assert.deepEqual([...SAFETY_IDS], swiftStringArray(SOURCE_PREFS, "safetyModes"));
});

test("subtitles-mode ids match TrackPreferences.ForcedPolicy", () => {
  assert.deepEqual([...SUB_MODE_IDS], swiftEnumCases(TRACK_PREFS, "ForcedPolicy"));
});

test("subtitle scale bounds match SubtitleStyle.sizeScaleRange", () => {
  // `static let sizeScaleRange: ClosedRange<Double> = 0.60...1.80`
  const m = /sizeScaleRange\s*:\s*ClosedRange<Double>\s*=\s*([\d.]+)\s*\.\.\.\s*([\d.]+)/.exec(SUBTITLE_STYLE);
  assert.ok(m, "could not find SubtitleStyle.sizeScaleRange");
  assert.equal(SUB_MIN, Number(m[1]), "web slider floor must equal the app's, or the web re-clamps an app value");
  assert.equal(SUB_MAX, Number(m[2]));
});

// MARK: - The legacy shim. Real accounts already hold these; reading must MIGRATE, never reject.

test("legacy web ids migrate to the user's closest app-side intent", () => {
  assert.equal(canonSafety("moderate"), "balanced");
  assert.equal(canonSubMode("on"), "always");
  assert.equal(canonSubEdge("shadow"), "shaded");
  assert.equal(canonSubEdge("none"), "outline"); // no app equivalent -> row default
  assert.equal(canonSubColor("cyan"), "white"); // no app equivalent -> row default
  assert.equal(canonSubColor("mint"), "white");
  assert.equal(canonSubFont("mono"), "modern");
});

test("canonical app ids pass through untouched", () => {
  for (const id of SAFETY_IDS) assert.equal(canonSafety(id), id);
  for (const id of SUB_MODE_IDS) assert.equal(canonSubMode(id), id);
  for (const id of SUB_FONT_IDS) assert.equal(canonSubFont(id), id);
  for (const id of SUB_COLOR_IDS) assert.equal(canonSubColor(id), id);
  for (const id of SUB_EDGE_IDS) assert.equal(canonSubEdge(id), id);
});

test("unknown values are undefined, not guesses (caller keeps what it had)", () => {
  for (const fn of [canonSafety, canonSubMode, canonSubFont, canonSubColor, canonSubEdge]) {
    assert.equal(fn("nonsense"), undefined);
    assert.equal(fn(""), undefined);
    assert.equal(fn(undefined), undefined);
    assert.equal(fn(null), undefined);
    assert.equal(fn(42), undefined); // a number is not an id; must not become "42"
    assert.equal(fn({}), undefined);
  }
});

test("subtitle scale clamps into the app's range", () => {
  assert.equal(canonSubScale(0.7), 0.7);
  assert.equal(canonSubScale(0.1), SUB_MIN); // below floor
  assert.equal(canonSubScale(9), SUB_MAX); // above ceiling
  assert.equal(canonSubScale(0.6), 0.6); // the app value the old 0.7 web floor could not express
});

// MARK: - The corruption path itself: web -> doc -> app.

test("canonicalizeSettings heals a settings object full of legacy ids", () => {
  const corrupt = {
    ...getSettings(),
    safetyFilter: "moderate",
    subtitlesMode: "on",
    subtitleFont: "mono",
    subtitleColor: "cyan",
    subtitleEdge: "shadow",
    subtitleScale: 0.7,
  };
  const healed = canonicalizeSettings(corrupt);
  assert.equal(healed.safetyFilter, "balanced");
  assert.equal(healed.subtitlesMode, "always");
  assert.equal(healed.subtitleFont, "modern");
  assert.equal(healed.subtitleColor, "white");
  assert.equal(healed.subtitleEdge, "shaded");
});

test("a write-up can never put a foreign id into the account doc", () => {
  // The actual regression that corrupted users: a Settings object holding legacy ids reaching the doc. Even
  // when handed pre-fix values directly, the write path must emit only ids the app can parse.
  const corrupt = {
    ...getSettings(),
    safetyFilter: "moderate",
    subtitlesMode: "on",
    subtitleFont: "mono",
    subtitleColor: "mint",
    subtitleEdge: "none",
    subtitleScale: 42,
  };
  const { playback } = mergeWebappSettingsIntoProfile({}, corrupt);
  assert.ok(SAFETY_IDS.includes(playback.safetyMode), `safetyMode leaked: ${playback.safetyMode}`);
  assert.ok(SUB_MODE_IDS.includes(playback.forced), `forced leaked: ${playback.forced}`);
  assert.ok(SUB_FONT_IDS.includes(playback.subFont), `subFont leaked: ${playback.subFont}`);
  assert.ok(SUB_COLOR_IDS.includes(playback.subColor), `subColor leaked: ${playback.subColor}`);
  assert.ok(SUB_EDGE_IDS.includes(playback.subBackground), `subBackground leaked: ${playback.subBackground}`);
  assert.ok(playback.subSizeScale >= SUB_MIN && playback.subSizeScale <= SUB_MAX);
});

test("write-up preserves app/dashboard keys the webapp does not model", () => {
  // The vocabulary fix must not become a data-loss fix. subSize/isKids are app-owned and web-invisible.
  const existing = { isKids: true, playback: { subSize: "xl", keywordsAreRegex: true } };
  const out = mergeWebappSettingsIntoProfile(existing, getSettings());
  assert.equal(out.isKids, true);
  assert.equal(out.playback.subSize, "xl");
  assert.equal(out.playback.keywordsAreRegex, true);
});

/** A doc in the real shape effectiveMainSettings() reads: the app mirror lives at `vortx.profiles[].settings`,
 *  and the web/dashboard overlay at `profileEdits.roster[]` applies only when it is NEWER than the mirror. */
const docWithPlayback = (playback, { viaOverlay = false } = {}) =>
  viaOverlay
    ? {
        vortx: { updatedAt: 1, profiles: [{ id: "p1", main: true, settings: {} }] },
        profileEdits: { editedAt: 2, roster: [{ id: "p1", settings: { playback } }] },
      }
    : { vortx: { updatedAt: 1, profiles: [{ id: "p1", main: true, settings: { playback } }] } };

const LEGACY_PLAYBACK = { safetyMode: "moderate", forced: "on", subFont: "mono", subColor: "cyan", subBackground: "shadow" };

test("read-down migrates a doc this browser corrupted before the fix (app mirror)", () => {
  // An account whose doc still holds the old web spellings must read back as the user's INTENT, not be
  // dropped (dropping silently reverts a real choice to whatever the browser last had).
  const patch = settingsPatchFromDoc(docWithPlayback(LEGACY_PLAYBACK));
  assert.equal(patch.safetyFilter, "balanced");
  assert.equal(patch.subtitlesMode, "always");
  assert.equal(patch.subtitleFont, "modern");
  assert.equal(patch.subtitleColor, "white");
  assert.equal(patch.subtitleEdge, "shaded");
});

test("read-down migrates legacy ids arriving via the profileEdits overlay too", () => {
  // The overlay is the path the webapp's OWN past writes came back through, so it is the likeliest place a
  // corrupted value actually sits on a real account.
  const patch = settingsPatchFromDoc(docWithPlayback(LEGACY_PLAYBACK, { viaOverlay: true }));
  assert.equal(patch.safetyFilter, "balanced");
  assert.equal(patch.subtitlesMode, "always");
  assert.equal(patch.subtitleEdge, "shaded");
});

test("read-down leaves unknown junk alone rather than inventing a value", () => {
  const patch = settingsPatchFromDoc(docWithPlayback({ safetyMode: "wat", subColor: "puce" }));
  assert.equal(patch.safetyFilter, undefined);
  assert.equal(patch.subtitleColor, undefined);
});
