import Foundation

/// Compile with the actual production policy only. No engine/source resolver is reimplemented here.
@main
@MainActor
private enum PlaybackTitleQueuePolicyTests {
    private static var assertions = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        if !condition() { fatalError(label) }
    }

    private static func movie(_ id: String = "tt1") -> PlaybackTitleQueuePolicy.Candidate {
        guard let candidate = PlaybackTitleQueuePolicy.Candidate(contentID: id, type: "movie", title: "Movie \(id)") else {
            fatalError("invalid fixture")
        }
        return candidate
    }

    static func main() {
        validation()
        orderingAndIdentity()
        boundedAdmission()
        playlistBatchImport()
        staleTickets()
        failureAndRetry()
        finishingAndManualSkip()
        print("PlaybackTitleQueuePolicy: 7 groups, \(assertions) assertions passed")
    }

    private static func validation() {
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "", type: "movie", title: "Title") == nil, "empty ID")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "a\n", type: "movie", title: "Title") == nil, "control character")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "a", type: "live", title: "Title") == nil, "live is not finite queue media")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "a", type: "movie", title: " \t") == nil, "empty title")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: String(repeating: "a", count: 1_025), type: "movie", title: "Title") == nil, "ID byte budget")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "a", type: "movie", title: String(repeating: "é", count: 257)) == nil, "UTF8 title budget")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "a", type: "movie", title: "Title", videoIDHint: "different") == nil, "movie cannot carry unrelated video")
        expect(PlaybackTitleQueuePolicy.Candidate(contentID: "kitsu:42", type: "series", title: "Series", videoIDHint: "kitsu:42:1:2", episodeLabel: "S1E2") != nil, "provider ID and exact episode survive")
    }

    private static func orderingAndIdentity() {
        var state = PlaybackTitleQueuePolicy()
        let first = UUID(), second = UUID(), next = UUID()
        expect(state.enqueue(movie("a"), placement: .last, id: first), "append first")
        expect(state.enqueue(movie("b"), placement: .last, id: second), "append second")
        expect(state.enqueue(movie("a"), placement: .next, id: next), "repeat content allowed, distinct entry")
        expect(state.upcoming.map(\.id) == [next, first, second], "play next is head insertion")
        expect(state.move(second, by: -1), "move stable UUID")
        expect(state.upcoming.map(\.id) == [next, second, first], "reordered identities")
        expect(!state.move(next, by: -1), "head move bounded")
        expect(!state.move(first, by: 1), "tail move bounded")
        expect(!state.move(first, by: Int.max), "arbitrary displacement rejected before addition")
        expect(state.remove(second), "remove exact entry")
        expect(state.upcoming.map(\.id) == [next, first], "duplicate content not removed together")
        expect(!state.remove(second), "repeat removal harmless")
        expect(!state.enqueue(movie("c"), placement: .last, id: first), "duplicate entry UUID rejected")
    }

    private static func boundedAdmission() {
        var state = PlaybackTitleQueuePolicy()
        for index in 0..<PlaybackTitleQueuePolicy.capacity {
            expect(state.enqueue(movie("\(index)"), placement: .last), "within bounded queue")
        }
        expect(state.count == 100, "capacity reached")
        expect(!state.enqueue(movie("overflow"), placement: .next), "overflow rejected")
        guard let ticket = state.nextTicket() else { fatalError("missing ticket") }
        expect(state.acceptStarted(ticket), "accepted first frame consumes head")
        expect(state.count == 100 && state.upcoming.count == 99, "active entry still consumes capacity")
        expect(!state.enqueue(movie("overflow"), placement: .last), "active entry does not create hidden extra capacity")
        expect(state.nextTicket() == nil, "cannot admit a second simultaneous queue player")
        state.clearUpcoming()
        expect(state.count == 1 && state.active?.ticket == ticket, "clear upcoming preserves current playback")
    }

    private static func playlistBatchImport() {
        var ordered = PlaybackTitleQueuePolicy()
        let existing = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        expect(ordered.enqueue(movie("existing"), placement: .last, id: existing), "seed batch order")
        var generated = [first, second][...]
        expect(ordered.appendCandidates([movie("first"), movie("first")], makeID: {
            generated.removeFirst()
        }), "batch accepted")
        expect(ordered.upcoming.map(\.id) == [existing, first, second], "batch order and duplicates preserved")
        expect(ordered.upcoming.map(\.candidate.contentID) == ["existing", "first", "first"],
               "batch catalog candidates stay aligned")

        var nearCapacity = PlaybackTitleQueuePolicy()
        for index in 0..<(PlaybackTitleQueuePolicy.capacity - 1) {
            expect(nearCapacity.enqueue(movie("capacity-\(index)"), placement: .last), "seed capacity")
        }
        let beforeCapacityIDs = nearCapacity.upcoming.map(\.id)
        var capacityFactoryCalls = 0
        expect(!nearCapacity.appendCandidates([movie("overflow-a"), movie("overflow-b")], makeID: {
            capacityFactoryCalls += 1
            return UUID()
        }), "over-capacity batch rejected")
        expect(capacityFactoryCalls == 0, "capacity rejected before fresh ID generation")
        expect(nearCapacity.upcoming.map(\.id) == beforeCapacityIDs, "capacity rejection is all-or-nothing")

        var collision = PlaybackTitleQueuePolicy()
        expect(collision.enqueue(movie("kept"), placement: .last, id: existing), "seed collision")
        let beforeCollision = collision.upcoming
        expect(!collision.appendCandidates([movie("rejected")], makeID: { existing }),
               "generated identity collision rejected")
        expect(collision.upcoming == beforeCollision, "identity rejection is all-or-nothing")

        var active = PlaybackTitleQueuePolicy()
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let pendingID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let addedID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        expect(active.enqueue(movie("active"), placement: .last, id: activeID), "seed active")
        expect(active.enqueue(movie("pending"), placement: .last, id: pendingID), "seed pending")
        guard let ticket = active.nextTicket() else { fatalError("missing batch active ticket") }
        expect(active.acceptStarted(ticket), "establish active item")
        let originalActive = active.active
        expect(active.appendCandidates([movie("added")], makeID: { addedID }),
               "batch appends around active item")
        expect(active.active == originalActive, "active entry and ticket ownership preserved")
        expect(active.upcoming.map(\.id) == [pendingID, addedID], "batch appends after existing pending order")
        expect(active.count == 3, "active item remains inside capacity accounting")
    }

    private static func staleTickets() {
        var state = PlaybackTitleQueuePolicy()
        let a = UUID(), b = UUID()
        _ = state.enqueue(movie("a"), placement: .last, id: a)
        _ = state.enqueue(movie("b"), placement: .last, id: b)
        guard let original = state.nextTicket() else { fatalError("missing original") }
        expect(state.move(a, by: 1) && state.move(a, by: -1), "A B A order restored")
        expect(state.upcoming.first?.id == original.entryID, "same head after ABA")
        expect(!state.acceptStarted(original), "revision rejects A B A source result")
        guard let removed = state.nextTicket() else { fatalError("missing removal ticket") }
        expect(state.remove(a), "remove old head")
        expect(!state.acceptStarted(removed), "removed source result cannot consume replacement")
        guard let accepted = state.nextTicket() else { fatalError("missing accepted ticket") }
        expect(state.acceptStarted(accepted), "current receipt admitted")
        expect(!state.acceptStarted(accepted), "duplicate accepted frame cannot consume two rows")
        expect(!state.finish(original.id), "outgoing old EOF cannot finish current entry")
    }

    private static func failureAndRetry() {
        var state = PlaybackTitleQueuePolicy()
        let id = UUID()
        _ = state.enqueue(movie(), placement: .last, id: id)
        guard let attempted = state.nextTicket() else { fatalError("missing attempt") }
        // A failed resolver/player/premature EOF calls no acceptStarted or finish method.
        expect(state.upcoming.first?.id == id && state.active == nil, "failed start retains pending item")
        expect(state.accepts(attempted), "same current source attempt remains admissible")
        expect(state.acceptStarted(attempted), "healthy first frame accepted")
        expect(state.active?.entry.id == id, "runtime error/close retains current item without advancing")
        expect(state.retryActive(), "explicit retry returns current item to head")
        expect(state.upcoming.first?.id == id && state.active == nil, "stable entry survives retry")
        expect(!state.acceptStarted(attempted), "old frame is stale after retry")
        guard let retry = state.nextTicket() else { fatalError("missing retry") }
        expect(retry.id != attempted.id && state.acceptStarted(retry), "retry has fresh player receipt")
    }

    private static func finishingAndManualSkip() {
        var state = PlaybackTitleQueuePolicy()
        let a = UUID(), b = UUID()
        _ = state.enqueue(movie("a"), placement: .last, id: a)
        _ = state.enqueue(movie("b"), placement: .last, id: b)
        guard let first = state.nextTicket() else { fatalError("missing first") }
        expect(state.acceptStarted(first), "first admitted")
        expect(state.finish(first.id), "caller-proven completion/manual skip retires only current identity")
        expect(!state.finish(first.id), "duplicate EOF is idempotently denied")
        expect(state.upcoming.first?.id == b && state.active == nil, "successor remains pending until it plays")
        guard let second = state.nextTicket() else { fatalError("missing second") }
        expect(state.acceptStarted(second), "second admitted independently")
        expect(state.finish(second.id), "last completion accepted")
        expect(state.count == 0 && state.nextTicket() == nil, "queue ends instead of inventing a successor")
    }
}
