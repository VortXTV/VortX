#!/usr/bin/env node

/**
 * Prepares, but never sends by default, a one-time Durable Object integrity
 * repair receipt. This exists solely for migrating a verified legacy feed
 * generation (for example the malformed Beta 18 record) into authoritative
 * Durable Object storage after an operator has independently checked its
 * immutable release assets.
 */

import { createHash, createHmac } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

function usage(message) {
  throw new Error(`${message || "invalid arguments"}; usage: repair-release-feed.mjs --manifest FILE --source FILE --appcast FILE --checksum FILE --legacy-receipt FILE --expected-generation LEGACY_GENERATION --out FILE [--execute --endpoint https://vortx.tv/__release/receipt]`);
}

function args(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) continue;
    const value = argv[index + 1];
    result[key.slice(2)] = value && !value.startsWith("--") ? value : true;
    if (result[key.slice(2)] !== true) index += 1;
  }
  return result;
}

const options = args(process.argv.slice(2));
for (const required of ["manifest", "source", "appcast", "checksum", "legacy-receipt", "expected-generation", "out"]) {
  if (!options[required] || options[required] === true) usage(`--${required} is required`);
}
let manifest;
try {
  manifest = JSON.parse(readFileSync(options.manifest, "utf8"));
} catch (error) {
  usage(`invalid manifest: ${error.message}`);
}
if (manifest?.schemaVersion !== 2 || !/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/.test(manifest?.tag || "") || !/^\d+$/.test(String(manifest?.releaseId || "")) || manifest.android !== null || manifest.prerelease !== true || options["expected-generation"] === manifest.generation) {
  usage("manifest must be an Apple-only schema 2 immutable release receipt");
}
const legacy = JSON.parse(readFileSync(options["legacy-receipt"], "utf8"));
const canonical = (value) => Array.isArray(value) ? value.map(canonical) : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])])) : value;
const legacyDigest = createHash("sha256").update(JSON.stringify(canonical(legacy))).digest("hex");
if (legacy?.manifest?.generation !== options["expected-generation"]) usage("legacy receipt generation does not match the observed generation guard");
function ghJSON(path) {
  try {
    return JSON.parse(execFileSync("gh", ["api", path], { encoding: "utf8" }));
  } catch (error) {
    throw new Error(`immutable GitHub verification failed for ${path}: ${error.message}`);
  }
}

function peeledTagCommit(tag) {
  let ref = ghJSON(`repos/VortXTV/VortX/git/ref/tags/${tag}`);
  let sha = ref?.object?.sha;
  let type = ref?.object?.type;
  for (let hops = 0; type === "tag" && hops < 5; hops += 1) {
    ref = ghJSON(`repos/VortXTV/VortX/git/tags/${sha}`);
    sha = ref?.object?.sha;
    type = ref?.object?.type;
  }
  if (type !== "commit" || !/^[a-f0-9]{40}$/i.test(sha || "")) throw new Error("tag did not peel to an immutable commit");
  return sha;
}

const release = ghJSON(`repos/VortXTV/VortX/releases/${manifest.releaseId}`);
if (String(release?.id) !== String(manifest.releaseId) || release?.tag_name !== manifest.tag || release?.draft !== false || release?.prerelease !== true) {
  throw new Error("release ID, strict prerelease state, or immutable tag does not match the repair manifest");
}
const tagCommit = peeledTagCommit(manifest.tag);
if (tagCommit.toLowerCase() !== manifest.sourceCommit.toLowerCase()) throw new Error("peeled tag commit does not match manifest sourceCommit");
const remoteAssets = Array.isArray(release.assets) ? release.assets : [];
for (const asset of Object.values(manifest.assets || {})) {
  const remote = remoteAssets.filter((candidate) => Number(candidate.id) === Number(asset.assetId) && candidate.name === asset.name);
  if (remote.length !== 1 || remote[0].state !== "uploaded" || Number(remote[0].size) !== Number(asset.size) || String(remote[0].digest || "").replace(/^sha256:/i, "").toLowerCase() !== String(asset.sha256).toLowerCase()) {
    throw new Error(`release asset ${asset.name} does not match the immutable repair manifest`);
  }
}
const receipt = {
  schemaVersion: 2,
  action: "repair",
  repairReason: "integrity-repair",
  expectedLegacyGeneration: options["expected-generation"],
  expectedLegacyDigest: legacyDigest,
  legacyRelease: {
    releaseId: String(release.id),
    tag: release.tag_name,
    sourceCommit: manifest.sourceCommit,
    tagCommit,
    prerelease: true,
    assetIds: Object.values(manifest.assets).map((asset) => Number(asset.assetId)),
  },
  manifest,
  source: readFileSync(options.source, "utf8"),
  appcast: readFileSync(options.appcast, "utf8"),
  checksum: readFileSync(options.checksum, "utf8"),
};
const body = JSON.stringify(receipt);
writeFileSync(options.out, `${body}\n`, { mode: 0o600 });
if (!options.execute) {
  console.log(`repair-release-feed: wrote unsigned repair receipt for ${manifest.tag}; review it and use --execute only during the approved migration window`);
} else {
  const secret = process.env.RELEASE_FEED_RECEIPT_SECRET;
  const endpoint = options.endpoint;
  if (!secret || endpoint !== "https://vortx.tv/__release/receipt") usage("--execute requires RELEASE_FEED_RECEIPT_SECRET and the exact production receipt endpoint");
  const signature = createHmac("sha256", secret).update(body).digest("hex");
  const response = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json", "x-vortx-receipt": `sha256=${signature}` }, body });
  const responseBody = await response.text();
  if (!response.ok) throw new Error(`repair was rejected (${response.status}): ${responseBody}`);
  const accepted = JSON.parse(responseBody);
  if (accepted.repaired !== true || accepted.generation !== manifest.generation) throw new Error("repair response did not bind the expected generation");
  console.log(`repair-release-feed: durable receipt repaired for ${manifest.tag} (${accepted.generation})`);
}
