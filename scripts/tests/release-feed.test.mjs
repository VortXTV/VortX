import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

import {
  assertAssetFile,
  assertMonotonic,
  assertSource,
  fetchJSON,
  main,
  releaseAssetURL,
  sha256File,
  verifyPublicRoutes,
} from "../release-feed.mjs";

const TAG = "v0.3.14-beta.19";
const BUILD = 221;
const VERSION = "0.3.14";
const IOS_URL = releaseAssetURL(TAG, "iOS");
const TVOS_URL = releaseAssetURL(TAG, "tvOS");
const IOS_SHA = "1".repeat(64);
const TVOS_SHA = "2".repeat(64);

function entry({ build = BUILD, url, size, sha256, minOSVersion }) {
  return {
    version: VERSION,
    buildVersion: String(build),
    date: "2026-08-20",
    localizedDescription: "Beta release notes.",
    downloadURL: url,
    size,
    sha256,
    minOSVersion,
  };
}

function sourceFixture({ build = BUILD, iosURL = IOS_URL, tvosURL = TVOS_URL, iosSha = IOS_SHA, tvosSha = TVOS_SHA } = {}) {
  return {
    name: "VortX",
    identifier: "tv.vortx.altstore",
    apps: [
      { name: "VortX", bundleIdentifier: "com.stremiox.app.native", versions: [entry({ build, url: iosURL, size: 101, sha256: iosSha, minOSVersion: "16.0" })] },
      { name: "VortX (Apple TV)", bundleIdentifier: "com.stremiox.tv", versions: [entry({ build, url: tvosURL, size: 202, sha256: tvosSha, minOSVersion: "18.0" })] },
    ],
  };
}

const expected = {
  tag: TAG,
  build: BUILD,
  version: VERSION,
  iosSize: 101,
  tvosSize: 202,
  iosSha256: IOS_SHA,
  tvosSha256: TVOS_SHA,
  iosURL: IOS_URL,
  tvosURL: TVOS_URL,
};

let temp;
let server;
let baseURL;

before(async () => {
  temp = await mkdtemp(join(tmpdir(), "vortx-release-feed-"));
  server = createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    response.setHeader("Content-Type", "application/json; charset=utf-8");
    response.setHeader("Cache-Control", "public, max-age=300, must-revalidate");
    if (url.pathname === "/no-cache") response.removeHeader("Cache-Control");
    if (url.pathname === "/html") {
      response.setHeader("Content-Type", "text/html");
      response.end("<html>not a feed</html>");
      return;
    }
    if (url.pathname === "/stale") {
      response.end(JSON.stringify(url.search ? { stale: true } : sourceFixture()));
      return;
    }
    if (url.pathname === "/compat" || url.pathname === "/source" || url.pathname === "/no-cache") {
      response.end(JSON.stringify(sourceFixture()));
      return;
    }
    if (url.pathname === "/appcast") {
      response.end(JSON.stringify({
        _generatedFromTag: TAG,
        ios: { build: BUILD, ipa: IOS_URL, size: 101, sha256: IOS_SHA, altstore: "https://vortx.tv/altstore.json" },
        tvos: { build: BUILD, ipa: TVOS_URL, size: 202, sha256: TVOS_SHA, altstore: "https://vortx.tv/altstore.json" },
        mac: { build: BUILD, ipa: "https://github.com/VortXTV/VortX/releases/download/v0.3.14-beta.19/VortX-macOS-v0.3.14-beta.19-ci.dmg", size: 303, sha256: "3".repeat(64), altstore: "https://vortx.tv/altstore.json" },
        android: null,
      }));
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "missing" }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseURL = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
});

test("Beta 10 build mismatch is rejected instead of advertising the wrong binary", () => {
  assert.throws(
    () => assertSource(sourceFixture({ build: 205 }), { ...expected, build: 204 }),
    /current build.*does not match/,
  );
});

test("release and manual cut paths both require feed propagation", async () => {
  const workflow = await readFile(new URL("../../.github/workflows/release-tvos.yml", import.meta.url), "utf8");
  assert.match(workflow, /concurrency:\s*\n\s+group:\s*vortx-release-attachments/);
  assert.match(workflow, /name: Update altstore\/source\.json and push to main/);
  assert.doesNotMatch(workflow, /if:\s*github\.event_name\s*==\s*['"]workflow_dispatch['"]\s*\n\s*uses: actions\/checkout/);
  assert.doesNotMatch(workflow, /name: Update altstore\/source\.json and push to main[\s\S]{0,240}if:\s*github\.event_name\s*==\s*['"]workflow_dispatch['"]/);
});

test("out-of-order publication is rejected when main already leads", () => {
  assert.throws(() => assertMonotonic(sourceFixture({ build: 222 }), BUILD, TAG), (error) => error.code === "out-of-order");
});

test("HTML route is rejected even when its status is 200", async () => {
  await assert.rejects(fetchJSON(`${baseURL}/html`), /expected JSON/);
});

test("query variants must not return a stale generation", async () => {
  const expectedFile = join(temp, "source.json");
  await writeFile(expectedFile, JSON.stringify(sourceFixture()));
  await assert.rejects(
    verifyPublicRoutes({
      expectedFile,
      ...expected,
      canonicalURL: `${baseURL}/stale`,
      compatibilityURL: `${baseURL}/compat`,
      attempts: 1,
    }),
    /different JSON bodies/,
  );
});

test("public route must advertise a bounded cache policy", async () => {
  const expectedFile = join(temp, "source-cache.json");
  await writeFile(expectedFile, JSON.stringify(sourceFixture()));
  await assert.rejects(
    verifyPublicRoutes({
      expectedFile,
      ...expected,
      canonicalURL: `${baseURL}/no-cache`,
      compatibilityURL: `${baseURL}/compat`,
      attempts: 1,
    }),
    /bounded cache-control/,
  );
});

test("missing assets and hash mismatches fail closed", async () => {
  const file = join(temp, "asset.bin");
  await writeFile(file, Buffer.from("release-artifact"));
  const digest = sha256File(file);
  assert.deepEqual(assertAssetFile(file, Buffer.byteLength("release-artifact"), digest), {
    size: Buffer.byteLength("release-artifact"),
    sha256: digest,
  });
  assert.throws(() => assertAssetFile(join(temp, "missing.bin"), 1, digest), /ENOENT/);
  assert.throws(() => assertAssetFile(file, Buffer.byteLength("release-artifact"), "f".repeat(64)), /SHA-256/);
});

test("bounded retry succeeds after transient route failures", async () => {
  let calls = 0;
  const response = { status: 200, headers: new Headers({ "content-type": "application/json" }), text: async () => JSON.stringify({ ok: true }) };
  const value = await fetchJSON("https://feed.test/source.json", {
    attempts: 3,
    delayMs: 0,
    fetchImpl: async () => {
      calls += 1;
      if (calls < 3) return { status: 503, headers: new Headers({ "content-type": "text/plain" }), text: async () => "try again" };
      return response;
    },
  });
  assert.equal(calls, 3);
  assert.deepEqual(value.value, { ok: true });
});

test("rollback restores the last known-good feed", async () => {
  const file = join(temp, "rollback-source.json");
  const backup = join(temp, "rollback-source.previous.json");
  await writeFile(file, "new-generation\n");
  await writeFile(backup, "known-good-generation\n");
  main(["rollback", "--file", file, "--backup", backup]);
  assert.equal(await readFile(file, "utf8"), "known-good-generation\n");
});

test("public routes pass current schema, asset metadata, and appcast checks", async () => {
  const expectedFile = join(temp, "source-valid.json");
  await writeFile(expectedFile, JSON.stringify(sourceFixture()));
  const result = await verifyPublicRoutes({
    expectedFile,
    ...expected,
    canonicalURL: `${baseURL}/source`,
    compatibilityURL: `${baseURL}/compat`,
    appcastURL: `${baseURL}/appcast`,
    attempts: 1,
  });
  assert.equal(result.appcast._generatedFromTag, TAG);
});
