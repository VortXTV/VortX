import SwiftUI
import CryptoKit

/// Local record of the personal media servers (Plex / Jellyfin / Emby) the user has connected. Mirrors the
/// `DebridKeys` / `IPTVPlaylistStore` split: the NON-secret management metadata (display name, kind, ordered
/// connection URLs, user id, machine id) lives in UserDefaults under `vortx.mediaServers.list`, while the
/// access TOKEN for each server is a credential and lives ONLY in the Keychain under
/// `vortx.mediaserver.<uuid>.token` (plus `vortx.mediaserver.plexAccount.token` for the Plex account token,
/// kept only to re-run resource discovery). Tokens therefore never enter a settings backup (which serializes
/// only the UserDefaults domain) and never leave the device except, optionally and encrypted, on the account
/// sync channel (`VortXSyncManager`, gated by the sync-logins toggle).
///
/// DORMANT BY DEFAULT: with no server recorded, `servers` is empty, `configs()` is `[]`, the coordinator holds
/// no providers, and nothing here touches the network. The store is the single source of truth the source
/// contributor and the catalog rails gate on (`servers.isEmpty` -> zero network anywhere in the app).
///
/// Per-ACCOUNT scope (not per-profile), exactly like the debrid keys: a server you connect is available to
/// every profile on the account and follows the account to your other Apple devices via the sync mirror.

// MARK: - Value types

/// The non-secret, syncable metadata for one connected media server. `id` is the stable server identity used
/// for the Keychain token account, the source group id, and the sync merge key. The token itself is NOT here.
struct MediaServerRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String              // user-facing display name ("Living Room Plex")
    let kind: MediaServerKind
    var urls: [String]            // ordered connection candidates (Plex returns several; JF/Emby have one)
    var userId: String            // Jellyfin/Emby user id (Plex: account id or empty)
    var machineId: String?        // Plex machineIdentifier / Jellyfin-Emby server id, for identity/dedup
    var addedAt: Date
    var needsReauth: Bool         // set when a provider 401/403s; surfaced as a settings badge, never blocking

    init(id: UUID = UUID(), name: String, kind: MediaServerKind, urls: [String], userId: String,
         machineId: String? = nil, addedAt: Date = Date(), needsReauth: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.urls = urls
        self.userId = userId
        self.machineId = machineId
        self.addedAt = addedAt
        self.needsReauth = needsReauth
    }
}

/// `MediaServerKind` is a plain String enum in the groundwork; make it Codable here (via the raw value) so the
/// record persists and syncs without touching the resolver file. An empty conformance is enough for a
/// raw-value enum: the synthesized `Codable` round-trips through the rawValue string.
extension MediaServerKind: Codable {}

// MARK: - Store

/// The user's connected media servers. The observable list and every read-modify-write transaction share
/// the main actor with their UI and sync-apply callers. Stateless credential/defaults readers remain
/// nonisolated so auth workers and encrypted sync serialization never need a UI-executor hop.
@MainActor
final class MediaServerStore: ObservableObject {
    static let shared = MediaServerStore()

    /// The connected servers, newest first. Persisted as a JSON array in UserDefaults (non-secret metadata).
    @Published private(set) var servers: [MediaServerRecord] = []

    // Non-secret metadata (UserDefaults). Tokens are Keychain-only (see `tokenAccount`).
    private nonisolated static let listKey       = "vortx.mediaServers.list"
    private nonisolated static let removedKey    = "vortx.mediaServers.removed"     // [uuidString: epochMillis] tombstones
    private nonisolated static let syncLoginsKey = "vortx.mediaServers.syncLogins"  // include tokens in the sync blob (default ON)
    private nonisolated static let deviceIdKey   = "vortx.mediaserver.deviceId"     // stable per-install client/device id
    private nonisolated static let plexClientKey = "vortx.mediaserver.plexClientId" // stable Plex X-Plex-Client-Identifier

    private nonisolated func tokenAccount(_ id: UUID) -> String { "vortx.mediaserver.\(id.uuidString).token" }
    nonisolated static let plexAccountTokenAccount = "vortx.mediaserver.plexAccount.token"

    private init() {
        servers = Self.loadRecords()
        // Warm the resolver coordinator from persisted servers so a synced/relaunched server is queryable.
        reloadCoordinator()
    }

    // MARK: Stable install identifiers (device id + Plex client id)

    /// A stable per-install id used as the Jellyfin/Emby `DeviceId` and the Plex `X-Plex-Client-Identifier`.
    /// Persisted so a Plex token (which is anchored to the client identifier) survives relaunches.
    nonisolated static var deviceId: String {
        if let s = UserDefaults.standard.string(forKey: deviceIdKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: deviceIdKey)
        return s
    }

    /// The Plex client identifier. Kept distinct from `deviceId` so it can be rotated independently if a Plex
    /// token is ever revoked, and because it anchors the account token across discovery re-runs.
    nonisolated static var plexClientIdentifier: String {
        if let s = UserDefaults.standard.string(forKey: plexClientKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: plexClientKey)
        return s
    }

    // MARK: Sync-logins toggle

    /// Whether server tokens ride the account sync channel (default ON). When OFF, the sync blob carries the
    /// server metadata but not its token, so a peer device shows the server as `needsReauth` and re-links.
    nonisolated var syncLogins: Bool {
        get { UserDefaults.standard.object(forKey: Self.syncLoginsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncLoginsKey); nudgeSync() }
    }

    // MARK: Token access (Keychain)

    /// The access token for a server, or nil when absent (a synced-without-token server, or one that needs
    /// re-auth). Keychain-only, never UserDefaults.
    nonisolated func token(for id: UUID) -> String? {
        Keychain.string(tokenAccount(id))
    }

    nonisolated func hasToken(for id: UUID) -> Bool { !(token(for: id) ?? "").isEmpty }

    /// The Plex account token (kept only to re-run resource discovery), or nil.
    nonisolated var plexAccountToken: String? { Keychain.string(Self.plexAccountTokenAccount) }

    // MARK: Mutations

    /// Record a freshly-connected server: stash its token in the Keychain, clear any old removal tombstone for
    /// this id, prepend the metadata, persist, rebuild the coordinator, and nudge sync. Idempotent by id.
    func add(_ record: MediaServerRecord, token: String, plexAccountToken: String? = nil) {
        Keychain.set(token, for: tokenAccount(record.id))
        if let plexAccountToken, !plexAccountToken.isEmpty {
            Keychain.set(plexAccountToken, for: Self.plexAccountTokenAccount)
        }
        clearRemovedTombstone(record.id)
        var next = servers.filter { $0.id != record.id }
        next.insert(record, at: 0)
        servers = next
        save()
    }

    /// Forget a server locally: drop its Keychain token, remove the metadata, stamp a removal tombstone (so a
    /// peer device drops it too), persist, rebuild the coordinator, nudge sync.
    func remove(id: UUID) {
        Keychain.set(nil, for: tokenAccount(id))
        servers.removeAll { $0.id == id }
        stampRemovedTombstone(id)
        save()
    }

    /// Mark a server as needing re-auth (a provider 401/403). Surfaced as a settings badge and a source-group
    /// notice; never blocks the other servers. No-op if already flagged or unknown.
    func markNeedsReauth(id: UUID) {
        guard let idx = servers.firstIndex(where: { $0.id == id }), !servers[idx].needsReauth else { return }
        servers[idx].needsReauth = true
        save()
    }

    /// Rename a server (display name), persist, nudge sync.
    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = servers.firstIndex(where: { $0.id == id }), servers[idx].name != trimmed else { return }
        servers[idx].name = trimmed
        save()
    }

    // MARK: Coordinator configs

    /// Build the resolver configs for the coordinator from the currently-connected servers that hold a token.
    /// A server with no local token (synced-without-token / needs re-auth) is skipped so it never fires a
    /// doomed request. One config per usable connection URL is NOT built here (the provider owns URL
    /// ordering); the primary URL is passed and the provider tries it.
    func configs() -> [MediaServerConfig] {
        servers.compactMap { record in
            guard let tok = token(for: record.id), !tok.isEmpty, let base = record.urls.first else { return nil }
            return MediaServerConfig(kind: record.kind, baseURL: base, apiKey: tok, userId: record.userId,
                                     id: record.id, displayName: record.name, urls: record.urls)
        }
    }

    /// Rebuild the coordinator's providers from the current servers. Hops to the main actor because the
    /// coordinator is `@MainActor` (mirrors `DebridKeys.setKey` -> `DebridCoordinator.reload`).
    private var coordinatorReloadGeneration = UUID()
    private var coordinatorReloadTask: Task<Void, Never>?
    private func reloadCoordinator() {
        let built = configs(), generation = UUID()
        coordinatorReloadGeneration = generation
        coordinatorReloadTask = Task { @MainActor [weak self] in
            guard self?.coordinatorReloadGeneration == generation else { return }
            MediaServerCoordinator.shared.reload(configs: built)
        }
    }

    // MARK: Persistence

    /// Re-read the persisted server list. The singleton seeds `servers` ONLY in `init`, so an account settings
    /// pull or a backup restore (both write `UserDefaults` directly, and `UserDefaults` KVO does not fire for a
    /// dotted key like `vortx.mediaServers.list`) leaves this object holding the pre-restore list. The metadata
    /// IS syncable (it is a plain app pref, so it rides the `doc.settings` blob), which is exactly what makes
    /// the stale copy dangerous rather than merely wrong on screen.
    ///
    /// Two concrete failures this prevents, both the same shape as `IPTVPlaylistStore`'s:
    ///  - WRITE-BACK. `save()` re-encodes the WHOLE in-memory array over `listKey`, so renaming one server,
    ///    marking one `needsReauth`, or removing one after a restore would flush the stale array back over the
    ///    restored one and drop every server the restore brought back. Re-reading first means a later `save()`
    ///    can only ever build on the restored list.
    ///  - MERGE BASE. `applySyncBlob` builds its `byId` map from this in-memory array, so a stale (on a
    ///    reinstall, EMPTY) base makes the union drop any server the settings blob restored but the `apiKeys`
    ///    blob does not carry. The two channels are authored separately and can legitimately diverge, so the
    ///    union must start from the restored list, not from whatever this object happened to load at launch.
    ///
    /// Rebuilds the coordinator (mirroring `init`) so a restored server with a Keychain token is queryable
    /// without a relaunch. Deliberately does NOT `save()` (a read must never write) and does NOT `nudgeSync()`:
    /// applying the account's own data must not echo straight back up as a fresh push. Guarded, so an unchanged
    /// list never churns `objectWillChange` or the coordinator. Callers are on the main thread (see
    /// `SettingsBackup.reloadLiveStores`), sharing this store's main-actor transaction boundary.
    /// `syncBlob()` remains a separate nonisolated persisted-data read and never accesses this list.
    func reloadFromDefaults() {
        let saved = Self.loadRecords()
        guard servers != saved else { return }
        servers = saved
        reloadCoordinator()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
        reloadCoordinator()
        nudgeSync()
    }

    /// Nudge the E2E sync without making the nonisolated persisted-settings setter a UI dependency.
    /// This task carries no mutable list or credentials into the main-actor request.
    private nonisolated func nudgeSync() {
        Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }
    }

    private nonisolated static func loadRecords() -> [MediaServerRecord] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let decoded = try? JSONDecoder().decode([MediaServerRecord].self, from: data) else { return [] }
        return decoded
    }

    // MARK: Removal tombstones (last-writer-wins across devices)

    private nonisolated static func loadRemoved() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: removedKey) as? [String: Double]) ?? [:]
    }
    private func stampRemovedTombstone(_ id: UUID) {
        var map = Self.loadRemoved()
        map[id.uuidString] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(map, forKey: Self.removedKey)
    }
    private func clearRemovedTombstone(_ id: UUID) {
        var map = Self.loadRemoved()
        guard map[id.uuidString] != nil else { return }
        map.removeValue(forKey: id.uuidString)
        UserDefaults.standard.set(map, forKey: Self.removedKey)
    }

    // MARK: Sync blob (section 9 of the plan)

    /// The JSON string mirrored on the account `apiKeys` channel under `vortx.mediaServers`, or nil when there
    /// is nothing to sync (no servers AND no tombstones). Reads from UserDefaults + Keychain directly (both
    /// thread-safe) so it is safe to call from the sync push path off the main actor without racing @Published.
    /// The token is included per server ONLY when the sync-logins toggle is ON.
    nonisolated func syncBlob() -> String? {
        let records = Self.loadRecords()
        let removed = Self.loadRemoved()
        guard !records.isEmpty || !removed.isEmpty else { return nil }
        let includeTokens = syncLogins
        var serversJSON: [[String: Any]] = []
        for r in records {
            var obj: [String: Any] = [
                "id": r.id.uuidString,
                "kind": r.kind.rawValue,
                "name": r.name,
                "urls": r.urls,
                "userId": r.userId,
                "addedAt": r.addedAt.timeIntervalSince1970 * 1000,
            ]
            if let m = r.machineId { obj["machineId"] = m }
            if includeTokens, let tok = token(for: r.id), !tok.isEmpty { obj["token"] = tok }
            serversJSON.append(obj)
        }
        let blob: [String: Any] = ["v": 1, "servers": serversJSON, "removed": removed]
        guard let data = try? JSONSerialization.data(withJSONObject: blob),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Apply a pulled sync blob: union-merge servers by id, honor removal tombstones (a `removed` stamp newer
    /// than a server's `addedAt` deletes it locally), and write a synced token to the Keychain ONLY when the
    /// local slot is empty (Keychain stays the source of truth; the doc is a best-effort mirror). A server that
    /// arrives without a token is recorded as `needsReauth`. Never deletes a locally-authored server that the
    /// remote simply lacks (asymmetric read-merge, exactly like the debrid guard). Runs its mutations on the
    /// main actor (it may be called from the sync apply path).
    @MainActor
    func applySyncBlob(_ json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let remoteServers = (root["servers"] as? [[String: Any]]) ?? []
        let remoteRemoved = (root["removed"] as? [String: Double]) ?? [:]

        // Merge remote removal tombstones into the local map (keep the newest stamp per id).
        var localRemoved = Self.loadRemoved()
        for (idStr, stamp) in remoteRemoved where stamp > (localRemoved[idStr] ?? 0) { localRemoved[idStr] = stamp }

        var byId: [UUID: MediaServerRecord] = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        var didChange = false

        for obj in remoteServers {
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr),
                  let kindRaw = obj["kind"] as? String, let kind = MediaServerKind(rawValue: kindRaw),
                  let name = obj["name"] as? String,
                  let urls = obj["urls"] as? [String] else { continue }
            let addedAt = (obj["addedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            // A removal newer than this server's add wins: drop it and do not resurrect.
            if let stamp = localRemoved[idStr], stamp > addedAt.timeIntervalSince1970 * 1000 {
                if byId[id] != nil { byId[id] = nil; Keychain.set(nil, for: tokenAccount(id)); didChange = true }
                continue
            }
            let userId = obj["userId"] as? String ?? ""
            let machineId = obj["machineId"] as? String
            // Token: adopt into the Keychain only when the local slot is empty (Keychain is authoritative).
            let hadToken = hasToken(for: id)
            if !hadToken, let tok = obj["token"] as? String, !tok.isEmpty {
                Keychain.set(tok, for: tokenAccount(id))
            }
            let needsReauth = !hasToken(for: id)
            let record = MediaServerRecord(id: id, name: name, kind: kind, urls: urls, userId: userId,
                                           machineId: machineId, addedAt: addedAt, needsReauth: needsReauth)
            if byId[id] != record { byId[id] = record; didChange = true }
        }

        // Persist the merged tombstones regardless (a pure tombstone pull still needs to stick).
        UserDefaults.standard.set(localRemoved, forKey: Self.removedKey)
        guard didChange else { return }
        // Newest-first, mirroring add().
        servers = byId.values.sorted { $0.addedAt > $1.addedAt }
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.listKey) }
        reloadCoordinator()
    }
    // MARK: - Source-bound received-provider settlement

    enum SyncSettlementRefusal: String, Sendable { case superseded, busy, malformed, credentialUnavailable, persistenceUnverified, publicationUnverified }
    struct SyncSettlementReceipt: Sendable {
        private let digest: Data
        private let operationID: UUID
        fileprivate init(source: String, operationID: UUID) {
            digest = AccountProviderSyncBlob.digest(source); self.operationID = operationID
        }
        func matches(source: String, operationID: UUID) -> Bool {
            self.operationID == operationID && digest == AccountProviderSyncBlob.digest(source)
        }
    }
    enum SyncSettlement: Sendable { case settled(SyncSettlementReceipt), refused(SyncSettlementRefusal) }
    /// Explicit effects for the actual algorithm's disposable fixture. Production always constructs
    /// the real Keychain/defaults/coordinator adapter; the alternate initializer is test-flag-only.
    struct SyncSettlementIO {
        var credential: (String) -> CredentialDurableReadResult
        var confirmedRead: (String, () -> Bool) -> KeychainFailureClosedStore.ConfirmedRead?
        var compare: (KeychainFailureClosedStore.ConfirmedRead, String?, String, () -> Bool) -> CredentialMutationResult
        var list: () throws -> Data?
        var removed: () throws -> [String: Double]
        var synchronize: () -> Bool
        var persist: (Data, [String: Double], () -> Bool) -> Bool
        var coordinator: ([MediaServerConfig]) -> Bool
    }
    #if ACCOUNT_PROVIDER_SETTLEMENT_TESTING
    private var settlementFixtureIO: SyncSettlementIO?
    init(settlementFixtureIO: SyncSettlementIO, servers: [MediaServerRecord] = []) {
        self.settlementFixtureIO = settlementFixtureIO; self.servers = servers
    }
    func fixtureQueueLegacyCoordinatorReload() { reloadCoordinator() }
    func fixtureDrainLegacyCoordinatorReload() async { await coordinatorReloadTask?.value }
    #endif
    private func receivedSettlementIO() -> SyncSettlementIO {
        #if ACCOUNT_PROVIDER_SETTLEMENT_TESTING
        if let settlementFixtureIO { return settlementFixtureIO }
        #endif
        return .init(credential: { Keychain.confirmedString($0) },
            confirmedRead: { Keychain.confirmedRead($0, isCurrentOwner: $1) },
            compare: { Keychain.compareAndSetConfirmed($0, with: $1, for: $2, isCurrentOwner: $3) },
            list: { try AccountProviderSyncBlob.defaultsData(UserDefaults.standard.object(forKey: Self.listKey)) },
            removed: { try AccountProviderSyncBlob.defaultsRemoved(UserDefaults.standard.object(forKey: Self.removedKey)) },
            synchronize: { UserDefaults.standard.synchronize() },
            persist: { bytes, removed, owns in
                guard owns() else { return false }
                UserDefaults.standard.set(removed, forKey: Self.removedKey)
                guard owns() else { return false }
                UserDefaults.standard.set(bytes, forKey: Self.listKey)
                return owns() && UserDefaults.standard.synchronize()
            }, coordinator: { configs in
                MediaServerCoordinator.shared.reload(configs: configs)
                return MediaServerCoordinator.shared.matchesInstalledConfiguration(configs)
            })
    }
    /// Synchronous MainActor apply, genuinely finished before return. The caller retains the original
    /// receive UUID and checks account/key/epoch/cancellation in isCurrent before every effect. The
    /// publication boundary prevents owner rebinding inside secure/defaults callbacks; it never waits.
    func applySyncBlobSettled(_ json: String, operationID: UUID,
                              isCurrent: @escaping () -> Bool) -> SyncSettlement {
        let owns: () -> Bool = { !Task.isCancelled && isCurrent() }
        guard owns() else { return .refused(.superseded) }
        guard CredentialPublicationOutbox.acquireBoundary() == .acquired else { return .refused(.busy) }
        defer { CredentialPublicationOutbox.endBoundary() }
        let io = receivedSettlementIO()
        var failureStage = SyncSettlementRefusal.malformed
        do {
            let root = try AccountProviderSyncBlob.root(json)
            let remote = try AccountProviderSyncBlob.rows(root, "servers")
            let remoteRemoved = try AccountProviderSyncBlob.removed(root)
            failureStage = .persistenceUnverified
            guard owns(), io.synchronize(), owns() else { return .refused(.persistenceUnverified) }
            let originalData = try io.list(), originalRemoved = try io.removed()
            let original = try originalData.map { try JSONDecoder().decode([MediaServerRecord].self, from: $0) } ?? []
            guard original == servers, Set(original.map(\.id)).count == original.count,
                  original.allSatisfy({ AccountProviderSyncBlob.validDate($0.addedAt) }) else { return .refused(.persistenceUnverified) }
            var removed = originalRemoved
            for (id, stamp) in remoteRemoved where stamp > (removed[id] ?? 0) { removed[id] = stamp }
            let effectiveRemoved = removed.reduce(into: [UUID: Double]()) { result, entry in
                if let id = UUID(uuidString: entry.key), entry.value > (result[id] ?? -Double.infinity) { result[id] = entry.value }
            }
            var records = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
            // Each slot keeps its original actual read capability throughout planning. Coalesce a
            // delete followed by a newer remote re-add to one final CAS against that same read;
            // never fabricate a missing-state capability after a merely planned deletion.
            var actions: [String: (KeychainFailureClosedStore.ConfirmedRead, String?)] = [:]
            var actionOrder: [String] = []
            var observations: [String: KeychainFailureClosedStore.ConfirmedRead] = [:]
            var credentials: [String: CredentialDurableReadResult] = [:]
            // A tombstone-only source must retire older local records too. A newer local
            // re-add wins; no absent remote row is interpreted as deletion.
            for record in original {
                if let stamp = effectiveRemoved[record.id], stamp > record.addedAt.timeIntervalSince1970 * 1000 {
                    let slot = tokenAccount(record.id)
                    guard let observation = io.confirmedRead(slot, owns) else { return .refused(.credentialUnavailable) }
                    observations[slot] = observation
                    let prior = observation.result
                    if prior != .missing { actions[slot] = (observation, nil); actionOrder.append(slot) }
                    credentials[slot] = .missing; records.removeValue(forKey: record.id)
                }
            }
            var seen: Set<UUID> = []
            failureStage = .malformed
            for row in remote {
                let idText = try AccountProviderSyncBlob.string(row, "id")
                guard let id = UUID(uuidString: idText), seen.insert(id).inserted,
                      let kind = MediaServerKind(rawValue: try AccountProviderSyncBlob.string(row, "kind")),
                      let urlsRaw = row["urls"] else { return .refused(.malformed) }
                let urls = try JSONDecoder().decode([String].self, from: urlsRaw)
                let name = try AccountProviderSyncBlob.string(row, "name")
                let date = try AccountProviderSyncBlob.date(row, "addedAt")
                let user = try AccountProviderSyncBlob.string(row, "userId", default: "")
                let machine = try AccountProviderSyncBlob.optionalString(row, "machineId")
                let incomingToken = try AccountProviderSyncBlob.optionalString(row, "token")
                let slot = tokenAccount(id)
                guard owns() else { return .refused(.superseded) }
                if let stamp = effectiveRemoved[id], stamp > date.timeIntervalSince1970 * 1000 { continue }
                if let local = records[id], local.addedAt > date { continue }
                if observations[slot] == nil {
                    guard let observation = io.confirmedRead(slot, owns) else { return .refused(.credentialUnavailable) }
                    observations[slot] = observation
                }
                guard let observation = observations[slot] else { return .refused(.credentialUnavailable) }
                let prior = credentials[slot] ?? observation.result
                var accepted = try AccountProviderSyncBlob.value(prior)
                if (accepted ?? "").isEmpty, let incomingToken, !incomingToken.isEmpty {
                    if actions[slot] == nil { actionOrder.append(slot) }
                    actions[slot] = (observation, incomingToken); accepted = incomingToken
                    credentials[slot] = .value(incomingToken)
                } else { credentials[slot] = prior }
                records[id] = MediaServerRecord(id: id, name: name, kind: kind, urls: urls, userId: user,
                    machineId: machine, addedAt: date, needsReauth: (accepted ?? "").isEmpty)
            }
            // Parsing/planning finished before the first credential mutation. A lost local compare
            // refuses instead of overwriting; completed earlier effects are not rolled back blindly.
            for slot in actionOrder {
                guard let (expected, value) = actions[slot] else { return .refused(.credentialUnavailable) }
                guard owns() else { return .refused(.superseded) }
                guard io.compare(expected, value, slot, owns) == .success,
                      AccountProviderSyncBlob.sameCredential((io.confirmedRead(slot, owns)?.result ?? .failure), value.map(CredentialDurableReadResult.value) ?? .missing)
                else { return .refused(.credentialUnavailable) }
            }
            let next = records.values.sorted { $0.addedAt == $1.addedAt ? $0.id.uuidString < $1.id.uuidString : $0.addedAt > $1.addedAt }
            var configs: [MediaServerConfig] = []
            for record in next {
                let slot = tokenAccount(record.id), actual = (io.confirmedRead(tokenAccount(record.id), owns)?.result ?? .failure)
                guard actual != .failure else { return .refused(.credentialUnavailable) }
                if let expected = credentials[slot], !AccountProviderSyncBlob.sameCredential(actual, expected) { return .refused(.credentialUnavailable) }
                credentials[slot] = actual
                if let token = try AccountProviderSyncBlob.value(actual), !token.isEmpty, let base = record.urls.first {
                    configs.append(.init(kind: record.kind, baseURL: base, apiKey: token, userId: record.userId,
                        id: record.id, displayName: record.name, urls: record.urls))
                }
            }
            guard owns(), try io.list() == originalData, try io.removed() == originalRemoved else { return .refused(.persistenceUnverified) }
            failureStage = .persistenceUnverified
            let bytes = try JSONEncoder().encode(next)
            guard io.persist(bytes, removed, owns), owns(), try io.list() == bytes, try io.removed() == removed else { return .refused(.persistenceUnverified) }
            coordinatorReloadGeneration = UUID() // Retire older queued coordinator projections.
            servers = next
            guard owns(), servers == next, io.coordinator(configs), owns() else { return .refused(.publicationUnverified) }
            for (slot, expected) in credentials {
                guard AccountProviderSyncBlob.sameCredential((io.confirmedRead(slot, owns)?.result ?? .failure), expected) else { return .refused(.credentialUnavailable) }
            }
            guard owns(), try io.list() == bytes, try io.removed() == removed, servers == next else { return .refused(.persistenceUnverified) }
            return .settled(.init(source: json, operationID: operationID))
        } catch { return .refused(owns() ? failureStage : .superseded) }
    }

}
