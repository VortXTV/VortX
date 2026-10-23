import Foundation
import CryptoKit

/// Foreground catch-up may merge a newer account document without replacing a certified
/// resident session. A failed pull is not permission to retire its resource selections.
enum NativeForegroundSyncPolicy {
    /// Failed checkpoint preparation is not repaired by repeating the same expensive
    /// import every few seconds. This controls attempts, never pending edits or authority.
    struct RecoveryBackoff: Equatable {
        private(set) var failures = 0
        private(set) var retryAt = Date.distantPast

        mutating func recordFailure(at now: Date) {
            failures = min(failures + 1, 4)
            retryAt = now.addingTimeInterval(min(12 * pow(2, Double(failures - 1)), 60))
        }

        func permitsAttempt(at now: Date, userInitiated: Bool) -> Bool {
            userInitiated || now >= retryAt
        }
    }
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
    ///
    /// Playback reports progress every few seconds, and every upload pulls, re-merges and re-encrypts
    /// the whole account document (megabytes, seconds of CPU). Progress-only work therefore waits until
    /// playback goes quiet (pause/exit) or `progressMaxWait` passes: other devices may see a position up
    /// to five minutes old while this one is still playing. Any other edit keeps the immediate cadence.
    struct PushQueue: Equatable {
        static let urgentDelay: TimeInterval = 2.5
        static let maxFailureBackoff: TimeInterval = 30
        /// Longer than the player's 20 s progress cadence (PlayerScreen), with room for a late tick. At 15 s
        /// every report outlived the quiet window, so continuous playback uploaded the whole account after each
        /// one (a Mac beta 2 log: 149 uploads for 145 reports). Playing now uploads once per `progressMaxWait`;
        /// a pause or stop, which ends the reports, uploads this long after the last one.
        static let progressQuiet: TimeInterval = 45
        static let progressMaxWait: TimeInterval = 300

        private(set) var generation: UInt64 = 0
        private(set) var hasPendingPush = false
        /// Latest generation carrying an edit other than playback progress.
        private var urgentGeneration: UInt64?
        /// First and latest progress reports not yet covered by an accepted upload.
        private var progressSince: Date?
        private var progressLatest: Date?

        var hasUrgentPush: Bool { urgentGeneration != nil }

        mutating func request(progressOnly: Bool = false, at now: Date = Date()) {
            generation &+= 1
            hasPendingPush = true
            if progressOnly {
                if progressSince == nil { progressSince = now }
                progressLatest = now
            } else {
                urgentGeneration = generation
            }
        }

        mutating func acknowledge(_ uploadedGeneration: UInt64, accepted: Bool) {
            guard accepted else { return }
            if let urgent = urgentGeneration, urgent <= uploadedGeneration { urgentGeneration = nil }
            guard uploadedGeneration == generation else {
                // Only progress reported during that upload remains; its window starts there.
                progressSince = progressLatest
                return
            }
            hasPendingPush = false
            progressSince = nil
            progressLatest = nil
        }

        /// Seconds until the next upload attempt, or nil when nothing is pending. A progress
        /// window never shortens the retry delay that follows a failed upload.
        func nextUploadDelay(now: Date, failureBackoff: TimeInterval?) -> TimeInterval? {
            guard hasPendingPush else { return nil }
            guard !hasUrgentPush, let since = progressSince, let latest = progressLatest else {
                return failureBackoff ?? Self.urgentDelay
            }
            let due = min(latest.addingTimeInterval(Self.progressQuiet), since.addingTimeInterval(Self.progressMaxWait))
            return max(due.timeIntervalSince(now), failureBackoff ?? 0)
        }

        static func nextFailureBackoff(after previous: TimeInterval?) -> TimeInterval {
            min((previous ?? urgentDelay) * 2, maxFailureBackoff)
        }
    }

    /// Converting the account's 0.4 data into the native engine (re-reading each linked Stremio account,
    /// rebuilding the import material, replaying it through the engine) took seconds on every sync and launch.
    /// Once a conversion completes this device remembers a fingerprint of the document's 0.4 fields and skips
    /// the conversion for as long as they still match: a change from an old app or the website flips it back
    /// on. A linked Stremio account changes outside the document, so with one present it is re-read after
    /// `linkedRefresh`.
    struct LegacyConversionRecord: Codable, Equatable {
        static let linkedRefresh: TimeInterval = 30 * 60

        let digest: String
        let convertedAt: Date

        enum Decision: String { case skip, first, changed, refresh }

        /// Fingerprint of the document's 0.4 fields exactly as pulled: every key but `excluded` (the carriers this
        /// device's own export rewrites), as sorted-key JSON. Those fields reach the device byte-for-byte as their
        /// writer left them, so the same account always hashes the same. The previous fingerprint hashed the
        /// credential-free archive, which re-encodes the settings backup's preference plist from a dictionary; its
        /// order differs per decode, so every pull looked changed and re-converted (0.5.4 Mac log: 32 conversions
        /// in 6 minutes, each also re-uploading the account). Nil when the fields are not JSON, which converts.
        static func digest(of document: [String: Any], excluding excluded: [String]) -> String? {
            var legacy = document
            for key in excluded { legacy.removeValue(forKey: key) }
            guard JSONSerialization.isValidJSONObject(legacy),
                  let body = try? JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            return SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        }

        static func decide(_ record: LegacyConversionRecord?, digest: String?, hasLinkedAccounts: Bool, now: Date) -> Decision {
            guard let record, let digest else { return .first }
            guard record.digest == digest else { return .changed }
            guard hasLinkedAccounts else { return .skip }
            let age = now.timeIntervalSince(record.convertedAt)
            guard age >= 0, age < linkedRefresh else { return .refresh }
            return .skip
        }
    }

    /// The while-active poll backs up the live sync socket, which announces another device's change as it lands.
    /// While the socket is answering (the worker replies to every 30 s keep-alive) a pull is due only every five
    /// minutes (owner, 2026-10-17). Each pull of a newer revision downloads and merges the whole account, and the
    /// device's own uploads (every progress save while watching) made the next poll do that again. Once the
    /// socket has been silent past two missed replies, every tick pulls as before so changes still flow.
    enum ActivePoll {
        static let liveSocketInterval: TimeInterval = 5 * 60
        static let socketSilenceLimit: TimeInterval = 75

        static func shouldPull(now: Date, lastPull: Date?, socketHeardAt: Date?) -> Bool {
            guard let socketHeardAt else { return true }
            let silence = now.timeIntervalSince(socketHeardAt)
            guard silence >= 0, silence < socketSilenceLimit, let lastPull else { return true }
            let since = now.timeIntervalSince(lastPull)
            return since < 0 || since >= liveSocketInterval
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
