import Foundation
import CryptoKit
import Darwin

struct VortxAccountScope: Codable, Hashable, Sendable {
    let account: String
    let ownerProfileID: String
    var authenticatedData: Data { Data((account + "\u{0}" + ownerProfileID).utf8) }
    func validate() throws {
        guard !account.isEmpty, !ownerProfileID.isEmpty,
              !account.contains("\u{0}"), !ownerProfileID.contains("\u{0}") else { throw VortxNativeError.invalidSnapshot }
    }
    func validateSnapshot(_ snapshot: String) throws -> VortxJSON {
        let value = try JSONDecoder().decode(VortxJSON.self, from: Data(snapshot.utf8))
        guard case .object(let profiles) = value["roster"]?["profiles"],
              profiles[ownerProfileID]?["owner"] == .bool(true),
              profiles[ownerProfileID]?["deleted"] != .bool(true),
              profiles.values.filter({ $0["owner"] == .bool(true) }).count == 1,
              profiles.allSatisfy({ $0.value["id"] == .string($0.key) }),
              case .string(let active) = value["activeProfileId"],
              profiles[active] != nil, profiles[active]?["deleted"] != .bool(true),
              case .object(let libraries) = value["libraries"], case .object = libraries[active],
              libraries.keys.allSatisfy({ profiles[$0] != nil }) else { throw VortxNativeError.invalidSnapshot }
        if let sync = value["nativeSync"], sync != .null {
            guard sync["scope"] == .string(account), sync["ownerProfileId"] == .string(ownerProfileID),
                  sync["schemaVersion"] == .integer(1) else { throw VortxNativeError.invalidSnapshot }
        }
        return value
    }
    func validateHydration(from original: String, to hydrated: String) throws {
        let before = try validateSnapshot(original), after = try validateSnapshot(hydrated)
        guard before["nativeSync"] == after["nativeSync"] else { throw VortxNativeError.invalidSnapshot }
        guard case .object(let libraries) = before["libraries"] else { throw VortxNativeError.invalidSnapshot }
        for (profile, library) in libraries {
            if let context = library["watchContexts"] {
                guard context == after["libraries"]?[profile]?["watchContexts"] else { throw VortxNativeError.invalidSnapshot }
            }
        }
    }
}

protocol VortxCheckpointStore: Sendable {
    /// nil means absent only. Corruption, inaccessible keys, wrong scope and I/O failures must throw.
    func read(scope: VortxAccountScope) throws -> String?
    /// Must atomically replace and read back before returning. Never log or write plaintext state.
    func commit(_ snapshot: String, scope: VortxAccountScope) throws
}

/// The host supplies a key from its existing account secure store. This class never stores that key,
/// tokens or plaintext snapshots. The encrypted file is separate from all legacy/account documents.
final class VortxEncryptedCheckpointStore: VortxCheckpointStore, @unchecked Sendable {
    private let directory: URL
    private let key: SymmetricKey
    private let lock = NSLock()
    init(directory: URL, key: SymmetricKey) throws {
        guard key.bitCount == 256 else { throw VortxNativeError.invalidSnapshot }
        self.directory = directory; self.key = key
    }
    private func url(_ scope: VortxAccountScope) -> URL {
        let digest = SHA256.hash(data: scope.authenticatedData).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("native-state-v1-\(digest).sealed")
    }
    private func open(_ data: Data, scope: VortxAccountScope) throws -> String {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: scope.authenticatedData)
        guard let snapshot = String(data: plain, encoding: .utf8) else { throw VortxNativeError.invalidSnapshot }
        _ = try scope.validateSnapshot(snapshot)
        return snapshot
    }
    func read(scope: VortxAccountScope) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        try scope.validate()
        do { return try open(Data(contentsOf: url(scope)), scope: scope) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        lock.lock(); defer { lock.unlock() }
        try scope.validate(); _ = try scope.validateSnapshot(snapshot)
        let sealed = try AES.GCM.seal(Data(snapshot.utf8), using: key, authenticating: scope.authenticatedData)
        guard let combined = sealed.combined else { throw VortxNativeError.invalidSnapshot }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".native-checkpoint-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: staged) }
        try combined.write(to: staged, options: [.withoutOverwriting, .completeFileProtection])
        let file = try FileHandle(forWritingTo: staged); defer { try? file.close() }
        try file.synchronize()
        guard try open(Data(contentsOf: staged), scope: scope) == snapshot else { throw VortxNativeError.invalidSnapshot }
        guard Darwin.rename(staged.path, url(scope).path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard try open(Data(contentsOf: url(scope)), scope: scope) == snapshot else { throw VortxNativeError.invalidSnapshot }
    }
}

/// Read-only migration carrier. The authenticated sync owner supplies documents from either legacy
/// collection. No token is accepted, no old key is erased, and no unscoped roster is auto-adopted.
struct VortxLegacyImport: Sendable {
    static let collection = "stremioxProfiles"
    static let rosterID = "stremiox:profiles"
    let scope: VortxAccountScope
    let documents: [String: String]
    init(scope: VortxAccountScope, documents: [String: String]) throws {
        try scope.validate()
        for (id, json) in documents {
            guard id == Self.rosterID || (id.hasPrefix("stremiox:watch:") && UUID(uuidString: String(id.dropFirst("stremiox:watch:".count))) != nil)
            else { throw VortxNativeError.invalidSnapshot }
            _ = try JSONDecoder().decode(VortxJSON.self, from: Data(json.utf8))
        }
        self.scope = scope; self.documents = documents
    }
}

enum VortxNativeScreenState: Sendable { case loading, ready(VortxJSON), failed }

private final class VortxSessionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func revoke() { lock.lock(); active = false; lock.unlock() }
    func withActive<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw VortxNativeError.closed }; return try operation()
    }
}

/// One live writer per scope in this process, even across separate encrypted-store instances.
/// Replacement must close the existing session first; racing opens fail without touching disk.
private final class VortxScopeWriter: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var leases: [String: VortxSessionLease] = [:]
    }
    private static let registry = Registry()
    private let scope: VortxAccountScope
    private let lock = NSLock()
    private var released = true
    init(scope: VortxAccountScope, lease: VortxSessionLease) throws {
        self.scope = scope
        let inserted = Self.registry.lock.withLock { () -> Bool in
            guard Self.registry.leases[scope.account] == nil else { return false }
            Self.registry.leases[scope.account] = lease; return true
        }
        guard inserted else { throw VortxNativeError.unavailable }
        released = false
    }
    func release() {
        lock.lock(); defer { lock.unlock() }; guard !released else { return }; released = true
        _ = Self.registry.lock.withLock { Self.registry.leases.removeValue(forKey: scope.account) }
    }
    static func revokeAll() {
        let leases = registry.lock.withLock { Array(registry.leases.values) }
        leases.forEach { $0.revoke() }
    }
    deinit { release() }
}

/// An explicitly constructed, account-owned native facade. Not selected by CoreBridge or any UI
/// preference. All state mutation is copy/apply/checkpoint/swap: a failed durable write leaves the
/// published runtime unchanged. Actor isolation fences logout/profile switches across async loads.
actor VortxNativeSession {
    enum CatalogScreen: String, Sendable { case board, discover, search }
    let scope: VortxAccountScope
    private let abi: any VortxRuntimeABI
    private let store: any VortxCheckpointStore
    private let transport: any VortxResourceTransport
    private var runtime: VortxNativeRuntime
    private var closed = false
    private var persistenceFailed = false
    private var epoch = UUID()
    private var tickets: [String: UUID] = [:]
    private var bridges: [String: VortxResourceBridge] = [:]
    private var pages: [String: [VortxResourceSnapshot]] = [:]
    private var screens: [String: VortxNativeScreenState] = [:]
    private var catalogRegistries: [String: [VortxResourceAddon]] = [:]
    private nonisolated let lease = VortxSessionLease()
    private let writer: VortxScopeWriter

    init(scope: VortxAccountScope, ownerName: String, abi: any VortxRuntimeABI,
         store: any VortxCheckpointStore, transport: any VortxResourceTransport,
         allowNewAccount: Bool = false, legacy: VortxLegacyImport? = nil,
         initialActions: [String] = []) throws {
        try scope.validate()
        guard legacy == nil || legacy?.scope == scope else { throw VortxNativeError.invalidSnapshot }
        self.scope = scope; self.abi = abi; self.store = store; self.transport = transport
        writer = try VortxScopeWriter(scope: scope, lease: lease)
        if let captured = try store.read(scope: scope) {
            _ = try scope.validateSnapshot(captured)
            runtime = try VortxNativeRuntime(abi: abi, snapshot: captured)
            // Hydration may migrate projections. Commit that full state before publishing it.
            let hydrated = try runtime.stateJSON()
            try scope.validateHydration(from: captured, to: hydrated)
            try Self.bind(runtime, scope: scope)
            let bound = try runtime.stateJSON()
            try lease.withActive { try store.commit(bound, scope: scope) }
        } else {
            guard allowNewAccount, legacy?.documents.isEmpty != false else { throw VortxNativeError.invalidSnapshot }
            runtime = try VortxNativeRuntime(abi: abi, ownerID: scope.ownerProfileID, ownerName: ownerName)
            try Self.bind(runtime, scope: scope)
            for action in initialActions { try Self.apply(runtime, action: action) }
            let bound = try runtime.stateJSON()
            _ = try scope.validateSnapshot(bound)
            try lease.withActive { try store.commit(bound, scope: scope) }
        }
    }
    private static func bind(_ runtime: VortxNativeRuntime, scope: VortxAccountScope) throws {
        let action = VortxJSON.object(["type": .string("bind_sync_scope"), "scope": .string(scope.account)])
        try apply(runtime, action: String(decoding: JSONEncoder().encode(action), as: UTF8.self))
        let bound = try scope.validateSnapshot(runtime.stateJSON())
        guard bound["nativeSync"]?["scope"] == .string(scope.account) else { throw VortxNativeError.invalidSnapshot }
    }
    private static func apply(_ runtime: VortxNativeRuntime, action: String) throws {
        let result = try runtime.dispatch(action, now: UInt64(Date().timeIntervalSince1970))
        guard try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))["ok"] == .bool(true) else { throw VortxNativeError.invalidResponse }
    }
    func close() {
        revoke(); closed = true; invalidateScreens(); runtime.close(); writer.release()
    }
    /// Synchronous logout boundary: waits for an already-running atomic commit, then forbids later
    /// commits even before the actor processes close(). No outgoing account writes occur after return.
    nonisolated func revoke() { lease.revoke() }
    /// Also reaches an authenticated mount that has opened a checkpoint but has not yet installed
    /// its facade. Owner/profile boundaries therefore revoke writes during every bootstrap await.
    nonisolated static func revokeAllForOwnerBoundary() { VortxScopeWriter.revokeAll() }
    private func invalidateScreens() {
        epoch = UUID(); bridges.values.forEach { $0.invalidate() }
        tickets.removeAll(); pages.removeAll(); screens.removeAll(); catalogRegistries.removeAll()
    }
    func invalidateResources() { invalidateScreens() }
    func stateJSON() throws -> String {
        guard !closed else { throw VortxNativeError.closed }; return try lease.withActive { try runtime.stateJSON() }
    }
    func playbackProjection() throws -> VortxJSON {
        let state = try scope.validateSnapshot(stateJSON())
        guard let profile = state["activeProfileId"] else { throw VortxNativeError.invalidSnapshot }
        let query = VortxJSON.object(["kind": .string("profile_playback"), "profileId": profile])
        let result = try lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) }
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        guard response["kind"] == .string("profile_playback"), response["profileId"] == profile,
              response["continueWatching"]?.array != nil, response["history"]?.array != nil,
              case .object = response["watchedVideoIdsByTitle"], case .object = response["watchedTitles"],
              case .object = response["resumeById"] else { throw VortxNativeError.invalidResponse }
        return response
    }
    func resumeSeconds(id: String, profileID: String) throws -> Double {
        guard try scope.validateSnapshot(stateJSON())["activeProfileId"] == .string(profileID) else { throw VortxNativeError.superseded }
        let query = VortxJSON.object(["kind": .string("resume_point"), "id": .string(id)])
        let result = try lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) }
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        guard response["kind"] == .string("resume_point") else { throw VortxNativeError.invalidResponse }
        if response["resume"] == .null { return 0 }
        guard let offset = try response["resume"]?["offsetMs"]?.decode(UInt64.self) else { throw VortxNativeError.invalidResponse }
        return Double(offset) / 1000
    }
    /// The kernel materializes membership/order; hosts do not reproduce its merge reducer.
    func resourceRegistry() throws -> [VortxResourceAddon] {
        let state = try scope.validateSnapshot(stateJSON())
        guard case .string(let active) = state["activeProfileId"], let profile = state["roster"]?["profiles"]?[active],
              let binding = profile["addons"], [.string("own"), .string("share_primary")].contains(binding) else { throw VortxNativeError.invalidSnapshot }
        let bucket = binding == .string("share_primary") ? scope.ownerProfileID : active
        let query = VortxJSON.object(["kind": .string("installed_addons"), "profileId": .string(bucket)])
        let result = try lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) }
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        guard response["kind"] == .string("installed_addons"), response["profileId"] == .string(bucket),
              let addons = response["addons"]?.array else { throw VortxNativeError.invalidResponse }
        let disabled = (try? profile["settings"]?["disabledAddons"]?.decode([String].self)) ?? []
        return try addons.compactMap { addon in
            guard case .string(let url) = addon["transportUrl"], !url.isEmpty,
                  case .object = addon["manifest"] else { throw VortxNativeError.invalidResponse }
            if disabled.contains(url) { return nil }
            let id = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
            return VortxResourceAddon(id: id, transportUrl: url, manifest: addon["manifest"])
        }
    }
    /// Native action wire only; full Stremio Ctx/player action compatibility is still an explicit gate.
    @discardableResult func dispatch(_ actions: [String], now: UInt64) throws -> [String] {
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        let old = try stateJSON()
        let candidate = try VortxNativeRuntime(abi: abi, snapshot: old)
        var installed = false
        defer { if !installed { candidate.close() } }
        try scope.validateHydration(from: old, to: candidate.stateJSON())
        var results: [String] = []
        for action in actions {
            let result = try candidate.dispatch(action, now: now)
            let value = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
            guard value["ok"] == .bool(true) else { throw VortxNativeError.invalidResponse }
            results.append(result)
        }
        let updated = try candidate.stateJSON()
        let state = try scope.validateSnapshot(updated)
        do { try lease.withActive { try store.commit(updated, scope: scope) } }
        catch VortxNativeError.closed { throw VortxNativeError.closed }
        catch {
            // A rename may have succeeded before a readback/fsync failure. Do not overwrite that
            // uncertain checkpoint with another transaction; reopen and validate it first.
            persistenceFailed = true; throw VortxNativeError.checkpointUncertain
        }
        let previous = runtime; runtime = candidate; installed = true; previous.close()
        if try scope.validateSnapshot(old)["activeProfileId"] != state["activeProfileId"] { invalidateScreens() }
        return results
    }
    func screen(_ name: String) -> VortxNativeScreenState? { screens[name] }
    private func begin(_ name: String) throws -> (VortxResourceBridge, UUID, UUID, String) {
        try Task.checkCancellation()
        guard !closed else { throw VortxNativeError.closed }
        let ticket = UUID(); tickets[name] = ticket; screens[name] = .loading
        let bridge = bridges[name] ?? VortxResourceBridge(transport: transport); bridges[name] = bridge
        guard case .string(let profile) = try scope.validateSnapshot(runtime.stateJSON())["activeProfileId"] else { throw VortxNativeError.invalidSnapshot }
        try lease.withActive {}; return (bridge, ticket, epoch, profile)
    }
    private func current(_ name: String, _ ticket: UUID, _ capturedEpoch: UUID) -> Bool {
        !closed && epoch == capturedEpoch && tickets[name] == ticket && (try? lease.withActive { true }) == true
    }
    func loadCatalog(_ screen: CatalogScreen, request: VortxResourceRequest, addons: [VortxResourceAddon], append: Bool = false) async throws -> VortxJSON {
        guard request.resource == .catalog else { throw VortxNativeError.invalidResponse }
        let name = screen.rawValue
        let (bridge, ticket, capturedEpoch, profile) = try begin(name)
        do {
            let result = try await bridge.load(ownerID: profile, request: request, addons: addons)
            guard current(name, ticket, capturedEpoch), bridge.accepts(result) else { throw VortxNativeError.superseded }
            let accepted = (append ? pages[name] ?? [] : []) + [result]
            var registry = append ? catalogRegistries[name] ?? [] : []
            for addon in addons {
                if let previous = registry.first(where: { $0.id == addon.id }) {
                    guard previous.transportUrl == addon.transportUrl else { throw VortxNativeError.invalidResponse }
                } else { registry.append(addon) }
            }
            let projection = try VortxResourceProjection.board(pages: accepted, registry: registry)
            catalogRegistries[name] = registry; pages[name] = accepted; screens[name] = .ready(projection); return projection
        } catch {
            if current(name, ticket, capturedEpoch) { screens[name] = .failed }; throw error
        }
    }
    func loadMeta(request: VortxResourceRequest, stream: VortxResourceRequest?, addons: [VortxResourceAddon]) async throws -> VortxJSON {
        guard request.resource == .meta, stream == nil || stream?.resource == .stream else { throw VortxNativeError.invalidResponse }
        let name = "meta_details"
        let (bridge, ticket, capturedEpoch, profile) = try begin(name)
        do {
            let meta = try await bridge.load(ownerID: profile, request: request, addons: addons)
            guard current(name, ticket, capturedEpoch), bridge.accepts(meta) else { throw VortxNativeError.superseded }
            var streams: VortxResourceSnapshot?
            if let stream { try Task.checkCancellation(); streams = try await bridge.load(ownerID: profile, request: stream, addons: addons) }
            guard current(name, ticket, capturedEpoch), bridge.accepts(streams ?? meta) else { throw VortxNativeError.superseded }
            let projection = try VortxResourceProjection.metaDetails(meta: meta, streams: streams, expectedStream: stream, registry: addons)
            screens[name] = .ready(projection); return projection
        } catch {
            if current(name, ticket, capturedEpoch) { screens[name] = .failed }; throw error
        }
    }
    func loadSubtitles(request: VortxResourceRequest, addons: [VortxResourceAddon]) async throws -> VortxJSON {
        guard request.resource == .subtitles else { throw VortxNativeError.invalidResponse }
        let name = "subtitles"
        let (bridge, ticket, capturedEpoch, profile) = try begin(name)
        do {
            let result = try await bridge.load(ownerID: profile, request: request, addons: addons)
            guard current(name, ticket, capturedEpoch), bridge.accepts(result) else { throw VortxNativeError.superseded }
            let projection = try VortxResourceProjection.subtitles(result, registry: addons)
            screens[name] = .ready(projection); return projection
        } catch {
            if current(name, ticket, capturedEpoch) { screens[name] = .failed }; throw error
        }
    }
}
