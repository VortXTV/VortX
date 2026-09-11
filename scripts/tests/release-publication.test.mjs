import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const workflow = readFileSync(new URL("../../.github/workflows/release-tvos.yml", import.meta.url), "utf8");
const start = workflow.indexOf("          PUBLISH_DEADLINE=");
const end = workflow.indexOf('          [ "$PUBLISHED" = 1 ]', start);
assert(start > 0 && end > start);
const loop = workflow.slice(start, end).replace(/^ {10}/gm, "");
const rollbackStart = workflow.indexOf("          rollback_release() {");
const rollbackEnd = workflow.indexOf("          on_failure() {", rollbackStart);
const rollback = workflow.slice(rollbackStart, rollbackEnd).replace(/^ {10}/gm, "");

function exercise(scenario, prerelease = false, compensate = false) {
  const temp = mkdtempSync(join(tmpdir(), "release-publication-"));
  writeFileSync(join(temp, "clock"), "0\n");
  writeFileSync(join(temp, "commands"), "");
  const release = { id: 12, tag_name: "v0.4.0-beta.12", draft: false, prerelease, published_at: "2026-09-11T21:17:14Z" };
  const shell = `set -euo pipefail
date() { local n; read -r n < "$FIXTURE/clock"; printf '%s\\n' "$((n+10))" > "$FIXTURE/clock"; printf '%s\\n' "$n"; }
sleep() { :; }
gh() {
  printf '%s\\n' "$*" >> "$FIXTURE/commands"
  if [[ "$*" == *'draft=true'* ]]; then printf '%s' "$DRAFT";
  elif [[ "$*" == *'make_latest=true'* ]]; then
    if [ "$SCENARIO" = latestError ]; then printf '%s' '{"message":"synthetic Latest failure"}'; return 1; fi
    printf '%s' "$RELEASE";
  elif [[ "$*" == *'/releases/latest'* ]]; then
    if [ "$SCENARIO" = latestOld ]; then printf '%s' '{"id":10,"tag_name":"v0.4.0-beta.10"}'; else printf '%s' "$RELEASE"; fi
  elif [ "$SCENARIO" = wrongIdentity ]; then printf '%s' '{"id":99,"draft":false}';
  else printf '%s' "$RELEASE"; fi
}
${loop}
ROLLBACK_FAILURE=0
${rollback}
${compensate ? "rollback_release" : ":"}
printf '%s|%s|%s' "$PUBLISHED" "\${PUBLISHED_AT:-unset}" "$ROLLBACK_FAILURE"
`;
  try {
    const output = execFileSync("bash", ["-c", shell], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: {
      ...process.env, FIXTURE: temp, SCENARIO: scenario, GH_REPO: "VortXTV/VortX", RELEASE_ID: "12",
      TAG: release.tag_name, IS_PRERELEASE: String(prerelease), RELEASE: JSON.stringify(release),
      DRAFT: JSON.stringify({ ...release, draft: true }),
    } });
    return { output, commands: readFileSync(join(temp, "commands"), "utf8").trim().split("\n") };
  } finally { rmSync(temp, { recursive: true, force: true }); }
}

test("real workflow publishes typed Boolean before requesting string-valued Latest", () => {
  const result = exercise("success");
  assert.equal(result.output, "1|2026-09-11T21:17:14Z|0");
  assert.match(result.commands[0], /PATCH -F draft=false/);
  assert.match(result.commands[1], /PATCH -f make_latest=true/);
  assert.equal(result.commands.filter(command => command.includes("draft=false")).length, 1);
});

test("real workflow retains publication identity for rollback when Latest stays old or errors", () => {
  for (const scenario of ["latestOld", "latestError"]) {
    const result = exercise(scenario, false, true);
    assert.equal(result.output, "0|2026-09-11T21:17:14Z|0");
    assert.equal(result.commands.filter(command => command.includes("draft=false")).length, 1);
    assert.match(result.commands.at(-1), /PATCH -F draft=true/);
  }
});

test("ordinary prereleases publish without changing Latest", () => {
  const result = exercise("success", true);
  assert.equal(result.output, "1|2026-09-11T21:17:14Z|0");
  assert(!result.commands.some(command => command.includes("latest")));
});

test("wrong publication identity never receives Latest authority or a rollback timestamp", () => {
  const result = exercise("wrongIdentity");
  assert.equal(result.output, "0|unset|0");
  assert(!result.commands.some(command => command.includes("latest")));
});
