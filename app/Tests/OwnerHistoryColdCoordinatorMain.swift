import Foundation
import XCTest
import Darwin

/// Real Darwin XCTest discovery for the actual cold admission helpers. This does not
/// substitute a native validator, transaction authority or cold-mount integration.
@main enum OwnerHistoryColdCoordinatorMain {
    @MainActor static func main() {
        let names = [
            "testExplicitCarrierSelectorRetainsOpaqueBytes",
            "testCarrierRejectsMissingMalformedAndWrongScopeSelector",
            "testColdRosterIsExactAuthenticatedNativeProjection",
            "testColdRejectsNonownerAndDifferentOpaqueSelector",
            "testColdRejectsMissingDeletedAndMismatchedOwner",
            "testColdDoesNotPromoteLegacySchemaOrInventHistory",
            "testStoredOwnerSelectorSurvivesChildOwnSelection",
            "testWarmOwnerFallbackAndOpaqueMismatch",
            "testFullAccountUnknownNumbersStayRaw",
            "testPendingLegacyCarrierRemainsLocalWithoutSchemaPromotion"
        ]
        let suite = XCTestSuite(forTestCaseClass: OwnerHistoryColdCoordinatorTests.self)
        guard suite.testCaseCount == names.count,
              names.allSatisfy({ name in suite.tests.filter { $0.name.contains(name) }.count == 1 }) else {
            print("FAIL cold coordinator XCTest discovery mismatch"); exit(91)
        }
        suite.run()
        guard let run = suite.testRun, run.hasSucceeded, run.executionCount == names.count,
              run.skipCount == 0, run.totalFailureCount == 0 else {
            print("FAIL cold coordinator XCTest execution or assertion"); exit(1)
        }
        print("PASS actual cold coordinator admission XCTest cases: 10")
    }
}
