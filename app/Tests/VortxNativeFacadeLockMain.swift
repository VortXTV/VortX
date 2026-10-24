import Foundation
import Darwin
import XCTest

@main enum VortxNativeFacadeLockMain {
    @MainActor static func main() {
        let cases: [(XCTestCase.Type, [String])] = [
            (VortxNativeFIFOAdmissionTests.self, [
                "testPrecedingIntentRetiresReadEvenAfterItSettles", "testBusyQueueCannotCaptureAReplacementRead",
                "testOneOriginalReadTransitionsToOnlyItsRunningMember", "testLaterEnqueuesDoNotRevokeTheEarlierRunningSource",
                "testTwoCapturesCannotBothBeAdmittedFromTheSameHead", "testOrdinaryMembersRetainFIFOOrderWithoutLatestWins",
                "testCancellationBeforeAdmissionInstallsNothing", "testQueuedCancellationPreservesLaterIntent",
                "testRunningCancellationAndActualIdentityChangeRetireAuthority", "testOriginalSourceIsNotReplacedByAValidQueue",
                "testRevokedSourceRejectsBeforeInstallation", "testCloseAndUncertaintyNeverReactivateAnAdmittedRead",
                "testWrongQueueCannotConsumeOrScheduleAnotherQueuesCapability",
                "testPostInstallationAuthorityFailureDoesNotCreateSecondCompletionOwner"
            ]),
            (VortxNativeFacadeLockTests.self, [
                "testStandaloneAndEmptyTransactionsReturnSynchronously",
                "testActualPublishWaitsForOutermostCommonLockAndNestedFIFO",
                "testActualPublishSuppressesEmptyUnchangedStaleAndClosed",
                "testActualPublishSortsFieldsAndPublishesBeforeCallback",
                "testThrowingNestedTransactionsDrainFIFOAfterUnlock",
                "testCapturedDeliveryDestructionHappensOutsideFacadeLock",
                "testReadAdmissionUsesSameRecursiveBoundaryAndPreservesMemberOrder",
                "testCallbackCanReenterPublishAndAdmitFIFO",
                "testSynchronousNotificationCompletesBeforeProducerReturn"
            ])
        ]
        var executed = 0
        for (type, names) in cases {
            let suite = XCTestSuite(forTestCaseClass: type)
            guard suite.testCaseCount == names.count,
                  names.allSatisfy({ name in suite.tests.filter { $0.name.contains(name) }.count == 1 }) else {
                print("FAIL facade lock/FIFO XCTest discovery"); exit(91)
            }
            suite.run()
            guard let run = suite.testRun, run.hasSucceeded, run.executionCount == names.count,
                  run.skipCount == 0, run.totalFailureCount == 0 else {
                print("FAIL facade lock/FIFO XCTest execution"); exit(1)
            }
            executed += run.executionCount
        }
        print("PASS actual FIFO and lock/publication worker XCTest cases: \(executed)")
    }
}
