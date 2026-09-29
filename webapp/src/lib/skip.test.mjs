import test from "node:test";
import assert from "node:assert/strict";
import { normaliseSkipSegments, skipLabel, fetchSkipSegments } from "./skip.ts";

const live = {
  intro: { start_ms: 448000, end_ms: 461000 },
  outro: { start_ms: 3630000, end_ms: 3699000 },
  recap: { start_ms: 0, end_ms: 59000 },
};
test("live worker object-map and milliseconds survive normalisation", () => {
  assert.deepEqual(normaliseSkipSegments(live), [
    { kind: "intro", start: 448, end: 461 },
    { kind: "credits", start: 3630, end: 3699 },
    { kind: "recap", start: 0, end: 59 },
  ]);
});
test("provider aliases retain all four kinds without guessing unknowns", () => {
  const labels = ["op", "ed", "previously", "next episode", "opening", "credits", "unknown", "post_credit"];
  assert.deepEqual(normaliseSkipSegments(labels.map(type => ({ type, start: 1, end: 2 }))).map(s => s.kind),
    ["intro", "credits", "recap", "preview", "intro", "credits"]);
  assert.deepEqual(["intro", "recap", "credits", "preview"].map(skipLabel),
    ["Skip Intro", "Skip Recap", "Skip Credits", "Skip Preview"]);
});
test("malformed neighbours, unknown types and nonfinite spans are rejected individually", () => {
  assert.deepEqual(normaliseSkipSegments([
    null, 8, [], { type: 1, start: 0, end: 1 }, { type: "intro", start: -1, end: 2 },
    { type: "intro", start: NaN, end: 2 }, { type: "credits", start: 1, end: Infinity },
    { type: "recap", start: 3, end: 2 }, { type: "intro", start: 0, end: 1 },
  ]), [{ kind: "intro", start: 0, end: 1 }]);
  for (const value of [undefined, null, 9, "invalid"]) assert.deepEqual(normaliseSkipSegments(value), []);
});
test("actual fetch accepts the live schema and remains fail soft", async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async (url, options) => {
      assert.equal(url, "https://skip.vortx.tv/skip?key=imdb%3Att0944947%3A1%3A1");
      assert.ok(options.signal);
      return { ok: true, json: async () => ({ segments: live }) };
    };
    assert.equal((await fetchSkipSegments("tt0944947", 1, 1)).length, 3);
    globalThis.fetch = async () => { throw new Error("offline"); };
    assert.deepEqual(await fetchSkipSegments("tt0944947"), []);
    assert.deepEqual(await fetchSkipSegments("kitsu:42"), []);
  } finally { globalThis.fetch = original; }
});
