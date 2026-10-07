import { test } from "node:test";
import assert from "node:assert/strict";
import { effectiveAddonRemovals, applyAddonIntents } from "./addonRemovals.ts";

const url = "https://example.invalid/addon/manifest.json";
const fold = (doc) => [...effectiveAddonRemovals(doc)];
test("older reinstall cannot erase newer numeric website removal, including case aliases", () => {
  const doc = { removedAddons: { [url.toUpperCase()]: 500 }, vortx: {
    deletedAddonsTs: { [url]: { removedAt: 100, futureField: "retained" } } } };
  applyAddonIntents(doc, { added: [url] }, 200);
  assert.deepEqual(fold(doc), [url]);
  assert.deepEqual(doc.vortx.deletedAddonsTs[url], { removedAt: 500, addedAt: 200, futureField: "retained" });
});
test("website reinstall publishes addedAt so all surfaces retire an Apple removal", () => {
  const doc = { removedAddons: { [url.toUpperCase()]: 100 }, webAddonRemovals: [url],
    vortx: { deletedAddons: [url], deletedAddonsTs: { [url.toUpperCase()]: { removedAt: 100 } } } };
  applyAddonIntents(doc, { added: [url] }, 200);
  assert.deepEqual(fold(doc), []);
  assert.deepEqual(doc.vortx.deletedAddons, []);
  assert.deepEqual(doc.webAddonRemovals, []);
  assert.deepEqual(doc.vortx.deletedAddonsTs[url], { removedAt: 100, addedAt: 200 });
  applyAddonIntents(doc, { removed: [url] }, 300);
  assert.deepEqual(fold(doc), [url]);
  assert.deepEqual(doc.vortx.deletedAddonsTs[url], { removedAt: 300, addedAt: 200 });
});
test("explicit intents preserve newer peer stamps; absent hints never mutate", () => {
  const doc = { vortx: { deletedAddonsTs: { [url]: { addedAt: 400, removedAt: 100 } } } };
  applyAddonIntents(doc, { removed: [url] }, 300);
  assert.deepEqual(fold(doc), []);
  const snapshot = structuredClone(doc);
  applyAddonIntents(doc, undefined, 900);
  assert.deepEqual(doc, snapshot);
});
test("new Apple reinstall defeats old website and flat removal receipts", () => {
  assert.deepEqual(fold({ removedAddons: { [url]: 100 }, webAddonRemovals: [url],
    vortx: { deletedAddons: [url], deletedAddonsTs: { [url]: { removedAt: 100, addedAt: 200 } } } }), []);
});
test("new website removal still defeats an earlier Apple install", () => {
  assert.deepEqual(fold({ removedAddons: { [url]: 300 }, vortx: {
    deletedAddonsTs: { [url]: { removedAt: 100, addedAt: 200 } } } }), [url]);
});
test("stamp-only removals apply; equal stamps favor the reinstall", () => {
  assert.deepEqual(fold({ vortx: { deletedAddonsTs: { [url]: { removedAt: 300 } } } }), [url]);
  assert.deepEqual(fold({ vortx: { deletedAddonsTs: { [url]: { removedAt: 300, addedAt: 300 } } } }), []);
});
test("legacy removals remain effective without fabricated freshness", () => {
  assert.deepEqual(fold({ webAddonRemovals: [url], vortx: { deletedAddons: [url] } }), [url]);
  assert.deepEqual(fold({ webAddonRemovals: [url], vortx: {
    deletedAddonsTs: { [url]: { addedAt: 2 } } } }), []);
});
test("malformed stamps cannot mask legacy removal and URL identity is normalized", () => {
  assert.deepEqual(fold({ vortx: { deletedAddons: [url.toUpperCase()],
    deletedAddonsTs: { [url]: { removedAt: NaN, addedAt: "200" } } } }), [url]);
  assert.deepEqual(fold({ removedAddons: { [url.toUpperCase()]: 100 }, vortx: {
    deletedAddonsTs: { [` ${url} `]: { addedAt: 200 } } } }), []);
  assert.deepEqual(fold({ removedAddons: [], vortx: null, webAddonRemovals: {} }), []);
});
