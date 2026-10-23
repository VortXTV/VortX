// PRIVATE — separately selectable PURE cleanup assay. UNCOMPILED / UNRUN.
// This does not rewrite or execute a negative version of the extracted production helper.
import Foundation

enum PureStaleCleanupControl {
    private struct Failure: Error { let message: String }

    // The result line is the entire disclosed mutation between these two pure functions.
    private static func corrected(_ currentAttempt: UUID?, finishingAttempt: UUID) -> UUID? {
        return currentAttempt == finishingAttempt ? nil : currentAttempt
    }

    private static func unconditional(_ currentAttempt: UUID?, finishingAttempt: UUID) -> UUID? {
        return nil
    }

    static func run(useUnconditionalCleanup: Bool) throws {
        let retiredAttempt = UUID()
        let successorAttempt = UUID()
        precondition(retiredAttempt != successorAttempt)
        let afterOwnCompletion = useUnconditionalCleanup
            ? unconditional(retiredAttempt, finishingAttempt: retiredAttempt)
            : corrected(retiredAttempt, finishingAttempt: retiredAttempt)
        guard afterOwnCompletion == nil else { throw Failure(message: "own slot did not clear") }
        let afterStaleCompletion = useUnconditionalCleanup
            ? unconditional(successorAttempt, finishingAttempt: retiredAttempt)
            : corrected(successorAttempt, finishingAttempt: retiredAttempt)
        guard afterStaleCompletion == successorAttempt else {
            throw Failure(message: "pure stale cleanup erased successor; expected negative-control failure")
        }
    }
}
