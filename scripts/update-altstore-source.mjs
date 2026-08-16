#!/usr/bin/env node
// Update altstore/source.json in place for a freshly-cut release, so AltStore / SideStore
// auto-update actually offers the new build. This is the single source of truth for the JSON
// transform; the release workflow calls it on every cut, and it can be run locally to backfill.
//
// AltStore/SideStore poll `.../main/altstore/source.json` and compare each app's FIRST
// versions[] entry against what is installed. If that entry does not advance, no update is
// offered. The file froze at Beta 12 / build 207 through Beta 15 because nothing wrote to it;
// wiring this into the pipeline is what keeps it in lockstep.
//
// Usage:
//   node scripts/update-altstore-source.mjs \
//     --file altstore/source.json --tag v0.3.14-beta.15 --build 217 \
//     --date 2026-08-16 --name "0.3.14 Beta 15" --note "<optional blurb>" \
//     --ios-size 64172346 --tvos-size 63601691
//
// Idempotent: re-running for the same --build replaces that build's entry rather than
// duplicating it, and preserves the entry's original date and (unless a fresh --note is given)
// its description, so a re-attach or a same-tag re-dispatch on any day produces no diff.

import { readFileSync, writeFileSync } from "node:fs";

const REPO = "VortXTV/VortX";
const MAX_HISTORY = 8; // keep the newest N per app; betas accumulate otherwise
const OWNER = "Mamaclapper";

// Static per-app wiring. Matched by bundleIdentifier so a schema drift fails loudly rather
// than silently writing the wrong asset. `slug` is the asset-name infix (VortX-<slug>-<tag>-ci.ipa).
const APP_TARGETS = [
  { bundleIdentifier: "com.stremiox.app.native", slug: "iOS", minOS: "16.0", sizeArg: "ios-size" },
  { bundleIdentifier: "com.stremiox.tv", slug: "tvOS", minOS: "18.0", sizeArg: "tvos-size" },
];

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    // A following token that is itself a flag (or the end of argv) means "no value". An explicit
    // empty string IS a value (e.g. --note "") and must be preserved as "", never coerced to a
    // truthy sentinel: coercing "" to "true" once corrupted the store description.
    const hasVal = i + 1 < argv.length && !argv[i + 1].startsWith("--");
    out[key] = hasVal ? argv[++i] : "";
  }
  return out;
}

function die(msg) {
  console.error(`update-altstore-source: ${msg}`);
  process.exit(1);
}

// The house style forbids em/en dashes and their look-alikes (figure dash, horizontal bar, minus
// sign) in user-facing prose. Neutralise them defensively so a hand-supplied note or an off-style
// release name can never smuggle one into the store.
function cleanProse(s) {
  return String(s)
    .replace(/[‒–—―−]/g, "-")
    .replace(/\s+/g, " ")
    .trim();
}

function requirePositiveInt(name, v) {
  if (!/^\d+$/.test(String(v)) || Number(v) <= 0) die(`--${name} must be a positive integer (got ${JSON.stringify(v)})`);
  return Number(v);
}

const args = parseArgs(process.argv.slice(2));

const file = args.file || die("--file is required");
const tag = args.tag || die("--tag is required");
if (!/^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$/.test(tag)) die(`--tag ${JSON.stringify(tag)} is not a strict release tag`);
const build = String(requirePositiveInt("build", args.build));
const date = args.date || die("--date is required");
if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) die(`--date must be YYYY-MM-DD (got ${JSON.stringify(date)})`);

const version = tag.replace(/^v/, "").split("-")[0]; // v0.3.14-beta.15 -> 0.3.14
const cleanedName = cleanProse(args.name || "");
const name = cleanedName || `${version} (${tag})`; // never let an empty/degenerate name reach prose
const note = cleanProse(args.note || "");
const generatedDescription = note || `${name}. One-tap update over any earlier build, nothing resets.`;

// Never let an AI/vendor name reach the public manifest (house rule: no AI names in public git).
for (const [label, value] of [["name", name], ["note", note]]) {
  if (/(claude|codex|anthropic|openai)/i.test(value)) {
    die(`--${label} contains a disallowed AI/vendor name; refusing to write it to the public store manifest`);
  }
}

const sizes = {
  "ios-size": requirePositiveInt("ios-size", args["ios-size"]),
  "tvos-size": requirePositiveInt("tvos-size", args["tvos-size"]),
};

let root;
try {
  root = JSON.parse(readFileSync(file, "utf8"));
} catch (e) {
  die(`cannot read/parse ${file}: ${e.message}`);
}
if (!root || !Array.isArray(root.apps)) die(`${file} has no apps[] array`);

for (const target of APP_TARGETS) {
  const app = root.apps.find((a) => a.bundleIdentifier === target.bundleIdentifier);
  if (!app) die(`no app with bundleIdentifier ${target.bundleIdentifier} in ${file} (schema drift)`);
  if (!Array.isArray(app.versions)) die(`app ${target.bundleIdentifier} has no versions[] array`);

  // If this build already has an entry, preserve its original date and (unless a fresh note is
  // supplied) its description, so a re-attach / same-tag re-dispatch is a true no-op and never
  // downgrades richer prose or churns the date across a UTC-day boundary.
  const existing = app.versions.find((v) => String(v.buildVersion) === build);
  const entry = {
    version,
    buildVersion: build,
    date: existing?.date || date,
    localizedDescription: note ? generatedDescription : existing?.localizedDescription || generatedDescription,
    downloadURL: `https://github.com/${REPO}/releases/download/${tag}/VortX-${target.slug}-${tag}-ci.ipa`,
    size: sizes[target.sizeArg],
    minOSVersion: target.minOS,
  };

  // Drop any existing entry for this build (dedup / replace), then put the new one on top.
  const rest = app.versions.filter((v) => String(v.buildVersion) !== build);
  app.versions = [entry, ...rest].slice(0, MAX_HISTORY);
}

writeFileSync(file, JSON.stringify(root, null, 2) + "\n");
console.log(`update-altstore-source: ${file} now leads with build ${build} (${tag}) for ${APP_TARGETS.length} apps by ${OWNER}`);
