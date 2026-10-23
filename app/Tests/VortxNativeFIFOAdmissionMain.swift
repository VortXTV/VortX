import Foundation
import XCTest
import Darwin

/// Real XCTest discovery/execution of the production FIFO primitive. No app, native ABI,
/// Session, account, checkpoint or network is substituted into this ownership-only lane.
@main enum VortxNativeFIFOAdmissionMain {
    @MainActor static func main() {
        let names = [
            "testPrecedingIntentRetiresReadEvenAfterItSettles",
            "testBusyQueueCannotCaptureAReplacementRead",
            "testOneOriginalReadTransitionsToOnlyItsRunningMember",
            "testLaterEnqueuesDoNotRevokeTheEarlierRunningSource",
            "testTwoCapturesCannotBothBeAdmittedFromTheSameHead",
            "testOrdinaryMembersRetainFIFOOrderWithoutLatestWins",
            "testCancellationBeforeAdmissionInstallsNothing",
            "testQueuedCancellationPreservesLaterIntent",
            "testRunningCancellationAndActualIdentityChangeRetireAuthority",
            "testOriginalSourceIsNotReplacedByAValidQueue",
            "testRevokedSourceRejectsBeforeInstallation",
            "testCloseAndUncertaintyNeverReactivateAnAdmittedRead",
            "testWrongQueueCannotConsumeOrScheduleAnotherQueuesCapability",
            "testPostInstallationAuthorityFailureDoesNotCreateSecondCompletionOwner"
        ]
        let suite = XCTestSuite(forTestCaseClass: VortxNativeFIFOAdmissionTests.self)
        guard suite.testCaseCount == names.count,
              names.allSatisfy({ name in suite.tests.filter { $0.name.contains(name) }.count == 1 }) else {
            print("FAIL FIFO XCTest discovery mismatch"); exit(91)
        }
        suite.run()
        guard let run = suite.testRun, run.hasSucceeded, run.executionCount == names.count,
              run.skipCount == 0, run.totalFailureCount == 0 else {
            print("FAIL FIFO XCTest execution or assertion"); exit(1)
        }
        print("PASS actual FIFO admission XCTest cases: 14")
    }
}
