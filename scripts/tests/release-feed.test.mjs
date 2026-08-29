import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

import {
  assertAssetFile,
  assertAppcast,
  assertMonotonic,
  assertSource,
  buildAppcast,
  buildReleaseFeedArtifact,
  fetchJSON,
  FEED_CAPS,
  main,
  projectBuildFromYmlText,
  releaseAssetURL,
  sha256File,
  validateReleaseFeedArtifact,
  verifyPublicRoutes,
} from "../release-feed.mjs";

const TAG = "v0.3.14-beta.19";
const BUILD = 221;
const VERSION = "0.3.14";
const IOS_URL = releaseAssetURL(TAG, "iOS");
const TVOS_URL = releaseAssetURL(TAG, "tvOS");
const MAC_URL = `https://github.com/VortXTV/VortX/releases/download/${TAG}/VortX-macOS-${TAG}-ci.dmg`;
const IOS_SHA = "1".repeat(64);
const TVOS_SHA = "2".repeat(64);
const MAC_SHA = "3".repeat(64);

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
  name: "Beta 19",
  notes: "Beta release notes.",
  prerelease: true,
  iosSize: 101,
  tvosSize: 202,
  macSize: 303,
  iosSha256: IOS_SHA,
  tvosSha256: TVOS_SHA,
  macSha256: MAC_SHA,
  iosURL: IOS_URL,
  tvosURL: TVOS_URL,
  macURL: MAC_URL,
};

function appcastFixture(android = null) {
  return {
    schemaVersion: 2,
    _generatedFromTag: TAG,
    _generatedFromCommit: "a".repeat(40),
    ios: { tag: TAG, version: VERSION, build: BUILD, name: "Beta 19", notes: "Beta release notes.", prerelease: true, ipa: IOS_URL, url: IOS_URL, size: 101, sha256: IOS_SHA, altstore: "https://vortx.tv/altstore.json", artifactType: "ipa" },
    tvos: { tag: TAG, version: VERSION, build: BUILD, name: "Beta 19", notes: "Beta release notes.", prerelease: true, ipa: TVOS_URL, url: TVOS_URL, size: 202, sha256: TVOS_SHA, altstore: null, artifactType: "ipa" },
    mac: { tag: TAG, version: VERSION, build: BUILD, name: "Beta 19", notes: "Beta release notes.", prerelease: true, ipa: MAC_URL, url: MAC_URL, size: 303, sha256: MAC_SHA, altstore: null, artifactType: "dmg" },
    android,
  };
}

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
      response.end(JSON.stringify(appcastFixture()));
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

test("the project build is an all-target contract, not the first matching line", () => {
  const six = Array.from({ length: 6 }, () => 'CURRENT_PROJECT_VERSION: "221"').join("\n");
  assert.equal(projectBuildFromYmlText(six), 221);
  assert.throws(() => projectBuildFromYmlText('CURRENT_PROJECT_VERSION: "221"'), /exactly six/);
  assert.throws(() => projectBuildFromYmlText(six.replace('"221"', '"220"')), /disagree/);
});

test("release and manual cut paths both require feed propagation", async () => {
  const workflow = await readFile(new URL("../../.github/workflows/release-tvos.yml", import.meta.url), "utf8");
  assert.match(workflow, /concurrency:\s*\n\s+group:\s*vortx-release-\$\{\{ inputs\.release_tag \}\}/);
  assert.match(workflow, /name: Build the content-addressed release feed artifact/);
  assert.match(workflow, /name: Attach only exact draft assets and create the authenticated staged receipt/);
  assert.match(workflow, /publish_release/);
  assert.match(workflow, /name: Atomically activate the staged feed, prove routes, then publish last/);
  assert.match(workflow, /node scripts\/release-feed\.mjs project-build --file app\/project\.yml/);
  assert.match(workflow, /PUBLISH_DEADLINE/);
  assert.match(workflow, /IS_PRERELEASE=false; \[\[ "\$TAG" == \*-\* \]\] && IS_PRERELEASE=true/);
  assert.match(workflow, /\.prerelease == \$prerelease/);
  assert.match(workflow, /rollback-verify=\$restore/);
  assert.match(workflow, /rollback-raw-source\.json/);
  assert.match(workflow, /name: Verify the immutable published release and public feed/);
  assert.doesNotMatch(workflow, /if:\s*github\.event_name\s*==\s*['"]workflow_dispatch['"]\s*\n\s*uses: actions\/checkout/);
  // The promotion must carry a deterministic, write-once operation ID and the promote/publish lane
  // must be gated by publish_release so that publish_release:false can never reach draft=false.
  assert.match(workflow, /OPERATION_ID="promote:\$RELEASE_ID:\$FEED_GENERATION"/);
  assert.match(workflow, /operationId:\$oid/);
  assert.match(workflow, /promote-body\.json/);
  assert.match(workflow, /if:\s*inputs\.publish_release == true/);
  const releaseWrite = workflow.slice(workflow.indexOf("  attach-release:"));
  assert.doesNotMatch(releaseWrite, /gh release upload/);
  assert.doesNotMatch(releaseWrite, /--clobber/);
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
    /exact staged source|route-byte-drift/,
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
    /bounded cache-control|unsafe cache-control/,
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
  await writeFile(`${file}.generation`, "new-generation\n");
  await writeFile(`${backup}.generation`, "known-good-generation\n");
  main(["rollback", "--file", file, "--backup", backup,
    "--expected-current-sha256", sha256File(file),
    "--expected-generation", "new-generation",
    "--restore-generation", "known-good-generation"]);
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

test("appcast must state Android null until a signed artifact exists", () => {
  const appcast = appcastFixture();
  delete appcast.android;
  assert.throws(() => assertAppcast(appcast, expected), /Android/);
});

test("content-addressed artifact records exact local bytes and keeps Android null", async () => {
  const sourceTemplate = join(temp, "source-template.json");
  const output = join(temp, "feed-artifact");
  const files = {
    ios: join(temp, "ios.ipa"),
    tvos: join(temp, "tvos.ipa"),
    lite: join(temp, "lite.ipa"),
    mac: join(temp, "mac.dmg"),
    checksum: join(temp, "checksums.txt"),
  };
  await writeFile(sourceTemplate, `${JSON.stringify(sourceFixture({ build: 220 }), null, 2)}\n`);
  await writeFile(files.ios, "ios-content");
  await writeFile(files.tvos, "tvos-content");
  await writeFile(files.lite, "lite-content");
  await writeFile(files.mac, "mac-content");
  const local = Object.values(files).slice(0, 4);
  await writeFile(files.checksum, `${local.map((file) => `${sha256File(file)}  out/${file.split("/").pop()}`).join("\n")}\n`);
  const result = buildReleaseFeedArtifact({
    tag: TAG,
    build: BUILD,
    sourceCommit: "a".repeat(40),
    sourceTemplate,
    output,
    iosFile: files.ios,
    tvosFile: files.tvos,
    tvosLiteFile: files.lite,
    macFile: files.mac,
    checksumFile: files.checksum,
    name: "Beta 19",
    note: "Beta release notes.",
  });
  assert.equal(result.manifest.android, null);
  assert.equal(result.manifest.assets.ios.state, "trusted-local");
  assert.equal(result.manifest.assets.mac.url, MAC_URL);
  assert.equal(JSON.parse(await readFile(join(output, "source.json"), "utf8")).apps[0].versions[0].buildVersion, "221");
  const appcast = JSON.parse(await readFile(join(output, "appcast.json"), "utf8"));
  assertAppcast(appcast, { ...expected, iosSize: 11, tvosSize: 12, macSize: 11, iosSha256: sha256File(files.ios), tvosSha256: sha256File(files.tvos), macSha256: sha256File(files.mac) });
  assert.equal(appcast.ios.altstore, "https://vortx.tv/altstore.json");
  assert.equal(appcast.tvos.altstore, null);
  assert.equal(appcast.mac.artifactType, "dmg");
});

// =================================================================================================
// t22: Release feed artifact validation (split Android, client caps, tag/versionName coherence)
// =================================================================================================

const VALID_ANDROID_FULL = Object.freeze({
  applicationId: "com.vortx.android",
  engine: "mpv",
  artifactType: "apk",
  version: VERSION,
  build: BUILD,
  signed: true,
  url: `https://github.com/VortXTV/VortX/releases/download/${TAG}/VortX-${VERSION}-full-mpv-universal.apk`,
  size: 85_000_000,
  sha256: "a".repeat(64),
  signer: "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89",
  prerelease: true,
});

const VALID_ANDROID_PLAY = Object.freeze({
  applicationId: "com.vortx.android",
  engine: "media3",
  artifactType: "apk",
  version: VERSION,
  build: BUILD,
  signed: true,
  url: `https://github.com/VortXTV/VortX/releases/download/${TAG}/VortX-${VERSION}-play-media3-universal.apk`,
  size: 72_000_000,
  sha256: "b".repeat(64),
  signer: "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89",
  prerelease: true,
});

function appcastAndroidFixture() {
  return {
    full: { ...VALID_ANDROID_FULL, tag: TAG, name: expected.name, notes: expected.notes },
    play: { ...VALID_ANDROID_PLAY, tag: TAG, name: expected.name, notes: expected.notes },
  };
}

function validManifest({ android = null, hasApple = true } = {}) {
  const m = {
    schemaVersion: 2,
    tag: TAG,
    build: BUILD,
    version: VERSION,
    name: "Beta 19",
    notes: "Beta release notes.",
    prerelease: true,
    sourceCommit: "a".repeat(40),
  };
  if (hasApple) {
    m.ios = { tag: TAG, version: VERSION, build: BUILD, url: IOS_URL, size: 101, sha256: IOS_SHA };
    m.tvos = { tag: TAG, version: VERSION, build: BUILD, url: TVOS_URL, size: 202, sha256: TVOS_SHA };
    m.mac = { tag: TAG, version: VERSION, build: BUILD, url: MAC_URL, size: 303, sha256: MAC_SHA };
  }
  m.android = android;
  return m;
}

// --- Positive fixtures ---------------------------------------------------------------------------

test("validateReleaseFeedArtifact accepts Apple-only release (android null)", () => {
  const result = validateReleaseFeedArtifact(validManifest({ android: null }));
  assert.equal(result.valid, true);
  assert.deepEqual(result.androidFlavors, []);
  assert.equal(result.hasApple, true);
});

test("validateReleaseFeedArtifact accepts full+play Android with Apple", () => {
  const result = validateReleaseFeedArtifact(validManifest({
    android: { full: VALID_ANDROID_FULL, play: VALID_ANDROID_PLAY },
  }));
  assert.equal(result.valid, true);
  assert.deepEqual(result.androidFlavors.sort(), ["full", "play"]);
  assert.equal(result.hasApple, true);
});

test("validateReleaseFeedArtifact accepts Android-only release (no Apple platforms)", () => {
  const result = validateReleaseFeedArtifact(validManifest({
    android: { full: VALID_ANDROID_FULL, play: VALID_ANDROID_PLAY },
    hasApple: false,
  }));
  assert.equal(result.valid, true);
  assert.deepEqual(result.androidFlavors.sort(), ["full", "play"]);
  assert.equal(result.hasApple, false);
});

test("validateReleaseFeedArtifact accepts single-flavor Android (full only)", () => {
  const result = validateReleaseFeedArtifact(validManifest({
    android: { full: VALID_ANDROID_FULL },
    hasApple: false,
  }));
  assert.equal(result.valid, true);
  assert.deepEqual(result.androidFlavors, ["full"]);
});

test("validateReleaseFeedArtifact accepts single-flavor Android (play only)", () => {
  const result = validateReleaseFeedArtifact(validManifest({
    android: { play: VALID_ANDROID_PLAY },
    hasApple: false,
  }));
  assert.equal(result.valid, true);
  assert.deepEqual(result.androidFlavors, ["play"]);
});

test("validateReleaseFeedArtifact accepts AAB artifact type", () => {
  const playAab = { ...VALID_ANDROID_PLAY, artifactType: "aab", url: VALID_ANDROID_PLAY.url.replace(".apk", ".aab") };
  const result = validateReleaseFeedArtifact(validManifest({
    android: { full: VALID_ANDROID_FULL, play: playAab },
  }));
  assert.equal(result.valid, true);
});

test("assertAppcast accepts schemaVersion 2 split Android release assets", () => {
  const android = appcastAndroidFixture();
  android.play = {
    ...android.play,
    artifactType: "aab",
    url: android.play.url.replace("-universal.apk", ".aab"),
  };
  assert.doesNotThrow(() => assertAppcast(appcastFixture(android), expected));
});

test("buildAppcast round-trips split Android entries through assertAppcast", () => {
  const input = {
    tag: TAG,
    build: BUILD,
    version: VERSION,
    name: expected.name,
    notes: expected.notes,
    prerelease: true,
    ios: { url: IOS_URL, size: expected.iosSize, sha256: IOS_SHA },
    tvos: { url: TVOS_URL, size: expected.tvosSize, sha256: TVOS_SHA },
    mac: { url: MAC_URL, size: expected.macSize, sha256: MAC_SHA },
    android: { full: VALID_ANDROID_FULL, play: VALID_ANDROID_PLAY },
  };
  const appcast = buildAppcast(input);
  assertAppcast(appcast, expected);
  assert.equal(appcast.android.full.tag, TAG);
  assert.equal(appcast.android.play.name, expected.name);
  assert.equal(appcast.android.play.notes, expected.notes);
  assert.equal(buildAppcast({ ...input, android: null }).android, null);
  assert.throws(() => buildAppcast({ ...input, android: { signed: true, url: VALID_ANDROID_FULL.url } }), /split into full\/play/);
});

test("assertAppcast rejects split Android drift and unsafe release URLs", () => {
  const cases = [
    {
      name: "flat root Android metadata",
      android: { signed: true, url: VALID_ANDROID_FULL.url },
      error: /split into full\/play/,
    },
    {
      name: "missing signing metadata",
      mutate: (android) => delete android.full.signer,
      error: /missing required schema fields/,
    },
    {
      name: "missing Android tag",
      mutate: (android) => delete android.full.tag,
      error: /missing required schema fields/,
    },
    {
      name: "missing Android name",
      mutate: (android) => delete android.full.name,
      error: /missing required schema fields/,
    },
    {
      name: "missing Android notes",
      mutate: (android) => delete android.full.notes,
      error: /missing required schema fields/,
    },
    {
      name: "Android tag drift",
      mutate: (android) => { android.full.tag = "v9.9.9"; },
      error: /release metadata or signing state differs/,
    },
    {
      name: "Android name drift",
      mutate: (android) => { android.full.name = "Other release"; },
      error: /release metadata or signing state differs/,
    },
    {
      name: "Android notes drift",
      mutate: (android) => { android.full.notes = "Other notes."; },
      error: /release metadata or signing state differs/,
    },
    {
      name: "credential-bearing URL",
      mutate: (android) => { android.full.url = android.full.url.replace("https://github.com", "https://token@github.com"); },
      error: /without credentials, query, or fragment/,
    },
    {
      name: "URL query",
      mutate: (android) => { android.play.url += "?download=1"; },
      error: /without credentials, query, or fragment/,
    },
    {
      name: "wrong release asset",
      mutate: (android) => { android.play.url = android.play.url.replace("play-media3-universal", "full-mpv-universal"); },
      error: /immutable VortXTV\/VortX release asset/,
    },
    {
      name: "wrong engine",
      mutate: (android) => { android.full.engine = "media3"; },
      error: /flavor, engine, or artifact type is invalid/,
    },
    {
      name: "oversized artifact",
      mutate: (android) => { android.full.size = FEED_CAPS.artifactBytes + 1; },
      error: /artifact metadata is invalid/,
    },
    {
      name: "noncanonical SHA-256",
      mutate: (android) => { android.play.sha256 = "B".repeat(64); },
      error: /artifact metadata is invalid/,
    },
  ];
  for (const testCase of cases) {
    const android = testCase.android || appcastAndroidFixture();
    testCase.mutate?.(android);
    assert.throws(() => assertAppcast(appcastFixture(android), expected), testCase.error, testCase.name);
  }
  assert.throws(() => assertAppcast({ ...appcastFixture(), schemaVersion: "2" }, expected), /schemaVersion/);
});

test("validateReleaseFeedArtifact accepts JSON string input with size check", () => {
  const json = JSON.stringify(validManifest({ android: { full: VALID_ANDROID_FULL } }));
  const result = validateReleaseFeedArtifact(json);
  assert.equal(result.valid, true);
});

// --- Negative fixtures: schema violations --------------------------------------------------------

test("rejects wrong schemaVersion", () => {
  const m = validManifest();
  m.schemaVersion = 1;
  assert.throws(() => validateReleaseFeedArtifact(m), /schemaVersion must be exactly 2/);
});

test("rejects missing schemaVersion", () => {
  const m = validManifest();
  delete m.schemaVersion;
  assert.throws(() => validateReleaseFeedArtifact(m), /schemaVersion/);
});

test("rejects invalid tag format", () => {
  const m = validManifest();
  m.tag = "not-a-tag";
  assert.throws(() => validateReleaseFeedArtifact(m), /valid release tag/);
});

test("rejects non-positive build", () => {
  const m = validManifest();
  m.build = 0;
  assert.throws(() => validateReleaseFeedArtifact(m), /positive integer/);
});

test("rejects version mismatch with tag", () => {
  const m = validManifest();
  m.version = "9.9.9";
  assert.throws(() => validateReleaseFeedArtifact(m), /tag-derived version/);
});

// --- Negative fixtures: flat root.android rejection ----------------------------------------------

test("rejects flat root.android with signing fields", () => {
  const m = validManifest();
  m.android = { signed: true, url: "https://example.com/a.apk", sha256: "a".repeat(64), size: 100 };
  assert.throws(() => validateReleaseFeedArtifact(m), /split flavor entries.*flat root\.android/);
});

test("rejects root.android as array", () => {
  const m = validManifest();
  m.android = [VALID_ANDROID_FULL];
  assert.throws(() => validateReleaseFeedArtifact(m), /must be an object/);
});

test("rejects empty android object (no flavors)", () => {
  const m = validManifest();
  m.android = {};
  assert.throws(() => validateReleaseFeedArtifact(m), /at least one flavor/);
});

test("rejects unknown android flavor", () => {
  const m = validManifest();
  m.android = { full: VALID_ANDROID_FULL, beta: VALID_ANDROID_PLAY };
  assert.throws(() => validateReleaseFeedArtifact(m), /unknown flavor "beta"/);
});

// --- Negative fixtures: per-field Android validation ---------------------------------------------

test("rejects wrong applicationId", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, applicationId: "com.evil.app" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /applicationId must be com\.vortx\.android/);
});

test("rejects wrong engine for full flavor", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, engine: "media3" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /engine must be "mpv" for the full flavor/);
});

test("rejects wrong engine for play flavor", () => {
  const m = validManifest({ android: { play: { ...VALID_ANDROID_PLAY, engine: "mpv" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /engine must be "media3" for the play flavor/);
});

test("rejects invalid artifactType", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, artifactType: "exe" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /artifactType must be one of/);
});

test("rejects non-HTTPS URL", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, url: "http://evil.com/a.apk" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /HTTPS/);
});

test("rejects upper-case SHA-256", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, sha256: "A".repeat(64) } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /lower-case 64-character hex/);
});

test("rejects short SHA-256", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, sha256: "abc123" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /lower-case 64-character hex/);
});

test("rejects unsigned entry", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, signed: false } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /signed must be true/);
});

test("rejects zero-size artifact", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, size: 0 } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /positive integer/);
});

test("rejects negative size", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, size: -1 } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /positive integer/);
});

test("rejects Android version mismatch with tag", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, version: "9.9.9" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /version must equal the tag version/);
});

test("rejects Android build mismatch", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, build: 999 } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /build must equal the release build/);
});

test("rejects prerelease mismatch", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, prerelease: false } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /prerelease must match/);
});

test("rejects empty signer", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, signer: "" } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /non-empty string/);
});

// --- Client-compatible caps ----------------------------------------------------------------------

test("rejects manifest exceeding 512 KiB cap", () => {
  const hugeNotes = "x".repeat(FEED_CAPS.notesLength + 1);
  const m = validManifest();
  m.notes = hugeNotes;
  // The JSON serialization will exceed 512 KiB
  const json = JSON.stringify(m);
  assert.ok(Buffer.byteLength(json, "utf8") > FEED_CAPS.manifestBytes || hugeNotes.length > FEED_CAPS.notesLength);
  assert.throws(() => validateReleaseFeedArtifact(m), /exceeds.*characters|exceeds.*bytes/);
});

test("rejects version string exceeding 64 chars", () => {
  const m = validManifest();
  m.version = "0." + "1".repeat(63);
  assert.throws(() => validateReleaseFeedArtifact(m), /exceeds 64 characters/);
});

test("rejects name exceeding 200 chars", () => {
  const m = validManifest();
  m.name = "R".repeat(201);
  assert.throws(() => validateReleaseFeedArtifact(m), /exceeds 200 characters/);
});

test("rejects notes exceeding 20,000 chars", () => {
  const m = validManifest();
  m.notes = "N".repeat(20_001);
  assert.throws(() => validateReleaseFeedArtifact(m), /exceeds 20000 characters/);
});

test("rejects artifact size exceeding 1 GiB cap", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, size: FEED_CAPS.artifactBytes + 1 } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /exceeds maximum/);
});

test("rejects oversized signer (>256 chars)", () => {
  const m = validManifest({ android: { full: { ...VALID_ANDROID_FULL, signer: "X".repeat(257) } } });
  assert.throws(() => validateReleaseFeedArtifact(m), /signer is too long/);
});

// --- Edge cases ----------------------------------------------------------------------------------

test("accepts manifest without notes field", () => {
  const m = validManifest();
  delete m.notes;
  const result = validateReleaseFeedArtifact(m);
  assert.equal(result.valid, true);
});

test("accepts manifest with null notes", () => {
  const m = validManifest();
  m.notes = null;
  const result = validateReleaseFeedArtifact(m);
  assert.equal(result.valid, true);
});

test("rejects invalid JSON string input", () => {
  assert.throws(() => validateReleaseFeedArtifact("{invalid json"), /not valid JSON/);
});

test("rejects non-object manifest", () => {
  assert.throws(() => validateReleaseFeedArtifact("42"), /must be a JSON object/);
});

test("rejects manifest without tag", () => {
  const m = validManifest();
  delete m.tag;
  assert.throws(() => validateReleaseFeedArtifact(m), /non-empty string.*tag/);
});

test("rejects invalid sourceCommit format", () => {
  const m = validManifest();
  m.sourceCommit = "not-a-sha";
  assert.throws(() => validateReleaseFeedArtifact(m), /40-character commit SHA/);
});

test("accepts manifest without sourceCommit", () => {
  const m = validManifest();
  delete m.sourceCommit;
  const result = validateReleaseFeedArtifact(m);
  assert.equal(result.valid, true);
});
