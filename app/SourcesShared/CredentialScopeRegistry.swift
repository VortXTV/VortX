import Foundation

// M3 (INS-260722-06R v2, RESOLVED = PER-ACCOUNT): one typed, process-wide CURRENT credential owner scope,
// shared by every named credential store (ApiKeys, TraktAuth, SIMKLAuth, MediaServerStore, IPTVPlaylistStore,
// ProfileSync's import flag; DebridKeys carries its own richer envelope on the same typed scope). The scope is
// bound SYNCHRONOUSLY on the main actor at restore, adopt (sign-in / register / recover / QR), and sign-out,
// in the same turn as `beginCredentialSessionMutation`, so no mutation owner can observe a half-switched scope.

/// Lock-protected holder of the current owner scope plus a monotonic bind generation. The lock exists so
/// NONISOLATED readers (auth-store actors capturing their owner at operation entry, `ApiKeys`' static
/// accessors on network paths) get a consistent (scope, generation) pair without hopping to the main actor;
/// every WRITER is main-actor isolated, which serializes binds with all main-actor mutation owners.
final class CredentialScopeRegistry: @unchecked Sendable {
    static let shared = CredentialScopeRegistry()

    private let lock = NSLock()
    private var scope: DebridOwnerScope = .signedOutDevice
    private var generation: UInt64 = 0

    /// A captured (scope, generation) pair. Equality means "the exact same bind epoch": a sign-out and
    /// re-bind of the SAME scope still advances the generation, so a stale capture never reads as current.
    struct Capture: Equatable, Sendable {
        let scope: DebridOwnerScope
        let generation: UInt64
        var namespace: String { scope.storageNamespace }
    }

    func capture() -> Capture {
        lock.lock()
        defer { lock.unlock() }
        return Capture(scope: scope, generation: generation)
    }

    func currentNamespace() -> String {
        lock.lock()
        defer { lock.unlock() }
        return scope.storageNamespace
    }

    func isCurrent(_ captured: Capture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return captured.scope == scope && captured.generation == generation
    }

    /// Bind the current owner scope. Main-actor only: the bind is one synchronous turn with the session
    /// mutation that caused it, so scope readers on the main actor never see scope and session disagree.
    @MainActor
    @discardableResult
    func bind(_ newScope: DebridOwnerScope) -> Capture {
        lock.lock()
        scope = newScope
        generation &+= 1
        let captured = Capture(scope: newScope, generation: generation)
        lock.unlock()
        return captured
    }
}

/// H6 (INS-260722-06R v2 SPLIT, honoring signed REQ-23) for the single-slot credential stores that gained
/// per-account scope in M3 (Trakt / SIMKL / ApiKeys / media-server / IPTV slots). Mirrors the semantics of
/// `DebridCredentialMigration` exactly, on plain Keychain slots:
///
///   UNOWNED GLOBAL legacy slot -> claim-and-DELETE-FIRST, or fail closed. A one-owner claim marker (no
///   credential value inside) is written and verified BEFORE the source is touched, so an interrupted move
///   can never be re-claimed by a different owner after relaunch; the source is then deleted BEFORE the
///   destination write, so two owners can never both hold the credential; the destination write is verified
///   by exact readback, and a readback mismatch is a fail-closed loss (never a re-created global source).
enum CredentialLegacyClaim {
    struct Marker: Codable, Equatable {
        static let currentFormat = 1
        let format: Int
        let ownerNamespace: String
        let sourceAccount: String

        init(ownerNamespace: String, sourceAccount: String) {
            format = Self.currentFormat
            self.ownerNamespace = ownerNamespace
            self.sourceAccount = sourceAccount
        }
    }

    enum Result: Equatable {
        case noSource
        case targetPresent
        case migrated
        case claimWriteFailed
        case claimConflict
        case claimedByOtherOwner
        case sourceLostAfterClaim
        case targetReadbackMismatch
    }

    private static func encode(_ marker: Marker) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(marker) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ raw: String) -> Marker? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Claim `sourceAccount` (an unowned pre-scoping global slot) for `ownerNamespace` and move its value
    /// into `destinationAccount` (that owner's scoped slot), delete-source-first per REQ-23.
    @discardableResult
    static func claimGlobalSlot(
        sourceAccount: String,
        destinationAccount: String,
        claimMarkerAccount: String,
        ownerNamespace: String,
        read: (String) -> String? = Keychain.string,
        write: (String?, String) -> Void = { value, account in _ = Keychain.set(value, for: account) },
        provenanceTag: String? = nil
    ) -> Result {
        let expected = Marker(ownerNamespace: ownerNamespace, sourceAccount: sourceAccount)
        if let raw = read(claimMarkerAccount) {
            guard let existing = decode(raw), existing.format == Marker.currentFormat else {
                return .claimConflict
            }
            guard existing.ownerNamespace == ownerNamespace else { return .claimedByOtherOwner }
            guard existing == expected else { return .claimConflict }
        } else {
            // No claim yet. Only mint one when there is actually a value to move: an empty source with no
            // claim is a plain no-op, so a device that never held the legacy slot never records a claim.
            guard let probe = read(sourceAccount), !probe.isEmpty else { return .noSource }
            guard let encoded = encode(expected) else { return .claimWriteFailed }
            write(encoded, claimMarkerAccount)
            guard read(claimMarkerAccount) == encoded else { return .claimWriteFailed }
        }

        // The destination already holds a value for this owner: the move is complete (or the owner authored
        // its own). Remove a still-present source so the credential can never be claimed twice.
        if let target = read(destinationAccount), !target.isEmpty {
            if read(sourceAccount)?.isEmpty == false {
                write(nil, sourceAccount)
            }
            return .targetPresent
        }

        guard let source = read(sourceAccount), !source.isEmpty else {
            // Claimed, but the source is gone and the destination is empty: an earlier interrupted move.
            // Fail closed (the claim stops any OTHER owner from ever adopting a reappearing value).
            return .sourceLostAfterClaim
        }

        // REQ-23 ordering: DELETE THE SOURCE FIRST (the claim moment for the value itself), then write the
        // destination, then verify by exact readback. A failed destination write or readback mismatch is a
        // fail-closed loss of the credential, never a second claimable copy.
        write(nil, sourceAccount)
        write(source, destinationAccount)
        guard read(destinationAccount) == source else {
            CredentialProvenance.record(
                event: "legacy-claim.readback-mismatch",
                ownerNamespace: ownerNamespace,
                detail: provenanceTag ?? sourceAccount
            )
            return .targetReadbackMismatch
        }
        if let provenanceTag {
            CredentialProvenance.record(
                event: "legacy-claim.migrated",
                ownerNamespace: ownerNamespace,
                detail: provenanceTag
            )
        }
        return .migrated
    }
}

extension CredentialLegacyClaim {
    /// Whole-SET variant of `claimGlobalSlot` for token sets whose slots only make sense together (the
    /// Trakt access/refresh/expiry/createdAt quad, the SIMKL access/expiry pair). ONE marker, keyed to the
    /// primary (first) slot, governs the set; the primary slot's value gates the move. Ordering per REQ-23:
    /// claim marker (verified) -> delete EVERY legacy source FIRST -> write every scoped destination ->
    /// exact readback of every written destination. A readback mismatch is a fail-closed loss.
    @discardableResult
    static func claimGlobalSlotSet(
        slots: [(source: String, destination: String)],
        claimMarkerAccount: String,
        ownerNamespace: String,
        read: (String) -> String? = Keychain.string,
        write: (String?, String) -> Void = { value, account in _ = Keychain.set(value, for: account) },
        provenanceTag: String? = nil
    ) -> Result {
        guard let primary = slots.first else { return .noSource }
        let expected = Marker(ownerNamespace: ownerNamespace, sourceAccount: primary.source)
        if let raw = read(claimMarkerAccount) {
            guard let existing = decode(raw), existing.format == Marker.currentFormat else {
                return .claimConflict
            }
            guard existing.ownerNamespace == ownerNamespace else { return .claimedByOtherOwner }
            guard existing == expected else { return .claimConflict }
        } else {
            guard let probe = read(primary.source), !probe.isEmpty else { return .noSource }
            guard let encoded = encode(expected) else { return .claimWriteFailed }
            write(encoded, claimMarkerAccount)
            guard read(claimMarkerAccount) == encoded else { return .claimWriteFailed }
        }

        if let target = read(primary.destination), !target.isEmpty {
            // The owner already holds a scoped set: single-claim semantics remove any lingering sources.
            for slot in slots where read(slot.source)?.isEmpty == false {
                write(nil, slot.source)
            }
            return .targetPresent
        }

        let values = slots.map { read($0.source) }
        guard let primaryValue = values[0], !primaryValue.isEmpty else { return .sourceLostAfterClaim }

        // Delete EVERY source first (the claim moment), then write, then verify.
        for slot in slots { write(nil, slot.source) }
        for (index, slot) in slots.enumerated() {
            if let value = values[index], !value.isEmpty { write(value, slot.destination) }
        }
        for (index, slot) in slots.enumerated() {
            guard let value = values[index], !value.isEmpty else { continue }
            guard read(slot.destination) == value else {
                CredentialProvenance.record(
                    event: "legacy-claim.readback-mismatch",
                    ownerNamespace: ownerNamespace,
                    detail: provenanceTag ?? slot.source
                )
                return .targetReadbackMismatch
            }
        }
        if let provenanceTag {
            CredentialProvenance.record(
                event: "legacy-claim.migrated",
                ownerNamespace: ownerNamespace,
                detail: provenanceTag
            )
        }
        return .migrated
    }
}

/// H5 (INS-260722-06R): immutable provenance for destructive credential transactions, recorded at COMMIT
/// time in the same synchronous turn as the mutation it describes. Device-local (never synced: the key lives
/// under the `vortx.sync.` prefix SettingsBackup excludes), append-only with a hard cap, and it NEVER
/// contains a credential value: only an event name, the owner namespace, a wall-clock stamp, and a
/// non-secret detail tag.
enum CredentialProvenance {
    private static let key = "vortx.sync.credentialProvenance.v1"
    private static let maxEntries = 256

    static func record(event: String, ownerNamespace: String, detail: String = "") {
        var entries = (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
        entries.append([
            "event": event,
            "owner": ownerNamespace,
            "detail": detail,
            "at": Date().timeIntervalSince1970,
        ])
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        UserDefaults.standard.set(entries, forKey: key)
    }

    /// Read-only view for diagnostics and tests.
    static func entries() -> [[String: Any]] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
    }
}
