// Standalone strict-concurrency contract for complete-set source settlement.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/source-settlement-policy \
//     app/SourcesShared/SourceSettlementPolicy.swift \
//     app/Tests/SourceSettlementPolicyTests.swift && /tmp/source-settlement-policy

import Foundation

@main
enum SourceSettlementPolicyTests {
    static func main() {
        expect(
            SourceSettlementPolicy.decide(
                raw: .pending,
                auxiliary: [.inactive, .inactive, .inactive], deadlineExpired: false
            ) == .waiting,
            "registration window remains pending instead of settling vacuously"
        )
        expect(
            SourceSettlementPolicy.decide(
                raw: .pending,
                auxiliary: [.terminal, .terminal, .inactive], deadlineExpired: false
            ) == .waiting,
            "a late raw contributor keeps the complete set closed"
        )
        expect(
            SourceSettlementPolicy.decide(
                raw: .terminal,
                auxiliary: [.terminal, .pending, .inactive], deadlineExpired: false
            ) == .waiting,
            "a registered auxiliary contributor keeps the complete set closed"
        )
        expect(
            SourceSettlementPolicy.decide(
                raw: .terminal,
                auxiliary: [.terminal, .terminal, .inactive], deadlineExpired: false
            ) == .settledAll,
            "delivered and terminally failed contributors settle together"
        )
        expect(
            SourceSettlementPolicy.decide(
                raw: .pending,
                auxiliary: [.pending, .terminal, .inactive], deadlineExpired: true
            ) == .settledDeadline,
            "the meaningful maximum wait bounds a hung generation"
        )
        expect(
            SourceSettlementPolicy.decide(
                raw: .terminal,
                auxiliary: [.terminal], deadlineExpired: true
            ) == .settledAll,
            "full completion wins even when the deadline fires at the same boundary"
        )
        expect(
            SourceSettlementPolicy.decide(
                raw: .inactive,
                auxiliary: [.terminal, .inactive, .inactive], deadlineExpired: false
            ) == .settledAll,
            "a known auxiliary-only page does not wait for a nonexistent raw contributor"
        )
        expect(
            SourceSettlementPolicy.shouldRearmDeadline(
                previous: .settledAll,
                hasPendingContributor: true,
                deadlineTaskActive: false
            ),
            "a new same-identity retry after full completion receives a fresh bounded deadline"
        )
        expect(
            !SourceSettlementPolicy.shouldRearmDeadline(
                previous: .settledDeadline,
                hasPendingContributor: true,
                deadlineTaskActive: false
            ),
            "an unchanged deadline-settled pending generation cannot restart forever"
        )
        expect(
            !SourceSettlementPolicy.shouldRearmDeadline(
                previous: .settledAll,
                hasPendingContributor: true,
                deadlineTaskActive: true
            ),
            "an already-owned retry deadline is never duplicated"
        )
        expect(
            SourceContributorCompletionOwnership.accepts(
                completedKey: "old", shownKey: "old", inFlightKey: "old", canceled: false
            ),
            "the exact live contributor generation may publish"
        )
        expect(
            !SourceContributorCompletionOwnership.accepts(
                completedKey: "old", shownKey: nil, inFlightKey: nil, canceled: false
            ),
            "clearing a contributor rejects its late completion"
        )
        expect(
            !SourceContributorCompletionOwnership.accepts(
                completedKey: "old", shownKey: "new", inFlightKey: "new", canceled: false
            ),
            "a replacement generation cannot receive the old task's rows"
        )
        expect(
            !SourceContributorCompletionOwnership.accepts(
                completedKey: "old", shownKey: "old", inFlightKey: "old", canceled: true
            ),
            "a canceled exact task cannot publish"
        )
        print("ALL PASS")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL  \(message)\n", stderr)
            exit(1)
        }
        print("PASS  \(message)")
    }
}
