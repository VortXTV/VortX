import Foundation

// MARK: - Credential model (pure Foundation)

/// A user's own USENET provider account, used to play a bare-NZB source ON DEVICE through the embedded
/// streaming server's native NNTP engine (no debrid, no TorBox). Every field is a credential and lives in
/// the Keychain ONLY (see `UsenetProviderStore`), never in UserDefaults, a preference, or a backup.
///
/// This is the LEGACY single-server shape: it is still the wire format `UsenetLocalResolver` accepts for
/// its single-credential overloads, and it is decoded BACKWARDS COMPATIBLY from an older Keychain value by
/// `UsenetProviderServerList.decode`. New writes are always the versioned multi-server list.
///
/// The whole value is JSON-encoded into a SINGLE Keychain entry, so host/port/connections travel with the
/// secret bytes and nothing about the account is ever written to a plain preference. The password is never
/// logged and never rendered back in plaintext (the settings field is secure entry).
struct UsenetProviderCredentials: Codable, Sendable, Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var maxConnections: Int
    var useSSL: Bool

    /// A configured provider needs a host, a login, a password, and sane numeric bounds.
    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.isEmpty
            && !password.isEmpty
            && (1...65535).contains(port)
            && (1...100).contains(maxConnections)
    }

    /// The `nntp(s)://user:pass@host:port/connections` server URL the embedded `/nzb` engine parses
    /// (server.js `parseNntpUrl`, regex `(nntps?)://(.*):(.*)@(.*):([0-9]+)/([0-9]+)`). The engine
    /// `decodeURIComponent`s the user and pass, so both are percent-encoded to alphanumerics here: that
    /// removes every `:` `@` `/` from inside them, which both keeps the greedy regex unambiguous and
    /// round-trips the exact original bytes back out of `decodeURIComponent`. The connection count is the
    /// user's setting, carried in the final path segment exactly as the engine expects.
    ///
    /// This URL is only ever POSTed to the LOCAL 127.0.0.1 server (`UsenetLocalResolver`); it never leaves
    /// the device and is never logged.
    var nntpServerURL: String {
        let scheme = useSSL ? "nntps" : "nntp"
        let user = Self.encodeComponent(username)
        let pass = Self.encodeComponent(password)
        let cleanHostRaw = host.trimmingCharacters(in: .whitespaces)
        let cleanHost = cleanHostRaw.contains(":") && !cleanHostRaw.hasPrefix("[")
            ? "[\(cleanHostRaw)]" : cleanHostRaw
        let boundedPort = min(max(port, 1), 65535)
        let boundedConns = min(max(maxConnections, 1), 100)
        return "\(scheme)://\(user):\(pass)@\(cleanHost):\(boundedPort)/\(boundedConns)"
    }

    /// Percent-encode down to alphanumerics so no delimiter survives in the user/pass segments. Over-encoding
    /// is safe: the engine's `decodeURIComponent` restores the original bytes exactly.
    static func encodeComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

// MARK: - Multiple saved servers (versioned, priority-ordered)

/// One NAMED saved NNTP server with a STABLE identity. `id` is minted once when the server is added and
/// never changes afterwards, so enable/disable, reorder, edit (including "leave the password blank to keep
/// the saved one") and undoable delete all address exactly one server even after renames or host edits.
///
/// ARRAY ORDER IS PRIORITY: the first enabled server in `UsenetProviderServerList.servers` is the primary,
/// later ones are lower-priority fallbacks handed to the Node engine in the same order.
struct UsenetProviderServer: Codable, Sendable, Equatable, Identifiable {
    static let legacyServerID = "legacy-usenet-provider"
    var id: String
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var maxConnections: Int
    var useSSL: Bool
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, host: String, port: Int, username: String,
         password: String, maxConnections: Int, useSSL: Bool, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.maxConnections = maxConnections
        self.useSSL = useSSL
        self.enabled = enabled
    }

    /// Wrap a legacy single-server credential as a named server using the reserved migration ID, so every
    /// decode of the unsaved legacy slot addresses the same server.
    init(legacy credentials: UsenetProviderCredentials) {
        self.init(id: Self.legacyServerID, name: credentials.host.trimmingCharacters(in: .whitespaces),
                  host: credentials.host, port: credentials.port, username: credentials.username,
                  password: credentials.password, maxConnections: credentials.maxConnections,
                  useSSL: credentials.useSSL, enabled: true)
    }

    var isValid: Bool {
        UsenetProviderConfiguration.isBareHost(host)
            && !username.isEmpty
            && !password.isEmpty
            && (1...65535).contains(port)
            && (1...100).contains(maxConnections)
    }

    /// Same wire shape as the legacy credential's `nntpServerURL` (identical engine contract).
    var nntpServerURL: String {
        UsenetProviderCredentials(host: host, port: port, username: username, password: password,
                                  maxConnections: maxConnections, useSSL: useSSL).nntpServerURL
    }

    /// Login-free view used by the settings list and any diagnostics surface. NEVER contains the username
    /// or the password, so rendering it can never leak credential material.
    var redactedSummary: String {
        "\(name) — \(host.trimmingCharacters(in: .whitespaces)):\(port) \(useSSL ? "SSL" : "plain") \(enabled ? "on" : "off")"
    }
}

/// The VERSIONED Keychain payload for multiple saved usenet servers. Written as ONE JSON blob into ONE
/// owner-scoped Keychain entry (see `UsenetProviderStore`), so all servers travel with their secret bytes
/// and nothing is ever stored in a preference, a backup, or a log.
///
/// DECODE IS BACKWARDS COMPATIBLE: an older single-server `UsenetProviderCredentials` JSON decodes into a
/// one-server list, so a migration is nothing more than the NEXT explicit save rewriting the same key in
/// the new shape. Because old and new payloads share one key, a FAILED write can never lose the old data —
/// the previous JSON is simply still there and still decodable.
struct UsenetProviderServerList: Codable, Sendable, Equatable {
    static let currentVersion = 2

    var version: Int
    var servers: [UsenetProviderServer]

    init(servers: [UsenetProviderServer]) {
        self.version = UsenetProviderServerList.currentVersion
        self.servers = servers
    }

    /// The enabled servers IN ARRAY ORDER (priority order). Disabled servers stay saved but are never
    /// submitted to the engine.
    var enabledServers: [UsenetProviderServer] {
        servers.filter(\.enabled)
    }

    /// The first enabled server as a legacy single credential, for compatibility callers.
    var firstEnabledCredentials: UsenetProviderCredentials? {
        guard let first = enabledServers.first, first.isValid else { return nil }
        return UsenetProviderCredentials(host: first.host, port: first.port, username: first.username,
                                         password: first.password, maxConnections: first.maxConnections,
                                         useSSL: first.useSSL)
    }

    /// Encode the current version, or nil (caller must abort and keep the old Keychain value).
    func encoded() -> Data? {
        guard version == UsenetProviderServerList.currentVersion,
              UsenetProviderConfiguration.isValidServerList(servers) else { return nil }
        let payload = self
        return try? JSONEncoder().encode(payload)
    }

    /// Decode a Keychain JSON blob: the current versioned list first, then the legacy single-server
    /// credential, else nil (empty/corrupt/unknown-future-version payloads are dropped fail-soft exactly
    /// like the previous single-credential store did).
    static func decode(_ data: Data) -> UsenetProviderServerList? {
        // A version marker is authoritative. Never reinterpret an unreadable or future
        // versioned payload as the legacy shape.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["version"] != nil {
            guard let list = try? JSONDecoder().decode(UsenetProviderServerList.self, from: data),
                  list.version == UsenetProviderServerList.currentVersion,
                  UsenetProviderConfiguration.isValidServerList(list.servers) else { return nil }
            return list
        }
        if let list = try? JSONDecoder().decode(UsenetProviderServerList.self, from: data),
           list.version == UsenetProviderServerList.currentVersion,
           UsenetProviderConfiguration.isValidServerList(list.servers) {
            return list
        }
        if let legacy = try? JSONDecoder().decode(UsenetProviderCredentials.self, from: data), legacy.isValid {
            let server = UsenetProviderServer(legacy: legacy)
            guard server.isValid else { return nil }
            return UsenetProviderServerList(servers: [server])
        }
        return nil
    }
}

// MARK: - Pure configuration helpers

/// Pure, Foundation-only helpers for the owner-scoped usenet credential store. Kept free of SwiftUI and of
/// the live `CredentialScopeRegistry` so the account-scoping contract is directly unit-testable.
enum UsenetProviderConfiguration {
    /// Keychain account prefix; the current owner id is appended so credentials never cross accounts.
    static let accountPrefix = "vortx.usenet.provider."

    /// The owner-scoped Keychain account for a given owner id. nil for an empty owner id: a boundary with
    /// no owner can never read or write anyone's servers, which is what keeps one account from inheriting
    /// (or re-using) another account's usenet passwords on the same device.
    static func keychainAccount(ownerID: String) -> String? {
        let trimmed = ownerID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return accountPrefix + trimmed
    }

    static func isBareHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253,
              host.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
              !host.contains("/"), !host.contains("@"), !host.contains("?"),
              !host.contains("#"), !host.contains("\\"), !host.contains(":"),
              !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        // Node's NNTP parser currently does not support IPv6 authorities. Accept only
        // DNS-style names and dotted-decimal IPv4 until that transport contract changes.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    static func isValidServerList(_ servers: [UsenetProviderServer]) -> Bool {
        guard servers.count <= 16 else { return false }
        var ids = Set<String>()
        return servers.allSatisfy { server in
            !server.id.isEmpty && ids.insert(server.id).inserted && server.isValid
        }
    }
}
