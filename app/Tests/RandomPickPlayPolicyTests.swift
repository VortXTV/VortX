import Foundation

enum RandomPickPlayPolicyTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func run() {
        var open = RandomPickPlayPolicy()
        expect(open.claim(enabled: false, current: true) == nil, "Open does not claim playback")
        expect(open.state == .pending, "disabled default does not secretly consume")

        var play = RandomPickPlayPolicy()
        let claim = play.claim(enabled: true, current: true)!
        expect(play.claim(enabled: true, current: true) == nil, "one resolver only")
        expect(!play.accepts(UUID(), current: true), "foreign completion cannot borrow authority")
        expect(play.accepts(claim, current: true), "current resolver may continue")
        expect(play.consume(claim, current: true), "one actual final handoff")
        expect(!play.consume(claim, current: true), "duplicate final handoff blocked")
        play.revoke()
        expect(play.state == .consumed, "page disappears after handoff without tearing down player")
        expect(play.claim(enabled: true, current: true) == nil, "view reappearance cannot replay consumed request")

        for reason in ["profile A-B-A", "PIN/Kids roster", "picker", "credential epoch", "metadata coordinates",
                       "source generation", "manual source", "route pop", "Pick again", "source filter"] {
            var pending = RandomPickPlayPolicy()
            let pendingClaim = pending.claim(enabled: true, current: true)!
            expect(!pending.accepts(pendingClaim, current: false), reason + " rejects pending resolver")
            expect(!pending.accepts(pendingClaim, current: true), reason + " stays revoked after values revert")
            expect(!pending.consume(pendingClaim, current: true), reason + " rejects late final handoff")
            expect(pending.claim(enabled: true, current: true) == nil, reason + " cannot re-arm")
        }
        var finalBoundary = RandomPickPlayPolicy()
        let beforeAwait = finalBoundary.claim(enabled: true, current: true)!
        expect(!finalBoundary.consume(beforeAwait, current: false), "final boundary independently checks authority")
        expect(finalBoundary.state == .revoked, "failed final handoff is terminal")
        var manual = RandomPickPlayPolicy()
        manual.revoke()
        expect(manual.claim(enabled: true, current: true) == nil, "manual action before sources settle wins")
        var staleBeforeClaim = RandomPickPlayPolicy()
        expect(staleBeforeClaim.claim(enabled: true, current: false) == nil, "stale before resolve rejected")
        expect(staleBeforeClaim.state == .revoked, "stale initial access cannot later recover authority")
        print("RandomPickPlayPolicy PASS: explicit Open/Play, one-shot, async/final fences, terminal cancellation and admitted player preservation")
    }
}
