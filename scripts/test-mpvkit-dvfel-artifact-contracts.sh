#!/usr/bin/env bash
# Focused source contracts and executable dirty-state fixtures for the pinned MPVKit-DVFEL
# builder and release artifact gate. This test never downloads, compiles, or publishes an artifact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-mpvkit-dvfel.sh"
PATCH="$ROOT/scripts/mpvkit-dvfel.patch"
VERIFY="$ROOT/scripts/verify-mpvkit-dvfel-artifacts.sh"
WORKFLOW="$ROOT/.github/workflows/release-tvos.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in "$BUILD" "$PATCH" "$VERIFY" "$WORKFLOW"; do
  [ -f "$file" ] || fail "missing required source: $file"
done

grep -Eq '^MPVKIT_REF="[0-9a-f]{40}"' "$BUILD" || fail "builder must retain one full MPVKit source pin"
grep -Fq 'MPVKIT_DIR="${MPVKIT_DVFEL_WORK:-$REPO/../MPVKit}"' "$BUILD" ||
  fail "builder default must use the canonical MPVKit sibling checkout"
grep -Fq 'DEST="${MPVKIT_DVFEL_DEST:-$REPO/_build/MPVKit-DVFEL}"' "$BUILD" ||
  fail "builder must stage by default in canonical _build"
if grep -Fq '$HOME/.cache/vortx-mpvkit-dvfel' "$BUILD"; then
  fail "builder must not silently use a HOME cache as its default source"
fi
if grep -Fq 'git checkout --quiet -- .' "$BUILD"; then
  fail "builder must not reset tracked user changes"
fi
grep -Fq 'git -C "$MPVKIT_DIR" rev-parse HEAD' "$BUILD" || fail "builder must validate an existing checkout HEAD"
grep -Fq 'FRESH_HEAD' "$BUILD" || fail "builder must assert the fresh clone resolved to the exact pin"
grep -Fq 'matches_exact_patch_tree' "$BUILD" || fail "builder must prove the complete approved patch tree"
grep -Fq 'exact MPVKit patch already applied' "$BUILD" || fail "builder must support an explicit exact-patch retry"
grep -Fq 'existing generated patch differs' "$BUILD" || fail "builder must not overwrite a changed generated patch"

# The Swift patch must request command output explicitly: Utility.shell returns an empty string on
# success otherwise, which would make a correct rev/status look absent. It must also reject arbitrary
# dirty state instead of treating a reverse hunk check as a full-tree proof.
grep -Fq 'Utility.shell(command, isOutput: true, currentDirectoryURL: directoryURL)' "$PATCH" ||
  fail "SpikeGit output/success checks must request shell output explicitly"
grep -Fq 'matchesExactPatchTree' "$PATCH" || fail "SpikeGit must compare the complete tree to the approved patch set"
grep -Fq 'git status --porcelain --untracked-files=all' "$PATCH" || fail "SpikeGit must inspect dirty state"
if grep -Fq 'test -z \\\"$(git status --porcelain --untracked-files=all)\\\"' "$PATCH"; then
  fail "SpikeGit must not require an exact applied checkout to have an empty status"
fi
grep -Fq 'git diff --cached --quiet' "$PATCH" || fail "SpikeGit must reject staged changes"
grep -Fq 'git rev-parse HEAD' "$PATCH" || fail "SpikeGit must validate an existing HEAD"
grep -Fq 'expected exact pin' "$PATCH" || fail "SpikeGit must assert the fresh checkout pin"
grep -Fq 'git apply --reverse --check' "$PATCH" || fail "SpikeGit must support an exact already-applied patch"
grep -Fq 'patch neither applies cleanly nor is already applied' "$PATCH" || fail "SpikeGit must fail actionable patch conflicts"

# The artifact verifier must inspect content, not only checksums or mtimes.
grep -Fq 'LIBAVCODEC_VERSION_MAJOR' "$VERIFY" || fail "artifact gate must inspect libavcodec major"
grep -Fq 'LIBAVFORMAT_VERSION_MAJOR' "$VERIFY" || fail "artifact gate must inspect libavformat major"
grep -Fq 'LIBAVCODEC_VERSION_MAJOR[[:space:]]+63' "$VERIFY" || fail "artifact gate must require libavcodec major 63"
grep -Fq 'LIBAVFORMAT_VERSION_MAJOR[[:space:]]+63' "$VERIFY" || fail "artifact gate must require libavformat major 63"
grep -Fq 'Libmpv-GPL; do' "$VERIFY" || fail "artifact gate must validate Libmpv slices"
grep -Fq 'expected_arches' "$VERIFY" || fail "artifact gate must require exact per-slice architectures"
grep -Fq 'tvos-arm64_arm64e' "$VERIFY" || fail "artifact gate must enumerate the tvOS arm64e slice"
grep -Fq 'dovi_split' "$VERIFY" || fail "artifact gate must require dovi_split"
grep -Fq 'if [ "$target" = Libavcodec-GPL ]; then' "$VERIFY" ||
  fail "artifact gate must scope dovi_split to libavcodec"
grep -Fq 'verify-mpvkit-dvfel-apple-tls.sh' "$VERIFY" || fail "artifact gate must retain TLS verification"

# Extract the real fetch step and require the verifier after unzip, before the next workflow step.
fetch_step="$(awk '/name: Fetch the MPVKit-DVFEL artifacts/{active=1; next}
  active && /^[[:space:]]+- name:/{exit} active{print}' "$WORKFLOW")"
grep -Fq 'unzip -q /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must unpack the pinned artifact"
grep -Fq 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must run the real MPV artifact verifier"
unzip_line="$(grep -nF 'unzip -q /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
verify_line="$(grep -nF 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
[ "$verify_line" -gt "$unzip_line" ] || fail "artifact verifier must run after unpack"

# Exercise the production builder preflight against a tiny local Git fixture. The approved patch is
# generated from the fixture's clean base, then the same builder is run for a clean apply, an exact
# patched retry, an unrelated same-file edit, and an unknown untracked file. No native build tools
# are used: the builder exits only after its checkout/patch preflight in this mode.
TEST_BUILD_ROOT="$ROOT/.build"
mkdir -p "$TEST_BUILD_ROOT"
FIXTURE="$(mktemp -d "$TEST_BUILD_ROOT/mpvkit-contract.XXXXXX")"
TOOLS="$FIXTURE/tools"
SOURCE="$FIXTURE/mpvkit"
FIXTURE_PATCH="$FIXTURE/approved.patch"
mkdir -p "$TOOLS" "$SOURCE"
cleanup_fixture() {
  rm -rf "$FIXTURE"
  rmdir "$TEST_BUILD_ROOT" 2>/dev/null || true
}
trap cleanup_fixture EXIT

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name "MPVKit contract fixture"
git -C "$SOURCE" config user.email "fixture@example.invalid"
mkdir -p "$SOURCE/Sources"
printf '%s\n' 'let packageValue = "base"' >"$SOURCE/Package.swift"
printf '%s\n' 'let sourceValue = "base"' >"$SOURCE/Sources/main.swift"
cp "$SOURCE/Package.swift" "$FIXTURE/base-package.swift"
git -C "$SOURCE" add -- Package.swift Sources/main.swift
git -C "$SOURCE" commit -q -m "fixture base"
FIXTURE_REF="$(git -C "$SOURCE" rev-parse HEAD)"

printf '%s\n' 'let packageValue = "approved"' >"$SOURCE/Package.swift"
git -C "$SOURCE" diff --binary -- Package.swift >"$FIXTURE_PATCH"
[ -s "$FIXTURE_PATCH" ] || fail "fixture patch was not generated"
cp "$FIXTURE/base-package.swift" "$SOURCE/Package.swift"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ] ||
  fail "fixture must start clean"

for tool in meson ninja cmake pkg-config nasm wget; do
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$TOOLS/$tool"
  chmod +x "$TOOLS/$tool"
done

run_builder() {
  local log="$1"
  MPVKIT_DVFEL_WORK="$SOURCE" \
    MPVKIT_DVFEL_REF="$FIXTURE_REF" \
    MPVKIT_DVFEL_PATCH="$FIXTURE_PATCH" \
    MPVKIT_DVFEL_DEST="$FIXTURE/stage" \
    MPVKIT_DVFEL_PREFLIGHT_ONLY=1 \
    PATH="$TOOLS:$PATH" \
    "$BUILD" >"$log" 2>&1
}

run_builder "$FIXTURE/clean.log" || fail "clean fixture preflight failed: $(cat "$FIXTURE/clean.log")"
grep -Fq 'preflight-only checkout and patch validation passed' "$FIXTURE/clean.log" ||
  fail "clean fixture did not reach the preflight success path"
grep -Fq 'approved' "$SOURCE/Package.swift" || fail "clean fixture did not apply its approved patch"
cp "$SOURCE/Package.swift" "$FIXTURE/exact-package.swift"

run_builder "$FIXTURE/retry.log" || fail "exact patched retry failed: $(cat "$FIXTURE/retry.log")"
grep -Fq 'exact MPVKit patch already applied' "$FIXTURE/retry.log" ||
  fail "exact patched retry did not use the idempotent path"

printf '%s\n' 'let unrelated = true' >>"$SOURCE/Package.swift"
if run_builder "$FIXTURE/unrelated.log"; then
  fail "unrelated same-file edit was accepted"
fi
grep -Fq 'exact approved VortX patch' "$FIXTURE/unrelated.log" ||
  fail "unrelated same-file edit failed without the exact-tree diagnostic"
cp "$FIXTURE/exact-package.swift" "$SOURCE/Package.swift"

printf '%s\n' 'untracked fixture data' >"$SOURCE/untracked.txt"
if run_builder "$FIXTURE/untracked.log"; then
  fail "unknown untracked file was accepted"
fi
grep -Fq 'unexpected dirty state' "$FIXTURE/untracked.log" ||
  fail "unknown untracked file failed without the dirty-state diagnostic"
rm -f "$SOURCE/untracked.txt"

[ "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" = ' M Package.swift' ] ||
  fail "fixture did not retain only the exact approved patch after dirty-state cases"

# Compile the actual patched SpikeGit implementation extracted from the canonical MPVKit source.
# The fixture provides only the surrounding Foundation types and a real Process-backed Utility.shell;
# it does not reimplement or regex-test the production validation logic.
CANONICAL_MPVKIT="${MPVKIT_DVFEL_CANONICAL:-/Users/daksh/VortXTV/MPVKit}"
[ -d "$CANONICAL_MPVKIT/.git" ] || fail "canonical MPVKit checkout is unavailable: $CANONICAL_MPVKIT"
CANONICAL_REF="$(git -C "$CANONICAL_MPVKIT" rev-parse HEAD)"
[ "$CANONICAL_REF" = "2103893078c5e339073b11737b86f7f22b9c4491" ] ||
  fail "canonical MPVKit fixture source is not pinned to 2103893: $CANONICAL_REF"

PATCHED_SOURCE="$FIXTURE/mpvkit-patched-source"
mkdir -p "$PATCHED_SOURCE"
git -C "$CANONICAL_MPVKIT" archive HEAD | tar -x -C "$PATCHED_SOURCE"
git -C "$CANONICAL_MPVKIT" apply --unsafe-paths --directory="$PATCHED_SOURCE" "$PATCH"
swiftc -parse "$PATCHED_SOURCE/Sources/BuildScripts/XCFrameworkBuild/main.swift" ||
  fail "actual patched MPVKit BuildScripts source did not parse"
SPIKE_BLOCK="$FIXTURE/spikegit-production.swift"
sed -n '/^enum SpikeGit {/,/^private class BuildOpenSSL: ZipBaseBuild {/p' \
  "$PATCHED_SOURCE/Sources/BuildScripts/XCFrameworkBuild/main.swift" | sed '$d' >"$SPIKE_BLOCK"
[ -s "$SPIKE_BLOCK" ] || fail "could not extract the patched production SpikeGit implementation"

SWIFT_PATCH_DIR="$FIXTURE/Sources/BuildScripts/patch/fixture"
mkdir -p "$SWIFT_PATCH_DIR"
cp "$FIXTURE_PATCH" "$SWIFT_PATCH_DIR/0001-approved.patch"
cp "$FIXTURE/base-package.swift" "$SOURCE/Package.swift"

SWIFT_HELPER="$FIXTURE/spikegit-fixture.swift"
{
  printf '%s\n' \
    'import Foundation' \
    'import Darwin' \
    '' \
    'enum Library: String {' \
    '    case fixture' \
    '}' \
    '' \
    'extension URL {' \
    '    static var currentDirectory: URL {' \
    '        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)' \
    '    }' \
    '' \
    '    static func + (left: URL, right: String) -> URL {' \
    '        left.appendingPathComponent(right)' \
    '    }' \
    '}' \
    '' \
    'enum Utility {' \
    '    @discardableResult' \
    '    static func shell(_ command: String, isOutput: Bool = false, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) -> String? {' \
    '        do {' \
    '            return try launch(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", command], isOutput: isOutput, currentDirectoryURL: currentDirectoryURL, environment: environment)' \
    '        } catch {' \
    '            return nil' \
    '        }' \
    '    }' \
    '' \
    '    @discardableResult' \
    '    static func launch(path: String, arguments: [String], isOutput: Bool = false, isPrint: Bool = true, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) throws -> String {' \
    '        try launch(executableURL: URL(fileURLWithPath: path), arguments: arguments, isOutput: isOutput, currentDirectoryURL: currentDirectoryURL, environment: environment)' \
    '    }' \
    '' \
    '    @discardableResult' \
    '    static func launch(executableURL: URL, arguments: [String], isOutput: Bool = false, isPrint: Bool = true, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) throws -> String {' \
    '        let task = Process()' \
    '        task.executableURL = executableURL' \
    '        task.arguments = arguments' \
    '        task.currentDirectoryURL = currentDirectoryURL' \
    '        var mergedEnvironment = ProcessInfo.processInfo.environment' \
    '        environment.forEach { mergedEnvironment[$0.key] = $0.value }' \
    '        task.environment = mergedEnvironment' \
    '        let outputPipe = Pipe()' \
    '        task.standardOutput = outputPipe' \
    '        let errorPipe = Pipe()' \
    '        task.standardError = errorPipe' \
    '        try task.run()' \
    '        task.waitUntilExit()' \
    '        guard task.terminationStatus == 0 else {' \
    '            let diagnostic = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""' \
    '            if !diagnostic.isEmpty { FileHandle.standardError.write(Data(diagnostic.utf8)) }' \
    '            throw NSError(domain: "SpikeGitFixture", code: Int(task.terminationStatus))' \
    '        }' \
    '        guard isOutput else { return "" }' \
    '        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""' \
    '    }' \
    '}' \
    ''
  sed -n '1,$p' "$SPIKE_BLOCK"
  printf '%s\n' \
    '' \
    'let expectedSHA = CommandLine.arguments[1]' \
    'let checkout = URL(fileURLWithPath: CommandLine.arguments[2])' \
    'do {' \
    '    try SpikeGit.clonePinned(url: "unused", sha: expectedSHA, library: .fixture, into: checkout)' \
    '    print("SPIKE FIXTURE PASS")' \
    '    exit(0)' \
    '} catch {' \
    '    print("SPIKE FIXTURE FAILURE: \(error.localizedDescription)")' \
    '    exit(1)' \
    '}'
} >"$SWIFT_HELPER"

SWIFT_BINARY="$FIXTURE/spikegit-fixture"
swiftc "$SWIFT_HELPER" -o "$SWIFT_BINARY" || fail "actual patched SpikeGit fixture did not compile"

run_spike() {
  local expected_sha="$1" log="$2"
  (cd "$SOURCE" && "$SWIFT_BINARY" "$expected_sha" "$SOURCE") >"$log" 2>&1
}

run_spike "$FIXTURE_REF" "$FIXTURE/swift-clean.log" ||
  fail "compiled SpikeGit rejected the initial clean checkout: $(cat "$FIXTURE/swift-clean.log")"
git -C "$SOURCE" apply "$FIXTURE_PATCH"
run_spike "$FIXTURE_REF" "$FIXTURE/swift-retry.log" ||
  fail "compiled SpikeGit rejected the exact patched retry: $(cat "$FIXTURE/swift-retry.log")"

BAD_REF="0000000000000000000000000000000000000000"
if run_spike "$BAD_REF" "$FIXTURE/swift-wrong-sha.log"; then
  fail "compiled SpikeGit accepted a wrong SHA"
fi
grep -Fq 'expected' "$FIXTURE/swift-wrong-sha.log" || fail "wrong SHA lacked the exact-pin diagnostic"

printf '%s\n' 'let unrelated = true' >>"$SOURCE/Package.swift"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-unrelated.log"; then
  fail "compiled SpikeGit accepted an unrelated same-file edit"
fi
grep -Fq 'conflicting, partial, or unrelated' "$FIXTURE/swift-unrelated.log" ||
  fail "compiled SpikeGit same-file rejection lacked the exact-tree diagnostic"
cp "$FIXTURE/exact-package.swift" "$SOURCE/Package.swift"

printf '%s\n' 'untracked Swift fixture data' >"$SOURCE/swift-untracked.txt"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-untracked.log"; then
  fail "compiled SpikeGit accepted an unknown untracked file"
fi
grep -Fq 'not owned by the approved patch set' "$FIXTURE/swift-untracked.log" ||
  fail "compiled SpikeGit untracked rejection lacked the ownership diagnostic"

echo "PASS: compiled production SpikeGit and MPVKit-DVFEL pin/dirty-state, FFmpeg/Libmpv capability, exact slices, TLS, and post-fetch artifact contracts"
