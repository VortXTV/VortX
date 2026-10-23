import Foundation
import XCTest
import Darwin

@main struct DefaultsVerificationMain {
    @MainActor static func main() {
        guard Bundle.main.object(forInfoDictionaryKey: "VortXEdgeSecret") == nil else { exit(90) }
        let original = XCTestSuite(forTestCaseClass: CurationDefaultsTests.self)
        let client = XCTestSuite(forTestCaseClass: CurationDefaultsClientTests.self)
        let originalNames = [
            "testValidEnvelopeProjectsExactPublicFolders", "testDecoderRejectsDuplicateAndUnsafePublicWire",
            "testUnknownEnvelopeEntryAndBaseFieldsRemainRaw", "testEndpointRequiresFixedHTTPSCatalogsOriginAndOwnPath",
            "testHealthySameScopeFlightSurvivesPreCancelledJoiner", "testLateAScopeCannotPublishAcrossBAndBackToA",
            "testStopCancelsNonCooperatingResultWithoutPublishing", "testFreshCacheAvoidsFetchAndTransientStaleRetainsLastGood",
            "testRetryWindowSuppressesRepeatAndHTTPAuthFailuresClearLastGood", "testMaximumStaleAgeAndClockRollbackUseFallback"
        ]
        let clientNames = [
            "testActualClientSignsAndUsesBoundedInjectedTransport", "testActualClientRejectsWholeEnvelopeAndDoesNotTruncate",
            "testActualClientMapsHTTPAndTransportFailures", "testActualTransportEnforcesStreamingCapAndRedirectRejection",
            "testStaleBeforeStampAndDuringStampNeverSends", "testStaleAfterResponseCannotPublish",
            "testActualTransportCallerCancellation"
        ]
        for (suite, expected) in [(original, originalNames), (client, clientNames)] {
            let names = suite.tests.map(\.name)
            guard suite.testCaseCount == expected.count,
                  expected.allSatisfy({ method in names.filter { $0.contains(method) }.count == 1 }) else {
                print("FAIL XCTest discovery mismatch"); exit(91)
            }
            suite.run()
            guard let run = suite.testRun, run.hasSucceeded, run.executionCount == expected.count,
                  run.skipCount == 0, run.totalFailureCount == 0 else {
                print("FAIL XCTest execution or assertion"); exit(1)
            }
        }
        print("PASS actual defaults XCTest checks: 17 (10 original + 7 client)")
    }
}
