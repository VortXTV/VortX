import Foundation

/// Compile only with the production PlaybackTitleQueuePolicy and PlaybackTitleQueueArchiveCodec sources.
/// This is a pure codec/policy regression receipt: it performs no disk, account, engine, or network work.
@main
@MainActor
private enum PlaybackTitleQueueDurabilityTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        if !condition() { fatalError(label) }
    }

    private static func expectFailure(_ expected: PlaybackTitleQueueArchiveCodec.Failure,
                                      _ data: Data, _ label: String) {
        assertions += 1
        do {
            _ = try PlaybackTitleQueueArchiveCodec.decode(data)
            fatalError("\(label): unexpectedly decoded")
        } catch let failure as PlaybackTitleQueueArchiveCodec.Failure {
            if failure != expected { fatalError("\(label): \(failure) != \(expected)") }
        } catch {
            fatalError("\(label): wrong error \(error)")
        }
    }

    private static func expectRejected(_ data: Data, _ label: String) {
        assertions += 1
        do {
            _ = try PlaybackTitleQueueArchiveCodec.decode(data)
            fatalError("\(label): unexpectedly decoded")
        } catch is PlaybackTitleQueueArchiveCodec.Failure {
            return
        } catch {
            fatalError("\(label): wrong error \(error)")
        }
    }

    private static func candidate(_ contentID: String, type: String = "movie",
                                  videoID: String? = nil) -> PlaybackTitleQueuePolicy.Candidate {
        guard let value = PlaybackTitleQueuePolicy.Candidate(
            contentID: contentID,
            type: type,
            title: "Title \(contentID)",
            videoIDHint: videoID,
            episodeLabel: videoID == nil ? nil : "S1 E2"
        ) else { fatalError("invalid fixture") }
        return value
    }

    static func main() throws {
        try canonicalSanitizedRoundTrip()
        canonicalRejection()
        invalidAndBoundedRejection()
        try coldActiveRestoresPendingAtHead()
        try transactionalMutationDoesNotPublishEarly()
        try escapedArchiveOverflowRejectsWholeEdit()
        try ownedEOFFailureKeepsActive()
        projectedPayloadDoesNotConsumeWriteSlot()
        print("PlaybackTitleQueueDurability: 8 groups, \(assertions) assertions passed")
    }

    private static func canonicalSanitizedRoundTrip() throws {
        let firstID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let entries: [PlaybackTitleQueuePolicy.Entry] = [
            .init(id: firstID, candidate: candidate("tt100")),
            .init(id: secondID, candidate: candidate("kitsu:42", type: "series", videoID: "kitsu:42:1:2"))
        ]
        let encoded = try PlaybackTitleQueueArchiveCodec.encode(entries)
        let encodedAgain = try PlaybackTitleQueueArchiveCodec.encode(entries)
        expect(encoded == encodedAgain, "writer is byte deterministic")
        let decoded = try PlaybackTitleQueueArchiveCodec.decode(encoded)
        expect(decoded == entries, "canonical round trip retains stable entry/catalog identity")

        guard let root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let rows = root["entries"] as? [[String: Any]] else { fatalError("shape") }
        expect(Set(root.keys) == Set(["entries", "schema"]), "top-level has only schema and entries")
        let allowed = Set(["entryID", "contentID", "type", "title", "videoIDHint", "episodeLabel"])
        expect(rows.allSatisfy { Set($0.keys).isSubset(of: allowed) },
               "rows contain only sanitized catalog/display fields")
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["url", "header", "lease", "profile", "pin", "email", "token",
                          "credential", "accountGeneration", "ticket", "revision"] {
            expect(!text.lowercased().contains(forbidden.lowercased()),
                   "archive omits \(forbidden)")
        }
        let empty = try PlaybackTitleQueueArchiveCodec.encode([])
        expect(empty == Data(#"{"entries":[],"schema":1}"#.utf8),
               "empty archive has one canonical spelling")
    }

    private static func canonicalRejection() {
        expectFailure(.invalidShape,
            Data(#" {"entries":[],"schema":1}"#.utf8),
            "leading whitespace is noncanonical")
        expectFailure(.invalidShape,
            Data(#"{"entries":[],"owner":"not-allowed","schema":1}"#.utf8),
            "unknown field rejected")
        expectRejected(Data(#"{"entries":[],"entries":[],"schema":1}"#.utf8),
                       "duplicate JSON key rejected")
        expectFailure(.unsupportedSchema,
            Data(#"{"entries":[],"schema":2}"#.utf8),
            "future schema rejected")
        expectFailure(.malformed, Data(#"{"entries":"#.utf8), "truncated JSON rejected")
    }

    private static func invalidAndBoundedRejection() {
        let invalidUUID = Data(
            #"{"entries":[{"contentID":"tt1","entryID":"not-a-uuid","title":"Title","type":"movie"}],"schema":1}"#.utf8
        )
        expectFailure(.invalidEntry, invalidUUID, "invalid stable UUID rejected")

        let id = "11111111-1111-4111-8111-111111111111"
        let row = #"{"contentID":"tt1","entryID":"\#(id)","title":"Title","type":"movie"}"#
        expectFailure(.duplicateEntry,
            Data(#"{"entries":[\#(row),\#(row)],"schema":1}"#.utf8),
            "duplicate stable entry rejected")
        expectFailure(.invalidEntry,
            Data(#"{"entries":[{"contentID":"tt1","entryID":"\#(id)","title":"Title","type":"live"}],"schema":1}"#.utf8),
            "invalid catalog type rejected")
        expectFailure(.oversized,
            Data(repeating: 0x20, count: PlaybackTitleQueueArchiveCodec.maximumBytes + 1),
            "oversized bytes rejected before parsing")

        let tooMany = (0...PlaybackTitleQueuePolicy.capacity).map { index in
            PlaybackTitleQueuePolicy.Entry(id: UUID(), candidate: candidate("tt\(index)"))
        }
        assertions += 1
        do {
            _ = try PlaybackTitleQueueArchiveCodec.encode(tooMany)
            fatalError("capacity overflow encoded")
        } catch let failure as PlaybackTitleQueueArchiveCodec.Failure {
            expect(failure == .tooManyEntries, "encoder rejects 101 entries")
        } catch {
            fatalError("wrong capacity error")
        }
    }

    private static func coldActiveRestoresPendingAtHead() throws {
        var original = PlaybackTitleQueuePolicy()
        let first = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let second = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        expect(original.enqueue(candidate("ttA"), placement: .last, id: first), "enqueue active fixture")
        expect(original.enqueue(candidate("ttB"), placement: .last, id: second), "enqueue upcoming fixture")
        guard let oldTicket = original.nextTicket() else { fatalError("old ticket") }
        expect(original.acceptStarted(oldTicket), "make first entry active")
        expect(original.durableEntries.map(\.id) == [first, second],
               "durable order places active before upcoming")

        let bytes = try PlaybackTitleQueueArchiveCodec.encode(original.durableEntries)
        let text = String(decoding: bytes, as: UTF8.self)
        expect(!text.contains(oldTicket.id.uuidString.lowercased()), "ticket authority is not persisted")
        expect(!text.contains(oldTicket.revision.uuidString.lowercased()), "policy revision is not persisted")

        let decoded = try PlaybackTitleQueueArchiveCodec.decode(bytes)
        var restored = PlaybackTitleQueuePolicy()
        expect(restored.restorePending(decoded), "cold snapshot installs into pristine state")
        expect(restored.active == nil, "old active entry becomes pending")
        expect(restored.upcoming.map(\.id) == [first, second], "stable active entry returns at head")
        guard let fresh = restored.nextTicket() else { fatalError("fresh ticket") }
        expect(fresh.entryID == first, "fresh route still targets restored head")
        expect(fresh.id != oldTicket.id && fresh.revision != oldTicket.revision,
               "cold restore mints fresh ticket/revision authority")

        var edited = PlaybackTitleQueuePolicy()
        _ = edited.enqueue(candidate("ttLocal"), placement: .last)
        expect(!edited.restorePending(decoded), "late restore cannot overwrite an in-memory edit")
    }

    private static func transactionalMutationDoesNotPublishEarly() throws {
        var current = PlaybackTitleQueuePolicy()
        let retained = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let added = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        expect(current.enqueue(candidate("tt-retained"), placement: .last, id: retained),
               "transaction fixture enqueued")
        let before = current.durableEntries

        let result = PlaybackTitleQueueMutationTransaction.prepare(current: current) {
            $0.enqueue(candidate("tt-added"), placement: .last, id: added)
        }
        guard case .prepared(let prepared) = result else {
            fatalError("valid transaction was not prepared")
        }
        expect(current.durableEntries == before,
               "pre-encoded transaction leaves live policy unchanged before admission")
        expect(prepared.policy.durableEntries.map(\.id) == [retained, added],
               "prepared transaction contains the complete staged policy")
        let decoded = try PlaybackTitleQueueArchiveCodec.decode(prepared.payload)
        expect(decoded == prepared.policy.durableEntries,
               "prepared immutable payload exactly represents staged policy")
    }

    private static func escapedArchiveOverflowRejectsWholeEdit() throws {
        func escapedCandidate(_ index: Int) -> PlaybackTitleQueuePolicy.Candidate {
            let prefix = String(format: "%03d", index)
            guard let value = PlaybackTitleQueuePolicy.Candidate(
                contentID: prefix + String(repeating: "\\", count: 1_021),
                type: "series",
                title: String(repeating: "\"", count: 512),
                videoIDHint: String(repeating: "\\\"", count: 512),
                episodeLabel: String(repeating: "\"", count: 512)
            ) else { fatalError("escaped fixture invalid") }
            return value
        }

        var accepted = PlaybackTitleQueuePolicy()
        var sawOversizedRejection = false
        for index in 0..<PlaybackTitleQueuePolicy.capacity {
            let stableID = UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012d", index + 1
            ))!
            let beforeEntries = accepted.durableEntries
            let beforeBytes = try PlaybackTitleQueueArchiveCodec.encode(beforeEntries)
            switch PlaybackTitleQueueMutationTransaction.prepare(current: accepted, mutation: {
                $0.enqueue(escapedCandidate(index), placement: .last, id: stableID)
            }) {
            case .prepared(let prepared):
                accepted = prepared.policy
                let decoded = try PlaybackTitleQueueArchiveCodec.decode(prepared.payload)
                expect(decoded == prepared.policy.durableEntries,
                       "accepted escaped edit has one exact canonical payload")
            case .rejected(.oversized):
                sawOversizedRejection = true
                expect(accepted.durableEntries == beforeEntries,
                       "oversized valid edit preserves the previously accepted policy")
                let afterBytes = try PlaybackTitleQueueArchiveCodec.encode(accepted.durableEntries)
                expect(afterBytes == beforeBytes,
                       "oversized valid edit preserves the previous durable bytes")
            case .rejected(let failure):
                fatalError("unexpected escaped transaction rejection: \(failure)")
            case .unchanged:
                fatalError("escaped transaction unexpectedly unchanged")
            }
            if sawOversizedRejection { break }
        }
        expect(sawOversizedRejection,
               "valid escaped fields exceed the byte budget before the 100-entry count limit")
    }

    private static func ownedEOFFailureKeepsActive() throws {
        var current = PlaybackTitleQueuePolicy()
        let activeID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let nextID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        expect(current.enqueue(candidate("tt-active"), placement: .last, id: activeID),
               "owned EOF fixture active entry enqueued")
        expect(current.enqueue(candidate("tt-next"), placement: .last, id: nextID),
               "owned EOF fixture next entry enqueued")
        guard let ticket = current.nextTicket(
            id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        ) else { fatalError("owned EOF fixture ticket") }
        expect(current.acceptStarted(ticket), "owned EOF fixture started")

        let stale = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        switch PlaybackTitleQueueMutationTransaction.prepare(current: current, mutation: {
            $0.finish(stale)
        }) {
        case .unchanged:
            break
        case .prepared(_), .rejected(_):
            fatalError("wrong ticket must not prepare a finish")
        }
        expect(current.active?.ticket == ticket,
               "wrong-ticket finish leaves the exact active item owned")
        expect(PlaybackTitleQueueOwnedEOFPolicy.decide(
            exactActiveOwned: false, durabilityCanAdmit: true
        ) == .notOwned, "unowned EOF is not claimed")
        expect(PlaybackTitleQueueOwnedEOFPolicy.decide(
            exactActiveOwned: true, durabilityCanAdmit: false
        ) == .claimWithoutMutation,
        "owned EOF remains claimed when durability has failed")
        expect(current.active?.ticket == ticket && current.upcoming.map(\.id) == [nextID],
               "failed durable admission neither finishes nor advances the active item")

        let exact = PlaybackTitleQueueMutationTransaction.prepare(current: current) {
            $0.finish(ticket.id)
        }
        guard case .prepared(let prepared) = exact else {
            fatalError("exact owned finish was not prepared")
        }
        expect(current.active?.ticket == ticket,
               "even an encodable exact finish stays staged until admission")
        expect(prepared.policy.active == nil && prepared.policy.upcoming.map(\.id) == [nextID],
               "admittable exact finish advances only in the staged policy")
        expect(PlaybackTitleQueueOwnedEOFPolicy.decide(
            exactActiveOwned: true, durabilityCanAdmit: true
        ) == .stageDurableFinish, "owned EOF stages a finish only when durability can admit it")
        let decoded = try PlaybackTitleQueueArchiveCodec.decode(prepared.payload)
        expect(decoded == prepared.policy.durableEntries,
               "owned finish payload matches the staged post-finish queue")
    }
    private static func projectedPayloadDoesNotConsumeWriteSlot() {
        typealias Gate = PlaybackTitleQueueWriteAdmissionPolicy
        expect(Gate.decide(payloadMatchesProjected: false, payloadMatchesCertified: false,
                           partitionPending: 31, totalPending: 31, capacity: 32) == .appendWrite,
               "a changed finish may consume the final slot")
        expect(Gate.decide(payloadMatchesProjected: true, payloadMatchesCertified: false,
                           partitionPending: 32, totalPending: 32, capacity: 32) == .reusePending(32),
               "the subsequent identical start preserves pending state without consuming another slot")
        expect(Gate.decide(payloadMatchesProjected: true, payloadMatchesCertified: true,
                           partitionPending: 3, totalPending: 32, capacity: 32) == .reusePending(3),
               "projected equality never marks existing pending writes saved")
        expect(Gate.decide(payloadMatchesProjected: false, payloadMatchesCertified: true,
                           partitionPending: 32, totalPending: 32, capacity: 32) == .reject,
               "certified predecessor is not authority for a different projected payload")
        expect(Gate.decide(payloadMatchesProjected: true, payloadMatchesCertified: true,
                           partitionPending: 0, totalPending: 32, capacity: 32) == .reuseSaved,
               "an identical already-certified local partition does not borrow another owner's slots")
        expect(Gate.decide(payloadMatchesProjected: true, payloadMatchesCertified: false,
                           partitionPending: 0, totalPending: 0, capacity: 32) == .reject,
               "missing certification with no pending write cannot be called saved")
        expect(Gate.decide(payloadMatchesProjected: false, payloadMatchesCertified: false,
                           partitionPending: 2, totalPending: 1, capacity: 32) == .reject,
               "impossible pending counters fail closed")
    }

}
