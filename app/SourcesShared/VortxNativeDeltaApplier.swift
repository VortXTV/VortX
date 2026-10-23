import Foundation

/// Unwired v3 candidate for the v2 wire contract. No ABI calls; this does not establish runtime
/// capability, native transaction ownership, or durable acceptance on its own. Inputs are
/// already-decoded values from the trusted, exclusively owned handle. This is not raw-JSON
/// admission: it cannot detect duplicate/canonical-colliding object keys lost by a decoder.
struct VortxNativeDeltaApplier {
    struct Binding: Equatable, Sendable {
        let scope: VortxAccountScope
        /// The owning session/authority generation, never an account ID reused after reopen.
        let ownerGeneration: UUID
        /// A fresh generation for every created, hydrated, or replaced native handle.
        let handleGeneration: UUID
        static func == (lhs: Self, rhs: Self) -> Bool {
            VortxNativeDeltaApplier.exactString(lhs.scope.account, rhs.scope.account)
                && VortxNativeDeltaApplier.exactString(lhs.scope.ownerProfileID, rhs.scope.ownerProfileID)
                && lhs.ownerGeneration == rhs.ownerGeneration && lhs.handleGeneration == rhs.handleGeneration
        }
    }

    struct Cursor: Equatable, Sendable {
        let session: String
        let revision: UInt64
        static func == (lhs: Self, rhs: Self) -> Bool {
            VortxNativeDeltaApplier.exactString(lhs.session, rhs.session) && lhs.revision == rhs.revision
        }
    }

    struct Candidate: Sendable {
        let snapshot: VortxJSON
        let snapshotJSON: String
        let cursor: Cursor
        /// Retain this decoded drain and its owner's raw response; do not drain a second time.
        let envelope: VortxJSON
        fileprivate let binding: Binding
        fileprivate let predecessor: UUID
    }

    enum Failure: Error, Equatable {
        case malformedEnvelope, negotiationRejected, initialBaseMismatch, cursorMismatch
        case bindingMismatch, staleCandidate, invalidPatchTarget, ambiguousReplacement, aliasedIdentity
    }

    private(set) var snapshot: VortxJSON
    private(set) var cursor: Cursor
    let binding: Binding
    private var publication = UUID()
    private static let maxRevision: UInt64 = 9_007_199_254_740_991
    private static let envelopeKeys: Set<String> = ["deltaVersion", "session", "baseRevision", "revision",
        "snapshot", "delta", "nativeWatchPatches", "accountSlotWatchPatches"]
    private static let deltaKeys: Set<String> = ["profiles", "libraries", "activeProfileId", "nativeSync",
        "accountLibraryArchives", "projectedAccountSlots"]

    /// Complete decoded-value equality for lossless preparation, not raw JSON admission.
    /// Uses the same exact UTF-8/key/enum/Double-bit comparator as accepted base validation.
    /// Call outside every session/publication critical section; this walks the whole value.
    static func exactlyMatchesPreparedBaseline(_ lhs: VortxJSON, _ rhs: VortxJSON) -> Bool {
        exactValue(lhs, rhs)
    }

    /// Call only after an eligible, exclusively owned handle has acknowledged normalization
    /// and v2 negotiation. expectedSnapshot is its complete post-normalization state.
    /// An old engine's generic ok response is insufficient: a matching v2 base is mandatory.
    init(binding: Binding, session: String, expectedSnapshot: VortxJSON,
         negotiationResponse: VortxJSON, initialEnvelope: VortxJSON) throws {
        try binding.scope.validate()
        try Self.validateSession(session)
        let acknowledgement = try Self.object(negotiationResponse)
        guard try Self.field(acknowledgement, "ok") == .bool(true) else { throw Failure.negotiationRejected }
        let envelope = try Self.envelope(initialEnvelope, session: session)
        guard try Self.field(envelope, "baseRevision") == .null,
              try Self.revision(Self.field(envelope, "revision")) == 0,
              try Self.field(envelope, "delta") == nil, try Self.field(envelope, "nativeWatchPatches") == nil,
              try Self.field(envelope, "accountSlotWatchPatches") == nil,
              let base = try Self.field(envelope, "snapshot") else {
            throw Failure.initialBaseMismatch
        }
        try Self.validateExactReferences(expectedSnapshot, scope: binding.scope)
        try Self.validateExactReferences(base, scope: binding.scope)
        _ = try binding.scope.validateSnapshot(Self.encode(expectedSnapshot))
        _ = try binding.scope.validateSnapshot(Self.encode(base))
        guard Self.exactValue(base, expectedSnapshot) else { throw Failure.initialBaseMismatch }
        self.binding = binding
        snapshot = base
        cursor = .init(session: session, revision: 0)
    }

    /// Pure preparation: rejection leaves both incumbent and cursor untouched. Full bases after
    /// initialization require a newly prepared applier; a legacy drain cannot silently reset it.
    func prepare(_ decodedEnvelope: VortxJSON, currentBinding: Binding) throws -> Candidate {
        guard currentBinding == binding else { throw Failure.bindingMismatch }
        let envelope = try Self.envelope(decodedEnvelope, session: cursor.session)
        let base = try Self.revision(Self.field(envelope, "baseRevision"))
        let nextRevision = try Self.revision(Self.field(envelope, "revision"))
        guard base == cursor.revision, nextRevision >= base, try Self.field(envelope, "snapshot") == nil else {
            throw Failure.cursorMismatch
        }
        let delta = try Self.object(Self.field(envelope, "delta"))
        try Self.allowedKeys(delta, Self.deltaKeys)
        let nativePatches = try Self.field(envelope, "nativeWatchPatches")
        let slotPatches = try Self.field(envelope, "accountSlotWatchPatches")
        let hasPatches = nativePatches != nil || slotPatches != nil
        guard !(try Self.field(delta, "nativeSync") != nil && hasPatches) else { throw Failure.ambiguousReplacement }

        var next = try Self.object(snapshot)
        var roster = try Self.object(Self.field(next, "roster"))
        var profiles = try Self.object(Self.field(roster, "profiles"))
        if let raw = try Self.field(delta, "profiles") {
            guard case .array(let updates) = raw else { throw Failure.malformedEnvelope }
            var seen = Set<String>()
            for rawProfile in updates {
                let profile = try Self.object(rawProfile)
                let id = try Self.identifier(Self.field(profile, "id"))
                guard seen.insert(id).inserted else { throw Failure.malformedEnvelope }
                _ = try Self.field(profiles, id) // A canonical-only key hit must never become an upsert.
                profiles[id] = rawProfile // Whole named profile replacement, never roster replacement.
            }
            roster["profiles"] = .object(profiles)
            next["roster"] = .object(roster)
        }
        if let raw = try Self.field(delta, "libraries") {
            let updates = try Self.object(raw)
            var libraries = try Self.object(Self.field(next, "libraries"))
            for (id, library) in updates {
                _ = try Self.profile(id, in: profiles)
                _ = try Self.field(libraries, id)
                _ = try Self.object(library)
                libraries[id] = library // Whole named library replacement; untouched libraries survive.
            }
            next["libraries"] = .object(libraries)
        }
        if let active = try Self.field(delta, "activeProfileId") {
            _ = try Self.profile(Self.identifier(active), in: profiles)
            next["activeProfileId"] = active
        }
        if let sync = try Self.field(delta, "nativeSync") {
            _ = try Self.object(sync)
            next["nativeSync"] = sync // Explicit full replacement, distinct from watch patches.
        }
        if let archives = try Self.field(delta, "accountLibraryArchives") {
            let previous = try Self.optionalObject(Self.field(next, "accountLibraryArchives"))
            for (id, rawSlots) in try Self.object(archives) {
                _ = try Self.field(profiles, id) // Retained metadata may outlive a current profile.
                let oldSlots = try Self.optionalObject(Self.field(previous, id))
                for (key, library) in try Self.object(rawSlots) {
                    _ = try Self.field(oldSlots, key)
                    _ = try Self.object(library)
                }
            }
            next["accountLibraryArchives"] = archives
        }
        if let projected = try Self.field(delta, "projectedAccountSlots") {
            let previous = try Self.optionalObject(Self.field(next, "projectedAccountSlots"))
            for (id, key) in try Self.object(projected) {
                _ = try Self.field(profiles, id)
                _ = try Self.field(previous, id)
                _ = try Self.retainedSlotKey(key)
            }
            next["projectedAccountSlots"] = projected
        }
        if hasPatches {
            // Resolve targets in the incumbent topology, not in newly supplied upserts.
            // Do not create a watch, profile, account-slot collection, slot, or watch path.
            let incumbent = try Self.object(snapshot)
            var sync = try Self.object(Self.field(incumbent, "nativeSync"))
            if let raw = nativePatches {
                var watches = try Self.object(Self.field(sync, "watches"))
                for (id, watch) in try Self.object(raw) {
                    try Self.requireProfile(id, in: snapshot)
                    guard let previous = try Self.field(watches, id) else { throw Failure.invalidPatchTarget }
                    try Self.validateWatch(previous)
                    try Self.validateWatch(watch)
                    watches[id] = watch
                }
                sync["watches"] = .object(watches)
            }
            if let raw = slotPatches {
                var accountSlots = try Self.object(Self.field(sync, "accountSlots"))
                for (id, rawPatches) in try Self.object(raw) {
                    try Self.requireProfile(id, in: snapshot)
                    let patches = try Self.object(rawPatches)
                    guard patches.count == 1, let existing = try Self.field(accountSlots, id) else { throw Failure.invalidPatchTarget }
                    var account = try Self.object(existing)
                    var slots = try Self.object(Self.field(account, "slots"))
                    let selectedKey = try Self.selectedSlot(account, slots: slots)
                    for (key, watch) in patches {
                        guard Self.exactString(key, selectedKey), let existingSlot = try Self.field(slots, key) else {
                            throw Failure.invalidPatchTarget
                        }
                        var slot = try Self.object(existingSlot)
                        guard let previous = try Self.field(slot, "watch") else { throw Failure.invalidPatchTarget }
                        try Self.validateWatch(previous)
                        try Self.validateWatch(watch)
                        slot["watch"] = watch
                        slots[key] = .object(slot)
                    }
                    account["slots"] = .object(slots)
                    accountSlots[id] = .object(account)
                }
                sync["accountSlots"] = .object(accountSlots)
            }
            next["nativeSync"] = .object(sync)
        }
        let value = VortxJSON.object(next)
        // Equal revision can be a valid idle drain; it cannot carry an effective mutation.
        guard nextRevision != base || Self.exactValue(value, snapshot) else { throw Failure.cursorMismatch }
        try Self.validateExactReferences(value, scope: binding.scope)
        let json = try Self.encode(value)
        _ = try binding.scope.validateSnapshot(json)
        return Candidate(snapshot: value, snapshotJSON: json,
            cursor: .init(session: cursor.session, revision: nextRevision), envelope: decodedEnvelope,
            binding: binding, predecessor: publication)
    }

    /// The owning session supplies current identity and an acceptance operation which returns
    /// only AFTER its durable readback and exact native transaction commit. Throwing leaves the
    /// local replica/cursor unchanged; it does NOT undo native state or an uncertain disk write.
    /// Any post-install error requires the session's existing uncertainty/reopen handling.
    mutating func complete(_ candidate: Candidate, currentBinding: () throws -> Binding,
                           accept: (Candidate) throws -> Void) throws {
        try check(candidate, currentBinding: currentBinding())
        try accept(candidate)
        try check(candidate, currentBinding: currentBinding())
        snapshot = candidate.snapshot
        cursor = candidate.cursor
        publication = UUID()
    }

    /// Use only after the owning session has resolved the native rollback. Invalidates all
    /// candidates from this publication, including an idle candidate, without moving the cursor.
    mutating func discard(_ candidate: Candidate, currentBinding: Binding) throws {
        try check(candidate, currentBinding: currentBinding)
        publication = UUID()
    }

    private func check(_ candidate: Candidate, currentBinding: Binding) throws {
        guard currentBinding == binding, candidate.binding == binding else { throw Failure.bindingMismatch }
        guard candidate.predecessor == publication else { throw Failure.staleCandidate }
    }

    private static func envelope(_ decoded: VortxJSON, session: String) throws -> [String: VortxJSON] {
        let value = try object(decoded)
        try allowedKeys(value, envelopeKeys)
        guard try revision(field(value, "deltaVersion")) == 2,
              try exactString(identifier(field(value, "session")), session),
              try field(value, "baseRevision") != nil, try field(value, "revision") != nil else {
            throw Failure.malformedEnvelope
        }
        return value
    }

    private static func encode(_ value: VortxJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func object(_ value: VortxJSON?) throws -> [String: VortxJSON] {
        guard case .object(let object) = value else { throw Failure.malformedEnvelope }
        return object
    }
    private static func optionalObject(_ value: VortxJSON?) throws -> [String: VortxJSON] {
        guard let value else { return [:] }
        return try object(value)
    }
    /// Swift's canonical dictionary index is only a hint. Check the surviving stored key bytes
    /// before reading/updating an identity; absence is distinct from an unrepresentable alias.
    private static func field(_ object: [String: VortxJSON], _ key: String) throws -> VortxJSON? {
        guard let index = object.index(forKey: key) else { return nil }
        guard exactString(object[index].key, key) else { throw Failure.aliasedIdentity }
        return object[index].value
    }
    private static func allowedKeys(_ object: [String: VortxJSON], _ allowed: Set<String>) throws {
        for key in object.keys {
            guard let index = allowed.firstIndex(of: key), exactString(key, allowed[index]) else {
                throw Failure.malformedEnvelope
            }
        }
    }
    private static func exactString(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
    /// Expected linear work in visited keys/values/bytes; no sorted copies or pairwise map scans.
    /// Preserve enum cases and Double bit patterns (including signed zero), never coerce numbers.
    private static func exactValue(_ lhs: VortxJSON, _ rhs: VortxJSON) -> Bool {
        switch (lhs, rhs) {
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            for (key, value) in left {
                guard let index = right.index(forKey: key), exactString(key, right[index].key),
                      exactValue(value, right[index].value) else { return false }
            }
            return true
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { exactValue($0.0, $0.1) }
        case (.string(let left), .string(let right)): return exactString(left, right)
        case (.integer(let left), .integer(let right)): return left == right
        case (.unsigned(let left), .unsigned(let right)): return left == right
        case (.number(let left), .number(let right)): return left.bitPattern == right.bitPattern
        case (.bool(let left), .bool(let right)): return left == right
        case (.null, .null): return true
        default: return false
        }
    }
    private static func identifier(_ value: VortxJSON?) throws -> String {
        guard case .string(let id) = value, !id.isEmpty else { throw Failure.malformedEnvelope }
        return id // Never trim, case-fold, normalize UUID spelling, or choose another profile.
    }
    private static func retainedSlotKey(_ value: VortxJSON) throws -> String {
        guard case .string(let key) = value else { throw Failure.malformedEnvelope }
        return key // Independent retained String metadata, not authority to create/select a slot.
    }
    private static func revision(_ value: VortxJSON?) throws -> UInt64 {
        let result: UInt64
        switch value {
        case .integer(let integer) where integer >= 0: result = UInt64(integer)
        case .unsigned(let integer): result = integer
        default: throw Failure.malformedEnvelope
        }
        guard result <= maxRevision else { throw Failure.malformedEnvelope }
        return result
    }
    private static func validateSession(_ session: String) throws {
        guard !session.isEmpty, session.utf8.count <= 128,
              !session.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw Failure.malformedEnvelope
        }
    }
    private static func requireProfile(_ id: String, in snapshot: VortxJSON) throws {
        let root = try object(snapshot), roster = try object(field(root, "roster"))
        _ = try profile(id, in: object(field(roster, "profiles")))
    }
    private static func profile(_ id: String, in profiles: [String: VortxJSON]) throws -> [String: VortxJSON] {
        guard !id.isEmpty, let value = try field(profiles, id) else { throw Failure.invalidPatchTarget }
        let record = try object(value)
        guard try exactString(identifier(field(record, "id")), id) else { throw Failure.aliasedIdentity }
        return record
    }
    private static func selectedSlot(_ account: [String: VortxJSON], slots: [String: VortxJSON]) throws -> String {
        let active = try object(field(account, "activeBinding"))
        guard let selectedAccount = try field(active, "account") else { throw Failure.invalidPatchTarget }
        _ = try object(selectedAccount)
        var selected: String?
        for (key, rawSlot) in slots {
            let slot = try object(rawSlot)
            guard let identity = try field(slot, "account") else { throw Failure.invalidPatchTarget }
            if exactValue(identity, selectedAccount) {
                guard selected == nil else { throw Failure.invalidPatchTarget }
                selected = key
            }
        }
        guard let selected else { throw Failure.invalidPatchTarget }
        return selected
    }
    /// Supplements, never changes, the shared validator. Check actual stored bytes for every
    /// host-interpreted identity/reference in the base and each reconstructed snapshot. Native
    /// semantic validity of opaque record content remains the trusted producer's obligation.
    private static func validateExactReferences(_ value: VortxJSON, scope: VortxAccountScope) throws {
        let root = try object(value), roster = try object(field(root, "roster"))
        let profiles = try object(field(roster, "profiles"))
        _ = try profile(scope.ownerProfileID, in: profiles)
        for id in profiles.keys { _ = try profile(id, in: profiles) }
        let activeID = try identifier(field(root, "activeProfileId"))
        _ = try profile(activeID, in: profiles)
        let libraries = try object(field(root, "libraries"))
        _ = try object(field(libraries, activeID))
        for id in libraries.keys { _ = try profile(id, in: profiles) }
        let sync: [String: VortxJSON]
        if let raw = try field(root, "nativeSync"), raw != .null {
            sync = try object(raw)
            guard try exactString(identifier(field(sync, "scope")), scope.account),
                  try exactString(identifier(field(sync, "ownerProfileId")), scope.ownerProfileID) else {
                throw Failure.aliasedIdentity
            }
            for name in ["profiles", "watches", "accountSlots"] {
                for (id, record) in try optionalObject(field(sync, name)) {
                    _ = try profile(id, in: profiles)
                    if name == "profiles", let embedded = try field(object(record), "profile") {
                        let document = try object(embedded)
                        guard try exactString(identifier(field(document, "id")), id) else { throw Failure.aliasedIdentity }
                    }
                }
            }
        } else { sync = [:] }
        let accounts = try optionalObject(field(sync, "accountSlots"))
        for (_, rawAccount) in accounts {
            let account = try object(rawAccount), slots = try object(field(account, "slots"))
            _ = try selectedSlot(account, slots: slots)
        }
        for (id, rawArchives) in try optionalObject(field(root, "accountLibraryArchives")) {
            _ = try field(profiles, id)
            _ = try object(rawArchives)
        }
        for (id, rawKey) in try optionalObject(field(root, "projectedAccountSlots")) {
            _ = try field(profiles, id)
            let key = try retainedSlotKey(rawKey)
            // These independent maps survive hydration without current targets. Consult an
            // existing relationship only to reject a canonical-only match; absence is not an
            // instruction to create, select, normalize, or discard historical state.
            if let rawAccount = try field(accounts, id) {
                let account = try object(rawAccount), slots = try object(field(account, "slots"))
                _ = try field(slots, key)
            }
        }
    }
    /// Structural v2 document validation only. Engine semantic validation remains authoritative.
    /// Opaque extensions travel with the complete replacement document; no field projection.
    private static func validateWatch(_ value: VortxJSON) throws {
        let watch = try object(value)
        for key in ["log", "contexts"] {
            for (_, entry) in try object(field(watch, key)) { _ = try object(entry) }
        }
        if let links = try field(watch, "identityLinks") {
            guard case .array(let groups) = links else { throw Failure.malformedEnvelope }
            for group in groups {
                guard case .array(let ids) = group else { throw Failure.malformedEnvelope }
                for id in ids { _ = try identifier(id) }
            }
        }
    }
}
