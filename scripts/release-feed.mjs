#!/usr/bin/env node

/**
 * Release feed operations shared by the release workflow and deterministic local checks.
 *
 * A release feed is a public install contract, not a release note. Every current entry is
 * therefore derived from the immutable tag and the uploaded asset metadata, and every public
 * route is checked as JSON before the workflow can finish successfully.
 */

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

export const REPOSITORY = "VortXTV/VortX";
export const SOURCE_HISTORY_LIMIT = 8;
export const FEED_ARTIFACT_SCHEMA = 2;
export const MAX_PUBLIC_CACHE_AGE = 300;
export const CANONICAL_ALTSTORE_URL = "https://vortx.tv/altstore.json";
export const COMPATIBILITY_ALTSTORE_URL = "https://vortx.tv/vortx-altstore.json";
export const APPCAST_URL = "https://vortx.tv/appcast.json";
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

// Like cleanProse, but preserves intentional newlines for multi-line fields
// such as release notes. Horizontal whitespace still collapses; blank-line
// runs normalize to a single blank line.
export function cleanMultilineProse(value) {
  return String(value || "")
    .replace(/[\u2012\u2013\u2014\u2015\u2212]/g, "-")
    .replace(/[^\S\n]+/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function releaseAssetURL(tag, slug) {
  requireTag(tag);
  if (!/^[A-Za-z]+$/.test(String(slug))) die(`invalid asset slug ${JSON.stringify(slug)}`);
  return `https://github.com/${REPOSITORY}/releases/download/${tag}/VortX-${slug}-${tag}-ci.ipa`;
}

function requireDownloadURL(name, value, tag, slug, extension = "ipa") {
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
  const expected = new URL(`https://github.com/${REPOSITORY}/releases/download/${tag}/${releaseAssetName(tag, slug, extension)}`);
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
  const directory = dirname(file);
  mkdirSync(directory, { recursive: true });
  const temporary = join(directory, `.${file.split("/").pop()}.tmp-${process.pid}`);
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o644 });
  renameSync(temporary, file);
}

function writeTextAtomic(file, text) {
  const directory = dirname(file);
  mkdirSync(directory, { recursive: true });
  const temporary = join(directory, `.${file.split("/").pop()}.tmp-${process.pid}`);
  writeFileSync(temporary, text, { mode: 0o644 });
  renameSync(temporary, file);
}

function readText(file) {
  try {
    return readFileSync(file, "utf8");
  } catch (error) {
    die(`cannot read ${file}: ${error.message}`);
  }
}

export function projectBuildFromYmlText(content) {
  const builds = [...String(content).matchAll(/CURRENT_PROJECT_VERSION:\s*"([0-9]+)"/g)].map((match) => match[1]);
  if (builds.length !== 6) die(`app/project.yml must contain exactly six CURRENT_PROJECT_VERSION values (found ${builds.length})`, "project-build");
  if (new Set(builds).size !== 1) die(`app/project.yml build values disagree: ${builds.join(", ")}`, "project-build");
  return requirePositiveInteger("project-build", builds[0]);
}

export function projectBuildFromYml(file) {
  return projectBuildFromYmlText(readText(file));
}

function normalizedDigest(value) {
  return String(value || "").toLowerCase().replace(/^sha256:/, "");
}

function releaseAssetName(tag, slug, extension = "ipa") {
  requireTag(tag);
  if (!/^[A-Za-z-]+$/.test(String(slug))) die(`invalid asset slug ${JSON.stringify(slug)}`);
  return `VortX-${slug}-${tag}-ci.${extension}`;
}

export function buildAppcast({
  tag,
  build,
  version,
  name,
  notes,
  prerelease,
  ios,
  tvos,
  mac,
  android = null,
  sourceCommit = null,
}) {
  const releaseTag = requireTag(tag);
  const releaseBuild = requirePositiveInteger("build", build);
  const releaseVersion = String(version || releaseTag.replace(/^v/, "").split("-", 1)[0]);
  const releaseName = cleanProse(name) || releaseTag;
  const releaseNotes = cleanMultilineProse(notes) || `${releaseName}. One-tap update over any earlier build, nothing resets.`;
  const entry = (platform, artifact, altstore, artifactType) => {
    if (!artifact || typeof artifact !== "object") die(`missing ${platform} artifact metadata`, "appcast-schema");
    const url = String(artifact.url || "");
    const slug = artifact.slug || (platform === "mac" ? "macOS" : platform === "tvos" ? "tvOS" : "iOS");
    requireDownloadURL(`${platform}-url`, url, releaseTag, slug, artifact.extension || "ipa");
    const size = requirePositiveInteger(`${platform}-size`, artifact.size);
    const sha256 = requireSha256(`${platform}-sha256`, artifact.sha256);
    return {
      tag: releaseTag,
      version: releaseVersion,
      build: releaseBuild,
      name: releaseName,
      notes: releaseNotes,
      prerelease: Boolean(prerelease),
      ipa: url,
      url,
      size,
      sha256,
      altstore: altstore || null,
      artifactType,
    };
  };
  if (android !== null && (typeof android !== "object" || Array.isArray(android))) {
    die("Android appcast entry must be split into full/play flavor objects", "appcast-android");
  }
  if (android !== null && ("signed" in android || "url" in android || "sha256" in android || "apk" in android)) {
    die("Android appcast entry must be split into full/play flavor objects", "appcast-android");
  }
  const appcast = {
    schemaVersion: FEED_ARTIFACT_SCHEMA,
    _generatedFromTag: releaseTag,
    _generatedFromCommit: sourceCommit || undefined,
    ios: entry("ios", { ...ios, slug: "iOS" }, CANONICAL_ALTSTORE_URL, "ipa"),
    tvos: entry("tvos", { ...tvos, slug: "tvOS" }, null, "ipa"),
    mac: entry("mac", { ...mac, slug: "macOS", extension: "dmg" }, null, "dmg"),
    android: android === null ? null : Object.fromEntries(Object.entries(android).map(([flavor, artifact]) => [flavor, artifact === null ? null : {
      ...artifact,
      tag: releaseTag,
      name: releaseName,
      notes: releaseNotes,
    }])),
  };
  assertAppcast(appcast, {
    tag: releaseTag,
    build: releaseBuild,
    version: releaseVersion,
    name: releaseName,
    notes: releaseNotes,
    prerelease: Boolean(prerelease),
    iosURL: appcast.ios.url,
    iosSize: appcast.ios.size,
    iosSha256: appcast.ios.sha256,
    tvosURL: appcast.tvos.url,
    tvosSize: appcast.tvos.size,
    tvosSha256: appcast.tvos.sha256,
    macURL: appcast.mac.url,
    macSize: appcast.mac.size,
    macSha256: appcast.mac.sha256,
  });
  return appcast;
}

function checksumEntries(text) {
  const entries = new Map();
  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    const match = line.match(/^([0-9a-fA-F]{64})\s+\*?(?:out\/)?([^\s]+)$/);
    if (!match) die(`checksum file contains an invalid line: ${rawLine}`, "checksum-invalid");
    if (entries.has(match[2])) die(`checksum file contains a duplicate entry for ${match[2]}`, "checksum-duplicate");
    entries.set(match[2], match[1].toLowerCase());
  }
  return entries;
}

export function assertChecksumFile(file, expectedFiles) {
  const text = readText(file);
  const entries = checksumEntries(text);
  const expectedNames = new Set(expectedFiles.map((expected) => String(expected.checksumName || expected.name)));
  if (entries.size !== expectedNames.size || [...entries.keys()].some((name) => !expectedNames.has(name))) {
    die("checksum file contains an unexpected or missing asset entry", "checksum-set");
  }
  for (const expected of expectedFiles) {
    const name = String(expected.checksumName || expected.name);
    const digest = entries.get(name);
    if (!digest) die(`checksum file has no entry for ${name}`, "checksum-missing");
    if (digest !== normalizedDigest(expected.sha256)) {
      die(`checksum file digest for ${name} differs from trusted local bytes`, "checksum-mismatch");
    }
  }
  return { text, sha256: sha256Buffer(text) };
}

function sha256Buffer(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function buildReleaseFeedArtifact(options) {
  const tag = requireTag(options.tag);
  const build = requirePositiveInteger("build", options.build);
  const sourceCommit = String(options.sourceCommit || "");
  if (!/^[0-9a-f]{40}$/i.test(sourceCommit)) die("--source-commit must be a 40-character commit SHA");
  const output = String(options.output || "");
  if (!output) die("--output is required");
  mkdirSync(output, { recursive: true });
  const sourceFile = join(output, "source.json");
  copyFileSync(String(options.sourceTemplate || ""), sourceFile);
  const date = String(options.date || new Date().toISOString().slice(0, 10));
  const name = cleanProse(options.name) || tag;
  const note = cleanMultilineProse(options.note);
  const assets = {
    ios: { file: String(options.iosFile || ""), name: releaseAssetName(tag, "iOS") },
    tvos: { file: String(options.tvosFile || ""), name: releaseAssetName(tag, "tvOS") },
    tvosLite: { file: String(options.tvosLiteFile || ""), name: releaseAssetName(tag, "tvOS-lite") },
    mac: { file: String(options.macFile || ""), name: releaseAssetName(tag, "macOS", "dmg") },
  };
  for (const [key, asset] of Object.entries(assets)) {
    if (!asset.file || !existsSync(asset.file)) die(`missing ${key} build artifact ${asset.file}`, "asset-missing");
    const metadata = assertAssetFile(asset.file, readFileSync(asset.file).byteLength, sha256File(asset.file));
    asset.size = metadata.size;
    asset.sha256 = metadata.sha256;
    asset.checksumName = asset.file.split("/").pop();
    asset.url = `https://github.com/${REPOSITORY}/releases/download/${tag}/${asset.name}`;
  }
  const checksum = assertChecksumFile(options.checksumFile, Object.values(assets));
  updateSourceFile({
    file: sourceFile,
    tag,
    build,
    date,
    name,
    note,
    iosSize: assets.ios.size,
    tvosSize: assets.tvos.size,
    iosSha256: assets.ios.sha256,
    tvosSha256: assets.tvos.sha256,
    iosURL: assets.ios.url,
    tvosURL: assets.tvos.url,
  });
  const appcast = buildAppcast({
    tag,
    build,
    version: tag.replace(/^v/, "").split("-", 1)[0],
    name,
    notes: note,
    prerelease: tag.includes("-"),
    sourceCommit,
    ios: assets.ios,
    tvos: assets.tvos,
    mac: assets.mac,
    android: null,
  });
  const appcastFile = join(output, "appcast.json");
  writeJSON(appcastFile, appcast);
  const sourceText = readText(sourceFile);
  const appcastText = readText(appcastFile);
  const feedSha256 = sha256Buffer(`${sourceText}\n${appcastText}\n${checksum.text}`);
  const manifest = {
    schemaVersion: FEED_ARTIFACT_SCHEMA,
    tag,
    build,
    version: tag.replace(/^v/, "").split("-", 1)[0],
    name,
    notes: cleanMultilineProse(note) || `${name}. One-tap update over any earlier build, nothing resets.`,
    prerelease: tag.includes("-"),
    sourceCommit,
    releaseId: options.releaseId ? String(options.releaseId) : null,
    generation: `${tag}:${build}:${feedSha256}`,
    feedSha256,
    sourceSha256: sha256Buffer(sourceText),
    appcastSha256: sha256Buffer(appcastText),
    checksumSha256: checksum.sha256,
    assets: Object.fromEntries(Object.entries(assets).map(([key, asset]) => [key, {
      name: asset.name,
      checksumName: asset.checksumName,
      url: asset.url,
      size: asset.size,
      sha256: asset.sha256,
      state: "trusted-local",
      assetId: null,
    }])),
    android: null,
  };
  writeJSON(join(output, "manifest.json"), manifest);
  writeTextAtomic(join(output, "SHA256SUMS-ci.txt"), checksum.text);
  return { manifest, sourceText, appcastText, checksumText: checksum.text };
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
  const note = cleanMultilineProse(options.note);
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

function assertCacheHeader(response, url, maxAge = MAX_PUBLIC_CACHE_AGE) {
  const cacheControl = responseHeader(response, "cache-control").toLowerCase();
  if (!cacheControl || /\bimmutable\b|\bno-store\b/.test(cacheControl)) {
    die(`${url} has an unsafe cache-control policy`, "route-cache");
  }
  const maxAgeMatch = cacheControl.match(/(?:^|,)\s*max-age=(\d+)/);
  const sharedAgeMatch = cacheControl.match(/(?:^|,)\s*s-maxage=(\d+)/);
  if (!maxAgeMatch) {
    die(`${url} has no bounded cache-control header`, "route-cache");
  }
  const publicAge = Number(maxAgeMatch[1]);
  const sharedAge = sharedAgeMatch ? Number(sharedAgeMatch[1]) : publicAge;
  if (!Number.isInteger(publicAge) || !Number.isInteger(sharedAge) || publicAge < 0 || sharedAge < 0 || publicAge > maxAge || sharedAge > maxAge) {
    die(`${url} has a cache age outside the bounded release-feed policy`, "route-cache");
  }
  if (sharedAgeMatch && sharedAge !== publicAge) {
    die(`${url} has conflicting max-age and s-maxage values`, "route-cache");
  }
}

export async function fetchJSON(url, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const attempts = Number(options.attempts ?? 1);
  const delayMs = Number(options.delayMs ?? 0);
  const timeoutMs = Number(options.timeoutMs ?? 12_000);
  const deadline = Number(options.deadline || 0);
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    if (deadline && Date.now() + Math.max(timeoutMs, 0) > deadline) {
      throw new ReleaseFeedError(`${url} exceeded the verification deadline`, "verification-deadline");
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(url, {
        headers: { Accept: "application/json", "Cache-Control": "no-cache", ...(options.headers || {}) },
        redirect: "follow",
        signal: controller.signal,
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
    } finally {
      clearTimeout(timeout);
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
  const expectedSourceBody = readText(options.expectedFile);
  const deadlineMs = Number(options.deadlineMs ?? 300_000);
  const rollbackBudgetMs = Number(options.rollbackBudgetMs ?? 30_000);
  const deadline = Date.now() + Math.max(1, deadlineMs - rollbackBudgetMs);
  const expected = {
    tag: requireTag(options.tag),
    build: requirePositiveInteger("build", options.build),
    version: String(options.version || String(options.tag).replace(/^v/, "").split("-")[0]),
    name: cleanProse(options.name) || String(options.tag),
    notes: cleanMultilineProse(options.notes || options.note) || `${cleanProse(options.name) || String(options.tag)}. One-tap update over any earlier build, nothing resets.`,
    prerelease: options.prerelease === undefined ? String(options.tag).includes("-") : String(options.prerelease) === "true",
    iosSize: requirePositiveInteger("ios-size", options.iosSize),
    tvosSize: requirePositiveInteger("tvos-size", options.tvosSize),
    iosSha256: requireSha256("ios-sha256", options.iosSha256),
    tvosSha256: requireSha256("tvos-sha256", options.tvosSha256),
    macSize: requirePositiveInteger("mac-size", options.macSize),
    macSha256: requireSha256("mac-sha256", options.macSha256),
    iosURL: requireDownloadURL("ios-url", options.iosURL || releaseAssetURL(options.tag, "iOS"), options.tag, "iOS"),
    tvosURL: requireDownloadURL("tvos-url", options.tvosURL || releaseAssetURL(options.tag, "tvOS"), options.tag, "tvOS"),
    macURL: requireDownloadURL("mac-url", options.macURL, options.tag, "macOS", "dmg"),
  };
  assertSource(expectedSource, expected);
  const canonicalURL = String(options.canonicalURL || "");
  const compatibilityURL = String(options.compatibilityURL || "");
  if (!canonicalURL || !compatibilityURL) die("--canonical-url and --compatibility-url are required");
  const fetchOptions = { ...options, deadline };
  const canonical = await fetchJSON(canonicalURL, fetchOptions);
  const compatibility = await fetchJSON(compatibilityURL, fetchOptions);
  assertCacheHeader(canonical.response, canonicalURL, options.maxCacheAge || MAX_PUBLIC_CACHE_AGE);
  assertCacheHeader(compatibility.response, compatibilityURL, options.maxCacheAge || MAX_PUBLIC_CACHE_AGE);
  if (canonical.body !== expectedSourceBody) die("canonical route body differs from the exact staged source bytes", "route-byte-drift");
  if (compatibility.body !== expectedSourceBody) die("compatibility route body differs from the exact staged source bytes", "route-byte-drift");
  if (canonical.body !== compatibility.body) die("canonical and compatibility route bytes differ", "route-byte-drift");
  assertSameJSON(canonical.value, compatibility.value, "canonical and compatibility routes");
  assertSource(canonical.value, expected);

  // Query strings must not select a different generation. This catches the observed stale query
  // route without relying on a particular cache implementation.
  const suffix = options.query || `release-check=${encodeURIComponent(expected.tag)}-${expected.build}`;
  const canonicalQuery = await fetchJSON(`${canonicalURL}${canonicalURL.includes("?") ? "&" : "?"}${suffix}`, fetchOptions);
  const compatibilityQuery = await fetchJSON(`${compatibilityURL}${compatibilityURL.includes("?") ? "&" : "?"}${suffix}`, fetchOptions);
  assertCacheHeader(canonicalQuery.response, canonicalQuery.url || canonicalURL, options.maxCacheAge || MAX_PUBLIC_CACHE_AGE);
  assertCacheHeader(compatibilityQuery.response, compatibilityQuery.url || compatibilityURL, options.maxCacheAge || MAX_PUBLIC_CACHE_AGE);
  if (canonicalQuery.body !== expectedSourceBody || compatibilityQuery.body !== expectedSourceBody) {
    die("query variant returned bytes different from the exact staged source", "route-query-drift");
  }
  assertSameJSON(canonical.value, canonicalQuery.value, "canonical route query variant");
  assertSameJSON(compatibility.value, compatibilityQuery.value, "compatibility route query variant");

  const result = { canonical: canonical.value, compatibility: compatibility.value };
  if (options.appcastURL) {
    const appcast = await fetchJSON(String(options.appcastURL), fetchOptions);
    assertCacheHeader(appcast.response, options.appcastURL, options.maxCacheAge || MAX_PUBLIC_CACHE_AGE);
    assertAppcast(appcast.value, expected);
    result.appcast = appcast.value;
  }
  return result;
}

export function assertAppcast(manifest, expected) {
  if (!manifest || typeof manifest !== "object") die("appcast is not an object", "appcast-schema");
  if (manifest.schemaVersion !== FEED_ARTIFACT_SCHEMA) die("appcast schemaVersion is not current", "appcast-schema");
  if (manifest._generatedFromTag !== expected.tag) die("appcast tag does not match release tag", "appcast-build");
  const expectedPlatforms = {
    ios: { url: expected.iosURL, size: expected.iosSize, sha256: expected.iosSha256, altstore: CANONICAL_ALTSTORE_URL, artifactType: "ipa" },
    tvos: { url: expected.tvosURL, size: expected.tvosSize, sha256: expected.tvosSha256, altstore: null, artifactType: "ipa" },
    mac: { url: expected.macURL, size: expected.macSize, sha256: expected.macSha256, altstore: null, artifactType: "dmg" },
  };
  for (const key of Object.keys(expectedPlatforms)) {
    const entry = manifest[key];
    if (!entry || Number(entry.build) !== Number(expected.build)) die(`appcast ${key} build does not match`, "appcast-build");
    const platform = expectedPlatforms[key];
    if (entry.tag !== expected.tag || entry.version !== expected.version || entry.name !== expected.name || entry.notes !== expected.notes || Boolean(entry.prerelease) !== Boolean(expected.prerelease)) {
      die(`appcast ${key} identity or release metadata differs`, "appcast-drift");
    }
    if (typeof entry.ipa !== "string" || entry.ipa !== platform.url || entry.url !== platform.url || !entry.ipa.startsWith("https://")) die(`appcast ${key} has an unexpected HTTPS asset URL`, "appcast-drift");
    if (Number(entry.size) !== Number(platform.size) || normalizedDigest(entry.sha256) !== normalizedDigest(platform.sha256)) die(`appcast ${key} size or SHA-256 differs from trusted asset metadata`, "appcast-drift");
    if (entry.altstore !== platform.altstore || entry.artifactType !== platform.artifactType) die(`appcast ${key} install route or artifact type is incorrect`, "appcast-schema");
  }
  if (manifest.android === null) return true;
  const android = manifest.android;
  if (!android || typeof android !== "object" || Array.isArray(android)) {
    die("appcast Android entry must be split into full/play flavor objects", "appcast-schema");
  }
  if ("signed" in android || "url" in android || "sha256" in android || "apk" in android) {
    die("appcast Android entry must be split into full/play flavor objects", "appcast-schema");
  }
  const flavors = {
    full: { engine: "mpv", artifacts: { apk: "VortX-${version}-full-mpv-universal.apk" } },
    play: { engine: "media3", artifacts: { apk: "VortX-${version}-play-media3-universal.apk", aab: "VortX-${version}-play-media3.aab" } },
  };
  let foundFlavor = false;
  for (const [flavor, entry] of Object.entries(android)) {
    const flavorContract = flavors[flavor];
    if (!flavorContract) die(`appcast Android entry has unknown flavor ${JSON.stringify(flavor)}`, "appcast-schema");
    if (entry === null || entry === undefined) continue;
    foundFlavor = true;
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      die(`appcast Android ${flavor} entry must be an object`, "appcast-schema");
    }
    const requiredFields = ["tag", "version", "build", "name", "notes", "prerelease", "applicationId", "engine", "artifactType", "signed", "url", "size", "sha256", "signer"];
    if (requiredFields.some((field) => !(field in entry))) {
      die(`appcast Android ${flavor} entry is missing required schema fields`, "appcast-schema");
    }
    if (entry.applicationId !== "com.vortx.android" || entry.engine !== flavorContract.engine || !Object.hasOwn(flavorContract.artifacts, entry.artifactType)) {
      die(`appcast Android ${flavor} flavor, engine, or artifact type is invalid`, "appcast-schema");
    }
    if (entry.tag !== expected.tag || entry.version !== expected.version || entry.name !== expected.name || entry.notes !== expected.notes || !Number.isInteger(entry.build) || entry.build !== Number(expected.build) || entry.signed !== true || entry.prerelease !== Boolean(expected.prerelease)) {
      die(`appcast Android ${flavor} release metadata or signing state differs`, "appcast-drift");
    }
    const assetName = flavorContract.artifacts[entry.artifactType].replace("${version}", expected.version);
    const expectedURL = `https://github.com/${REPOSITORY}/releases/download/${expected.tag}/${assetName}`;
    let parsed;
    try {
      if (typeof entry.url !== "string") throw new TypeError("URL must be a string");
      parsed = new URL(entry.url);
    } catch {
      die(`appcast Android ${flavor} URL is invalid`, "appcast-schema");
    }
    if (parsed.protocol !== "https:" || parsed.hostname !== "github.com" || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.href !== expectedURL) {
      die(`appcast Android ${flavor} URL must be the immutable VortXTV/VortX release asset without credentials, query, or fragment`, "appcast-drift");
    }
    if (!Number.isInteger(entry.size) || entry.size <= 0 || entry.size > FEED_CAPS.artifactBytes || typeof entry.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(entry.sha256) || typeof entry.signer !== "string" || entry.signer.length === 0 || entry.signer.length > 256) {
      die(`appcast Android ${flavor} artifact metadata is invalid`, "appcast-schema");
    }
  }
  if (!foundFlavor) die("appcast Android entry must contain a full or play flavor", "appcast-schema");
  return true;
}

// =================================================================================================
// Release feed artifact validation (t22: split Android, client caps, tag/versionName coherence)
// =================================================================================================

// Client-compatible field caps. These bounds protect every downstream consumer (updater, appcast
// reader, AltStore source generator) from oversized payloads that would blow parsing budgets or
// UI layouts. They are generous enough for any real release but tight enough to catch accidents.
export const FEED_CAPS = Object.freeze({
  manifestBytes: 512 * 1024,     // 512 KiB total manifest
  artifactBytes: 1 * 1024 * 1024 * 1024, // 1 GiB per artifact
  versionLength: 64,             // version string max chars
  nameLength: 200,               // release name max chars
  notesLength: 20_000,           // release notes max chars
});

const VALID_ANDROID_FLAVORS = Object.freeze(["full", "play"]);
const VALID_ANDROID_ARTIFACT_TYPES = Object.freeze(["apk", "aab"]);
const ANDROID_APPLICATION_ID = "com.vortx.android";

function assertStringField(obj, field, label, maxLength) {
  const value = obj[field];
  if (typeof value !== "string" || value.length === 0) {
    die(`${label} must be a non-empty string (field: ${field})`, "feed-schema");
  }
  if (maxLength && value.length > maxLength) {
    die(`${label}.${field} exceeds ${maxLength} characters (got ${value.length})`, "feed-caps");
  }
  return value;
}

function assertHTTPSURL(value, label) {
  if (typeof value !== "string" || !value.startsWith("https://")) {
    die(`${label} must be an HTTPS URL (got ${JSON.stringify(value)})`, "feed-schema");
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    die(`${label} is not a valid URL`, "feed-schema");
  }
  if (parsed.protocol !== "https:") {
    die(`${label} must use HTTPS`, "feed-schema");
  }
  return value;
}

function assertLowerHex64(value, label) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    die(`${label} must be a lower-case 64-character hex SHA-256 digest (got ${JSON.stringify(value)})`, "feed-schema");
  }
  return value;
}

function assertPositiveInt(value, label, max) {
  if (!Number.isInteger(value) || value <= 0) {
    die(`${label} must be a positive integer (got ${JSON.stringify(value)})`, "feed-schema");
  }
  if (max && value > max) {
    die(`${label} exceeds maximum ${max} (got ${value})`, "feed-caps");
  }
  return value;
}

function validateAndroidFlavorEntry(flavor, entry, tagVersion, build, prerelease) {
  const label = `android.${flavor}`;
  if (!entry || typeof entry !== "object") {
    die(`${label} must be an object`, "feed-schema");
  }
  // Required metadata fields
  assertStringField(entry, "applicationId", label, null);
  if (entry.applicationId !== ANDROID_APPLICATION_ID) {
    die(`${label}.applicationId must be ${ANDROID_APPLICATION_ID} (got ${JSON.stringify(entry.applicationId)})`, "feed-schema");
  }
  assertStringField(entry, "engine", label, null);
  if (flavor === "full" && entry.engine !== "mpv") {
    die(`${label}.engine must be "mpv" for the full flavor (got ${JSON.stringify(entry.engine)})`, "feed-schema");
  }
  if (flavor === "play" && entry.engine !== "media3") {
    die(`${label}.engine must be "media3" for the play flavor (got ${JSON.stringify(entry.engine)})`, "feed-schema");
  }
  // Artifact type
  if (!VALID_ANDROID_ARTIFACT_TYPES.includes(entry.artifactType)) {
    die(`${label}.artifactType must be one of ${VALID_ANDROID_ARTIFACT_TYPES.join(", ")} (got ${JSON.stringify(entry.artifactType)})`, "feed-schema");
  }
  // Version coherence
  assertStringField(entry, "version", label, FEED_CAPS.versionLength);
  if (entry.version !== tagVersion) {
    die(`${label}.version must equal the tag version ${tagVersion} (got ${JSON.stringify(entry.version)})`, "feed-coherence");
  }
  // Build number
  if (!Number.isInteger(entry.build) || entry.build !== build) {
    die(`${label}.build must equal the release build ${build} (got ${JSON.stringify(entry.build)})`, "feed-coherence");
  }
  // Signing
  if (entry.signed !== true) {
    die(`${label}.signed must be true`, "feed-schema");
  }
  // URL
  assertHTTPSURL(entry.url, `${label}.url`);
  // Size
  assertPositiveInt(entry.size, `${label}.size`, FEED_CAPS.artifactBytes);
  // SHA-256 (must be lower-case 64-hex)
  assertLowerHex64(entry.sha256, `${label}.sha256`);
  // Signer (compact, non-empty)
  assertStringField(entry, "signer", label, null);
  if (entry.signer.length > 256) {
    die(`${label}.signer is too long (${entry.signer.length} chars); expected a compact fingerprint`, "feed-caps");
  }
  // Prerelease coherence
  if (Boolean(entry.prerelease) !== Boolean(prerelease)) {
    die(`${label}.prerelease must match the release prerelease flag`, "feed-coherence");
  }
  return true;
}

/**
 * Validate a release feed artifact (manifest.json) against the full schema contract.
 *
 * Enforces:
 *   - schemaVersion exactly 2
 *   - Split android.full and android.play independently validated
 *   - Android-only releases accepted (no ios/tvos/mac required when android present alone)
 *   - Client-compatible caps on all string/size fields
 *   - Exact APK metadata: applicationId, engine, artifactType, lower-case 64-hex SHA-256,
 *     compact pinned signer, HTTPS artifact URL
 *   - Tag version equals Android versionName and coherent build/version fields
 *   - Flat root.android metadata rejected (must be split into full/play)
 *
 * @param {object|string} artifact - The manifest object or its JSON text
 * @param {object} [options] - Optional overrides
 * @param {string} [options.tagVersion] - Expected tag-derived version (e.g. "0.3.14")
 * @returns {{valid: boolean, androidFlavors: string[], hasApple: boolean}}
 */
export function validateReleaseFeedArtifact(artifact, options = {}) {
  let manifest;
  if (typeof artifact === "string") {
    // Check manifest size cap on raw text
    if (Buffer.byteLength(artifact, "utf8") > FEED_CAPS.manifestBytes) {
      die(`manifest exceeds ${FEED_CAPS.manifestBytes} bytes (${Buffer.byteLength(artifact, "utf8")} bytes)`, "feed-caps");
    }
    try {
      manifest = JSON.parse(artifact);
    } catch (error) {
      die(`manifest is not valid JSON: ${error.message}`, "feed-schema");
    }
  } else {
    manifest = artifact;
  }
  if (!manifest || typeof manifest !== "object") {
    die("manifest must be a JSON object", "feed-schema");
  }
  // schemaVersion must be exactly 2
  if (manifest.schemaVersion !== FEED_ARTIFACT_SCHEMA) {
    die(`schemaVersion must be exactly ${FEED_ARTIFACT_SCHEMA} (got ${JSON.stringify(manifest.schemaVersion)})`, "feed-schema");
  }
  // Top-level identity fields with caps
  const tag = assertStringField(manifest, "tag", "manifest", null);
  if (!RELEASE_TAG_RE.test(tag)) {
    die(`manifest.tag must be a valid release tag (got ${JSON.stringify(tag)})`, "feed-schema");
  }
  const build = assertPositiveInt(manifest.build, "manifest.build", null);
  const version = assertStringField(manifest, "version", "manifest", FEED_CAPS.versionLength);
  const tagVersion = options.tagVersion || tag.replace(/^v/, "").split("-", 1)[0];
  if (version !== tagVersion) {
    die(`manifest.version must equal the tag-derived version ${tagVersion} (got ${JSON.stringify(version)})`, "feed-coherence");
  }
  assertStringField(manifest, "name", "manifest", FEED_CAPS.nameLength);
  if (manifest.notes !== undefined && manifest.notes !== null) {
    assertStringField(manifest, "notes", "manifest", FEED_CAPS.notesLength);
  }
  // Source commit
  if (manifest.sourceCommit !== undefined && manifest.sourceCommit !== null) {
    if (typeof manifest.sourceCommit !== "string" || !/^[0-9a-f]{40}$/i.test(manifest.sourceCommit)) {
      die("manifest.sourceCommit must be a 40-character commit SHA", "feed-schema");
    }
  }
  // Detect Apple platforms
  const hasIos = manifest.ios !== undefined && manifest.ios !== null;
  const hasTvos = manifest.tvos !== undefined && manifest.tvos !== null;
  const hasMac = manifest.mac !== undefined && manifest.mac !== null;
  const hasApple = hasIos || hasTvos || hasMac;
  // Android validation
  const android = manifest.android;
  if (android === null || android === undefined) {
    // No Android entry at all: acceptable (Apple-only release)
    return { valid: true, androidFlavors: [], hasApple };
  }
  // Reject flat root.android (must be split into full/play sub-objects)
  if (typeof android !== "object" || Array.isArray(android)) {
    die("manifest.android must be an object with split flavor entries (full/play), not a flat value", "feed-schema");
  }
  // If android has top-level signing fields (flat format), reject
  if ("signed" in android || "url" in android || "sha256" in android || "apk" in android) {
    die("manifest.android must use split flavor entries (android.full, android.play); flat root.android metadata is rejected", "feed-schema");
  }
  const foundFlavors = [];
  for (const flavor of VALID_ANDROID_FLAVORS) {
    if (android[flavor] !== undefined && android[flavor] !== null) {
      validateAndroidFlavorEntry(flavor, android[flavor], tagVersion, build, manifest.prerelease);
      foundFlavors.push(flavor);
    }
  }
  if (foundFlavors.length === 0) {
    die("manifest.android must contain at least one flavor entry (full or play)", "feed-schema");
  }
  // Reject unknown flavors
  for (const key of Object.keys(android)) {
    if (!VALID_ANDROID_FLAVORS.includes(key)) {
      die(`manifest.android contains unknown flavor "${key}"; only ${VALID_ANDROID_FLAVORS.join(", ")} are permitted`, "feed-schema");
    }
  }
  return { valid: true, androidFlavors: foundFlavors, hasApple };
}

export function main(argv = process.argv.slice(2)) {
  const [command, ...rest] = argv;
  const args = parseArgs(rest);
  if (command === "project-build") {
    console.log(projectBuildFromYml(args.file || "app/project.yml"));
    return;
  }
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
    if (!args.file || !args.backup || !args["expected-current-sha256"] || !args["expected-generation"] || !args["restore-generation"]) {
      die("rollback requires --file, --backup, --expected-current-sha256, --expected-generation, and --restore-generation");
    }
    const currentSha = sha256File(args.file);
    if (currentSha !== requireSha256("expected-current-sha256", args["expected-current-sha256"])) {
      die("rollback refused because the current feed bytes changed", "rollback-cas");
    }
    const generationFile = args["generation-file"] || `${args.file}.generation`;
    const backupGenerationFile = args["backup-generation-file"] || `${args.backup}.generation`;
    if (!existsSync(generationFile) || !existsSync(backupGenerationFile)) {
      die("rollback requires generation sidecars for exact CAS", "rollback-generation");
    }
    if (readText(generationFile).trim() !== String(args["expected-generation"])) {
      die("rollback refused because the current generation changed", "rollback-cas");
    }
    if (readText(backupGenerationFile).trim() !== String(args["restore-generation"])) {
      die("rollback refused because the restore generation is not the trusted backup", "rollback-generation");
    }
    const temporary = `${args.file}.rollback-${process.pid}`;
    copyFileSync(args.backup, temporary);
    renameSync(temporary, args.file);
    const generationTemporary = `${generationFile}.rollback-${process.pid}`;
    copyFileSync(backupGenerationFile, generationTemporary);
    renameSync(generationTemporary, generationFile);
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
      name: args.name,
      note: args.note,
      notes: args.notes,
      prerelease: args.prerelease,
      iosSize: args["ios-size"],
      tvosSize: args["tvos-size"],
      iosSha256: args["ios-sha256"],
      tvosSha256: args["tvos-sha256"],
      macSize: args["mac-size"],
      macSha256: args["mac-sha256"],
      iosURL: args["ios-url"],
      tvosURL: args["tvos-url"],
      macURL: args["mac-url"],
      canonicalURL: args["canonical-url"],
      compatibilityURL: args["compatibility-url"],
      appcastURL: args["appcast-url"],
      attempts: Number(args.attempts || 1),
      delayMs: Number(args["delay-ms"] || 0),
      timeoutMs: Number(args["timeout-ms"] || 12000),
      deadlineMs: Number(args["deadline-ms"] || 300000),
      rollbackBudgetMs: Number(args["rollback-budget-ms"] || 30000),
    }).then(() => console.log(`release-feed: public routes verified for ${args.tag} build ${args.build}`));
  }
  if (command === "build-artifact") {
    const result = buildReleaseFeedArtifact({
      tag: args.tag,
      build: args.build,
      sourceCommit: args["source-commit"],
      sourceTemplate: args["source-template"],
      output: args.output,
      iosFile: args["ios-file"],
      tvosFile: args["tvos-file"],
      tvosLiteFile: args["tvos-lite-file"],
      macFile: args["mac-file"],
      checksumFile: args["checksum-file"],
      date: args.date,
      name: args.name,
      note: args.note,
      releaseId: args["release-id"],
    });
    console.log(`release-feed: built ${result.manifest.generation}`);
    return;
  }
  if (command === "validate-android-feed") {
    if (!args.file) die("validate-android-feed requires --file");
    const raw = readText(args.file);
    const result = validateReleaseFeedArtifact(raw, { tagVersion: args["tag-version"] });
    console.log(`release-feed: validated ${args.file} (flavors: ${result.androidFlavors.join(", ") || "none"}, apple: ${result.hasApple})`);
    return;
  }
  die(`unknown command ${JSON.stringify(command)}; expected project-build, update-altstore, verify-source, check-monotonic, verify-asset, verify-public, build-artifact, validate-android-feed, or rollback`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  Promise.resolve(main()).catch((error) => {
    console.error(`release-feed: ${error.message}`);
    process.exitCode = 1;
  });
}
