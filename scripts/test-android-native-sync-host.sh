#!/usr/bin/env bash
set -euo pipefail
verify_inputs() {
  (cd "$GITHUB_WORKSPACE" &&
    find vortx-core \( -path vortx-core/target -o -path vortx-core/target-andx \) -prune -o \
      -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$VORTX_JNI_SOURCE_MANIFEST.current") || return 1
  cmp --silent "$VORTX_JNI_SOURCE_MANIFEST" "$VORTX_JNI_SOURCE_MANIFEST.current" || return 1
  test "$(sha256sum "$VORTX_JNI_LIBRARY" | cut -d' ' -f1)" = "$VORTX_JNI_EXPECTED_SHA256"
}
finish() {
  result=$?
  trap - EXIT
  if ! verify_inputs; then exit 1; fi
  exit "$result"
}
trap finish EXIT
verify_inputs
test ! -e app/build/test-results/testPlayDebugUnitTest
nice -n 15 ./gradlew :app:testPlayDebugUnitTest \
  -Pkotlin.compiler.execution.strategy=in-process \
  --init-script native-sync-hosted.init.gradle \
  --tests com.vortx.android.sync.VortXSyncManagerBackupRevisionTest \
  --tests com.vortx.android.sync.NativeAccountSyncTest \
  --no-daemon --max-workers=1 --no-parallel --no-build-cache --no-configuration-cache --stacktrace
# Independently prove the retained XML contains all 22 current tests and no assumptions.
python3 - <<'PY'
import pathlib, xml.etree.ElementTree as ET
root = pathlib.Path("app/build/test-results/testPlayDebugUnitTest")
expected = {
    "com.vortx.android.sync.VortXSyncManagerBackupRevisionTest": {
        "stale prepared peer cannot overwrite winner and fresh merged base survives cold reopen",
        "rejected winner echo cannot relabel a candidate derived from a different fresh base",
        "stale GET retries never promote stale payload and retain pending until fresh merge",
        "failed rebuild keeps pending intent and never blindly resends stale candidate",
        "invalid pull revisions cannot apply upload or acknowledge local intent",
        "largest safe base is readable but cannot overflow into a push or pending ACK",
        "account replacement during recovery cannot send or acknowledge under new lease",
        "native authenticated absence creates at zero with null witness",
        "native absent row race remerges the winning seed before next proposal",
        "lost accepted native response preserves intent and fresh retry merges intervening winner",
        "native upgrade required stops retries without acknowledging or stamping success",
        "same account reauthentication while PUT waits cannot acknowledge retired lease",
        "retired native installation cannot acknowledge a candidate accepted during remount",
        "ACKed provider-only rollback arms durable repair and restores cold peer without native differences",
    },
    "com.vortx.android.sync.NativeAccountSyncTest": {
        "missing failed malformed and undecryptable account pulls never seed or upload native state",
        "native push preserves adjacent authenticated fields and excludes device selection",
        "native pull preflights exact overlay number tokens before org json rounding",
        "unsupported host settings remain dirty while native push may read its merge base",
        "real native library checkpoint retries past retained theme dirty stamp and receives peer after cold restart",
        "real JNI native and host fields sync separately with failed push cold persistence and exact event acknowledgement",
        "real JNI first backup uses zero and collisions or unknown outcomes require authenticated repull",
        "native provider clear is uploaded and acknowledged but edit during PUT remains pending",
    },
}
files = sorted(root.glob("TEST-*.xml"))
assert {p.name for p in files} == {f"TEST-{name}.xml" for name in expected}, "Unexpected/missing JUnit classes"
for path in files:
    suite = ET.parse(path).getroot()
    name = suite.attrib["name"]
    assert path.name == f"TEST-{name}.xml", "JUnit suite identity differs from its retained filename"
    count = len(expected[name])
    cases = suite.findall("testcase")
    assert suite.tag == "testsuite" and int(suite.attrib["tests"]) == count == len(cases)
    assert all(int(suite.attrib[key]) == 0 for key in ("failures", "errors", "skipped"))
    assert int(suite.attrib.get("disabled", "0")) == 0
    assert {case.attrib["name"] for case in cases} == expected[name]
    assert all(case.attrib["classname"] == name and case.attrib.get("status", "run") == "run" for case in cases)
    assert not any(element.tag in ("failure", "error", "skipped", "disabled") for element in suite.iter())
print("Verified retained real JNI results: BackupRevision14 + NativeAccountSync8; zero skips/failures/errors")
PY
verify_inputs
jq --arg after "$(sha256sum "$VORTX_JNI_LIBRARY" | cut -d' ' -f1)" \
  --arg inputs "$(sha256sum "$VORTX_JNI_SOURCE_MANIFEST.current" | cut -d' ' -f1)" \
  '. + {postRuntimeLibrarySha256:$after,postRuntimeSourceInputsSha256:$inputs,
    testClasses:{"com.vortx.android.sync.VortXSyncManagerBackupRevisionTest":14,
      "com.vortx.android.sync.NativeAccountSyncTest":8},
    executed:22,realJniCases:17,skipped:0,failures:0,errors:0}' \
  "$VORTX_JNI_RECEIPT" > app/build/reports/native-sync-host/host-jni-accepted.json
