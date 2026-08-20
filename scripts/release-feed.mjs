#!/usr/bin/env node

/**
 * Release feed operations shared by the release workflow and deterministic local checks.
 *
 * A release feed is a public install contract, not a release note. Every current entry is
 * therefore derived from the immutable tag and the uploaded asset metadata, and every public
 * route is checked as JSON before the workflow can finish successfully.
 */

import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";

export const REPOSITORY = "VortXTV/VortX";
export const SOURCE_HISTORY_LIMIT = 8;
export const RELEASE_TAG_RE = /^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?$/;
export const REQUIRED_TARGETS = Object.freeze([
  Object.freeze({
    key: "ios",
    bundleIdentifier: "com.stremiox.app.native",
    slug: "iOS",
    minOSVersion: "16.0",
  }),
  Object.freeze({
    key: "tvos",
    bundleIdentifier: "com.stremiox.tv",
    slug: "tvOS",
    minOSVersion: "18.0",
  }),
]);

export class ReleaseFeedError extends Error {
  constructor(message, code = "release-feed-invalid") {
    super(message);
    this.name = "ReleaseFeedError";
    this.code = code;
  }
}

function die(message, code = "release-feed-invalid") {
  throw new ReleaseFeedError(message, code);
}

export function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[index + 1];
    if (next && !next.startsWith("--")) {
      args[key] = next;
      index += 1;
    } else {
      args[key] = "";
    }
  }
  return args;
}

export function requireTag(value) {
  if (!RELEASE_TAG_RE.test(String(value || ""))) {
    die(`--tag must be a strict release tag (got ${JSON.stringify(value)})`);
  }
  return String(value);
}

export function requirePositiveInteger(name, value) {
  if (!/^\d+$/.test(String(value ?? "")) || Number(value) <= 0) {
    die(`--${name} must be a positive integer (got ${JSON.stringify(value)})`);
  }
  return Number(value);
}

export function requireSha256(name, value) {
  const sha = String(value || "").toLowerCase().replace(/^sha256:/, "");
  if (!/^[0-9a-f]{64}$/.test(sha)) {
    die(`--${name} must be a 64-character SHA-256 digest (got ${JSON.stringify(value)})`);
  }
  return sha;
}

export function cleanProse(value) {
  return String(value || "")
    .replace(/[\u2012\u2013\u2014\u2015\u2212]/g, "-")
    .replace(/\s+/g, " ")
    .trim();
}

export function releaseAssetURL(tag, slug) {
  requireTag(tag);
  if (!/^[A-Za-z]+$/.test(String(slug))) die(`invalid asset slug ${JSON.stringify(slug)}`);
  return `https://github.com/${REPOSITORY}/releases/download/${tag}/VortX-${slug}-${tag}-ci.ipa`;
}

function requireDownloadURL(name, value, tag, slug) {
  const url = String(value || "");
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    die(`--${name} is not an absolute URL`);
  }
  if (parsed.protocol !== "https:" || parsed.hostname !== "github.com" || parsed.search || parsed.hash) {
    die(`--${name} must be the immutable GitHub release URL without query or fragment`);
  }
  const expected = new URL(releaseAssetURL(tag, slug));
  if (parsed.href !== expected.href) {
    die(`--${name} does not point at the expected ${slug} asset`);
  }
  return parsed.href;
}

function readJSON(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    die(`cannot read/parse ${file}: ${error.message}`);
  }
}

function writeJSON(file, value) {
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function appFor(source, target) {
  if (!source || !Array.isArray(source.apps)) die("source has no apps[] array");
  const app = source.apps.find((candidate) => candidate?.bundleIdentifier === target.bundleIdentifier);
  if (!app) die(`source has no ${target.bundleIdentifier} app`);
  if (!Array.isArray(app.versions)) die(`${target.bundleIdentifier} has no versions[] array`);
  return app;
}

function currentVersion(app, target) {
  const entry = app.versions[0];
  if (!entry || typeof entry !== "object") die(`${target.bundleIdentifier} has no current versions[0] entry`);
  return entry;
}

function assertCurrentEntry(entry, target, expected) {
  const expectedURL = expected[`${target.key}URL`] || releaseAssetURL(expected.tag, target.slug);
  if (String(entry.buildVersion) !== String(expected.build)) {
    die(`${target.key} current build ${JSON.stringify(entry.buildVersion)} does not match ${expected.build}`);
  }
  if (entry.version !== expected.version) {
    die(`${target.key} current version ${JSON.stringify(entry.version)} does not match ${expected.version}`);
  }
  if (entry.downloadURL !== expectedURL) {
    die(`${target.key} downloadURL is not the exact release asset URL`);
  }
  if (Number(entry.size) !== Number(expected[`${target.key}Size`])) {
    die(`${target.key} size ${JSON.stringify(entry.size)} does not match uploaded size ${expected[`${target.key}Size`]}`);
  }
  if (String(entry.sha256 || "").toLowerCase().replace(/^sha256:/, "") !== expected[`${target.key}Sha256`]) {
    die(`${target.key} sha256 does not match the uploaded asset`);
  }
  if (entry.minOSVersion !== target.minOSVersion) {
    die(`${target.key} minOSVersion changed unexpectedly`);
  }
  if (typeof entry.localizedDescription !== "string" || !entry.localizedDescription.trim()) {
    die(`${target.key} current entry has no localizedDescription`);
  }
}

export function assertSource(source, expected) {
  const version = String(expected.tag).replace(/^v/, "").split("-")[0];
  const normalized = {
    ...expected,
    version,
    iosURL: expected.iosURL || releaseAssetURL(expected.tag, "iOS"),
    tvosURL: expected.tvosURL || releaseAssetURL(expected.tag, "tvOS"),
  };
  for (const target of REQUIRED_TARGETS) {
    const app = appFor(source, target);
    assertCurrentEntry(currentVersion(app, target), target, normalized);
    if (app.versions.length > SOURCE_HISTORY_LIMIT) {
      die(`${target.key} history exceeds ${SOURCE_HISTORY_LIMIT} entries`);
    }
    const builds = app.versions.map((entry) => Number(entry.buildVersion));
    if (builds.some((build) => !Number.isInteger(build) || build <= 0)) {
      die(`${target.key} contains a non-positive or non-numeric historical build`);
    }
    if (new Set(builds).size !== builds.length) die(`${target.key} history contains duplicate builds`);
  }
  return true;
}

export function assertMonotonic(source, targetBuild, targetTag) {
  const build = requirePositiveInteger("build", targetBuild);
  requireTag(targetTag);
  for (const target of REQUIRED_TARGETS) {
    const app = appFor(source, target);
    const current = currentVersion(app, target);
    const currentBuild = Number(current.buildVersion);
    if (!Number.isInteger(currentBuild) || currentBuild <= 0) die(`${target.key} current build is invalid`);
    if (currentBuild > build) {
      die(`${target.key} already advertises newer build ${currentBuild}; refusing out-of-order publication`, "out-of-order");
    }
    if (currentBuild === build && current.downloadURL && !current.downloadURL.includes(`/${targetTag}/`)) {
      die(`${target.key} already uses build ${build} for a different tag; refusing replacement`, "build-conflict");
    }
  }
  return true;
}

export function assertRollbackTarget(source, targetBuild, targetTag) {
  const build = requirePositiveInteger("build", targetBuild);
  const tag = requireTag(targetTag);
  for (const target of REQUIRED_TARGETS) {
    const entry = currentVersion(appFor(source, target), target);
    if (Number(entry.buildVersion) !== build || !String(entry.downloadURL || "").includes(`/download/${tag}/`)) {
      die(`${target.key} no longer advertises ${tag} build ${build}; refusing a downgrade`, "rollback-target-mismatch");
    }
  }
  return true;
}

export function updateSourceFile(options) {
  const file = options.file;
  if (!file) die("--file is required");
  const tag = requireTag(options.tag);
  const build = requirePositiveInteger("build", options.build);
  const date = String(options.date || "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) die(`--date must be YYYY-MM-DD (got ${JSON.stringify(date)})`);
  const version = tag.replace(/^v/, "").split("-")[0];
  const name = cleanProse(options.name) || `${version} (${tag})`;
  const note = cleanProse(options.note);
  const localizedDescription = note || `${name}. One-tap update over any earlier build, nothing resets.`;
  const iosSize = requirePositiveInteger("ios-size", options.iosSize);
  const tvosSize = requirePositiveInteger("tvos-size", options.tvosSize);
  const iosSha256 = requireSha256("ios-sha256", options.iosSha256);
  const tvosSha256 = requireSha256("tvos-sha256", options.tvosSha256);
  const iosURL = requireDownloadURL("ios-url", options.iosURL || releaseAssetURL(tag, "iOS"), tag, "iOS");
  const tvosURL = requireDownloadURL("tvos-url", options.tvosURL || releaseAssetURL(tag, "tvOS"), tag, "tvOS");
  const source = readJSON(file);
  assertMonotonic(source, build, tag);
  const metadata = {
    ios: { size: iosSize, sha256: iosSha256, url: iosURL },
    tvos: { size: tvosSize, sha256: tvosSha256, url: tvosURL },
  };
  for (const target of REQUIRED_TARGETS) {
    const app = appFor(source, target);
    const existing = app.versions.find((entry) => String(entry.buildVersion) === String(build));
    const item = metadata[target.key];
    const entry = {
      version,
      buildVersion: String(build),
      date: existing?.date || date,
      localizedDescription: note ? localizedDescription : existing?.localizedDescription || localizedDescription,
      downloadURL: item.url,
      size: item.size,
      sha256: item.sha256,
      minOSVersion: target.minOSVersion,
    };
    app.versions = [entry, ...app.versions.filter((candidate) => String(candidate.buildVersion) !== String(build))]
      .slice(0, SOURCE_HISTORY_LIMIT);
  }
  assertSource(source, {
    tag,
    build,
    version,
    iosSize,
    tvosSize,
    iosSha256,
    tvosSha256,
    iosURL,
    tvosURL,
  });
  writeJSON(file, source);
  return source;
}

export function sha256File(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

export function assertAssetFile(file, expectedSize, expectedSha256) {
  const size = readFileSync(file).byteLength;
  if (size !== Number(expectedSize)) die(`${file} is ${size} bytes, expected ${expectedSize}`, "asset-mismatch");
  const digest = sha256File(file);
  if (digest !== String(expectedSha256).toLowerCase().replace(/^sha256:/, "")) {
    die(`${file} has SHA-256 ${digest}, expected ${expectedSha256}`, "asset-mismatch");
  }
  return { size, sha256: digest };
}

function responseHeader(response, name) {
  return response.headers?.get?.(name) || "";
}

function assertCacheHeader(response, url) {
  const cacheControl = responseHeader(response, "cache-control").toLowerCase();
  if (!/\bmax-age=\d+/.test(cacheControl)) {
    die(`${url} has no bounded cache-control header`, "route-cache");
  }
}

export async function fetchJSON(url, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const attempts = Number(options.attempts ?? 1);
  const delayMs = Number(options.delayMs ?? 0);
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetchImpl(url, {
        headers: { Accept: "application/json", "Cache-Control": "no-cache", ...(options.headers || {}) },
        redirect: "follow",
      });
      const body = await response.text();
      const contentType = responseHeader(response, "content-type").toLowerCase();
      if (response.status !== 200) throw new ReleaseFeedError(`${url} returned HTTP ${response.status}`, "route-status");
      if (!contentType.includes("application/json") && !contentType.includes("+json")) {
        throw new ReleaseFeedError(`${url} returned ${contentType || "no content type"}, expected JSON`, "route-content-type");
      }
      let value;
      try {
        value = JSON.parse(body);
      } catch {
        throw new ReleaseFeedError(`${url} returned a body that is not JSON`, "route-json");
      }
      return { response, body, value };
    } catch (error) {
      lastError = error;
      if (attempt < attempts && delayMs > 0) await delay(delayMs);
    }
  }
  throw lastError || new ReleaseFeedError(`could not fetch ${url}`, "route-fetch");
}

function stableJSON(value) {
  return JSON.stringify(value);
}

export function assertSameJSON(left, right, label = "routes") {
  if (stableJSON(left) !== stableJSON(right)) die(`${label} returned different JSON bodies`, "route-drift");
}

export async function verifyPublicRoutes(options) {
  const expectedSource = readJSON(options.expectedFile);
  const expected = {
    tag: requireTag(options.tag),
    build: requirePositiveInteger("build", options.build),
    version: String(options.version || String(options.tag).replace(/^v/, "").split("-")[0]),
    iosSize: requirePositiveInteger("ios-size", options.iosSize),
    tvosSize: requirePositiveInteger("tvos-size", options.tvosSize),
    iosSha256: requireSha256("ios-sha256", options.iosSha256),
    tvosSha256: requireSha256("tvos-sha256", options.tvosSha256),
    iosURL: requireDownloadURL("ios-url", options.iosURL || releaseAssetURL(options.tag, "iOS"), options.tag, "iOS"),
    tvosURL: requireDownloadURL("tvos-url", options.tvosURL || releaseAssetURL(options.tag, "tvOS"), options.tag, "tvOS"),
  };
  assertSource(expectedSource, expected);
  const canonicalURL = String(options.canonicalURL || "");
  const compatibilityURL = String(options.compatibilityURL || "");
  if (!canonicalURL || !compatibilityURL) die("--canonical-url and --compatibility-url are required");
  const canonical = await fetchJSON(canonicalURL, options);
  const compatibility = await fetchJSON(compatibilityURL, options);
  assertCacheHeader(canonical.response, canonicalURL);
  assertCacheHeader(compatibility.response, compatibilityURL);
  assertSameJSON(canonical.value, compatibility.value, "canonical and compatibility routes");
  assertSource(canonical.value, expected);

  // Query strings must not select a different generation. This catches the observed stale query
  // route without relying on a particular cache implementation.
  const suffix = options.query || `release-check=${encodeURIComponent(expected.tag)}-${expected.build}`;
  const canonicalQuery = await fetchJSON(`${canonicalURL}${canonicalURL.includes("?") ? "&" : "?"}${suffix}`, options);
  const compatibilityQuery = await fetchJSON(`${compatibilityURL}${compatibilityURL.includes("?") ? "&" : "?"}${suffix}`, options);
  assertCacheHeader(canonicalQuery.response, canonicalQuery.url || canonicalURL);
  assertCacheHeader(compatibilityQuery.response, compatibilityQuery.url || compatibilityURL);
  assertSameJSON(canonical.value, canonicalQuery.value, "canonical route query variant");
  assertSameJSON(compatibility.value, compatibilityQuery.value, "compatibility route query variant");

  const result = { canonical: canonical.value, compatibility: compatibility.value };
  if (options.appcastURL) {
    const appcast = await fetchJSON(String(options.appcastURL), options);
    assertCacheHeader(appcast.response, options.appcastURL);
    assertAppcast(appcast.value, expected);
    result.appcast = appcast.value;
  }
  return result;
}

export function assertAppcast(manifest, expected) {
  if (!manifest || typeof manifest !== "object") die("appcast is not an object", "appcast-schema");
  if (manifest._generatedFromTag !== expected.tag) die("appcast tag does not match release tag", "appcast-build");
  for (const key of ["ios", "tvos", "mac"]) {
    const entry = manifest[key];
    if (!entry || Number(entry.build) !== Number(expected.build)) die(`appcast ${key} build does not match`, "appcast-build");
    if (typeof entry.ipa !== "string" || !entry.ipa.startsWith("https://")) die(`appcast ${key} has no HTTPS asset URL`, "appcast-schema");
    if (!Number.isInteger(Number(entry.size)) || Number(entry.size) <= 0) die(`appcast ${key} has no positive size`, "appcast-schema");
    if (!/^[0-9a-f]{64}$/i.test(String(entry.sha256 || "").replace(/^sha256:/i, ""))) die(`appcast ${key} has no SHA-256`, "appcast-schema");
    if (entry.altstore !== "https://vortx.tv/altstore.json") die(`appcast ${key} has an unexpected AltStore route`, "appcast-schema");
    if (key === "ios" && (entry.ipa !== expected.iosURL || Number(entry.size) !== Number(expected.iosSize) || String(entry.sha256).toLowerCase().replace(/^sha256:/, "") !== expected.iosSha256)) {
      die("appcast iOS metadata differs from the canonical source", "appcast-drift");
    }
    if (key === "tvos" && (entry.ipa !== expected.tvosURL || Number(entry.size) !== Number(expected.tvosSize) || String(entry.sha256).toLowerCase().replace(/^sha256:/, "") !== expected.tvosSha256)) {
      die("appcast tvOS metadata differs from the canonical source", "appcast-drift");
    }
    if (key === "mac" && !entry.ipa.includes(`/download/${expected.tag}/VortX-macOS-${expected.tag}-ci.dmg`)) {
      die("appcast macOS URL is not the release asset", "appcast-drift");
    }
  }
  if (manifest.android !== null && manifest.android !== undefined) {
    const entry = manifest.android;
    if (!entry || typeof entry !== "object" || !String(entry.apk || entry.url || "").startsWith("https://")) {
      die("appcast Android entry is not a valid HTTPS install artifact", "appcast-schema");
    }
  }
  return true;
}

export function main(argv = process.argv.slice(2)) {
  const [command, ...rest] = argv;
  const args = parseArgs(rest);
  if (command === "update-altstore") {
    updateSourceFile({
      file: args.file,
      tag: args.tag,
      build: args.build,
      date: args.date,
      name: args.name,
      note: args.note,
      iosSize: args["ios-size"],
      tvosSize: args["tvos-size"],
      iosSha256: args["ios-sha256"],
      tvosSha256: args["tvos-sha256"],
      iosURL: args["ios-url"],
      tvosURL: args["tvos-url"],
    });
    console.log(`release-feed: updated ${args.file} for ${args.tag} build ${args.build}`);
    return;
  }
  if (command === "verify-source") {
    const source = readJSON(args.file);
    assertSource(source, {
      tag: requireTag(args.tag),
      build: requirePositiveInteger("build", args.build),
      version: args.version || String(args.tag).replace(/^v/, "").split("-")[0],
      iosSize: requirePositiveInteger("ios-size", args["ios-size"]),
      tvosSize: requirePositiveInteger("tvos-size", args["tvos-size"]),
      iosSha256: requireSha256("ios-sha256", args["ios-sha256"]),
      tvosSha256: requireSha256("tvos-sha256", args["tvos-sha256"]),
      iosURL: args["ios-url"],
      tvosURL: args["tvos-url"],
    });
    console.log(`release-feed: verified local source for ${args.tag} build ${args.build}`);
    return;
  }
  if (command === "check-monotonic") {
    assertMonotonic(readJSON(args.file), args.build, args.tag);
    console.log(`release-feed: monotonic guard passed for ${args.tag} build ${args.build}`);
    return;
  }
  if (command === "rollback") {
    if (!args.file || !args.backup) die("rollback requires --file and --backup");
    if (args["only-if-tag"] || args["only-if-build"]) {
      assertRollbackTarget(readJSON(args.file), args["only-if-build"], args["only-if-tag"]);
    }
    copyFileSync(args.backup, args.file);
    console.log(`release-feed: restored ${args.file} from ${args.backup}`);
    return;
  }
  if (command === "verify-asset") {
    if (!args.file) die("verify-asset requires --file");
    assertAssetFile(args.file, requirePositiveInteger("size", args.size), requireSha256("sha256", args.sha256));
    console.log(`release-feed: verified ${args.file}`);
    return;
  }
  if (command === "verify-public") {
    return verifyPublicRoutes({
      expectedFile: args["expected-file"],
      tag: args.tag,
      build: args.build,
      version: args.version,
      iosSize: args["ios-size"],
      tvosSize: args["tvos-size"],
      iosSha256: args["ios-sha256"],
      tvosSha256: args["tvos-sha256"],
      iosURL: args["ios-url"],
      tvosURL: args["tvos-url"],
      canonicalURL: args["canonical-url"],
      compatibilityURL: args["compatibility-url"],
      appcastURL: args["appcast-url"],
      attempts: Number(args.attempts || 1),
      delayMs: Number(args["delay-ms"] || 0),
    }).then(() => console.log(`release-feed: public routes verified for ${args.tag} build ${args.build}`));
  }
  die(`unknown command ${JSON.stringify(command)}; expected update-altstore, verify-source, check-monotonic, verify-asset, verify-public, or rollback`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  Promise.resolve(main()).catch((error) => {
    console.error(`release-feed: ${error.message}`);
    process.exitCode = 1;
  });
}
