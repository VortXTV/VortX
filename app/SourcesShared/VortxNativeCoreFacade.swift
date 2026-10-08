import Foundation

/// Compatibility entry point for CoreBridge's existing Load/Unload wire. It never initializes or
/// calls Stremio. Unsupported actions return false and record a non-sensitive diagnostic code.
/// Account migration/key acquisition remain explicit prerequisites to constructing the session.
final class VortxNativeCoreFacade: @unchecked Sendable {
    struct RegistryBinding: Equatable, Sendable { let scope: VortxAccountScope; let profileID: String; let generation: UUID }
    private let session: VortxNativeSession
    private var registry: [VortxResourceAddon]
    private var registryGeneration = UUID()
    private var registrySnapshot: [VortxResourceAddon] { lock.withLock { registry } }
    // Dispatch admission is one synchronous transaction, including nested begin/enqueue helpers.
    // This prevents a profile change/rebind from slipping between a UI identity read and enqueue.
    private let lock = NSRecursiveLock()
    private var values: [String: VortxJSON] = [:]
    private var selections: [String: VortxJSON] = [:]
    private var generations: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var closed = false
    private let changed: @Sendable ([String]) -> Void
    private let mutationAccepted: @Sendable () -> Void
    private var failure: String?
    private var resourceRegistryValid = true
    private var pendingProfileTransitions = 0
    private var accountEpoch = UUID()
    private var sourceArchive: Data?
    var authenticatedSourceArchive: Data? { lock.withLock { sourceArchive } }
    var accountGeneration: UUID { lock.withLock { accountEpoch } }
    func captureSourceFence() -> @Sendable () -> Bool {
        guard let captured = profileSnapshot() else { return { false } }
        let archive = authenticatedSourceArchive
        return { [weak self] in
            guard let current = self?.profileSnapshot() else { return false }
            return current.generation == captured.generation && current.pending == captured.pending && self?.authenticatedSourceArchive == archive
        }
    }
    private func accountIdentity(_ state: VortxJSON?) -> VortxJSON {
        var bindings: [String: VortxJSON] = [:]
        if case .object(let profiles) = state?["roster"]?["profiles"] {
            for (id, profile) in profiles {
                bindings[id] = state?["nativeSync"]?["accountSlots"]?[id]?["activeBinding"]
                    ?? .object(["account": profile["account"] ?? .null, "revision": .integer(0), "transactionId": .null])
            }
        }
        return .object(bindings)
    }
    private var playback: VortxJSON?
    private var libraryRequest: VortxJSON?
    var lastFailure: String? { lock.withLock { failure } }
    var isAvailable: Bool { lock.withLock { !closed } }
    func cachedResumeSeconds(id: String) -> Double? {
        lock.withLock {
            guard !closed, pendingProfileTransitions == 0, let value = playback?["resumeById"]?[id] else { return nil }
            if value == .null { return 0 }
            guard let offset = try? value["offsetMs"]?.decode(UInt64.self) else { return nil }
            return Double(offset) / 1000
        }
    }
    func resumeSeconds(id: String, profileID: String, expectedAccountGeneration: UUID) async throws -> Double {
        let accepted = lock.withLock { !closed && accountEpoch == expectedAccountGeneration && pendingProfileTransitions == 0 && values["native_state"]?["activeProfileId"] == .string(profileID) }
        guard accepted else { throw VortxNativeError.superseded }
        let seconds = try await session.resumeSeconds(id: id, profileID: profileID)
        guard lock.withLock({ !closed && accountEpoch == expectedAccountGeneration && pendingProfileTransitions == 0 && values["native_state"]?["activeProfileId"] == .string(profileID) }) else { throw VortxNativeError.superseded }
        return seconds
    }
    func dispatchForProfile(_ action: VortxJSON, profileID: String, expectedAccountGeneration: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, values["native_state"]?["activeProfileId"] == .string(profileID),
              let type = string(action["type"]), ["report_progress", "mark_watched", "reset_watched", "remove_from_continue_watching"].contains(type),
              let bytes = try? JSONEncoder().encode(action) else { return fail("stale_profile_intent") }
        return enqueueMutation(type: type, raw: String(decoding: bytes, as: UTF8.self))
    }
    func dispatchCaptured(data: Data, field: String?, expectedAccountGeneration: UUID) -> Bool {
        lock.withLock {
            guard !closed, accountEpoch == expectedAccountGeneration else { return false }
            return dispatch(data: data, field: field)
        }
    }

    static func create(session: VortxNativeSession, registry: [VortxResourceAddon],
                       mutationAccepted: @escaping @Sendable () -> Void = {},
                       changed: @escaping @Sendable ([String]) -> Void) async throws -> VortxNativeCoreFacade {
        guard Set(registry.map(\.id)).count == registry.count else { throw VortxNativeError.invalidResponse }
        let facade = VortxNativeCoreFacade(session: session, registry: registry, mutationAccepted: mutationAccepted, changed: changed)
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        facade.playback = try await session.playbackProjection()
        facade.values = try facade.stateFields(state)
        facade.values["native_host_preferences"] = try await session.hostPreferencesDocument()
        facade.values["native_own_overlay_pending"] = try await session.pendingOwnAccountOverlays()
        facade.sourceArchive = try await session.authenticatedSourceArchive()
        return facade
    }
    private init(session: VortxNativeSession, registry: [VortxResourceAddon], mutationAccepted: @escaping @Sendable () -> Void, changed: @escaping @Sendable ([String]) -> Void) {
        self.session = session; self.registry = registry; self.changed = changed; self.mutationAccepted = mutationAccepted
    }
    func stateData(_ field: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; guard !closed, let value = values[field] else { return nil }
        return try? JSONEncoder().encode(value)
    }
    func profileSnapshot() -> (state: VortxJSON, host: VortxJSON, pending: VortxJSON, generation: UUID)? {
        lock.withLock {
            guard !closed, let state = values["native_state"], let host = values["native_host_preferences"] else { return nil }
            return (state, host, values["native_own_overlay_pending"] ?? .object([:]), accountEpoch)
        }
    }
    func close() {
        lock.lock(); closed = true; let old = Array(tasks.values); tasks.removeAll(); generations.removeAll(); values.removeAll(); lock.unlock()
        session.revoke()
        old.forEach { $0.cancel() }; Task { await session.close() }
    }
    func shutdown() async { close(); await session.close() }
    var registryBinding: RegistryBinding? {
        lock.withLock {
            guard !closed, pendingProfileTransitions == 0, let profile = string(values["native_state"]?["activeProfileId"]) else { return nil }
            return RegistryBinding(scope: session.scope, profileID: profile, generation: registryGeneration)
        }
    }
    /// Caller-confirmed registry replacement is bound to the accepted account/profile generation.
    /// New loads stay rejected during replacement; all previous resource publications are revoked.
    func rebindRegistry(_ replacement: [VortxResourceAddon], expected: RegistryBinding) async throws {
        let admission = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard Set(replacement.map(\.id)).count == replacement.count, registryBinding == expected else { return (false, nil) }
            // A watched-card admission may already have passed its lock check and be waiting to
            // enter the session actor. Wait for that exact FIFO member before invalidating the
            // resource host; otherwise a rebind can land between the facade check and dispatch.
            let predecessor = tasks["native_state"]
            invalidateResourcePublications(); return (true, predecessor)
        }
        guard admission.0 else { throw VortxNativeError.superseded }
        await admission.1?.value
        await session.invalidateResources()
        let accepted = lock.withLock { () -> Bool in
            guard !closed, expected.scope == session.scope, expected.generation == registryGeneration,
                  values["native_state"]?["activeProfileId"] == .string(expected.profileID) else { return false }
            registry = replacement; resourceRegistryValid = true; registryGeneration = UUID()
            values["ctx"] = .object(["profile": .object(["addons": .array(replacement.map {
                .object(["transportUrl": .string($0.transportUrl), "manifest": $0.manifest ?? .object([:])])
            })])]); return true
        }
        guard accepted else { throw VortxNativeError.superseded }; changed(["ctx"])
    }
    /// Called under lock. Keep the durable-state publication, discard only prior resource ownership.
    private func invalidateResourcePublications() {
        resourceRegistryValid = false
        for (field, task) in tasks where field != "native_state" { task.cancel() }
        generations = generations.filter { $0.key == "native_state" }
        values = values.filter { ["native_state", "library"].contains($0.key) }; selections = [:]
    }
    private func resourceIdentity(_ state: VortxJSON?) -> VortxJSON {
        let active = string(state?["activeProfileId"]) ?? ""
        let profile = state?["roster"]?["profiles"]?[active]
        return .object(["active": .string(active), "binding": profile?["addons"] ?? .null,
                        "account": accountIdentity(state),
                        "settings": profile?["settings"] ?? .null, "parental": profile?["parental"] ?? .null,
                        "addons": state?["nativeSync"]?["addons"] ?? .null])
    }
    private func fail(_ code: String) -> Bool { lock.lock(); failure = code; lock.unlock(); return false }
    private func string(_ value: VortxJSON?) -> String? { if case .string(let text) = value { return text }; return nil }
    private func path(_ value: VortxJSON?) throws -> VortxResourceRequest {
        guard let value else { throw VortxNativeError.invalidResponse }; return try value.decode(VortxResourceRequest.self)
    }
    private func begin(_ field: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }; guard !closed else { return nil }
        let ticket = UUID(); tasks[field]?.cancel(); generations[field] = ticket; failure = nil; return ticket
    }
    private func publish(_ fields: [String: VortxJSON], field: String, ticket: UUID) {
        lock.lock()
        guard !closed, generations[field] == ticket else { lock.unlock(); return }
        fields.forEach {
            values[$0.key] = $0.key == "meta_details" ? metaWithPlayback($0.value, library: values["library"]?["catalog"]?.array ?? []) : $0.value
        }; lock.unlock(); changed(Array(fields.keys))
    }
    private func enqueue(_ field: String, initial: VortxJSON? = nil, operation: @escaping @Sendable () async throws -> [String: VortxJSON]) -> Bool {
        guard let ticket = begin(field) else { return false }
        if let initial { publish([field: initial], field: field, ticket: ticket) }
        let task = Task { [weak self] in
            do { try Task.checkCancellation(); let result = try await operation(); try Task.checkCancellation(); self?.publish(result, field: field, ticket: ticket) }
            catch {
                guard let self else { return }
                self.lock.withLock {
                    if self.generations[field] == ticket && !self.closed { self.failure = "native_operation_failed" }
                }
                self.publish([field: .object(["nativeError": .string("native_operation_failed")])], field: field, ticket: ticket)
            }
        }
        lock.lock()
        if closed || generations[field] != ticket { task.cancel() } else { tasks[field] = task }
        lock.unlock(); return true
    }
    private func enqueueMutation(type: String, raw: String, legacyMaterial: Data? = nil,
                                 actions: [String]? = nil, hostRemote: VortxJSON? = nil,
                                 hostEdits: [VortxNativeHostPreferences.Edit] = [],
                                 legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]] = [:],
                                 admission: (@Sendable () -> Bool)? = nil,
                                 websiteEvents: [VortxJSON] = [], websiteBaseline: VortxNativeProfileEditHost.Baselines = [:],
                                 sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil,
                                 completion: (@Sendable (Result<VortxJSON, Error>) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard !closed else { return false }
        let predecessor = tasks["native_state"]
        let ticket = UUID(); generations["native_state"] = ticket
        let profileTransition = ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"].contains(type)
        if profileTransition { pendingProfileTransitions += 1 }
        // State intents are FIFO, never latest-wins: dropping one would lose progress/profile edits.
        tasks["native_state"] = Task { [weak self] in
            await predecessor?.value
            guard let self else { completion?(.failure(VortxNativeError.closed)); return }
            var transitionReleased = false
            defer { if profileTransition && !transitionReleased { self.lock.withLock { self.pendingProfileTransitions -= 1 } } }
            var durableCommitted = false
            do {
                try Task.checkCancellation()
                // Resource-backed gestures may wait behind an add-on/profile mutation.  Their
                // metadata was accepted for an earlier registry generation, so revalidate at
                // the FIFO boundary rather than treating the pre-enqueue check as durable.
                guard admission?() ?? true else {
                    _ = self.fail("stale_native_mutation")
                    completion?(.failure(VortxNativeError.superseded))
                    return
                }
                _ = try await session.dispatch(actions ?? [raw], now: UInt64(Date().timeIntervalSince1970), legacyMaterial: legacyMaterial,
                                               hostRemote: hostRemote, hostEdits: hostEdits, legacyWatchlists: legacyWatchlists, websiteEvents: websiteEvents, websiteBaseline: websiteBaseline,
                                               sourceAuthority: sourceAuthority, authenticatedSourceArchive: authenticatedSourceArchive)
                durableCommitted = true
                let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
                let playback = try await session.playbackProjection()
                let host = try await session.hostPreferencesDocument()
                let website = try await session.websiteEditOutcome()
                let ownPending = try await session.pendingOwnAccountOverlays()
                let sourceArchive = try await session.authenticatedSourceArchive()
                let websiteChanged = !websiteEvents.isEmpty && self.lock.withLock {
                    self.values["native_state"]?["nativeSync"] != state["nativeSync"] ||
                        self.values["native_host_preferences"] != host || self.values["native_website_edits"] != website
                }
                let resourceChanged = self.lock.withLock { self.resourceIdentity(self.values["native_state"]) != self.resourceIdentity(state) }
                // Only the native registry query determines installed membership/order. It also
                // resolves own/share-primary before new-profile resource loads can be admitted.
                let replacement = resourceChanged ? try? await session.resourceRegistry() : nil
                if resourceChanged { await session.invalidateResources() }
                let publishedFields = try self.lock.withLock { () -> [String: VortxJSON]? in
                    guard !self.closed else { return nil }
                    if self.accountIdentity(self.values["native_state"]) != self.accountIdentity(state) { self.accountEpoch = UUID() }
                    self.failure = nil
                    self.playback = playback
                    self.sourceArchive = sourceArchive
                    if self.resourceIdentity(self.values["native_state"]) != self.resourceIdentity(state) {
                        self.invalidateResourcePublications(); self.registryGeneration = UUID()
                        if let replacement { self.registry = replacement; self.resourceRegistryValid = true }
                        else { self.failure = "registry_unavailable" }
                    }
                    var fields = try self.stateFields(state)
                    fields["native_host_preferences"] = host
                    fields["native_website_edits"] = website
                    fields["native_own_overlay_pending"] = ownPending
                    fields.forEach { self.values[$0.key] = $0.value }; return fields
                }
                // FIFO intents each publish their acknowledged state before the next task executes.
                // A later get_state must not hide the profile transition's accepted state.
                if profileTransition { self.lock.withLock { self.pendingProfileTransitions -= 1 }; transitionReleased = true }
                if let publishedFields { self.changed(Array(publishedFields.keys)) }
                guard publishedFields != nil, let document = state["nativeSync"] else { throw VortxNativeError.closed }
                if !["get_state", "merge_native_sync", "bind_sync_scope"].contains(type) || !hostEdits.isEmpty || websiteChanged { self.mutationAccepted() }
                completion?(.success(document))
            } catch VortxNativeError.checkpointUncertain {
                _ = self.fail("checkpoint_uncertain_reopen_required"); completion?(.failure(VortxNativeError.checkpointUncertain))
            } catch {
                if durableCommitted {
                    // The acknowledged snapshot exists, but its required projection failed. Do
                    // not relabel the previous/empty history as the successful new profile state.
                    self.close(); _ = self.fail("native_projection_unavailable_reopen_required")
                } else { _ = self.fail("native_mutation_failed") }
                completion?(.failure(error))
            }
        }
        return true
    }
    /// Resource-backed public actions need a durable result, unlike synchronous UI wires whose
    /// Bool only reports admission.  In particular, a registry may change while this intent is
    /// waiting behind another state mutation; report that rejection to the card caller.
    private func enqueueWatchedMutation(type: String, actions: [String], admission: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let admitted = enqueueMutation(type: type, raw: "", actions: actions, admission: admission) { result in
                switch result {
                case .success: continuation.resume(returning: true)
                case .failure: continuation.resume(returning: false)
                }
            }
            if !admitted { continuation.resume(returning: false) }
        }
    }
    /// Merge the fresh authenticated remote carrier and export only the accepted CRDT document.
    /// This shares the exact FIFO with profile/progress intents; a stale read cannot overwrite a
    /// concurrent local change, and a failed merge/checkpoint never becomes an outgoing snapshot.
    func mergeSyncDocument(_ remote: VortxJSON?, legacyMaterial: Data? = nil) async throws -> VortxJSON {
        let action = remote.map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) }
            ?? .object(["type": .string("get_state")])
        let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            if !enqueueMutation(type: remote == nil ? "get_state" : "merge_native_sync", raw: raw, legacyMaterial: legacyMaterial,
                                completion: { continuation.resume(with: $0) }) {
                continuation.resume(throwing: VortxNativeError.closed)
            }
        }
    }
    /// One durable transaction contains both private-kernel state and public host preferences.
    /// Its returned carrier is read only after the same FIFO's merge/checkpoint acknowledgement.
    func mergeAccountDocument(_ remote: VortxJSON?, hostRemote: VortxJSON?, legacyMaterial: Data?,
                              hostEdits: [VortxNativeHostPreferences.Edit] = [], websiteEvents: [VortxJSON] = [],
                              legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]] = [:],
                              websiteBaseline: VortxNativeProfileEditHost.Baselines = [:],
                              sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil) async throws -> VortxJSON {
        let action = remote.map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) }
            ?? .object(["type": .string("get_state")])
        let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            if !enqueueMutation(type: remote == nil ? "get_state" : "merge_native_sync", raw: raw, legacyMaterial: legacyMaterial,
                                hostRemote: hostRemote, hostEdits: hostEdits, legacyWatchlists: legacyWatchlists, websiteEvents: websiteEvents, websiteBaseline: websiteBaseline,
                                sourceAuthority: sourceAuthority, authenticatedSourceArchive: authenticatedSourceArchive, completion: { [weak self] result in
                switch result {
                case .success(let native):
                    guard let self, let host = self.lock.withLock({ self.values["native_host_preferences"] }) else { continuation.resume(throwing: VortxNativeError.closed); return }
                    let website = self.lock.withLock { self.values["native_website_edits"] ?? .object([:]) }
                    continuation.resume(returning: .object(["nativeSync": native, "nativeHostPreferences": host, "profileEditResults": website]))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }) { continuation.resume(throwing: VortxNativeError.closed) }
        }
    }
    func mutateProfiles(_ actions: [VortxJSON], hostEdits: [VortxNativeHostPreferences.Edit], expectedProfileID: String, expectedAccountGeneration: UUID,
                        sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, values["native_state"]?["activeProfileId"] == .string(expectedProfileID),
                  actions.allSatisfy({ ["add_profile", "patch_profile", "delete_profile", "switch_profile", "rebind_profile_account"].contains(string($0["type"]) ?? "") }) else { continuation.resume(throwing: VortxNativeError.superseded); return }
            do {
                let raw = try actions.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                if !enqueueMutation(type: "patch_profile", raw: "", actions: raw, hostEdits: hostEdits,
                                    sourceAuthority: sourceAuthority, authenticatedSourceArchive: authenticatedSourceArchive,
                                    completion: { result in continuation.resume(with: result.map { _ in () }) }) {
                    continuation.resume(throwing: VortxNativeError.closed)
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    /// A synchronous UI admission receipt, not a durable-write acknowledgement. The native FIFO
    /// owns persistence and rejects stale profile gestures before resolving their effective bucket.
    func reorderAddonURLs(_ urls: [String], profileID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, pendingProfileTransitions == 0,
              values["native_state"]?["activeProfileId"] == .string(profileID),
              let binding = values["native_state"]?["roster"]?["profiles"]?[profileID]?["addons"],
              [.string("own"), .string("share_primary")].contains(binding),
              urls.allSatisfy({ !$0.isEmpty }), Set(urls).count == urls.count else { return fail("stale_or_invalid_addon_order") }
        let bucket = binding == .string("share_primary") ? session.scope.ownerProfileID : profileID
        let action: VortxJSON = .object(["type": .string("reorder_addons"), "profileId": .string(bucket), "transportUrls": .array(urls.map(VortxJSON.string))])
        guard let data = try? JSONEncoder().encode(action) else { return false }
        return enqueueMutation(type: "reorder_addons", raw: String(decoding: data, as: UTF8.self))
    }
    /// Apply a complete, already-resolved episode inventory in one kernel transaction.  Series
    /// actions deliberately contain only opaque IDs supplied by the current metadata response:
    /// a title-level mark would incorrectly claim future or unavailable episodes are watched.
    func setWatchedVideos(metaID: String, videoIDs: [String], name: String, type: String, poster: String?, watched: Bool,
                          profileID: String, expectedAccountGeneration: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accountEpoch == expectedAccountGeneration else { return fail("stale_watched_account") }
        let uniqueIDs = Array(Set(videoIDs.filter { !$0.isEmpty })).sorted()
        guard !closed, pendingProfileTransitions == 0,
              values["native_state"]?["activeProfileId"] == .string(profileID), !uniqueIDs.isEmpty,
              let inventory = acceptedMetadataInventory(metaID: metaID, type: type),
              Set(uniqueIDs).isSubset(of: Set(inventory)) else {
            return fail("stale_or_empty_watched_inventory")
        }
        let generation = registryGeneration
        do {
            let actions = try uniqueIDs.map { videoID -> String in
                let action: VortxJSON = .object([
                    "type": .string(watched ? "mark_watched" : "reset_watched"),
                    "metaId": .string(metaID), "videoId": .string(videoID), "name": .string(name),
                    "metadata": .object(["type": .string(type), "poster": poster.map(VortxJSON.string) ?? .null]),
                ])
                return String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
            }
            return enqueueMutation(type: watched ? "mark_watched" : "reset_watched", raw: "", actions: actions,
                                   admission: { [weak self] in
                guard let self else { return false }
                return self.lock.withLock {
                    guard !self.closed, self.accountEpoch == expectedAccountGeneration, self.pendingProfileTransitions == 0,
                          self.resourceRegistryValid, self.registryGeneration == generation,
                          self.values["native_state"]?["activeProfileId"] == .string(profileID),
                          let current = self.acceptedMetadataInventory(metaID: metaID, type: type) else { return false }
                    return Set(uniqueIDs).isSubset(of: Set(current))
                }
            })
        } catch { return fail("invalid_watched_inventory") }
    }
    /// Card actions may not have a resident detail page. Resolve their exact metadata through the
    /// native resource host without publishing into the navigation slot, then recheck the captured
    /// profile and registry generation before one atomic episode transaction is admitted.
    func resolveAndSetWatchedVideos(metaID: String, type: String, name: String, poster: String?, watched: Bool,
                                    profileID: String, expectedAccountGeneration: UUID, season: Int? = nil) async -> Bool {
        let captured: (UUID, [VortxResourceAddon])? = lock.withLock {
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, resourceRegistryValid,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else { return nil }
            return (registryGeneration, registry)
        }
        guard let captured else { return fail("stale_watched_resolution") }
        // libraryMetadata owns a unique resource-host slot.  In particular, this must not use
        // loadMeta: that owns the visible meta_details slot and would cancel/clobber navigation.
        guard let meta = try? await session.libraryMetadata(id: metaID, type: type, profileID: profileID, addons: captured.1) else {
            return fail("watched_metadata_unavailable")
        }
        let ids = (meta["videos"]?.array ?? []).filter { season == nil || (try? $0["season"]?.decode(Int.self)) == season }.compactMap { string($0["id"]) }
        guard !ids.isEmpty else { return fail("watched_metadata_unavailable") }
        let actions: [String]? = lock.withLock {
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, registryGeneration == captured.0,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else {
                _ = fail("stale_watched_resolution"); return nil
            }
            do {
                return try Array(Set(ids)).sorted().map { videoID in
                    let action: VortxJSON = .object(["type": .string(watched ? "mark_watched" : "reset_watched"), "metaId": .string(metaID), "videoId": .string(videoID), "name": .string(name), "metadata": .object(["type": .string(type), "poster": poster.map(VortxJSON.string) ?? .null])])
                    return String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
                }
            } catch { _ = fail("invalid_watched_inventory"); return nil }
        }
        guard let actions else { return false }
        return await enqueueWatchedMutation(type: watched ? "mark_watched" : "reset_watched", actions: actions,
                                            admission: { [weak self] in
            guard let self else { return false }
            return self.lock.withLock {
                !self.closed && self.accountEpoch == expectedAccountGeneration
                    && self.pendingProfileTransitions == 0 && self.resourceRegistryValid
                    && self.registryGeneration == captured.0
                    && self.values["native_state"]?["activeProfileId"] == .string(profileID)
            }
        })
    }
    /// Metadata comes only from the accepted native registry. The return value acknowledges the
    /// durable FIFO add, not merely HTTP success or UI dispatch. Legacy recovery may only confirm
    /// existing native membership; it cannot manufacture a new save over a native removal.
    func addCatalogItem(id: String, type: String, profileID: String, allowInsert: Bool, expectedAccountGeneration: UUID) async throws -> Bool {
        let captured = try lock.withLock { () -> (UUID, [VortxResourceAddon], Bool) in
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, resourceRegistryValid,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else { throw VortxNativeError.superseded }
            let saved = values["native_state"]?["libraries"]?[profileID]?["items"]?.array?.contains {
                $0["kind"] == .string("standard") && $0["id"] == .string(id) && $0["type"] == .string(type)
            } == true
            return (registryGeneration, registry, saved)
        }
        if captured.2 { return true }
        guard allowInsert else { return false }
        let meta = try await session.libraryMetadata(id: id, type: type, profileID: profileID, addons: captured.1)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, resourceRegistryValid, registryGeneration == captured.0,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else {
                continuation.resume(throwing: VortxNativeError.superseded); return
            }
            let item: VortxJSON = .object(["kind": .string("standard"), "id": .string(id), "type": .string(type),
                                           "name": meta["name"]!, "poster": meta["poster"] ?? .null])
            let action: VortxJSON = .object(["type": .string("add_library_item"), "profileId": .string(profileID), "item": item])
            do {
                let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
                guard enqueueMutation(type: "add_library_item", raw: raw, completion: { result in continuation.resume(with: result.map { _ in true }) }) else {
                    continuation.resume(throwing: VortxNativeError.closed); return
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    /// Testing/integration receipt: waits for currently admitted operations, never launches UI/media.
    func settled() async {
        let pending = lock.withLock { Array(tasks.values) }
        for task in pending { await task.value }
    }

    func dispatch(data: Data, field: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        guard let action = try? JSONDecoder().decode(VortxJSON.self, from: data),
              let name = string(action["action"]) else { return fail("invalid_action") }
        let field = field ?? "ctx"
        if name == "Unload", ["board", "search", "discover", "meta_details", "subtitles", "player"].contains(field) {
            guard let ticket = begin(field) else { return false }
            _ = lock.withLock { selections.removeValue(forKey: field) }
            publish([field: .object(["selected": .null, "catalogs": .array([]), "metaItems": .array([]), "streams": .array([]), "metaStreams": .array([])])], field: field, ticket: ticket)
            return true
        }
        // Explicit native action admission. No authentication/session-token operation is translated.
        if name == "Vortx", let native = action["args"], let type = string(native["type"]),
           Self.nativeActions.contains(type), let encoded = try? JSONEncoder().encode(native) {
            let raw = String(decoding: encoded, as: UTF8.self)
            return enqueueMutation(type: type, raw: raw)
        }
        // UI translations below refer to the currently published profile/selection. While a queued
        // transition is unsettled, do not infer whether a gesture belongs to the old or new profile.
        if lock.withLock({ pendingProfileTransitions > 0 }) { return fail("profile_transition_pending") }
        if name == "Ctx", string(action["args"]?["action"]) == "LibraryItemMarkAsWatched",
           let id = string(action["args"]?["args"]?["id"]), case .bool(let watched) = action["args"]?["args"]?["is_watched"] {
            var intent: [String: VortxJSON] = ["type": .string(watched ? "mark_watched" : "reset_watched"), "metaId": .string(id)]
            if let video = action["args"]?["args"]?["videoId"] ?? action["args"]?["args"]?["video_id"] {
                guard string(video) != nil else { return fail("invalid_episode_identity") }; intent["videoId"] = video
            }
            let native: VortxJSON = .object(["action": .string("Vortx"), "args": .object(intent)])
            guard let bytes = try? JSONEncoder().encode(native) else { return false }; return dispatch(data: bytes, field: "native_state")
        }
        if name == "Ctx", let subaction = string(action["args"]?["action"]),
           ["InstallAddon", "InstallAddonLocal", "ReplaceAddon", "ReplaceAddonLocal", "UninstallAddon", "UninstallAddonLocal"].contains(subaction) {
            return dispatchAddonMutation(subaction: subaction, args: action["args"]?["args"])
        }
        if name == "Ctx", let subaction = string(action["args"]?["action"]), ["AddToLibrary", "RemoveFromLibrary"].contains(subaction) {
            let state = lock.withLock { values["native_state"] }
            guard let profile = string(state?["activeProfileId"]) else { return fail("missing_profile") }
            var native: [String: VortxJSON] = ["profileId": .string(profile)]
            if subaction == "AddToLibrary" {
                guard let meta = action["args"]?["args"], let id = string(meta["id"]), let type = string(meta["type"]), let title = string(meta["name"]) else { return fail("invalid_library_meta") }
                native["type"] = .string("add_library_item")
                native["item"] = .object(["kind": .string("standard"), "id": .string(id), "type": .string(type), "name": .string(title), "poster": meta["poster"] ?? .null])
            } else {
                guard let id = string(action["args"]?["args"]) else { return fail("invalid_library_id") }
                let matches = state?["libraries"]?[profile]?["items"]?.array?.filter { $0["id"] == .string(id) && $0["kind"] == .string("standard") } ?? []
                guard matches.count == 1, let type = string(matches[0]["type"]) else { return fail("ambiguous_library_id") }
                native["type"] = .string("remove_library_item"); native["key"] = .string(type + ":" + id)
            }
            guard let bytes = try? JSONEncoder().encode(VortxJSON.object(["action": .string("Vortx"), "args": .object(native)])) else { return false }
            return dispatch(data: bytes, field: "native_state")
        }
        if name == "MetaDetails", let subaction = string(action["args"]?["action"]), ["MarkAsWatched", "MarkVideoAsWatched"].contains(subaction) {
            let detail = lock.withLock { values["meta_details"] }
            guard let metaID = string(detail?["selected"]?["metaPath"]?["id"]) else { return fail("missing_meta_selection") }
            let arguments = action["args"]?["args"]
            let watched: VortxJSON? = subaction == "MarkAsWatched" ? arguments : arguments?.array?.last
            guard case .bool(let marked) = watched else { return fail("invalid_watched_intent") }
            var native: [String: VortxJSON] = ["type": .string(marked ? "mark_watched" : "reset_watched"), "metaId": .string(metaID)]
            if subaction == "MarkVideoAsWatched" {
                guard let video = string(arguments?.array?.first?["id"]) else { return fail("invalid_episode_identity") }; native["videoId"] = .string(video)
            }
            guard let bytes = try? JSONEncoder().encode(VortxJSON.object(native)) else { return false }
            return enqueueMutation(type: marked ? "mark_watched" : "reset_watched", raw: String(decoding: bytes, as: UTF8.self))
        }
        let model = string(action["args"]?["model"])
        if ["board", "search", "discover", "meta_details", "subtitles"].contains(field),
           !lock.withLock({ resourceRegistryValid }) { return fail("registry_rebind_required") }
        if name == "Load", model == "Player", field == "player", let selected = action["args"]?["args"],
           let meta = try? path(selected["metaRequest"]?["path"]), let stream = try? path(selected["streamRequest"]?["path"]),
           meta.resource == .meta, stream.resource == .stream, meta.type == stream.type,
           selected["stream"] != nil, lock.withLock({ resourceRegistryValid }) {
            guard let ticket = begin(field) else { return false }
            lock.withLock { selections[field] = selected }
            publish([field: .object(["selected": selected])], field: field, ticket: ticket)
            return true
        }
        if name == "Player", string(action["args"]?["action"]) == "TimeChanged", field == "player" {
            let selected = lock.withLock { selections["player"] }
            guard let metaID = string(selected?["metaRequest"]?["path"]?["id"]),
                  let videoID = string(selected?["streamRequest"]?["path"]?["id"]),
                  let time = try? action["args"]?["args"]?["time"]?.decode(UInt64.self),
                  let duration = try? action["args"]?["args"]?["duration"]?.decode(UInt64.self), duration > 0 else { return fail("invalid_player_progress") }
            guard let mediaType = selected?["metaRequest"]?["path"]?["type"] else { return fail("invalid_player_type") }
            let readyMeta = values["meta_details"]?["metaItems"]?.array?.compactMap { $0["content"]?["content"] }.first { $0["id"] == .string(metaID) }
            let native: VortxJSON = .object(["type": .string("report_progress"), "metaId": .string(metaID), "videoId": .string(videoID),
                                           "name": readyMeta?["name"] ?? .string(metaID), "positionMs": .unsigned(time), "durationMs": .unsigned(duration),
                                           "metadata": .object(["type": mediaType, "poster": readyMeta?["poster"] ?? .null])])
            guard let bytes = try? JSONEncoder().encode(native) else { return false }
            return enqueueMutation(type: "report_progress", raw: String(decoding: bytes, as: UTF8.self))
        }
        if name == "Load", model == "CatalogsWithExtra", ["board", "search"].contains(field) {
            guard let ticket = begin(field) else { return false }
            let selection = action["args"]?["args"] ?? .object([:])
            lock.withLock { selections[field] = selection }
            let extra = (try? selection["extra"]?.decode([[String]].self)) ?? []
            let loading = catalogRequests(extra: extra, type: string(selection["type"])).compactMap { try? loadingEntry($0.0, $0.1) }
            publish([field: .object(["selected": selection, "catalogs": .array(loading.map { .array([$0]) })])], field: field, ticket: ticket)
            return true
        }
        if name == "CatalogsWithExtra", string(action["args"]?["action"]) == "LoadRange", ["board", "search"].contains(field) {
            let selection = lock.withLock { selections[field] }
            guard let selection, let screen = VortxNativeSession.CatalogScreen(rawValue: field) else { return fail("missing_selection") }
            let extra = (try? selection["extra"]?.decode([[String]].self)) ?? []
            let catalogs = catalogRequests(extra: extra, type: string(selection["type"]))
            let end = (try? action["args"]?["args"]?["end"]?.decode(Int.self)) ?? catalogs.count
            guard end >= 0 else { return fail("invalid_range") }
            let previous = values[field]
            let loaded = previous?["catalogs"]?.array?.filter { $0.array?.first?["content"]?["type"] != .string("Loading") } ?? []
            return enqueue(field) { [self] in
                var board: VortxJSON = loaded.isEmpty ? .object(["selected": selection, "catalogs": .array([])]) : previous!
                var hasPages = !loaded.isEmpty
                for (index, item) in catalogs.prefix(end).enumerated() {
                    if index < loaded.count { continue }
                    try Task.checkCancellation()
                    board = try await session.loadCatalog(screen, request: item.1, addons: [item.0], append: hasPages)
                    hasPages = true
                }
                return [field: board]
            }
        }
        if name == "CatalogsWithExtra", string(action["args"]?["action"]) == "LoadNextPage", ["board", "search"].contains(field) {
            guard let index = try? action["args"]?["args"]?.decode(Int.self), index >= 0,
                  let rows = values[field]?["catalogs"]?.array, index < rows.count,
                  let screen = VortxNativeSession.CatalogScreen(rawValue: field) else { return fail("invalid_catalog_page") }
            guard let next = nextCatalogPage(rows[index].array ?? []) else { return true }
            return enqueue(field) { [self] in
                [field: try await session.loadCatalog(screen, request: next.1, addons: [next.0], append: true)]
            }
        }
        if name == "Load", model == "MetaDetails", field == "meta_details" {
            guard let request = try? path(action["args"]?["args"]?["metaPath"]) else { return fail("invalid_meta_path") }
            let streamValue = action["args"]?["args"]?["streamPath"]
            let stream = streamValue == nil || streamValue == .null ? nil : try? path(streamValue)
            if streamValue != nil && streamValue != .null && stream == nil { return fail("invalid_stream_path") }
            let addons = registrySnapshot
            let loading: VortxJSON = .object([
                "selected": .object(["metaPath": (try? VortxResourceProjection.path(request)) ?? .null, "streamPath": (try? stream.map(VortxResourceProjection.path)) ?? .null]),
                "metaItems": .array(addons.compactMap { try? loadingEntry($0, request) }),
                "streams": .array(stream.map { path in addons.compactMap { try? loadingEntry($0, path) } } ?? []), "metaStreams": .array([])])
            return enqueue(field, initial: loading) { [self] in [field: try await session.loadMeta(request: request, stream: stream, addons: addons)] }
        }
        if name == "Load", model == "CatalogWithFilters", field == "discover" {
            let supplied = action["args"]?["args"]?["request"]
            let requests = catalogRequests(extra: [], type: nil)
            let chosen: (VortxResourceAddon, VortxResourceRequest)?
            if let supplied, let request = try? path(supplied["path"]), let addon = registrySnapshot.first(where: { .string($0.transportUrl) == supplied["base"] }), validCatalogRequest(request, addon: addon) { chosen = (addon, request) }
            else if supplied == nil { chosen = requests.first } else { return fail("invalid_catalog_request") }
            guard let chosen else { return fail("no_catalogs") }
            guard let loading = try? loadingEntry(chosen.0, chosen.1) else { return fail("invalid_catalog_request") }
            let initial = discoverProjection(pages: [loading], chosen: chosen, requests: requests)
            return enqueue(field, initial: initial) { [self] in
                let board = try await session.loadCatalog(.discover, request: chosen.1, addons: [chosen.0])
                let pages = board["catalogs"]?.array?.flatMap { $0.array ?? [] } ?? []
                return [field: discoverProjection(pages: pages, chosen: chosen, requests: requests)]
            }
        }
        if name == "CatalogWithFilters", string(action["args"]?["action"]) == "LoadNextPage", field == "discover" {
            guard let pages = values[field]?["catalog"]?.array else { return fail("missing_selection") }
            guard let next = nextCatalogPage(pages) else { return true }
            let requests = catalogRequests(extra: [], type: nil)
            return enqueue(field) { [self] in
                let board = try await session.loadCatalog(.discover, request: next.1, addons: [next.0], append: true)
                return [field: discoverProjection(pages: board["catalogs"]?.array?.flatMap { $0.array ?? [] } ?? [], chosen: next, requests: requests)]
            }
        }
        if name == "Load", model == "LibraryWithFilters", field == "library" {
            let request = action["args"]?["args"]?["request"]
            guard let state = values["native_state"], let value = libraryProjection(state: state, request: request),
                  let ticket = begin(field) else { return fail("unsupported_library_filter") }
            libraryRequest = request
            publish([field: value], field: field, ticket: ticket); return true
        }
        if name == "Load", model == "LocalSearch", field == "local_search" {
            guard let ticket = begin(field) else { return false }
            publish([field: .object(["searchResults": .array([])])], field: field, ticket: ticket); return true
        }
        if name == "Search", field == "local_search" {
            guard let query = string(action["args"]?["searchQuery"]),
                  let maxResults = try? action["args"]?["maxResults"]?.decode(Int.self), (1...100).contains(maxResults),
                  let state = values["native_state"], let projection = localSearchProjection(state: state, query: query, maxResults: maxResults),
                  let ticket = begin(field) else { return fail("invalid_local_search_request") }
            publish([field: projection], field: field, ticket: ticket); return true
        }
        if name == "Load", model == "Subtitles", field == "subtitles", let request = try? path(action["args"]?["args"]) {
            let addons = registrySnapshot
            return enqueue(field) { [self] in [field: try await session.loadSubtitles(request: request, addons: addons)] }
        }
        return fail("unsupported_action")
    }
    private static let nativeActions: Set<String> = ["add_profile", "switch_profile", "delete_profile", "set_parental", "set_ranking_prefs", "report_progress", "mark_watched", "reset_watched", "remove_from_continue_watching", "merge_watch_state", "merge_watch_document", "link_resume_identity", "get_state", "bind_sync_scope", "merge_native_sync", "patch_profile", "rebind_profile_account", "install_addon", "remove_addon", "reorder_addons", "add_library_item", "remove_library_item"]
    private func addonOwner(for state: VortxJSON) -> String? {
        guard let active = string(state["activeProfileId"]),
              let binding = state["roster"]?["profiles"]?[active]?["addons"],
              [.string("own"), .string("share_primary")].contains(binding) else { return nil }
        return binding == .string("share_primary") ? session.scope.ownerProfileID : active
    }
    /// CoreBridge verifies the fetched response before it reaches this adapter.  Revalidate the
    /// immutable transport identity and the manifest's required human/API identity here as well,
    /// because a raw Ctx action can otherwise bypass that async installer boundary.
    private func addonDescriptor(_ value: VortxJSON?) -> (url: String, addon: VortxJSON)? {
        guard let url = string(value?["transportUrl"]), addonMemberKey(url) != nil,
              let manifest = value?["manifest"], case .object = manifest,
              let id = string(manifest["id"]), !id.isEmpty, let name = string(manifest["name"]), !name.isEmpty else { return nil }
        return (url, .object(["transportUrl": .string(url), "manifest": manifest]))
    }
    /// Kernel membership keys fold only URL scheme and host. The descriptor keeps the original
    /// transport URL, including path and presentation casing, for actions and resource hosting.
    private func addonMemberKey(_ url: String) -> String? {
        guard var parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme; parts.host = host.lowercased()
        return parts.string
    }
    private func dispatchAddonMutation(subaction: String, args: VortxJSON?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, pendingProfileTransitions == 0, let state = values["native_state"], let owner = addonOwner(for: state) else {
            return fail("stale_or_invalid_addon_owner")
        }
        guard let current = installedAddonURLs(state: state, owner: owner) else { return fail("invalid_native_addon_inventory") }
        func raw(_ action: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(action), as: UTF8.self) }
        do {
            switch subaction {
            case "InstallAddon", "InstallAddonLocal":
                guard let descriptor = addonDescriptor(args), let identity = addonMemberKey(descriptor.url),
                      !current.contains(where: { addonMemberKey($0) == identity }) else {
                    return fail("invalid_or_duplicate_addon")
                }
                return enqueueMutation(type: "install_addon", raw: try raw(.object([
                    "type": .string("install_addon"), "profileId": .string(owner), "addon": descriptor.addon,
                ])))
            case "UninstallAddon", "UninstallAddonLocal":
                guard let descriptor = addonDescriptor(args), let identity = addonMemberKey(descriptor.url),
                      current.contains(where: { addonMemberKey($0) == identity }) else {
                    return fail("unknown_addon_identity")
                }
                return enqueueMutation(type: "remove_addon", raw: try raw(.object([
                    "type": .string("remove_addon"), "profileId": .string(owner), "transportUrl": .string(descriptor.url),
                ])))
            case "ReplaceAddon", "ReplaceAddonLocal":
                // Validate both immutable identities before queuing any removal.  `dispatch` runs
                // the whole list against one throwaway runtime, so an install/reorder failure leaves
                // the old membership, order and visible registry untouched.
                guard let old = addonDescriptor(args?["old"]), let new = addonDescriptor(args?["new"]),
                      let oldIdentity = addonMemberKey(old.url), let newIdentity = addonMemberKey(new.url),
                      let oldIndex = current.firstIndex(where: { addonMemberKey($0) == oldIdentity }),
                      (oldIdentity == newIdentity || !current.contains(where: { addonMemberKey($0) == newIdentity })) else {
                    return fail("invalid_addon_replacement")
                }
                var order = current; order[oldIndex] = new.url
                let install = VortxJSON.object(["type": .string("install_addon"), "profileId": .string(owner), "addon": new.addon])
                let remove = VortxJSON.object(["type": .string("remove_addon"), "profileId": .string(owner), "transportUrl": .string(old.url)])
                let reorder = VortxJSON.object(["type": .string("reorder_addons"), "profileId": .string(owner), "transportUrls": .array(order.map(VortxJSON.string))])
                // Case-only scheme/host changes address one kernel membership key. Remove that
                // key before installing its replacement; install-then-remove would tombstone the
                // newly written record and make the following canonical reorder fail.
                let actions = oldIdentity == newIdentity ? [remove, install, reorder] : [install, remove, reorder]
                return enqueueMutation(type: "replace_addon", raw: "", actions: try actions.map(raw))
            default: return fail("unsupported_addon_mutation")
            }
        } catch { return fail("invalid_addon_mutation") }
    }
    /// Resource registry omits profile-disabled add-ons. Kernel reorder requires every live
    /// owner-bucket identity exactly once, so mutation order comes from the unfiltered CRDT map.
    private func installedAddonURLs(state: VortxJSON, owner: String) -> [String]? {
        guard case .object(let records) = state["nativeSync"]?["addons"]?[owner]?["records"] else { return nil }
        let live = records.compactMap { key, record -> (String, String, UInt64)? in
            guard case .object = record["value"], let url = string(record["value"]?["transportUrl"]), addonMemberKey(url) == key,
                  let addedAt = try? record["addedAt"]?.decode(UInt64.self),
                  let removedAt = try? record["removedAt"]?.decode(UInt64.self), addedAt > removedAt else { return nil }
            return (key, url, addedAt)
        }
        let liveByKey = Dictionary(uniqueKeysWithValues: live.map { ($0.0, ($0.1, $0.2)) })
        guard liveByKey.count == live.count else { return nil }
        // CRDT order retains removed identities. Mirror the kernel: retain only still-live ids,
        // then append live records which have not yet entered the retained order.
        let order = (state["nativeSync"]?["addons"]?[owner]?["order"]?["ids"]?.array?.compactMap(string) ?? [])
            .filter { liveByKey[$0] != nil }
        let ordered = Set(order)
        let remaining = live.filter { !ordered.contains($0.0) }
            .sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }.map(\.0)
        return order.compactMap { liveByKey[$0]?.0 } + remaining.compactMap { liveByKey[$0]?.0 }
    }
    private func acceptedMetadataInventory(metaID: String, type: String) -> [String]? {
        guard let detail = values["meta_details"], detail["selected"]?["metaPath"]?["id"] == .string(metaID),
              detail["selected"]?["metaPath"]?["type"] == .string(type) else { return nil }
        let ready = detail["metaItems"]?.array?.compactMap { $0["content"]?["content"] }.first {
            $0["id"] == .string(metaID) && $0["type"] == .string(type)
        }
        guard let ready else { return nil }
        let inventory = ready["videos"]?.array?.compactMap { string($0["id"]) }.filter { !$0.isEmpty } ?? []
        return inventory.isEmpty ? nil : inventory
    }
    private func catalogDefinition(_ request: VortxResourceRequest, addon: VortxResourceAddon) -> VortxJSON? {
        addon.manifest?["catalogs"]?.array?.first { $0["id"] == .string(request.id) && $0["type"] == .string(request.type) }
    }
    private func validCatalogRequest(_ request: VortxResourceRequest, addon: VortxResourceAddon) -> Bool {
        guard request.resource == .catalog, let definition = catalogDefinition(request, addon: addon),
              request.extra.allSatisfy({ $0.count == 2 }), Set(request.extra.map { $0[0] }).count == request.extra.count else { return false }
        let extras = definition["extra"]?.array ?? []
        let supported = Set(extras.compactMap { string($0["name"]) } + (definition["extraSupported"]?.array ?? []).compactMap { string($0) })
        guard request.extra.allSatisfy({ supported.contains($0[0]) }),
              extras.filter({ $0["isRequired"] == .bool(true) }).allSatisfy({ definition in request.extra.contains { .string($0[0]) == definition["name"] } }) else { return false }
        for extra in request.extra {
            if extra[0] == "skip", UInt64(extra[1]) == nil { return false }
            if let options = extras.first(where: { $0["name"] == .string(extra[0]) })?["options"]?.array,
               !options.contains(.string(extra[1])) { return false }
        }
        return true
    }
    private func catalogRequest(_ addon: VortxResourceAddon, _ request: VortxResourceRequest) -> VortxJSON {
        .object(["base": .string(addon.transportUrl), "path": (try? VortxResourceProjection.path(request)) ?? .null])
    }
    private func nextCatalogPage(_ pages: [VortxJSON]) -> (VortxResourceAddon, VortxResourceRequest)? {
        guard let last = pages.last, last["content"]?["type"] == .string("Ready"),
              let items = last["content"]?["content"]?.array, !items.isEmpty,
              let request = try? path(last["request"]?["path"]),
              let addon = registrySnapshot.first(where: { .string($0.transportUrl) == last["request"]?["base"] }),
              let definition = catalogDefinition(request, addon: addon),
              (definition["extra"]?.array ?? []).contains(where: { $0["name"] == .string("skip") }) || (definition["extraSupported"]?.array ?? []).contains(.string("skip")) else { return nil }
        let offset = request.extra.first(where: { $0.first == "skip" }).flatMap { UInt64($0[1]) } ?? 0
        let (next, overflow) = offset.addingReportingOverflow(UInt64(items.count))
        guard !overflow else { return nil }
        let result = VortxResourceRequest(resource: .catalog, type: request.type, id: request.id,
                                         extra: request.extra.filter { $0.first != "skip" } + [["skip", String(next)]])
        return validCatalogRequest(result, addon: addon) ? (addon, result) : nil
    }
    private func discoverProjection(pages: [VortxJSON], chosen: (VortxResourceAddon, VortxResourceRequest),
                                    requests: [(VortxResourceAddon, VortxResourceRequest)]) -> VortxJSON {
        var seenTypes = Set<String>()
        let types = requests.compactMap { item -> VortxJSON? in
            guard seenTypes.insert(item.1.type).inserted else { return nil }
            return .object(["type": .string(item.1.type), "selected": .bool(item.1.type == chosen.1.type), "request": catalogRequest(item.0, item.1)])
        }
        let catalogs = requests.filter { $0.1.type == chosen.1.type }.map { item -> VortxJSON in
            .object(["catalog": catalogDefinition(item.1, addon: item.0)?["name"] ?? .string(item.1.id),
                     "selected": .bool(item.0.id == chosen.0.id && item.1.id == chosen.1.id), "request": catalogRequest(item.0, item.1)])
        }
        let extras = (catalogDefinition(chosen.1, addon: chosen.0)?["extra"]?.array ?? []).compactMap { definition -> VortxJSON? in
            guard let name = string(definition["name"]), !["skip", "search"].contains(name),
                  let options = definition["options"]?.array else { return nil }
            let candidates: [VortxJSON] = (definition["isRequired"] == .bool(true) ? [] : [.null]) + options
            let selected = chosen.1.extra.first { $0.first == name }.map { VortxJSON.string($0[1]) } ?? .null
            let choices = candidates.map { value -> VortxJSON in
                var extra = chosen.1.extra.filter { $0.first != name && $0.first != "skip" }
                if let value = string(value) { extra.append([name, value]) }
                let request = VortxResourceRequest(resource: .catalog, type: chosen.1.type, id: chosen.1.id, extra: extra)
                return .object(["value": value, "selected": .bool(value == selected), "request": catalogRequest(chosen.0, request)])
            }
            return .object(["name": .string(name), "options": .array(choices)])
        }
        let next = nextCatalogPage(pages).map { VortxJSON.object(["request": catalogRequest($0.0, $0.1)]) } ?? .null
        return .object(["catalog": .array(pages), "selectable": .object(["types": .array(types), "catalogs": .array(catalogs), "extra": .array(extras), "next_page": next])])
    }
    private func loadingEntry(_ addon: VortxResourceAddon, _ request: VortxResourceRequest) throws -> VortxJSON {
        .object(["request": .object(["base": .string(addon.transportUrl), "path": try VortxResourceProjection.path(request)]), "content": .object(["type": .string("Loading")])])
    }
    private func catalogRequests(extra: [[String]], type: String?) -> [(VortxResourceAddon, VortxResourceRequest)] {
        registrySnapshot.flatMap { addon in
            (addon.manifest?["catalogs"]?.array ?? []).compactMap { catalog in
                guard let id = string(catalog["id"]), let kind = string(catalog["type"]), type == nil || type == kind else { return nil }
                let supported = Set((catalog["extra"]?.array ?? []).compactMap { string($0["name"]) } + (catalog["extraSupported"]?.array ?? []).compactMap { string($0) })
                guard extra.allSatisfy({ $0.count == 2 && supported.contains($0[0]) }) else { return nil }
                let required = (catalog["extra"]?.array ?? []).filter { $0["isRequired"] == .bool(true) }.compactMap { string($0["name"]) }
                guard required.allSatisfy({ name in extra.contains { $0.first == name } }) else { return nil }
                return (addon, VortxResourceRequest(resource: .catalog, type: kind, id: id, extra: extra))
            }
        }
    }
    private func projectedLibraryItems(_ state: VortxJSON) throws -> [VortxJSON] {
        guard let active = string(state["activeProfileId"]), let library = state["libraries"]?[active] else { throw VortxNativeError.invalidSnapshot }
        return (library["items"]?.array ?? []).filter { $0["kind"] == .string("standard") }.compactMap { item -> VortxJSON? in
            guard let id = string(item["id"]), let type = string(item["type"]) else { return nil }
            // Exact native selected-unit projection, never max(old episode offsets). A saved
            // membership without watch evidence stays unwatched and out of Continue Watching.
            let resume = playback?["continueWatching"]?.array?.first { $0["metaId"] == .string(id) }
            let offset = resume?["offsetMs"] ?? .integer(0)
            let duration = resume?["durationMs"] ?? .integer(0)
            let watched = playback?["watchedTitles"]?[id] ?? .integer(0)
            return .object(["_id": .string(id), "type": .string(type), "name": item["name"] ?? .string(id), "poster": item["poster"] ?? .null,
                            "state": .object(["timeOffset": offset, "duration": duration,
                                              "video_id": resume?["videoId"] ?? .null, "lastWatched": isoTimestamp(resume?["updatedAt"]),
                                              "flaggedWatched": watched, "timesWatched": watched])])
        }
    }
    private func libraryProjection(state: VortxJSON, request: VortxJSON?) -> VortxJSON? {
        let requestedType: String?
        switch request?["type"] {
        case nil, .some(.null): requestedType = nil
        case .some(.string(let type)) where !type.isEmpty: requestedType = type
        default: return nil
        }
        let sort: String
        switch request?["sort"] {
        case nil: sort = "lastwatched"
        case .some(.string(let value)): sort = value
        default: return nil
        }
        guard ["lastwatched", "name", "namereverse", "timeswatched", "watched", "notwatched"].contains(sort),
              request?["page"] == nil || request?["page"] == .integer(1),
              let all = try? projectedLibraryItems(state) else { return nil }
        var availableTypes = Array(Set(all.compactMap { string($0["type"]) })).sorted()
        if let requestedType, !availableTypes.contains(requestedType) { availableTypes.append(requestedType); availableTypes.sort() }
        var rows = all.enumerated().map { (index: $0.offset, row: $0.element) }
        if let requestedType { rows.removeAll { string($0.row["type"]) != requestedType } }
        func watched(_ row: VortxJSON) -> Bool { (try? row["state"]?["flaggedWatched"]?.decode(UInt64.self)) ?? 0 > 0 }
        func count(_ row: VortxJSON) -> UInt64 { (try? row["state"]?["timesWatched"]?.decode(UInt64.self)) ?? 0 }
        switch sort {
        case "name": rows.sort { let left = string($0.row["name"]) ?? ""; let right = string($1.row["name"]) ?? ""; return left == right ? $0.index < $1.index : left.localizedCaseInsensitiveCompare(right) == .orderedAscending }
        case "namereverse": rows.sort { let left = string($0.row["name"]) ?? ""; let right = string($1.row["name"]) ?? ""; return left == right ? $0.index < $1.index : left.localizedCaseInsensitiveCompare(right) == .orderedDescending }
        case "timeswatched": rows.sort { count($0.row) == count($1.row) ? $0.index < $1.index : count($0.row) > count($1.row) }
        case "watched": rows.removeAll { !watched($0.row) }
        case "notwatched": rows.removeAll { watched($0.row) }
        default: break // Preserve the kernel's current native order for most-recent.
        }
        func option(_ type: String?, selected: Bool) -> VortxJSON {
            .object(["type": type.map(VortxJSON.string) ?? .null, "selected": .bool(selected),
                     "request": .object(["type": type.map(VortxJSON.string) ?? .null, "sort": .string(sort), "page": .integer(1)])])
        }
        let types = [option(nil, selected: requestedType == nil)] + availableTypes.map { option($0, selected: requestedType == $0) }
        let sorts = ["lastwatched", "name", "namereverse", "timeswatched", "watched", "notwatched"].map {
            VortxJSON.object(["sort": .string($0), "selected": .bool($0 == sort),
                              "request": .object(["type": requestedType.map(VortxJSON.string) ?? .null, "sort": .string($0), "page": .integer(1)])])
        }
        return .object(["catalog": .array(rows.map(\.row)), "selectable": .object(["types": .array(types), "sorts": .array(sorts)])])
    }
    private func localSearchProjection(state: VortxJSON, query: String, maxResults: Int) -> VortxJSON? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, let rows = try? projectedLibraryItems(state) else { return nil }
        let matches = rows.filter { row in
            (string(row["name"]) ?? "").localizedCaseInsensitiveContains(needle) ||
            (string(row["_id"]) ?? "").localizedCaseInsensitiveContains(needle)
        }.prefix(maxResults).compactMap { row -> VortxJSON? in
            guard let id = string(row["_id"]), let name = string(row["name"]), let type = string(row["type"]) else { return nil }
            return .object(["id": .string(id), "name": .string(name), "type": .string(type), "poster": row["poster"] ?? .null, "releaseInfo": .null])
        }
        return .object(["searchResults": .array(Array(matches))])
    }
    private func stateFields(_ state: VortxJSON) throws -> [String: VortxJSON] {
        let projected = try projectedLibraryItems(state)
        let descriptors = (lock.withLock { resourceRegistryValid ? registry : [] }).map { addon in VortxJSON.object(["transportUrl": .string(addon.transportUrl), "manifest": addon.manifest ?? .object([:])]) }
        var fields: [String: VortxJSON] = ["native_state": state, "ctx": .object(["profile": .object(["addons": .array(descriptors)])]),
                "native_playback": playback ?? .null,
                "continue_watching_preview": .object(["items": .array((playback?["continueWatching"]?.array ?? []).compactMap(playbackRow))]),
                "native_history": .object(["items": .array((playback?["history"]?.array ?? []).compactMap(playbackRow))]),
                "library": libraryProjection(state: state, request: libraryRequest) ?? .object(["catalog": .array(projected), "selectable": .object(["types": .array([]), "sorts": .array([])])])]
        if let detail = values["meta_details"] { fields["meta_details"] = metaWithPlayback(detail, library: projected) }
        return fields
    }
    private func metaWithPlayback(_ detail: VortxJSON, library: [VortxJSON]) -> VortxJSON {
        guard case .object(var fields) = detail, let id = string(detail["selected"]?["metaPath"]?["id"]) else { return detail }
        fields["libraryItem"] = library.first { $0["_id"] == .string(id) } ?? .null
        fields["watchedVideoIds"] = playback?["watchedVideoIdsByTitle"]?[id] ?? .array([])
        return .object(fields)
    }
    private func isoTimestamp(_ value: VortxJSON?) -> VortxJSON {
        guard let seconds = try? value?.decode(UInt64.self), seconds <= 253_402_300_799 else { return .null }
        return .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds))))
    }
    private func playbackRow(_ row: VortxJSON) -> VortxJSON? {
        guard let id = string(row["metaId"]), let type = string(row["type"]), !type.isEmpty,
              let offset = try? row["offsetMs"]?.decode(UInt64.self), let duration = try? row["durationMs"]?.decode(UInt64.self),
              let count = try? row["timesWatched"]?.decode(UInt64.self), case .bool(let watched) = row["watched"] else { return nil }
        return .object(["_id": .string(id), "type": .string(type), "name": row["name"] ?? .string(id), "poster": row["poster"] ?? .null,
                        "state": .object(["timeOffset": .unsigned(offset), "duration": .unsigned(duration),
                                          "video_id": row["videoId"] ?? .null, "lastWatched": isoTimestamp(row["updatedAt"]),
                                          "flaggedWatched": .integer(watched ? 1 : 0), "timesWatched": .unsigned(count)])])
    }
}
