// PRIVATE — append AFTER the WHOLE pinned model in ONE file, only under a later root allocation.
// This is fixture-only private access, not a production body change. UNCOMPILED / UNRUN.
extension WatchStatsModel {
    private struct FixtureFailure: Error, CustomStringConvertible { let description: String }

    private static func fixtureRequire(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw FixtureFailure(description: message) }
    }

    private static func fixtureContext(owner: Bool, uid: String? = "fixture-owner-a")
        -> (WatchStatsModel, UserProfile, UserProfile) {
        let a = UserProfile(id: UUID(), isOwner: owner, usesOwnAccount: false)
        let b = UserProfile(id: UUID(), isOwner: owner, usesOwnAccount: false)
        let profiles = ProfileStore.shared
        profiles.fixtureRoster([a, b])
        profiles.fixtureSelect(a.id)
        profiles.activeKeychainAccount = "fixture-account"
        profiles.watch = [:]
        CredentialScopeRegistry.shared.fixtureRebind()
        let core = CoreBridge.shared
        core.fixtureUID = uid
        core.library = nil
        core.continueWatching = []
        core.boardRows = []
        core.discover = nil
        core.searchResults = []
        core.metaDetails = nil
        return (WatchStatsModel(), a, b)
    }

    private static func fixtureRecords(_ years: [Int], prefix: String) -> [WatchRecord] {
        years.map { year in
            WatchRecord(id: "\(prefix)-\(year)", type: "movie", name: "\(prefix)-\(year)", poster: nil,
                        watchSeconds: 60, plays: 1,
                        lastWatched: WatchStats.parseISODate("\(year)-06-01T00:00:00Z"))
        }
    }

    private static func fixtureOverlay(_ years: [Int]) {
        ProfileStore.shared.watch = Dictionary(uniqueKeysWithValues: years.map { year in
            ("tt-overlay-\(year)", WatchEntry(name: "Overlay \(year)", durationMs: (year - 2021) * 60_000,
                                            lastWatched: "\(year)-06-01T00:00:00Z"))
        })
    }

    // CONTROLLED COMPLETION BOUNDARY: load captures the real original request, but its queued
    // owner Task is cancelled before entry. The unchanged finishLoad/abandon methods are then driven
    // synchronously. This does NOT stand in for the utility worker or a post-await guard receipt.
    private func fixtureBoundaryRequest() -> LoadRequest {
        load()
        precondition(activeRequest != nil && libraryTask != nil)
        let request = activeRequest!
        libraryTask?.cancel()
        libraryTask = nil
        return request
    }

    // CONTROLLED DRAIN-CALLBACK BOUNDARY: these two statements are the literal callback operations.
    // The original queued GCD callback is NOT consumed by this seam. Synchronous boundary cases do
    // not yield; their models/subscriptions are released before callbacks can run. Flag assertions
    // concern the unchanged drain's logical remainder admission, NOT physical GCD callback count.
    private func fixtureDrainCallbackBoundary() {
        publicationScheduled = false
        drainPublications()
    }

    private static func fixtureNeutralGetters(_ model: WatchStatsModel) -> Bool {
        let stats = model.stats
        let years = model.availableYears
        let loading = model.isLoading
        let selection = model.selectedYear
        return stats == nil && years.isEmpty && !loading && selection == nil
    }

    private static func fixtureOriginalAuthorityBoundaries() throws {
        for variant in 0..<4 {
            let (model, a, b) = fixtureContext(owner: true, uid: variant == 3 ? nil : "fixture-owner-a")
            let original = model.fixtureBoundaryRequest()
            if variant == 0 {
                ProfileStore.shared.fixtureSelect(b.id)
                ProfileStore.shared.fixtureSelect(a.id)
                try fixtureRequire(ProfileStore.shared.activeID == original.authority.profileID
                    && CoreBridge.shared.currentUID() == original.authority.expectedUID,
                    "ABA must restore profile and UID payload")
                try fixtureRequire(!LegacyWatchOwnership.applicationEpochIsCurrent(original.authority.epoch),
                                   "ABA must retire original real epoch")
            } else if variant == 1 {
                CredentialScopeRegistry.shared.fixtureRebind()
            } else {
                CoreBridge.shared.fixtureUID = variant == 2 ? nil : "fixture-owner-b"
            }
            model.finishLoad(fixtureRecords([2022], prefix: "obsolete"), request: original)
            model.fixtureDrainCallbackBoundary()
            try fixtureRequire(model.records.isEmpty && model.cachedAuthority == nil
                && model.activeRequest == nil && model.stats == nil && !model.isLoading,
                "obsolete original authority accepted")
        }
    }

    private static func fixtureSameOwnerReversedBoundary() throws {
        let (model, _, _) = fixtureContext(owner: true)
        let older = model.fixtureBoundaryRequest()
        let newer = model.fixtureBoundaryRequest()
        try fixtureRequire(older.generation != newer.generation
            && older.authority.epoch == newer.authority.epoch, "same-owner distinct request setup")
        model.selectedYear = 2024
        model.finishLoad(fixtureRecords([2024], prefix: "newer"), request: newer)
        model.finishLoad(fixtureRecords([2022], prefix: "older"), request: older)
        model.abandon(older)
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(model.activeRequest?.generation == newer.generation
            && model.selectedYear == 2024 && model.availableYears == [2024]
            && model.stats?.topTitles.first?.id == "newer-2024" && !model.isLoading,
            "older controlled finish/abandon damaged newer request/cache")
    }

    private static func fixtureCaptureDuringNestedProfileSetter() throws {
        let (model, _, b) = fixtureContext(owner: true)
        let profiles = ProfileStore.shared
        let oldWaitCount = CoreBridge.shared.waitCallCount
        var entered = false
        var blocked = false
        let observation = profiles.$profiles.dropFirst().sink { _ in
            guard !entered else { return }
            entered = true
            profiles.fixtureSelect(b.id)
            blocked = LegacyWatchOwnership.captureApplicationEpoch() == nil
            model.load()
            blocked = blocked && model.activeRequest == nil && model.libraryTask == nil
        }
        defer { observation.cancel() }
        var sameBindings = profiles.profiles
        sameBindings[0].name = "nonmaterial outer roster assignment"
        profiles.fixtureRoster(sameBindings)
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(entered && blocked && LegacyWatchOwnership.captureApplicationEpoch() != nil
            && CoreBridge.shared.waitCallCount == oldWaitCount && model.stats == nil && !model.isLoading,
            "nested profile setter admitted mixed authority")
    }

    private static func fixtureNestedLoadAndDelayedRetirement() throws {
        let (model, _, b) = fixtureContext(owner: false)
        fixtureOverlay([2022])
        model.load()
        var count = 0
        var depth = 0
        var maximumDepth = 0
        let observation = model.objectWillChange.sink {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            count += 1
            if count == 1 {
                ProfileStore.shared.fixtureSelect(b.id)
                fixtureOverlay([2024])
                model.load()
                model.selectedYear = 2024
            }
            depth -= 1
        }
        defer { observation.cancel() }
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(count == 2 && maximumDepth == 1 && model.selectedYear == 2024
            && model.stats?.topTitles.first?.id == "tt-overlay-2024" && model.stats?.totalWatchSeconds == 180,
            "nested load/year lost B desired value or nested a Published setter")
        // Same unchanged retirement method used by the delayed subscription callback, driven at
        // its boundary. This is NOT a receipt for NotificationCenter receive(on:) delivery.
        try fixtureRequire(!model.retireStaleState() && model.stats?.topTitles.first?.id == "tt-overlay-2024",
                           "delayed retirement erased current B cache")
    }

    private static func fixtureYearAndBudget(remainder: Bool) throws {
        let (model, _, _) = fixtureContext(owner: false)
        fixtureOverlay([2022, 2023, 2024])
        model.load()
        model.fixtureDrainCallbackBoundary()
        model.selectedYear = 2022
        var count = 0
        var depth = 0
        var maximumDepth = 0
        let observation = model.objectWillChange.sink {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            count += 1
            if count == 1 { model.selectedYear = 2023 }
            if count == 2 && remainder { model.selectedYear = 2024 }
            depth -= 1
        }
        defer { observation.cancel() }
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(count == 2 && maximumDepth == 1 && model.selectedYear == 2023
            && model.stats?.scopeLabel == "2023" && model.stats?.totalWatchSeconds == 120,
            "first drain exceeded two assignments or lost newest published scope")
        if remainder {
            try fixtureRequire(model.publicationPending && model.publicationScheduled
                && model.desired.selectedYear == 2024, "missing bounded remainder admission")
            model.fixtureDrainCallbackBoundary()
            try fixtureRequire(count == 3 && model.selectedYear == 2024
                && model.stats?.scopeLabel == "2024" && model.stats?.totalWatchSeconds == 180
                && !model.publicationPending && !model.publicationScheduled, "remainder did not publish latest scope")
        } else {
            try fixtureRequire(!model.publicationPending && !model.publicationScheduled, "unexpected remainder")
        }
    }

    private static func fixtureInvalidationOnly(secondAssignment: Bool) throws {
        let (model, _, _) = fixtureContext(owner: false)
        fixtureOverlay([2022, 2023])
        model.load()
        model.fixtureDrainCallbackBoundary()
        model.selectedYear = 2022
        let invalidateAt = secondAssignment ? 2 : 1
        var count = 0
        var neutralInside = false
        var neutralAfterStored = false
        let observation = model.objectWillChange.sink {
            count += 1
            if secondAssignment && count == 1 { model.selectedYear = 2023 }
            if count == invalidateAt {
                LegacyWatchOwnership.invalidateSession() // Calls no model method.
                neutralInside = fixtureNeutralGetters(model)
            }
            if count == invalidateAt + 1 {
                neutralAfterStored = model.presentation.stats != nil && fixtureNeutralGetters(model)
            }
        }
        defer { observation.cancel() }
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(neutralInside, "willSet invalidation exposed an old owner through a public getter")
        if secondAssignment {
            // The second stale snapshot IS physically stored, budget is exhausted, and no await has
            // let the queued repair run. Check ALL FOUR public getters at this exact point.
            try fixtureRequire(count == 2 && model.presentation.stats != nil
                && model.presentation.authority != nil && fixtureNeutralGetters(model)
                && model.publicationPending && model.publicationScheduled,
                "getter admission failed after stale second storage and before queued repair")
            model.fixtureDrainCallbackBoundary()
        }
        try fixtureRequire(neutralAfterStored && model.stats == nil && model.availableYears.isEmpty
            && !model.isLoading && model.records.isEmpty,
            "old stored snapshot remained exposed or repair retained records")
        try fixtureRequire(model.desired.selectedYear == (secondAssignment ? 2023 : 2022),
                           "retirement discarded latest scope intent")
    }

    private static func fixtureRetentionAndEmptyOverlay() throws {
        let (model, _, _) = fixtureContext(owner: true)
        let first = model.fixtureBoundaryRequest()
        model.finishLoad(fixtureRecords([2024], prefix: "cached"), request: first)
        model.fixtureDrainCallbackBoundary()
        let second = model.fixtureBoundaryRequest()
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(second.generation != first.generation && model.isLoading
            && model.stats?.topTitles.first?.id == "cached-2024" && model.availableYears == [2024],
            "same-authority reload dropped valid original cache")
        let (overlay, _, _) = fixtureContext(owner: false)
        overlay.selectedYear = 2030
        overlay.load()
        overlay.fixtureDrainCallbackBoundary()
        try fixtureRequire(overlay.stats != nil && overlay.stats?.titlesCount == 0
            && overlay.availableYears.isEmpty && overlay.selectedYear == nil && !overlay.isLoading,
            "successful empty overlay is not an empty computed result")
    }

    // REAL Task/library-wait path: each schedule proves entry before switching, releases the explicit
    // continuation, then awaits that original Task.value. A stale result must stop before utility work.
    private static func fixtureWaitingOwnerChange(aba: Bool) async throws {
        let (model, a, b) = fixtureContext(owner: true)
        let hold = CoreBridge.shared.planLibraryWait()
        defer { hold.releaseIfHeld() }
        model.load()
        let original = model.activeRequest!
        let task = model.libraryTask!
        await hold.entered.wait()
        try fixtureRequire(original.authority.expectedUID == "fixture-owner-a", "original UID capture")
        ProfileStore.shared.fixtureSelect(b.id)
        CoreBridge.shared.fixtureUID = "fixture-owner-b"
        if aba {
            ProfileStore.shared.fixtureSelect(a.id)
            CoreBridge.shared.fixtureUID = "fixture-owner-a"
        }
        hold.release()
        await task.value
        model.fixtureDrainCallbackBoundary()
        try fixtureRequire(model.records.isEmpty && model.cachedAuthority == nil
            && model.stats == nil && !model.isLoading, "post-await old owner accepted")
    }

    private func fixtureStatsReceipt(containing id: String) -> (FixtureSignal, AnyCancellable) {
        let signal = FixtureSignal()
        let observation = $presentation.sink { value in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated {
                if value.stats?.topTitles.contains(where: { $0.id == id }) == true && !signal.isFinished {
                    signal.finish()
                }
            }
        }
        return (signal, observation)
    }

    private static func fixtureSameOwnerWaitingAndPipeline() async throws {
        let (model, _, _) = fixtureContext(owner: true)
        let aHold = CoreBridge.shared.planLibraryWait()
        defer { aHold.releaseIfHeld() }
        model.load()
        let older = model.activeRequest!
        let aTask = model.libraryTask!
        await aHold.entered.wait()
        let bHold = CoreBridge.shared.planLibraryWait()
        defer { bHold.releaseIfHeld() }
        model.load()
        let newer = model.activeRequest!
        let bTask = model.libraryTask!
        await bHold.entered.wait()
        aHold.release()
        await aTask.value
        try fixtureRequire(model.activeRequest?.generation == newer.generation && model.libraryTask != nil
            && model.desired.isLoading, "old cancelled wait cleared waiting successor")
        // A deliberately delivered late COMPLETION BOUNDARY remains unable to borrow B's generation.
        model.finishLoad(fixtureRecords([2022], prefix: "late-a"), request: older)
        try fixtureRequire(model.activeRequest?.generation == newer.generation && model.records.isEmpty,
                           "late A boundary damaged still-waiting B")
        let (receipt, observation) = model.fixtureStatsReceipt(containing: "tt-live-b")
        defer { observation.cancel() }
        CoreBridge.shared.library = .init(catalog: [
            CoreCWItem(id: "tt-live-b", name: "Live B", state: .init(duration: 120_000, timeOffset: 0, timesWatched: 1))
        ])
        bHold.release()
        await bTask.value
        await receipt.wait()
        try fixtureRequire(model.stats?.topTitles.first?.id == "tt-live-b"
            && model.stats?.titlesCount == 1 && model.stats?.totalWatchSeconds == 120
            && !model.isLoading && model.libraryTask == nil,
            "real legacy Task/utility/main publication failed to expose B")
    }

    private static func fixtureSignedOutPipeline() async throws {
        let (model, _, _) = fixtureContext(owner: true, uid: nil)
        let hold = CoreBridge.shared.planLibraryWait()
        defer { hold.releaseIfHeld() }
        model.load()
        let original = model.activeRequest!
        let task = model.libraryTask!
        await hold.entered.wait()
        try fixtureRequire(original.authority.expectedUID == nil, "nil UID must be captured exactly")
        model.selectedYear = 2030
        let (receipt, observation) = model.fixtureStatsReceipt(containing: "tt-disk-2024")
        defer { observation.cancel() }
        hold.release()
        await task.value
        await receipt.wait()
        try fixtureRequire(model.stats?.titlesCount == 2 && model.stats?.totalWatchSeconds == 210
            && model.availableYears == [2024, 2023] && model.selectedYear == nil && !model.isLoading
            && model.cachedAuthority?.expectedUID == nil,
            "nil UID policy, recent overwrite, or unavailable-year normalization changed")
    }

    // Direct production worker-helper exercise stays OFF MAIN. This is a separate helper-boundary
    // receipt, not a replacement implementation or proof of a particular production worker's completion.
    nonisolated private static func fixtureReadOwnerHelpers(expectedUID: String?) async -> [WatchRecord] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                let bucket = Self.bucketRecords(expectedUID: expectedUID)
                let merged = Self.mergeLive(into: bucket, library: [], continueWatching: [])
                continuation.resume(returning: merged)
            }
        }
    }

    static func fixtureRun() async throws {
        // This entire first group is synchronous on MainActor. Boundary-generated callbacks cannot
        // run until these methods return and their model/observation owners have been released.
        try fixtureOriginalAuthorityBoundaries()
        try fixtureSameOwnerReversedBoundary()
        try fixtureCaptureDuringNestedProfileSetter()
        try fixtureNestedLoadAndDelayedRetirement()
        try fixtureYearAndBudget(remainder: false)
        try fixtureYearAndBudget(remainder: true)
        try fixtureInvalidationOnly(secondAssignment: false)
        try fixtureInvalidationOnly(secondAssignment: true)
        try fixtureRetentionAndEmptyOverlay()
        try await fixtureWaitingOwnerChange(aba: false)
        try await fixtureWaitingOwnerChange(aba: true)
        try await fixtureSameOwnerWaitingAndPipeline()
        try await fixtureSignedOutPipeline()
        let nilUID = await fixtureReadOwnerHelpers(expectedUID: nil)
        let otherUID = await fixtureReadOwnerHelpers(expectedUID: "different-owner")
        try fixtureRequire(nilUID.count == 2 && nilUID.first(where: { $0.id == "tt-disk-2023" })?.watchSeconds == 90
            && otherUID.isEmpty, "off-main production bucket/merge helper policy")
    }
}
