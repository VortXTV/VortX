#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
legacy_recovery_dir=$(mktemp -d "$PWD/app/build/legacy-profile-recovery.XXXXXX")
printf 'Retained legacy recovery artifacts: %s\n' "$legacy_recovery_dir"
legacy_recovery_inputs=(
    scripts/test-legacy-profile-recovery.sh
    app/SourcesShared/LegacyProfileRecoveryPolicy.swift
    app/SourcesShared/LegacyWatchOwnership.swift
    app/SourcesShared/ProfileSync.swift
    app/SourcesShared/Profiles.swift
    app/SourcesShared/ProfilesView.swift
    app/SourcesShared/StremioAccount.swift
    app/Tests/LegacyProfileRecoveryPolicyTests.swift
    app/Tests/LegacyWatchOwnershipTests.swift
    app/Tests/LegacyProfileLifecycleTests.swift
)
shasum -a 256 "${legacy_recovery_inputs[@]}" > "$legacy_recovery_dir/inputs.before.sha256"
legacy_recovery_exit() {
    local terminal_status=$?
    trap - EXIT
    shasum -a 256 "${legacy_recovery_inputs[@]}" > "$legacy_recovery_dir/inputs.after.sha256" || terminal_status=2
    if ! cmp -s "$legacy_recovery_dir/inputs.before.sha256" "$legacy_recovery_dir/inputs.after.sha256"; then
        printf 'FAIL: source inputs changed during verification.\n' >&2
        terminal_status=2
    fi
    printf 'Terminal status %s; retained %s\n' "$terminal_status" "$legacy_recovery_dir"
    exit "$terminal_status"
}
trap legacy_recovery_exit EXIT
# Execute the real roster/selection observers, including Swift array element writeback.
# Only the @Published wrapper is removed; the binding decisions are extracted verbatim.
awk '
  FNR == NR {
    if ($0 ~ /^enum ProfileSelectionRead \{/) { copyingMirror = 1 }
    if (copyingMirror) {
      mirror = mirror $0 "\n"
      if ($0 == "}") copyingMirror = 0
      next
    }
    if ($0 ~ /BEGIN legacy-watch lifecycle projection/) { copying = 1; next }
    if ($0 ~ /END legacy-watch lifecycle projection/) { copying = 0; next }
    if (copying) { line = $0; sub(/@Published /, "", line); projection = projection line "\n" }
    next
  }
  /INSERT ACTUAL PROFILE SELECTION READ/ { printf "%s", mirror; insertedMirror = 1; next }
  /INSERT ACTUAL LEGACY WATCH LIFECYCLE PROJECTION/ { printf "%s", projection; inserted = 1; next }
  { print }
  END { if (mirror == "" || !insertedMirror || projection == "" || !inserted) exit 1 }
' app/SourcesShared/Profiles.swift app/Tests/LegacyProfileLifecycleTests.swift > "$legacy_recovery_dir/Lifecycle.swift"
legacy_compile_status=0
nice -n 15 xcrun swiftc -j 1 -num-threads 1 -whole-module-optimization \
    -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/LegacyProfileRecoveryPolicy.swift app/SourcesShared/LegacyWatchOwnership.swift \
    app/Tests/LegacyProfileRecoveryPolicyTests.swift app/Tests/LegacyWatchOwnershipTests.swift "$legacy_recovery_dir/Lifecycle.swift" \
    -o "$legacy_recovery_dir/recovery-tests" > "$legacy_recovery_dir/compile.log" 2>&1 || legacy_compile_status=$?
if (( legacy_compile_status != 0 )); then
    cat "$legacy_recovery_dir/compile.log"
    exit "$legacy_compile_status"
fi
legacy_run_status=0
nice -n 15 "$legacy_recovery_dir/recovery-tests" "$PWD" > "$legacy_recovery_dir/run.log" 2>&1 || legacy_run_status=$?
cat "$legacy_recovery_dir/run.log"
exit "$legacy_run_status"
