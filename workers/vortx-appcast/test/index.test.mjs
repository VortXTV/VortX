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

function asset(slug, extension, checksumName, byte, assetId) {
  const name = `VortX-${slug}-${TAG}-ci.${extension}`;
  const url = `https://github.com/VortXTV/VortX/releases/download/${TAG}/${name}`;
  return { name, checksumName, url, size: byte.length, sha256: sha256(byte), state: "uploaded", assetId };
}

function makeReceipt({ releaseId = "19", build = BUILD } = {}) {
  const assets = {
    ios: asset("iOS", "ipa", "VortX-iOS-ci.ipa", "ios-bytes", 11),
    tvos: asset("tvOS", "ipa", "VortX-tvOS-ci.ipa", "tvos-bytes", 12),
    tvosLite: asset("tvOS-lite", "ipa", "VortX-tvOS-lite-ci.ipa", "lite-bytes", 13),
    mac: asset("macOS", "dmg", "VortX-macOS-ci.dmg", "mac-bytes", 14),
  };
  const note = "Verified release notes.";
  const source = {
    name: "VortX",
    identifier: "tv.vortx.altstore",
    apps: [
      {
        name: "VortX",
        bundleIdentifier: "com.stremiox.app.native",
        versions: [{ version: "0.3.14", buildVersion: String(build), date: "2026-08-20", localizedDescription: note, downloadURL: assets.ios.url, size: assets.ios.size, sha256: assets.ios.sha256, minOSVersion: "16.0" }],
      },
      {
        name: "VortX (Apple TV)",
        bundleIdentifier: "com.stremiox.tv",
        versions: [{ version: "0.3.14", buildVersion: String(build), date: "2026-08-20", localizedDescription: note, downloadURL: assets.tvos.url, size: assets.tvos.size, sha256: assets.tvos.sha256, minOSVersion: "18.0" }],
      },
    ],
  };
  const sourceText = `${JSON.stringify(source, null, 2)}\n`;
  const appcast = {
    schemaVersion: 2,
    _generatedFromTag: TAG,
    _generatedFromCommit: COMMIT,
    ios: { tag: TAG, version: "0.3.14", build, name: "Beta 19", notes: note, prerelease: true, ipa: assets.ios.url, url: assets.ios.url, size: assets.ios.size, sha256: assets.ios.sha256, altstore: "https://vortx.tv/altstore.json", artifactType: "ipa" },
    tvos: { tag: TAG, version: "0.3.14", build, name: "Beta 19", notes: note, prerelease: true, ipa: assets.tvos.url, url: assets.tvos.url, size: assets.tvos.size, sha256: assets.tvos.sha256, altstore: null, artifactType: "ipa" },
    mac: { tag: TAG, version: "0.3.14", build, name: "Beta 19", notes: note, prerelease: true, ipa: assets.mac.url, url: assets.mac.url, size: assets.mac.size, sha256: assets.mac.sha256, altstore: null, artifactType: "dmg" },
    android: null,
  };
  const appcastText = `${JSON.stringify(appcast, null, 2)}\n`;
  const checksum = Object.values(assets).map((entry) => `${entry.sha256}  out/${entry.checksumName}`).join("\n") + "\n";
  const feedSha256 = sha256(`${sourceText}\n${appcastText}\n${checksum}`);
  const manifest = {
    schemaVersion: 2,
    tag: TAG,
    build,
    version: "0.3.14",
    name: "Beta 19",
    notes: note,
    prerelease: true,
    sourceCommit: COMMIT,
    releaseId,
    generation: `${TAG}:${BUILD}:${feedSha256}`,
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

function environment(kv) {
  const env = { LASTGOOD: kv, RELEASE_FEED_RECEIPT_SECRET: SECRET };
  env.COORDINATOR = {
    idFromName: () => "release-feed",
    get: () => ({ fetch: (request) => new FeedCoordinator({}, env).fetch(request) }),
  };
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
  const promoted = await worker.fetch(signedRequest("/__release/receipt", { action: "promote", releaseId: "19", generation, expectedActiveGeneration: null }), env);
  assert.equal(promoted.status, 200);
  for (const path of ["/altstore.json", "/vortx-altstore.json", "/appcast.json"]) {
    const response = await worker.fetch(new Request(`https://vortx.tv${path}?cache-bust=old`), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(response.headers.get("cache-control"), "public, max-age=120, s-maxage=120, must-revalidate");
    assert.equal(response.headers.get("x-vortx-feed-generation"), generation);
  }
  const conflict = await worker.fetch(signedRequest("/__release/receipt", { action: "promote", releaseId: "19", generation, expectedActiveGeneration: "wrong" }), env);
  assert.equal(conflict.status, 409);
  const rolledBack = await worker.fetch(signedRequest("/__release/receipt", { action: "rollback", expectedCurrentGeneration: generation, restoreGeneration: "none" }), env);
  assert.equal(rolledBack.status, 200);
  const unavailable = await worker.fetch(new Request("https://vortx.tv/altstore.json"), env);
  assert.equal(unavailable.status, 503);
});

test("unsigned or malformed staged generations never reach the public routes", async () => {
  const kv = new MemoryKV();
  const env = environment(kv);
  const receipt = makeReceipt();
  receipt.manifest.android = {};
  const response = await worker.fetch(signedRequest("/__release/receipt", receipt), env);
  assert.equal(response.status, 503);
  assert.equal(await kv.get("feed:active"), null);
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
  assert.equal((await worker.fetch(signedRequest("/__release/receipt", { action: "promote", releaseId: "19", generation, expectedActiveGeneration: null }), env)).status, 200);
  const older = makeReceipt({ releaseId: "18", build: 220 });
  const olderResponse = await worker.fetch(signedRequest("/__release/receipt", older), env);
  assert.equal(olderResponse.status, 503);
  assert.equal(await kv.get("feed:staged:18"), null);
});

test("HTML and unknown routes fail as JSON errors", async () => {
  const env = environment(new MemoryKV());
  const html = await worker.fetch(new Request("https://vortx.tv/altstore.json", { method: "POST", body: "<html>" }), env);
  assert.equal(html.status, 405);
  const missing = await worker.fetch(new Request("https://vortx.tv/unknown.json"), env);
  assert.equal(missing.status, 404);
  assert.match(await missing.text(), /unknown feed route/);
});
