import Foundation

/// Foreground catch-up may merge a newer account document without replacing a certified
/// resident session. A failed pull is not permission to retire its resource selections.
enum NativeForegroundSyncPolicy {
    static func shouldPullBroadcast(version: Int, lastAcknowledgedVersion: Int, ownerIsCurrent: Bool) -> Bool {
        ownerIsCurrent && version > lastAcknowledgedVersion
    }

    /// Compare only authenticated, successfully joined exported carriers. NativeSync contains
    /// causal provenance, not device-local selectors/rolling counters; do not strip its fields.
    /// Structural values avoid JSON key-order/encoding noise. An equal join must not echo-upload.
    static func requiresCausalRepublish(pulledNative: VortxJSON?, pulledHost: VortxJSON?,
                                        joinedNative: VortxJSON, joinedHost: VortxJSON) -> Bool {
        joinedNative != pulledNative || joinedHost != pulledHost
    }
    /// A transport ACK covers only the edit generation captured before that upload. A failure
    /// or an edit accepted while the request suspends must remain queued for another export.
    struct PushQueue: Equatable {
        private(set) var generation: UInt64 = 0
        private(set) var hasPendingPush = false

        mutating func request() {
            generation &+= 1
            hasPendingPush = true
        }

        mutating func acknowledge(_ uploadedGeneration: UInt64, accepted: Bool) {
            guard accepted, uploadedGeneration == generation else { return }
            hasPendingPush = false
        }
    }

    @MainActor
    static func ensureSession(isCurrent: () -> Bool, hasCertifiedSession: () -> Bool,
                              settleResident: () async -> Void,
                              restore: () async -> Bool) async -> Bool {
        guard isCurrent() else { return false }
        if hasCertifiedSession() { return true }
        // A resident session with an admitted profile transaction temporarily cannot certify
        // a publication binding. Give its FIFO ownership back before deciding it needs replacement.
        await settleResident()
        guard isCurrent() else { return false }
        if hasCertifiedSession() { return true }
        let restored = await restore()
        return restored && isCurrent() && hasCertifiedSession()
    }

    /// Cold host/credential projection can run before a native session is attributable. Mounting
    /// it afterward is not an ACK: commit this exact pulled document and its host preferences under
    /// the still-current capture before acknowledging the cloud version.
    @MainActor
    static func mayAcknowledgeDocument(nativeDocumentCommitted: Bool, isCurrent: () -> Bool,
                                       ensureSession: () async -> Bool,
                                       commitDocument: () async -> Bool) async -> Bool {
        guard isCurrent() else { return false }
        guard nativeDocumentCommitted else {
            guard await ensureSession(), isCurrent() else { return false }
            return await commitDocument() && isCurrent()
        }
        return true
    }

    struct ResourceIntent: Sendable {
        let searchQuery: String?
        let metadataAction: Data?
        let metadataGeneration: UUID

        func searchToReplay(currentQuery: String?) -> String? {
            guard let searchQuery, searchQuery == currentQuery, searchQuery.count >= 2 else { return nil }
            return searchQuery
        }

        func metadataToReplay(currentGeneration: UUID) -> Data? {
            currentGeneration == metadataGeneration ? metadataAction : nil
        }

        func searchToReplay(currentQuery: String?, hasPendingSearch: Bool, pendingScopeIsCurrent: Bool) -> String? {
            if hasPendingSearch, pendingScopeIsCurrent { return currentQuery }
            return searchToReplay(currentQuery: currentQuery)
        }

        func metadataToReplay(currentAction: Data?, currentGeneration: UUID, pendingScopeIsCurrent: Bool) -> Data? {
            if let currentAction, pendingScopeIsCurrent { return currentAction }
            return metadataToReplay(currentGeneration: currentGeneration)
        }
    }

    enum ProgressIdentity: Equatable {
        case movie
        case episode(String)
        case reject
    }

    /// Episode-like media must carry an exact video identity. The title fallback used by
    /// PlaybackMeta cannot become an episode progress record in the kernel.
    static func progressIdentity(isEpisodic: Bool, libraryID: String, videoID: String) -> ProgressIdentity {
        guard isEpisodic else { return .movie }
        guard !videoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              videoID != libraryID else { return .reject }
        return .episode(videoID)
    }
}
