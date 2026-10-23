// PRIVATE — read-only exact-fragment correspondence guard; no compile/runtime claim.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.argv.length !== 2) throw new Error("No arguments accepted");

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const profiles = readFileSync(resolve(repo, "app/SourcesShared/Profiles.swift"));
const fixture = readFileSync(resolve(repo, "app/Tests/ProfileMigrationSourceUnit/Fixture.swift"));
const specs = [
  ["declarations", 4, "293–301.", "293–301.", 9],
  ["complete helper", 4, "492–526, complete corrected helper.", "492–526.", 35],
  ["transition reset", 8, "420–423, entire original reset condition and operation.", "420–423.", 4],
  ["direct edit", 8, "1699; the wider captureDiscovery path is not extracted.", "1699.", 1],
];

function uniqueIndex(bytes, needle, label) {
  const first = bytes.indexOf(needle);
  if (first < 0 || bytes.indexOf(needle, first + 1) !== -1) {
    throw new Error(`${label}: expected exactly one occurrence`);
  }
  return first;
}

function markerIndex(indent, marker, label) {
  const bytes = Buffer.from(" ".repeat(indent) + marker, "utf8");
  const at = uniqueIndex(fixture, bytes, label);
  if ((at > 0 && fixture[at - 1] !== 10) || fixture[at + bytes.length] !== 10) {
    throw new Error(`${label}: marker must be an exact complete LF-terminated line`);
  }
  return [at, bytes.length];
}

const fragments = [];
for (const [label, indent, beginSuffix, endSuffix, expectedLines] of specs) {
  const [begin, beginLength] = markerIndex(indent, `// BEGIN literal afterimage ${beginSuffix}`, `${label} begin`);
  const [end] = markerIndex(indent, `// END literal afterimage ${endSuffix}`, `${label} end`);
  const start = begin + beginLength + 1;
  if (end <= start) throw new Error(`${label}: empty or reversed fragment`);
  const fragment = fixture.subarray(start, end);
  if (fragment.toString("utf8").trim().length === 0 || fragments.some(previous => previous.equals(fragment))) {
    throw new Error(`${label}: empty or duplicate fragment`);
  }
  let lines = 0;
  for (const byte of fragment) if (byte === 10) lines += 1;
  if (lines !== expectedLines) throw new Error(`${label}: literal span line count changed`);
  uniqueIndex(profiles, fragment, `${label} whole source fragment`);
  fragments.push(fragment);
}

console.log("Profile migration source correspondence: 4 complete literal fragments occur exactly once; no compile/runtime claim.");
