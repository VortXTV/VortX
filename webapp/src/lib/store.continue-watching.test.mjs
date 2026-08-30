import { test } from "node:test";
import assert from "node:assert/strict";
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

const values = new Map();
globalThis.localStorage = {
  getItem: (key) => (values.has(key) ? values.get(key) : null),
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
  clear: () => values.clear(),
};
globalThis.document = {
  documentElement: {
    dataset: {},
    style: { setProperty() {}, removeProperty() {} },
  },
};
globalThis.window = new EventTarget();
globalThis.matchMedia = () => ({ matches: false });

const look = {
  accentID: "vortx",
  background: "warm",
  textScale: 1,
  audioLang: "en",
  subtitleLang: "en",
  subtitlesMode: "always",
};
values.set(
  "vortx.web.profiles.v1",
  JSON.stringify([
    { id: "owner", name: "Owner", avatar: "🦊", look },
    { id: "overlay", name: "Overlay", avatar: "🐼", look },
  ]),
);
values.set("vortx.web.activeProfile.v1", "owner");

const { setActiveProfile } = await import("./profiles.ts");
const {
  clearProgress,
  continueWatching,
  exportBackup,
  importBackup,
  mergeContinueWatching,
  recordProgress,
} = await import("./store.ts");

const entry = (patch = {}) => ({
  id: "tmdb:1396",
  type: "series",
  name: "Breaking Bad",
  poster: "https://img/current.jpg",
  resumeId: "tt0903747:5:16",
  position: 1200,
  duration: 2700,
  updatedAt: 200,
  ...patch,
});

const clearCW = () => {
  for (const key of [...values.keys()]) {
    if (key.startsWith("vortx.web.cw.")) values.delete(key);
  }
  values.set("vortx.web.activeProfile.v1", "owner");
};

test("web Continue Watching rejects zero duration and tombstones the exact finish boundary", () => {
  clearCW();
  recordProgress(entry(), 10, 0);
  assert.deepEqual(continueWatching(), [], "zero duration is never valid progress");

  recordProgress(entry(), 100, 200);
  assert.equal(continueWatching().length, 1, "in-progress playback is retained");
  recordProgress(entry(), 190, 200);
  assert.deepEqual(continueWatching(), [], "exactly 95% is finished");
  assert.equal(
    mergeContinueWatching([entry({ position: 100, duration: 200, updatedAt: 0 })]),
    false,
    "stale hydration cannot resurrect a finished row",
  );
});

test("backup validates and restores timestamped Continue Watching removals", () => {
  clearCW();
  const tombstones = [{ keys: ["id:series:imdb:tt0903747"], removedAt: 1234 }];
  values.set("vortx.web.cw.removed.v1", JSON.stringify(tombstones));
  const backup = exportBackup();
  values.delete("vortx.web.cw.removed.v1");
  assert.equal(importBackup(backup), true);
  assert.deepEqual(JSON.parse(values.get("vortx.web.cw.removed.v1")), tombstones);

  const malformed = JSON.parse(backup);
  malformed.data["vortx.web.cw.removed.v1"] = [{ keys: [7], removedAt: "now" }];
  values.set("sentinel", "preserved");
  assert.equal(importBackup(JSON.stringify(malformed)), false, "malformed tombstones reject the whole restore");
  assert.equal(values.get("sentinel"), "preserved");
});

test("web Continue Watching keeps alias removal and profile boundaries durable", () => {
  clearCW();
  values.set(
    "vortx.web.cw.v1",
    JSON.stringify([
      entry(),
      entry({
        id: "imdb:tt0903747",
        poster: "https://img/old.jpg",
        resumeId: "tt0903747:5:15",
        updatedAt: 100,
      }),
    ]),
  );
  assert.deepEqual(continueWatching().map((item) => item.id), ["tmdb:1396"], "owner aliases render once");

  clearProgress("tmdb:1396");
  assert.deepEqual(continueWatching(), [], "explicit removal clears the whole alias component");
  assert.equal(
    mergeContinueWatching([entry({ id: "imdb:tt0903747", updatedAt: 150 })]),
    false,
    "stale account hydration cannot resurrect a tombstoned alias",
  );

  const rewatchAt = Date.now() + 1000;
  assert.equal(
    mergeContinueWatching([entry({ id: "imdb:tt0903747", updatedAt: rewatchAt, position: 60 })]),
    true,
    "newer playback explicitly re-adds the title",
  );
  assert.deepEqual(continueWatching().map((item) => item.id), ["imdb:tt0903747"]);

  values.set("vortx.web.cw.v1.overlay", JSON.stringify([entry({ id: "tt7654321", resumeId: "tt7654321:1:1" })]));
  setActiveProfile("overlay");
  assert.deepEqual(continueWatching().map((item) => item.id), ["tt7654321"], "overlay reads only its scope");
  clearProgress("tt7654321");
  assert.deepEqual(continueWatching(), [], "overlay removal applies only to the overlay scope");

  setActiveProfile("owner");
  assert.deepEqual(
    continueWatching().map((item) => item.id),
    ["imdb:tt0903747"],
    "switching back restores the untouched owner rail",
  );
  assert.ok(values.has("vortx.web.cw.removed.v1"));
  assert.ok(values.has("vortx.web.cw.removed.v1.overlay"));
});
