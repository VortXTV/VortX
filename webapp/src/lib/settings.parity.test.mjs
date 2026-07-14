// Behavioral parity tests for the Apple<->web settings bridge, exercising the REAL functions from
// syncSettings.ts + streamRanking.ts (Node 26 strips the TS types on import). Run: `node --test`.
// Pins the 4K max-quality encoding: the app stores its Max-quality cap as 4000 (a 2160p token parses to a
// 4000 score, and the cap compares against that), while the Min-quality floor stays 2160 (raw height).
// Covers: legacy 2160 read normalizes to 4000, 4000 writes back, odd values are ignored, a 540p source is
// KNOWN, and a 2160p source passes an "Up to 4K" cap but is hidden by an "Up to 1080p" cap.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

// The source uses bundler-style extensionless relative imports (`./settings`), which Node's ESM loader
// won't resolve to a `.ts` file on its own. Register a tiny resolve hook that appends `.ts` for
// extensionless relative specifiers, so the REAL modules (and their transitive imports) load under
// `node --test`. Runs before the dynamic imports below.
registerHooks({
  resolve(spec, ctx, next) {
    if (/^\.\.?\//.test(spec) && !/\.[cm]?[jt]s$/.test(spec)) {
      try {
        return next(spec + ".ts", ctx);
      } catch {
        // fall through to the default resolution below
      }
    }
    return next(spec, ctx);
  },
});

// syncSettings.ts -> settings.ts uses localStorage lazily; stub it so an accidental read never throws.
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
  clear: () => store.clear(),
};

const { settingsPatchFromDoc, mergeWebappSettingsIntoProfile } = await import("./syncSettings.ts");
const { applyStreamFilters, resolutionOf } = await import("./streamRanking.ts");

/** A synced-doc whose main profile carries the given playback knobs. */
const docWith = (playback) => ({
  vortx: { profiles: [{ id: "main", main: true, settings: { playback } }] },
});

/** A complete web Settings object with the given overrides (only the fields filters read matter here). */
const settingsWith = (over) => ({
  accentID: "vortx", background: "warm", textScale: 1, audioLang: "", subtitleLang: "",
  subtitlesMode: "on", autoplayTrailers: true, mdblistKey: "", subtitleScale: 1,
  subtitleBackground: true, preferredQuality: 0, tmdbKey: "", directLinksOnly: false, skipStep: 10,
  episodeAlerts: false, useAddonOrder: false, sourceOrder: ["debrid", "usenet", "torrent", "direct"],
  safetyFilter: "off", hideWords: "", requireWords: "", instantOnly: false, hideDeadTorrents: false,
  hdrOnly: false, hideAV1: false, maxQuality: 0, minQuality: 0, hideUnknownResolution: false,
  preferredAudioOnly: false, maxFileSizeGB: 0, performance: "auto", subtitleFont: "modern",
  subtitleColor: "white", subtitleEdge: "outline", ...over,
});

const stream = (name) => ({ url: "https://cdn.example/x.mp4", name });
const group = (streams) => [{ addonName: "Test", transportUrl: "https://addon/", streams }];

test("read-down: legacy 2160 max cap normalizes to the app's 4000 4K tag", () => {
  assert.equal(settingsPatchFromDoc(docWith({ maxResolution: 2160 })).maxQuality, 4000);
});

test("read-down: 4000 max cap reads straight through as 4K", () => {
  assert.equal(settingsPatchFromDoc(docWith({ maxResolution: 4000 })).maxQuality, 4000);
});

test("read-down: 1080/720 max caps read through unchanged", () => {
  assert.equal(settingsPatchFromDoc(docWith({ maxResolution: 1080 })).maxQuality, 1080);
  assert.equal(settingsPatchFromDoc(docWith({ maxResolution: 720 })).maxQuality, 720);
});

test("read-down: an illegal max cap (1440) is ignored, not applied", () => {
  assert.equal("maxQuality" in settingsPatchFromDoc(docWith({ maxResolution: 1440 })), false);
});

test("read-down: min floor 4K stays 2160 (raw height), and an odd floor is ignored", () => {
  assert.equal(settingsPatchFromDoc(docWith({ minResolution: 2160 })).minQuality, 2160);
  assert.equal("minQuality" in settingsPatchFromDoc(docWith({ minResolution: 999 })), false);
});

test("write-up: a 4K cap writes maxResolution 4000 into the profile playback", () => {
  const out = mergeWebappSettingsIntoProfile({}, settingsWith({ maxQuality: 4000 }));
  assert.equal(out.playback.maxResolution, 4000);
});

test("parse: a 540p-labelled source is now a KNOWN resolution", () => {
  assert.equal(resolutionOf(stream("Movie.2023.540p.WEB-DL")), 540);
});

test("filter: a 2160p source passes an Up-to-4K cap but is hidden by an Up-to-1080p cap", () => {
  const g = group([stream("Movie.2023.2160p.WEB-DL")]);
  const passed = applyStreamFilters(g, settingsWith({ maxQuality: 4000 }));
  assert.equal(passed[0].streams.length, 1, "4K source passes the 4K cap");
  const hidden = applyStreamFilters(g, settingsWith({ maxQuality: 1080 }));
  assert.equal(hidden[0].streams.length, 0, "4K source is dropped by the 1080p cap");
});
