import Foundation

/// Compile with the actual production Policy and the Token declaration extracted verbatim from
/// RandomPickPlayIntent.swift. The injected authorization callback is a fixture, not a substitute
/// for native owner/composition checks. This suite exercises the production source witness itself.
@main
@MainActor
private enum PlaybackTitleQueueSourceAdmissionTests {
    private static var assertions = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        if !condition() { fatalError(label) }
    }

    static func main() {
        guard let candidate = PlaybackTitleQueuePolicy.Candidate(contentID: "tt1", type: "series",
                title: "Series", videoIDHint: "tt1:1:2") else { fatalError("fixture") }
        var state = PlaybackTitleQueuePolicy()
        let entryID = UUID()
        _ = state.enqueue(candidate, placement: .last, id: entryID)
        guard let ticket = state.nextTicket() else { fatalError("ticket") }
        var ownerIsCurrent = true
        var routeIsCurrent = true
        var authorizationCalls = 0
        let token = PlaybackTitleQueueToken(ticketID: ticket.id, entryID: ticket.entryID,
            revision: ticket.revision, contentID: candidate.contentID, type: candidate.type,
            videoIDHint: candidate.videoIDHint) { contentID, videoID, type in
                authorizationCalls += 1
                return ownerIsCurrent && routeIsCurrent && state.accepts(ticket)
                    && contentID == "tt1" && videoID == "tt1:1:2" && type == "series"
            }

        expect(!token.sourceAdmitted, "constructing a route is not source admission")
        expect(token.routingToken(contentID: "tt1", videoID: "tt1:1:2", type: "series") === token,
               "matching manual navigation preserves the exact original capability")
        expect(token.routingToken(contentID: "tt1", videoID: "tt1:1:3", type: "series") == nil,
               "another explicit episode detaches the exact-episode queue")
        expect(token.routingToken(contentID: "tt2", videoID: "tt1:1:2", type: "series") == nil,
               "unrelated title detaches the queue")
        expect(authorizationCalls == 0 && !token.sourceAdmitted,
               "routing identity filter neither calls live authorizer nor grants source")
        expect(!token.admitResolvedSource(contentID: "tt2", videoID: "tt1:1:2", type: "series"), "unrelated title denied")
        expect(!token.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:3", type: "series"), "unrelated exact episode denied")
        expect(!token.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:2", type: "movie"), "unrelated media type denied")
        expect(!token.sourceAdmitted && state.upcoming.first?.id == entryID, "manual failed admission retains stable head")
        ownerIsCurrent = false
        expect(token.routingToken(contentID: "tt1", videoID: "tt1:1:2", type: "series") === token,
               "matching stale capability stays attached instead of falling back to ordinary admission")
        expect(!token.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:2", type: "series"), "changed original owner denied")
        ownerIsCurrent = true
        routeIsCurrent = false
        expect(!token.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:2", type: "series"), "removed/replaced route denied")
        routeIsCurrent = true
        // A manual source/quality handoff does not depend on the now-retired automatic intent.
        expect(token.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:2", type: "series"), "current explicit resolved source admitted")
        expect(token.sourceAdmitted, "explicit source opens the exact original witness")
        expect(state.active == nil && state.upcoming.first?.id == entryID, "source acceptance still does not consume queue")
        expect(state.acceptStarted(ticket), "existing accepted first-frame stage consumes once")
        expect(!state.acceptStarted(ticket), "repeated frame cannot consume another entry")
        expect(!token.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:2", type: "series"), "old route cannot issue a second source after first-frame admission")
        expect(state.active?.entry.id == entryID, "healthy active entry retains stable identity")
        expect(authorizationCalls == 7, "every explicit source attempt consults its captured authorizer")

        var reordered = PlaybackTitleQueuePolicy()
        let first = UUID(), second = UUID()
        _ = reordered.enqueue(candidate, placement: .last, id: first)
        _ = reordered.enqueue(candidate, placement: .last, id: second)
        guard let old = reordered.nextTicket() else { fatalError("old") }
        let stale = PlaybackTitleQueueToken(ticketID: old.id, entryID: old.entryID,
            revision: old.revision, contentID: candidate.contentID, type: candidate.type,
            videoIDHint: candidate.videoIDHint) { _, _, _ in reordered.accepts(old) }
        _ = reordered.move(first, by: 1)
        _ = reordered.move(first, by: -1)
        expect(reordered.upcoming.first?.id == first, "same head restored after order ABA")
        expect(!stale.admitResolvedSource(contentID: "tt1", videoID: "tt1:1:2", type: "series"), "manual source cannot bypass reordered ticket revision")
        expect(!stale.sourceAdmitted, "denied ABA source never gains witness")
        print("PlaybackTitleQueueSourceAdmission: \(assertions) assertions passed")
    }
}
