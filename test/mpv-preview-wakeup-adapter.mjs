#!/usr/bin/env node
// Generates bounded adapters from CURRENT repository source. No native APIs or compiler invoked here.
// Commands: generate|verify|mutants REPO_ROOT RUN_DIRECTORY
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const [command, rootArgument, runArgument] = process.argv.slice(2);
if (!["generate", "verify", "mutants"].includes(command) || !rootArgument || !runArgument) {
  throw new Error("Usage: node test/mpv-preview-wakeup-adapter.mjs generate|verify|mutants REPO_ROOT RUN_DIRECTORY");
}
const repoRoot = fs.realpathSync(rootArgument);
const runDirectory = fs.realpathSync(runArgument);
const runRelative = path.relative(repoRoot, runDirectory);
if (!runRelative.startsWith("app/build/") || runRelative.split(path.sep).includes("..")) {
  throw new Error("Run directory must be a dedicated child of this repository's app/build");
}
const sha = value => crypto.createHash("sha256").update(value).digest("hex");
const controllerPath = "app/Sources/Player/MPVMetalViewController.swift";
const fullTemplatePath = "app/Tests/MPVWakeupAdapterTests.swift.in";
const strictTemplatePath = "app/Tests/MPVWakeupStrictSchedulingTests.swift.in";
const inputPaths = [
  controllerPath, fullTemplatePath, strictTemplatePath,
  "test/mpv-preview-wakeup-adapter.mjs", "scripts/test-mpv-preview-wakeup-adapter.sh",
  "test/mpv-bounded-child.mjs",
  "app/project.yml"
];
if (fs.existsSync(path.join(repoRoot, "app/VortX.xcodeproj/project.pbxproj"))) {
  inputPaths.push("app/VortX.xcodeproj/project.pbxproj");
}
function safeRelative(value) {
  if (typeof value !== "string" || path.isAbsolute(value) || value.split(/[\\/]/).includes("..")) {
    throw new Error("Invalid relative artifact path");
  }
  return value;
}
function readInput(relative) { return fs.readFileSync(path.join(repoRoot, safeRelative(relative))); }
function writeArtifact(name, value) {
  if (path.basename(name) !== name) throw new Error("Generated filename must be a leaf name");
  fs.writeFileSync(path.join(runDirectory, name), value, { flag: "wx" });
}
function verify() {
  const manifestBytes = fs.readFileSync(path.join(runDirectory, "manifest.json"));
  const digest = fs.readFileSync(path.join(runDirectory, "manifest.sha256"), "utf8").trim();
  if (sha(manifestBytes) !== digest) throw new Error("Generated manifest changed");
  const manifest = JSON.parse(manifestBytes);
  if (manifest.schema !== 1 || manifest.repoRoot !== repoRoot || manifest.runDirectory !== runDirectory) {
    throw new Error("Manifest belongs to a different source/run directory");
  }
  for (const item of manifest.inputs) {
    if (sha(readInput(item.path)) !== item.sha256) throw new Error("Current input drift: " + item.path);
  }
  for (const item of manifest.outputs) {
    if (path.basename(item.name) !== item.name) throw new Error("Invalid generated filename");
    if (sha(fs.readFileSync(path.join(runDirectory, item.name))) !== item.sha256) {
      throw new Error("Generated Swift source drift: " + item.name);
    }
  }
  return manifest;
}
if (command !== "generate") {
  const manifest = verify();
  if (command === "verify") {
    process.stdout.write("VERIFIED: current inputs, manifest, and all generated Swift sources unchanged\n");
  } else {
    for (const item of manifest.outputs.filter(item => item.mutation)) {
      process.stdout.write(`${item.mutation}\t${item.name}\t${item.expectedAssertion}\n`);
    }
  }
  process.exit(0);
}
if (fs.readdirSync(runDirectory).length !== 0) throw new Error("Generation requires an empty dedicated run directory");
const inputs = inputPaths.map(relative => {
  const bytes = readInput(relative);
  return { path: relative, bytes: bytes.length, sha256: sha(bytes) };
});
const controller = readInput(controllerPath).toString("utf8");
const fullTemplate = readInput(fullTemplatePath).toString("utf8");
const strictTemplate = readInput(strictTemplatePath).toString("utf8");
const receipts = [];
function uniqueOffset(text, anchor, label) {
  const index = text.indexOf(anchor);
  if (index < 0 || text.indexOf(anchor, index + anchor.length) >= 0) {
    throw new Error("Absent or ambiguous anchor: " + label);
  }
  return index;
}
function extract(label, start, end) {
  const a = uniqueOffset(controller, start, label + " start");
  const b = uniqueOffset(controller, end, label + " end");
  if (b <= a) throw new Error("Reversed extraction boundary: " + label);
  const text = controller.slice(a, b).trimEnd();
  receipts.push({ label, path: controllerPath,
    startLine: controller.slice(0, a).split("\n").length,
    endLine: controller.slice(0, b).split("\n").length - 1,
    sha256: sha(text) });
  return text;
}
const sections = {
  PRODUCTION_RELAY: extract("entire current native-retained relay",
    "fileprivate final class WakeupRelay:", "/// Mutable Core Image"),
  PRODUCTION_REGISTER: extract("current native registration and immutable eligibility",
    "        let relay = Unmanaged.passRetained(WakeupRelay(self, handle:", "        setupNotification()"),
  PRODUCTION_STOP: extract("actual stop retirement/unregister/quit/serial-destroy tail",
    "        appliedDynamicRange = nil\n        // Fence every preview wake/continuation",
    "    deinit {\n        // Safety net:"),
  PRODUCTION_DEINIT: extract("complete actual deinit",
    "    deinit {\n        // Safety net:", "    private func finishCacheFlushFlight("),
  PRODUCTION_DRAIN_HEAD: extract("actual queue begin/defer/context guards and native dequeue",
    "    func readEvents() {", "                let rawSeekOwner ="),
  PRODUCTION_NONE: extract("actual NONE exit with drained-restart branch",
    "                if event?.pointee.event_id == MPV_EVENT_NONE {",
    "                switch event!.pointee.event_id {"),
  PRODUCTION_SHUTDOWN: extract("actual SHUTDOWN exit",
    "                case MPV_EVENT_SHUTDOWN:", "                case MPV_EVENT_LOG_MESSAGE:")
};
extract("record-only omitted native event payload, NOT executed by these adapters",
  "                // Command admission and dequeue share this boundary;",
  "                case MPV_EVENT_SHUTDOWN:");
function replaceOnce(text, before, after, label) {
  if (text.split(before).length !== 2) throw new Error("Absent/ambiguous replacement: " + label);
  return text.replace(before, after);
}
function fill(template, parts) {
  let text = template;
  for (const [name, value] of Object.entries(parts)) {
    text = replaceOnce(text, `// ${name}`, value, name);
  }
  if (/\/\/ PRODUCTION_[A-Z_]+/.test(text)) throw new Error("Unresolved production extraction marker");
  return text;
}
const fixtureCleanup = `    // TEST FIXTURE ONLY: production stop/deinit/destroy are excluded from this strict6 lane.
    func releaseFixtureAfterQuiescence() {
        precondition(queue.pending.isEmpty && !queue.running)
        wakeupRelay?.takeUnretainedValue().retire()
        if let handle = mpv { mpv_set_wakeup_callback(handle, nil, nil) }
        mpv = nil
        let relay = wakeupRelay
        wakeupRelay = nil
        relay?.release()
    }
`;
function strictBody() {
  // Remove markers BEFORE expansion: production teardown is not adapted or represented as tested.
  let template = replaceOnce(fullTemplate,
    "    func stopTail() {\n        // PRODUCTION_STOP\n    // PRODUCTION_DEINIT\n",
    fixtureCleanup, "explicit strict6 teardown exclusion");
  const testsStart = uniqueOffset(template, "@main\nprivate enum MPVWakeupAdapterTests {", "full lifecycle test entry");
  template = template.slice(0, testsStart) + strictTemplate;
  const parts = { ...sections };
  delete parts.PRODUCTION_STOP;
  delete parts.PRODUCTION_DEINIT;
  return fill(template, parts);
}
const outputs = [];
function emit(name, body, lane, mutation = null, expectedAssertion = null, mutationReceipt = null) {
  const excluded = lane === "strict6-scheduling" ? ["PRODUCTION_STOP", "PRODUCTION_DEINIT"] : [];
  const header = [
    `// Lane: ${lane}; mutation: ${mutation ?? "none"}`,
    "// CURRENT repository extraction. Not a full controller/native/thread/device proof.",
    "// legacy5: selected actual lifecycle in project Swift5/default concurrency + WAE.",
    "// strict6-scheduling: new relay/scheduling in Swift6/complete/WAE; production teardown EXCLUDED.",
    `// Controller sha256=${sha(controller)}`,
    "// Manifest records source inputs, exact selected excerpts, lane boundaries, and generated hashes.",
    `// Excluded production sections: ${excluded.join(",") || "none of the selected lifecycle excerpts"}`,
    ...(mutationReceipt ? ["// MUTATION " + JSON.stringify(mutationReceipt)] : [])
  ].join("\n") + "\n";
  const generated = header + body;
  writeArtifact(name, generated);
  outputs.push({ name, lane, mutation, expectedAssertion, mutationReceipt, sha256: sha(generated) });
}
emit("legacy5.swift", fill(fullTemplate, sections), "legacy5");
emit("strict6-scheduling.swift", strictBody(), "strict6-scheduling");
const mutants = [
  {
    id: "pending-continuation", section: "PRODUCTION_RELAY",
    before: "        if continueDraining { enqueueDrain() }",
    after: "        if continueDraining { /* activated mutant: omit promised continuation */ }",
    expected: "reentrant wake while dequeue lock is held produces one continuation"
  },
  {
    id: "stop-retirement", section: "PRODUCTION_STOP",
    before: "        wakeupRelay?.takeUnretainedValue().retire()",
    after: "        // activated mutant: omitted stop retirement",
    expected: "stop retires relay before native unregister"
  },
  {
    id: "deinit-retirement", section: "PRODUCTION_DEINIT",
    before: "        wakeupRelay?.takeUnretainedValue().retire()",
    after: "        // activated mutant: omitted deinit retirement",
    expected: "deinit retires relay before native unregister"
  },
  {
    id: "expected-context", section: "PRODUCTION_RELAY",
    before: "        return !retired && phase == .draining && self.handle == handle",
    after: "        return !retired && phase == .draining",
    expected: "old relay's expected-context guard cannot poll a different context"
  },
  {
    id: "burst-admission", section: "PRODUCTION_RELAY",
    before: "        guard phase == .idle else { lock.unlock(); return }",
    after: "        // activated mutant: every pending signal schedules again",
    expected: "native callback burst queues one preview consumer"
  }
];
for (const mutant of mutants) {
  const parts = { ...sections };
  const before = parts[mutant.section];
  parts[mutant.section] = replaceOnce(before, mutant.before, mutant.after, mutant.id);
  emit(`mutant-${mutant.id}.swift`, fill(fullTemplate, parts), "legacy5",
    mutant.id, mutant.expected,
    { section: mutant.section, beforeSHA256: sha(before), afterSHA256: sha(parts[mutant.section]) });
}
const manifest = {
  schema: 1, repoRoot, runDirectory, generatedAt: new Date().toISOString(),
  inputs, receipts, outputs,
  lanes: {
    legacy5: {
      swiftVersion: "5", concurrency: "app-default, NOT complete strict6", warningsAsErrors: true,
      excluded: "unchanged native event payload; platform/native/thread/device behavior"
    },
    "strict6-scheduling": {
      swiftVersion: "6", concurrency: "complete", warningsAsErrors: true,
      excluded: "production stop/deinit/destruction and lifecycle assertions, plus native event payload/platform/native/thread/device behavior"
    }
  },
  mutationRule: "Compile must succeed; only supervisor-confirmed normal child exit 1 plus the exact expected WAKEUP_ASSERTION_FAILED line is a kill. Compile failure, timeout, interruption, spawn failure, unconfirmed cleanup, or input drift is NEVER a kill."
};
const manifestBytes = JSON.stringify(manifest, null, 2) + "\n";
writeArtifact("manifest.json", manifestBytes);
writeArtifact("manifest.sha256", sha(manifestBytes) + "\n");
verify();
process.stdout.write(`GENERATED: ${outputs.length} current-source adapters; manifest=${path.join(runDirectory, "manifest.json")}\n`);
