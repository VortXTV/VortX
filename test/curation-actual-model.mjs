#!/usr/bin/env node
// Authoring this generator does not execute it. Runtime copies/extracts actual source verbatim,
// freezes every donor/selected input, and never supplies a duplicate curation/legacy algorithm.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
const canonicalRoot = "/Users/daksh/VortXTV";
const supervisorSHA = "c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62";
function within(root, target) {
  const relative = path.relative(root, target);
  return relative !== "" && relative !== ".." && !relative.startsWith("../") && !path.isAbsolute(relative);
}
function uniqueIndex(source, marker) {
  const first = source.indexOf(marker);
  if (first < 0 || source.indexOf(marker, first + marker.length) !== -1) {
    throw new Error(`Missing/ambiguous source marker: ${marker}`);
  }
  return first;
}
function exactDeclaration(source, marker) {
  const start = uniqueIndex(source, marker);
  // These donor declarations begin at column zero and close at column zero; nested braces are
  // indented. Fail on missing boundary. The exact selected text/hash is retained in the manifest.
  const end = source.indexOf("\n}\n", start);
  if (end < 0) throw new Error(`Missing top-level declaration end: ${marker}`);
  return source.slice(start, end + 3);
}
function exactValidator(source) {
  const start = uniqueIndex(source, '    static let forYouPrefix = "forYou."');
  const functionStart = uniqueIndex(source, "    static func validateForYouField(");
  if (functionStart < start) throw new Error("Unexpected validator declaration order");
  const end = source.indexOf("\n    }\n", functionStart);
  if (end < 0) throw new Error("Missing host validator end");
  const result = source.slice(start, end + 7);
  for (const marker of ["static let forYouMaxBytes = 16_384", "static func validateForYouField("]) {
    if (!result.includes(marker)) throw new Error("Host validator extraction drift");
  }
  return result;
}
function checkedOutput(runDir, name, bytes) {
  const output = path.join(runDir, name);
  fs.writeFileSync(output, bytes, { flag: "wx" });
  return { path: output, sha256: sha256(bytes) };
}
function generate(repoArgument, candidateArgument, runArgument, runnerArgument) {
  const repo = fs.realpathSync(repoArgument), candidate = fs.realpathSync(candidateArgument);
  const run = fs.realpathSync(runArgument), runner = fs.realpathSync(runnerArgument);
  for (const value of [repo, candidate, run, runner]) {
    if (!within(canonicalRoot, value)) throw new Error("Curation proof must remain inside canonical VortX workspace");
  }
  if (!within(path.join(repo, "app/build"), run)) throw new Error("Unexpected retained run directory");
  const inputs = [];
  const read = relative => {
    const file = fs.realpathSync(relative), bytes = fs.readFileSync(file);
    if (!within(canonicalRoot, file)) throw new Error("Input escapes canonical workspace");
    inputs.push({ path: file, sha256: sha256(bytes) });
    return bytes.toString("utf8");
  };
  const supervisor = read(path.join(repo, "test/mpv-bounded-child.mjs"));
  if (sha256(Buffer.from(supervisor)) !== supervisorSHA) throw new Error("Bounded-child helper changed");
  read(runner);
  read(fs.realpathSync(new URL(import.meta.url)));
  const donor = name => read(path.join(repo, "app/SourcesShared", name));
  const rawJSON = exactDeclaration(donor("VortxResourceBridge.swift"), "indirect enum VortxJSON:");
  const nativeError = exactDeclaration(donor("VortxNativeRuntime.swift"), "enum VortxNativeError:");
  const validator = exactValidator(donor("VortxNativeHostPreferences.swift"));
  const outputs = [];
  outputs.push(checkedOutput(run, "Support.swift",
    `import Foundation\n\n${rawJSON}\n${nativeError}\nenum VortxNativeHostPreferences {\n${validator}}\n`));
  outputs.push(checkedOutput(run, "ForYouInterests.swift", donor("ForYouInterests.swift")));
  outputs.push(checkedOutput(run, "VortxNativeHostFieldMutation.swift", donor("VortxNativeHostFieldMutation.swift")));
  for (const name of ["CurationCollection.swift", "CurationDocument.swift", "CurationEdit.swift"]) {
    outputs.push(checkedOutput(run, name, read(path.join(candidate, "app/SourcesShared", name))));
  }
  outputs.push(checkedOutput(run, "main.swift", read(path.join(candidate, "app/Tests/CurationDocumentTests.swift"))));
  // Include reviewed Store/Bridge placement evidence without falsely claiming this model lane
  // compiles the complete app or tests ownership/UI/native checkpoint integration.
  read(path.join(candidate, "app/SourcesShared/ForYouStore.swift"));
  const manifest = {
    schema: 1, generatedAt: new Date().toISOString(), repo, candidate, runner,
    proof: "strict6 actual common models + full legacy model + exact production JSON/error/validator/evidence extracts",
    excluded: ["ForYouStore/CoreBridge lifecycle execution", "native engine/checkpoint", "UI", "app/device", "network/account"],
    supervisorSHA, inputs, outputs,
    extracted: [
      { declaration: "VortxJSON", sha256: sha256(rawJSON) },
      { declaration: "VortxNativeError", sha256: sha256(nativeError) },
      { declaration: "VortxNativeHostPreferences forYou constants/validator", sha256: sha256(validator) }
    ]
  };
  fs.writeFileSync(path.join(run, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n", { flag: "wx" });
}
function verify(runArgument) {
  const run = fs.realpathSync(runArgument);
  if (!within(canonicalRoot, run)) throw new Error("Unexpected verification root");
  const manifest = JSON.parse(fs.readFileSync(path.join(run, "manifest.json"), "utf8"));
  if (manifest.schema !== 1 || manifest.supervisorSHA !== supervisorSHA) throw new Error("Manifest contract mismatch");
  for (const entry of [...manifest.inputs, ...manifest.outputs]) {
    if (!within(canonicalRoot, entry.path) || sha256(fs.readFileSync(entry.path)) !== entry.sha256) {
      throw new Error(`Source drift: ${entry.path}`);
    }
  }
}
try {
  const [command, ...args] = process.argv.slice(2);
  if (command === "generate" && args.length === 4) generate(...args);
  else if (command === "verify" && args.length === 1) verify(args[0]);
  else throw new Error("Usage: curation-actual-model.mjs generate REPO CANDIDATE RUN RUNNER | verify RUN");
} catch (error) {
  process.stderr.write(`CURATION PROOF INPUT FAILURE: ${String(error.message ?? error)}\n`);
  process.exitCode = 90;
}
