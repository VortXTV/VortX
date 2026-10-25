#!/usr/bin/env bash
# Focused source contracts and executable dirty-state fixtures for the pinned MPVKit-DVFEL
# builder and release artifact gate. No native artifact build, download or publication runs;
# source verification compiles a bounded production Swift helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-mpvkit-dvfel.sh"
PATCH="$ROOT/scripts/mpvkit-dvfel.patch"
REFERENCE_PATCH="$ROOT/scripts/mpv-original-http-reference-recipe.patch"
VERIFY="$ROOT/scripts/verify-mpvkit-dvfel-artifacts.sh"
WORKFLOW="$ROOT/.github/workflows/release-tvos.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in "$BUILD" "$PATCH" "$REFERENCE_PATCH" "$VERIFY" "$WORKFLOW"; do
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
grep -Fq 'diff --git a/Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch b/Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch' "$PATCH" ||
  fail "approved MPVKit tree must carry the exact Swift frontend recipe correction"
grep -Fq "+    swift_flags = ['-frontend', '-c', '-whole-module-optimization', '-sdk', macos_sdk_path," "$PATCH" ||
  fail "one-object Swift frontend recipe must request whole-module compilation"

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
grep -Fq 'verify_ffmpeg_maintenance "$target" "$headers" "$slice"' "$VERIFY" ||
  fail "artifact gate must reject the superseded 63.1.100 artifact in every FFmpeg slice"
grep -Fq '${prefix}_VERSION_MINOR[[:space:]]+1' "$VERIFY" || fail "artifact gate must require maintenance minor 1"
grep -Fq '${prefix}_VERSION_MICRO[[:space:]]+102' "$VERIFY" || fail "artifact gate must require maintenance micro 102"
grep -Fq 'ffmpegPinnedSHA = "946fcce07b6dcd0331c8cc609192aeff5e1924f8"' "$PATCH" ||
  fail "builder must bind the reviewed n9.0.2 commit"
grep -Fq 'ffmpegPinnedBranch = "n9.0.2"' "$PATCH" || fail "builder must fetch the reviewed release tag"
grep -Fq 'Libmpv-GPL; do' "$VERIFY" || fail "artifact gate must validate Libmpv slices"
grep -Fq 'expected_arches' "$VERIFY" || fail "artifact gate must require exact per-slice architectures"
grep -Fq 'tvos-arm64_arm64e' "$VERIFY" || fail "artifact gate must enumerate the tvOS arm64e slice"
grep -Fq 'dovi_split' "$VERIFY" || fail "artifact gate must require dovi_split"
grep -Fq 'if [ "$target" = Libavcodec-GPL ]; then' "$VERIFY" ||
  fail "artifact gate must scope dovi_split to libavcodec"
grep -Fq 'verify-mpvkit-dvfel-apple-tls.sh' "$VERIFY" || fail "artifact gate must retain TLS verification"

# Extract the real fetch step and require the verifier after unzip, before the next workflow step.
fetch_step="$(awk '/^[[:space:]]+- name: Fetch the MPVKit-DVFEL artifacts/{active=1; next}
  active && /^[[:space:]]+- name:/{exit} active{print}' "$WORKFLOW")"
grep -Fq 'unzip -oq /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must unpack the pinned artifact"
grep -Fq 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must run the real MPV artifact verifier"
unzip_line="$(grep -nF 'unzip -oq /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
verify_line="$(grep -nF 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
[ "$verify_line" -gt "$unzip_line" ] || fail "artifact verifier must run after unpack"

# Exercise the production builder preflight against a tiny local Git fixture. The approved patch is
# generated from the fixture's clean base, then the same builder is run for a clean apply, an exact
# patched retry including tracked 0002, unrelated/partial recipe edits, and an unknown untracked
# file. No native build tools are used: the builder exits only after checkout/patch preflight.
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

# A verified component ZIP also contains root files such as .gitignore that already
# exist in the vendor directory. Both real consumers must extract without a stdin
# prompt; do not mistake an EOF prompt failure for bad native payload contents.
SHELL_WORKFLOW="$ROOT/.github/workflows/release-packaging-validation.yml"
grep -Fq 'unzip -oq "$RUNNER_TEMP/mpvkit.zip" -d "$DEST"' "$SHELL_WORKFLOW" ||
  fail "secretless consumer must noninteractively unpack the verified artifact"
mkdir -p "$FIXTURE/extract-source/artifacts" "$FIXTURE/extract-destination"
printf 'verified component root\n' > "$FIXTURE/extract-source/.gitignore"
printf 'verified payload\n' > "$FIXTURE/extract-source/artifacts/payload"
printf 'previous vendor root\n' > "$FIXTURE/extract-destination/.gitignore"
(
  cd "$FIXTURE/extract-source"
  zip -q "$FIXTURE/collision.zip" .gitignore artifacts/payload
)
unzip -oq "$FIXTURE/collision.zip" -d "$FIXTURE/extract-destination" < /dev/null
cmp "$FIXTURE/extract-source/.gitignore" "$FIXTURE/extract-destination/.gitignore" ||
  fail "noninteractive unpack did not replace the known existing component file"
cmp "$FIXTURE/extract-source/artifacts/payload" "$FIXTURE/extract-destination/artifacts/payload" ||
  fail "noninteractive unpack lost an artifact entry"

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name "MPVKit contract fixture"
git -C "$SOURCE" config user.email "fixture@example.invalid"
mkdir -p "$SOURCE/Sources"
printf '%s\n' 'let packageValue = "base"' >"$SOURCE/Package.swift"
printf '%s\n' 'let sourceValue = "base"' >"$SOURCE/Sources/main.swift"
FIXTURE_SWIFT_RECIPE='Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch'
mkdir -p "$(dirname "$SOURCE/$FIXTURE_SWIFT_RECIPE")"
printf '%s\n' "swift_flags = ['-frontend', '-c', '-sdk', 'fixture-sdk']" >"$SOURCE/$FIXTURE_SWIFT_RECIPE"
cp "$SOURCE/Package.swift" "$FIXTURE/base-package.swift"
cp "$SOURCE/$FIXTURE_SWIFT_RECIPE" "$FIXTURE/base-swift-recipe.patch"
git -C "$SOURCE" add -- Package.swift Sources/main.swift "$FIXTURE_SWIFT_RECIPE"
git -C "$SOURCE" commit -q -m "fixture base"
FIXTURE_REF="$(git -C "$SOURCE" rev-parse HEAD)"

printf '%s\n' 'let packageValue = "approved"' >"$SOURCE/Package.swift"
printf '%s\n' "swift_flags = ['-frontend', '-c', '-whole-module-optimization', '-sdk', 'fixture-sdk']" >"$SOURCE/$FIXTURE_SWIFT_RECIPE"
git -C "$SOURCE" diff --binary -- Package.swift "$FIXTURE_SWIFT_RECIPE" >"$FIXTURE_PATCH"
[ -s "$FIXTURE_PATCH" ] || fail "fixture patch was not generated"
cp "$FIXTURE/base-package.swift" "$SOURCE/Package.swift"
cp "$FIXTURE/base-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ] ||
  fail "fixture must start clean"

# Capture the installed resolver before creating the builder-only tool stubs. The
# target-isolation fixture must exercise real pkg-config metadata resolution.
PKG_CONFIG_EXECUTABLE="$(command -v pkg-config)" || fail "installed pkg-config is required"
case "$PKG_CONFIG_EXECUTABLE" in
  /*) [ -x "$PKG_CONFIG_EXECUTABLE" ] || fail "pkg-config is not executable" ;;
  *) fail "pkg-config must resolve to an absolute installed executable" ;;
esac

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
grep -Fq -- '-whole-module-optimization' "$SOURCE/$FIXTURE_SWIFT_RECIPE" ||
  fail "clean fixture did not carry the approved Swift frontend recipe"
cp "$SOURCE/Package.swift" "$FIXTURE/exact-package.swift"
cp "$SOURCE/$FIXTURE_SWIFT_RECIPE" "$FIXTURE/exact-swift-recipe.patch"

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

printf '%s\n' 'unrelated recipe edit' >>"$SOURCE/$FIXTURE_SWIFT_RECIPE"
if run_builder "$FIXTURE/unrelated-recipe.log"; then
  fail "unrelated edit to the approved tracked Swift recipe was accepted"
fi
grep -Fq 'exact approved VortX patch' "$FIXTURE/unrelated-recipe.log" ||
  fail "unrelated recipe edit failed without the exact-tree diagnostic"
cp "$FIXTURE/exact-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

cp "$FIXTURE/base-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"
if run_builder "$FIXTURE/partial-recipe.log"; then
  fail "partial approved tree with the Swift recipe missing was accepted"
fi
grep -Fq 'exact approved VortX patch' "$FIXTURE/partial-recipe.log" ||
  fail "partial recipe failed without the exact-tree diagnostic"
cp "$FIXTURE/exact-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

printf '%s\n' 'untracked fixture data' >"$SOURCE/untracked.txt"
if run_builder "$FIXTURE/untracked.log"; then
  fail "unknown untracked file was accepted"
fi
grep -Fq 'unexpected dirty state' "$FIXTURE/untracked.log" ||
  fail "unknown untracked file failed without the dirty-state diagnostic"
rm -f "$SOURCE/untracked.txt"

[ "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" = "$(printf '%s\n' ' M Package.swift' " M $FIXTURE_SWIFT_RECIPE")" ] ||
  fail "fixture did not retain only the exact approved patch after dirty-state cases"

# Compile actual patched SpikeGit and target pkg-config getters extracted from canonical MPVKit.
# The fixture supplies surrounding types and a Process-backed Utility, retaining production bodies.
CANONICAL_MPVKIT="${MPVKIT_DVFEL_CANONICAL:-/Users/daksh/VortXTV/MPVKit}"
[ -d "$CANONICAL_MPVKIT/.git" ] || fail "canonical MPVKit checkout is unavailable: $CANONICAL_MPVKIT"
CANONICAL_REF="$(git -C "$CANONICAL_MPVKIT" rev-parse HEAD)"
[ "$CANONICAL_REF" = "2103893078c5e339073b11737b86f7f22b9c4491" ] ||
  fail "canonical MPVKit fixture source is not pinned to 2103893: $CANONICAL_REF"

# Verify the new native carrier through real Git application, not string-only
# assertions or a copied C implementation. Only its HTTP/local-witness source
# prerequisites touch these three preimages. Existing constructor/publication
# producer contracts remain intact; this block is not their runtime proof.
NATIVE_SOURCE="${MPVKIT_DVFEL_NATIVE_CONTRACT_SOURCE:-$CANONICAL_MPVKIT/dist/libmpv-master-8c67647b}"
[ -e "$NATIVE_SOURCE/.git" ] || fail "canonical native contract source is unavailable: $NATIVE_SOURCE"
NATIVE_HEAD="$(git -C "$NATIVE_SOURCE" rev-parse HEAD)"
[ "$NATIVE_HEAD" = "8c67647b50059406c5c0444903597281b81516cf" ] ||
  fail "native contract source is not pinned to 8c67647b: $NATIVE_HEAD"
REFERENCE_HASH="$(shasum -a 256 "$REFERENCE_PATCH")"
[ "${REFERENCE_HASH%% *}" = "7d4eaa5236fa8b1b7fb2bd1500ff71aac48fa79fca9e790dfab0dee6d3f0023e" ] ||
  fail "native initial-request carrier differs from the reviewed source"
NATIVE_REAL_INDEX="$(git -C "$NATIVE_SOURCE" rev-parse --path-format=absolute --git-path index)"
[ -f "$NATIVE_REAL_INDEX" ] || fail "native canonical index is unavailable"
NATIVE_INDEX_BEFORE="$(shasum -a 256 "$NATIVE_REAL_INDEX")"
NATIVE_INDEX="$FIXTURE/native-reference.index"
native_git() {
  GIT_INDEX_FILE="$NATIVE_INDEX" git -C "$NATIVE_SOURCE" "$@"
}
check_native_source() {
  local relative="$1" expected="$2" observed
  native_git show ":$relative" >"$FIXTURE/native-reference-${relative##*/}"
  observed="$(shasum -a 256 "$FIXTURE/native-reference-${relative##*/}")"
  [ "${observed%% *}" = "$expected" ] || fail "native source identity mismatch: $relative"
}
native_git read-tree "$NATIVE_HEAD"
native_git apply --cached "$ROOT/scripts/mpv-http-seek-interrupt.patch"
native_git apply --cached "$ROOT/scripts/mpv-original-local-file-witness.patch"
check_native_source stream/stream.h e7c6b69128db214210074d3a88e4291f97e2fc3119e60f34d8601a2085416fef
check_native_source stream/stream.c 9f99d368a9485c6d1977735cc7276eda34b512bf61ee45cfd585a084d677f034
check_native_source stream/stream_lavf.c a162b26af4381e946f9a0fa576b12bc9b29310135b6deb7f134cf6867068c654
if native_git ls-files --error-unmatch -- stream/reference_source.h >/dev/null 2>&1; then
  fail "native reference header unexpectedly exists before carrier application"
fi
NATIVE_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$REFERENCE_PATCH"
[ "$(native_git diff --cached --name-only "$NATIVE_PRE_TREE" --)" = "$(printf '%s\n' \
  stream/reference_source.h stream/stream.c stream/stream.h stream/stream_lavf.c)" ] ||
  fail "native initial-request carrier changed unexpected source paths"
check_native_source stream/stream.h a5f1b6fd23f58bcb0282e36448f34dde0121768abac95913c29163ae163747c6
check_native_source stream/stream.c 6da9c9c7e1efb4da5a37fe4c7a92188d9f3d4732bdfd4a4c976fe7e9f30145e9
check_native_source stream/stream_lavf.c 15a7a08223efe0db0a33b2bc7b39616dd43fecfc1eca1e0ced23f16c7a839ad9
check_native_source stream/reference_source.h 6330b5056700efacd2655a31b011a88c3e4e8b6424360bfe6ee1d728fd7399a1
[ "$(shasum -a 256 "$NATIVE_REAL_INDEX")" = "$NATIVE_INDEX_BEFORE" ] ||
  fail "native canonical index changed during the isolated carrier contract"

PATCHED_INDEX="$FIXTURE/mpvkit-source.index"
PATCHED_SOURCE="$FIXTURE/mpvkit-main.swift"
PATCHED_BASE="$FIXTURE/mpvkit-base.swift"
# Verify the entire approved patch in an isolated index, then emit only these two inputs.
# No source checkout or canonical index/working-tree edit is created.
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" read-tree HEAD
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" apply --cached "$PATCH"
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" show :Sources/BuildScripts/XCFrameworkBuild/main.swift >"$PATCHED_SOURCE"
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" show :Sources/BuildScripts/XCFrameworkBuild/base.swift >"$PATCHED_BASE"
swiftc -j 1 -num-threads 1 -parse "$PATCHED_SOURCE" ||
  fail "actual patched MPVKit BuildScripts source did not parse"
SPIKE_BLOCK="$FIXTURE/spikegit-production.swift"
sed -n '/^enum SpikeGit {/,/^private class BuildOpenSSL: ZipBaseBuild {/p' \
  "$PATCHED_SOURCE" | sed '$d' >"$SPIKE_BLOCK"
[ -s "$SPIKE_BLOCK" ] || fail "could not extract the patched production SpikeGit implementation"
SMB_METADATA_BLOCK="$FIXTURE/smb-metadata-production.swift"
sed -n '/^enum SmbMetadataNormalizer {/,/^private class BuildSmbclient:/p' \
  "$PATCHED_SOURCE" | sed '$d' >"$SMB_METADATA_BLOCK"
[ -s "$SMB_METADATA_BLOCK" ] || fail "could not extract production SmbMetadataNormalizer"
ENVIRONMENT_BLOCK="$FIXTURE/environment-production.swift"
PKG_CONFIG_BLOCK="$FIXTURE/pkgconfig-production.swift"
# These selectors end at the method's four-space closing brace, preserving each
# complete production body without pulling unrelated SDK/build implementation in.
sed -n '/^    func environment(platform: PlatformType, arch: ArchType) -> \[String: String\] {/,/^    }/p' \
  "$PATCHED_BASE" >"$ENVIRONMENT_BLOCK"
sed -n '/^    func pkgConfigPath(arch: ArchType) -> String {/,/^    }/p' \
  "$PATCHED_BASE" >"$PKG_CONFIG_BLOCK"
[ -s "$ENVIRONMENT_BLOCK" ] || fail "could not extract production BaseBuild.environment"
[ -s "$PKG_CONFIG_BLOCK" ] || fail "could not extract production PlatformType.pkgConfigPath"
SDK_SYSTEM_BLOCK="$FIXTURE/sdk-system-production.swift"
sed -n '/^enum SDKSystemMetadata {/,/^class BaseBuild {/p' "$PATCHED_BASE" | sed '$d' >"$SDK_SYSTEM_BLOCK"
[ -s "$SDK_SYSTEM_BLOCK" ] || fail "could not extract production SDKSystemMetadata"
base_build="$(sed -n '/^    func build(platform: PlatformType, arch: ArchType) throws {/,/^    }/p' "$PATCHED_BASE")"
grep -Fq 'var environ = environment(platform: platform, arch: arch)' <<<"$base_build" ||
  fail "actual BaseBuild.build must retain a mutable production environment"
grep -Fq 'try SDKSystemMetadata.append(to: &environ, sdkRoot: URL(fileURLWithPath: platform.isysroot), buildRoot: buildURL)' <<<"$base_build" ||
  fail "actual BaseBuild.build must append selected SDK metadata before launching its tools"
sdk_append_line="$(grep -nF 'try SDKSystemMetadata.append(' <<<"$base_build" | cut -d: -f1)"
first_tool_line="$(grep -nF 'Utility.' <<<"$base_build" | head -1 | cut -d: -f1)"
[ "$sdk_append_line" -lt "$first_tool_line" ] || fail "SDK metadata must precede the actual build tool calls"

SWIFT_PATCH_DIR="$FIXTURE/Sources/BuildScripts/patch/fixture"
mkdir -p "$SWIFT_PATCH_DIR"
cp "$FIXTURE_PATCH" "$SWIFT_PATCH_DIR/0001-approved.patch"
cp "$FIXTURE/base-package.swift" "$SOURCE/Package.swift"
cp "$FIXTURE/base-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

SWIFT_HELPER="$FIXTURE/spikegit-fixture.swift"
{
  printf '%s\n' \
    'import Foundation' \
    'import Darwin' \
    'import CryptoKit' \
    '' \
    'enum Library: String, CaseIterable {' \
    '    case fixture, FFmpeg, openssl' \
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
    '' \
    '    static func + (left: URL, right: [String]) -> URL {' \
    '        right.reduce(left) { $0.appendingPathComponent($1) }' \
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
  cat "$SMB_METADATA_BLOCK"
  cat "$SDK_SYSTEM_BLOCK"
  cat <<'SWIFT_TYPES'

enum ArchType: String { case arm64, x86_64, arm64e }
enum PlatformType: String {
    case xros, xrsimulator, maccatalyst, macos, isimulator, tvsimulator, tvos, ios
SWIFT_TYPES
  cat "$PKG_CONFIG_BLOCK"
  cat <<'SWIFT_BASE'
}

class BaseBuild {
    static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    func cFlags(platform: PlatformType, arch: ArchType) -> [String] { ["fixture-cflags"] }
    func ldFlags(platform: PlatformType, arch: ArchType) -> [String] { ["fixture-ldflags"] }
SWIFT_BASE
  cat "$ENVIRONMENT_BLOCK"
  cat <<'SWIFT_ISOLATION'
}

func requireFixture(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(domain: "TargetIsolationFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func writeModule(_ name: String, version: String = "1.0", requires: String = "", in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = """
    Name: \(name)
    Description: Synthetic target-isolation contract sentinel
    Version: \(version)
    Requires.private: \(requires)
    Libs: -lvortx_sentinel

    """
    try contents.write(to: directory.appendingPathComponent("\(name).pc"), atomically: true, encoding: .utf8)
}

func runTargetIsolation(executable: String, root: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try requireFixture(manager.changeCurrentDirectoryPath(root.path), "could not enter pkg-config fixture")
    let hostPath = root.appendingPathComponent("host-path")
    let hostLibdir = root.appendingPathComponent("host-libdir")
    try requireFixture(ProcessInfo.processInfo.environment["PKG_CONFIG_PATH"] == hostPath.path,
                       "parent PKG_CONFIG_PATH poison was not supplied")
    try requireFixture(ProcessInfo.processInfo.environment["PKG_CONFIG_LIBDIR"] == hostLibdir.path,
                       "parent PKG_CONFIG_LIBDIR poison was not supplied")
    try writeModule("vortx-host-path-sentinel", in: hostPath)
    try writeModule("vortx-host-libdir-sentinel", in: hostLibdir)
    try writeModule("vortx-transitive-host-sentinel", in: hostPath)
    // A duplicate target identity makes host precedence observable by its version.
    try writeModule("vortx-target-sentinel", version: "9.0", in: hostPath)
    let poison = ["PKG_CONFIG_PATH": hostPath.path, "PKG_CONFIG_LIBDIR": hostLibdir.path]
    for module in ["vortx-host-path-sentinel", "vortx-host-libdir-sentinel"] {
        _ = try Utility.launch(path: executable, arguments: ["--exists", module], environment: poison)
    }

    let cases: [(PlatformType, ArchType)] = [
        (.tvos, .arm64), (.tvos, .arm64e), (.tvsimulator, .x86_64),
        (.ios, .arm64), (.macos, .arm64),
    ]
    for (platform, arch) in cases {
        let environment = BaseBuild().environment(platform: platform, arch: arch)
        let getter = platform.pkgConfigPath(arch: arch)
        try requireFixture(environment["PKG_CONFIG_LIBDIR"] == getter, "environment did not use production target getter")
        try requireFixture(environment["PKG_CONFIG_PATH"] == "", "environment must explicitly clear PKG_CONFIG_PATH")
        let paths = getter.components(separatedBy: ":")
        let suffix = "\(platform.rawValue)/thin/\(arch.rawValue)/lib/pkgconfig"
        let expected = ["fixture", "FFmpeg", "openssl"].map { root.appendingPathComponent("\($0)/\(suffix)").path }
        try requireFixture(paths == expected, "target roots differ, contain host roots, or contain empty segments: \(getter)")
        try requireFixture(paths.count == Library.allCases.count && !paths.contains(""), "target root list is not finite and explicit")
        try requireFixture(paths.allSatisfy { !manager.fileExists(atPath: $0) }, "absent dependency roots were not retained")
        let target = URL(fileURLWithPath: paths[1])
        try writeModule("vortx-target-sentinel", in: target)
        try writeModule("vortx-needs-host-sentinel", requires: "vortx-transitive-host-sentinel", in: target)
        // Positive control proves the host dependency exists and can satisfy the
        // target's private dependency if host search is accidentally permitted.
        var contaminated = poison
        contaminated["PKG_CONFIG_PATH"] = "\(hostPath.path):\(target.path)"
        _ = try Utility.launch(path: executable, arguments: ["--static", "--libs", "vortx-needs-host-sentinel"], environment: contaminated)
        let version = try Utility.launch(path: executable, arguments: ["--modversion", "vortx-target-sentinel"], isOutput: true, environment: environment)
        try requireFixture(version == "1.0", "target metadata was missing or shadowed by the host sentinel")
        for module in ["vortx-host-path-sentinel", "vortx-host-libdir-sentinel"] {
            let result = try? Utility.launch(path: executable, arguments: ["--exists", module], environment: environment)
            try requireFixture(result == nil, "host-only module leaked into target search: \(module)")
        }
        let transitive = try? Utility.launch(path: executable, arguments: ["--static", "--libs", "vortx-needs-host-sentinel"], environment: environment)
        try requireFixture(transitive == nil, "missing target private dependency was satisfied by host metadata")
    }

    // No roots exist for this different platform/architecture. The getter must
    // still set nonempty LIBDIR, and the resolver must fail despite host poison.
    let missing = BaseBuild().environment(platform: .xrsimulator, arch: .arm64e)
    let missingPaths = (missing["PKG_CONFIG_LIBDIR"] ?? "").components(separatedBy: ":")
    try requireFixture(missingPaths.count == Library.allCases.count && !missingPaths.contains(""), "absent roots produced empty LIBDIR")
    try requireFixture(missingPaths.allSatisfy { !manager.fileExists(atPath: $0) }, "missing target fixture unexpectedly exists")
    let absent = try? Utility.launch(path: executable, arguments: ["--exists", "vortx-target-sentinel"], environment: missing)
    try requireFixture(absent == nil, "nonexistent target roots fell back to host metadata")
    print("TARGET ISOLATION FIXTURE PASS")
}

// These observations deliberately reuse production's immutable proof records.
// They exercise policy, not physical ZIP/archive/header validation or provenance.
func smbObserved(_ base: SmbMetadataNormalizer.Snapshot,
                 version: String? = nil, zipHash: String? = nil,
                 headers: [String: String]? = nil, archives: [String: String]? = nil,
                 templates: [String: String]? = nil, requested: Set<String>? = nil,
                 restored: [String: SmbMetadataNormalizer.Restored]? = nil) -> SmbMetadataNormalizer.Snapshot {
    SmbMetadataNormalizer.Snapshot(version: version ?? base.version, zipHash: zipHash ?? base.zipHash,
        headers: headers ?? base.headers, archives: archives ?? base.archives,
        templates: templates ?? base.templates, requested: requested ?? base.requested,
        restored: restored ?? base.restored)
}

func expectSmbRefusal(_ label: String, _ operation: () throws -> Void) throws {
    var rejected = false
    do { try operation() } catch { rejected = true }
    try requireFixture(rejected, "SMB policy accepted \(label)")
}

func runSmbMetadataContract(root: URL) throws {
    typealias Normalizer = SmbMetadataNormalizer
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let output = root.appendingPathComponent("output")
    let headers = Normalizer.headerPins.mapValues { $0.1 }
    let archives = Dictionary(uniqueKeysWithValues: Normalizer.rows.compactMap { row in row.archiveHash.map { (row.key, $0) } })
    let templates = Dictionary(uniqueKeysWithValues: Normalizer.rows.map { ($0.key, Normalizer.template($0)) })
    let requested = Set(Normalizer.rows.map { $0.key })
    let restored = Dictionary(uniqueKeysWithValues: Normalizer.rows.map { row in
        (row.key, Normalizer.Restored(text: templates[row.key]!.replacingOccurrences(of: "/path/to/workdir", with: output.path),
                                     archiveHash: row.archiveHash, headers: headers))
    })
    let original = Normalizer.Snapshot(version: Normalizer.version, zipHash: Normalizer.zipHash,
        headers: headers, archives: archives, templates: templates, requested: requested, restored: restored)
    let correctable: Set<String> = ["isimulator/x86_64", "macos/arm64", "macos/x86_64", "tvos/arm64e", "tvsimulator/x86_64"]
    let unchanged: Set<String> = ["ios/arm64", "isimulator/arm64", "tvos/arm64", "tvsimulator/arm64"]
    let unsupported: Set<String> = ["maccatalyst/arm64", "maccatalyst/x86_64", "xros/arm64", "xrsimulator/arm64"]
    try requireFixture(archives.count == 9 && templates.count == 13, "production proof record cardinality changed")
    try requireFixture(requested == correctable.union(unchanged).union(unsupported), "production template keys changed")
    let changes = try Normalizer.plan(original, outputRoot: output)
    try requireFixture(Set(changes.keys) == correctable, "plan must change exactly the five approved GLib declarations")
    for row in Normalizer.rows {
        let before = restored[row.key]!.text
        guard let after = changes[row.key] else {
            try requireFixture(unchanged.contains(row.key) || unsupported.contains(row.key), "approved correction was omitted")
            try requireFixture(Normalizer.template(row, corrected: true) == templates[row.key], "unchanged/unsupported template would be normalized")
            continue
        }
        let exactRemoval = before.replacingOccurrences(of: " -lglib-2.0", with: "")
            .replacingOccurrences(of: "Requires.private: gnutls glib-2.0", with: "Requires.private: gnutls")
        try requireFixture(after == exactRemoval, "correction changed fields beyond the exact two GLib tokens")
        for retained in ["Version: 0.7.0\n", "-lresolv -lpthread -lz -liconv -lgnutls", "-lncurses -lreadline", "Requires.private: gnutls\n", "-lsmbclient"] {
            try requireFixture(after.contains(retained), "correction removed API version, GnuTLS, or system flags")
        }
        try requireFixture(after.contains(" -lpam") == row.pam, "correction changed PAM selection")
        try requireFixture(!after.contains("glib-2.0"), "approved GLib token was retained")
    }
    var afterRestored = restored
    for (key, text) in changes {
        let prior = restored[key]!
        afterRestored[key] = Normalizer.Restored(text: text, archiveHash: prior.archiveHash, headers: prior.headers)
    }
    let afterPlan = try Normalizer.plan(smbObserved(original, restored: afterRestored), outputRoot: output)
    try requireFixture(afterPlan.isEmpty, "exact approved afterimages were not idempotent")
    let completed: Set<String> = ["macos/arm64", "tvos/arm64e"]
    var partial = restored
    for key in completed { partial[key] = afterRestored[key] }
    let partialPlan = try Normalizer.plan(smbObserved(original, restored: partial), outputRoot: output)
    try requireFixture(Set(partialPlan.keys) == correctable.subtracting(completed), "mixed exact before/after states were not recoverable")
    try requireFixture(partialPlan.allSatisfy { changes[$0.key] == $0.value }, "partial recovery changed approved output")
    let active = correctable.union(unchanged)
    let activeRestored = restored.filter { active.contains($0.key) }
    let activePlan = try Normalizer.plan(smbObserved(original, requested: active, restored: activeRestored), outputRoot: output)
    try requireFixture(activePlan == changes, "selecting the nine proven payloads changed correction policy")
    let none = try Normalizer.plan(smbObserved(original, requested: [], restored: [:]), outputRoot: output)
    try requireFixture(none.isEmpty, "wrapper validation planned unrequested writes")

    var failures: [(String, Normalizer.Snapshot)] = [
        ("wrong version", smbObserved(original, version: "4.25.1")),
        ("wrong ZIP fingerprint", smbObserved(original, zipHash: String(repeating: "0", count: 64))),
        ("missing canonical headers", smbObserved(original, headers: [:])),
        ("missing raw archive", smbObserved(original, archives: [:])),
        ("missing raw templates", smbObserved(original, templates: [:])),
        ("missing requested restored row", smbObserved(original, restored: [:])),
        ("extra restored row", smbObserved(original, requested: active)),
    ]
    var badHeaders = headers
    badHeaders["libsmbclient.h"] = "changed-header"
    failures.append(("wrong canonical header", smbObserved(original, headers: badHeaders)))
    var badArchives = archives
    badArchives["macos/arm64"] = "changed-archive"
    failures.append(("wrong raw archive", smbObserved(original, archives: badArchives)))
    badArchives = archives
    badArchives["maccatalyst/arm64"] = archives["macos/arm64"]
    failures.append(("unproven archive observation", smbObserved(original, archives: badArchives)))
    var badTemplates = templates
    badTemplates["macos/arm64"] = templates["macos/arm64"]! + "# unrelated change\n"
    failures.append(("changed raw PC", smbObserved(original, templates: badTemplates)))
    badTemplates = templates
    badTemplates["unknown/arm64"] = "unknown template"
    failures.append(("unknown raw template row", smbObserved(original, templates: badTemplates)))
    let selected = "macos/arm64"
    let prior = restored[selected]!
    var badRestored = restored
    badRestored[selected] = Normalizer.Restored(text: prior.text, archiveHash: "changed-restored-archive", headers: prior.headers)
    failures.append(("wrong restored archive", smbObserved(original, restored: badRestored)))
    badRestored = restored
    badRestored[selected] = Normalizer.Restored(text: prior.text, archiveHash: prior.archiveHash, headers: badHeaders)
    failures.append(("wrong restored header", smbObserved(original, restored: badRestored)))
    badRestored = restored
    badRestored[selected] = Normalizer.Restored(text: prior.text + "# unrelated change\n", archiveHash: prior.archiveHash, headers: prior.headers)
    failures.append(("changed restored PC", smbObserved(original, restored: badRestored)))
    badRestored = restored
    badRestored["unknown/arm64"] = prior
    failures.append(("unknown requested key", smbObserved(original, requested: requested.union(["unknown/arm64"]), restored: badRestored)))
    for (label, observation) in failures {
        try expectSmbRefusal(label) { _ = try Normalizer.plan(observation, outputRoot: output) }
    }
    // The wrapper-name guard runs before payload IO; no 97 MB ZIP is fabricated.
    try expectSmbRefusal("wrong wrapper directory") {
        _ = try Normalizer.snapshot(wrapper: root.appendingPathComponent("unapproved-wrapper"), outputRoot: output,
                                    version: Normalizer.version, requested: [])
    }

    // Exercise actual streaming fileHash only on tiny data, with a known SHA-256.
    let bytes = Data("abc".utf8)
    let small = root.appendingPathComponent("hash-input")
    try bytes.write(to: small)
    let smallHash = try Normalizer.fileHash(small, size: 3)
    try requireFixture(smallHash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "small streaming hash differs")
    try expectSmbRefusal("wrong small-file size") { _ = try Normalizer.fileHash(small, size: 4) }
    let symlink = root.appendingPathComponent("hash-link")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: small)
    try expectSmbRefusal("small-file symlink") { _ = try Normalizer.fileHash(symlink, size: 3) }
    let remainingBytes = try Data(contentsOf: small)
    try requireFixture(remainingBytes == bytes, "hash/validation changed fixture input bytes")
    let entries = try manager.contentsOfDirectory(atPath: root.path).sorted()
    try requireFixture(entries == ["hash-input", "hash-link"], "pure plan wrote files or fileHash mutated the fixture set")
    // Exact-name cached zero ZIP must refuse without deleting its cache/sibling data.
    let cache = root.appendingPathComponent("libsmbclient-\(Normalizer.version)")
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    let zeroZIP = cache.appendingPathComponent("libsmbclient.zip")
    let sibling = cache.appendingPathComponent("keep")
    try Data().write(to: zeroZIP)
    try bytes.write(to: sibling)
    try expectSmbRefusal("cached zero ZIP") { try Normalizer.validateArchive(zeroZIP, version: Normalizer.version) }
    let zeroBytes = try Data(contentsOf: zeroZIP)
    let siblingBytes = try Data(contentsOf: sibling)
    try requireFixture(zeroBytes.isEmpty, "cached zero ZIP was changed or deleted")
    try requireFixture(siblingBytes == bytes, "cached ZIP validation deleted sibling data")
    let absentDirectory = root.appendingPathComponent("fresh-absent")
    try Normalizer.validateFreshDirectory(absentDirectory)
    try requireFixture(!manager.fileExists(atPath: absentDirectory.path), "fresh validation created a cache")
    let emptyDirectory = root.appendingPathComponent("fresh-empty")
    try manager.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
    try Normalizer.validateFreshDirectory(emptyDirectory)
    let partialDirectory = root.appendingPathComponent("fresh-partial")
    try manager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
    let retained = partialDirectory.appendingPathComponent("retained")
    try bytes.write(to: retained)
    try expectSmbRefusal("nonempty cache without ZIP") { try Normalizer.validateFreshDirectory(partialDirectory) }
    let retainedBytes = try Data(contentsOf: retained)
    try requireFixture(retainedBytes == bytes, "fresh-cache refusal changed unknown retained data")
    let directoryLink = root.appendingPathComponent("fresh-link")
    try manager.createSymbolicLink(at: directoryLink, withDestinationURL: emptyDirectory)
    try expectSmbRefusal("symlink cache without ZIP") { try Normalizer.validateFreshDirectory(directoryLink) }
    print("SMB METADATA POLICY FIXTURE PASS (synthetic fingerprints; not physical ZIP/payload validation)")
}

func runSDKSystemContract(executable: String, root: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try requireFixture(manager.changeCurrentDirectoryPath(root.path), "could not enter SDK fixture")
    let header = "#define ZLIB_VERSION \"1.2.13\"\n"
    let xmlHeader = "#define LIBXML_DOTTED_VERSION \"2.9.13\"\n"
    let stub = "--- !tapi-tbd\ntbd-version: 4\ntargets: [ arm64-macos ]\ninstall-name: '/usr/lib/libz.1.dylib'\n...\n"
    func tree(_ name: String, header text: String? = nil, stub linker: String? = nil) throws -> (URL, URL) {
        let sdk = root.appendingPathComponent(name + ".sdk"), build = root.appendingPathComponent(name + "-build")
        try manager.createDirectory(at: sdk.appendingPathComponent("usr/include"), withIntermediateDirectories: true)
        try manager.createDirectory(at: sdk.appendingPathComponent("usr/include/libxml2/libxml"), withIntermediateDirectories: true)
        try manager.createDirectory(at: sdk.appendingPathComponent("usr/lib"), withIntermediateDirectories: true)
        try manager.createDirectory(at: build, withIntermediateDirectories: true)
        try (text ?? header).write(to: sdk.appendingPathComponent("usr/include/zlib.h"), atomically: true, encoding: .utf8)
        try (linker ?? stub).write(to: sdk.appendingPathComponent("usr/lib/libz.tbd"), atomically: true, encoding: .utf8)
        try xmlHeader.write(to: sdk.appendingPathComponent("usr/include/libxml2/libxml/xmlversion.h"), atomically: true, encoding: .utf8)
        try stub.replacingOccurrences(of: "/usr/lib/libz.1.dylib", with: "/usr/lib/libxml2.2.dylib").write(to: sdk.appendingPathComponent("usr/lib/libxml2.tbd"), atomically: true, encoding: .utf8)
        return (sdk, build)
    }
    func refused(_ name: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try requireFixture(rejected, "SDK zlib accepted " + name)
    }
    let (sdk, build) = try tree("valid")
    let metadata = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build)
    let pc = metadata.appendingPathComponent("zlib.pc")
    let expected = "Name: zlib\nDescription: Target Apple SDK zlib\nVersion: 1.2.13\nLibs: -lz\nCflags:\n"
    let xmlPC = metadata.appendingPathComponent("libxml-2.0.pc")
    let expectedXML = "Name: libxml-2.0\nDescription: Target Apple SDK libxml2\nVersion: 2.9.13\nLibs: -lxml2\nCflags: -I\"\(sdk.path)/usr/include/libxml2\"\n"
    let first = try String(contentsOf: pc, encoding: .utf8)
    let firstXML = try String(contentsOf: xmlPC, encoding: .utf8)
    let metadataNames = try manager.contentsOfDirectory(atPath: metadata.path).sorted()
    try requireFixture(firstXML == expectedXML && metadataNames == ["libxml-2.0.pc", "zlib.pc"], "SDK libxml metadata or exact two-file set differs")
    try requireFixture(metadata.path == build.appendingPathComponent("vortx-sdk-pkgconfig").path && first == expected, "SDK metadata is not the exact deterministic afterimage")
    let repeated = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build)
    let repeatedText = try String(contentsOf: pc, encoding: .utf8)
    let repeatedXML = try String(contentsOf: xmlPC, encoding: .utf8)
    try requireFixture(repeated.path == metadata.path && repeatedText == first && repeatedXML == firstXML, "SDK metadata preparation is not idempotent")
    // The actual production dictionary must replace the Process scaffold's poison.
    let host = root.appendingPathComponent("host")
    try manager.createDirectory(at: host, withIntermediateDirectories: true)
    try "Name: zlib\nDescription: Host poison\nVersion: 99.0\nLibs: -lhost_poison\n".write(to: host.appendingPathComponent("zlib.pc"), atomically: true, encoding: .utf8)
    try "Name: libxml-2.0\nDescription: Host poison\nVersion: 99.0\nLibs: -lhost_xml_poison\n".write(to: host.appendingPathComponent("libxml-2.0.pc"), atomically: true, encoding: .utf8)
    try writeModule("vortx-sdk-host-only", in: host)
    try requireFixture(ProcessInfo.processInfo.environment["PKG_CONFIG_PATH"] == host.path && ProcessInfo.processInfo.environment["PKG_CONFIG_LIBDIR"] == host.path, "SDK fixture requires poisoned parent paths")
    _ = try Utility.launch(path: executable, arguments: ["--exists", "vortx-sdk-host-only"])
    var environment = BaseBuild().environment(platform: .tvos, arch: .arm64)
    let existing = environment["PKG_CONFIG_LIBDIR"]!
    try SDKSystemMetadata.append(to: &environment, sdkRoot: sdk, buildRoot: build)
    try requireFixture(environment["PKG_CONFIG_LIBDIR"] == existing + ":" + metadata.path && environment["PKG_CONFIG_PATH"] == "", "SDK metadata must follow the unchanged target roots")
    let paths = environment["PKG_CONFIG_LIBDIR"]!.components(separatedBy: ":")
    try requireFixture(!paths.contains("") && !paths.contains(host.path), "SDK append introduced empty or host search roots")
    let target = URL(fileURLWithPath: paths[0])
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try "Name: freetype2\nDescription: Synthetic target transitive dependency\nVersion: 2.13.0\nRequires.private: zlib\nLibs: -lfreetype\nCflags:\n".write(to: target.appendingPathComponent("freetype2.pc"), atomically: true, encoding: .utf8)
    try "Name: libbluray\nDescription: Synthetic target transitive dependency\nVersion: 1.0\nRequires.private: libxml-2.0 >= 2.6\nLibs: -lbluray\nCflags:\n".write(to: target.appendingPathComponent("libbluray.pc"), atomically: true, encoding: .utf8)
    try "Name: vortx-sdk-client\nDescription: Synthetic two-SDK-row client\nVersion: 1.0\nRequires.private: zlib libxml-2.0 >= 2.6\nLibs: -lvortx_sdk_client\n".write(to: target.appendingPathComponent("vortx-sdk-client.pc"), atomically: true, encoding: .utf8)
    let version = try Utility.launch(path: executable, arguments: ["--modversion", "zlib"], isOutput: true, environment: environment)
    let flags = try Utility.launch(path: executable, arguments: ["--cflags", "zlib"], isOutput: true, environment: environment)
    let libs = try Utility.launch(path: executable, arguments: ["--libs", "zlib"], isOutput: true, environment: environment)
    let transitive = try Utility.launch(path: executable, arguments: ["--static", "--libs", "freetype2"], isOutput: true, environment: environment)
    let xmlVersion = try Utility.launch(path: executable, arguments: ["--modversion", "libxml-2.0"], isOutput: true, environment: environment)
    let xmlFlags = try Utility.launch(path: executable, arguments: ["--cflags", "libxml-2.0"], isOutput: true, environment: environment)
    let bluray = try Utility.launch(path: executable, arguments: ["--static", "--libs", "libbluray"], isOutput: true, environment: environment)
    let both = try Utility.launch(path: executable, arguments: ["--static", "--libs", "vortx-sdk-client"], isOutput: true, environment: environment)
    try requireFixture(xmlVersion == "2.9.13" && xmlFlags.trimmingCharacters(in: .whitespacesAndNewlines) == "-I\(sdk.path)/usr/include/libxml2", "SDK libxml version/include path resolved host metadata")
    try requireFixture(bluray.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["-lbluray", "-lxml2"], "real pkg-config did not resolve target libbluray to SDK libxml")
    try requireFixture(both.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["-lvortx_sdk_client", "-lz", "-lxml2"], "real pkg-config did not resolve the two fixed SDK rows")
    try requireFixture(version == "1.2.13" && flags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && libs.trimmingCharacters(in: .whitespacesAndNewlines) == "-lz", "SDK zlib resolved host metadata or added include/library search flags")
    try requireFixture(transitive.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["-lfreetype", "-lz"], "real pkg-config did not resolve target freetype to SDK zlib")
    let leaked = try? Utility.launch(path: executable, arguments: ["--exists", "vortx-sdk-host-only"], environment: environment)
    try requireFixture(leaked == nil, "poisoned host metadata leaked after SDK append")
    try "Name: zlib\nDescription: Earlier target zlib\nVersion: 7.7.7\nLibs: -ltarget_zlib\n".write(to: target.appendingPathComponent("zlib.pc"), atomically: true, encoding: .utf8)
    let earlier = try Utility.launch(path: executable, arguments: ["--modversion", "zlib"], isOutput: true, environment: environment)
    try requireFixture(earlier == "7.7.7", "SDK zlib shadowed an earlier target dependency")
    try "Name: libxml-2.0\nDescription: Earlier target libxml\nVersion: 7.7.7\nLibs: -ltarget_xml\n".write(to: target.appendingPathComponent("libxml-2.0.pc"), atomically: true, encoding: .utf8)
    let earlierXML = try Utility.launch(path: executable, arguments: ["--modversion", "libxml-2.0"], isOutput: true, environment: environment)
    try requireFixture(earlierXML == "7.7.7", "SDK libxml shadowed an earlier target dependency")
    for (name, value) in [("empty", ""), ("leading", ":" + existing), ("trailing", existing + ":"), ("middle", existing + "::missing")] {
        var invalid = environment; invalid["PKG_CONFIG_LIBDIR"] = value
        try refused(name + " LIBDIR") { try SDKSystemMetadata.append(to: &invalid, sdkRoot: sdk, buildRoot: build) }
    }
    var inherited = environment; inherited["PKG_CONFIG_PATH"] = host.path
    try refused("nonempty PKG_CONFIG_PATH") { try SDKSystemMetadata.append(to: &inherited, sdkRoot: sdk, buildRoot: build) }
    for (name, text) in [("malformed", "#define ZLIB_VERSION \"1.2.13-host\"\n"), ("duplicate", header + header)] {
        let (badSDK, badBuild) = try tree(name, header: text)
        try refused(name + " version") { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
    }
    for (name, text) in [("malformed-xml", "#define LIBXML_DOTTED_VERSION \"2.9.13-host\"\n"), ("duplicate-xml", xmlHeader + xmlHeader)] {
        let (badSDK, badBuild) = try tree(name)
        try text.write(to: badSDK.appendingPathComponent("usr/include/libxml2/libxml/xmlversion.h"), atomically: true, encoding: .utf8)
        try refused(name + " version") { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
    }
    for (name, missing) in [("missing-header", "usr/include/zlib.h"), ("missing-stub", "usr/lib/libz.tbd"), ("missing-xml-header", "usr/include/libxml2/libxml/xmlversion.h"), ("missing-xml-stub", "usr/lib/libxml2.tbd")] {
        let (badSDK, badBuild) = try tree(name)
        try manager.removeItem(at: badSDK.appendingPathComponent(missing))
        try refused(name) { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
    }
    let (invalidSDK, invalidBuild) = try tree("invalid-stub", stub: "not a TAPI zlib stub\n")
    try refused("invalid stub identity") { _ = try SDKSystemMetadata.prepare(sdkRoot: invalidSDK, buildRoot: invalidBuild) }
    let (wrongSDK, wrongBuild) = try tree("wrong-stub", stub: stub.replacingOccurrences(of: "/usr/lib/libz.1.dylib", with: "/usr/lib/libhost.dylib"))
    try refused("wrong TAPI install name") { _ = try SDKSystemMetadata.prepare(sdkRoot: wrongSDK, buildRoot: wrongBuild) }
    let (linkedSDK, linkedBuild) = try tree("linked-stub")
    try manager.moveItem(at: linkedSDK.appendingPathComponent("usr/lib/libz.tbd"), to: linkedSDK.appendingPathComponent("usr/lib/libz.1.tbd"))
    try manager.createSymbolicLink(atPath: linkedSDK.appendingPathComponent("usr/lib/libz.tbd").path, withDestinationPath: "libz.1.tbd")
    let linkedMetadata = try SDKSystemMetadata.prepare(sdkRoot: linkedSDK, buildRoot: linkedBuild)
    let (xmlLinkedSDK, xmlLinkedBuild) = try tree("linked-xml-stub")
    try manager.moveItem(at: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.tbd"), to: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.2.tbd"))
    try manager.createSymbolicLink(atPath: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.tbd").path, withDestinationPath: "libxml2.2.tbd")
    _ = try SDKSystemMetadata.prepare(sdkRoot: xmlLinkedSDK, buildRoot: xmlLinkedBuild)
    let (escapeSDK, escapeBuild) = try tree("escaping-stub")
    let outside = root.appendingPathComponent("outside.tbd"); try stub.write(to: outside, atomically: true, encoding: .utf8)
    try manager.removeItem(at: escapeSDK.appendingPathComponent("usr/lib/libz.tbd"))
    try manager.createSymbolicLink(at: escapeSDK.appendingPathComponent("usr/lib/libz.tbd"), withDestinationURL: outside)
    try refused("escaping stub symlink") { _ = try SDKSystemMetadata.prepare(sdkRoot: escapeSDK, buildRoot: escapeBuild) }
    let keptOutside = try String(contentsOf: outside, encoding: .utf8)
    try requireFixture(keptOutside == stub, "escaping-stub refusal changed its target")
    let (escapeXML, escapeXMLBuild) = try tree("escaping-xml-stub")
    try manager.removeItem(at: escapeXML.appendingPathComponent("usr/lib/libxml2.tbd"))
    try manager.createSymbolicLink(at: escapeXML.appendingPathComponent("usr/lib/libxml2.tbd"), withDestinationURL: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.2.tbd"))
    try refused("escaping libxml stub symlink") { _ = try SDKSystemMetadata.prepare(sdkRoot: escapeXML, buildRoot: escapeXMLBuild) }
    for name in ["zlib.pc", "libxml-2.0.pc"] {
        let (badSDK, badBuild) = try tree("prevalidate-" + name)
        let directory = badBuild.appendingPathComponent("vortx-sdk-pkgconfig")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let unknownPC = directory.appendingPathComponent(name)
        try "unknown\n".write(to: unknownPC, atomically: true, encoding: .utf8)
        try refused("unknown " + name + " before any other row write") { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        let kept = try String(contentsOf: unknownPC, encoding: .utf8)
        try requireFixture(names == [name] && kept == "unknown\n", "refusal wrote the missing row or changed unknown metadata")
    }
    try "unknown metadata\n".write(to: pc, atomically: true, encoding: .utf8)
    try refused("unknown existing PC") { _ = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build) }
    let unknown = try String(contentsOf: pc, encoding: .utf8)
    try requireFixture(unknown == "unknown metadata\n", "unknown PC was overwritten")
    try expected.write(to: pc, atomically: true, encoding: .utf8)
    let extra = metadata.appendingPathComponent("keep"); try "keep\n".write(to: extra, atomically: true, encoding: .utf8)
    try refused("extra metadata entry") { _ = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build) }
    let kept = try String(contentsOf: extra, encoding: .utf8)
    try requireFixture(kept == "keep\n", "unknown metadata entry was changed")
    let (_, aliasBuild) = try tree("symlink-dir")
    try manager.createSymbolicLink(at: aliasBuild.appendingPathComponent("vortx-sdk-pkgconfig"), withDestinationURL: linkedMetadata)
    try refused("symlink metadata directory") { _ = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: aliasBuild) }
    let alias = try manager.destinationOfSymbolicLink(atPath: aliasBuild.appendingPathComponent("vortx-sdk-pkgconfig").path)
    try requireFixture(alias == linkedMetadata.path, "refused metadata symlink was changed")
    print("SDK SYSTEM FIXTURE PASS (synthetic SDK zlib/libxml metadata and real pkg-config; no native build/link proof)")
}

do {
    if CommandLine.arguments[1] == "--target-isolation" {
        try runTargetIsolation(executable: CommandLine.arguments[2], root: URL(fileURLWithPath: CommandLine.arguments[3]))
    } else if CommandLine.arguments[1] == "--smb-metadata-contract" {
        try runSmbMetadataContract(root: URL(fileURLWithPath: CommandLine.arguments[2]))
    } else if CommandLine.arguments[1] == "--sdk-zlib-contract" {
        try runSDKSystemContract(executable: CommandLine.arguments[2], root: URL(fileURLWithPath: CommandLine.arguments[3]))
    } else {
        let expectedSHA = CommandLine.arguments[1]
        let checkout = URL(fileURLWithPath: CommandLine.arguments[2])
        try SpikeGit.clonePinned(url: "unused", sha: expectedSHA, library: .fixture, into: checkout)
        print("SPIKE FIXTURE PASS")
    }
    exit(0)
} catch {
    print("PRODUCTION FIXTURE FAILURE: \(error.localizedDescription)")
    exit(1)
}
SWIFT_ISOLATION
} >"$SWIFT_HELPER"

SWIFT_BINARY="$FIXTURE/spikegit-fixture"
swiftc -j 1 -num-threads 1 "$SWIFT_HELPER" -o "$SWIFT_BINARY" || fail "actual patched SpikeGit fixture did not compile"

PKG_CONFIG_PATH="$FIXTURE/sdk-zlib-contract/host" PKG_CONFIG_LIBDIR="$FIXTURE/sdk-zlib-contract/host" \
  "$SWIFT_BINARY" --sdk-zlib-contract "$PKG_CONFIG_EXECUTABLE" "$FIXTURE/sdk-zlib-contract" \
  >"$FIXTURE/sdk-zlib-contract.log" 2>&1 ||
  fail "compiled production SDK zlib fixture failed: $(cat "$FIXTURE/sdk-zlib-contract.log")"

# Pure-policy coverage uses synthetic observations of immutable production pins;
# this invocation does not hash or validate the physical wrapper ZIP/payloads.
"$SWIFT_BINARY" --smb-metadata-contract "$FIXTURE/smb-metadata-contract" \
  >"$FIXTURE/smb-metadata-contract.log" 2>&1 ||
  fail "compiled production SMB metadata policy fixture failed: $(cat "$FIXTURE/smb-metadata-contract.log")"

# The Process scaffold deliberately merges its poisoned parent environment, then
# overlays the actual production dictionary. Production Utility.launch instead
# carries HOME/default PATH only; this fixture does not claim it inherits poison.
PKG_CONFIG_PATH="$FIXTURE/pkg-config/host-path" \
  PKG_CONFIG_LIBDIR="$FIXTURE/pkg-config/host-libdir" \
  "$SWIFT_BINARY" --target-isolation "$PKG_CONFIG_EXECUTABLE" "$FIXTURE/pkg-config" \
  >"$FIXTURE/target-isolation.log" 2>&1 ||
  fail "compiled production target-isolation fixture failed: $(cat "$FIXTURE/target-isolation.log")"

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

printf '%s\n' 'unrelated Swift recipe edit' >>"$SOURCE/$FIXTURE_SWIFT_RECIPE"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-unrelated-recipe.log"; then
  fail "compiled SpikeGit accepted an unrelated approved-recipe edit"
fi
grep -Fq 'conflicting, partial, or unrelated' "$FIXTURE/swift-unrelated-recipe.log" ||
  fail "compiled SpikeGit recipe rejection lacked the exact-tree diagnostic"
cp "$FIXTURE/exact-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

printf '%s\n' 'untracked Swift fixture data' >"$SOURCE/swift-untracked.txt"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-untracked.log"; then
  fail "compiled SpikeGit accepted an unknown untracked file"
fi
grep -Fq 'not owned by the approved patch set' "$FIXTURE/swift-untracked.log" ||
  fail "compiled SpikeGit untracked rejection lacked the ownership diagnostic"

echo "PASS: compiled production SpikeGit and target pkg-config isolation, MPVKit-DVFEL pin/dirty-state, FFmpeg/Libmpv capability, exact slices, TLS, and post-fetch artifact contracts"
