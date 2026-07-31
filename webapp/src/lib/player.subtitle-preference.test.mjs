import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
      const candidate = new URL(specifier + ".ts", context.parentURL);
      if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});

const values = new Map([
  [
    "vortx.web.settings.v1",
    JSON.stringify({
      subtitleLang: "fr",
      subtitlesMode: "always",
    }),
  ],
]);
globalThis.localStorage = {
  getItem: (key) => (values.has(key) ? values.get(key) : null),
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
  clear: () => values.clear(),
};

const createdTracks = [];
globalThis.document = {
  createElement(tag) {
    assert.equal(tag, "track");
    const element = {
      kind: "",
      srclang: "",
      label: "",
      src: "",
      track: { language: "", mode: "disabled" },
    };
    createdTracks.push(element);
    return element;
  },
};
globalThis.fetch = async () =>
  new Response("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n", {
    status: 200,
    headers: { "content-type": "text/vtt" },
  });

const player = await import("./player.ts");

test("real subtitle append path shows the persisted preferred language", async () => {
  const video = {
    appendChild(track) {
      track.track.language = track.srclang;
    },
  };

  assert.equal(typeof player.__playerTestHooks?.addSubtitleTracks, "function");
  await player.__playerTestHooks.addSubtitleTracks(video, [
    { lang: "en", url: "https://example.test/en.vtt" },
    { lang: "fr", url: "https://example.test/fr.vtt" },
  ]);

  assert.deepEqual(
    createdTracks.map((track) => track.track.mode),
    ["disabled", "showing"],
  );
});

test("mode policy disables all tracks when off and only always falls back", () => {
  const apply = player.__playerTestHooks?.applySubtitlePreference;
  assert.equal(typeof apply, "function");

  const off = [
    { language: "en", mode: "showing" },
    { language: "fr", mode: "showing" },
  ];
  apply(off, "off", "fr");
  assert.deepEqual(off.map((track) => track.mode), ["disabled", "disabled"]);

  const forced = [
    { language: "en", mode: "disabled" },
    { language: "fr", mode: "disabled" },
  ];
  apply(forced, "forced", "fr");
  assert.deepEqual(forced.map((track) => track.mode), ["disabled", "disabled"]);

  const always = [
    { language: "en", mode: "disabled" },
    { language: "fr", mode: "disabled" },
  ];
  apply(always, "always", "de");
  assert.deepEqual(always.map((track) => track.mode), ["showing", "disabled"]);
});
