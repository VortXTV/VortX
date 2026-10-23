import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { projectNativeSync } from "./nativeSyncProjection.ts";
const fixture = JSON.parse(readFileSync(new URL("./fixtures/native-sync-carrier.json", import.meta.url), "utf8"));
function account() {
  const doc = structuredClone(fixture.cases[0].document), native = doc.nativeSync, owner = native.ownerProfileId;
  native.libraries[owner] = { records: {}, order: { updatedAt: 1, ids: [] } };
  native.watches[owner] = { log: {}, contexts: {} };
  return { doc, owner, library: native.libraries[owner], watch: native.watches[owner] };
}
function save(library, id, type, name, removed = false) {
  const identity = type + ":" + id;
  library.records[identity] = { addedAt: 5, removedAt: removed ? 6 : 0, valueAt: 5,
    value: { kind: "standard", id, type, name, extension: { untouched: true } } };
  library.order.ids.push(identity);
}
test("all native fixture outputs retain their complete pre-index projection", () => {
  const output = [...fixture.cases, ...fixture.edgeCases, ...fixture.ownSlotCases].map((item) => projectNativeSync(item.document));
  assert.equal(createHash("sha256").update(JSON.stringify(output)).digest("hex"), "1e92b42402e214ad7f424eabba925af603d45519eb505e4da15c80604c800da8");
});
test("missing context lookups enumerate the context collection once per projection", () => {
  const { doc, owner, library, watch } = account();
  for (let i = 0; i < 1200; i++) {
    save(library, "tt" + i, "series", "Title " + i);
    watch.log["tt" + i + ":1:1"] = { resume_ms: i, resume_at: i + 1 };
    watch.contexts["unused:" + i] = { metaId: "unused:" + i };
  }
  const original = JSON.stringify(doc);
  let enumerations = 0;
  watch.contexts = new Proxy(watch.contexts, { ownKeys(target) { enumerations++; return Reflect.ownKeys(target); } });
  const projection = projectNativeSync(doc);
  assert.ok(enumerations <= 4, "context scans must be bounded independently of watch log size: " + enumerations);
  assert.equal(projection.libraryByProfile[owner].length, 1200);
  assert.deepEqual(projection.continueByProfile[owner].map((row) => row.id),
    Array.from({ length: 30 }, (_, i) => "tt" + (1199 - i)));
  assert.equal(JSON.stringify(doc), original, "projection retains all input bytes and unknown extensions");
});
test("prefix and canonical lookup indexes preserve longest title and first saved descriptor", () => {
  const { doc, owner, library, watch } = account();
  save(library, "x", "series", "Short");
  save(library, "x:10", "movie", "First");
  save(library, "x:10", "series", "Second");
  save(library, "removed", "movie", "Gone", true);
  watch.log["x:10:1:2"] = { resume_ms: 7, resume_at: 9 };
  watch.contexts.unused = [];
  const original = JSON.stringify(doc), projection = projectNativeSync(doc);
  assert.deepEqual(projection.continueByProfile[owner].map(({ id, name, t, d }) => ({ id, name, t, d })),
    [{ id: "x:10", name: "First", t: 7, d: 0 }]);
  assert.deepEqual(projection.libraryByProfile[owner].map((row) => row.name), ["Short", "First", "Second"]);
  assert.equal(JSON.stringify(doc), original);
});
test("aliased fallback metadata, direct context precedence and title tombstones remain exact", () => {
  const { doc, owner, watch } = account();
  watch.identityLinks = [["tt123", "tmdb:123", "themoviedb:123"]];
  watch.log["themoviedb:123:1:1"] = { resume_ms: 7, resume_at: 9 };
  watch.contexts["tt123:1:1"] = { metaId: "tt123", name: "Alpha", updatedAt: 4, durationMs: 10 };
  watch.contexts["tmdb:123:1:1"] = { metaId: "tt123", name: "Zeta", updatedAt: 4, durationMs: 10 };
  assert.equal(projectNativeSync(doc).continueByProfile[owner][0].name, "Zeta");
  watch.contexts["themoviedb:123:1:1"] = { metaId: "tt123", name: "Direct", updatedAt: 0, durationMs: 10 };
  assert.equal(projectNativeSync(doc).continueByProfile[owner][0].name, "Direct");
  watch.log.tt123 = { removed_at: 10 };
  watch.contexts.tt123 = { metaId: "tt123", name: "Title", durationMs: 10 };
  assert.deepEqual(projectNativeSync(doc).continueByProfile[owner] ?? [], []);
});
test("colon-heavy fallback identifiers cannot amplify prefix hashing beyond saved input", () => {
  for (const hasSavedTitle of [false, true]) {
    const { doc, owner, library, watch } = account();
    if (hasSavedTitle) save(library, "tt7", "series", "Short");
    const key = "audit" + ":".repeat(20_000) + "suffix";
    watch.log[key] = { resume_ms: 7, resume_at: 9 };
    const original = Set.prototype.has;
    let probedBytes = 0;
    Set.prototype.has = function (value) {
      if (typeof value === "string") probedBytes += value.length;
      return original.call(this, value);
    };
    let projection;
    try { projection = projectNativeSync(doc); } finally { Set.prototype.has = original; }
    assert.equal(projection.continueByProfile[owner][0].id, key);
    assert.ok(probedBytes < 1_000, "prefix hash bytes must depend on saved title lengths, not every colon: " + probedBytes);
  }
});
