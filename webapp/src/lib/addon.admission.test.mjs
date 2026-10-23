import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
    const candidate = new URL(specifier + ".ts", context.parentURL);
    if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
  }
  return next(specifier, context);
} });
const stored = new Map();
globalThis.localStorage = { getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, String(value)), removeItem: (key) => stored.delete(key) };
const { loadAddon, catalogRefs, supportsResource } = await import("./addon.ts");
const { addAddon } = await import("./store.ts");
const base = { id: "synthetic", name: "Synthetic" };
const respond = (manifest) => { globalThis.fetch = async () => new Response(JSON.stringify(manifest), { status: 200 }); };

test("malformed known manifest fields fail admission before catalog/resource code can consume them", async () => {
  const invalid = [
    null, [], "manifest", { id: "missing-name" }, { ...base, name: 7 }, { ...base, version: null },
    { ...base, types: {} }, { ...base, types: [1] },
    { ...base, resources: { catalog: true } }, { ...base, resources: [null] }, { ...base, resources: [1] },
    { ...base, resources: [{ name: null }] }, { ...base, resources: [{ name: "catalog", types: "movie" }] },
    { ...base, resources: [{ name: "meta", idPrefixes: [1] }] },
    { ...base, catalogs: {} }, { ...base, catalogs: [null] }, { ...base, catalogs: [{ type: "movie", id: 1 }] },
    { ...base, catalogs: [{ type: "movie", id: "top", name: 7 }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extra: {} }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extra: [null] }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extra: [{ name: "search", isRequired: "yes" }] }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extra: [{ name: "genre", options: "Drama" }] }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extra: [{ name: "genre", optionsLimit: 1.5 }] }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extraSupported: {} }] },
    { ...base, catalogs: [{ type: "movie", id: "top", extraRequired: [7] }] },
  ];
  for (const [index, manifest] of invalid.entries()) {
    respond(manifest);
    await assert.rejects(loadAddon("https://synthetic.test/manifest.json"), /Not a valid add-on manifest/, `malformed fixture ${index}`);
  }
});

test("minimal optional/default fields remain admitted without rewriting the returned manifest", async () => {
  respond(base); const addon = await loadAddon("https://synthetic.test/manifest.json");
  assert.deepEqual(addon.manifest, base); assert.equal("version" in addon.manifest, false);
  assert.deepEqual(catalogRefs([addon]), []); assert.equal(supportsResource(addon, "catalog"), false);
});

test("valid resource/catalog DTOs retain documented nulls, unknown extensions and configured URL identity", async () => {
  const manifest = {
    ...base, version: "1.0.0", types: ["movie"], idPrefixes: null, description: null,
    resources: ["catalog", { name: "meta", types: ["movie"], idPrefixes: null, futureResource: { retained: true } }],
    catalogs: [{ type: "movie", id: "top", name: null, extraSupported: null, extraRequired: null,
      extra: [{ name: "genre", isRequired: false, options: null, optionsLimit: null, futureExtra: ["retained"] }], futureCatalog: { retained: true } }],
    behaviorHints: { configurable: true, futureHint: "retained" }, futureManifest: { retained: [null, 1, "value"] },
  };
  let requested; globalThis.fetch = async (url) => { requested = url; return new Response(JSON.stringify(manifest), { status: 200 }); };
  const expected = "https://EXAMPLE.test/SecretCase/manifest.json?config=Case%2BValue";
  const addon = await loadAddon("stremio://EXAMPLE.test/SecretCase/manifest.json?config=Case%2BValue");
  assert.equal(requested, expected); assert.equal(addon.transportUrl, expected);
  assert.deepEqual(addon.manifest, manifest); assert.equal(catalogRefs([addon]).length, 1);
  assert.equal(supportsResource(addon, "meta", "movie", "tt1"), true);
});

test("the real installation path rejects a malformed manifest without persisting any add-on", async () => {
  stored.clear(); respond({ ...base, resources: { catalog: true } });
  await assert.rejects(addAddon("https://synthetic.test/manifest.json"), /Not a valid add-on manifest/);
  assert.equal(stored.size, 0);
});
