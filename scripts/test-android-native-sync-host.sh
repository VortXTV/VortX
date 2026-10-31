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
  --tests com.vortx.android.integrations.NativeProspectiveProviderTest \
  --tests com.vortx.android.engine.NativeOwnerHistoryJniTest \
  --tests com.vortx.android.engine.NativeOwnerHistoryCompatibilityTest \
  --tests com.vortx.android.engine.NativeRawHostPreferencesTest \
  --no-daemon --max-workers=1 --no-parallel --no-build-cache --no-configuration-cache --stacktrace
# Exact methods, not a stale aggregate count. No executed receipt is written before XML validation.
python3 - <<'PY'
import hashlib, json, os, pathlib, xml.etree.ElementTree as ET
assert os.environ.get("VORTX_JNI_SYNC") == "1", "Real generic JNI cases must be enabled"
assert pathlib.Path(os.environ["VORTX_JNI_LIBRARY"]).is_file(), "Reviewed JNI library is missing"
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
        "real coordinator clears prior provenance before failed direct and typed applies and retirement",
        "generic saved edit retains real GET after sync lease expiry and uploads raw siblings",
        "full pending provider family can reject playlist before any local checkpoint replacement",
        "queued dirty callback cannot hide oversized current host setting from precommit budget",
        "host ABA after capture and before fork commit is rejected by writer revision",
        "provider pending acknowledgement invalidates full record even when selected credential event is unchanged",
        "original absent register observation cannot overwrite a first committed playlist edit",
        "same plaintext checkpoint replacement cannot reuse original encrypted file capability",
        "second authenticated raw read retires old playlist raw identity before a later edit",
        "generic frozen receipt survives fresh GET while rejected candidate and retired lifetime cannot ACK",
        "settings wrapper detaches sets and keeps clear multi key listener and unregister behavior",
    },
    "com.vortx.android.integrations.NativeProspectiveProviderTest": {
        "absent vault observes qualified legacy fallback without initializing secure storage",
        "complete vault witness rejects same encoded replacement and pending only change",
    },
    "com.vortx.android.engine.NativeOwnerHistoryJniTest": {
        "openForkRequestAndQuiescentCloseUseRealPrivateSessionProtocol",
        "javaVerifierExceptionRejectsAndDoesNotRemainPendingOnThread",
        "verifierReentryAndCloseRejectButStatelessCanonicalizerRemainsAvailable",
        "strictUtf8BoundsAndRealCanonicalReceiptAreEnforced",
        "warmSchemaSixReceiveEncryptedColdReopenAndOrdinaryMutationUseRealJni",
    },
    "com.vortx.android.engine.NativeOwnerHistoryCompatibilityTest": {
        "rawUnknownNumbersAndNegativeZeroSurviveOwnedReplacement",
        "strictRawAdmissionRejectsDuplicateUnicodeAndMalformedNumbers",
        "schemaFivePendingCarrierIsLocalOnly",
        "presentationNeverExposesOrNormalizesUnknownRoots",
        "witnessBoundDeltaRetainsExactSourceAndUnknowns",
        "coldNativeNormalizationRetainsOmittedUnknownsAndRejectsKnownOrSourceDrift",
        "warmPeerUnknownSiblingsSurviveNormalizationAndCollisionsRefuseBeforeFork",
        "fullAccountUnknownCarrierDoesNotInheritOverlayNodeBudget",
        "sourceReplayDerivesMovieMembershipAndProgressFromOriginalBytes",
        "removedSourceDoesNotInventMembershipTombstone",
        "sourcePrivacyAndRetirementCannotBecomeReceipt",
        "pendingRecordCannotAcquireNewBindingOnUnion",
        "exactDurableReadbackPrecedesNativeAcceptance",
        "persistenceFailureHasNoNativeAcceptAndPoisonsOwner",
        "staleOriginalReadRefusesBeforePersistence",
        "explicitActionRejectionDoesNotCheckpointOrAcknowledge",
        "failedForkRetirementRemainsStickyAfterCurrentCloseSucceeds",
        "stagedPlaybackProofIsSameTargetAndNeverPublished",
        "keyedCapabilityArmsBeforeMutationAndKeepsOriginalDurableOrder",
        "olderRuntimeGetsNoFormatAndNegotiatedRuntimeMayFallBackToCoarse",
        "malformedRuntimeCapabilitiesAreRejectedAndFailedPersistCannotAcceptKeyed",
        "preparedAccountAdmissionSeesActualCandidateAndCannotRewriteItsOwnedBytes",
        "preparedAccountRejectionAndLateCallbackNeverPersistOrAccept",
        "preparedAccountCallbackCannotMoveToAnotherThreadOrReusePersistence",
        "preparedAccountRetainsOriginalFileAndAuthorityThroughAdmission",
    },
    "com.vortx.android.engine.NativeRawHostPreferencesTest": {
        "ordinary edit preserves original import tokens and unknown local metadata",
        "cold raw capture and checkpoint replacement never use a serialized observation",
        "incoming Lamport winner adopts exact source register and retains local metadata",
        "opaque future numeric spelling keeps conservative format refusal",
        "profile spelling is preserved and canonical aliases reject",
        "opaque imports require original incoming bytes and never become generic DTO edits",
        "unsupported wrapper extension remains rejected and source bytes remain untouched",
        "changed opaque arrays with a lossy baseline reject instead of dropping raw tokens",
        "typed full account preview preserves source archive native and unknown siblings",
        "prepared account full encrypted budget includes pending provider family before callback",
        "supported profile numeric edits accept noncanonical baselines and preserve unknown siblings",
        "schema owned global and integer array edits preserve unrelated raw members",
        "repeated known clock and numeric events retain original spelling including negative zero",
        "controlled rounded projections reach immutable event and opaque mutation refusals",
        "numeric token comparison handles long exponents without arbitrary precision arithmetic",
        "real ForYou prepare changes rating years and createdAt while retaining unknown raw members",
        "real ForYou people add rename and remove preserve original row and metadata slices",
        "ForYou duplicate and reserved identities preserve ambiguity while unrelated append works",
        "ForYou rounded nonintegral and unsupported people identities never authorize edits",
        "ForYou immutable numeric and unique people formatting agrees but exact contradictions refuse",
        "ForYou opaque arrays unsupported containers and altered original people observations refuse",
        "real collection delete and closed Watchlist removal admit explicit tombstones only",
    },
}
# Reviewed source paths for this explicit subset enter real VortxCore bindings and assert native
# output (all BackupRevision cases use Fixture.start; generic cases assert exported schema/state;
# owner-history cases assert actual native protocol replies). Fake gateways/provider-only tests
# remain in the required roster but do not count as real JNI cases. No inference from name prefixes.
jni_required = {
    "com.vortx.android.sync.VortXSyncManagerBackupRevisionTest": set(expected["com.vortx.android.sync.VortXSyncManagerBackupRevisionTest"]),
    "com.vortx.android.sync.NativeAccountSyncTest": {
        "real coordinator clears prior provenance before failed direct and typed applies and retirement",
        "real native library checkpoint retries past retained theme dirty stamp and receives peer after cold restart",
        "real JNI native and host fields sync separately with failed push cold persistence and exact event acknowledgement",
        "real JNI first backup uses zero and collisions or unknown outcomes require authenticated repull",
        "generic saved edit retains real GET after sync lease expiry and uploads raw siblings",
        "full pending provider family can reject playlist before any local checkpoint replacement",
        "queued dirty callback cannot hide oversized current host setting from precommit budget",
        "host ABA after capture and before fork commit is rejected by writer revision",
        "provider pending acknowledgement invalidates full record even when selected credential event is unchanged",
        "original absent register observation cannot overwrite a first committed playlist edit",
        "same plaintext checkpoint replacement cannot reuse original encrypted file capability",
        "second authenticated raw read retires old playlist raw identity before a later edit",
        "generic frozen receipt survives fresh GET while rejected candidate and retired lifetime cannot ACK",
    },
    "com.vortx.android.engine.NativeOwnerHistoryJniTest": set(expected["com.vortx.android.engine.NativeOwnerHistoryJniTest"]),
}
assert all(names <= expected[name] for name, names in jni_required.items())
files = sorted(root.glob("TEST-*.xml"))
assert {p.name for p in files} == {f"TEST-{name}.xml" for name in expected}, "Unexpected/missing JUnit classes"
executed_classes = {}
executed_jni = {}
xml_sha256 = {}
for path in files:
    xml_bytes = path.read_bytes()
    suite = ET.fromstring(xml_bytes)
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
    executed_classes[name] = len(cases)
    executed_jni[name] = sorted({case.attrib["name"] for case in cases} & jni_required.get(name, set()))
    xml_sha256[path.name] = hashlib.sha256(xml_bytes).hexdigest()
result = {
    "testClasses": executed_classes,
    "executed": sum(executed_classes.values()),
    "realJniCases": sum(len(names) for names in executed_jni.values()),
    "realJniCaseNames": executed_jni,
    "junitXmlSha256": xml_sha256,
    "skipped": 0, "failures": 0, "errors": 0,
}
result_path = pathlib.Path("app/build/reports/native-sync-host/host-jni-test-results.json")
result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.write_text(json.dumps(result, sort_keys=True) + "\n")
print(f"Verified exact JUnit XML: {result['executed']} executed, {result['realJniCases']} real-JNI-required cases; zero skips/failures/errors")
PY
verify_inputs
jq --arg after "$(sha256sum "$VORTX_JNI_LIBRARY" | cut -d' ' -f1)" \
  --arg inputs "$(sha256sum "$VORTX_JNI_SOURCE_MANIFEST.current" | cut -d' ' -f1)" \
  --slurpfile tests app/build/reports/native-sync-host/host-jni-test-results.json \
  '. + $tests[0] + {postRuntimeLibrarySha256:$after,postRuntimeSourceInputsSha256:$inputs}' \
  "$VORTX_JNI_RECEIPT" > app/build/reports/native-sync-host/host-jni-accepted.json
