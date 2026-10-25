// Appended VERBATIM to the same generated file as the exact private production
// frame owner/types/comparators. All code in this recovery packet is UNRUN.
// Real Combine + complete CoreModels; no source receipt/Facade/Session is mocked.
extension CoreBridge {
    @MainActor static func runGuardedMetadataCases(
        old: CoreMetaDetails, next: CoreMetaDetails,
        check: @MainActor (Bool, String) -> Void
    ) throws {
        @MainActor func publish(_ owner: MetadataPresentation, _ value: CoreMetaDetails?,
                                status: StreamAddonStatusProjection? = nil) -> Bool {
            owner.commitFrame(details: value, status: status,
                expectedProposal: owner.proposal.metadata, isCurrent: { true },
                trustedStore: { store in store(); return true })
        }
        @MainActor func counter(_ owner: MetadataPresentation) -> Bool {
            owner.advanceStreamsEpoch(expectedProposal: owner.proposal.streams,
                isCurrent: { true }, trustedStore: { store in store(); return true })
        }
        let differentSources = CoreMetaDetails(selected: next.selected, metaItems: next.metaItems,
            streams: [], metaStreams: [], libraryItem: next.libraryItem,
            watchedVideoIds: next.watchedVideoIds)
        check(old != next && !Self.metaDetailsStreamsChanged(current: old, next: next)
              && Self.metaDetailsStreamsChanged(current: old, next: differentSources),
              "frame case inputs distinguish metadata-only A from a source-changing B")

        do {
            let missingID: VortxJSON = .object(["action": .string("Load"), "args": .object([
                "model": .string("MetaDetails"), "args": .object(["metaPath": .object(["type": .string("series")])])])])
            let valid: VortxJSON = .object(["action": .string("Load"), "args": .object([
                "model": .string("MetaDetails"), "args": .object(["metaPath": .object(["id": .string("synthetic-title")])])])])
            check(!Self.nativeMetadataNavigationIsValid(missingID)
                  && Self.nativeMetadataNavigationIsValid(valid)
                  && Self.nativeMetadataNavigationIsValid(.object(["action": .string("Unload")])),
                  "actual pure validator rejects missing metaPath.id and retains valid Load/Unload")
            // Separate real08 source contract proves no hook/host/M/clear mutation
            // before this guard and retains invalid_meta_path logging.
        }
        do {
            let signal = ObservableObjectPublisher()
            let owner = MetadataPresentation(objectWillChange: signal)
            _ = publish(owner, old)
            let before = owner.streamsEpoch
            var fired = false, nestedAccepted = false, observedCoherent = true
            var epochs: [Int] = [], metadata: [CoreMetaDetails?] = []
            let epochSub = owner.streamsEpochPublisher.dropFirst().sink { epochs.append($0) }
            let metaSub = owner.metaDetailsPublisher.dropFirst().sink {
                metadata.append($0)
                observedCoherent = observedCoherent && owner.streamsEpoch == before + 1
            }
            let willSub = signal.sink {
                guard !fired else { return }; fired = true
                nestedAccepted = counter(owner)
            }
            let accepted = publish(owner, next)
            willSub.cancel(); metaSub.cancel(); epochSub.cancel()
            check(fired && nestedAccepted && accepted && owner.metaDetails == next
                  && owner.streamsEpoch == before + 1 && metadata == [next]
                  && epochs == [before + 1] && observedCoherent,
                  "actual frame: willChange counter-only B is merged and does not veto valid metadata A")
        }
        do {
            let signal = ObservableObjectPublisher()
            let owner = MetadataPresentation(objectWillChange: signal)
            _ = publish(owner, old)
            let before = owner.streamsEpoch
            var fired = false, nestedAccepted = false
            var metadata: [CoreMetaDetails?] = []
            let metaSub = owner.metaDetailsPublisher.dropFirst().sink { metadata.append($0) }
            let willSub = signal.sink {
                guard !fired else { return }; fired = true
                nestedAccepted = publish(owner, differentSources)
            }
            let accepted = publish(owner, next)
            willSub.cancel(); metaSub.cancel()
            check(fired && nestedAccepted && !accepted && owner.metaDetails == differentSources
                  && metadata == [differentSources] && owner.streamsEpoch == before + 1,
                  "actual frame: willChange newer metadata B vetoes A before the plain backing swap")
        }
        do {
            let owner = MetadataPresentation(objectWillChange: ObservableObjectPublisher())
            _ = publish(owner, old)
            let before = owner.streamsEpoch
            var fired = false, nestedAccepted = false
            var epochs: [Int] = [], metadata: [CoreMetaDetails?] = []
            let epochSub = owner.streamsEpochPublisher.dropFirst().sink { epochs.append($0) }
            let metaSub = owner.metaDetailsPublisher.dropFirst().sink {
                metadata.append($0)
                guard $0 == next, !fired else { return }; fired = true
                nestedAccepted = counter(owner)
            }
            let accepted = publish(owner, next)
            metaSub.cancel(); epochSub.cancel()
            check(fired && nestedAccepted && accepted && owner.metaDetails == next
                  && owner.streamsEpoch == before + 1 && metadata == [next]
                  && epochs == [before + 1],
                  "actual frame: postcommit counter reentry keeps valid metadata A tail and does not duplicate metadata")
        }
        do {
            let owner = MetadataPresentation(objectWillChange: ObservableObjectPublisher())
            _ = publish(owner, old)
            var first: [CoreMetaDetails?] = [], second: [CoreMetaDetails?] = []
            var fired = false, nestedAccepted = false
            @MainActor func nested(_ value: CoreMetaDetails?) {
                guard value == next, !fired else { return }; fired = true
                nestedAccepted = publish(owner, differentSources)
            }
            let a = owner.metaDetailsPublisher.dropFirst().sink { first.append($0); nested($0) }
            let b = owner.metaDetailsPublisher.dropFirst().sink { second.append($0); nested($0) }
            let accepted = publish(owner, next)
            a.cancel(); b.cancel()
            // No CurrentValueSubject subscriber iteration order is assumed.
            check(fired && nestedAccepted && !accepted && owner.metaDetails == differentSources
                  && first.last == differentSources && second.last == differentSources
                  && (first + second).filter({ $0 == next }).count == 1,
                  "actual frame: per-subscriber emission filter suppresses resumed A after nested metadata B")
        }
        do {
            let owner = MetadataPresentation(objectWillChange: ObservableObjectPublisher())
            _ = publish(owner, old)
            let original = owner.proposal.metadata
            _ = publish(owner, next); _ = publish(owner, old)
            let accepted = owner.commitFrame(details: differentSources, status: nil,
                expectedProposal: original, isCurrent: { true },
                trustedStore: { store in store(); return true })
            check(!accepted && owner.metaDetails == old,
                  "actual frame: value A-to-B-to-A does not revive original metadata proposal")
        }
        do {
            let signal = ObservableObjectPublisher()
            let owner = MetadataPresentation(objectWillChange: signal)
            _ = publish(owner, old)
            let before = owner.streamsEpoch, originalStreams = owner.proposal.streams
            var gates = 0, wakes = 0
            var metadata: [CoreMetaDetails?] = [], epochs: [Int] = []
            let willSub = signal.sink { wakes += 1 }
            let metaSub = owner.metaDetailsPublisher.dropFirst().sink { metadata.append($0) }
            let epochSub = owner.streamsEpochPublisher.dropFirst().sink { epochs.append($0) }
            // Refusal drives the REAL owner seam but is not a Facade/source receipt.
            // The separate real01c source contract establishes the actual F gate.
            let rejected = owner.commitFrame(details: differentSources, status: nil,
                expectedProposal: owner.proposal.metadata, isCurrent: { true },
                trustedStore: { _ in gates += 1; return false })
            let rejectedQuiet = !rejected && gates == 1 && wakes == 1
                && owner.metaDetails == old && owner.streamsEpoch == before
                && owner.proposal.streams == originalStreams && metadata.isEmpty && epochs.isEmpty
            let acceptedB = publish(owner, differentSources)
            willSub.cancel(); metaSub.cancel(); epochSub.cancel()
            check(rejectedQuiet && acceptedB && owner.metaDetails == differentSources
                  && owner.streamsEpoch == before + 1 && metadata == [differentSources]
                  && epochs == [before + 1],
                  "actual frame seam: final-store refusal publishes no payload/counter; later equal candidate B commits once (not real F runtime)")
        }
        do {
            let owner = MetadataPresentation(objectWillChange: ObservableObjectPublisher())
            _ = publish(owner, old)
            let before = owner.streamsEpoch
            var originalCurrent = true, deferredB = false, coherent = true
            var epochs: [Int] = [], metadata: [CoreMetaDetails?] = []
            let epochSub = owner.streamsEpochPublisher.dropFirst().sink { epochs.append($0) }
            let metaSub = owner.metaDetailsPublisher.dropFirst().sink {
                metadata.append($0)
                guard $0 == differentSources, !deferredB else { return }
                coherent = coherent && owner.streamsEpoch == before + 1
                originalCurrent = false; deferredB = true
            }
            let acceptedA = owner.commitFrame(details: differentSources, status: nil,
                expectedProposal: owner.proposal.metadata, isCurrent: { originalCurrent },
                trustedStore: { store in store(); return true })
            // A has already atomically stored metadata AND epoch before fanout.
            // B is deliberately delivered later with IDENTICAL decoded details.
            let acceptedB = publish(owner, differentSources)
            metaSub.cancel(); epochSub.cancel()
            check(deferredB && coherent && !acceptedA && acceptedB
                  && owner.metaDetails == differentSources && owner.streamsEpoch == before + 1
                  && metadata == [differentSources] && epochs == [before + 1],
                  "actual frame: postfanout retirement plus deferred typed-equal B retains one coherent source-epoch event (local current flag, not source runtime)")
        }
        do {
            let owner = MetadataPresentation(objectWillChange: ObservableObjectPublisher())
            let projection = StreamAddonStatusProjection(selected: old.selected, rows: [])
            _ = publish(owner, old, status: projection)
            let before = owner.streamsEpoch, clear = owner.beginClear()
            var nilMetadataSawCoherentFrame = false, epochs: [Int] = [], statusChanges = 0
            let metaSub = owner.metaDetailsPublisher.dropFirst().sink {
                if $0 == nil {
                    nilMetadataSawCoherentFrame = owner.acceptedStatus == nil
                        && owner.streamsEpoch == before + 1 && owner.ownsClear(clear)
                }
            }
            let epochSub = owner.streamsEpochPublisher.dropFirst().sink { epochs.append($0) }
            let statusSub = owner.statusPublisher.dropFirst().sink { _ in statusChanges += 1 }
            let accepted = owner.clear(bumpStreams: true, preservingClear: clear,
                expectedProposal: owner.proposal.metadata, isCurrent: { true },
                trustedStore: { store in store(); return true })
            metaSub.cancel(); epochSub.cancel(); statusSub.cancel()
            check(accepted && nilMetadataSawCoherentFrame && owner.metaDetails == nil
                  && owner.acceptedStatus == nil && epochs == [before + 1] && statusChanges == 1,
                  "actual frame: nil metadata/status/epoch and clear identity are coherent before every value fanout")
            // The original nil PHASE continuation is a separate actual08 source
            // contract. This does not construct or execute a fake metadata phase.
        }
        do {
            let owner = MetadataPresentation(objectWillChange: ObservableObjectPublisher())
            let projection = StreamAddonStatusProjection(selected: old.selected, rows: [])
            _ = publish(owner, old, status: projection)
            let before = owner.streamsEpoch
            let overlay = CoreMetaDetails(selected: old.selected, metaItems: old.metaItems,
                streams: old.streams, metaStreams: old.metaStreams, libraryItem: old.libraryItem,
                watchedVideoIds: ["frame-overlay-watch"])
            var epochs: [Int] = [], statusChanges = 0
            let epochSub = owner.streamsEpochPublisher.dropFirst().sink { epochs.append($0) }
            let statusSub = owner.statusPublisher.dropFirst().sink { _ in statusChanges += 1 }
            let accepted = owner.commitOverlay(overlay, expectedProposal: owner.proposal.metadata,
                isCurrent: { true }, trustedStore: { store in store(); return true })
            let equal = owner.commitOverlay(overlay, expectedProposal: owner.proposal.metadata,
                isCurrent: { true }, trustedStore: { store in store(); return true })
            epochSub.cancel(); statusSub.cancel()
            check(accepted && equal && owner.metaDetails == overlay && owner.streamsEpoch == before
                  && owner.acceptedStatus == projection && epochs.isEmpty && statusChanges == 0,
                  "actual frame: library/watch overlay preserves source epoch and paired status; equal overlay stays quiet")
        }
        do {
            // Only the clone's class name and ONE post-willChange veto differ.
            // The positive production owner/types above are extracted unchanged.
            let signal = ObservableObjectPublisher()
            let owner = UnfencedMetadataPresentation(objectWillChange: signal)
            _ = owner.commitFrame(details: old, status: nil,
                expectedProposal: owner.proposal.metadata, isCurrent: { true },
                trustedStore: { store in store(); return true })
            var fired = false
            let sub = signal.sink {
                guard !fired else { return }; fired = true
                _ = owner.commitFrame(details: differentSources, status: nil,
                    expectedProposal: owner.proposal.metadata, isCurrent: { true },
                    trustedStore: { store in store(); return true })
            }
            _ = owner.commitFrame(details: next, status: nil,
                expectedProposal: owner.proposal.metadata, isCurrent: { true },
                trustedStore: { store in store(); return true })
            sub.cancel()
            check(fired && owner.metaDetails == next,
                  "negative control: removing only post-willChange veto reproduces A backing overwrite after B")
        }
    }
}
