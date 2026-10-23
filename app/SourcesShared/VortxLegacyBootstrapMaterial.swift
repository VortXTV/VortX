import Foundation
import CoreFoundation
import CryptoKit

/// Pure projection of a COMPLETE, authenticated, host-reconciled legacy account snapshot.
/// The caller supplies the resolved roster and actual owner UUID, and must atomically retain the
/// original encrypted document (including all preferences and unknown fields) beside the native
/// checkpoint and import receipt. This projection is never a replacement for that source document.
/// It does not read a profile store, credentials, defaults, the network, or the wall clock.
enum VortxLegacyBootstrapMaterial {
    struct ReconciliationRequired: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "Native migration reconciliation required: " + reason }
    }

    /// One source unit (a library row, add-on, intent, overlay entry or watch) the projection could
    /// not represent (issue #262). It is held, never fatal: the unit stays only in the retained
    /// original document, enters no native state, and every other unit still imports. A whole-account
    /// stop for one odd row locked users out of profiles, add-ons and sync together. The kind is a
    /// fixed code; the reason can name a source key, so scrub it before logging.
    struct Held: Sendable, Equatable {
        let kind: String
        let reason: String
    }

    /// The host must seal pending receipts with its authenticated source archive before committing
    /// this material. Pending receipts are neither installed membership nor acknowledged removals.
    struct Preparation: Sendable {
        let material: Data
        let pendingMembershipReceipts: Data?
        let pendingCount: Int
        let held: [Held]
    }

    /// Marks a row an own-account source view could not project, so the adapter holds just that row.
    fileprivate static let heldReasonKey = "vortxHeldReason"

    /// A one-line, value-free summary of held units for diagnostics: `kind:reason(count)` pairs.
    static func heldSummary(_ held: [Held]) -> String {
        let counts = Dictionary(grouping: held) { $0.kind + ":" + scrubbedReason($0.reason) }.mapValues(\.count)
        return counts.keys.sorted().map { $0 + "(" + String(counts[$0] ?? 0) + ")" }.joined(separator: ",")
    }

    /// A reconciliation reason as a diagnostics code. Reasons are fixed text plus, at most, a source
    /// key such as a profile UUID or video ID; any word that is not plain letters becomes `x`.
    static func scrubbedReason(_ reason: String) -> String {
        reason.split(separator: " ").map { word in
            word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") } ? word.lowercased() : "x"
        }.joined(separator: "_")
    }
    static let maximumPendingMembershipReceipts = 10_000

    /// Global legacy account policy is historical. An active account slot is a separate CAS
    /// authority and must never manufacture a new ownAccountSources entry for an existing ID.
    enum AccountOrigin: Sendable, Equatable { case own, shared, isolated }
    static func accountOrigins(_ bytes: Data?) throws -> [UUID: AccountOrigin] {
        guard let bytes else { return [:] }
        let root = try VortxProfileOverlayWitness.decodeObject(json: bytes)
        guard let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), [1.0, 2.0].contains(version.doubleValue),
              let rows = root["roster"] as? [[String: Any]],
              let addons = root["addons"] as? [String: Any],
              let libraries = root["libraries"] as? [String: Any],
              let watches = root["watches"] as? [String: Any],
              let links = root["identityLinks"] as? [String: Any] else {
            throw ReconciliationRequired(reason: "Retained account origin requires a complete baseline")
        }
        let sources = root["ownAccountSources"] as? [String: Any] ?? [:]
        let owners = rows.filter { ($0["owner"] as? Bool) == true }
        guard owners.count == 1, let ownerID = owners[0]["id"] as? String else {
            throw ReconciliationRequired(reason: "Retained account origin requires a unique owner")
        }
        var result: [UUID: AccountOrigin] = [:]
        var seen = Set<UUID>()
        for row in rows {
            guard let raw = row["id"] as? String, let id = UUID(uuidString: raw), id.uuidString == raw,
                  seen.insert(id).inserted, let account = row["account"] as? [String: Any],
                  let kind = account["kind"] as? String, let policy = row["addons"] as? String else {
                throw ReconciliationRequired(reason: "Retained account origin is malformed")
            }
            if raw == ownerID { continue }
            switch kind {
            case "own":
                guard sources[raw] != nil, policy == "own" else {
                    throw ReconciliationRequired(reason: "Retained own-account baseline has a partial absent profile tuple")
                }
                result[id] = .own
            case "shared":
                guard sources[raw] == nil, policy == "share_primary", account["value"] as? String == ownerID else {
                    throw ReconciliationRequired(reason: "Retained shared account origin is malformed")
                }
                result[id] = .shared
            case "local_only":
                guard sources[raw] == nil, policy == "own", Set(account.keys) == ["kind"],
                      let a = addons[raw] as? [String: Any], Set(a.keys) == ["items", "order", "intents"],
                      let l = libraries[raw] as? [String: Any], Set(l.keys) == ["items", "intents"],
                      [a["items"], a["order"], a["intents"], l["items"], l["intents"], watches[raw], links[raw]]
                        .allSatisfy({ ($0 as? [Any])?.isEmpty == true }) else {
                    throw ReconciliationRequired(reason: "Retained isolated account origin is not empty")
                }
                result[id] = .isolated
            default:
                throw ReconciliationRequired(reason: "Retained account origin is unsupported")
            }
        }
        return result
    }

    /// A caller-owned, server-authenticated source receipt for one secondary profile's independent
    /// streaming account. The caller must keep its credential-generation proof private; neither a
    /// token nor a token-derived fingerprint may enter this value or the native material.
    struct OwnAccountSource: Sendable, Equatable {
        let profileID: UUID
        let verifiedStreamingUID: String
        let sourceDocument: Data
        let profileOverlaySHA256: String?

        init(profileID: UUID, verifiedStreamingUID: String, sourceDocument: Data, profileOverlaySHA256: String? = nil) {
            self.profileID = profileID
            self.verifiedStreamingUID = verifiedStreamingUID
            self.sourceDocument = sourceDocument
            self.profileOverlaySHA256 = profileOverlaySHA256
        }

        var sourceDocumentSHA256: String {
            SHA256.hash(data: sourceDocument).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// An exact, token-free own-source envelope retained by the authenticated host archive.  It is
    /// usable only to prove that a current UUID-scoped root overlay is the same overlay already
    /// bound into a kernel-validated retained tuple; it never creates a new source assertion.
    struct RetainedOwnAccountSourceEnvelope: Sendable, Equatable {
        let profileID: UUID
        let sourceDocument: Data

        init(profileID: UUID, sourceDocument: Data) {
            self.profileID = profileID
            self.sourceDocument = sourceDocument
        }

        fileprivate var sourceDocumentSHA256: String {
            SHA256.hash(data: sourceDocument).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A complete token-free carrier exported by the *active* schema-4 account slot.  The host
    /// may obtain these only after it has validated/merged nativeSync with the private engine.
    /// They deliberately remain distinct from `legacyImport.baseline`: a later same-UID rebind
    /// changes the active slot without advancing the historical, last-acknowledged migration receipt.
    struct RetainedOwnAccountSlotBaseline: Sendable, Equatable {
        let profileID: UUID
        /// Exact JSON bytes of the kernel-exported `sourceBaseline` carrier. No raw credential or
        /// raw account response belongs here. The authenticated host must supply this only after
        /// detached nativeSync validation; the importer then validates its complete typed shape.
        let sourceBaseline: Data

        init(profileID: UUID, sourceBaseline: Data) {
            self.profileID = profileID
            self.sourceBaseline = sourceBaseline
        }
    }

    enum RetainedOwnAccountOverlayStatus: String, Sendable, Equatable {
        /// A witnessed source tuple matches the current authenticated UUID-scoped overlay.
        case matchedWitness = "matched_witness"
        /// A legacy v1 source has no witness, but a sealed exact raw envelope proves equality.
        case matchedSealedEnvelope = "matched_sealed_envelope"
        /// The retained tuple has no witness and no sealed envelope can prove the live slice.
        case missingWitness = "missing_witness"
        /// A retained witness exists but does not describe the current live slice.
        case changedWitness = "changed_witness"
        /// No slot or historical tuple is available for this current own profile.
        case missingRetainedSource = "missing_retained_source"
    }

    /// A classifier-issued authority to omit exactly one current own-profile overlay from this
    /// material projection. The raw slice is not acknowledged or transformed: callers must retain
    /// it together with this status while continuing unrelated reconciliation. The initializer and
    /// binding fields are file-private so ordinary callers cannot turn an arbitrary omission into
    /// a valid material projection.
    struct RetainedOwnAccountOverlayDisposition: Sendable, Equatable {
        let profileID: UUID
        let sourceDocumentSHA256: String?
        let retainedProfileOverlaySHA256: String?
        let currentProfileOverlaySHA256: String
        let status: RetainedOwnAccountOverlayStatus
        fileprivate let rootDocumentSHA256: String

        fileprivate init(profileID: UUID, sourceDocumentSHA256: String?, retainedProfileOverlaySHA256: String?,
                         currentProfileOverlaySHA256: String, status: RetainedOwnAccountOverlayStatus,
                         rootDocumentSHA256: String) {
            self.profileID = profileID
            self.sourceDocumentSHA256 = sourceDocumentSHA256
            self.retainedProfileOverlaySHA256 = retainedProfileOverlaySHA256
            self.currentProfileOverlaySHA256 = currentProfileOverlaySHA256
            self.status = status
            self.rootDocumentSHA256 = rootDocumentSHA256
        }
    }

    /// A Sendable UTF-8 JSON result that can cross the caller's authentication/MainActor boundary.
    /// The result is the `material` member of `import_legacy_sync`, not a runtime or sync document.
    ///
    /// `profileEdits` is an authenticated, independently reconciled website authority channel. A
    /// caller that has retained and will process that channel separately may defer only its
    /// material-side reconciliation check; the edits themselves never enter this projection.
    /// The default remains strict so ordinary legacy imports cannot acknowledge pending edits.
    /// `retainedOwnAccountBaseline` is accepted only from the authenticated nativeSync helper after
    /// it has detached-merged and validated a nativeSync 3 / legacyImport 2 receipt. It is the
    /// exact `legacyImport.baseline` material 2 bytes, never an engine snapshot or raw source.
    static func encode(document: Data, roster: [UserProfile], ownerProfileID: UUID,
                       rosterModifiedSeconds: Double?, deferProfileEdits: Bool = false,
                       ownAccountSources: [OwnAccountSource] = [], retainedOwnAccountBaseline: Data? = nil,
                       retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope] = [],
                       retainedOwnAccountSlotBaselines: [RetainedOwnAccountSlotBaseline] = [],
                       deferredOwnAccountOverlays: [RetainedOwnAccountOverlayDisposition] = [],
                       missingOwnAccountProfileIDs: Set<UUID> = [],
                       accountID: String? = nil,
                       watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow] = []) throws -> Data {
        try project(document: document, roster: roster, ownerProfileID: ownerProfileID,
            rosterModifiedSeconds: rosterModifiedSeconds, deferProfileEdits: deferProfileEdits,
            ownAccountSources: ownAccountSources, retainedOwnAccountBaseline: retainedOwnAccountBaseline,
            retainedOwnAccountSourceEnvelopes: retainedOwnAccountSourceEnvelopes,
            retainedOwnAccountSlotBaselines: retainedOwnAccountSlotBaselines,
            deferredOwnAccountOverlays: deferredOwnAccountOverlays,
            missingOwnAccountProfileIDs: missingOwnAccountProfileIDs, accountID: accountID,
            watchedEvidence: watchedEvidence, preparePendingMembership: false).material
    }

    /// Only this explicit path may separate a validated but unresolved historical membership
    /// receipt from the native projection. The exact source values and binding remain in the
    /// returned pending ledger; callers cannot manufacture individual deferral permissions.
    static func prepare(document: Data, roster: [UserProfile], ownerProfileID: UUID,
                        rosterModifiedSeconds: Double? = nil, deferProfileEdits: Bool = false,
                        ownAccountSources: [OwnAccountSource] = [], retainedOwnAccountBaseline: Data? = nil,
                        retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope] = [],
                        retainedOwnAccountSlotBaselines: [RetainedOwnAccountSlotBaseline] = [],
                        deferredOwnAccountOverlays: [RetainedOwnAccountOverlayDisposition] = [],
                        missingOwnAccountProfileIDs: Set<UUID> = [],
                        accountID: String? = nil,
                        watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow] = []) throws -> Preparation {
        try project(document: document, roster: roster, ownerProfileID: ownerProfileID,
            rosterModifiedSeconds: rosterModifiedSeconds, deferProfileEdits: deferProfileEdits,
            ownAccountSources: ownAccountSources, retainedOwnAccountBaseline: retainedOwnAccountBaseline,
            retainedOwnAccountSourceEnvelopes: retainedOwnAccountSourceEnvelopes,
            retainedOwnAccountSlotBaselines: retainedOwnAccountSlotBaselines,
            deferredOwnAccountOverlays: deferredOwnAccountOverlays,
            missingOwnAccountProfileIDs: missingOwnAccountProfileIDs, accountID: accountID,
            watchedEvidence: watchedEvidence, preparePendingMembership: true)
    }

    /// `encode` and `prepare` both project through here; the result also reports held units.
    static func project(document: Data, roster: [UserProfile], ownerProfileID: UUID,
                       rosterModifiedSeconds: Double?, deferProfileEdits: Bool = false,
                       ownAccountSources: [OwnAccountSource] = [], retainedOwnAccountBaseline: Data? = nil,
                       retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope] = [],
                       retainedOwnAccountSlotBaselines: [RetainedOwnAccountSlotBaseline] = [],
                       deferredOwnAccountOverlays: [RetainedOwnAccountOverlayDisposition] = [],
                       missingOwnAccountProfileIDs: Set<UUID> = [],
                       accountID: String? = nil,
                       watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow] = [],
                       preparePendingMembership: Bool) throws -> Preparation {
        guard let source = try? VortxProfileOverlayWitness.decodeObject(json: document) else {
            throw ReconciliationRequired(reason: "Account document must be an object")
        }
        for row in watchedEvidence {
            guard let accountID else { throw ReconciliationRequired(reason: "Watched evidence requires authenticated account scope") }
            try row.validateSource(accountID: accountID, ownerProfileID: ownerProfileID, document: document,
                                   roster: roster, ownAccountSources: ownAccountSources)
        }
        let adapter = try Adapter(document: source, roster: roster, ownerID: ownerProfileID,
                                  modified: rosterModifiedSeconds, deferProfileEdits: deferProfileEdits,
                                  accountID: accountID, sourceSHA256: sha256(document), watchedEvidence: watchedEvidence,
                                  preparePendingMembership: preparePendingMembership)
        let material = try JSONSerialization.data(withJSONObject: adapter.build(ownAccountSources: ownAccountSources,
                                                                         retainedOwnAccountBaseline: retainedOwnAccountBaseline,
                                                                         retainedOwnAccountSourceEnvelopes: retainedOwnAccountSourceEnvelopes,
                                                                         retainedOwnAccountSlotBaselines: retainedOwnAccountSlotBaselines,
                                                                         deferredOwnAccountOverlays: deferredOwnAccountOverlays,
                                                                         missingOwnAccountProfileIDs: missingOwnAccountProfileIDs,
                                                                         rootDocumentSHA256: sha256(document)), options: [.sortedKeys, .withoutEscapingSlashes])
        return Preparation(material: material, pendingMembershipReceipts: try adapter.pendingMembershipData(),
                           pendingCount: adapter.pendingMembership.count, held: adapter.held)
    }

    /// Classifies nonempty UUID-scoped own overlays before a cold material projection. Active
    /// schema-4 slot baselines win over `legacyImport.baseline`; the latter is only a historical
    /// fallback. A returned disposition is intentionally required by `encode` before it can omit
    /// a current raw overlay from a retained typed tuple.
    static func classifyDeferredOwnAccountOverlays(document: Data, roster: [UserProfile], ownerProfileID: UUID,
                                                   rosterModifiedSeconds: Double? = nil,
                                                   retainedOwnAccountBaseline: Data? = nil,
                                                   retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope] = [],
                                                   retainedOwnAccountSlotBaselines: [RetainedOwnAccountSlotBaseline] = []) throws -> [RetainedOwnAccountOverlayDisposition] {
        let source = try VortxProfileOverlayWitness.decodeObject(json: document)
        let adapter = try Adapter(document: source, roster: roster, ownerID: ownerProfileID,
                                  modified: rosterModifiedSeconds, deferProfileEdits: true)
        return try adapter.classifyDeferredOwnAccountOverlays(retainedBaseline: retainedOwnAccountBaseline,
                                                              retainedSourceEnvelopes: retainedOwnAccountSourceEnvelopes,
                                                              retainedSlotBaselines: retainedOwnAccountSlotBaselines,
                                                              rootDocumentSHA256: sha256(document))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct OwnerHistoryProjection: Sendable {
        /// Exactly library/watches/identityLinks, without roster/import schema/baseline/receipt.
        let carrier: Data
        let held: [Held]
    }

    /// Pure owner-source projection through the existing row/time/watch converters. Never calls
    /// build/encode/import_legacy_sync, never constructs OwnAccountSource, never reads the clock.
    static func projectOwnerHistory(accountID: String, ownerProfileID: UUID, profileID: UUID,
                                    verifiedUID: String, sourceDocument: Data,
                                    watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow]) throws -> OwnerHistoryProjection {
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: accountID, profileID: profileID,
            verifiedStreamingUID: verifiedUID, ownerProfileID: ownerProfileID)
        try LegacyWatchedBitfieldMigrationEvidence.validateOwnerSource(scope: scope, source: sourceDocument)
        let projection = try LegacyWatchedBitfieldMigrationEvidence.ownerHistoryLibraryProjection(
            scope: scope, source: sourceDocument)
        guard let raw = try VortxProfileOverlayWitness.decodeObject(json: projection)["result"] as? [Any] else {
            throw fail("Malformed owner history source")
        }
        for row in watchedEvidence {
            try row.validateOwnerHistorySource(accountID: accountID, ownerProfileID: ownerProfileID,
                profileID: profileID, verifiedUID: verifiedUID, sourceDocument: sourceDocument)
        }
        var roster = [UserProfile(id: ownerProfileID, name: "Owner", avatar: "", isOwner: true)]
        if profileID != ownerProfileID { roster.append(UserProfile(id: profileID, name: "Viewer", avatar: "", isOwner: false)) }
        let adapter = try Adapter(document: [:], roster: roster, ownerID: ownerProfileID, modified: nil,
            deferProfileEdits: false, accountID: accountID, sourceSHA256: sha256(sourceDocument),
            verifiedStreamingUID: verifiedUID, watchedEvidence: watchedEvidence)
        let carrier = try adapter.ownerHistoryRows(raw, profileID: profileID)
        return OwnerHistoryProjection(carrier: try JSONSerialization.data(withJSONObject: carrier,
            options: [.sortedKeys, .withoutEscapingSlashes]), held: adapter.held)
    }

    private final class Adapter {
        typealias Object = [String: Any]
        let document: Object
        let vortx: Object
        let roster: [UserProfile]
        let owner: UserProfile
        let modified: Double?
        let profiles: [String: UserProfile]
        let deferProfileEdits: Bool
        let independentSource: Bool
        let accountID: String?
        let sourceSHA256: String?
        let verifiedStreamingUID: String?
        let watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow]
        let preparePendingMembership: Bool
        var pendingMembership: [String: Object] = [:]
        var pendingMembershipSizes: [String: Int] = [:]
        var pendingMembershipBytes = 0
        // profile -> exact video unit -> source JSON pointer -> original source object.
        // Populated only for explicit host preparation, never from projected watch facts.
        var watchSources: [String: [String: [String: Object]]] = [:]
        var deleted = Set<String>()
        var watches: [String: [Object]] = [:]
        var titles: [String: [String: Object]] = [:]
        var held: [Held] = []
        /// One undo list per open unit; a held unit replays its own list, a kept one hands it outward.
        private var undo: [[() -> Void]] = []

        init(document: Object, roster: [UserProfile], ownerID: UUID, modified: Double?,
             deferProfileEdits: Bool, allowIndependentSource: Bool = false,
             accountID: String? = nil, sourceSHA256: String? = nil, verifiedStreamingUID: String? = nil,
             watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow] = [],
             preparePendingMembership: Bool = false) throws {
            self.document = document
            self.vortx = try object(document, "vortx") ?? [:]
            self.roster = roster
            self.modified = modified
            self.deferProfileEdits = deferProfileEdits
            self.independentSource = allowIndependentSource
            self.accountID = accountID
            self.sourceSHA256 = sourceSHA256
            self.verifiedStreamingUID = verifiedStreamingUID
            self.watchedEvidence = watchedEvidence
            self.preparePendingMembership = preparePendingMembership
            try require(!roster.isEmpty && Set(roster.map(\.id)).count == roster.count, "Duplicate or empty profile roster")
            let owners = roster.filter(\.isOwner)
            if allowIndependentSource {
                try require(roster.count == 1 && roster[0].id == ownerID,
                            "Independent account source must bind exactly one profile")
                self.owner = roster[0]
            } else {
                try require(owners.count == 1 && owners[0].id == ownerID, "A unique resolved owner UUID is required")
                self.owner = owners[0]
            }
            profiles = Dictionary(uniqueKeysWithValues: roster.map { ($0.id.uuidString, $0) })
        }

        /// Projects one source unit atomically. A unit that needs reconciliation is held: every effect
        /// it made (titles, watches, provenance, pending receipts) is undone, it is recorded, and the
        /// projection continues. Units nest; any other error still stops the projection. Returns
        /// false when held.
        @discardableResult
        func unit(_ kind: String, _ body: () throws -> Void) throws -> Bool {
            let watchCounts = watches.mapValues(\.count), heldCount = held.count
            undo.append([])
            do {
                try body()
                let effects = undo.removeLast()
                if !undo.isEmpty { undo[undo.count - 1] += effects }
                return true
            } catch let error as ReconciliationRequired {
                for step in undo.removeLast().reversed() { step() }
                // Watches only grow by appending inside a unit, so their prior counts restore them.
                for profile in Array(watches.keys) {
                    guard let keep = watchCounts[profile] else { watches.removeValue(forKey: profile); continue }
                    if var rows = watches[profile], rows.count > keep { rows.removeSubrange(keep...); watches[profile] = rows }
                }
                held.removeSubrange(heldCount...)
                held.append(Held(kind: (independentSource ? "own_" : "") + kind, reason: error.reason))
                return false
            }
        }

        /// Registers how to undo one effect of the innermost open unit.
        private func onHold(_ step: @escaping () -> Void) {
            if !undo.isEmpty { undo[undo.count - 1].append(step) }
        }

        /// A row an own-account source could not project arrives as a held marker; hold it here.
        func heldSource(_ row: Object) throws {
            if let reason = row[VortxLegacyBootstrapMaterial.heldReasonKey] as? String { throw fail(reason) }
        }

        func pendingMembershipData() throws -> Data? {
            guard !pendingMembership.isEmpty else { return nil }
            guard let accountID, !accountID.isEmpty, accountID.utf8.count <= 256,
                  accountID == accountID.trimmingCharacters(in: .whitespacesAndNewlines),
                  accountID.rangeOfCharacter(from: .controlCharacters) == nil,
                  sourceSHA256 != nil else { throw fail("Pending membership receipts require authenticated account scope") }
            let ledger = pendingMembership.keys.sorted().compactMap { pendingMembership[$0] }
            try rejectCredentials(ledger)
            let bytes = try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys, .withoutEscapingSlashes])
            try require(bytes.count <= 32 * 1024 * 1024, "Pending membership receipts exceed archive limit")
            return bytes
        }

        private func retainPendingMembership(kind: String, profileID: String, identity: String,
                                             sourceField: String, receipt: Object) throws {
            try require(preparePendingMembership && !independentSource, "Membership deferral requires explicit host preparation")
            try require(!identity.isEmpty && identity.utf8.count <= 8192,
                        "Pending membership identity is invalid")
            guard let sourceSHA256 else { throw fail("Pending membership receipts require authenticated source") }
            try rejectCredentials(receipt)
            let key = kind + ":" + profileID + ":" + Data(identity.utf8).base64EncodedString()
            try require(pendingMembership[key] != nil || pendingMembership.count < maximumPendingMembershipReceipts,
                        "Pending membership receipts exceed count limit")
            let retained: Object = ["kind": kind, "profileId": profileID, "identity": identity,
                                    "sourceField": sourceField, "receipt": receipt,
                                    "sourceDocumentSha256": sourceSHA256]
            let size = try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys, .withoutEscapingSlashes]).count
            let newSize = pendingMembershipBytes - (pendingMembershipSizes[key] ?? 0) + size
            try require(newSize <= 32 * 1024 * 1024, "Pending membership receipts exceed archive limit")
            let priorReceipt = pendingMembership[key], priorSize = pendingMembershipSizes[key], priorBytes = pendingMembershipBytes
            onHold {
                self.pendingMembership[key] = priorReceipt
                self.pendingMembershipSizes[key] = priorSize
                self.pendingMembershipBytes = priorBytes
            }
            pendingMembershipBytes = newSize; pendingMembershipSizes[key] = size
            pendingMembership[key] = retained
        }

        private func rememberWatchSource(profileID: String, unit: String, sourceField: String, receipt: Object) {
            guard preparePendingMembership && !independentSource else { return }
            let prior = watchSources[profileID]?[unit]?[sourceField]
            onHold { self.watchSources[profileID]?[unit]?[sourceField] = prior }
            watchSources[profileID, default: [:]][unit, default: [:]][sourceField] = receipt
        }

        private func rememberAppendedWatchSources(profileID: String, sourceField: String, receipt: Object, from index: Int) {
            guard preparePendingMembership && !independentSource else { return }
            for row in (watches[profileID] ?? []).dropFirst(index) {
                if let unit = row["videoId"] as? String ?? row["metaId"] as? String {
                    rememberWatchSource(profileID: profileID, unit: unit, sourceField: sourceField, receipt: receipt)
                }
            }
        }

        private func preparedWatches(profileID: String, rows: [Object]) throws -> [Object] {
            guard preparePendingMembership else { return try resolveWatches(rows, held: &held) }
            let grouped = try Dictionary(grouping: rows) { row in
                try optionalString(row, "videoId") ?? string(row, "metaId")
            }
            let conflicts = try Set(grouped.filter { _, rows in
                try Set(rows.map { try string($0, "metaId") }).count > 1
            }.keys)
            for identity in conflicts.sorted() {
                // Either way the conflicting unit leaves the projection: as a pending receipt, or held.
                try unit("watch") {
                    let originals = watchSources[profileID]?[identity] ?? [:]
                    try require(!originals.isEmpty, "Conflicting watch identity lacks original source receipts")
                    let sources: [Object] = originals.keys.sorted().map { ["sourceField": $0, "receipt": originals[$0]!] }
                    try retainPendingMembership(kind: "watch_identity_conflict", profileID: profileID, identity: identity,
                        sourceField: "/vortx/byProfile/" + pointer(profileID) + "/watch_identity_conflicts", receipt: ["sources": sources])
                }
            }
            return try resolveWatches(rows.filter { row in
                !conflicts.contains(try optionalString(row, "videoId") ?? string(row, "metaId"))
            }, held: &held)
        }

        private func pointer(_ raw: String) -> String {
            raw.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }

        private func sourcePointer(_ locator: LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator,
                                   profileID: String) -> String {
            // Keep evidence locators unchanged: their placeholder is part of the evidence
            // binding. Pending provenance instead addresses the exact original JSON key.
            locator.pointer.replacingOccurrences(of: "<captured-profile>", with: pointer(profileID))
        }

        func build(ownAccountSources: [OwnAccountSource], retainedOwnAccountBaseline: Data?,
                   retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope],
                   retainedOwnAccountSlotBaselines: [RetainedOwnAccountSlotBaseline],
                   deferredOwnAccountOverlays: [RetainedOwnAccountOverlayDisposition],
                   missingOwnAccountProfileIDs: Set<UUID>,
                   rootDocumentSHA256: String) throws -> Object {
            if let modified { _ = try validClock(modified, "rosterModifiedSeconds") }
            // The native `own` binding represents a secondary independently authenticated
            // streaming persona. The resolved primary owner remains local-only, never silently
            // downgraded from an impossible owner-owned source claim.
            try require(!roster.contains { $0.isOwner && $0.usesOwnAccount },
                        "Owner profile cannot use an independent streaming account")
            // A tombstone that names no valid UUID can match no profile; hold it rather than the account.
            deleted = []
            for value in try array(vortx, "deletedProfiles") ?? [] {
                try unit("deleted_profile") {
                    guard let raw = value as? String, let id = UUID(uuidString: raw) else { throw fail("Invalid deleted profile identity") }
                    deleted.insert(id.uuidString)
                }
            }
            try require(!deleted.contains(owner.id.uuidString), "Owner profile is tombstoned")
            let origins = try VortxLegacyBootstrapMaterial.accountOrigins(retainedOwnAccountBaseline)
            let ownIDs = Set(roster.filter { !$0.isOwner && $0.usesOwnAccount }.map(\.id))
            try require(missingOwnAccountProfileIDs.isSubset(of: ownIDs), "Missing source profile is not an independent non-owner")
            try require(missingOwnAccountProfileIDs.isEmpty || retainedOwnAccountBaseline == nil,
                        "Missing source deferral is limited to the first legacy import")
            try require(missingOwnAccountProfileIDs.isDisjoint(with: Set(ownAccountSources.map(\.profileID))),
                        "Missing source profile conflicts with an authenticated source")
            try require(missingOwnAccountProfileIDs.isDisjoint(with: Set(retainedOwnAccountSlotBaselines.map(\.profileID)))
                        && missingOwnAccountProfileIDs.isDisjoint(with: Set(retainedOwnAccountSourceEnvelopes.map(\.profileID))),
                        "Missing source profile conflicts with retained source evidence")
            try require(Set(retainedOwnAccountSlotBaselines.map(\.profileID)).isSubset(of: Set(roster.map(\.id))),
                        "Retained slot belongs to an unknown profile")
            let isolatedIDs = missingOwnAccountProfileIDs.union(origins.compactMap { $0.value == .isolated ? $0.key : nil })
            let resolved = try resolveOwnAccountSources(ownAccountSources, retainedBaseline: retainedOwnAccountBaseline,
                                                        retainedSourceEnvelopes: retainedOwnAccountSourceEnvelopes,
                                                        retainedSlotBaselines: retainedOwnAccountSlotBaselines,
                                                        origins: origins, isolatedIDs: isolatedIDs)
            let sources = resolved.material
            for profile in roster {
                watches[profile.id.uuidString] = []
                titles[profile.id.uuidString] = [:]
            }
            let nativeRoster = try roster.map { profile -> Object in
                var row = try projectProfile(profile, ownSource: sources[profile.id.uuidString])
                if isolatedIDs.contains(profile.id) {
                    row["account"] = ["kind": "local_only"]; row["addons"] = "own"
                } else if origins[profile.id] == .shared {
                    row["account"] = ["kind": "shared", "value": owner.id.uuidString]; row["addons"] = "share_primary"
                }
                return row
            }
            let addons = try addonBucket()
            let library = try ownerLibrary()
            try validateOwnProfileOverlayBindings(resolved.overlayAuthority, deferred: deferredOwnAccountOverlays,
                                                  rootDocumentSHA256: rootDocumentSHA256)
            // An independent source owns its profile's overlay context. Avoid parsing the root
            // bucket first: watched-only rows can rely on metadata in that independent library,
            // and accepting then overwriting them would make a stale root slice authoritative.
            try importOverlays(excluding: Set(sources.keys).union(isolatedIDs.map(\.uuidString)))
            try importOwnerIntents()
            if !deferProfileEdits { try validateProfileEdits(ownerLibrary: library) }
            var addonBuckets: [String: Object] = [owner.id.uuidString: addons]
            var libraryBuckets: [String: Object] = [owner.id.uuidString: library]
            var ownSourceMaterial: [String: Object] = [:]
            var identityLinks = Dictionary(uniqueKeysWithValues: roster.map { ($0.id.uuidString, [[String]]()) })
            var retainedWatchProfiles = Set<String>()
            // These exact empty buckets are the permanent global legacy baseline for a pending
            // origin. A later own/shared CAS may populate a slot, never these legacy buckets.
            for id in isolatedIDs.map(\.uuidString) where profiles[id] != nil {
                addonBuckets[id] = ["items": [], "order": [], "intents": []]
                libraryBuckets[id] = ["items": [], "intents": []]
                watches[id] = []; identityLinks[id] = []
            }
            for (profileID, source) in sources {
                let buckets = try source.buckets(accountID: accountID, watchedEvidence: watchedEvidence)
                held += buckets.held
                addonBuckets[profileID] = buckets.addons
                libraryBuckets[profileID] = buckets.library
                watches[profileID] = buckets.watches
                titles[profileID] = buckets.titles
                identityLinks[profileID] = buckets.identityLinks
                if source.isRetained { retainedWatchProfiles.insert(profileID) }
                var proof: Object = ["verifiedStreamingUid": source.verifiedStreamingUID, "sourceDocumentSha256": source.sourceDocumentSHA256]
                if let witness = source.profileOverlaySHA256 { proof["profileOverlaySha256"] = witness }
                ownSourceMaterial[profileID] = proof
            }
            // Resolving can record holds on this adapter, so iterate a copy, never the live map.
            let collected = watches
            var resolvedWatches: [String: [Object]] = [:]
            for profileID in collected.keys.sorted() {
                let rows = collected[profileID] ?? []
                resolvedWatches[profileID] = retainedWatchProfiles.contains(profileID) ? rows : try preparedWatches(profileID: profileID, rows: rows)
            }
            var result: Object = [
                "schemaVersion": sources.isEmpty ? 1 : 2, "roster": nativeRoster, "deletedProfileIds": deleted.sorted(),
                "addons": addonBuckets, "libraries": libraryBuckets,
                "watches": resolvedWatches,
                // Removal keys do not establish an IMDb/TMDB equivalence edge. The caller must
                // reconcile such aliases explicitly; this adapter never guesses an identity link.
                "identityLinks": identityLinks
            ]
            if !ownSourceMaterial.isEmpty { result["ownAccountSources"] = ownSourceMaterial }
            if let modified { result["rosterModifiedSeconds"] = modified }
            try rejectCredentials(result)
            return result
        }

        private func projectProfile(_ profile: UserProfile, ownSource: ResolvedOwnAccountSource?) throws -> Object {
            // A profile cannot be held, only a preference it carries: an unrepresentable one keeps
            // its native default and stays in the retained roster.
            var textScale = 1000
            try unit("profile_setting") {
                try require(profile.textScale.isFinite && profile.textScale > 0 && profile.textScale <= 100,
                            "Invalid profile text scale")
                textScale = Int((profile.textScale * 1000).rounded())
            }
            let inherited = owner.addonPreferences?.disabledAddonURLsOverride ?? owner.disabledAddons ?? []
            // Follow the shipping profile policy without consulting the active profile/defaults.
            let disabled = profile.addonPreferences?.disabledAddonURLsOverride
                ?? (profile.addonPreferences == nil ? profile.disabledAddons : nil)
                ?? (profile.isOwner ? profile.disabledAddons ?? [] : inherited)
            var disabledURLs: [String] = []
            for raw in disabled {
                try unit("profile_setting") { disabledURLs.append(try normalizeURL(raw)) }
            }
            let languages = unique([profile.playback?.audioLang, profile.playback?.subtitleLang].compactMap { $0 }.filter { !$0.isEmpty })
            var settings: Object = ["accent": profile.accentID, "oled": profile.oled,
                                    "textScale": textScale,
                                    "languages": languages, "disabledAddons": unique(disabledURLs)]
            if let playback = profile.playback {
                var ranking: Object = ["preferred_languages": unique(terms(playback.audioLang)).sorted()]
                if let resolution = playback.maxResolution, resolution != 0 {
                    try unit("profile_setting") {
                        let values = [480: "480p", 720: "720p", 1080: "1080p", 2160: "2160p", 4000: "2160p"]
                        guard let value = values[resolution] else { throw fail("Unsupported profile resolution cap") }
                        ranking["max_resolution"] = value
                    }
                }
                if let size = playback.maxFileSizeGB {
                    try unit("profile_setting") {
                        try require(size.isFinite && size >= 0, "Invalid profile file-size cap")
                        if size > 0 { ranking["max_filesize_gb"] = size }
                    }
                }
                // Transport classes (debrid/torrent/etc.) are NOT native quality classes
                // (remux/web/etc.). Transport order, regex filters, and UI overrides remain in the
                // adjacent full roster; only directly compatible native fields are projected here.
                if playback.keywordsAreRegex != true {
                    ranking["keyword_include"] = terms(playback.includeKeywords)
                    if playback.avoidBehavior != "rank" { ranking["keyword_exclude"] = terms(playback.excludeKeywords) }
                }
                settings["ranking"] = ranking
            }
            let account: Object
            let addons: String
            if let ownSource {
                account = ["kind": "own", "value": ownSource.verifiedStreamingUID]
                addons = "own"
            } else {
                account = profile.isOwner ? ["kind": "local_only"] : ["kind": "shared", "value": owner.id.uuidString]
                addons = "share_primary"
            }
            var result: Object = ["id": profile.id.uuidString, "name": profile.name, "owner": profile.isOwner,
                                  "account": account, "addons": addons, "settings": settings,
                                  "parental": ["kids": profile.isKids, "familyEdit": profile.familyEdit]]
            if let pin = profile.pin, !pin.isEmpty {
                try require(pin.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                            "Legacy plaintext or malformed PIN requires explicit reconciliation")
                result["pin"] = pin
            }
            return result
        }

        private struct OwnAccountBuckets {
            let addons: Object
            let library: Object
            let watches: [Object]
            let titles: [String: Object]
            let identityLinks: [[String]]
            var held: [Held] = []
        }

        private struct ResolvedOwnAccountSource {
            let profileID: String
            let verifiedStreamingUID: String
            let sourceDocumentSHA256: String
            let profileOverlaySHA256: String?
            let sourceDocument: Object?
            let retainedBuckets: OwnAccountBuckets?
            var isRetained: Bool { retainedBuckets != nil }

            func buckets(accountID: String?, watchedEvidence: [VortxLegacyWatchedMigration.ValidatedRow]) throws -> OwnAccountBuckets {
                if let retainedBuckets { return retainedBuckets }
                guard let sourceDocument else { throw fail("Missing own-account source material") }
                // An independently authenticated account has the same root membership/history
                // carriers as the primary account, but never borrows root-document data from the
                // profile roster's account. Its envelope carries only the authenticated, exact
                // UUID-scoped overlay slice when that profile has durable local intents.
                let profile = UserProfile(id: UUID(uuidString: profileID)!, name: "Independent", avatar: "🍿")
                let adapter = try Adapter(document: sourceDocument, roster: [profile], ownerID: profile.id, modified: nil,
                    deferProfileEdits: false, allowIndependentSource: true, accountID: accountID,
                    sourceSHA256: sourceDocumentSHA256, verifiedStreamingUID: verifiedStreamingUID, watchedEvidence: watchedEvidence)
                adapter.watches[profileID] = []
                adapter.titles[profileID] = [:]
                let addons = try adapter.addonBucket()
                let library = try adapter.ownerLibrary()
                try adapter.importOverlays()
                try adapter.validateProfileEdits(ownerLibrary: library)
                var held = adapter.held
                let watches = try VortxLegacyBootstrapMaterial.resolveWatches(adapter.watches[profileID] ?? [], held: &held, kind: "own_watch")
                return OwnAccountBuckets(addons: addons, library: library, watches: watches,
                                         titles: adapter.titles[profileID] ?? [:], identityLinks: [], held: held)
            }
        }

        /// The authenticated producer retains the exact datastore and add-on response bodies inside
        /// this small envelope.  The source digest covers the envelope bytes, not a host-reserialized
        /// projection; parsing below creates a private compatibility view only after that proof.
        private static func decodeOwnAccountEnvelope(_ source: Data, profileID: String) throws -> Object {
            guard let envelope = try JSONSerialization.jsonObject(with: source) as? Object,
                  Set(envelope.keys) == ["schemaVersion", "libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64"],
                  let version = envelope["schemaVersion"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), (version.intValue == 1 || version.intValue == 2),
                  Double(version.intValue) == version.doubleValue,
                  let libraryBase64 = envelope["libraryResponseBase64"] as? String,
                  let addonsBase64 = envelope["addonsResponseBase64"] as? String,
                  let overlayBase64 = envelope["profileOverlayBase64"] as? String,
                  let libraryBytes = Data(base64Encoded: libraryBase64),
                  let addonBytes = Data(base64Encoded: addonsBase64),
                  let overlayBytes = Data(base64Encoded: overlayBase64),
                  libraryBytes.base64EncodedString() == libraryBase64,
                  addonBytes.base64EncodedString() == addonsBase64,
                  overlayBytes.base64EncodedString() == overlayBase64,
                  let libraryEnvelope = try JSONSerialization.jsonObject(with: libraryBytes) as? Object,
                  let addonEnvelope = try JSONSerialization.jsonObject(with: addonBytes) as? Object,
                  let overlay = try? VortxProfileOverlayWitness.decodeObject(json: overlayBytes),
                  (Set(libraryEnvelope.keys) == ["result"] ||
                    (Set(libraryEnvelope.keys) == ["result", "error"] && libraryEnvelope["error"] is NSNull)),
                  (Set(addonEnvelope.keys) == ["result"] ||
                    (Set(addonEnvelope.keys) == ["result", "error"] && addonEnvelope["error"] is NSNull)),
                  let libraryRows = libraryEnvelope["result"] as? [Any],
                  let addonResult = addonEnvelope["result"] as? Object,
                  Set(addonResult.keys) == ["addons"],
                  let addons = addonResult["addons"] as? [Any] else {
                throw fail("Own-account source envelope requires exact library and add-on responses")
            }
            try VortxLegacyBootstrapMaterial.rejectCredentials(envelope)
            try VortxLegacyBootstrapMaterial.rejectCredentials(libraryEnvelope)
            try VortxLegacyBootstrapMaterial.rejectCredentials(addonEnvelope)
            try VortxLegacyBootstrapMaterial.rejectCredentials(overlay)
            // A row or descriptor this view cannot carry becomes a held marker; the adapter holds
            // that one unit, and the exact response bytes stay bound to the source proof.
            let rows: [Object] = libraryRows.map { raw in
                do { return try projectOwnLibraryRow(raw) } catch {
                    return [heldReasonKey: (error as? ReconciliationRequired)?.reason ?? "Malformed own-account library row"]
                }
            }
            let descriptors: [Object] = addons.map { raw in
                guard let descriptor = raw as? Object else { return [heldReasonKey: "Malformed own-account add-on descriptor"] }
                guard let manifest = descriptor["manifest"] as? Object, (try? string(manifest, "id")) != nil else {
                    return [heldReasonKey: "Own-account add-on requires a manifest"]
                }
                return descriptor
            }
            var vortx: Object = ["library": rows, "addons": descriptors]
            var document: Object = ["vortx": vortx,
                                    "addonOrder": descriptors.compactMap { try? string($0, "transportUrl") }]
            guard Set(overlay.keys).isSubset(of: ["vortx", "webProgress"]) else {
                throw fail("Own-account overlay has unsupported source carrier")
            }
            if let rawVortx = try object(overlay, "vortx") {
                guard Set(rawVortx.keys) == ["byProfile"],
                      let byProfile = try object(rawVortx, "byProfile"),
                      Set(byProfile.keys) == [profileID],
                      byProfile[profileID] is Object else {
                    throw fail("Own-account overlay must be scoped to its authenticated profile")
                }
                vortx["byProfile"] = byProfile
                document["vortx"] = vortx
            }
            if let rawProgress = try object(overlay, "webProgress") {
                guard Set(rawProgress.keys) == ["removed"],
                      let removed = try object(rawProgress, "removed"),
                      Set(removed.keys) == ["byProfile"],
                      let byProfile = try object(removed, "byProfile"),
                      Set(byProfile.keys) == [profileID],
                      byProfile[profileID] is [Any] else {
                    throw fail("Own-account overlay removals must be scoped to its authenticated profile")
                }
                document["webProgress"] = ["removed": ["byProfile": byProfile]]
            }
            return document
        }

        private static func projectOwnLibraryRow(_ raw: Any) throws -> Object {
            guard let row = raw as? Object else { throw fail("Malformed own-account library row") }
            let id = try string(row, "_id")
            let type = try contentType(row)
            var projected: Object = ["id": id, "type": type]
            if let name = try optionalString(row, "name") { projected["name"] = name }
            if let poster = try optionalString(row, "poster") { projected["poster"] = poster }
            if let removed = try boolean(row, "removed") { projected["removed"] = removed }
            if let temporary = try boolean(row, "temp") { projected["temp"] = temporary }
            guard let state = try object(row, "state") else { return projected }
            if let offset = try ownMilliseconds(state, "timeOffset") { projected["t"] = ownSeconds(offset) }
            if let duration = try ownMilliseconds(state, "duration") { projected["d"] = ownSeconds(duration) }
            if let watchedAt = try optionalString(state, "lastWatched") { projected["lastWatched"] = watchedAt }
            if let video = try optionalString(state, "video_id") { projected["v"] = video }
            if let count = try ownCount(state, "timesWatched") { projected["timesWatched"] = count }
            if let flagged = try ownFlag(state, "flaggedWatched") { projected["currentVideoWatched"] = flagged }
            if let opaque = try optionalString(state, "watched") { projected["watched"] = opaque }
            return projected
        }

        private static func ownMilliseconds(_ root: Object, _ key: String) throws -> Int64? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 9_007_199_254_740_990,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw fail("Malformed own-account millisecond state " + key)
            }
            return number.int64Value
        }

        func ownerHistoryRows(_ rows: [Any], profileID: UUID) throws -> Object {
            let profile = profileID.uuidString
            var items: [Object] = []
            var identities: [String: Data] = [:]
            for (index, raw) in rows.enumerated() {
                try unit("owner_history_row") {
                    let row = try Self.projectOwnLibraryRow(raw)
                    let id = try string(row, "id"), type = try contentType(row), key = type + ":" + id
                    guard identities[key] == nil else { throw fail("Duplicate or Unicode-ambiguous owner history identity") }
                    identities[key] = Data(key.utf8)
                    try known(profile, id, row)
                    // Membership and watch remain distinct source facts. A removed/temp source row
                    // contributes no saved item and NO invented membership tombstone/weak epoch.
                    // This additive evidence cannot erase an earlier source or a native register.
                    if try boolean(row, "removed") != true && boolean(row, "temp") != true {
                        var item: Object = ["kind": "standard", "id": id, "type": type,
                                             "name": try optionalString(row, "name") ?? ""]
                        if let poster = try optionalString(row, "poster"), !poster.isEmpty { item["poster"] = poster }
                        items.append(item)
                    }
                    try importWatch(profile, id, row, history: false, overlay: false,
                        locator: .ownerAccountLibraryResponse(index: index))
                    try importMarks(profile, id, row, sourceField: "/libraryResponseBase64/result/\(index)")
                }
            }
            let resolved = try resolveWatches(watches[profile] ?? [], held: &held, kind: "owner_history_watch")
            return ["library": ["items": items, "intents": []], "watches": resolved, "identityLinks": []]
        }

        /// `milliseconds` below parses the decimal representation and multiplies it by 1,000.
        /// Preserve an incoming integral millisecond value as Decimal seconds so values close to
        /// the documented 2^53-safe bound do not take an IEEE-754 rounding detour.
        private static func ownSeconds(_ milliseconds: Int64) -> NSDecimalNumber {
            let decimal = Decimal(string: String(milliseconds), locale: Locale(identifier: "en_US_POSIX"))!
            return NSDecimalNumber(decimal: decimal / 1000)
        }

        private static func ownCount(_ root: Object, _ key: String) throws -> Int64? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 0xffff_ffff,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw fail("Malformed own-account count " + key)
            }
            return number.int64Value
        }

        private static func ownFlag(_ root: Object, _ key: String) throws -> Bool? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 0 || number.doubleValue == 1 else {
                throw fail("Malformed own-account watched flag")
            }
            return number.doubleValue == 1
        }

        private convenience init(independentSource document: Object, profile: UserProfile) throws {
            try self.init(document: document, roster: [profile], ownerID: profile.id, modified: nil,
                          deferProfileEdits: false, allowIndependentSource: true)
        }

        private struct ResolvedOwnSources {
            let material: [String: ResolvedOwnAccountSource]
            let overlayAuthority: [String: ResolvedOwnAccountSource]
        }
        private func resolveOwnAccountSources(_ rawSources: [OwnAccountSource], retainedBaseline: Data?,
                                              retainedSourceEnvelopes: [RetainedOwnAccountSourceEnvelope],
                                              retainedSlotBaselines: [RetainedOwnAccountSlotBaseline],
                                              origins: [UUID: AccountOrigin], isolatedIDs: Set<UUID>) throws -> ResolvedOwnSources {
            let ownProfiles = roster.filter { !$0.isOwner && !isolatedIDs.contains($0.id)
                && (origins[$0.id] == .own || (origins[$0.id] == nil && $0.usesOwnAccount)) }
            let requiredIDs = Set(ownProfiles.map(\.id))
            var sources: [String: ResolvedOwnAccountSource] = [:]
            for source in rawSources {
                try require(requiredIDs.contains(source.profileID), "Authenticated source conflicts with original account policy")
                let profileID = source.profileID.uuidString
                try require(sources[profileID] == nil, "Duplicate own-account source receipt")
                try require(source.verifiedStreamingUID == source.verifiedStreamingUID.trimmingCharacters(in: .whitespacesAndNewlines)
                            && !source.verifiedStreamingUID.isEmpty
                            && source.verifiedStreamingUID.utf8.count <= 256
                            && !source.verifiedStreamingUID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                            "Own-account source lacks a verified streaming identity")
                try require(source.sourceDocumentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                            "Own-account source has an invalid document digest")
                try require(source.profileOverlaySHA256 == nil || source.profileOverlaySHA256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                            "Own-account source has an invalid overlay witness")
                let envelopeVersion = try Self.ownAccountEnvelopeVersion(source.sourceDocument)
                try require(envelopeVersion == 1 || envelopeVersion == 2, "Own-account source has an unsupported envelope version")
                try require(envelopeVersion == 2 ? source.profileOverlaySHA256 != nil : source.profileOverlaySHA256 == nil,
                            envelopeVersion == 2 ? "Own-account source v2 requires an overlay witness" : "Own-account source v1 cannot invent an overlay witness")
                if let witness = source.profileOverlaySHA256 {
                    try require(witness == Self.envelopeOverlayWitness(source.sourceDocument),
                                "Own-account source overlay witness does not match its exact envelope")
                }
                let document = try Self.decodeOwnAccountEnvelope(source.sourceDocument, profileID: profileID)
                sources[profileID] = ResolvedOwnAccountSource(profileID: profileID,
                    verifiedStreamingUID: source.verifiedStreamingUID,
                    sourceDocumentSHA256: source.sourceDocumentSHA256, profileOverlaySHA256: source.profileOverlaySHA256, sourceDocument: document, retainedBuckets: nil)
            }
            let freshSourceIDs = Set(sources.keys)
            let historical = try retainedOwnAccountSources(retainedBaseline, requiredProfiles: ownProfiles)
            let activeSlots = try retainedOwnAccountSlotSources(retainedSlotBaselines.filter { requiredIDs.contains($0.profileID) }, requiredProfiles: ownProfiles)
            var overlayAuthority = sources
            for profile in ownProfiles where sources[profile.id.uuidString] == nil {
                let id = profile.id.uuidString
                guard let acknowledgedOverlay = Self.preferredRetainedSource(profileID: id,
                                                                 activeSlots: activeSlots, historical: historical) else {
                    throw fail("Own-account profiles require exactly one authenticated streaming-account source")
                }
                // A slot refresh already owns its causal native events. Relifting its newer
                // watch/membership buckets into the older global migration receipt would replay
                // those events as new legacy edits and can reject on equal native clocks.
                // Reconcile against the latest acknowledged global receipt, not the immutable
                // first bootstrap. The active tuple remains authority for exact overlay proofs.
                try require(retainedBaseline == nil || historical[id] != nil,
                            "An active own slot cannot become a new global legacy source")
                sources[id] = historical[id] ?? acknowledgedOverlay
                overlayAuthority[id] = acknowledgedOverlay
            }
            var retainedEnvelopeIDs = Set<String>()
            for envelope in retainedSourceEnvelopes {
                let profileID = envelope.profileID.uuidString
                try require(retainedEnvelopeIDs.insert(profileID).inserted, "Duplicate retained own-account source envelope")
                try require(!freshSourceIDs.contains(profileID), "Retained source envelope conflicts with a fresh authenticated source")
                guard let retainedSource = overlayAuthority[profileID], let retainedBuckets = retainedSource.retainedBuckets else {
                    throw fail("Retained source envelope lacks a validated own-account tuple")
                }
                try require(envelope.sourceDocumentSHA256 == retainedSource.sourceDocumentSHA256,
                            "Retained source envelope does not match the acknowledged source digest")
                let document = try Self.decodeOwnAccountEnvelope(envelope.sourceDocument, profileID: profileID)
                try require(retainedSource.isRetained, "Retained source envelope has no active own-account profile")
                let enveloped = ResolvedOwnAccountSource(profileID: profileID,
                    verifiedStreamingUID: retainedSource.verifiedStreamingUID,
                    sourceDocumentSHA256: retainedSource.sourceDocumentSHA256,
                    profileOverlaySHA256: retainedSource.profileOverlaySHA256,
                    sourceDocument: document, retainedBuckets: retainedBuckets)
                overlayAuthority[profileID] = enveloped
                // A current source archive must never relabel the older material tuple.
                if sources[profileID]?.sourceDocumentSHA256 == retainedSource.sourceDocumentSHA256 {
                    sources[profileID] = enveloped
                }
            }
            let ownIDs = Set(ownProfiles.map { $0.id.uuidString })
            try require(Set(sources.keys) == ownIDs, "Own-account profiles require exactly one authenticated streaming-account source")
            return ResolvedOwnSources(material: sources, overlayAuthority: overlayAuthority)
        }

        /// `legacyImport.baseline` is the latest acknowledged global account source. A current active
        /// slot can prove an overlay already consumed by a verified refresh of that same UID.
        /// This is overlay authority only, not permission to replace migration material buckets.
        /// A distinct A→B rebind cannot attribute the historical UUID-only A overlay to B.
        private static func preferredRetainedSource(profileID: String, activeSlots: [String: ResolvedOwnAccountSource],
                                                    historical: [String: ResolvedOwnAccountSource]) -> ResolvedOwnAccountSource? {
            guard let historical = historical[profileID] else { return activeSlots[profileID] }
            guard let active = activeSlots[profileID], active.verifiedStreamingUID == historical.verifiedStreamingUID else {
                return historical
            }
            return active
        }

        private func retainedOwnAccountSlotSources(_ baselines: [RetainedOwnAccountSlotBaseline],
                                                   requiredProfiles: [UserProfile]) throws -> [String: ResolvedOwnAccountSource] {
            let required = Set(requiredProfiles.map { $0.id.uuidString })
            var result: [String: ResolvedOwnAccountSource] = [:]
            for baseline in baselines {
                let id = baseline.profileID.uuidString
                try require(required.contains(id), "Active own-account slot does not belong to the current own roster")
                try require(result[id] == nil, "Duplicate active own-account slot baseline")
                let carrier = try Self.decodeSlotBaseline(baseline.sourceBaseline, profileID: id)
                result[id] = carrier
            }
            return result
        }

        fileprivate func classifyDeferredOwnAccountOverlays(retainedBaseline: Data?,
                                                        retainedSourceEnvelopes: [RetainedOwnAccountSourceEnvelope],
                                                        retainedSlotBaselines: [RetainedOwnAccountSlotBaseline],
                                                        rootDocumentSHA256: String) throws -> [RetainedOwnAccountOverlayDisposition] {
            let origins = try VortxLegacyBootstrapMaterial.accountOrigins(retainedBaseline)
            let ownProfiles = roster.filter { !$0.isOwner
                && (origins[$0.id] == .own || (origins[$0.id] == nil && $0.usesOwnAccount)) }
            let requiredIDs = Set(ownProfiles.map(\.id))
            let historical = try retainedOwnAccountSources(retainedBaseline, requiredProfiles: ownProfiles)
            let activeSlots = try retainedOwnAccountSlotSources(retainedSlotBaselines.filter { requiredIDs.contains($0.profileID) }, requiredProfiles: ownProfiles)
            var envelopes: [String: Object] = [:]
            for envelope in retainedSourceEnvelopes {
                let id = envelope.profileID.uuidString
                try require(envelopes[id] == nil, "Duplicate retained own-account source envelope")
                guard let retained = Self.preferredRetainedSource(profileID: id, activeSlots: activeSlots,
                                                                   historical: historical) else {
                    throw fail("Retained source envelope lacks a validated own-account tuple")
                }
                try require(envelope.sourceDocumentSHA256 == retained.sourceDocumentSHA256,
                            "Retained source envelope does not match the acknowledged source digest")
                envelopes[id] = try Self.decodeOwnAccountEnvelope(envelope.sourceDocument, profileID: id)
            }
            return try ownProfiles.compactMap { profile in
                let id = profile.id.uuidString
                let slice = try Self.profileOverlaySlice(document, profileID: id)
                guard !slice.isEmpty else { return nil }
                let currentWitness = try Self.profileOverlayWitness(slice)
                guard let retained = Self.preferredRetainedSource(profileID: id, activeSlots: activeSlots,
                                                                   historical: historical) else {
                    return RetainedOwnAccountOverlayDisposition(profileID: profile.id, sourceDocumentSHA256: nil,
                        retainedProfileOverlaySHA256: nil, currentProfileOverlaySHA256: currentWitness,
                        status: .missingRetainedSource, rootDocumentSHA256: rootDocumentSHA256)
                }
                if let witness = retained.profileOverlaySHA256 {
                    return RetainedOwnAccountOverlayDisposition(profileID: profile.id,
                        sourceDocumentSHA256: retained.sourceDocumentSHA256, retainedProfileOverlaySHA256: witness,
                        currentProfileOverlaySHA256: currentWitness,
                        status: witness == currentWitness ? .matchedWitness : .changedWitness,
                        rootDocumentSHA256: rootDocumentSHA256)
                }
                if let envelope = envelopes[id] {
                    let sourceSlice = try Self.profileOverlaySlice(envelope, profileID: id)
                    return RetainedOwnAccountOverlayDisposition(profileID: profile.id,
                        sourceDocumentSHA256: retained.sourceDocumentSHA256, retainedProfileOverlaySHA256: nil,
                        currentProfileOverlaySHA256: currentWitness,
                        status: try Self.equivalentJSON(slice, sourceSlice) ? .matchedSealedEnvelope : .changedWitness,
                        rootDocumentSHA256: rootDocumentSHA256)
                }
                return RetainedOwnAccountOverlayDisposition(profileID: profile.id,
                    sourceDocumentSHA256: retained.sourceDocumentSHA256, retainedProfileOverlaySHA256: nil,
                    currentProfileOverlaySHA256: currentWitness, status: .missingWitness,
                    rootDocumentSHA256: rootDocumentSHA256)
            }
        }

        private static func envelopeOverlayWitness(_ source: Data) throws -> String {
            guard let envelope = try JSONSerialization.jsonObject(with: source) as? Object,
                  let raw = envelope["profileOverlayBase64"] as? String, let bytes = Data(base64Encoded: raw),
                  bytes.base64EncodedString() == raw else { throw fail("Own-account source envelope lacks an exact overlay") }
            return try VortxProfileOverlayWitness.digest(json: bytes)
        }

        private static func ownAccountEnvelopeVersion(_ source: Data) throws -> Int {
            guard let envelope = try JSONSerialization.jsonObject(with: source) as? Object,
                  let version = envelope["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                  Double(version.intValue) == version.doubleValue else { throw fail("Own-account source envelope is malformed") }
            return version.intValue
        }

        /// A cold peer can retain only the kernel-validated typed tuple. The caller has already
        /// validated nativeSync's receipt/history and selected `legacyImport.baseline`; this local
        /// structural check prevents a stale, cross-profile, or partial tuple from standing in for
        /// a fresh authenticated source. It intentionally never derives a new source digest.
        private func retainedOwnAccountSources(_ bytes: Data?, requiredProfiles: [UserProfile]) throws -> [String: ResolvedOwnAccountSource] {
            guard let bytes else { return [:] }
            guard let baseline = try? VortxProfileOverlayWitness.decodeObject(json: bytes),
                  let version = baseline["schemaVersion"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), Double(version.intValue) == version.doubleValue,
                  version.intValue == 1 || version.intValue == 2 else {
                throw fail("Retained own-account baseline has an unsupported material schema")
            }
            // Material 1 predates own-account sources. It says nothing about a profile that was
            // made own-account later, so a complete active schema-4 slot may supply that profile's
            // current tuple. It must not be mistaken for a malformed partial material-2 tuple.
            guard version.intValue == 2 else { return [:] }
            guard let roster = try array(baseline, "roster"),
                  let sourceRows = try object(baseline, "ownAccountSources"),
                  let addons = try object(baseline, "addons"),
                  let libraries = try object(baseline, "libraries"),
                  let watches = try object(baseline, "watches"),
                  let links = try object(baseline, "identityLinks") else {
                throw fail("Retained own-account baseline is not complete material 2")
            }
            var profiles: [String: Object] = [:]
            for raw in roster {
                guard let profile = raw as? Object else { throw fail("Retained own-account baseline has a malformed roster") }
                let id = try string(profile, "id")
                try require(profiles[id] == nil, "Retained own-account baseline has duplicate profiles")
                profiles[id] = profile
            }
            var retained: [String: ResolvedOwnAccountSource] = [:]
            for profile in requiredProfiles {
                let id = profile.id.uuidString
                guard let source = try object(sourceRows, id) else {
                    // The profile did not have an own source at the time this immutable baseline
                    // was written. Buckets alongside an absent source would be a partial claim,
                    // not an unknown historical state, so keep that closed.
                    try require(addons[id] == nil && libraries[id] == nil && watches[id] == nil && links[id] == nil,
                                "Retained own-account baseline has a partial absent profile tuple")
                    continue
                }
                guard
                      Set(source.keys).isSubset(of: ["verifiedStreamingUid", "sourceDocumentSha256", "profileOverlaySha256"]),
                      let uid = try optionalString(source, "verifiedStreamingUid"),
                      uid == uid.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
                      uid.utf8.count <= 256, uid.rangeOfCharacter(from: .controlCharacters) == nil,
                      let digest = try optionalString(source, "sourceDocumentSha256"),
                      digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      let retainedProfile = profiles[id],
                      try boolean(retainedProfile, "owner") == false,
                      let account = try object(retainedProfile, "account"),
                      try optionalString(account, "kind") == "own", try optionalString(account, "value") == uid,
                      try optionalString(retainedProfile, "addons") == "own",
                      let addonBucket = try object(addons, id),
                      Set(addonBucket.keys) == ["items", "order", "intents"],
                      let addonItems = try array(addonBucket, "items"),
                      let addonOrder = try array(addonBucket, "order"),
                      let addonIntents = try array(addonBucket, "intents"),
                      let libraryBucket = try object(libraries, id),
                      Set(libraryBucket.keys) == ["items", "intents"],
                      let libraryItems = try array(libraryBucket, "items"),
                      let libraryIntents = try array(libraryBucket, "intents"),
                      let watchRows = try array(watches, id),
                      let linkRows = try array(links, id) else {
                    throw fail("Retained own-account baseline lacks a complete authenticated profile tuple")
                }
                let identityLinks = try linkRows.map { raw -> [String] in
                    guard let row = raw as? [String] else { throw fail("Retained own-account baseline has malformed identity links") }
                    return row
                }
                let witness = try optionalString(source, "profileOverlaySha256")
                try require(witness == nil || witness!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                            "Retained own-account baseline has an invalid overlay witness")
                retained[id] = ResolvedOwnAccountSource(profileID: id, verifiedStreamingUID: uid,
                    sourceDocumentSHA256: digest, profileOverlaySHA256: witness, sourceDocument: nil,
                    retainedBuckets: OwnAccountBuckets(addons: ["items": addonItems, "order": addonOrder, "intents": addonIntents],
                                                       library: ["items": libraryItems, "intents": libraryIntents],
                                                       watches: try watchRows.map { raw in
                        guard let row = raw as? Object else { throw fail("Retained own-account baseline has malformed watches") }
                        return row
                    }, titles: [:], identityLinks: identityLinks))
            }
            return retained
        }

        private func validateOwnProfileOverlayBindings(_ sources: [String: ResolvedOwnAccountSource],
                                                       deferred: [RetainedOwnAccountOverlayDisposition],
                                                       rootDocumentSHA256: String) throws {
            var deferrals: [String: RetainedOwnAccountOverlayDisposition] = [:]
            for disposition in deferred {
                let id = disposition.profileID.uuidString
                try require(deferrals[id] == nil, "Duplicate deferred own-account overlay")
                try require(disposition.rootDocumentSHA256 == rootDocumentSHA256,
                            "Deferred own-account overlay belongs to another root document")
                deferrals[id] = disposition
            }
            for (profileID, source) in sources {
                let rootSlice = try Self.profileOverlaySlice(document, profileID: profileID)
                if let disposition = deferrals.removeValue(forKey: profileID) {
                    // The classifier proof binds current bytes to a separately acknowledged
                    // overlay tuple. It can retain an unmatched slice as pending, but cannot
                    // change the typed reconciliation material or invent a source assertion.
                    try require(source.isRetained, "Deferred own-account overlay has no retained source")
                    try require(disposition.sourceDocumentSHA256 == source.sourceDocumentSHA256,
                                "Deferred own-account overlay does not match the retained source digest")
                    try require(disposition.retainedProfileOverlaySHA256 == source.profileOverlaySHA256,
                                "Deferred own-account overlay does not match the retained source witness")
                    try require(disposition.currentProfileOverlaySHA256 == Self.profileOverlayWitness(rootSlice),
                                "Deferred own-account overlay does not match the current root slice")
                    continue
                }
                if let sourceDocument = source.sourceDocument {
                    let sourceSlice = try Self.profileOverlaySlice(sourceDocument, profileID: profileID)
                    try require(try Self.equivalentJSON(rootSlice, sourceSlice),
                                "Own-account root overlay differs from its authenticated source")
                } else {
                    if rootSlice.isEmpty { continue }
                    throw fail("Current own-account overlay requires an authenticated source refresh")
                }
            }
            try require(deferrals.isEmpty, "Deferred own-account overlay has no retained own-account profile")
        }

        /// Extract the only two scoped overlay carriers. A lowercased or duplicate UUID key would
        /// make the root and source disagree about the authenticated identity, so refuse it rather
        /// than normalizing a potentially unrelated bucket into a source proof.
        private static func profileOverlaySlice(_ document: Object, profileID: String) throws -> Object {
            var slice: Object = [:]
            if let vortx = try object(document, "vortx"), let byProfile = try object(vortx, "byProfile") {
                let keys = byProfile.keys.filter { UUID(uuidString: $0)?.uuidString == profileID }
                try require(keys.count <= 1 && (keys.isEmpty || keys[0] == profileID),
                            "Own-account overlay has an ambiguous profile identity")
                if let bucket = byProfile[profileID] {
                    guard bucket is Object else { throw fail("Own-account overlay has a malformed profile bucket") }
                    slice["vortx"] = ["byProfile": [profileID: bucket]]
                }
            }
            if let progress = try object(document, "webProgress"), let removed = try object(progress, "removed"),
               let byProfile = try object(removed, "byProfile") {
                let keys = byProfile.keys.filter { UUID(uuidString: $0)?.uuidString == profileID }
                try require(keys.count <= 1 && (keys.isEmpty || keys[0] == profileID),
                            "Own-account overlay removals have an ambiguous profile identity")
                if let removals = byProfile[profileID] {
                    guard removals is [Any] else { throw fail("Own-account overlay has malformed profile removals") }
                    slice["webProgress"] = ["removed": ["byProfile": [profileID: removals]]]
                }
            }
            return slice
        }

        private static func equivalentJSON(_ lhs: Object, _ rhs: Object) throws -> Bool {
            try JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys, .withoutEscapingSlashes]) ==
                JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        private static func profileOverlayWitness(_ slice: Object) throws -> String {
            try VortxProfileOverlayWitness.digest(json: JSONSerialization.data(withJSONObject: slice,
                                                                                 options: [.sortedKeys, .withoutEscapingSlashes]))
        }

        private static func decodeSlotBaseline(_ bytes: Data, profileID: String) throws -> ResolvedOwnAccountSource {
            guard let carrier = try? VortxProfileOverlayWitness.decodeObject(json: bytes),
                  Set(carrier.keys) == ["source", "addons", "library", "watches", "identityLinks"],
                  let source = try object(carrier, "source"),
                  Set(source.keys) == ["verifiedStreamingUid", "sourceDocumentSha256"]
                    || Set(source.keys) == ["verifiedStreamingUid", "sourceDocumentSha256", "profileOverlaySha256"],
                  let uid = try optionalString(source, "verifiedStreamingUid"),
                  uid == uid.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
                  uid.utf8.count <= 256, uid.rangeOfCharacter(from: .controlCharacters) == nil,
                  let digest = try optionalString(source, "sourceDocumentSha256"),
                  digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let addons = try object(carrier, "addons"), Set(addons.keys) == ["items", "order", "intents"],
                  let addonItems = try array(addons, "items"), let addonOrder = try array(addons, "order"),
                  let addonIntents = try array(addons, "intents"),
                  let library = try object(carrier, "library"), Set(library.keys) == ["items", "intents"],
                  let libraryItems = try array(library, "items"), let libraryIntents = try array(library, "intents"),
                  let watches = try array(carrier, "watches"), let links = try array(carrier, "identityLinks") else {
                throw fail("Active own-account slot baseline is malformed")
            }
            let identityLinks = try links.map { raw -> [String] in
                guard let row = raw as? [String] else { throw fail("Active own-account slot baseline has malformed identity links") }
                return row
            }
            let witness = try optionalString(source, "profileOverlaySha256")
            try require(witness == nil || witness!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                        "Active own-account slot baseline has an invalid overlay witness")
            return ResolvedOwnAccountSource(profileID: profileID, verifiedStreamingUID: uid,
                sourceDocumentSHA256: digest, profileOverlaySHA256: witness, sourceDocument: nil,
                retainedBuckets: OwnAccountBuckets(addons: ["items": addonItems, "order": addonOrder, "intents": addonIntents],
                                                   library: ["items": libraryItems, "intents": libraryIntents],
                                                   watches: try watches.map { raw in
                    guard let row = raw as? Object else { throw fail("Active own-account slot baseline has malformed watches") }
                    return row
                }, titles: [:], identityLinks: identityLinks))
        }

        func addonBucket() throws -> Object {
            var descriptors: [String: Object] = [:]
            var descriptorOrder: [String] = []
            // The app-owned descriptor wins against a stale generic imported descriptor.
            for rows in [try array(vortx, "addons") ?? [], try array(document, "addons") ?? []] {
                for value in rows {
                    try unit("addon") {
                        guard let raw = value as? Object else { throw fail("Malformed object row addons") }
                        try heldSource(raw)
                        let url = try normalizeURL(string(raw, "transportUrl"))
                        guard let manifest = try object(raw, "manifest") else { throw fail("URL-only add-on requires manifest reconciliation") }
                        _ = try string(manifest, "id"); _ = try string(manifest, "name"); _ = try string(manifest, "version")
                        if let flags = try object(raw, "flags") {
                            _ = try boolean(flags, "official"); _ = try boolean(flags, "protected")
                        }
                        // Checked per descriptor so one credential-bearing manifest holds only itself.
                        try rejectCredentials(raw)
                        if descriptors[url] == nil {
                            var row = raw; row["transportUrl"] = url
                            descriptors[url] = row; descriptorOrder.append(url)
                        }
                    }
                }
            }
            func resolve(_ raw: String) throws -> String {
                let url = try normalizeURL(raw)
                let matches = descriptors.keys.filter { $0.lowercased() == url.lowercased() }
                // Old writers lowercased the whole URL. Even an exact lowercase descriptor cannot
                // disambiguate that spelling when a second configured path differs only by case.
                if url == url.lowercased() { try require(matches.count <= 1, "Ambiguous legacy add-on URL identity") }
                if descriptors[url] != nil { return url }
                try require(matches.count <= 1, "Ambiguous legacy add-on URL identity")
                return matches.first ?? url
            }
            var intents: [String: Object] = [:]
            var publishedStamps = Set<String>()
            var exactIntentCarriers: [String: Object] = [:]
            var exactDeletedCarriers: [String: [String]] = [:]
            var exactWebRemovalCarriers: [String: [String]] = [:]
            // Spellings of one URL merge into one intent, so they are held or kept together.
            let rawIntents = try object(vortx, "deletedAddonsTs") ?? [:]
            var spellings: [String: [String]] = [:]
            for raw in rawIntents.keys.sorted() {
                try unit("addon_intent") { spellings[try resolve(raw), default: []].append(raw) }
            }
            for url in spellings.keys.sorted() {
                try unit("addon_intent") {
                    var intent: Object = ["transportUrl": url]
                    var stamped = false
                    for raw in spellings[url] ?? [] {
                        guard let entry = rawIntents[raw] as? Object else { throw fail("Malformed add-on intent") }
                        try require(Set(entry.keys).isSubset(of: ["addedAt", "removedAt", "intentV3"]), "Unsupported add-on intent carrier")
                        if try clock(entry, "addedAt") != nil || clock(entry, "removedAt") != nil { stamped = true }
                        try mergeClock(entry, into: &intent, from: "addedAt", to: "addedAtMs")
                        try mergeClock(entry, into: &intent, from: "removedAt", to: "removedAtMs")
                        if let rawIntent = entry["intentV3"] {
                            let typed = try legacyAddonIntentV3(rawIntent)
                            if let previous = intent["intentV3"] as? Object {
                                intent["intentV3"] = try mergeLegacyAddonIntentV3(previous, typed)
                            } else { intent["intentV3"] = typed }
                        }
                    }
                    for raw in spellings[url] ?? [] { exactIntentCarriers[url, default: [:]][raw] = rawIntents[raw] }
                    if stamped { publishedStamps.insert(url) }
                    intents[url] = intent
                }
            }
            for value in try array(vortx, "deletedAddons") ?? [] {
                try unit("addon_removal") {
                    guard let raw = value as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw fail("Malformed identity deletedAddons")
                    }
                    let url = try resolve(raw)
                    // Shipping AddonTombstones migration epoch is 1ms, not a fabricated 'now'.
                    if intents[url]?["addedAtMs"] == nil && intents[url]?["removedAtMs"] == nil && intents[url]?["intentV3"] == nil {
                        try require(!publishedStamps.contains(url), "Ambiguous zero-stamp add-on removal requires reconciliation")
                        intents[url] = ["transportUrl": url, "removedAtMs": 1.0]
                    }
                    exactDeletedCarriers[url, default: []].append(raw)
                }
            }
            for value in try array(document, "webAddonRemovals") ?? [] {
                try unit("addon_web_removal") {
                    guard let raw = value as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw fail("Malformed identity webAddonRemovals")
                    }
                    let url = try resolve(raw)
                    let intent = intents[url] ?? [:]
                    try require(intent["intentV3"] != nil || (try clock(intent, "addedAtMs") ?? 0) > 0 || (try clock(intent, "removedAtMs") ?? 0) > 0,
                                "Unclocked web add-on removal requires reconciliation")
                    exactWebRemovalCarriers[url, default: []].append(raw)
                }
            }
            for url in intents.keys.sorted() {
                let kept = try unit("addon_intent") {
                    let row = intents[url] ?? [:]
                    let added = try clock(row, "addedAtMs") ?? 0, removed = try clock(row, "removedAtMs") ?? 0
                    let live = try legacyAddonIntentV3IsPresent(row, added: added, removed: removed)
                    if live && descriptors[url] == nil && preparePendingMembership {
                        let exact = exactIntentCarriers[url] ?? [:]
                        try require(!exact.isEmpty, "Live add-on install requires descriptor reconciliation")
                        try retainPendingMembership(kind: "addon_install", profileID: owner.id.uuidString, identity: url,
                            sourceField: "/vortx/deletedAddonsTs", receipt: ["deletedAddonsTs": exact,
                                "deletedAddons": exactDeletedCarriers[url] ?? [],
                                "webAddonRemovals": exactWebRemovalCarriers[url] ?? []])
                        intents.removeValue(forKey: url)
                        return
                    }
                    try require(!live || descriptors[url] != nil,
                                "Live add-on install requires descriptor reconciliation")
                }
                if !kept { intents.removeValue(forKey: url) }
            }
            var order: [String] = []
            for value in try array(document, "addonOrder") ?? [] {
                try unit("addon_order") {
                    guard let raw = value as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw fail("Malformed identity addonOrder")
                    }
                    let url = try resolve(raw)
                    try require(descriptors[url] != nil && !order.contains(url), "Add-on order has duplicate or unknown descriptors")
                    order.append(url)
                }
            }
            return ["items": descriptorOrder.compactMap { descriptors[$0] }, "order": order,
                    "intents": intents.keys.sorted().compactMap { intents[$0] }]
        }

        func ownerLibrary() throws -> Object {
            let ownerID = owner.id.uuidString
            let rows = try array(vortx, "library") ?? array(document, "library") ?? []
            var items: [String: Object] = [:], intents: [String: Object] = [:]
            var removedRows = Set<String>(), publishedStamps = Set<String>()
            var seen = Set<String>()
            for (index, value) in rows.enumerated() {
                try unit("library_row") {
                    guard let row = value as? Object else { throw fail("Malformed owner library row") }
                    try heldSource(row)
                    let id = try string(row, "id"), type = try contentType(row)
                    let key = type + ":" + id
                    try require(!seen.contains(key), "Duplicate owner library identity")
                    var item: Object = ["kind": "standard", "id": id, "type": type, "name": try optionalString(row, "name") ?? ""]
                    if let poster = try optionalString(row, "poster"), !poster.isEmpty { item["poster"] = poster }
                    let temporary = try boolean(row, "temp") == true
                    let removed = try boolean(row, "removed") == true
                    if temporary && !independentSource { throw fail("Temporary owner-library membership requires reconciliation") }
                    try known(ownerID, id, row)
                    let locator: LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator = independentSource
                        ? .ownAccountLibraryResponse(index: index)
                        : (vortx["library"] is [Any] ? .authenticatedOwnerLibrary(index: index) : .authenticatedLegacyRootLibrary(index: index))
                    // Viewing state is its own unit: a progress record the engine cannot represent is
                    // held without dropping the title's saved membership.
                    try unit("library_progress") {
                        try importWatch(ownerID, id, row, history: false, overlay: false, locator: locator)
                        try importMarks(ownerID, id, row, sourceField: locator.pointer)
                    }
                    seen.insert(key)
                    if removed && !temporary {
                        // eventEpochMs/lastWatched describe viewing, not membership removal. Require
                        // a separately proven library tombstone below; never promote a viewing clock.
                        // A freshly authenticated own-account baseline has no causal deletion clock;
                        // its explicit `removed:true` is represented by the documented weak epoch 1.
                        removedRows.insert(key)
                        if independentSource { intents[key] = ["key": key, "removedAtMs": 1.0] }
                    } else if !temporary { items[key] = item }
                }
            }
            do {
                let buckets = try object(vortx, "byProfile") ?? [:]
                for rawID in buckets.keys.sorted() where UUID(uuidString: rawID) == UserProfile.ownerID || UUID(uuidString: rawID) == owner.id {
                    try unit("owner_history") {
                        guard let bucket = buckets[rawID] as? Object else { throw fail("Malformed owner-history bucket") }
                        for (index, value) in (try array(bucket, "ownerHistory") ?? []).enumerated() {
                            try unit("owner_history") {
                                guard let row = value as? Object else { throw fail("Malformed object row ownerHistory") }
                                let id = try string(row, "id")
                                try known(ownerID, id, row)
                                let locator: LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator = independentSource
                                    ? .ownAccountOwnerHistory(index: index)
                                    : .authenticatedOwnerHistory(sourceProfileID: rawID, index: index)
                                try importWatch(ownerID, id, row, history: true, overlay: false, locator: locator)
                                try importMarks(ownerID, id, row, sourceField: locator.pointer)
                            }
                        }
                    }
                }
            }
            let rawLibraryIntents = try object(vortx, "deletedLibraryTs") ?? [:]
            var rawLibraryDeletes: [String] = []
            for value in try array(vortx, "deletedLibrary") ?? [] {
                try unit("library_removal") {
                    guard let raw = value as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw fail("Malformed identity deletedLibrary")
                    }
                    rawLibraryDeletes.append(raw)
                }
            }
            let exactLibraryDeletes = Dictionary(grouping: rawLibraryDeletes, by: { $0 })
            func keyFor(_ raw: String) throws -> String? {
                let matches = (titles[ownerID] ?? [:]).filter { id, row in
                    let type = row["type"] as? String ?? ""
                    return id.lowercased() == raw.lowercased() || (type + ":" + id).lowercased() == raw.lowercased()
                }
                if matches.isEmpty, let split = raw.firstIndex(of: ":") {
                    let type = String(raw[..<split]), id = String(raw[raw.index(after: split)...])
                    if ["movie", "series"].contains(type) && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return raw // Already typed removal needs no invented catalog metadata.
                    }
                }
                if matches.isEmpty && preparePendingMembership {
                    try require(!raw.isEmpty && raw == raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        && raw.rangeOfCharacter(from: .controlCharacters) == nil, "Pending membership identity is invalid")
                    if exactLibraryDeletes[raw] != nil, let entry = rawLibraryIntents[raw] as? Object {
                        let added = try clock(entry, "addedAt"), removed = try clock(entry, "removedAt")
                        try require(added == nil && removed == nil || (added ?? 0) > 0 || (removed ?? 0) > 0,
                                    "Ambiguous zero-stamp library removal requires reconciliation")
                    }
                    var receipt: Object = ["deletedLibrary": exactLibraryDeletes[raw] ?? []]
                    if let original = rawLibraryIntents[raw] { receipt["deletedLibraryTs"] = [raw: original] }
                    try retainPendingMembership(kind: "library_removal", profileID: owner.id.uuidString, identity: raw,
                                                sourceField: rawLibraryIntents[raw] == nil ? "/vortx/deletedLibrary" : "/vortx/deletedLibraryTs", receipt: receipt)
                    return nil
                }
                try require(matches.count == 1, "Untyped library removal requires title-type reconciliation")
                let match = matches.first!
                return (try contentType(match.value)) + ":" + match.key
            }
            for raw in rawLibraryIntents.keys.sorted() {
                try unit("library_intent") {
                    guard let entry = rawLibraryIntents[raw] as? Object else { throw fail("Malformed library intent") }
                    try require(Set(entry.keys).isSubset(of: ["addedAt", "removedAt"]), "Unsupported library intent carrier")
                    // Validate clocks before deferral: pending is not a malformed-input escape hatch.
                    let added = try clock(entry, "addedAt"), removed = try clock(entry, "removedAt")
                    guard let key = try keyFor(raw) else { return }
                    var intent = intents[key] ?? ["key": key]
                    try mergeClock(entry, into: &intent, from: "addedAt", to: "addedAtMs")
                    try mergeClock(entry, into: &intent, from: "removedAt", to: "removedAtMs")
                    if added != nil || removed != nil { publishedStamps.insert(key) }
                    intents[key] = intent
                }
            }
            for raw in rawLibraryDeletes {
                try unit("library_removal") {
                    guard let key = try keyFor(raw) else { return }
                    if intents[key]?["addedAtMs"] == nil && intents[key]?["removedAtMs"] == nil {
                        try require(!publishedStamps.contains(key), "Ambiguous zero-stamp library removal requires reconciliation")
                        intents[key] = ["key": key, "removedAtMs": 1.0]
                    }
                }
            }
            for key in removedRows.sorted() {
                try unit("library_row") {
                    let intent = intents[key] ?? [:]
                    try require((try clock(intent, "removedAtMs") ?? 0) > (try clock(intent, "addedAtMs") ?? 0),
                                "Owner-library removal lacks a proven membership tombstone")
                }
            }
            for key in intents.keys.sorted() {
                let kept = try unit("library_intent") {
                    let row = intents[key] ?? [:]
                    let added = try clock(row, "addedAtMs") ?? 0, removed = try clock(row, "removedAtMs") ?? 0
                    try require(added <= 0 || added < removed || items[key] != nil,
                                "Live library addition requires descriptor reconciliation")
                }
                if !kept { intents.removeValue(forKey: key) }
            }
            return ["items": items.keys.sorted().compactMap { items[$0] }, "intents": intents.keys.sorted().compactMap { intents[$0] }]
        }

        func importOverlays(excluding excludedProfiles: Set<String> = []) throws {
            let buckets = try object(vortx, "byProfile") ?? [:]
            let progress = try object(document, "webProgress") ?? [:]
            let removed = try object(progress, "removed") ?? [:]
            let web = try object(removed, "byProfile") ?? [:]
            var seen = Set<String>()
            for rawID in Set(buckets.keys).union(web.keys).sorted() {
                // A bucket whose profile cannot be resolved is held whole; its rows hold one by one.
                try unit("profile_overlay") {
                    guard let uuid = UUID(uuidString: rawID) else { throw fail("Watch carrier references an unknown profile") }
                    let id = uuid.uuidString
                    if excludedProfiles.contains(id) { return }
                    try require(seen.insert(id).inserted, "Duplicate profile bucket identity")
                    let bucket = try object(buckets, rawID) ?? [:]
                    if deleted.contains(id) { return } // Retained verbatim in the original encrypted carrier.
                    if uuid == UserProfile.ownerID && profiles[id] == nil {
                        try require(!["library", "watched", "removed"].contains { bucket[$0] != nil } && web[rawID] == nil,
                                    "Ambiguous historical owner overlay")
                        return
                    }
                    try require(profiles[id] != nil, "Watch carrier references an unknown profile")
                    if uuid != owner.id && uuid != UserProfile.ownerID && bucket["ownerHistory"] != nil {
                        throw fail("Owner history attached to a secondary profile")
                    }
                    let rows = try array(bucket, "library") ?? []
                    // Every rail title, held or not, outranks its duplicate durable row below.
                    let railIDs = rows.compactMap { ($0 as? Object).flatMap { try? string($0, "id") } }
                    let railTitles = Set(railIDs)
                    let duplicated = Set(Dictionary(grouping: railIDs, by: { $0 }).filter { $0.value.count > 1 }.keys)
                    for (index, value) in rows.enumerated() {
                        try unit("profile_overlay_row") {
                            guard let row = value as? Object else { throw fail("Malformed object row library") }
                            let meta = try string(row, "id")
                            try require(!duplicated.contains(meta), "Duplicate overlay title snapshots require reconciliation")
                            try known(id, meta, row)
                            let locator: LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator = independentSource
                                ? .ownAccountProfileLibrary(index: index) : .authenticatedProfileLibrary(index: index)
                            let sourceField = sourcePointer(locator, profileID: rawID)
                            try importWatch(id, meta, row, history: false, overlay: true, locator: locator, sourceField: sourceField)
                            try importMarks(id, meta, row, sourceField: sourceField)
                        }
                    }
                    let durable = try object(bucket, "watched") ?? [:]
                    for meta in durable.keys.sorted() {
                        try unit("profile_overlay_watched") {
                            guard let row = durable[meta] as? Object else { throw fail("Malformed durable watched row") }
                            try require(!meta.isEmpty, "Empty durable watch identity")
                            // Apple account-doc ingress gives the complete rail snapshot precedence over
                            // the ENTIRE duplicate durable row, including its explicit ma/ua clocks. The
                            // durable map fills titles beyond the rail; it is not an independent operation log.
                            if !railTitles.contains(meta) {
                                try importMarks(id, meta, row, sourceField: "/vortx/byProfile/" + pointer(rawID) + "/watched/" + pointer(meta))
                            }
                        }
                    }
                    let removals = try (array(bucket, "removed") ?? []).enumerated().map {
                        ("/vortx/byProfile/" + pointer(rawID) + "/removed/" + String($0.offset), $0.element)
                    } + (array(web, rawID) ?? []).enumerated().map {
                        ("/webProgress/removed/byProfile/" + pointer(rawID) + "/" + String($0.offset), $0.element)
                    }
                    for (sourceField, value) in removals {
                        try unit("profile_overlay_removal") {
                            guard let removal = value as? Object else { throw fail("Malformed object row removed") }
                            let keys = try strings(removal, "keys")
                            guard let at = try clock(removal, "removedAt"), at > 0, !keys.isEmpty else { throw fail("Unclocked or empty watch removal") }
                            let matches = (titles[id] ?? [:]).filter { meta, row in
                                keys.contains { removalMatches($0, meta: meta, type: row["type"] as? String ?? "") }
                            }
                            // Several matched titles are NOT proof that they are equivalent. An explicit
                            // alias reconciliation must precede this extraction in that case.
                            try require(matches.count == 1 && keys.allSatisfy { key in
                                matches.contains { removalMatches(key, meta: $0.key, type: $0.value["type"] as? String ?? "") }
                            }, "Watch removal requires verified title reconciliation")
                            let match = matches.first!
                            var row = context(id, match.key)
                            row["removedAtMs"] = at
                            watches[id, default: []].append(row)
                            rememberWatchSource(profileID: id, unit: match.key, sourceField: sourceField, receipt: removal)
                        }
                    }
                }
            }
        }

        func importWatch(_ profile: String, _ meta: String, _ raw: Object, history: Bool, overlay: Bool,
                         locator: LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator,
                         sourceField: String? = nil) throws {
            let start = watches[profile]?.count ?? 0
            let sourceField = sourceField ?? sourcePointer(locator, profileID: profile)
            defer { rememberAppendedWatchSources(profileID: profile, sourceField: sourceField, receipt: raw, from: start) }
            let position = try milliseconds(raw, "t"), duration = try milliseconds(raw, "d")
            let hasPositivePosition = (try clock(raw, "t") ?? 0) > 0
            let iso = try lastWatched(raw)
            let event = try clock(raw, "eventEpochMs")
            if history { try require(event != nil && event! > 0 && iso != nil, "Malformed genuine owner history") }
            let played = history ? event : iso
            let video = try optionalString(raw, "v").flatMap { $0.isEmpty ? nil : $0 }
            let bits = try optionalString(raw, "watched")
            var decoded = [String]()
            if let bits, !bits.isEmpty {
                guard let accountID, let sourceSHA256, let profileID = UUID(uuidString: profile) else {
                    throw fail("Opaque watched bitfield requires episode reconciliation")
                }
                let matching = watchedEvidence.filter { $0.matches(profileID: profileID, sourceSHA256: sourceSHA256, locator: locator) }
                try require(matching.count == 1, "Opaque watched bitfield requires episode reconciliation")
                decoded = try matching[0].videoIDs(accountID: accountID, profileID: profileID, sourceSHA256: sourceSHA256,
                    verifiedStreamingUID: verifiedStreamingUID, locator: locator, metaID: meta, bitmap: bits)
            }
            let watched = try boolean(raw, "currentVideoWatched"), whole = try boolean(raw, "wholeTitleWatched")
            let type = try contentType(raw)
            try require(type != "series" || whole != true, "Whole-series watch intent requires episode reconciliation")
            let marks = try strings(raw, "w")
            let marked = try object(raw, "ma") ?? [:], reset = try object(raw, "ua") ?? [:]
            let hasMarks = !marks.isEmpty || !marked.isEmpty || !reset.isEmpty || !decoded.isEmpty
            let count = try unsigned(raw, "timesWatched", maximum: 0xffff_ffff)
            if overlay && !hasPositivePosition && !hasMarks && watched != true && whole != true {
                if preparePendingMembership {
                    // Even a saved-only row must satisfy the normal known field shapes. It grants
                    // no viewing clock or saved-membership authority to the native projection.
                    _ = try optionalString(raw, "name"); _ = try optionalString(raw, "poster")
                    try retainPendingMembership(kind: "profile_saved_overlay", profileID: profile, identity: meta,
                                                sourceField: sourceField, receipt: raw)
                    return
                }
                throw fail("Saved-only overlay membership requires explicit reconciliation")
            }
            // Bitmap evidence proves bare watched facts only. The normal clocked ma/ua fold
            // below removes this boolean whenever an explicit mark or reset exists.
            for video in decoded {
                var row = context(profile, meta); row["videoId"] = video; row["watched"] = true
                watches[profile, default: []].append(row)
            }
            // Ordinary saved rows can contain a synthetic lastWatched. Only a positive position or
            // an explicit genuine-history carrier proves playback; a watched bit alone proves no play.
            let hasProgress = hasPositivePosition || history
            if !hasProgress && watched != true && whole != true && count == nil { return }
            if type == "series" && (hasProgress || watched == true) {
                try require(video != nil, "Series progress or completion requires an exact video identity")
                try require(watched != true || video != meta, "Whole-series completion requires episode reconciliation")
            }
            if hasProgress {
                try require(played != nil && played! > 0 && position != nil, "Progress lacks a genuine viewing clock")
            }
            var row = context(profile, meta)
            for field in ["name", "poster"] {
                if let value = try optionalString(raw, field), !value.isEmpty { row[field] = value }
            }
            if let video { row["videoId"] = video }
            if hasProgress {
                row["positionMs"] = position; row["lastPlayedAtMs"] = played
            }
            if let duration { row["durationMs"] = duration }
            if watched == true || whole == true { row["watched"] = true }
            if let count { row["timesWatched"] = count }
            watches[profile, default: []].append(row)
        }

        func importMarks(_ profile: String, _ meta: String, _ raw: Object, sourceField: String) throws {
            let start = watches[profile]?.count ?? 0
            defer { rememberAppendedWatchSources(profileID: profile, sourceField: sourceField, receipt: raw, from: start) }
            let watched = Set(try strings(raw, "w"))
            let marked = try object(raw, "ma") ?? [:], reset = try object(raw, "ua") ?? [:]
            for video in watched.union(marked.keys).union(reset.keys).sorted() {
                try require(!video.isEmpty, "Empty watched video identity")
                let ma = try clock(marked, video), ua = try clock(reset, video)
                let bareWatched = (ma ?? 0) == 0 && (ua ?? 0) == 0 && watched.contains(video)
                if (ma ?? 0) == 0 && (ua ?? 0) == 0 && !bareWatched { continue }
                if video == meta {
                    try require(titles[profile]?[meta]?["type"] as? String == "movie",
                                "Whole-title watched intent requires verified movie or episode reconciliation")
                }
                var row = context(profile, meta); row["videoId"] = video
                if (try optionalString(raw, "v")) == video || (video == meta && row["type"] as? String == "movie"),
                   let duration = try milliseconds(raw, "d") { row["durationMs"] = duration }
                if let ma, ma > 0 { row["markedAtMs"] = ma }
                if let ua, ua > 0 { row["resetAtMs"] = ua }
                // The account-doc ingress filters nonpositive clocks before overlay merging. Zero
                // and null therefore mean no operation here and do not suppress a bare watched bit.
                if bareWatched { row["watched"] = true }
                if row["markedAtMs"] != nil || row["resetAtMs"] != nil || row["watched"] != nil { watches[profile, default: []].append(row) }
            }
        }

        func importOwnerIntents() throws {
            struct Intent { let sourceKey: String; let raw: Object; let title: String; let video: String; let watched: Bool; let clock: Double; let actor: String }
            let carrier = try object(vortx, "ownerWatched") ?? [:]
            var candidates: [String: [Intent]] = [:]
            for sourceKey in carrier.keys.sorted() {
                try unit("owner_watched_intent") {
                    guard let raw = carrier[sourceKey] as? Object else { throw fail("Malformed owner watched intent") }
                    let title = try string(raw, "t"), video = try string(raw, "v"), actor = try string(raw, "a")
                    guard let watched = try boolean(raw, "w"), let at = try clock(raw, "u"), at > 0 else { throw fail("Unclocked owner watched intent") }
                    candidates[title + "\u{1f}" + video, default: []].append(
                        Intent(sourceKey: sourceKey, raw: raw, title: title, video: video, watched: watched, clock: at, actor: actor))
                }
            }
            // Every intent for one title/video is decided together, so a tie conflict holds them all.
            for key in candidates.keys.sorted() {
                try unit("owner_watched_intent") {
                    var winner: Intent?
                    for next in candidates[key] ?? [] {
                        rememberWatchSource(profileID: owner.id.uuidString, unit: next.video,
                                            sourceField: "/vortx/ownerWatched/" + pointer(next.sourceKey), receipt: next.raw)
                        if let old = winner {
                            try require(old.clock != next.clock || old.actor != next.actor || old.watched == next.watched,
                                        "Conflicting owner watched intent tie")
                            if next.clock < old.clock || (next.clock == old.clock && next.actor < old.actor) { continue }
                        }
                        winner = next
                    }
                    guard let intent = winner else { return }
                    let id = owner.id.uuidString
                    try require(intent.title != intent.video || titles[id]?[intent.title]?["type"] as? String == "movie",
                                "Whole-title owner intent requires verified movie or episode reconciliation")
                    var row = context(id, intent.title); row["videoId"] = intent.video
                    row[intent.watched ? "markedAtMs" : "resetAtMs"] = intent.clock
                    watches[id, default: []].append(row)
                }
            }
        }

        func known(_ profile: String, _ meta: String, _ row: Object) throws {
            let type = try contentType(row)
            if let prior = titles[profile]?[meta] {
                try require(prior["type"] as? String == type, "Same media ID has conflicting movie/series ownership")
            }
            var metadata = titles[profile]?[meta] ?? ["type": type]
            for key in ["name", "poster"] {
                if let value = try optionalString(row, key), !value.isEmpty {
                    // Stable metadata fallback independent of carrier/map iteration; each progress
                    // fragment below keeps its own source metadata for strictly-newer selection.
                    if let prior = metadata[key] as? String { metadata[key] = min(prior, value) }
                    else { metadata[key] = value }
                }
            }
            let prior = titles[profile]?[meta]
            onHold { self.titles[profile]?[meta] = prior }
            titles[profile, default: [:]][meta] = metadata
        }

        /// Pending web edits are a separate authority channel. A roster snapshot alone cannot prove
        /// that web membership changes have been consumed; consult only this authenticated carrier.
        func validateProfileEdits(ownerLibrary: Object) throws {
            guard let edits = try object(document, "profileEdits") else { return }
            let rows = try objects(edits, "roster"), adds = try object(edits, "libraryAdds") ?? [:]
            guard !rows.isEmpty || !adds.isEmpty else { return }
            guard let at = try clock(edits, "editedAt"), at > 0 else { throw fail("Unclocked profile edits require reconciliation") }
            if !rows.isEmpty {
                try require(modified != nil && at <= modified! * 1000, "Pending profile roster edits require reconciliation")
            }
            for row in rows {
                guard let uuid = UUID(uuidString: try string(row, "id")) else { throw fail("Invalid profile edit identity") }
                let id = uuid.uuidString
                if try boolean(row, "deleted") == true {
                    try require(uuid != owner.id && deleted.contains(id), "Profile deletion edit lacks its permanent tombstone")
                } else {
                    // Missing IDs are created even by stale web edits in the shipping host.
                    try require(profiles[id] != nil || deleted.contains(id), "Profile edit identity is absent from resolved roster")
                }
            }
            let ownerItems = try objects(ownerLibrary, "items")
            let ownerIntents = try objects(ownerLibrary, "intents")
            for (rawID, raw) in adds {
                guard let uuid = UUID(uuidString: rawID), let items = raw as? [Object] else { throw fail("Malformed profile library additions") }
                let id = uuid.uuidString
                if deleted.contains(id) { continue }
                try require(profiles[id] != nil, "Library additions reference an unknown profile")
                if items.isEmpty { continue }
                // A secondary's old add operation manufactures a zero-offset overlay observation.
                // An existing progress row does not prove it was applied. Do not emulate that reset.
                try require(uuid == owner.id, "Secondary profile library additions require an explicit applied receipt")
                for item in items {
                    let meta = try string(item, "id"), type = try contentType(item), key = type + ":" + meta
                    let intent = ownerIntents.first { $0["key"] as? String == key } ?? [:]
                    let removed = try clock(intent, "removedAtMs") ?? 0, added = try clock(intent, "addedAtMs") ?? 0
                    let saved = ownerItems.contains { $0["id"] as? String == meta && $0["type"] as? String == type }
                    try require(saved && removed <= added, "Owner library addition is absent from resolved saved membership")
                }
            }
        }

        func context(_ profile: String, _ meta: String) -> Object {
            var row = titles[profile]?[meta] ?? [:]
            row["metaId"] = meta
            return row
        }
    }

    /// Folds watch rows into one row per video unit. A unit whose rows contradict each other is
    /// held as a whole (recorded under `kind`); every other unit still resolves.
    private static func resolveWatches(_ source: [[String: Any]], held: inout [Held], kind: String = "watch") throws -> [[String: Any]] {
        var units: [String: [String: Any]] = [:]
        var contradicted = Set<String>()
        // A stable source ordering makes omitted-field fallback independent of the dictionary or
        // carrier traversal order, including duration metadata with equal source clocks.
        let ordered = try source.map { row in
            (row, try clock(row, "lastPlayedAtMs") ?? 0,
             try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        }.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.2.lexicographicallyPrecedes(rhs.2) : lhs.1 < rhs.1 }
        for (incoming, _, _) in ordered {
            let meta = try string(incoming, "metaId")
            let key = try optionalString(incoming, "videoId") ?? meta
            if contradicted.contains(key) { continue }
            guard var old = units[key] else { units[key] = incoming; continue }
            do {
                try require(old["metaId"] as? String == meta, "Watch unit belongs to conflicting title identities")
                let oldType = old["type"] as? String, newType = incoming["type"] as? String
                try require(oldType == nil || newType == nil || oldType == newType, "Watch unit belongs to conflicting content types")
                let before = try clock(old, "lastPlayedAtMs") ?? 0, after = try clock(incoming, "lastPlayedAtMs") ?? 0
                if let a = old["positionMs"] as? Int64, let b = incoming["positionMs"] as? Int64, before == after {
                    try require(a == b, "Equal viewing clocks have conflicting positions")
                }
                if old["durationMs"] == nil { old["durationMs"] = incoming["durationMs"] }
                if after > before || old["positionMs"] == nil {
                    for field in ["lastPlayedAtMs", "positionMs", "durationMs"] where incoming[field] != nil { old[field] = incoming[field] }
                }
                for field in ["name", "type", "poster", "videoId"] {
                    guard let value = incoming[field] as? String, !value.isEmpty else { continue }
                    if let prior = old[field] as? String, !prior.isEmpty {
                        if after > before { old[field] = value }
                        else if after == before { old[field] = min(prior, value) }
                    } else { old[field] = value }
                }
                for field in ["markedAtMs", "resetAtMs", "removedAtMs", "timesWatched"] {
                    if let value = try clock(incoming, field) { old[field] = max(value, try clock(old, field) ?? 0) }
                }
                if incoming["watched"] as? Bool == true { old["watched"] = true }
                units[key] = old
            } catch let error as ReconciliationRequired {
                contradicted.insert(key)
                units.removeValue(forKey: key)
                held.append(Held(kind: kind, reason: error.reason))
            }
        }
        return units.keys.sorted().map { key in
            var row = units[key]!
            if row["markedAtMs"] != nil || row["resetAtMs"] != nil { row.removeValue(forKey: "watched") }
            return row
        }
    }

    private static func fail(_ reason: String) -> ReconciliationRequired { ReconciliationRequired(reason: reason) }
    private static func require(_ condition: Bool, _ reason: String) throws { if !condition { throw fail(reason) } }
    private static func object(_ root: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? [String: Any] else { throw fail("Malformed object carrier " + key) }
        return value
    }
    private static func array(_ root: [String: Any], _ key: String) throws -> [Any]? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? [Any] else { throw fail("Malformed array carrier " + key) }
        return value
    }
    private static func objects(_ root: [String: Any], _ key: String) throws -> [[String: Any]] {
        try (array(root, key) ?? []).map { value in
            guard let row = value as? [String: Any] else { throw fail("Malformed object row " + key) }
            return row
        }
    }
    private static func strings(_ root: [String: Any], _ key: String) throws -> [String] {
        try (array(root, key) ?? []).map { value in
            guard let row = value as? String, !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("Malformed identity " + key) }
            return row
        }
    }
    private static func optionalString(_ root: [String: Any], _ key: String) throws -> String? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw fail("Malformed string " + key) }
        return value
    }
    private static func string(_ root: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(root, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { throw fail("Missing or invalid " + key) }
        return value
    }
    private static func boolean(_ root: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw fail("Malformed boolean " + key) }
        return value.boolValue
    }
    private static func contentType(_ root: [String: Any]) throws -> String {
        let value = try string(root, "type")
        try require(value == "movie" || value == "series", "Unsupported catalog content type")
        return value
    }
    private static func validClock(_ value: Double, _ key: String) throws -> Double {
        try require(value.isFinite && value >= 0 && value <= 9_007_199_254_740_990, "Invalid clock " + key)
        return value
    }
    private static func clock(_ root: [String: Any], _ key: String) throws -> Double? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw fail("Malformed clock " + key) }
        return try validClock(value.doubleValue, key)
    }
    private static func mergeClock(_ source: [String: Any], into target: inout [String: Any], from: String, to: String) throws {
        if let value = try clock(source, from), value > 0 { target[to] = max(value, try clock(target, to) ?? 0) }
    }
    /// Known historical website metadata is forwarded into the typed private baseline verbatim.
    /// It never replaces source clocks or becomes a newly authored native/web transaction.
    private static func legacyAddonIntentV3(_ raw: Any) throws -> [String: Any] {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["version", "counter", "eventId", "state", "wallTime", "legacyRemovedSeen", "legacyAddedSeen"],
              try clock(value, "version") == 3,
              let text = value["counter"] as? String, let counter = UInt64(text), counter < UInt64.max, String(counter) == text,
              let id = value["eventId"] as? String, id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              let state = value["state"] as? String, state == "present" || state == "removed" else {
            throw fail("Unsupported add-on intentV3 carrier")
        }
        let latest = Date().timeIntervalSince1970 * 1000 + 48 * 60 * 60 * 1000
        for field in ["wallTime", "legacyRemovedSeen", "legacyAddedSeen"] {
            guard let stamp = try clock(value, field), stamp <= latest else { throw fail("Invalid add-on intentV3 clock") }
        }
        return value
    }
    private static func legacyAddonIntentV3IsPresent(_ row: [String: Any], added: Double, removed: Double) throws -> Bool {
        guard let raw = row["intentV3"] else { return added > 0 && added >= removed }
        let intent = try legacyAddonIntentV3(raw)
        let removedAdvanced = removed > (try clock(intent, "legacyRemovedSeen")!)
        let addedAdvanced = added > (try clock(intent, "legacyAddedSeen")!)
        if removedAdvanced && addedAdvanced { return added > removed }
        if removedAdvanced { return false }
        if addedAdvanced { return true }
        return intent["state"] as? String == "present"
    }
    private static func mergeLegacyAddonIntentV3(_ left: [String: Any], _ right: [String: Any]) throws -> [String: Any] {
        let leftCounter = UInt64(left["counter"] as! String)!, rightCounter = UInt64(right["counter"] as! String)!
        let leftID = left["eventId"] as! String, rightID = right["eventId"] as! String
        if leftCounter == rightCounter && leftID == rightID {
            try require(left["state"] as? String == right["state"] as? String && (try clock(left, "wallTime")) == clock(right, "wallTime"),
                        "Ambiguous legacy add-on intentV3 aliases")
        }
        var winner = rightCounter > leftCounter || (rightCounter == leftCounter && rightID > leftID) ? right : left
        winner["legacyAddedSeen"] = try max(clock(left, "legacyAddedSeen")!, clock(right, "legacyAddedSeen")!)
        winner["legacyRemovedSeen"] = try max(clock(left, "legacyRemovedSeen")!, clock(right, "legacyRemovedSeen")!)
        return winner
    }
    private static func milliseconds(_ root: [String: Any], _ key: String) throws -> Int64? {
        guard try clock(root, key) != nil, let number = root[key] as? NSNumber else { return nil }
        guard var value = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) else { throw fail("Malformed progress") }
        value *= 1000
        // Legacy playback offsets are seconds with finer-than-millisecond precision. Quantize
        // position/duration only; causal timestamps elsewhere remain untouched. Bound the original
        // value before rounding so an excessive value cannot round back into the accepted range.
        try require(value <= Decimal(9_007_199_254_740_990 as Int64),
                    "Excessive progress cannot be represented")
        var integer = Decimal(); NSDecimalRound(&integer, &value, 0, .plain)
        return NSDecimalNumber(decimal: integer).int64Value
    }
    private static func unsigned(_ root: [String: Any], _ key: String, maximum: Double) throws -> Int64? {
        guard let value = try clock(root, key) else { return nil }
        try require(value <= maximum && value.rounded(.towardZero) == value, "Invalid count " + key)
        return Int64(value)
    }
    // Built once: compiling the pattern and a formatter per row was over half the projection's time,
    // and the projection runs on every open and sync. The formatter is shared only under its lock.
    private static let lastWatchedPattern = try? NSRegularExpression(
        pattern: "^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d+))?(Z|[+-]\\d{2}:\\d{2})$")
    nonisolated(unsafe) private static let lastWatchedFormatter = ISO8601DateFormatter()
    private static let lastWatchedFormatterLock = NSLock()
    private static func lastWatched(_ root: [String: Any]) throws -> Double? {
        guard let raw = try optionalString(root, "lastWatched"), !raw.isEmpty else { return nil }
        // Parse whole seconds independently: ISO8601DateFormatter rounds fractional timestamps on
        // some OS versions. Add the original decimal fraction afterwards to preserve Double clocks.
        guard let regex = lastWatchedPattern,
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let secondsRange = Range(match.range(at: 1), in: raw), let zoneRange = Range(match.range(at: 3), in: raw) else { throw fail("Invalid lastWatched clock") }
        let text = String(raw[secondsRange]) + String(raw[zoneRange])
        guard let date = lastWatchedFormatterLock.withLock({ lastWatchedFormatter.date(from: text) }) else { throw fail("Invalid lastWatched clock") }
        let fraction = Range(match.range(at: 2), in: raw).flatMap { Double("0." + raw[$0]) } ?? 0
        let value = try validClock(date.timeIntervalSince1970 * 1000 + fraction * 1000, "lastWatched")
        return value > 0 ? value : nil
    }
    private static func normalizeURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { throw fail("Unsupported add-on transport URL") }
        url.scheme = scheme; url.host = host.lowercased()
        guard let normalized = url.string else { throw fail("Unsupported add-on transport URL") }
        return normalized
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert($0).inserted }
    }
    private static func terms(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    // Shared with the denial-only cold overlay reader; never grants title equivalence.
    static func removalMatches(_ key: String, meta: String, type: String) -> Bool {
        let prefix = type + "\u{1f}"
        guard key.hasPrefix(prefix) else { return false }
        let provider = String(key.dropFirst(prefix.count))
        if provider == meta.lowercased() { return true }
        if meta.range(of: "^tt[0-9]+$", options: .regularExpression) != nil { return provider == "imdb:" + meta.lowercased() }
        if meta.range(of: "^tmdb:[0-9]+$", options: .regularExpression) != nil { return provider == "tmdb:" + type + ":" + meta.dropFirst(5) }
        return false
    }
    private static func rejectCredentials(_ raw: Any) throws {
        if let object = raw as? [String: Any] {
            for (key, value) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                try require(!["token", "accesstoken", "refreshtoken", "authtoken", "authkey", "password", "authorization", "bearer", "datakey", "apikey", "apikeys", "clientsecret", "credential", "credentials", "nativeprovidercredentials"].contains(normalized),
                            "Credential-bearing material is not native state")
                try rejectCredentials(value)
            }
        } else if let array = raw as? [Any] { for value in array { try rejectCredentials(value) } }
    }
}
