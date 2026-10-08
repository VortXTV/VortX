import Foundation

/// Credential-only carrier. This value may live only in the account Keychain or encrypted cloud
/// document, never a native snapshot, host preference, recovery archive, diagnostic or log.
struct VortxNativeProviderCredentials {
    typealias Register = VortxNativeHostPreferences.Register
    struct Document: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let scope: String
        var fields: [String: Register]
    }
    struct Local: Codable {
        var counter: UInt64
        var document: Document
        var pending: [String: Register]
        /// Secure local outbox only. Written before an OAuth tuple changes, and never exported.
        /// A crash/failure leaves this explicit intent available for a certified retry.
        var prepared: [String: Register]? = nil
    }
    private static let storeLock = NSRecursiveLock()
    static func withStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        storeLock.lock(); defer { storeLock.unlock() }; return try body()
    }
    static let keys: Set<String> = ["tmdb", "mdblist", "fanart", "realDebrid", "allDebrid", "premiumize", "torBox",
                                    "traktAccess", "traktRefresh", "traktExpiry", "simklAccess", "simklExpiry"]
    static let groups = [["traktAccess", "traktRefresh", "traktExpiry"], ["simklAccess", "simklExpiry"]]
    let actor: String
    var local: Local
    init(scope: String, actor: String, sealed: Data? = nil) throws {
        guard !scope.isEmpty, VortxNativeHostPreferences.validActor(actor) else { throw VortxNativeError.invalidSnapshot }
        self.actor = actor
        local = try sealed.map { try JSONDecoder().decode(Local.self, from: $0) }
            ?? Local(counter: 0, document: Document(schemaVersion: 1, scope: scope, fields: [:]), pending: [:])
        try Self.validate(local.document, scope: scope)
        try Self.validate(Document(schemaVersion: 1, scope: scope, fields: local.prepared ?? [:]), scope: scope)
        guard local.counter <= VortxNativeHostPreferences.maxClock,
              local.pending.allSatisfy({ local.document.fields[$0.key] == $0.value }) else { throw VortxNativeError.invalidSnapshot }
        local.counter = max(local.counter, (Array(local.document.fields.values) + Array((local.prepared ?? [:]).values)).map(\.clock).max() ?? 0)
    }
    func encoded() throws -> Data { try JSONEncoder().encode(local) }
    var document: VortxJSON { get throws { try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(local.document)) } }
    mutating func edit(_ fields: [String: VortxJSON]) throws {
        guard !fields.isEmpty, local.counter < VortxNativeHostPreferences.maxClock else { throw VortxNativeError.invalidSnapshot }
        var next = local
        next.counter += 1
        for (key, value) in fields {
            let register = Register(clock: next.counter, actor: actor, value: value)
            next.document.fields[key] = register; next.pending[key] = register
        }
        try Self.validate(next.document, scope: local.document.scope)
        local = next
    }
    var hasPreparedMutation: Bool { local.prepared?.isEmpty == false }
    mutating func prepare(_ fields: [String: VortxJSON]) throws -> [String: Register] {
        var candidate = self
        try candidate.edit(fields)
        let events = candidate.local.document.fields.filter { fields[$0.key] != nil }
        var prepared = local.prepared ?? [:]
        for (key, event) in events { prepared[key] = event }
        try Self.validate(Document(schemaVersion: 1, scope: local.document.scope, fields: prepared), scope: local.document.scope)
        local.counter = candidate.local.counter; local.prepared = prepared
        return events
    }
    mutating func finishPrepared(_ events: [String: Register]) throws {
        guard !events.isEmpty, events.allSatisfy({ local.prepared?[$0.key] == $0.value }) else { throw VortxNativeError.superseded }
        var candidate = local
        for (key, event) in events {
            candidate.document.fields[key] = event; candidate.pending[key] = event
            candidate.prepared?.removeValue(forKey: key)
        }
        try Self.validate(candidate.document, scope: local.document.scope)
        local = candidate
    }
    func authorizes(_ events: [String: Register]) -> Bool {
        !hasPreparedMutation && !events.isEmpty && events.allSatisfy { local.document.fields[$0.key] == $0.value }
    }
    mutating func merge(_ wire: VortxJSON?) throws {
        guard !hasPreparedMutation else { throw VortxNativeError.unavailable }
        guard let wire else { return }
        guard case .object(let root) = wire, Set(root.keys) == ["schemaVersion", "scope", "fields"],
              case .object(let fields) = root["fields"] else { throw VortxNativeError.invalidSnapshot }
        for value in fields.values {
            guard case .object(let item) = value, Set(item.keys) == ["clock", "actor", "value"] else { throw VortxNativeError.invalidSnapshot }
        }
        let incoming = try wire.decode(Document.self)
        try Self.validate(incoming, scope: local.document.scope)
        var next = local
        for (key, value) in incoming.fields {
            if let old = next.document.fields[key] {
                if old.clock == value.clock && old.actor == value.actor {
                    guard old.value == value.value else { throw VortxNativeError.invalidSnapshot }
                } else if value.clock > old.clock || (value.clock == old.clock && value.actor > old.actor) {
                    next.document.fields[key] = value
                    // A newer authenticated register supersedes an older pending event, not a
                    // fabricated local edit. A separately changed local event has a different stamp.
                    if next.pending[key] == old { next.pending.removeValue(forKey: key) }
                }
            } else { next.document.fields[key] = value }
        }
        try Self.validate(next.document, scope: local.document.scope)
        next.counter = max(next.counter, next.document.fields.values.map(\.clock).max() ?? 0)
        local = next
    }
    mutating func acknowledge(_ sent: [String: Register]) {
        for (key, register) in sent where local.pending[key] == register { local.pending.removeValue(forKey: key) }
    }
    func mirror(into original: [String: String]) -> [String: String] {
        var result = original
        for (key, event) in local.document.fields {
            if case .string(let value) = event.value { result[key] = value }
            else { result.removeValue(forKey: key) }
        }
        return result
    }
    private static func validate(_ document: Document, scope: String) throws {
        guard document.schemaVersion == 1, document.scope == scope else { throw VortxNativeError.invalidSnapshot }
        for (key, event) in document.fields {
            guard keys.contains(key), event.clock <= VortxNativeHostPreferences.maxClock,
                  VortxNativeHostPreferences.validActor(event.actor) else { throw VortxNativeError.invalidSnapshot }
            switch event.value {
            case .null: break
            case .string(let value):
                guard !value.isEmpty else { throw VortxNativeError.invalidSnapshot }
                if key == "traktExpiry" || key == "simklExpiry" {
                    guard let expiry = UInt64(value), expiry <= VortxNativeHostPreferences.maxClock,
                          String(expiry) == value else { throw VortxNativeError.invalidSnapshot }
                }
            default: throw VortxNativeError.invalidSnapshot
            }
        }
        for group in groups {
            let values = group.compactMap { document.fields[$0] }
            guard values.isEmpty || (values.count == group.count && values.allSatisfy {
                $0.clock == values[0].clock && $0.actor == values[0].actor && ($0.value == .null) == (values[0].value == .null)
            }) else { throw VortxNativeError.invalidSnapshot }
        }
    }
}
