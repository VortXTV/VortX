import assert from "node:assert/strict";
import { createHash, createHmac, webcrypto } from "node:crypto";
import { test } from "node:test";

import worker, { FeedCoordinator } from "../src/index.js";

globalThis.crypto ??= webcrypto;

const TAG = "v0.3.14-beta.19";
const BUILD = 221;
const SECRET = "release-feed-test-secret";
const COMMIT = "a".repeat(40);

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}

function asset(tag, slug, extension, checksumName, byte, assetId) {
  const name = `VortX-${slug}-${tag}-ci.${extension}`;
  const url = `https://github.com/VortXTV/VortX/releases/download/${tag}/${name}`;
  return { name, checksumName, url, size: byte.length, sha256: sha256(byte), state: "uploaded", assetId };
}

function makeReceipt({ releaseId = "19", build = BUILD, tag = TAG } = {}) {
  const version = tag.replace(/^v/, "").replace(/-.*/, "");
  const prerelease = tag.includes("-");
  const releaseName = prerelease ? "Beta 19" : `VortX ${version}`;
  const assets = {
    ios: asset(tag, "iOS", "ipa", "VortX-iOS-ci.ipa", "ios-bytes", 11),
    tvos: asset(tag, "tvOS", "ipa", "VortX-tvOS-ci.ipa", "tvos-bytes", 12),
    tvosLite: asset(tag, "tvOS-lite", "ipa", "VortX-tvOS-lite-ci.ipa", "lite-bytes", 13),
    mac: asset(tag, "macOS", "dmg", "VortX-macOS-ci.dmg", "mac-bytes", 14),
  };
  const note = "Verified release notes.";
  const source = {
    name: "VortX",
    identifier: "tv.vortx.altstore",
    apps: [
      {
        name: "VortX",
        bundleIdentifier: "com.stremiox.app.native",
        versions: [{ version, buildVersion: String(build), date: "2026-08-20", localizedDescription: note, downloadURL: assets.ios.url, size: assets.ios.size, sha256: assets.ios.sha256, minOSVersion: "16.0" }],
      },
      {
        name: "VortX (Apple TV)",
        bundleIdentifier: "com.stremiox.tv",
        versions: [{ version, buildVersion: String(build), date: "2026-08-20", localizedDescription: note, downloadURL: assets.tvos.url, size: assets.tvos.size, sha256: assets.tvos.sha256, minOSVersion: "18.0" }],
      },
    ],
  };
  const sourceText = `${JSON.stringify(source, null, 2)}\n`;
  const appcast = {
    schemaVersion: 2,
    _generatedFromTag: tag,
    _generatedFromCommit: COMMIT,
    ios: { tag, version, build, name: releaseName, notes: note, prerelease, ipa: assets.ios.url, url: assets.ios.url, size: assets.ios.size, sha256: assets.ios.sha256, altstore: "https://vortx.tv/altstore.json", artifactType: "ipa" },
    tvos: { tag, version, build, name: releaseName, notes: note, prerelease, ipa: assets.tvos.url, url: assets.tvos.url, size: assets.tvos.size, sha256: assets.tvos.sha256, altstore: null, artifactType: "ipa" },
    mac: { tag, version, build, name: releaseName, notes: note, prerelease, ipa: assets.mac.url, url: assets.mac.url, size: assets.mac.size, sha256: assets.mac.sha256, altstore: null, artifactType: "dmg" },
    android: null,
  };
  const appcastText = `${JSON.stringify(appcast, null, 2)}\n`;
  const checksum = Object.values(assets).map((entry) => `${entry.sha256}  out/${entry.checksumName}`).join("\n") + "\n";
  const feedSha256 = sha256(`${sourceText}\n${appcastText}\n${checksum}`);
  const manifest = {
    schemaVersion: 2,
    tag,
    build,
    version,
    name: releaseName,
    notes: note,
    prerelease,
    sourceCommit: COMMIT,
    releaseId,
    generation: `${tag}:${build}:${feedSha256}`,
    feedSha256,
    sourceSha256: sha256(sourceText),
    appcastSha256: sha256(appcastText),
    checksumSha256: sha256(checksum),
    assets,
    android: null,
  };
  return { action: "stage", ...manifest, manifest, source: sourceText, appcast: appcastText, checksum };
}

class MemoryKV {
  constructor() { this.values = new Map(); }
  async get(key, options) {
    const value = this.values.get(key);
    if (value === undefined) return null;
    return options?.type === "json" ? JSON.parse(value) : value;
  }
  async put(key, value) { this.values.set(key, value); }
  async delete(key) { this.values.delete(key); }
}

class MemoryStorage {
  constructor() { this.values = new Map(); this.tail = Promise.resolve(); }
  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { this.values.delete(key); }
  transaction(callback) {
    const result = this.tail.then(() => callback(this));
    this.tail = result.catch(() => undefined);
    return result;
  }
}

function environment(kv, extra = {}) {
  const env = { RELEASE_FEED_RECEIPT_SECRET: SECRET, LEGACY_LASTGOOD: kv, ...extra };
  const state = { storage: new MemoryStorage() };
  env.COORDINATOR = {
    idFromName: () => "release-feed",
    get: () => ({ fetch: (request) => new FeedCoordinator(state, env).fetch(request) }),
  };
  env.__state = state;
  return env;
}

function signedRequest(path, payload) {
  const body = JSON.stringify(payload);
  const signature = createHmac("sha256", SECRET).update(body).digest("hex");
  return new Request(`https://vortx.tv${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-vortx-receipt": `sha256=${signature}` },
    body,
  });
}

test("staging, promotion, exact bytes, query invariance, and rollback are fail-closed", async () => {
  const kv = new MemoryKV();
  const env = environment(kv);
  const receipt = makeReceipt();
  const staged = await worker.fetch(signedRequest("/__release/receipt", receipt), env);
  assert.equal(staged.status, 200, await staged.text());
  const generation = receipt.manifest.generation;
  const promoted = await worker.fetch(signedRequest("/__release/receipt", { action: "promote", operationId: "initial-promote", releaseId: "19", generation, expectedActiveGeneration: null }), env);
  assert.equal(promoted.status, 200);
  for (const path of ["/altstore.json", "/vortx-altstore.json", "/appcast.json"]) {
    const response = await worker.fetch(new Request(`https://vortx.tv${path}?cache-bust=old`), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(response.headers.get("cache-control"), "public, max-age=120, s-maxage=120, must-revalidate");
    assert.equal(response.headers.get("x-vortx-feed-generation"), generation);
  }
  const conflict = await worker.fetch(signedRequest("/__release/receipt", { action: "promote", operationId: "wrong-promote", releaseId: "19", generation, expectedActiveGeneration: "wrong" }), env);
  assert.equal(conflict.status, 409);
  const rolledBack = await worker.fetch(signedRequest("/__release/receipt", { action: "rollback", expectedCurrentGeneration: generation, restoreGeneration: "none" }), env);
  assert.equal(rolledBack.status, 200);
  const unavailable = await worker.fetch(new Request("https://vortx.tv/altstore.json"), env);
  assert.equal(unavailable.status, 503);
});

test("stable and prerelease receipts require tag-matching prerelease state", async () => {
  const stableEnv = environment(new MemoryKV());
  const stable = makeReceipt({ releaseId: "315", build: 233, tag: "v0.3.15" });
  assert.equal(stable.manifest.prerelease, false);
  const stableResponse = await worker.fetch(signedRequest("/__release/receipt", stable), stableEnv);
  assert.equal(stableResponse.status, 200, await stableResponse.text());

  const stableMismatch = makeReceipt({ releaseId: "316", build: 234, tag: "v0.3.16" });
  stableMismatch.manifest.prerelease = true;
  const stableMismatchResponse = await worker.fetch(
    signedRequest("/__release/receipt", stableMismatch),
    environment(new MemoryKV()),
  );
  assert.equal(stableMismatchResponse.status, 503);

  const prereleaseMismatch = makeReceipt();
  prereleaseMismatch.manifest.prerelease = false;
  const prereleaseMismatchResponse = await worker.fetch(
    signedRequest("/__release/receipt", prereleaseMismatch),
    environment(new MemoryKV()),
  );
  assert.equal(prereleaseMismatchResponse.status, 503);
});

test("feed routes answer HEAD with GET metadata and honor If-None-Match with 304", async () => {
  const kv = new MemoryKV();
  const env = environment(kv);
  const receipt = makeReceipt();
  const staged = await worker.fetch(signedRequest("/__release/receipt", receipt), env);
  assert.equal(staged.status, 200, await staged.text());
  const generation = receipt.manifest.generation;
  const promoted = await worker.fetch(signedRequest("/__release/receipt", { action: "promote", operationId: "head-promote", releaseId: "19", generation, expectedActiveGeneration: null }), env);
  assert.equal(promoted.status, 200);

  // HEAD returns the exact GET headers with an empty body.
  const head = await worker.fetch(new Request("https://vortx.tv/appcast.json", { method: "HEAD" }), env);
  assert.equal(head.status, 200);
  assert.equal(await head.text(), "");
  assert.equal(head.headers.get("etag"), `"${generation}"`);
  assert.equal(head.headers.get("x-vortx-feed-generation"), generation);
  assert.equal(head.headers.get("content-type"), "application/json; charset=utf-8");

  // Conditional GET with the current ETag answers 304 Not Modified (no body).
  const conditional = await worker.fetch(new Request("https://vortx.tv/appcast.json", { headers: { "if-none-match": `"${generation}"` } }), env);
  assert.equal(conditional.status, 304);
  assert.equal(await conditional.text(), "");

  // A stale or mismatched ETag falls through to a full 200 response.
  const stale = await worker.fetch(new Request("https://vortx.tv/appcast.json", { headers: { "if-none-match": '"stale-generation"' } }), env);
  assert.equal(stale.status, 200);
  assert.notEqual((await stale.text()).length, 0);

  // Unsupported methods on feed routes still fail closed.
  const deleted = await worker.fetch(new Request("https://vortx.tv/appcast.json", { method: "DELETE" }), env);
  assert.equal(deleted.status, 405);
});

test("a replayed promote is idempotent while the exact target is active and 409 after rollback", async () => {
  const kv = new MemoryKV();
  const env = environment(kv);
  const receipt = makeReceipt();
  const staged = await worker.fetch(signedRequest("/__release/receipt", receipt), env);
  assert.equal(staged.status, 200, await staged.text());
  const generation = receipt.manifest.generation;
  const payload = { action: "promote", operationId: "promote:19:target-generation", releaseId: "19", generation, expectedActiveGeneration: null };
  const first = await worker.fetch(signedRequest("/__release/receipt", payload), env);
  assert.equal(first.status, 200);
  // Simulate a lost response: the first call committed in DO storage but the caller never observed
  // it. Retrying the exact same signed bytes must return an idempotent success, not a consume-409.
  const retry = await worker.fetch(signedRequest("/__release/receipt", payload), env);
  assert.equal(retry.status, 200);
  const retryBody = await retry.json();
  assert.equal(retryBody.idempotent, true);
  assert.equal(retryBody.generation, generation);
  // After a rollback of that same operation, the exact same bytes must fail closed with 409,
  // because the previous generation is no longer the active one for that operation.
  const rolledBack = await worker.fetch(signedRequest("/__release/receipt", { action: "rollback", expectedCurrentGeneration: generation, restoreGeneration: "none" }), env);
  assert.equal(rolledBack.status, 200);
  const conflict = await worker.fetch(signedRequest("/__release/receipt", payload), env);
  // After rollback the generation is terminal, so the replay must fail closed (409), never a false
  // idempotent 200. generation-terminal is the specific fail-closed answer for a rolled-back gen.
  assert.equal(conflict.status, 409);
  const conflictBody = await conflict.json();
  assert.equal(conflictBody.error, "generation-terminal");
});

test("unsigned or malformed staged generations never reach the public routes", async () => {
  const kv = new MemoryKV();
  const env = environment(kv);
  const receipt = makeReceipt();
  receipt.manifest.android = {};
  const response = await worker.fetch(signedRequest("/__release/receipt", receipt), env);
  assert.equal(response.status, 503);
  assert.equal(await env.__state.storage.get("active"), undefined);
  const wrongAuth = await worker.fetch(new Request("https://vortx.tv/__release/receipt", { method: "POST", body: JSON.stringify(makeReceipt()) }), env);
  assert.equal(wrongAuth.status, 401);
});

test("staging requires an immutable release ID and serializes build order", async () => {
  const kv = new MemoryKV();
  const env = environment(kv);
  const missingId = makeReceipt();
  missingId.manifest.releaseId = null;
  const missingResponse = await worker.fetch(signedRequest("/__release/receipt", missingId), env);
  assert.equal(missingResponse.status, 503);

  const current = makeReceipt();
  const promoted = await worker.fetch(signedRequest("/__release/receipt", current), env);
  assert.equal(promoted.status, 200);
  const generation = current.manifest.generation;
  assert.equal((await worker.fetch(signedRequest("/__release/receipt", { action: "promote", operationId: "current-promote", releaseId: "19", generation, expectedActiveGeneration: null }), env)).status, 200);
  const older = makeReceipt({ releaseId: "18", build: 220 });
  const olderResponse = await worker.fetch(signedRequest("/__release/receipt", older), env);
  assert.equal(olderResponse.status, 409);
  assert.equal(await env.__state.storage.get("staged:release:18"), undefined);
});

test("HTML and unknown routes fail as JSON errors", async () => {
  const env = environment(new MemoryKV());
  const html = await worker.fetch(new Request("https://vortx.tv/altstore.json", { method: "POST", body: "<html>" }), env);
  assert.equal(html.status, 405);
  const missing = await worker.fetch(new Request("https://vortx.tv/unknown.json"), env);
  assert.equal(missing.status, 404);
  assert.match(await missing.text(), /unknown feed route/);
});

test("the Durable Object serializes conflicting stages and records a canonical receipt digest", async () => {
  const env = environment(new MemoryKV());
  const first = makeReceipt({ releaseId: "19" });
  const conflicting = makeReceipt({ releaseId: "19", build: 222 });
  const [one, two] = await Promise.all([
    worker.fetch(signedRequest("/__release/receipt", first), env),
    worker.fetch(signedRequest("/__release/receipt", conflicting), env),
  ]);
  const statuses = [one.status, two.status].sort();
  assert.deepEqual(statuses, [200, 409]);
  const record = await env.__state.storage.get("staged:release:19");
  assert.match(record.receiptSha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(await env.__state.storage.get(`staged:generation:${record.manifest.generation}`), record);
});

test("integrity repair can seed a malformed legacy generation once and never overwrite an active receipt", async () => {
  const kv = new MemoryKV();
  const legacy = makeReceipt({ releaseId: "18", build: 220, tag: "v0.3.14-beta.18" });
  await kv.put("feed:active", JSON.stringify(legacy));
  const repair = makeReceipt({ releaseId: "19", build: 221, tag: "v0.3.14-beta.19" });
  repair.action = "repair";
  repair.operationId = "repair-legacy";
  repair.repairReason = "integrity-repair";
  repair.expectedLegacyGeneration = legacy.manifest.generation;
  repair.expectedLegacyDigest = sha256(JSON.stringify(canonical(legacy)));
  repair.legacyRelease = {
    releaseId: repair.manifest.releaseId,
    tag: repair.manifest.tag,
    sourceCommit: repair.manifest.sourceCommit,
    tagCommit: repair.manifest.sourceCommit,
    prerelease: true,
    assetIds: Object.values(repair.manifest.assets).map((asset) => asset.assetId),
  };
  const env = environment(kv, { LEGACY_OBSERVED_GENERATION: legacy.manifest.generation, LEGACY_OBSERVED_DIGEST: repair.expectedLegacyDigest });
  const seeded = await worker.fetch(signedRequest("/__release/receipt", repair), env);
  assert.equal(seeded.status, 200, await seeded.text());
  const second = await worker.fetch(signedRequest("/__release/receipt", repair), env);
  assert.equal(second.status, 409);
  const publicFeed = await worker.fetch(new Request("https://vortx.tv/altstore.json"), env);
  assert.equal(publicFeed.status, 200);
  assert.match((await env.__state.storage.get(`quarantine:legacy:${legacy.manifest.generation}`)).state, /repaired/);
});

test("legacy repair rejects a receipt that is not the configured quarantined generation", async () => {
  const repair = makeReceipt({ releaseId: "18", build: 220 });
  repair.action = "repair";
  repair.operationId = "repair-wrong";
  repair.repairReason = "integrity-repair";
  repair.expectedLegacyGeneration = "not-the-legacy-generation";
  repair.expectedLegacyDigest = "0".repeat(64);
  repair.legacyRelease = {
    releaseId: repair.manifest.releaseId,
    tag: repair.manifest.tag,
    sourceCommit: repair.manifest.sourceCommit,
    tagCommit: repair.manifest.sourceCommit,
    prerelease: true,
    assetIds: Object.values(repair.manifest.assets).map((asset) => asset.assetId),
  };
  const env = environment(new MemoryKV(), { LEGACY_OBSERVED_GENERATION: repair.manifest.generation, LEGACY_OBSERVED_DIGEST: repair.expectedLegacyDigest });
  const response = await worker.fetch(signedRequest("/__release/receipt", repair), env);
  assert.equal(response.status, 409);
  assert.equal(await env.__state.storage.get("active"), undefined);
});

test("a promote retry preserves B rollback to A and a staged older generation cannot downgrade C", async () => {
  const env = environment(new MemoryKV());
  const a = makeReceipt({ releaseId: "17", build: 220, tag: "v0.3.14-beta.17" });
  const b = makeReceipt({ releaseId: "18", build: 221, tag: "v0.3.14-beta.18" });
  const c = makeReceipt({ releaseId: "19", build: 222, tag: "v0.3.14-beta.19" });
  for (const receipt of [a, b, c]) assert.equal((await worker.fetch(signedRequest("/__release/receipt", receipt), env)).status, 200);
  let operation = 0;
  const promote = (receipt, expected, operationId = `operation-${++operation}`) => worker.fetch(signedRequest("/__release/receipt", { action: "promote", operationId, releaseId: receipt.manifest.releaseId, generation: receipt.manifest.generation, expectedActiveGeneration: expected }), env);
  assert.equal((await promote(a, null)).status, 200);
  assert.equal((await promote(b, a.manifest.generation, "captured-b")).status, 200);
  const retry = await promote(b, b.manifest.generation);
  assert.equal(retry.status, 200);
  assert.equal((await retry.json()).idempotent, true);
  assert.equal((await worker.fetch(signedRequest("/__release/receipt", { action: "rollback", expectedCurrentGeneration: b.manifest.generation, restoreGeneration: a.manifest.generation }), env)).status, 200);
  assert.equal((await promote(c, a.manifest.generation)).status, 200);
  const replay = await promote(b, a.manifest.generation, "captured-b");
  assert.equal(replay.status, 409);
  const stale = await promote(b, c.manifest.generation);
  assert.equal(stale.status, 409);
  assert.match(await stale.text(), /generation-terminal|promote-build-order/);
});
