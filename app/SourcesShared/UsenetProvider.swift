import SwiftUI

// MARK: - Credential model

/// A user's own USENET provider account, used to play a bare-NZB source ON DEVICE through the embedded
/// streaming server's native NNTP engine (no debrid, no TorBox). Every field is a credential and lives in
/// the Keychain ONLY (see `UsenetProviderStore`), never in UserDefaults, a preference, or a backup.
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
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        let boundedPort = min(max(port, 1), 65535)
        let boundedConns = min(max(maxConnections, 1), 100)
        return "\(scheme)://\(user):\(pass)@\(cleanHost):\(boundedPort)/\(boundedConns)"
    }

    /// Percent-encode down to alphanumerics so no delimiter survives in the user/pass segments. Over-encoding
    /// is safe: the engine's `decodeURIComponent` restores the original bytes exactly.
    private static func encodeComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

// MARK: - Keychain-only store

/// Durable store for the user's usenet-provider credentials. KEYCHAIN ONLY, on the SAME account key across
/// iOS / tvOS / Mac (settings parity, same-key mandate). Never touches UserDefaults, so `SettingsBackup`
/// (which snapshots only the app's UserDefaults domain) can never carry or export it, exactly like the
/// account token and the debrid keys.
///
/// The account name is scoped to the current VortX owner (mirroring `DebridService.keychainAccount`), so
/// signing out and a different account signing in on the same device can never inherit the previous
/// account's usenet password.
enum UsenetProviderStore {
    /// Keychain account prefix; the current owner id is appended so credentials never cross accounts.
    static let accountPrefix = "vortx.usenet.provider."

    /// The owner-scoped Keychain account for the CURRENT VortX owner. Read synchronously from the process
    /// owner authority, the same source `DebridKeys` scopes against.
    static func account() -> String {
        accountPrefix + CredentialScopeRegistry.shared.capture().scope.keychainOwnerID
    }

    /// Load and decode the current owner's credentials, or nil when none are set / a value is malformed.
    /// Pure and thread-safe (the Keychain boundary is lock-backed), so the resolver actor calls it directly.
    static func loadCredentials() -> UsenetProviderCredentials? {
        guard let json = Keychain.string(account()),
              let data = json.data(using: .utf8),
              let creds = try? JSONDecoder().decode(UsenetProviderCredentials.self, from: data),
              creds.isValid else { return nil }
        return creds
    }

    /// True when a valid provider is configured for the current owner.
    static var isConfigured: Bool { loadCredentials() != nil }

    /// Persist credentials (Keychain only). Republishes usenet playback availability so usenet rows light up
    /// immediately. Returns false on an invalid value or a Keychain write failure.
    @discardableResult
    static func save(_ credentials: UsenetProviderCredentials) -> Bool {
        guard credentials.isValid,
              let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else { return false }
        let ok = Keychain.set(json, for: account()) == .success
        refreshAvailability()
        return ok
    }

    /// Remove the current owner's credentials and republish availability.
    @discardableResult
    static func clear() -> Bool {
        let ok = Keychain.set(nil, for: account()) == .success
        refreshAvailability()
        return ok
    }

    /// Publish whether a usenet provider is configured into the shared availability gate. Called once at app
    /// launch and on every credential mutation. Cheap (one Keychain read) and never holds a lock across I/O.
    static func refreshAvailability() {
        DebridPlaybackAvailability.shared.publishUsenetProvider(isConfigured)
    }
}

// MARK: - Local NNTP resolver

/// Turns a bare-NZB source into a loopback stream URL by driving the embedded streaming server's dormant
/// native NNTP engine (Stremio's bundled `nzb-http`, mounted at `/nzb`). FULL TARGETS ONLY: the resolve is
/// compiled out where the embedded server is absent (`VORTX_NO_EMBEDDED_SERVER`, the Lite build), so Lite
/// stays TorBox-only.
///
/// Flow (server.js `/nzb` router): POST `{servers:[nntp url], nzbUrl}` to `127.0.0.1:<port>/nzb/create`; the
/// engine fetches the NZB and probes the first + last segment against the user's provider, then returns
/// `{"key":"<key>"}` on success (or a 5xx when the source cannot stream, e.g. missing segments / unrepaired
/// par2). The playable URL is `/nzb/stream?key=<key>`, which the engine 302-redirects to the served file;
/// libmpv follows the redirect and streams it exactly like any direct link.
enum UsenetLocalResolver {
    enum ResolveError: Error, Equatable {
        case unavailable          // compiled out (Lite) or invalid credentials
        case createFailed(Int)    // engine could not start the stream (e.g. segments missing) -> clear failure
        case badResponse          // engine answered without a usable key
    }

    /// Bounded network budget. An NZB fetch + first/last segment probe over a working provider settles in a
    /// few seconds, and a source that cannot stream 5xx-fails fast; this ceiling only guards a stalled
    /// provider so a play tap can never hang.
    static let requestTimeout: TimeInterval = 20

    /// Resolve `nzbUrl` to a loopback stream URL, or throw. The nntp URL (carrying the user's provider
    /// password) is POSTed ONLY to `StremioServer.usenetNodeBase` (the local Node server) - deliberately
    /// never `StremioServer.base` or the generic embedded/native endpoint - and is never logged.
    static func resolve(nzbUrl: String, credentials: UsenetProviderCredentials) async throws -> URL {
        try await resolve(nzbURLs: [nzbUrl], servers: [], credentials: credentials)
    }

    /// Submit validated add-on mirrors and NNTP hints to Node's NZB control endpoint.  A saved VortX
    /// provider is appended when present; add-on credentials are never copied into preferences or logs.
    static func resolve(nzbURLs: [String], servers: [String],
                        credentials: UsenetProviderCredentials? = nil,
                        waitForNode: Bool = false) async throws -> URL {
        #if VORTX_NO_EMBEDDED_SERVER
        throw ResolveError.unavailable
        #else
        let validNZBs = nzbURLs.filter { value in
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
                && url.user == nil && url.password == nil
        }
        var localServers = servers.filter { value in
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "nntp" || scheme == "nntps") && url.host?.isEmpty == false
        }
        // An add-on's server list is an explicit routing choice.  Keep that ordering intact and use the
        // Keychain provider only when the stream did not specify any server; do not silently mix accounts.
        if localServers.isEmpty, let credentials, credentials.isValid {
            localServers.append(credentials.nntpServerURL)
        }
        guard !validNZBs.isEmpty, !localServers.isEmpty else { throw ResolveError.unavailable }
        let base = if waitForNode { await waitForNodeBase() } else { StremioServer.usenetNodeBase }
        guard let base else { throw ResolveError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            return try await UsenetNodeClient.createStream(
                base: base, nzbURLs: validNZBs, servers: localServers, session: session, timeout: requestTimeout
            )
        } catch let error as UsenetNodeClient.ClientError {
            switch error {
            case .createFailed(let code): throw ResolveError.createFailed(code)
            case .badResponse: throw ResolveError.badResponse
            }
        }
        #endif
    }

    /// Node and native can boot concurrently on mobile.  An explicit tap waits briefly for Node to publish
    /// its actual port instead of guessing the native port; auto selection never calls this waiting path.
    private static func waitForNodeBase() async -> String? {
        for _ in 0..<10 {
            if let base = StremioServer.usenetNodeBase { return base }
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return StremioServer.usenetNodeBase
    }
}

// MARK: - Settings screen

/// Settings screen to enter the user's usenet-provider account. ONE file mounted by BOTH the tvOS and
/// iOS/iPad/Mac settings screens (settings parity). Mirrors `DebridKeysView` (ScrollView + card list).
///
/// The password uses secure entry and is never displayed back: on load the other fields are restored but the
/// password field stays empty with a "saved" hint, so the stored secret is never re-materialised into UI
/// state. Saving with an empty password keeps the previously stored one.
struct UsenetProviderView: View {
    @State private var host = ""
    @State private var portText = "563"
    @State private var username = ""
    @State private var password = ""
    @State private var maxConnText = "10"
    @State private var useSSL = true
    @State private var hasSavedPassword = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Usenet provider").screenTitleStyle()
                Text("Add your own usenet provider account to play NZB sources on this device, streamed straight from your provider. Your login stays on this device in the keychain and is never included in backups or synced. This is separate from debrid; you can use either or both.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                credentialCard
                connectionCard

                HStack(spacing: Theme.Space.md) {
                    Button("Save") { save() }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(!canSave)
                    Button("Remove") { clear() }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .disabled(!hasSavedPassword && host.isEmpty && username.isEmpty)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(Theme.Typography.label)
                        .foregroundStyle(isError ? Theme.Palette.danger : Theme.Palette.accent)
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear(perform: load)
    }

    private var credentialCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            fieldLabel("Server host")
            TextField("news.example.com", text: $host)
                .font(.system(size: 15, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif

            fieldLabel("Username")
            TextField("Your provider username", text: $username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            fieldLabel("Password")
            SecureField(hasSavedPassword ? "Saved - leave blank to keep" : "Your provider password", text: $password)
                .font(.system(size: 15, design: .monospaced))
                #if os(iOS)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            fieldLabel("Port")
            TextField("563", text: $portText)
                .font(.system(size: 15, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            fieldLabel("Max connections")
            TextField("10", text: $maxConnText)
                .font(.system(size: 15, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            Toggle("Use SSL", isOn: $useSSL)
                .tint(Theme.Palette.accent)
                .onChange(of: useSSL) { applySSLDefaultPort($0) }

            Text("Most providers use SSL on port 563, or plain NNTP on port 119. Keep connections at or below your provider's limit.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.isEmpty
            && (hasSavedPassword || !password.isEmpty)
            && (Int(portText).map { (1...65535).contains($0) } ?? false)
            && (Int(maxConnText).map { (1...100).contains($0) } ?? false)
    }

    private func load() {
        guard let creds = UsenetProviderStore.loadCredentials() else { return }
        host = creds.host
        portText = String(creds.port)
        username = creds.username
        maxConnText = String(creds.maxConnections)
        useSSL = creds.useSSL
        // Never re-materialise the stored password into UI state; just flag that one exists.
        hasSavedPassword = true
        password = ""
    }

    private func applySSLDefaultPort(_ ssl: Bool) {
        // Only auto-nudge the port when it still holds the other mode's canonical default, so a custom port
        // is never overwritten.
        if ssl, portText == "119" { portText = "563" }
        if !ssl, portText == "563" { portText = "119" }
    }

    private func save() {
        guard let port = Int(portText), let maxConns = Int(maxConnText) else {
            fail("Enter a valid port and connection count.")
            return
        }
        // An empty password field keeps the previously stored one; never blanks a saved secret.
        let existing = UsenetProviderStore.loadCredentials()
        let effectivePassword = password.isEmpty ? (existing?.password ?? "") : password
        let creds = UsenetProviderCredentials(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username,
            password: effectivePassword,
            maxConnections: maxConns,
            useSSL: useSSL)
        guard creds.isValid else {
            fail("Fill in the host, username, and password.")
            return
        }
        if UsenetProviderStore.save(creds) {
            password = ""
            hasSavedPassword = true
            isError = false
            statusMessage = "Saved. NZB sources can now play through your provider."
        } else {
            fail("Could not save to the keychain. Try again.")
        }
    }

    private func clear() {
        UsenetProviderStore.clear()
        host = ""
        portText = useSSL ? "563" : "119"
        username = ""
        password = ""
        maxConnText = "10"
        hasSavedPassword = false
        isError = false
        statusMessage = "Removed."
    }

    private func fail(_ message: String) {
        isError = true
        statusMessage = message
    }
}
