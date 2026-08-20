#!/usr/bin/env node

/**
 * Prepares, but never sends by default, a one-time Durable Object integrity
 * repair receipt. This exists solely for migrating a verified legacy feed
 * generation (for example the malformed Beta 18 record) into authoritative
 * Durable Object storage after an operator has independently checked its
 * immutable release assets.
 */

import { createHmac } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

function usage(message) {
  if (message) console.error(`repair-release-feed: ${message}`);
  console.error("usage: repair-release-feed.mjs --manifest FILE --source FILE --appcast FILE --checksum FILE --out FILE [--execute --endpoint URL]");
  process.exitCode = 2;
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
for (const required of ["manifest", "source", "appcast", "checksum", "out"]) {
  if (!options[required] || options[required] === true) usage(`--${required} is required`);
}
let manifest;
try {
  manifest = JSON.parse(readFileSync(options.manifest, "utf8"));
} catch (error) {
  usage(`invalid manifest: ${error.message}`);
}
if (manifest?.schemaVersion !== 2 || !/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/.test(manifest?.tag || "") || !/^\d+$/.test(String(manifest?.releaseId || "")) || manifest.android !== null) {
  usage("manifest must be an Apple-only schema 2 immutable release receipt");
}
const receipt = {
  schemaVersion: 2,
  action: "repair",
  repairReason: "integrity-repair",
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
  if (!secret || !endpoint || endpoint === true || new URL(endpoint).protocol !== "https:") usage("--execute requires RELEASE_FEED_RECEIPT_SECRET and an HTTPS --endpoint");
  const signature = createHmac("sha256", secret).update(body).digest("hex");
  const response = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json", "x-vortx-receipt": `sha256=${signature}` }, body });
  const responseBody = await response.text();
  if (!response.ok) throw new Error(`repair was rejected (${response.status}): ${responseBody}`);
  const accepted = JSON.parse(responseBody);
  if (accepted.repaired !== true || accepted.generation !== manifest.generation) throw new Error("repair response did not bind the expected generation");
  console.log(`repair-release-feed: durable receipt repaired for ${manifest.tag} (${accepted.generation})`);
}
