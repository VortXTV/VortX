import Foundation
import XCTest
import Darwin

/// Real Darwin XCTest discovery/execution, following the existing FIFO fixture entry point.
/// No native/store/authority or parser algorithm is substituted. All cases remain UNRUN here.
@main enum OwnerHistorySnapshotConservationMain {
    @MainActor static func main() {
        let names = [
            "testSignedZeroAndLargeIntegerTokensNeverBecomeFoundationNumbers",
            "testStructuralCanonicalComparisonKeepsNumbersButIgnoresKeyOrdering",
            "testMalformedAndDuplicateKeysFailClosed",
            "testDeltaRestoresExactSourceAndPreservesUnknownHostSibling",
            "testAbsentNativeDeltaPreservesCompleteNativeDocument",
            "testForeignWitnessParentAndInjectedOwnerHistoryReject",
            "testColdNativeCheckpointCannotEraseUnrelatedHostFields",
            "testColdPeerNormalizationRetainsOmittedUnknownNativeBytes",
            "testColdPeerNormalizationRejectsKnownSourceAndReturnedUnknownChanges",
            "testOmittedUnknownNativeSiblingsRetainOriginalRawTokensAndSource",
            "testKnownSerdeOptionalsClearOnOmissionAndDoNotResurrect",
            "testExplicitRawUnknownNativeUpsertRetainsOtherUnknownFields",
            "testColdReplacementPreservesUnknownNativeAndHostButReplacesExactSource",
            "testColdReplacementMayRemoveKnownSourceWithoutErasingUnknownNative",
            "testRepeatedRawReadsDoNotRewriteSnapshotNativeOrSourceBytes",
            "testExistingProfileAndLibraryUpsertsRetainUnmentionedRows",
            "testUnsupportedRootChangesMalformedNativeAndSourceInjectionStillReject"
        ]
        let suite = XCTestSuite(forTestCaseClass: OwnerHistoryExactJSONAuthoredTests.self)
        guard suite.testCaseCount == names.count,
              names.allSatisfy({ name in suite.tests.filter { $0.name.contains(name) }.count == 1 }) else {
            print("FAIL Snapshot XCTest discovery mismatch"); exit(91)
        }
        suite.run()
        guard let run = suite.testRun, run.hasSucceeded, run.executionCount == names.count,
              run.skipCount == 0, run.totalFailureCount == 0 else {
            print("FAIL Snapshot XCTest execution or assertion"); exit(1)
        }
        print("PASS actual raw Snapshot XCTest cases: 17 (7 original + 10 conservation)")
    }
}
