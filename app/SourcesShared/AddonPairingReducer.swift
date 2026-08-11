import Foundation

// MARK: - Shared QR pairing contracts

/// The one canonical identity rule shared by QR delivery dedupe and the normal add-on installer.
/// Fragments are never part of an add-on identity; queries are preserved because they can carry an
/// add-on's configured tenant/token. The manifest suffix is checked on the path, not on the whole URL,
/// so a query ending in "manifest.json" cannot bypass normalization.
func canonicalAddonIdentity(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty else { return nil }

    components.scheme = scheme
    components.host = host.lowercased()
    components.fragment = nil

    var path = components.path
    if !path.lowercased().hasSuffix("/manifest.json") {
        if path.isEmpty {
            path = "/manifest.json"
        } else if path.hasSuffix("/") {
            path += "manifest.json"
        } else {
            path += "/manifest.json"
        }
    }
    components.path = path
    return components.url?.absoluteString
}

/// Convert a remote revision to a bounded, non-negative integer without allowing NaN, infinity, or an
/// out-of-range value to trap the app. Missing, negative, and non-finite values are treated as revision 0.
func safeRevision(_ value: Double?) -> Int {
    guard let value, value.isFinite, value > 0 else { return 0 }
    if value >= Double(Int.max) { return Int.max }
    return Int(value)
}

/// Confirmed result returned by the hardened CoreBridge install path.
enum AddonInstallOutcome: Equatable {
    case installed
    case alreadyInstalled
    case failed(retryable: Bool, message: String)
}

/// Result returned by the manifest preview path used before an automatic install.
enum AddonPreviewOutcome: Equatable {
    case ready(name: String)
    case alreadyInstalled(name: String)
    case rejected(retryable: Bool, message: String)
}

// MARK: - Reducer

/// Pure decision core for Install by QR. The original beta API (`delivered`, `resolved`, `installFinished`)
/// remains available for existing hosts. The durable API (`deliveries`, `installFinishedAttempt`,
/// `sessionClosed`) is the path used by the hardened QR view.
enum AddonPairingReducer {

    // MARK: State

    enum DeliveryStatus: String, Equatable {
        case pending
        case installed
        case failed
    }

    /// Relay-minted identity for one phone submission. `id` is stable across polls and session-token
    /// rotation; `identity` is the canonical manifest URL used for local dedupe.
    struct Delivery: Equatable {
        let id: String
        let url: String
        let identity: String
        let sessionToken: String
        let revision: Int
        let deliveryRevision: Int
        let status: DeliveryStatus
        let attempt: Int
        let retryable: Bool
        let claimed: Bool

        init(id: String, url: String, identity: String, sessionToken: String,
             revision: Int = 0, status: DeliveryStatus = .pending,
             deliveryRevision: Int = 0, attempt: Int = 0, retryable: Bool = false,
             claimed: Bool = false) {
            self.id = id
            self.url = url
            self.identity = identity
            self.sessionToken = sessionToken
            self.revision = max(0, revision)
            self.deliveryRevision = max(0, deliveryRevision)
            self.status = status
            self.attempt = max(0, attempt)
            self.retryable = retryable
            self.claimed = claimed
        }
    }

    enum AckStatus: String, Equatable {
        case installed
        case failed
    }

    /// One visible submission. Legacy rows derive their ID from session + identity; durable rows use the
    /// relay delivery ID and retain attempt/revision/ack metadata for stale-result protection.
    struct Row: Identifiable, Equatable {
        let sessionToken: String
        let url: String
        let identity: String
        var name: String?
        var state: RowState
        let deliveryID: String?
        var revision: Int
        var deliveryRevision: Int
        var attempt: Int
        var acked: AckStatus?
        var authoritySession: String?
        var authorityGeneration: Int?

        init(sessionToken: String, url: String, identity: String, name: String?, state: RowState,
             deliveryID: String? = nil, revision: Int = 0, deliveryRevision: Int = 0,
             attempt: Int = 0, acked: AckStatus? = nil,
             authoritySession: String? = nil, authorityGeneration: Int? = nil) {
            self.sessionToken = sessionToken
            self.url = url
            self.identity = identity
            self.name = name
            self.state = state
            self.deliveryID = deliveryID
            self.revision = max(0, revision)
            self.deliveryRevision = max(0, deliveryRevision)
            self.attempt = max(0, attempt)
            self.acked = acked
            self.authoritySession = authoritySession
            self.authorityGeneration = authorityGeneration
        }

        static func makeId(sessionToken: String, identity: String) -> String {
            sessionToken + "\u{1}" + identity
        }

        var id: String {
            if let deliveryID, !deliveryID.isEmpty { return deliveryID }
            return Self.makeId(sessionToken: sessionToken, identity: identity)
        }

        var isDurable: Bool { deliveryID != nil }
    }

    enum RowState: Equatable {
        case resolving
        case ready
        case invalid
        case installing
        case installed
        case failed(String)

        var isInFlight: Bool {
            switch self {
            case .resolving, .ready, .installing: return true
            case .invalid, .installed, .failed: return false
            }
        }

        var isManualActionable: Bool {
            switch self {
            case .ready, .failed: return true
            default: return false
            }
        }
    }

    struct PendingAck: Equatable {
        let deliveryID: String
        let token: String
        let status: AckStatus
        var attempt: Int
        var revision: Int
        var deliveryRevision: Int
        let retryable: Bool
        var authoritySession: String
        var authorityGeneration: Int
        var mutationID: String
        var dispatched: Bool
        var requiresClaim: Bool
        /// A failed claim response is ambiguous: the relay may have committed the claim before the response was
        /// lost. Suppress direct ACK retries until a poll supplies the authoritative attempt/revision again.
        var awaitingPoll: Bool
    }

    struct State: Equatable {
        var rows: [Row] = []
        /// Legacy once-only dispatch guard. Durable rows use `attempt` as the authority, but retain this set
        /// for the beta API and for old tests/hosts.
        var autoInstalled: Set<String> = []
        /// Highest accepted relay revision for the current live session.
        var latestRevision: Int = 0
        /// Closed sessions remain in the reducer until all local work drains.
        var closedSessions: Set<String> = []
        /// Sticky release fence: late poll/results cannot resurrect a released session.
        var releasedSessions: Set<String> = []
        /// Release requests are server mutations. Keep them pending until the relay confirms `released:true`.
        var releasingSessions: Set<String> = []
        /// Stable release mutation ids make an ambiguous release retry idempotent within this app lifetime.
        var releaseMutationIDs: [String: String] = [:]
        /// Highest server delivery revision durably acknowledged for each delivery ID. A delivery ID may be
        /// reused by a later transactional replacement, so the ID alone is not a permanent duplicate fence.
        var acknowledgedDeliveryRevisions: [String: Int] = [:]
        /// New delivery IDs for a URL whose canonical row is still resolving/installing.
        var pendingDuplicateDeliveries: [String: [Delivery]] = [:]
        /// Durable rows whose failure can be retried locally. The row state stays the beta `.failed(String)`
        /// shape so existing UI and public behavior remain unchanged.
        var retryableFailures: Set<String> = []
        /// Acknowledgements are queued until the relay confirms the network mutation. `dispatched == false`
        /// means the next poll/resume may re-enqueue the request after an ACK transport failure; `awaitingPoll`
        /// is the stronger claim-response-loss fence and suppresses direct re-enqueue until reconciliation.
        var pendingAcks: [String: PendingAck] = [:]
        /// Claim requests are server-fenced and retried from the next poll after transport failure.
        var claimingDeliveryIDs: Set<String> = []
        /// Authority tuple sent to the relay claim/ack routes. A fresh view gets a fresh id; generation changes
        /// when in-flight work is resumed under a new authority.
        var authoritySession: String = ""
        var authorityGeneration: Int = 0

        func isSessionReleased(_ token: String) -> Bool { releasedSessions.contains(token) }
        func isInFlight(sessionToken: String) -> Bool {
            rows.contains { row in
                row.sessionToken == sessionToken &&
                    (row.state.isInFlight || retryableFailures.contains(row.id))
            } || pendingAcks.values.contains { $0.token == sessionToken } ||
                releasingSessions.contains(sessionToken)
        }
    }

    /// Fence a claim completion before it can become a reducer event. `stop()` can only cancel the task
    /// cooperatively, so a non-cancellable await may still return after the view has moved to a new generation.
    /// The pending mutation and authority must still be the exact claim request that produced the response.
    static func canDispatchAckClaimCompletion(
        _ state: State,
        deliveryID: String,
        authoritySession: String,
        authorityGeneration: Int,
        mutationID: String,
        expectedGeneration: Int,
        currentGeneration: Int,
        taskIsCancelled: Bool
    ) -> Bool {
        guard !taskIsCancelled,
              currentGeneration == expectedGeneration,
              let pending = state.pendingAcks[deliveryID],
              pending.mutationID == mutationID,
              pending.authoritySession == authoritySession,
              pending.authorityGeneration == authorityGeneration,
              pending.requiresClaim,
              !pending.awaitingPoll else { return false }
        return true
    }

    // MARK: Events / effects

    enum ResolveOutcome: Equatable {
        case invalid
        case ready(name: String)
        case alreadyInstalled(name: String)
        /// Durable preview failure. Retryability is kept separate from the user-facing message so a
        /// transient transport failure remains recoverable while a validation/SSRF rejection is terminal.
        case rejected(retryable: Bool, message: String)
    }

    enum InstallOutcome: Equatable {
        case installed
        case failed(String)
        case failedWithRetry(retryable: Bool, message: String)

        /// Convenience spelling for hosts that want to construct the richer failure with a labeled case.
        static func failed(retryable: Bool, message: String) -> InstallOutcome {
            .failedWithRetry(retryable: retryable, message: message)
        }
    }

    /// A preview result is valid only for the exact durable delivery tuple that started it. A delivery ID can be
    /// reused by a higher-revision replacement, so the ID alone is not enough to fence a late URL-A completion.
    struct ResolveTicket: Equatable {
        let rowID: String
        let revision: Int
        let deliveryRevision: Int
        let identity: String
    }

    enum Event {
        /// Beta compatibility path: URL-only relay payloads are keyed by session + canonical identity.
        case delivered(urls: [String], sessionToken: String, liveToken: String?)
        /// Durable path: the whole poll is bound to the live token and monotonic relay revision.
        case deliveries([Delivery], sessionToken: String, liveToken: String?, revision: Int)
        case resolved(rowId: String, outcome: ResolveOutcome)
        case resolvedDurable(ticket: ResolveTicket, outcome: ResolveOutcome)
        case installFinished(rowId: String, outcome: InstallOutcome)
        /// Confirmed result for a specific install attempt. Results from older attempts are ignored.
        case installFinishedAttempt(rowId: String, attempt: Int, outcome: InstallOutcome)
        /// The relay claim is the server authority for the install attempt. Local preview success is not enough
        /// to start an install; the attempt returned here must match the later confirmed outcome.
        case claimFinished(rowId: String, authoritySession: String, authorityGeneration: Int,
                           attempt: Int, deliveryRevision: Int, success: Bool)
        /// Network acknowledgement result. Only `success == true` commits `acked` / duplicate state.
        case ackFinished(deliveryID: String, token: String, status: AckStatus,
                         authoritySession: String, authorityGeneration: Int,
                         attempt: Int, deliveryRevision: Int, revision: Int, retryable: Bool,
                         mutationID: String, success: Bool)
        /// Claim phase for an acknowledgement. A failed claim is not an ACK transport failure: it leaves the
        /// pending mutation fenced until a poll rebases it, while a proven claim permits the exact ACK mutation.
        case ackClaimFinished(deliveryID: String, token: String,
                              authoritySession: String, authorityGeneration: Int,
                              attempt: Int, deliveryRevision: Int,
                              mutationID: String, success: Bool)
        /// Explicit retry hook used after a bounded network retry or on the next lifecycle poll.
        case retryPendingAck(deliveryID: String)
        /// Closed-session lifecycle tick: re-enqueue failed claims/ACKs and retry an unconfirmed release.
        case retryPendingWork(sessionToken: String)
        /// The relay release mutation is the authoritative close fence.
        case releaseFinished(sessionToken: String, success: Bool)
        /// A sheet reopen / replacement creates a new local authority and re-queues canceled in-flight work.
        case authorityChanged(session: String, generation: Int)
        case manualInstall(rowId: String)
        case sessionRotated(liveToken: String)
        /// Phone-side Done/close observed. Release is emitted only after in-flight rows drain.
        case sessionClosed(sessionToken: String)
    }

    enum Effect: Equatable {
        case resolve(rowId: String, url: String)
        case resolveDurable(ticket: ResolveTicket, url: String)
        case install(rowId: String, url: String)
        case claim(deliveryID: String, token: String, deliveryRevision: Int, authoritySession: String,
                   authorityGeneration: Int)
        case installAttempt(rowId: String, url: String, attempt: Int)
        /// A claim response is ambiguous on transport failure; re-poll before minting/retrying an ACK.
        case poll(token: String, authoritySession: String, authorityGeneration: Int)
        case ack(deliveryID: String, token: String, status: AckStatus,
                 authoritySession: String, authorityGeneration: Int,
                 attempt: Int, deliveryRevision: Int, revision: Int, retryable: Bool,
                 mutationID: String, requiresClaim: Bool)
        case releaseSession(token: String, authoritySession: String, authorityGeneration: Int, mutationID: String)
    }

    // MARK: Transition

    static func reduce(_ state: inout State, _ event: Event, normalize: (String) -> String?) -> [Effect] {
        switch event {
        case let .delivered(urls, sessionToken, liveToken):
            return reduceLegacyDelivery(&state, urls: urls, sessionToken: sessionToken,
                                        liveToken: liveToken, normalize: normalize)

        case let .deliveries(deliveries, sessionToken, liveToken, revision):
            guard sessionToken == liveToken,
                  !sessionToken.isEmpty,
                  !state.releasedSessions.contains(sessionToken),
                  revision >= state.latestRevision else { return [] }
            state.latestRevision = max(state.latestRevision, revision)
            var effects: [Effect] = []
            for delivery in deliveries where delivery.sessionToken == sessionToken &&
                !delivery.id.isEmpty && delivery.id.count <= 512 {
                guard delivery.revision >= state.latestRevision || delivery.revision == 0 else { continue }
                effects += ingest(&state, delivery: delivery, normalize: normalize)
            }
            effects += flushPendingClaims(&state)
            effects += flushPendingAcks(&state)
            effects += maybeRelease(&state)
            return effects

        case let .resolved(rowId, outcome):
            return reduceResolved(&state, rowId: rowId, outcome: outcome)

        case let .resolvedDurable(ticket, outcome):
            return reduceResolved(&state, rowId: ticket.rowID, outcome: outcome, ticket: ticket)

        case let .installFinished(rowId, outcome):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }) else { return [] }
            // Durable callers must use the attempt-tagged event. Accepting an untagged late result would
            // reintroduce the exact stale-retry race this reducer is hardening against.
            if state.rows[idx].isDurable {
                guard state.rows[idx].state == .installing else { return [] }
                return finishDurableAttempt(&state, index: idx, attempt: state.rows[idx].attempt, outcome: outcome)
            }
            switch outcome {
            case .installed:
                state.rows[idx].state = .installed
            case let .failed(message):
                state.rows[idx].state = .failed(message)
            case let .failedWithRetry(_, message):
                state.rows[idx].state = .failed(message)
            }
            return []

        case let .installFinishedAttempt(rowId, attempt, outcome):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }),
                  state.rows[idx].isDurable,
                  state.rows[idx].state == .installing,
                  state.rows[idx].attempt == attempt else { return [] }
            return finishDurableAttempt(&state, index: idx, attempt: attempt, outcome: outcome)

        case let .claimFinished(rowId, authoritySession, authorityGeneration, attempt, deliveryRevision, success):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }),
                  state.rows[idx].isDurable,
                  state.rows[idx].state == .ready,
                  state.claimingDeliveryIDs.contains(rowId),
                  (state.authoritySession.isEmpty || state.authoritySession == authoritySession),
                  state.authorityGeneration == authorityGeneration,
                  deliveryRevision >= 0 else { return [] }
            state.claimingDeliveryIDs.remove(rowId)
            guard success,
                  attempt >= 1,
                  attempt >= state.rows[idx].attempt,
                  deliveryRevision >= state.rows[idx].deliveryRevision else { return [] }
            if state.authoritySession.isEmpty { state.authoritySession = authoritySession }
            state.rows[idx].attempt = attempt
            state.rows[idx].deliveryRevision = deliveryRevision
            state.rows[idx].authoritySession = authoritySession
            state.rows[idx].authorityGeneration = authorityGeneration
            state.rows[idx].state = .installing
            return [.installAttempt(rowId: rowId, url: state.rows[idx].url, attempt: state.rows[idx].attempt)]

        case let .ackFinished(deliveryID, token, status, authoritySession, authorityGeneration,
                              attempt, deliveryRevision, revision, retryable, mutationID, success):
            return finishAck(&state, deliveryID: deliveryID, token: token, status: status,
                             authoritySession: authoritySession, authorityGeneration: authorityGeneration,
                             attempt: attempt, deliveryRevision: deliveryRevision, revision: revision,
                             retryable: retryable, mutationID: mutationID, success: success)

        case let .ackClaimFinished(deliveryID, token, authoritySession, authorityGeneration,
                                   attempt, deliveryRevision, mutationID, success):
            return finishAckClaim(&state, deliveryID: deliveryID, token: token,
                                  authoritySession: authoritySession, authorityGeneration: authorityGeneration,
                                  attempt: attempt, deliveryRevision: deliveryRevision,
                                  mutationID: mutationID, success: success)

        case let .retryPendingAck(deliveryID):
            guard var pending = state.pendingAcks[deliveryID], !pending.dispatched, !pending.awaitingPoll else { return [] }
            pending.dispatched = true
            state.pendingAcks[deliveryID] = pending
            return [ackEffect(pending)]

        case let .retryPendingWork(sessionToken):
            guard !sessionToken.isEmpty,
                  state.closedSessions.contains(sessionToken),
                  !state.releasedSessions.contains(sessionToken) else { return [] }
            var effects = flushPendingClaims(&state)
            effects += flushPendingAcks(&state)
            effects += maybeRelease(&state)
            return effects

        case let .releaseFinished(sessionToken, success):
            guard state.releasingSessions.remove(sessionToken) != nil else { return [] }
            guard success else { return [] }
            state.releaseMutationIDs.removeValue(forKey: sessionToken)
            state.releasedSessions.insert(sessionToken)
            return []

        case let .authorityChanged(session, generation):
            return requeueForAuthorityChange(&state, session: session, generation: generation)

        case let .manualInstall(rowId):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }),
                  state.rows[idx].state.isManualActionable else { return [] }
            if let deliveryID = state.rows[idx].deliveryID,
               var pending = state.pendingAcks[deliveryID] {
                // Retry is a serialized operation. Never delete an ACK whose network request or claim phase is
                // still live: an old failed ACK can commit first and advance the relay delivery revision, making
                // a same-attempt installed ACK stale. Once the request has settled without confirmation, replay
                // its exact mutation before permitting a new install/claim tuple.
                if pending.dispatched || pending.awaitingPoll { return [] }
                guard !pending.requiresClaim else { return [] }
                pending.dispatched = true
                state.pendingAcks[deliveryID] = pending
                return [ackEffect(pending)]
            }
            state.autoInstalled.insert(rowId)
            state.retryableFailures.remove(rowId)
            state.acknowledgedDeliveryRevisions.removeValue(forKey: rowId)
            state.rows[idx].acked = nil
            state.claimingDeliveryIDs.remove(rowId)
            let url = state.rows[idx].url
            if state.rows[idx].isDurable {
                // The relay owns attempt/revision. A manual retry must reclaim using the last known server
                // delivery revision and adopt the claim response; inventing a local attempt strands the ACK when
                // the relay idempotently returns the existing claim tuple.
                state.rows[idx].authoritySession = state.authoritySession.isEmpty
                    ? state.rows[idx].sessionToken : state.authoritySession
                state.rows[idx].authorityGeneration = state.authorityGeneration
                state.rows[idx].state = .ready
                return beginDurableClaim(&state, index: idx)
            }
            state.rows[idx].attempt += 1
            state.rows[idx].state = .installing
            return [.install(rowId: rowId, url: url)]

        case let .sessionRotated(liveToken):
            state.rows.removeAll { $0.sessionToken != liveToken && $0.state.isInFlight }
            let liveIDs = Set(state.rows.compactMap(\.deliveryID))
            state.pendingAcks = state.pendingAcks.filter { $0.value.token == liveToken && liveIDs.contains($0.key) }
            state.claimingDeliveryIDs = state.claimingDeliveryIDs.filter { liveIDs.contains($0) }
            state.pendingDuplicateDeliveries = state.pendingDuplicateDeliveries.mapValues { deliveries in
                deliveries.filter { $0.sessionToken == liveToken }
            }.filter { !$0.value.isEmpty }
            state.latestRevision = 0
            return []

        case let .sessionClosed(sessionToken):
            guard !sessionToken.isEmpty else { return [] }
            state.closedSessions.insert(sessionToken)
            return maybeRelease(&state)
        }
    }

    // MARK: Durable ingest

    private static func resolveEffect(for row: Row) -> Effect {
        guard row.isDurable else { return .resolve(rowId: row.id, url: row.url) }
        return .resolveDurable(
            ticket: ResolveTicket(rowID: row.id,
                                  revision: row.revision,
                                  deliveryRevision: row.deliveryRevision,
                                  identity: row.identity),
            url: row.url
        )
    }

    private static func ingest(_ state: inout State, delivery: Delivery,
                               normalize: (String) -> String?) -> [Effect] {
        if let acknowledgedRevision = state.acknowledgedDeliveryRevisions[delivery.id],
           delivery.deliveryRevision <= acknowledgedRevision {
            return []
        }
        if let existingIDIndex = state.rows.firstIndex(where: { $0.id == delivery.id }) {
            return reconcileRemoteDelivery(&state, index: existingIDIndex, delivery: delivery)
        }

        let normalized = normalize(delivery.url)
        let identity = normalized ?? delivery.identity
        guard !identity.isEmpty else { return [] }

        // A terminal canonical row can acknowledge a second relay delivery without creating a second install
        // row. That duplicate ACK is keyed by the delivery ID, so reconcile it after URL validation but before
        // the canonical-row switch below; replacement polls are authoritative even when their URL no longer
        // matches the installed canonical row.
        if state.pendingAcks[delivery.id] != nil {
            return reconcilePendingDuplicateAck(&state, delivery: delivery, identity: identity, normalized: normalized)
        }

        if let existingIndex = state.rows.firstIndex(where: { $0.identity == identity }) {
            let existing = state.rows[existingIndex]
            switch existing.state {
            case .installed:
                if delivery.status == .installed {
                    acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
                    return []
                }
                return ackDuplicate(&state, delivery: delivery, status: .installed, attempt: existing.attempt)
            case .invalid:
                return ackDuplicate(&state, delivery: delivery, status: .failed, attempt: existing.attempt)
            case .failed:
                if state.retryableFailures.contains(existing.id) {
                    stashDuplicate(&state, delivery: delivery, identity: identity)
                    return []
                }
                return ackDuplicate(&state, delivery: delivery, status: .failed, attempt: existing.attempt)
            case .resolving, .installing:
                stashDuplicate(&state, delivery: delivery, identity: identity)
                return []
            case .ready:
                guard existing.isDurable else {
                    stashDuplicate(&state, delivery: delivery, identity: identity)
                    return []
                }
                return beginDurableClaim(&state, index: existingIndex)
            }
        }

        let row = Row(sessionToken: delivery.sessionToken,
                      url: delivery.url,
                      identity: identity,
                      name: nil,
                      state: normalized == nil ? .invalid : .resolving,
                      deliveryID: delivery.id,
                      revision: delivery.revision,
                      deliveryRevision: delivery.deliveryRevision,
                      attempt: delivery.attempt)

        // A terminal status is trusted only after the URL itself is valid. The relay's terminal status is the
        // durable restart record; the app never marks a freshly dispatched install terminal until its own
        // confirmed result arrives.
        if normalized == nil {
            state.rows.append(row)
            state.retryableFailures.remove(delivery.id)
            return ackForRow(&state, index: state.rows.count - 1, status: .failed, requiresClaim: true)
        }

        switch delivery.status {
        case .pending:
            state.rows.append(row)
            if delivery.retryable {
                state.rows[state.rows.count - 1].state = .failed("Previous install failed")
                state.retryableFailures.insert(delivery.id)
                return []
            }
            return [resolveEffect(for: row)]
        case .installed:
            var restored = row
            restored.state = .installed
            restored.acked = .installed
            state.rows.append(restored)
            acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
            return []
        case .failed:
            var restored = row
            restored.state = .failed("Previous install failed")
            restored.acked = delivery.retryable ? nil : .failed
            state.rows.append(restored)
            if delivery.retryable {
                state.retryableFailures.insert(delivery.id)
            } else {
                acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
            }
            return []
        }
    }

    private static func reconcilePendingDuplicateAck(_ state: inout State,
                                                     delivery: Delivery,
                                                     identity: String,
                                                     normalized: String?) -> [Effect] {
        guard state.rows.firstIndex(where: { $0.id == delivery.id }) == nil,
              var pending = state.pendingAcks[delivery.id] else { return [] }
        // Both the per-delivery revision and the enclosing poll revision are server authorities. A stale poll
        // must not rewind a rowless pending ACK merely because its URL or status is otherwise well formed.
        guard delivery.deliveryRevision >= pending.deliveryRevision,
              delivery.revision >= pending.revision else { return [] }

        let matchesInstalledCanonical = normalized != nil && state.rows.contains { row in
            row.sessionToken == delivery.sessionToken &&
                row.state == .installed &&
                row.identity == identity
        }
        if !matchesInstalledCanonical && delivery.status == .pending && !delivery.retryable {
            // A changed normalized identity is a new install, even when the relay reused the delivery ID. Fence
            // the old rowless ACK before materializing the exact newer delivery tuple; a late ACK completion then
            // fails the pending-mutation guard instead of publishing the old installed result.
            guard delivery.deliveryRevision > pending.deliveryRevision else { return [] }
            state.pendingAcks.removeValue(forKey: delivery.id)
            state.claimingDeliveryIDs.remove(delivery.id)
            state.retryableFailures.remove(delivery.id)
            let row = Row(sessionToken: delivery.sessionToken,
                          url: delivery.url,
                          identity: identity,
                          name: nil,
                          state: normalized == nil ? .invalid : .resolving,
                          deliveryID: delivery.id,
                          revision: delivery.revision,
                          deliveryRevision: delivery.deliveryRevision,
                          attempt: delivery.attempt)
            state.rows.append(row)
            let index = state.rows.count - 1
            guard normalized != nil else {
                return ackForRow(&state, index: index, status: .failed, requiresClaim: true)
            }
            switch delivery.status {
            case .pending:
                if delivery.retryable {
                    state.rows[index].state = .failed("Previous install failed")
                    state.retryableFailures.insert(delivery.id)
                    return maybeRelease(&state)
                }
                return [resolveEffect(for: row)]
            case .installed:
                state.rows[index].state = .installed
                state.rows[index].acked = .installed
                acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
                return maybeRelease(&state)
            case .failed:
                state.rows[index].state = .failed("Previous install failed")
                state.rows[index].acked = delivery.retryable ? nil : .failed
                if delivery.retryable {
                    state.retryableFailures.insert(delivery.id)
                } else {
                    acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
                }
                return maybeRelease(&state)
            }
        }

        if delivery.status == .installed {
            guard pending.status == .installed else { return [] }
            state.pendingAcks.removeValue(forKey: delivery.id)
            acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
            return maybeRelease(&state)
        }

        if delivery.status == .failed {
            // The relay has already committed a terminal failed result and cleared the foreign claim. There is
            // no local row to mark failed: remove only this delivery-ID ACK, retain the canonical installed row,
            // and let close/release drain exactly once. Retryable failures are represented as pending by the
            // relay contract and therefore never cross this terminal branch.
            guard !delivery.retryable else { return [] }
            state.pendingAcks.removeValue(forKey: delivery.id)
            state.claimingDeliveryIDs.remove(delivery.id)
            acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
            return maybeRelease(&state)
        }

        guard delivery.status == .pending,
              !delivery.retryable,
              pending.awaitingPoll ||
              delivery.deliveryRevision > pending.deliveryRevision ||
              (delivery.claimed && pending.requiresClaim) else { return [] }

        pending.attempt = delivery.attempt
        pending.revision = delivery.revision
        pending.deliveryRevision = delivery.deliveryRevision
        if !state.authoritySession.isEmpty {
            pending.authoritySession = state.authoritySession
            pending.authorityGeneration = state.authorityGeneration
        }
        pending.mutationID = newMutationID()
        pending.dispatched = true
        pending.requiresClaim = true
        pending.awaitingPoll = false
        state.pendingAcks[delivery.id] = pending
        return [ackEffect(pending)]
    }

    private static func reconcileRemoteDelivery(_ state: inout State, index: Int,
                                                delivery: Delivery) -> [Effect] {
        guard state.rows[index].deliveryID == delivery.id else { return [] }
        let current = state.rows[index]
        guard delivery.deliveryRevision >= current.deliveryRevision else { return [] }

        // A higher delivery revision is normally a server claim/retry, but a changed URL at a higher revision
        // is a transactional phone-side replacement. Replace the row atomically so an old install completion can
        // never ACK the new URL; the old row's pending ACK/claim fences are discarded with the old revision.
        if delivery.deliveryRevision > current.deliveryRevision &&
            (delivery.url != current.url || delivery.identity != current.identity) {
            state.pendingAcks.removeValue(forKey: delivery.id)
            state.claimingDeliveryIDs.remove(delivery.id)
            state.retryableFailures.remove(delivery.id)
            state.acknowledgedDeliveryRevisions.removeValue(forKey: delivery.id)
            var replacement = Row(sessionToken: delivery.sessionToken,
                                   url: delivery.url,
                                   identity: delivery.identity,
                                   name: nil,
                                   state: delivery.status == .pending && !delivery.retryable ? .resolving : .failed("Previous install failed"),
                                   deliveryID: delivery.id,
                                   revision: delivery.revision,
                                   deliveryRevision: delivery.deliveryRevision,
                                   attempt: delivery.attempt)
            switch delivery.status {
            case .pending where !delivery.retryable:
                state.rows[index] = replacement
                return [resolveEffect(for: replacement)]
            case .pending, .failed:
                if !delivery.retryable { replacement.acked = .failed }
                state.rows[index] = replacement
                if delivery.retryable {
                    state.retryableFailures.insert(delivery.id)
                } else {
                    acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
                }
                return maybeRelease(&state)
            case .installed:
                replacement.state = .installed
                replacement.acked = .installed
                state.rows[index] = replacement
                acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
                return maybeRelease(&state)
            }
        }

        guard delivery.url == current.url, delivery.identity == current.identity else { return [] }

        // A reopen or ambiguous claim response can leave a pending ACK behind the relay's newer claim. Rebase the
        // row and ACK outcome from the exact poll first. The relay does not disclose claim ownership, so even a
        // claimed poll must require a fresh local-authority claim; preserve the local install result while the
        // view proves that claim. This prevents either a foreign claim or a lost claim response from publishing an
        // old ACK, and avoids re-resolving/reinstalling an already confirmed local result.
        if let existing = state.pendingAcks[delivery.id],
           delivery.status == .pending,
           !delivery.retryable,
           delivery.attempt >= existing.attempt,
           delivery.deliveryRevision > current.deliveryRevision || existing.awaitingPoll ||
           (delivery.claimed && existing.requiresClaim) {
            var rebased = existing
            rebased.attempt = delivery.attempt
            rebased.revision = delivery.revision
            rebased.deliveryRevision = delivery.deliveryRevision
            if !state.authoritySession.isEmpty {
                rebased.authoritySession = state.authoritySession
                rebased.authorityGeneration = state.authorityGeneration
            }
            rebased.mutationID = newMutationID()
            rebased.dispatched = true
            rebased.requiresClaim = true
            rebased.awaitingPoll = false
            state.pendingAcks[delivery.id] = rebased
            state.rows[index].revision = delivery.revision
            state.rows[index].attempt = rebased.attempt
            state.rows[index].deliveryRevision = rebased.deliveryRevision
            state.rows[index].authoritySession = rebased.authoritySession
            state.rows[index].authorityGeneration = rebased.authorityGeneration
            return [ackEffect(rebased)]
        }

        state.rows[index].deliveryRevision = max(state.rows[index].deliveryRevision, delivery.deliveryRevision)
        state.rows[index].revision = max(state.rows[index].revision, delivery.revision)
        if delivery.attempt > state.rows[index].attempt {
            state.rows[index].attempt = delivery.attempt
            if state.rows[index].state == .installing {
                state.rows[index].state = .resolving
                state.rows[index].authoritySession = nil
                state.rows[index].authorityGeneration = nil
                state.claimingDeliveryIDs.remove(delivery.id)
                state.pendingAcks.removeValue(forKey: delivery.id)
                return [resolveEffect(for: state.rows[index])]
            }
        }

        switch delivery.status {
        case .installed:
            state.rows[index].state = .installed
            state.rows[index].acked = .installed
            state.retryableFailures.remove(delivery.id)
            state.claimingDeliveryIDs.remove(delivery.id)
            state.pendingAcks.removeValue(forKey: delivery.id)
            acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
            return maybeRelease(&state)
        case .failed:
            // A server-confirmed failure is terminal for this attempt but remains manually retryable. Do not let a
            // stale, lower-attempt poll overwrite a newer local install attempt.
            guard delivery.attempt >= state.rows[index].attempt || state.rows[index].state != .installing else { return [] }
            state.rows[index].state = .failed("Previous install failed")
            state.rows[index].acked = delivery.retryable ? nil : .failed
            if delivery.retryable {
                state.retryableFailures.insert(delivery.id)
            } else {
                state.retryableFailures.remove(delivery.id)
            }
            state.claimingDeliveryIDs.remove(delivery.id)
            state.pendingAcks.removeValue(forKey: delivery.id)
            if delivery.retryable {
                state.acknowledgedDeliveryRevisions.removeValue(forKey: delivery.id)
            } else {
                acknowledge(&state, deliveryID: delivery.id, deliveryRevision: delivery.deliveryRevision)
            }
            return maybeRelease(&state)
        case .pending:
            if delivery.retryable {
                state.rows[index].state = .failed("Previous install failed")
                state.rows[index].acked = nil
                state.retryableFailures.insert(delivery.id)
                state.claimingDeliveryIDs.remove(delivery.id)
                state.pendingAcks.removeValue(forKey: delivery.id)
                return maybeRelease(&state)
            }
            if state.rows[index].state == .ready && state.rows[index].isDurable {
                return beginDurableClaim(&state, index: index)
            }
            return []
        }
    }

    private static func beginDurableClaim(_ state: inout State, index: Int) -> [Effect] {
        guard state.rows[index].isDurable,
              state.rows[index].state == .ready,
              let deliveryID = state.rows[index].deliveryID,
              !state.claimingDeliveryIDs.contains(deliveryID) else { return [] }
        state.claimingDeliveryIDs.insert(deliveryID)
        let authority = state.authoritySession.isEmpty ? state.rows[index].sessionToken : state.authoritySession
        return [.claim(deliveryID: deliveryID,
                       token: state.rows[index].sessionToken,
                       deliveryRevision: state.rows[index].deliveryRevision,
                       authoritySession: authority,
                       authorityGeneration: state.authorityGeneration)]
    }

    private static func flushPendingClaims(_ state: inout State) -> [Effect] {
        var effects: [Effect] = []
        for index in state.rows.indices where state.rows[index].state == .ready && state.rows[index].isDurable {
            effects += beginDurableClaim(&state, index: index)
        }
        return effects
    }

    private static func acknowledge(_ state: inout State, deliveryID: String, deliveryRevision: Int) {
        let revision = max(0, deliveryRevision)
        state.acknowledgedDeliveryRevisions[deliveryID] = max(
            state.acknowledgedDeliveryRevisions[deliveryID] ?? -1,
            revision
        )
    }

    private static func newMutationID() -> String { UUID().uuidString }

    private static func ackEffect(_ pending: PendingAck) -> Effect {
        .ack(deliveryID: pending.deliveryID,
             token: pending.token,
             status: pending.status,
             authoritySession: pending.authoritySession,
             authorityGeneration: pending.authorityGeneration,
             attempt: pending.attempt,
             deliveryRevision: pending.deliveryRevision,
             revision: pending.revision,
             retryable: pending.retryable,
             mutationID: pending.mutationID,
             requiresClaim: pending.requiresClaim)
    }

    private static func flushPendingAcks(_ state: inout State) -> [Effect] {
        var effects: [Effect] = []
        for deliveryID in state.pendingAcks.keys.sorted() {
            guard var pending = state.pendingAcks[deliveryID], !pending.dispatched, !pending.awaitingPoll else { continue }
            pending.dispatched = true
            state.pendingAcks[deliveryID] = pending
            effects.append(ackEffect(pending))
        }
        return effects
    }

    private static func finishAckClaim(_ state: inout State, deliveryID: String, token: String,
                                       authoritySession: String, authorityGeneration: Int,
                                       attempt: Int, deliveryRevision: Int,
                                       mutationID: String, success: Bool) -> [Effect] {
        guard var pending = state.pendingAcks[deliveryID],
              pending.token == token,
              pending.authoritySession == authoritySession,
              pending.authorityGeneration == authorityGeneration,
              pending.requiresClaim,
              !pending.awaitingPoll,
              pending.mutationID == mutationID else { return [] }

        if !success {
            // The server may have committed the claim before its response was lost. Keep the old attempt/revision
            // untouched and wait for a poll to tell us whether the claim is ours, foreign, or absent.
            pending.dispatched = false
            pending.awaitingPoll = true
            state.pendingAcks[deliveryID] = pending
            return [.poll(token: token, authoritySession: authoritySession, authorityGeneration: authorityGeneration)]
        }

        guard attempt >= 1,
              deliveryRevision >= pending.deliveryRevision else { return [] }

        pending.attempt = attempt
        pending.deliveryRevision = deliveryRevision
        pending.dispatched = true
        pending.requiresClaim = false
        pending.awaitingPoll = false
        state.pendingAcks[deliveryID] = pending
        if let index = state.rows.firstIndex(where: { $0.deliveryID == deliveryID }) {
            state.rows[index].attempt = attempt
            state.rows[index].deliveryRevision = deliveryRevision
            state.rows[index].authoritySession = authoritySession
            state.rows[index].authorityGeneration = authorityGeneration
        }
        return []
    }

    private static func finishAck(_ state: inout State, deliveryID: String, token: String,
                                 status: AckStatus, authoritySession: String, authorityGeneration: Int,
                                 attempt: Int, deliveryRevision: Int, revision: Int, retryable: Bool,
                                 mutationID: String,
                                 success: Bool) -> [Effect] {
        guard var pending = state.pendingAcks[deliveryID],
              pending.token == token,
              pending.status == status,
              pending.authoritySession == authoritySession,
              pending.authorityGeneration == authorityGeneration,
              attempt >= pending.attempt,
              deliveryRevision >= pending.deliveryRevision,
              pending.revision == revision,
              pending.retryable == retryable,
              pending.mutationID == mutationID else { return [] }

        // An ACK cannot commit while its claim phase is unresolved. A stale caller that bypasses the explicit
        // claim event is ignored rather than being allowed to turn an ambiguous claim into a terminal result.
        guard !pending.requiresClaim else {
            if !success {
                pending.dispatched = false
                pending.awaitingPoll = true
                state.pendingAcks[deliveryID] = pending
            }
            return []
        }

        if !success {
            pending.attempt = attempt
            pending.deliveryRevision = deliveryRevision
            pending.dispatched = false
            // Keep the same mutation id for an ambiguous transport result. If the relay committed the ACK
            // before the response was lost, its durable replay record returns the accepted report on retry.
            // A later authority change deliberately mints a new id and requires a fresh claim.
            pending.awaitingPoll = false
            state.pendingAcks[deliveryID] = pending
            return []
        }

        state.pendingAcks.removeValue(forKey: deliveryID)
        if !retryable {
            acknowledge(&state, deliveryID: deliveryID, deliveryRevision: deliveryRevision)
        }
        if let index = state.rows.firstIndex(where: { $0.deliveryID == deliveryID }) {
            state.rows[index].attempt = max(state.rows[index].attempt, attempt)
            state.rows[index].deliveryRevision = max(state.rows[index].deliveryRevision, deliveryRevision)
            if retryable {
                state.rows[index].acked = nil
                state.retryableFailures.insert(deliveryID)
            } else {
                state.rows[index].acked = status
                state.retryableFailures.remove(deliveryID)
            }
        }
        return maybeRelease(&state)
    }

    private static func requeueForAuthorityChange(_ state: inout State, session: String,
                                                  generation: Int) -> [Effect] {
        guard !session.isEmpty, generation >= 0 else { return [] }
        state.authoritySession = session
        state.authorityGeneration = generation
        state.claimingDeliveryIDs.removeAll()
        state.releasingSessions.removeAll()
        state.releaseMutationIDs.removeAll()
        for key in Array(state.pendingAcks.keys) {
            guard var pending = state.pendingAcks[key] else { continue }
            pending.authoritySession = session
            pending.authorityGeneration = generation
            pending.mutationID = newMutationID()
            pending.dispatched = false
            pending.requiresClaim = true
            pending.awaitingPoll = false
            state.pendingAcks[key] = pending
        }

        var effects: [Effect] = []
        for index in state.rows.indices where state.rows[index].isDurable {
            switch state.rows[index].state {
            case .resolving, .ready, .installing:
                state.rows[index].state = .resolving
                state.rows[index].authoritySession = nil
                state.rows[index].authorityGeneration = nil
                effects.append(resolveEffect(for: state.rows[index]))
            default:
                break
            }
        }
        effects += flushPendingAcks(&state)
        return effects
    }

    private static func reduceLegacyDelivery(_ state: inout State, urls: [String], sessionToken: String,
                                             liveToken: String?, normalize: (String) -> String?) -> [Effect] {
        guard sessionToken == liveToken else { return [] }
        var known = Set(state.rows.map(\.id))
        var effects: [Effect] = []
        for url in urls {
            let normalized = normalize(url)
            let identity = normalized ?? url
            let rowId = Row.makeId(sessionToken: sessionToken, identity: identity)
            guard !known.contains(rowId) else { continue }
            known.insert(rowId)
            if normalized == nil {
                state.rows.append(Row(sessionToken: sessionToken, url: url, identity: identity,
                                      name: nil, state: .invalid))
            } else {
                state.rows.append(Row(sessionToken: sessionToken, url: url, identity: identity,
                                      name: nil, state: .resolving))
                effects.append(.resolve(rowId: rowId, url: url))
            }
        }
        return effects
    }

    private static func reduceResolved(_ state: inout State, rowId: String,
                                        outcome: ResolveOutcome,
                                        ticket: ResolveTicket? = nil) -> [Effect] {
        guard let idx = state.rows.firstIndex(where: { $0.id == rowId }) else { return [] }
        let durable = state.rows[idx].isDurable
        // Durable previews must arrive through the tuple-bearing event. The row-id-only compatibility event is
        // intentionally limited to legacy URL batches; otherwise a late URL-A task could still publish onto a
        // same-ID URL-B replacement.
        guard !durable || ticket != nil else { return [] }
        if let ticket {
            guard durable,
                  ticket.rowID == rowId,
                  state.rows[idx].revision == ticket.revision,
                  state.rows[idx].deliveryRevision == ticket.deliveryRevision,
                  state.rows[idx].identity == ticket.identity else { return [] }
        }
        // A durable preview result belongs to the row's current resolving phase. Replayed or late preview
        // results must not rewind an installing/installed row and start a second attempt.
        if durable, state.rows[idx].state != .resolving { return [] }
        switch outcome {
        case .invalid:
            state.rows[idx].state = .invalid
            if durable {
                state.retryableFailures.remove(rowId)
                var effects = ackForRow(&state, index: idx, status: .failed, requiresClaim: true)
                effects += flushDuplicates(&state, identity: state.rows[idx].identity, status: .failed)
                effects += maybeRelease(&state)
                return effects
            }
            return []

        case let .rejected(retryable, message):
            state.rows[idx].state = .failed(message)
            if retryable { state.retryableFailures.insert(rowId) }
            else { state.retryableFailures.remove(rowId) }
            var effects: [Effect] = []
            if durable && !retryable {
                effects += ackForRow(&state, index: idx, status: .failed, requiresClaim: true)
            }
            effects += maybeRelease(&state)
            return effects

        case let .alreadyInstalled(name):
            state.rows[idx].name = name
            state.rows[idx].state = .installed
            guard durable else { return [] }
            state.retryableFailures.remove(rowId)
            var effects = ackForRow(&state, index: idx, status: .installed, requiresClaim: true)
            effects += flushDuplicates(&state, identity: state.rows[idx].identity, status: .installed)
            effects += maybeRelease(&state)
            return effects

        case let .ready(name):
            state.rows[idx].name = name
            state.rows[idx].state = .ready
            if durable { return beginDurableClaim(&state, index: idx) }
            return autoInstallIfEligible(&state, rowId: rowId)
        }
    }

    private static func autoInstallIfEligible(_ state: inout State, rowId: String) -> [Effect] {
        guard let idx = state.rows.firstIndex(where: { $0.id == rowId }),
              state.rows[idx].state == .ready,
              !state.autoInstalled.contains(rowId) else { return [] }
        state.autoInstalled.insert(rowId)
        state.rows[idx].state = .installing
        return [.install(rowId: rowId, url: state.rows[idx].url)]
    }

    private static func finishDurableAttempt(_ state: inout State, index: Int, attempt: Int,
                                             outcome: InstallOutcome) -> [Effect] {
        guard state.rows[index].attempt == attempt, state.rows[index].state == .installing else { return [] }
        let rowID = state.rows[index].id
        let identity = state.rows[index].identity
        switch outcome {
        case .installed:
            state.rows[index].state = .installed
            state.retryableFailures.remove(rowID)
            var effects = ackForRow(&state, index: index, status: .installed)
            effects += flushDuplicates(&state, identity: identity, status: .installed)
            effects += maybeRelease(&state)
            return effects
        case let .failed(message):
            state.rows[index].state = .failed(message)
            state.retryableFailures.remove(rowID)
            var effects = ackForRow(&state, index: index, status: .failed)
            effects += maybeRelease(&state)
            return effects
        case let .failedWithRetry(retryable, message):
            state.rows[index].state = .failed(message)
            if retryable {
                state.retryableFailures.insert(rowID)
            } else {
                state.retryableFailures.remove(rowID)
            }
            var effects: [Effect] = []
            effects += ackForRow(&state, index: index, status: .failed, retryable: retryable)
            effects += maybeRelease(&state)
            return effects
        }
    }

    // MARK: Durable ack / close helpers

    private static func ackForRow(_ state: inout State, index: Int, status: AckStatus,
                                  retryable: Bool = false, requiresClaim: Bool = false) -> [Effect] {
        guard let deliveryID = state.rows[index].deliveryID else { return [] }
        if state.rows[index].acked == status { return [] }
        if let existing = state.pendingAcks[deliveryID], existing.status == status,
           existing.retryable == retryable,
           existing.attempt == state.rows[index].attempt,
           existing.deliveryRevision == state.rows[index].deliveryRevision {
            guard !existing.dispatched, !existing.awaitingPoll else { return [] }
            var requeued = existing
            requeued.dispatched = true
            requeued.requiresClaim = existing.requiresClaim || requiresClaim
            state.pendingAcks[deliveryID] = requeued
            return [ackEffect(requeued)]
        }
        let authoritySession = state.rows[index].authoritySession ??
            (state.authoritySession.isEmpty ? state.rows[index].sessionToken : state.authoritySession)
        let pending = PendingAck(deliveryID: deliveryID,
                                 token: state.rows[index].sessionToken,
                                 status: status,
                                 attempt: state.rows[index].attempt,
                                 revision: state.rows[index].revision,
                                 deliveryRevision: state.rows[index].deliveryRevision,
                                 retryable: retryable,
                                 authoritySession: authoritySession,
                                 authorityGeneration: state.rows[index].authorityGeneration ?? state.authorityGeneration,
                                 mutationID: newMutationID(),
                                 dispatched: true,
                                 requiresClaim: requiresClaim,
                                 awaitingPoll: false)
        state.pendingAcks[deliveryID] = pending
        return [ackEffect(pending)]
    }

    private static func ackDuplicate(_ state: inout State, delivery: Delivery, status: AckStatus,
                                     attempt: Int) -> [Effect] {
        guard state.acknowledgedDeliveryRevisions[delivery.id].map({ delivery.deliveryRevision <= $0 }) != true,
              state.pendingAcks[delivery.id] == nil else { return [] }
        let authoritySession = state.authoritySession.isEmpty ? delivery.sessionToken : state.authoritySession
        let pending = PendingAck(deliveryID: delivery.id,
                                 token: delivery.sessionToken,
                                 status: status,
                                 attempt: max(0, attempt),
                                 revision: delivery.revision,
                                 deliveryRevision: delivery.deliveryRevision,
                                 retryable: false,
                                 authoritySession: authoritySession,
                                 authorityGeneration: state.authorityGeneration,
                                 mutationID: newMutationID(),
                                 dispatched: true,
                                 requiresClaim: true,
                                 awaitingPoll: false)
        state.pendingAcks[delivery.id] = pending
        return [ackEffect(pending)]
    }

    private static func stashDuplicate(_ state: inout State, delivery: Delivery, identity: String) {
        var pending = state.pendingDuplicateDeliveries[identity] ?? []
        guard !pending.contains(where: { $0.id == delivery.id }) else { return }
        pending.append(delivery)
        state.pendingDuplicateDeliveries[identity] = pending
    }

    private static func flushDuplicates(_ state: inout State, identity: String,
                                        status: AckStatus) -> [Effect] {
        guard let pending = state.pendingDuplicateDeliveries.removeValue(forKey: identity) else { return [] }
        return pending.flatMap { ackDuplicate(&state, delivery: $0, status: status, attempt: $0.attempt) }
    }

    private static func maybeRelease(_ state: inout State) -> [Effect] {
        var effects: [Effect] = []
        for token in state.closedSessions where !state.releasedSessions.contains(token) &&
            !state.releasingSessions.contains(token) {
            guard !state.isInFlight(sessionToken: token) else { continue }
            let authoritySession = state.authoritySession.isEmpty ? token : state.authoritySession
            let authorityGeneration = max(1, state.authorityGeneration)
            let mutationID = state.releaseMutationIDs[token] ?? newMutationID()
            state.releaseMutationIDs[token] = mutationID
            state.releasingSessions.insert(token)
            effects.append(.releaseSession(token: token,
                                           authoritySession: authoritySession,
                                           authorityGeneration: authorityGeneration,
                                           mutationID: mutationID))
        }
        return effects
    }

    // MARK: Pure batch / Done reductions

    enum BatchStatus: Equatable {
        case empty
        case working
        case allInstalled(Int)
        case partial(installed: Int, failed: Int, invalid: Int)
    }

    static func batchStatus(_ states: [RowState]) -> BatchStatus {
        guard !states.isEmpty else { return .empty }
        if states.contains(where: { $0.isInFlight }) { return .working }
        var installed = 0, failed = 0, invalid = 0
        for state in states {
            switch state {
            case .installed: installed += 1
            case .invalid: invalid += 1
            case .failed: failed += 1
            default: break
            }
        }
        if installed == states.count { return .allInstalled(installed) }
        return .partial(installed: installed, failed: failed, invalid: invalid)
    }

    static func doneState(_ status: BatchStatus) -> (title: String, enabled: Bool) {
        switch status {
        case .working: return ("Installing…", false)
        case .empty, .allInstalled, .partial: return ("Done", true)
        }
    }
}
