import SwiftUI

// MARK: - Keychain-only store (owner-scoped, multiple servers)

/// Durable store for the user's usenet-provider servers. KEYCHAIN ONLY, on the SAME account key across
/// iOS / tvOS / Mac (settings parity, same-key mandate). Never touches UserDefaults, so `SettingsBackup`
/// (which snapshots only the app's UserDefaults domain) can never carry or export it, exactly like the
/// account token and the debrid keys.
///
/// The account name is scoped to the current VortX owner (mirroring `DebridService.keychainAccount`), so
/// signing out and a different account signing in on the same device can never inherit — or re-use — the
/// previous account's usenet passwords. The owner is captured ONCE at the start of every operation and the
/// SAME account string is used for the read and the write, so an account switch during an operation can
/// never splice one owner's servers into another owner's entry.
///
/// The payload is the versioned `UsenetProviderServerList`; an older single-server JSON still decodes (see
/// `UsenetProviderServerList.decode`), and because both shapes live at the SAME key a failed write simply
/// leaves the previous value intact — the old data is never lost to a failed save.
enum UsenetProviderStore {
    /// Keychain account prefix; the current owner id is appended so credentials never cross accounts.
    static let accountPrefix = UsenetProviderConfiguration.accountPrefix

    /// The owner-scoped Keychain account for the CURRENT VortX owner, captured once per call. Read
    /// synchronously from the process owner authority, the same source `DebridKeys` scopes against.
    static func account() -> String {
        guard let scoped = account(CredentialScopeRegistry.shared.capture()) else { return accountPrefix }
        return scoped
    }

    static func account(_ capture: CredentialScopeRegistry.Capture) -> String? {
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        return UsenetProviderConfiguration.keychainAccount(ownerID: capture.scope.keychainOwnerID)
    }

    /// Load and decode the current owner's FULL saved server list (priority order, enabled and disabled),
    /// or nil when nothing is saved / a value is malformed. Pure and thread-safe (the Keychain boundary is
    /// lock-backed). A legacy single-server value migrates transparently into a one-server list here.
    static func loadServerList() -> UsenetProviderServerList? {
        loadServerList(ownerCapture: CredentialScopeRegistry.shared.capture())
    }

    static func loadServerList(ownerCapture capture: CredentialScopeRegistry.Capture) -> UsenetProviderServerList? {
        guard let ownerAccount = account(capture), case .value(let json) = Keychain.confirmedString(ownerAccount),
              let data = json.data(using: .utf8) else { return nil }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        let decoded = UsenetProviderServerList.decode(data)
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        return decoded
    }

    /// ALL enabled servers in priority order, snapshotted in one synchronous owner-scoped read. Callers
    /// must capture this BEFORE their first await and pass the array through, never re-read the account
    /// mid-flight.
    static func loadEnabledServers() -> [UsenetProviderServer] {
        loadEnabledServers(ownerCapture: CredentialScopeRegistry.shared.capture())
    }

    static func loadEnabledServers(ownerCapture capture: CredentialScopeRegistry.Capture) -> [UsenetProviderServer] {
        loadServerList(ownerCapture: capture)?.enabledServers ?? []
    }

    /// Compatibility entry point for existing callers: the FIRST enabled server as a legacy single
    /// credential, or nil when none is set / valid. The playback resolver itself snapshots
    /// `loadEnabledServers()` instead, so it routes through every saved server, not just the first.
    static func loadCredentials() -> UsenetProviderCredentials? {
        loadServerList()?.firstEnabledCredentials
    }

    /// True when at least one enabled valid provider is configured for the current owner.
    static var isConfigured: Bool { loadCredentials() != nil }

    /// Persist the whole ordered server list (Keychain only, one JSON blob, one write). Returns false on
    /// an encoding failure or a Keychain write failure; a failed write leaves the previous value — old or
    /// legacy-shaped — untouched and still loadable, so no save can lose the user's servers. Republishes
    /// usenet playback availability so usenet rows light up immediately.
    @discardableResult
    @MainActor
    static func save(_ list: UsenetProviderServerList) -> Bool {
        // Capture the owner ONCE at operation start; the same account string is used for this whole
        // mutation, so a concurrent account transition can never splice owners.
        save(list, ownerCapture: CredentialScopeRegistry.shared.capture())
    }

    @MainActor
    static func save(_ list: UsenetProviderServerList, ownerCapture capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let ownerAccount = account(capture), let data = list.encoded(),
              let json = String(data: data, encoding: .utf8) else { return false }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        // Never overwrite an unreadable or malformed existing item during an ordinary edit.
        // Explicit clear() is the deliberate recovery path for such data.
        switch Keychain.confirmedString(ownerAccount) {
        case .failure: return false
        case .value(let existing):
            guard let existingData = existing.data(using: .utf8), UsenetProviderServerList.decode(existingData) != nil else { return false }
        case .missing: break
        }
        let ok = Keychain.set(json, for: ownerAccount) == .success
        refreshAvailability()
        return ok
    }

    /// Remove the current owner's saved servers and republish availability.
    @discardableResult
    @MainActor
    static func clear() -> Bool {
        clear(ownerCapture: CredentialScopeRegistry.shared.capture())
    }

    @MainActor
    static func clear(ownerCapture capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let ownerAccount = account(capture), CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        let ok = Keychain.set(nil, for: ownerAccount) == .success
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
/// Flow (server.js `/nzb` router): POST `{servers:[nntp urls], nzbUrl}` to `127.0.0.1:<port>/nzb/create`; the
/// engine fetches the NZB and probes the first + last segment against the user's providers, then returns
/// `{"key":"<key>"}` on success (or a 5xx when the source cannot stream, e.g. missing segments / unrepaired
/// par2). The playable URL is `/nzb/stream?key=<key>`, which the engine 302-redirects to the served file;
/// libmpv follows the redirect and streams it exactly like any direct link.
///
/// The engine accepts a WHOLE ORDERED `servers` ARRAY per create and performs real per-article failover
/// across it (a backup server supplies exactly the articles the primary lacks, verified by
/// `test/server-nntp.test.js`). Local routing therefore submits the user's enabled servers in priority
/// order as ONE saved-route create instead of blindly re-downloading the NZB once per server.
enum UsenetLocalResolver {
    enum ResolveError: Error, Equatable {
        case unavailable          // compiled out (Lite) or no usable servers
        case createFailed(Int)    // engine could not start the stream (e.g. segments missing) -> clear failure
        case badResponse          // engine answered without a usable key
    }

    /// Bounded network budget. An NZB fetch + first/last segment probe over a working provider settles in a
    /// few seconds, and a source that cannot stream 5xx-fails fast; this ceiling only guards a stalled
    /// provider so a play tap can never hang.
    static let requestTimeout: TimeInterval = 20

    struct RoutedStream: Sendable {
        let url: URL
        let route: DebridUsenetRoute
    }

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
        let savedServers = credentials.map { [UsenetProviderServer(legacy: $0)] } ?? []
        guard let resolved = try await resolveRouted(nzbURLs: nzbURLs, servers: servers,
                                                     savedServers: savedServers,
                                                     waitForNode: waitForNode) else {
            throw ResolveError.unavailable
        }
        return resolved.url
    }

    /// Add-on route first, then the saved servers in the user's priority order as ONE create each.
    /// Cancellation and a caller-selected exclusion are terminal: neither can quietly spend another account.
    /// `savedServers` must be the caller's ONE-TIME snapshot (captured before any await), never re-read
    /// from the Keychain inside this function.
    static func resolveRouted(nzbURLs: [String], servers: [String],
                              savedServers: [UsenetProviderServer] = [],
                              waitForNode: Bool = false,
                              excluding: Set<DebridUsenetRoute> = []) async throws -> RoutedStream? {
        #if VORTX_NO_EMBEDDED_SERVER
        throw ResolveError.unavailable
        #else
        let validNZBs = nzbURLs.filter { value in
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
                && url.user == nil && url.password == nil
        }
        let addonServers = UsenetStreamValidation.nntpServers(servers)
        let savedServerURLs = UsenetStreamValidation.nntpServers(
            savedServers.filter { $0.enabled && $0.isValid }.map(\.nntpServerURL))
        let attempts = UsenetRoutingPolicy.localAttempts(addonServers: addonServers,
                                                         savedServers: savedServerURLs,
                                                         excluding: excluding)
        guard !validNZBs.isEmpty, !attempts.isEmpty else { throw ResolveError.unavailable }
        let base = if waitForNode { try await waitForNodeBase() } else { StremioServer.usenetNodeBase }
        guard let base else { throw ResolveError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // This is the same serial/cancellation policy exercised by the injected transport regression test.
        guard let (route, url) = try await UsenetRoutingPolicy.firstSuccessful(attempts, create: { attempt in
            try await UsenetNodeClient.createStream(
                base: base, nzbURLs: validNZBs, servers: attempt.servers, session: session, timeout: requestTimeout
            )
        }) else {
            throw ResolveError.badResponse
        }
        return RoutedStream(url: url, route: route)
        #endif
    }

    /// Node and native can boot concurrently on mobile.  An explicit tap waits briefly for Node to publish
    /// its actual port instead of guessing the native port; auto selection never calls this waiting path.
    private static func waitForNodeBase() async throws -> String? {
        for _ in 0..<15 {
            if let base = StremioServer.usenetNodeBase { return base }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        return StremioServer.usenetNodeBase
    }
}

// MARK: - Settings screen

/// Settings screen to manage the user's usenet-provider SERVERS (add, edit, enable, reorder, delete).
/// ONE file mounted by BOTH the tvOS and iOS/iPad/Mac settings screens (settings parity). Mirrors
/// `DebridKeysView` (ScrollView + card list).
///
/// The saved list is kept in UI state with every password BLANKED: the stored secret is never
/// re-materialised into UI state. A blank password on save retains exactly the password already stored for
/// THAT server id (never another server's, never another owner's — the Keychain entry is owner-scoped).
/// Delete is explicit (confirm tap) and recoverable (Undo restores the server with its saved password at
/// its original priority slot). Move Up / Move Down are plain focusable buttons, so a tv remote drives the
/// whole screen. The Node connection contract used at playback is untouched.
struct UsenetProviderView: View {
    @ObservedObject private var accountSession = VortXSyncManager.shared
    @State private var ownerCapture = CredentialScopeRegistry.shared.capture()
    /// UI copy of the saved list. Passwords are ALWAYS "" here; the stored secret is only merged back at
    /// save time, keyed by the server's stable id.
    @State private var servers: [UsenetProviderServer] = []
    /// Ids of servers that currently have a stored password (drives the "leave blank to keep" hint).
    @State private var storedPasswordIDs: Set<String> = []
    /// A server pending undoable deletion, with its original index, kept only until the next action.
    @State private var pendingUndo: (server: UsenetProviderServer, index: Int)?

    @State private var isAdding = false
    @State private var editingID: String?
    @State private var confirmingDeleteID: String?

    // Editor form state (used by both Add and Edit).
    @State private var name = ""
    @State private var host = ""
    @State private var portText = "563"
    @State private var username = ""
    @State private var password = ""
    @State private var maxConnText = "10"
    @State private var useSSL = true

    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Usenet providers").screenTitleStyle()
                Text("Add your own usenet provider servers to play NZB sources on this device, streamed straight from your providers. Enabled servers are tried in list order, and each one can supply the articles the others lack. Your logins stay on this device in the keychain and are never included in backups or synced. This is separate from debrid; you can use either or both.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                if servers.isEmpty {
                    Text("No servers saved yet. Add one below.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textTertiary)
                } else {
                    serverList
                }

                if isAdding || editingID != nil {
                    editorCard
                } else {
                    Button("Add server") { beginAdd() }
                        .buttonStyle(PrimaryActionStyle())
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(Theme.Typography.label)
                        .foregroundStyle(isError ? Theme.Palette.danger : Theme.Palette.accent)
                }
                if pendingUndo != nil {
                    Button("Undo remove") { undoDelete() }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear(perform: load)
        .onReceive(accountSession.$account) { _ in
            Task { @MainActor in
                if !CredentialScopeRegistry.shared.isCurrent(ownerCapture) { boundaryReset() }
            }
        }
        .onDisappear { password = ""; pendingUndo = nil }
    }

    // MARK: Saved server list

    private var serverList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                serverCard(server, index: index)
            }
            Text("Enabled servers are used top to bottom. The first one is your main server; the rest are fallbacks.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func serverCard(_ server: UsenetProviderServer, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name.isEmpty ? server.host : server.name)
                        .font(Theme.Typography.body)
                    // Redacted, credential-free line; the stored password is never rendered.
                    Text("\(server.host):\(server.port) \(server.useSSL ? "SSL" : "plain")\(server.enabled ? "" : " · off")")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                if editingID != server.id {
                    Toggle("Enabled", isOn: Binding(
                        get: { server.enabled },
                        set: { toggle(server, enabled: $0) }))
                        .tint(Theme.Palette.accent)
                        .labelsHidden()
                }
            }
            if editingID != server.id {
                HStack(spacing: Theme.Space.md) {
                    Button("Edit") { beginEdit(server) }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    Button("Up") { move(server, offset: -1) }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .disabled(index == 0)
                    Button("Down") { move(server, offset: 1) }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .disabled(index == servers.count - 1)
                    if confirmingDeleteID == server.id {
                        Button("Confirm remove") { delete(server, at: index) }
                            .buttonStyle(ChipButtonStyle(selected: true))
                        Button("Keep") { confirmingDeleteID = nil; pendingUndo = nil }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    } else {
                        Button("Remove") { confirmingDeleteID = server.id }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    // MARK: Add / Edit form

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                fieldLabel("Name")
                TextField("My provider", text: $name)

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
                SecureField((editingID.map { storedPasswordIDs.contains($0) } ?? false)
                            ? "Saved - leave blank to keep" : "Your provider password", text: $password)
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

            HStack(spacing: Theme.Space.md) {
                Button(editingID == nil ? "Add" : "Save") { saveEditor() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(!canSaveEditor)
                Button("Cancel") { closeEditor() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    // MARK: Load / persist

    /// Reload the saved list with passwords blanked. Only structural + non-secret fields enter UI state.
    private func load() {
        guard CredentialScopeRegistry.shared.isCurrent(ownerCapture) else {
            boundaryReset()
            return
        }
        let stored = UsenetProviderStore.loadServerList(ownerCapture: ownerCapture)?.servers ?? []
        storedPasswordIDs = Set(stored.filter { !$0.password.isEmpty }.map(\.id))
        servers = stored.map { var redacted = $0; redacted.password = ""; return redacted }
        if servers.isEmpty, !isAdding, editingID == nil { closeEditor() }
    }

    /// Merge UI state (blank passwords) with the stored secrets for the SAME ids only, then persist the
    /// whole ordered list. A blank password therefore retains exactly that server's saved password; a
    /// server with no stored secret must carry a non-empty entered password (enforced in `canSaveEditor`).
    private func persist() -> Bool {
        guard CredentialScopeRegistry.shared.isCurrent(ownerCapture) else { boundaryReset(); return false }
        let storedPasswords = Dictionary((UsenetProviderStore.loadServerList(ownerCapture: ownerCapture)?.servers ?? []).map { ($0.id, $0.password) }, uniquingKeysWith: { first, _ in first })
        let merged = servers.map { server in
            var full = server
            if full.password.isEmpty { full.password = storedPasswords[server.id] ?? "" }
            return full
        }
        let ok = UsenetProviderStore.save(UsenetProviderServerList(servers: merged), ownerCapture: ownerCapture)
        // Always resync from the Keychain: a failed write left the previous value in place, so the UI must
        // reflect reality rather than an unsaved in-memory mutation. The editor's typed fields survive.
        load()
        if !ok { fail("Could not save to the keychain. Nothing was changed; try again.") }
        return ok
    }

    // MARK: Actions

    private func beginAdd() {
        pendingUndo = nil
        closeEditor()
        isAdding = true
        name = ""; host = ""; username = ""; password = ""
        portText = "563"; maxConnText = "10"; useSSL = true
    }

    private func beginEdit(_ server: UsenetProviderServer) {
        pendingUndo = nil
        closeEditor()
        editingID = server.id
        name = server.name
        host = server.host
        portText = String(server.port)
        username = server.username
        maxConnText = String(server.maxConnections)
        useSSL = server.useSSL
        password = "" // never prefill the stored secret; blank keeps it
    }

    private func closeEditor() {
        password = ""
        isAdding = false
        editingID = nil
        confirmingDeleteID = nil
    }

    private var canSaveEditor: Bool {
        let hasStoredPassword = editingID.map { storedPasswordIDs.contains($0) } ?? false
        return UsenetProviderConfiguration.isBareHost(host)
            && !username.isEmpty
            && (!password.isEmpty || hasStoredPassword)
            && (Int(portText).map { (1...65535).contains($0) } ?? false)
            && (Int(maxConnText).map { (1...100).contains($0) } ?? false)
    }

    private func saveEditor() {
        guard let port = Int(portText), let maxConns = Int(maxConnText) else {
            fail("Enter a valid port and connection count.")
            return
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let structural = UsenetProviderConfiguration.isBareHost(trimmedHost) && !username.isEmpty
            && (1...65535).contains(port) && (1...100).contains(maxConns)
        if let id = editingID, let index = servers.firstIndex(where: { $0.id == id }) {
            // Blank password keeps exactly THIS server's stored password; id, position and enabled state
            // are preserved so the stable identity (and priority slot) survive the edit.
            guard structural, !password.isEmpty || storedPasswordIDs.contains(id) else {
                fail("Fill in the host, username, and password.")
                return
            }
            var edited = servers[index]
            edited.name = name.isEmpty ? trimmedHost : name
            edited.host = trimmedHost
            edited.port = port
            edited.username = username
            if !password.isEmpty { edited.password = password }
            edited.maxConnections = maxConns
            edited.useSSL = useSSL
            servers[index] = edited
            if persist() {
                closeEditor()
                statusOk("Saved. \(edited.name) keeps its priority slot.")
            }
        } else {
            // Add: an empty password is invalid - a NEW server has nothing to retain.
            guard structural, !password.isEmpty else {
                fail("Fill in the host, username, and password.")
                return
            }
            let added = UsenetProviderServer(name: name.isEmpty ? trimmedHost : name, host: trimmedHost,
                                             port: port, username: username, password: password,
                                             maxConnections: maxConns, useSSL: useSSL, enabled: true)
            servers.append(added)
            if persist() {
                closeEditor()
                statusOk("Added \(added.name) at priority \(servers.count).")
            }
        }
    }

    private func toggle(_ server: UsenetProviderServer, enabled: Bool) {
        pendingUndo = nil
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].enabled = enabled
        confirmingDeleteID = nil
        if persist() {
            statusOk("\(servers[index].name) \(enabled ? "enabled" : "disabled").")
        }
    }

    /// Move Up / Down are plain focusable buttons: a tv remote selects them exactly like every other
    /// control on this screen. Reordering rewrites the whole ordered list, i.e. the saved priority.
    private func move(_ server: UsenetProviderServer, offset: Int) {
        pendingUndo = nil
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let target = index + offset
        guard servers.indices.contains(target) else { return }
        servers.swapAt(index, target)
        confirmingDeleteID = nil
        if persist() { statusOk("Priority updated.") }
    }

    /// Delete is explicit (a second confirming tap) and recoverable: the removed server, its stored
    /// password and its exact priority slot are held for Undo until the next action.
    private func delete(_ server: UsenetProviderServer, at index: Int) {
        pendingUndo = nil
        // Capture the full server (with its stored secret) from the Keychain before removal, for Undo.
        guard CredentialScopeRegistry.shared.isCurrent(ownerCapture) else { boundaryReset(); return }
        let stored = UsenetProviderStore.loadServerList(ownerCapture: ownerCapture)?.servers.first { $0.id == server.id } ?? server
        servers.removeAll { $0.id == server.id }
        confirmingDeleteID = nil
        if persist() {
            pendingUndo = (server: stored, index: min(index, servers.count))
            statusOk("Removed \(stored.name). Tap Undo remove to restore it.")
        }
    }

    private func undoDelete() {
        guard let undo = pendingUndo else { return }
        let index = min(undo.index, servers.count)
        servers.insert(undo.server, at: index)
        pendingUndo = nil
        if persist() {
            statusOk("Restored \(undo.server.name) at its priority slot.")
        }
    }

    private func applySSLDefaultPort(_ ssl: Bool) {
        // Only auto-nudge the port when it still holds the other mode's canonical default, so a custom port
        // is never overwritten.
        if ssl, portText == "119" { portText = "563" }
        if !ssl, portText == "563" { portText = "119" }
    }

    private func statusOk(_ message: String) {
        isError = false
        statusMessage = message
    }

    private func fail(_ message: String) {
        isError = true
        statusMessage = message
    }

    private func boundaryReset() {
        servers = []
        storedPasswordIDs = []
        pendingUndo = nil
        password = ""
        isAdding = false
        editingID = nil
        ownerCapture = CredentialScopeRegistry.shared.capture()
        load()
    }
}
