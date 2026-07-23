#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd -P)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

TMP_ROOT="$(mktemp -d)"
DERIVED_DATA="${CREDENTIAL_DERIVED_DATA:-$TMP_ROOT/derived}"
SIMULATOR_UDID=""

cleanup() {
    status="$?"
    trap - EXIT INT TERM
    if [ -n "$SIMULATOR_UDID" ]; then
        xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_ROOT"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${CREDENTIAL_TEST_DESTINATION:-}" ]; then
    DESTINATION="$CREDENTIAL_TEST_DESTINATION"
else
    TVOS_RUNTIME="$(xcrun simctl list runtimes -j | /usr/bin/ruby -rjson -e '
        runtimes = JSON.parse(STDIN.read).fetch("runtimes")
        available = runtimes.select { |runtime| runtime["platform"] == "tvOS" && runtime["isAvailable"] }
        selected = available.max_by { |runtime| runtime.fetch("version", "0").split(".").map(&:to_i) }
        abort "no available tvOS Simulator runtime" unless selected
        puts selected.fetch("identifier")
    ')"
    SIMULATOR_UDID="$(xcrun simctl create \
        "VortX-Credential-Integrity-$$" \
        com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K \
        "$TVOS_RUNTIME")"
    DESTINATION="platform=tvOS Simulator,id=$SIMULATOR_UDID"
fi

echo "credential gate: production wiring and source mutants"
xcrun swiftc \
    -parse-as-library \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$APP_DIR/Tests/DebridCredentialCallerGateTests.swift" \
    -o "$TMP_ROOT/debrid-credential-callers"
(cd "$ROOT_DIR" && "$TMP_ROOT/debrid-credential-callers")

echo "credential gate: durable ordering and crash schedules"
xcrun swiftc \
    -parse-as-library \
    -D DEBRID_LIBRARY_LIVENESS_TEST \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$APP_DIR/SourcesShared/Keychain.swift" \
    "$APP_DIR/SourcesShared/CredentialScope.swift" \
    "$APP_DIR/SourcesShared/DebridCredentialState.swift" \
    "$APP_DIR/SourcesiOS/DebridLibraryView.swift" \
    "$APP_DIR/Tests/DebridCredentialOrderingTests.swift" \
    -o "$TMP_ROOT/debrid-credential-ordering"
"$TMP_ROOT/debrid-credential-ordering"

run_xctest() {
    project="$1"
    derived="$2"
    selector="$3"
    if [ -n "$SIMULATOR_UDID" ]; then
        xcrun simctl terminate "$SIMULATOR_UDID" com.stremiox.tv >/dev/null 2>&1 || true
        xcrun simctl uninstall "$SIMULATOR_UDID" com.stremiox.tv >/dev/null 2>&1 || true
    fi
    xcodebuild \
        -project "$project" \
        -scheme VortXTV \
        -configuration Debug \
        -destination "$DESTINATION" \
        -derivedDataPath "$derived" \
        -only-testing:"$selector" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        test
}

echo "credential gate: production-linked controlled suspension races"
run_xctest \
    "$APP_DIR/VortX.xcodeproj" \
    "$DERIVED_DATA/green" \
    "VortXTests/CredentialOwnerScopingRaceTests"

MUTANT_ROOT="$TMP_ROOT/mutant-repo"
mkdir -p "$MUTANT_ROOT/app"
rsync -a \
    --exclude '/build/' \
    --exclude '/.dd/' \
    "$APP_DIR/" "$MUTANT_ROOT/app/"
cp "$ROOT_DIR/CHANGELOG.md" "$MUTANT_ROOT/CHANGELOG.md"

mutate_exactly_once() {
    mutant="$1"
    /usr/bin/ruby - "$MUTANT_ROOT/app" "$mutant" <<'RUBY'
app, mutant = ARGV
case mutant
when "m1"
  path = File.join(app, "SourcesShared/CredentialScope.swift")
  old = "        guard isCurrent(stamp) else { return nil }\n        return try mutation()"
  replacement = "        let result = try mutation()\n        guard isCurrent(stamp) else { return nil }\n        return result"
when "m2"
  path = File.join(app, "SourcesShared/CredentialScope.swift")
  old = "        guard isCurrent(stamp) else { return nil }\n        return try mutation()"
  replacement = "        _ = stamp\n        return try mutation()"
when "m3"
  path = File.join(app, "SourcesShared/TraktAuth.swift")
  old = "            CredentialScopeAuthority.shared.commitIfCurrent(stamp) {\n                mutation(stamp.scope.scope)"
  replacement = "            CredentialScopeAuthority.shared.commitIfCurrent(\n                CredentialScopeAuthority.shared.commitStamp()\n            ) {\n                mutation(stamp.scope.scope)"
when "m68"
  path = File.join(app, "SourcesShared/DebridResolver.swift")
  old = [
    "        let current = credentialStore.compareAndInstall(revision: snapshot.revision) {",
    "            guard revisionFence.accept(snapshot) else { return }",
    "            resolvers = nextResolvers",
    "            torboxUsenet = nextTorBoxUsenet",
    "            appliedSnapshot = snapshot",
    "            installed = true",
    "        }",
  ].join("\n")
  replacement = [
    "        let current = true",
    "        if revisionFence.accept(snapshot) {",
    "            resolvers = nextResolvers",
    "            torboxUsenet = nextTorBoxUsenet",
    "            appliedSnapshot = snapshot",
    "            installed = true",
    "        }",
  ].join("\n")
else
  abort "unknown mutant #{mutant}"
end

source = File.binread(path)
count = source.scan(old).length
abort "#{mutant}: expected one mutation target in #{path}, found #{count}" unless count == 1
File.binwrite(path, source.sub(old, replacement))
RUBY
}

run_killed_mutant() {
    mutant="$1"
    relative_path="$2"
    test_name="$3"
    target="$MUTANT_ROOT/app/$relative_path"
    backup="$TMP_ROOT/$mutant.backup"
    log="$TMP_ROOT/$mutant.log"
    cp "$target" "$backup"
    mutate_exactly_once "$mutant"

    set +e
    set -o pipefail
    run_xctest \
        "$MUTANT_ROOT/app/VortX.xcodeproj" \
        "$DERIVED_DATA/$mutant" \
        "VortXTests/CredentialOwnerScopingRaceTests/$test_name" \
        2>&1 | tee "$log"
    status="$?"
    set -e
    cp "$backup" "$target"

    if [ "$status" -eq 0 ]; then
        echo "ERROR: $mutant survived its production-linked race" >&2
        exit 1
    fi
    if grep -Fq "The following build commands failed" "$log"; then
        echo "ERROR: $mutant caused a build failure instead of a race assertion failure" >&2
        exit 1
    fi
    if ! grep -Fq "CredentialOwnerScopingRaceTests.$test_name()" "$log"; then
        echo "ERROR: $mutant failed without naming its expected race test" >&2
        exit 1
    fi
    if ! grep -Fq "** TEST FAILED **" "$log"; then
        echo "ERROR: $mutant did not produce the required test-red receipt" >&2
        exit 1
    fi
    echo "KILLED $mutant by $test_name"
}

echo "credential gate: runtime mutants must turn the real races red"
run_killed_mutant \
    m1 \
    SourcesShared/CredentialScope.swift \
    testTraktInjectedCommitSuspensionRejectsAAfterOwnerB
run_killed_mutant \
    m2 \
    SourcesShared/CredentialScope.swift \
    testTraktInjectedCommitSuspensionRejectsAAfterOwnerB
run_killed_mutant \
    m3 \
    SourcesShared/TraktAuth.swift \
    testTraktInjectedCommitSuspensionRejectsAAfterOwnerB
run_killed_mutant \
    m68 \
    SourcesShared/DebridResolver.swift \
    testCoordinatorPendingAIsAnnulledWhenBPublishes

echo "ALL CREDENTIAL INTEGRITY GATES PASSED"
