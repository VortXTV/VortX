import Foundation

/// A debrid service VortX can hold an API key for.
enum DebridService: String, CaseIterable, Identifiable, Sendable {
    case realDebrid, allDebrid, premiumize, torBox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .allDebrid:  return "AllDebrid"
        case .premiumize: return "Premiumize"
        case .torBox:     return "TorBox"
        }
    }

    var hint: String {
        switch self {
        case .realDebrid: return "real-debrid.com, My Account then API."
        case .allDebrid:  return "alldebrid.com, Account then API keys."
        case .premiumize: return "premiumize.me, Account then API."
        case .torBox:     return "torbox.app, Settings then API."
        }
    }

    /// New account scopes are versioned and cannot collide with the permanent signed-out slot.
    /// The historical `.local` slot remains the signed-out device's live storage by design.
    func keychainAccount(owner: DebridOwnerScope) -> String {
        switch owner {
        case .signedOutDevice:
            return "vortx.debrid." + rawValue + ".local"
        case .account(let uuid):
            return "vortx.debrid.v2." + rawValue + ".account." + uuid.uuidString.lowercased()
        }
    }

    /// The shipped pre-v2 account scope. It is a migration source only for its exact canonical UUID owner.
    func legacyRawAccountKeychainAccount(_ uuid: UUID) -> String {
        "vortx.debrid." + rawValue + "." + uuid.uuidString.lowercased()
    }

    /// The pre-scoping global entry. It is read only under the first-explicit-bind rule and never written.
    var legacyGlobalKeychainAccount: String { "vortx.debrid." + rawValue }
}

/// Credential ownership is typed so a signed-out device can never alias a signed-in account.
enum DebridOwnerScope: Sendable, Equatable, Hashable {
    case signedOutDevice
    case account(UUID)

    /// The server emits lowercase `crypto.randomUUID()` strings. Foundation renders UUIDs uppercase, so the
    /// comparison lowercases Foundation's round-trip while requiring the input itself to remain exact lowercase.
    static func canonicalAccount(_ raw: String) -> DebridOwnerScope? {
        guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }
        return .account(uuid)
    }

    var storageNamespace: String {
        switch self {
        case .signedOutDevice: return "device.local"
        case .account(let uuid): return "account." + uuid.uuidString.lowercased()
        }
    }
}

/// One complete immutable view of credential ownership and values.
struct DebridCredentialSnapshot: Sendable, Equatable {
    let owner: DebridOwnerScope
    let revision: UInt64
    let keys: [DebridService: String]
}

/// Main-owner state mechanics. `DebridKeys` owns and mutates this value on the main actor.
struct DebridCredentialMutableState {
    private(set) var snapshot: DebridCredentialSnapshot

    init(owner: DebridOwnerScope, keys: [DebridService: String]) {
        snapshot = DebridCredentialSnapshot(owner: owner, revision: 1, keys: Self.normalized(keys))
    }

    var owner: DebridOwnerScope { snapshot.owner }
    var revision: UInt64 { snapshot.revision }
    var keys: [DebridService: String] { snapshot.keys }

    /// Replace an owner and its complete key set as one revision. Equal state is a no-op.
    mutating func replace(owner: DebridOwnerScope, keys: [DebridService: String])
        -> DebridCredentialSnapshot? {
        commit(owner: owner, keys: Self.normalized(keys))
    }

    /// Apply one local edit. Empty or whitespace-only values clear the service.
    mutating func setKey(_ value: String, for service: DebridService) -> DebridCredentialSnapshot? {
        var next = snapshot.keys
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { next.removeValue(forKey: service) }
        else { next[service] = trimmed }
        return commit(owner: snapshot.owner, keys: next)
    }

    /// Apply every present remote service in one envelope while preserving absent services.
    mutating func applyRemoteKeys(_ remote: [DebridService: String]) -> DebridCredentialSnapshot? {
        var next = snapshot.keys
        for (service, value) in remote {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { next.removeValue(forKey: service) }
            else { next[service] = trimmed }
        }
        return commit(owner: snapshot.owner, keys: next)
    }

    private mutating func commit(owner: DebridOwnerScope, keys: [DebridService: String])
        -> DebridCredentialSnapshot? {
        guard owner != snapshot.owner || keys != snapshot.keys else { return nil }
        precondition(snapshot.revision < UInt64.max, "debrid credential revision exhausted")
        snapshot = DebridCredentialSnapshot(owner: owner, revision: snapshot.revision + 1, keys: keys)
        return snapshot
    }

    private static func normalized(_ input: [DebridService: String]) -> [DebridService: String] {
        var out: [DebridService: String] = [:]
        for (service, value) in input {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[service] = trimmed }
        }
        return out
    }
}

/// The only detached-reader view. The lock protects replacement of one immutable envelope.
final class DebridCredentialSnapshotStore: @unchecked Sendable {
    static let shared = DebridCredentialSnapshotStore(
        initial: DebridCredentialSnapshot(owner: .signedOutDevice, revision: 0, keys: [:])
    )

    private let lock = NSLock()
    private var value: DebridCredentialSnapshot

    init(initial: DebridCredentialSnapshot) { value = initial }

    func load() -> DebridCredentialSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Publication is monotonic too, so a delayed owner task cannot replace a newer complete envelope.
    @discardableResult
    func publish(_ snapshot: DebridCredentialSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.revision > value.revision else { return false }
        value = snapshot
        return true
    }

    /// Checked immediately before a resolver spends its captured credential.
    func isCurrent(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.revision == revision
    }

    /// Checked after every provider await and before the result can leave the coordinator.
    func resultIsCurrent(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.revision == revision
    }

    func isConfigured(_ service: DebridService) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.keys[service]?.isEmpty == false
    }
}

/// Coordinator-side acceptance state. The first envelope is accepted; later equal or older ones are not.
struct DebridCredentialRevisionFence {
    private(set) var appliedRevision: UInt64?

    mutating func accept(_ snapshot: DebridCredentialSnapshot) -> Bool {
        if let appliedRevision, snapshot.revision <= appliedRevision { return false }
        appliedRevision = snapshot.revision
        return true
    }
}

enum DebridCredentialMigrationResult: Equatable {
    case noSource
    case targetPresent
    case migrated
    case writeFailed
    case readbackMismatch
    case deleteFailed
}

/// Copy the first eligible source into an empty target. A source is deleted only after an acknowledged write,
/// byte-identical target readback, and successful source deletion.
enum DebridCredentialMigration {
    static func migrateFirstAvailable(
        target: String,
        sources: [String],
        read: (String) -> String?,
        write: (String, String) -> Bool,
        delete: (String) -> Bool
    ) -> DebridCredentialMigrationResult {
        if read(target)?.isEmpty == false { return .targetPresent }
        guard let source = sources.first(where: { read($0)?.isEmpty == false }),
              let value = read(source), !value.isEmpty else { return .noSource }
        guard write(value, target) else { return .writeFailed }
        guard read(target) == value else { return .readbackMismatch }
        guard delete(source) else { return .deleteFailed }
        return .migrated
    }
}
