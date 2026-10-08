import Foundation
import CryptoKit
import Darwin
import Security

/// This key authenticates only the local checkpoint inventory. Account ciphertext remains readable
/// with its independent account key after device-key loss; no installation identity is exported.
enum VortxNativeInstallationKey {
    private static let lock = NSLock()
    static func loadOrCreate() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tv.vortx.native-installation", kSecAttrAccount as String: "checkpoint-inventory-v2",
            kSecAttrSynchronizable as String: false]
        func read() throws -> Data? {
            var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 else { throw VortxNativeError.unavailable }
            return bytes
        }
        if let existing = try read() { return SymmetricKey(data: existing) }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw VortxNativeError.unavailable }
        var item = query; item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem, let confirmed = try read(),
              status == errSecDuplicateItem || confirmed == bytes else { throw VortxNativeError.unavailable }
        return SymmetricKey(data: confirmed)
    }
}

/// Native-only exports cannot acknowledge legacy host edits they deliberately do not serialize.
enum VortxNativeSyncExportPolicy {
    static func permitsStateOnlyExport(hasDirtySettings: Bool, hasLegacyAddonOrderIntent: Bool,
                                       overridingLegacySource: Bool = false) -> Bool {
        !hasDirtySettings && !hasLegacyAddonOrderIntent && !overridingLegacySource
    }
}

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
    func readHostPreferences(scope: VortxAccountScope) throws -> Data?
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data?
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws
}
extension VortxCheckpointStore {
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { nil }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { nil }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws { throw VortxNativeError.unavailable }
}

/// The host supplies a key from its existing account secure store. This class never persists that
/// key or plaintext snapshots; the bootstrap archive excludes known credential carriers. The sealed
/// file is separate from the original legacy/account documents and never replaces them.
final class VortxEncryptedCheckpointStore: VortxCheckpointStore, @unchecked Sendable {
    private struct Envelope: Codable {
        let format: String
        let state: String
        let bootstrap: Data?
        var hostPreferences: Data? = nil
    }
    private let directory: URL
    private let key: SymmetricKey
    private let installationKey: SymmetricKey?
    private let lock = NSLock()
    private var bootstraps: [VortxAccountScope: Data] = [:]
    private struct AccountLocator: Codable {
        let format: String
        let scope: VortxAccountScope
    }
    private struct InventoryProof: Codable { let scope: VortxAccountScope; let ciphertextDigest: Data }
    private struct IndexedCiphertext: Codable { let format: String; let ciphertext: Data; let proof: Data }
    private static let indexedPrefix = Data("vortx-native-indexed-ciphertext-v2\n".utf8)
    struct Recovery {
        let scope: VortxAccountScope
        let state: String
        let bootstrap: Data
    }
    init(directory: URL, key: SymmetricKey, installationKey: SymmetricKey? = nil, bootstrap: Data? = nil, bootstrapScope: VortxAccountScope? = nil) throws {
        guard key.bitCount == 256, installationKey == nil || installationKey?.bitCount == 256 else { throw VortxNativeError.invalidSnapshot }
        if let bootstrap {
            guard let bootstrapScope else { throw VortxNativeError.invalidSnapshot }
            try bootstrapScope.validate(); try VortxNativeBootstrapArchive.validate(bootstrap)
            bootstraps[bootstrapScope] = bootstrap
        }
        self.directory = directory; self.key = key; self.installationKey = installationKey
    }
    private func url(_ scope: VortxAccountScope) -> URL {
        let digest = SHA256.hash(data: scope.authenticatedData).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("native-state-v1-\(digest).sealed")
    }
    private func locatorAAD(_ account: String) -> Data { Data(("vortx-native-account-locator-v1\u{0}" + account).utf8) }
    private func locatorURL(_ account: String) -> URL {
        let digest = SHA256.hash(data: locatorAAD(account)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("native-account-v1-\(digest).sealed")
    }
    private func indexURL(_ account: String) -> URL {
        directory.appendingPathComponent(locatorURL(account).lastPathComponent.replacingOccurrences(of: "native-account-v1-", with: "native-account-v2-"))
    }
    private func indexAAD(_ filename: String) -> Data { Data(("vortx-native-inventory-v2\u{0}" + filename).utf8) }
    private func indexedCiphertext(_ ciphertext: Data, scope: VortxAccountScope) throws -> Data {
        guard let installationKey else { return ciphertext }
        let proof = InventoryProof(scope: scope, ciphertextDigest: Data(SHA256.hash(data: ciphertext)))
        guard let sealed = try AES.GCM.seal(JSONEncoder().encode(proof), using: installationKey,
            authenticating: indexAAD(url(scope).lastPathComponent)).combined else { throw VortxNativeError.invalidSnapshot }
        return Self.indexedPrefix + (try JSONEncoder().encode(IndexedCiphertext(format: "vortx-native-indexed-ciphertext-v2", ciphertext: ciphertext, proof: sealed)))
    }
    private func accountCiphertext(_ data: Data) throws -> Data {
        // The original account-key ciphertext is never discarded or made dependent on the install key.
        guard data.starts(with: Self.indexedPrefix) else { return data }
        let indexed = try JSONDecoder().decode(IndexedCiphertext.self, from: data.dropFirst(Self.indexedPrefix.count))
        guard indexed.format == "vortx-native-indexed-ciphertext-v2" else { throw VortxNativeError.invalidSnapshot }
        return indexed.ciphertext
    }
    private func authenticatedInventory(for requestedScope: VortxAccountScope) throws -> Set<String> {
        guard let installationKey else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var covered: Set<String> = []
        var authenticatedIndexes: Set<String> = []
        for file in files where file.lastPathComponent.hasPrefix("native-account-v2-") {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: installationKey,
                                         authenticating: indexAAD(file.lastPathComponent))
            let locator = try JSONDecoder().decode(AccountLocator.self, from: plain)
            try locator.scope.validate()
            guard locator.format == "vortx-native-account-locator-v2", indexURL(locator.scope.account).path == file.path else { throw VortxNativeError.invalidSnapshot }
            guard locator.scope.account != requestedScope.account || locator.scope == requestedScope else { throw VortxNativeError.invalidSnapshot }
            let stateURL = url(locator.scope)
            let bytes = try Data(contentsOf: stateURL)
            guard bytes.starts(with: Self.indexedPrefix) else { throw VortxNativeError.invalidSnapshot }
            let indexed = try JSONDecoder().decode(IndexedCiphertext.self, from: bytes.dropFirst(Self.indexedPrefix.count))
            guard indexed.format == "vortx-native-indexed-ciphertext-v2" else { throw VortxNativeError.invalidSnapshot }
            let proofBytes = try AES.GCM.open(AES.GCM.SealedBox(combined: indexed.proof), using: installationKey,
                                             authenticating: indexAAD(stateURL.lastPathComponent))
            let proof = try JSONDecoder().decode(InventoryProof.self, from: proofBytes)
            guard proof.scope == locator.scope, proof.ciphertextDigest == Data(SHA256.hash(data: indexed.ciphertext)),
                  covered.insert(stateURL.path).inserted else { throw VortxNativeError.invalidSnapshot }
            authenticatedIndexes.insert(file.lastPathComponent)
        }
        guard files.filter({ $0.lastPathComponent.hasPrefix("native-account-v1-") }).allSatisfy({
            authenticatedIndexes.contains($0.lastPathComponent.replacingOccurrences(of: "native-account-v1-", with: "native-account-v2-"))
        }) else { throw VortxNativeError.invalidSnapshot }
        return covered
    }
    private func durableInstall(_ bytes: Data, at destination: URL) throws {
        let staged = directory.appendingPathComponent(".native-index-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: staged) }
        try bytes.write(to: staged, options: [.withoutOverwriting, .completeFileProtection])
        let file = try FileHandle(forWritingTo: staged); defer { try? file.close() }; try file.synchronize()
        guard try Data(contentsOf: staged) == bytes else { throw VortxNativeError.invalidSnapshot }
        guard Darwin.rename(staged.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let fd = Darwin.open(directory.path, O_RDONLY); guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }; guard Darwin.fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard try Data(contentsOf: destination) == bytes else { throw VortxNativeError.invalidSnapshot }
    }
    /// Publish only after a full authenticated account open. The account key and namespace
    /// authenticate this owner lookup; global profile preferences never establish ownership.
    func rememberAuthenticatedScope(_ scope: VortxAccountScope) throws {
        lock.lock(); defer { lock.unlock() }
        try scope.validate()
        do {
            let prior = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: locatorURL(scope.account))),
                                         using: key, authenticating: locatorAAD(scope.account))
            let pinned = try JSONDecoder().decode(AccountLocator.self, from: prior)
            guard pinned.format == "vortx-native-account-locator-v1", pinned.scope == scope else { throw VortxNativeError.invalidSnapshot }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {}
        let existing = try open(Data(contentsOf: url(scope)), scope: scope)
        guard existing.bootstrap != nil else { throw VortxNativeError.invalidSnapshot }
        let payload = try JSONEncoder().encode(AccountLocator(format: "vortx-native-account-locator-v1", scope: scope))
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: locatorAAD(scope.account))
        guard let bytes = sealed.combined else { throw VortxNativeError.invalidSnapshot }
        let staged = directory.appendingPathComponent(".native-locator-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: staged) }
        try bytes.write(to: staged, options: [.withoutOverwriting, .completeFileProtection])
        let file = try FileHandle(forWritingTo: staged); defer { try? file.close() }
        try file.synchronize()
        let stagedPlain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: staged)), using: key, authenticating: locatorAAD(scope.account))
        guard stagedPlain == payload else { throw VortxNativeError.invalidSnapshot }
        guard Darwin.rename(staged.path, locatorURL(scope.account).path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let installed = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: locatorURL(scope.account))),
                                        using: key, authenticating: locatorAAD(scope.account))
        guard installed == payload else { throw VortxNativeError.invalidSnapshot }
        if let installationKey {
            // Only account-key-authenticated state may acquire an installation index. A crash before
            // either publication leaves the file unindexed and blocks new-account admission.
            let ciphertext = try accountCiphertext(Data(contentsOf: url(scope)))
            try durableInstall(indexedCiphertext(ciphertext, scope: scope), at: url(scope))
            let indexPayload = try JSONEncoder().encode(AccountLocator(format: "vortx-native-account-locator-v2", scope: scope))
            guard let indexBytes = try AES.GCM.seal(indexPayload, using: installationKey,
                authenticating: indexAAD(indexURL(scope.account).lastPathComponent)).combined else { throw VortxNativeError.invalidSnapshot }
            try durableInstall(indexBytes, at: indexURL(scope.account))
        }
    }
    /// Offline recovery is read-only until the caller hydrates the proven checkpoint. Missing
    /// locator/checkpoint/archive is not permission to provision a new account.
    func recovery(account: String) throws -> Recovery? {
        lock.lock(); defer { lock.unlock() }
        let bytes: Data
        do { bytes = try Data(contentsOf: locatorURL(account)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: locatorAAD(account))
        let locator = try JSONDecoder().decode(AccountLocator.self, from: plain)
        guard locator.format == "vortx-native-account-locator-v1", locator.scope.account == account else { throw VortxNativeError.invalidSnapshot }
        try locator.scope.validate()
        let envelope = try open(Data(contentsOf: url(locator.scope)), scope: locator.scope)
        guard let bootstrap = envelope.bootstrap else { throw VortxNativeError.invalidSnapshot }
        bootstraps[locator.scope] = bootstrap
        return Recovery(scope: locator.scope, state: envelope.state, bootstrap: bootstrap)
    }
    /// A new cloud owner cannot reset a known account. Older unindexed checkpoints require
    /// their exact authenticated owner before opening; unknown files are never proof of absence.
    func authenticatedCheckpoint(scope: VortxAccountScope) throws -> String? {
        let known = try recovery(account: scope.account)
        guard known == nil || known?.scope == scope else { throw VortxNativeError.invalidSnapshot }
        let checkpoint = try read(scope: scope)
        if known == nil, checkpoint == nil {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
            let covered = try authenticatedInventory(for: scope)
            guard files.filter({ $0.lastPathComponent.hasPrefix("native-state-v1-") }).allSatisfy({ covered.contains($0.path) }) else { throw VortxNativeError.invalidSnapshot }
        }
        return checkpoint
    }
    private func open(_ data: Data, scope: VortxAccountScope) throws -> Envelope {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: accountCiphertext(data)), using: key, authenticating: scope.authenticatedData)
        guard let snapshot = String(data: plain, encoding: .utf8) else { throw VortxNativeError.invalidSnapshot }
        if let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any], object["format"] != nil {
            let envelope = try JSONDecoder().decode(Envelope.self, from: plain)
            guard envelope.format == "vortx-native-checkpoint-v1" else { throw VortxNativeError.invalidSnapshot }
            _ = try scope.validateSnapshot(envelope.state)
            if let bootstrap = envelope.bootstrap { try VortxNativeBootstrapArchive.validate(bootstrap) }
            if let host = envelope.hostPreferences { try VortxNativeHostPreferences.validateSealed(host, scope: scope) }
            return envelope
        }
        // Dual-read the prior raw runtime format without ever treating a failed decode as absence.
        _ = try scope.validateSnapshot(snapshot)
        return Envelope(format: "vortx-native-checkpoint-v1", state: snapshot, bootstrap: nil)
    }
    func read(scope: VortxAccountScope) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        try scope.validate()
        do {
            let envelope = try open(Data(contentsOf: url(scope)), scope: scope)
            if let retained = envelope.bootstrap { bootstraps[scope] = retained }
            return envelope.state
        }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        try commitSnapshot(snapshot, scope: scope, hostPreferences: nil)
    }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        do { return try open(Data(contentsOf: url(scope)), scope: scope).hostPreferences }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let bootstrap: Data?
        do { bootstrap = try open(Data(contentsOf: url(scope)), scope: scope).bootstrap }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { bootstrap = bootstraps[scope] }
        guard let bootstrap, let material = try JSONDecoder().decode(VortxJSON.self, from: bootstrap)["legacyImportMaterial"] else { return nil }
        return try JSONEncoder().encode(material)
    }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try VortxNativeHostPreferences.validateSealed(hostPreferences, scope: scope)
        try commitSnapshot(snapshot, scope: scope, hostPreferences: hostPreferences)
    }
    private func commitSnapshot(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        try scope.validate(); _ = try scope.validateSnapshot(snapshot)
        var retainedHost = hostPreferences
        do {
            // The first migration source is immutable, even for a fresh store instance making a
            // later commit. A decode/read failure must not replace it with a newer/empty carrier.
            let retained = try open(Data(contentsOf: url(scope)), scope: scope)
            if let bootstrap = retained.bootstrap { bootstraps[scope] = bootstrap }
            if retainedHost == nil { retainedHost = retained.hostPreferences }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {}
        let bootstrap = bootstraps[scope]
        let envelope = Envelope(format: "vortx-native-checkpoint-v1", state: snapshot, bootstrap: bootstrap, hostPreferences: retainedHost)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(envelope), using: key, authenticating: scope.authenticatedData)
        guard let combined = sealed.combined else { throw VortxNativeError.invalidSnapshot }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".native-checkpoint-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: staged) }
        try indexedCiphertext(combined, scope: scope).write(to: staged, options: [.withoutOverwriting, .completeFileProtection])
        let file = try FileHandle(forWritingTo: staged); defer { try? file.close() }
        try file.synchronize()
        let stagedRead = try open(Data(contentsOf: staged), scope: scope)
        guard stagedRead.state == snapshot, stagedRead.bootstrap == bootstrap, stagedRead.hostPreferences == retainedHost else { throw VortxNativeError.invalidSnapshot }
        guard Darwin.rename(staged.path, url(scope).path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let installed = try open(Data(contentsOf: url(scope)), scope: scope)
        guard installed.state == snapshot, installed.bootstrap == bootstrap, installed.hostPreferences == retainedHost else { throw VortxNativeError.invalidSnapshot }
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

/// An explicitly constructed, account-owned native session, selected only by the compile-time gate,
/// never a UI preference. All state mutation is copy/apply/checkpoint/swap: a failed durable write leaves the
/// published runtime unchanged. Actor isolation fences logout/profile switches across async loads.
actor VortxNativeSession {
    enum CatalogScreen: String, Sendable { case board, discover, search }
    let scope: VortxAccountScope
    private let abi: any VortxRuntimeABI
    private let store: any VortxCheckpointStore
    private let transport: any VortxResourceTransport
    private var runtime: VortxNativeRuntime
    private var hostPreferences: VortxNativeHostPreferences
    private let legacyBaseline: Data?
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
         initialActions: [String] = [], hostActor: String = UUID().uuidString.lowercased()) throws {
        try scope.validate()
        guard legacy == nil || legacy?.scope == scope else { throw VortxNativeError.invalidSnapshot }
        self.scope = scope; self.abi = abi; self.store = store; self.transport = transport
        legacyBaseline = try store.readLegacyMaterial(scope: scope)
        hostPreferences = try VortxNativeHostPreferences(scope: scope, actor: hostActor, sealed: store.readHostPreferences(scope: scope))
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
    /// A never-backed account must win create-only publication before it owns a durable local
    /// checkpoint. This detached candidate has no writer lease, checkpoint or mounted session.
    nonisolated static func detachedLegacySync(scope: VortxAccountScope, ownerName: String, material: Data,
                                               abi: any VortxRuntimeABI) throws -> VortxJSON {
        try scope.validate()
        let candidate = try VortxNativeRuntime(abi: abi, ownerID: scope.ownerProfileID, ownerName: ownerName)
        defer { candidate.close() }
        try bind(candidate, scope: scope)
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account),
            "ownerProfileId": .string(scope.ownerProfileID), "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        try apply(candidate, action: String(decoding: JSONEncoder().encode(action), as: UTF8.self))
        guard let sync = try scope.validateSnapshot(candidate.stateJSON())["nativeSync"] else { throw VortxNativeError.invalidSnapshot }
        return sync
    }
    /// Before durable reopen/adoption, prove the complete legacy material against a detached
    /// kernel candidate. Exact receipt replay is compatible with older artifacts; changed intent
    /// requires the private kernel's causal reconciliation action. Missing receipts never seed.
    nonisolated static func validateLegacyCompatibility(scope: VortxAccountScope, ownerName: String,
                                                        snapshot: String?, nativeSync: VortxJSON?, material: Data,
                                                        abi: any VortxRuntimeABI, baselineMaterial: Data? = nil) throws {
        try scope.validate()
        let candidate: VortxNativeRuntime
        if let snapshot {
            _ = try scope.validateSnapshot(snapshot)
            candidate = try VortxNativeRuntime(abi: abi, snapshot: snapshot)
        } else { candidate = try VortxNativeRuntime(abi: abi, ownerID: scope.ownerProfileID, ownerName: ownerName) }
        defer { candidate.close() }
        try bind(candidate, scope: scope)
        if let nativeSync {
            let action: VortxJSON = .object(["type": .string("merge_native_sync"), "document": nativeSync])
            try apply(candidate, action: String(decoding: JSONEncoder().encode(action), as: UTF8.self))
        }
        try validateLegacyReceipt(candidate, scope: scope, material: material, baselineMaterial: baselineMaterial)
    }
    private static func validateLegacyReceipt(_ candidate: VortxNativeRuntime, scope: VortxAccountScope, material: Data, baselineMaterial: Data?) throws {
        let state = try scope.validateSnapshot(candidate.stateJSON())
        guard state["nativeSync"]?["legacyImport"]?["schemaVersion"] == .integer(1) else { throw VortxNativeError.invalidSnapshot }
        let replay: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account),
                                       "ownerProfileId": .string(scope.ownerProfileID),
                                       "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        let replayResult = try candidate.dispatch(String(decoding: JSONEncoder().encode(replay), as: UTF8.self), now: UInt64(Date().timeIntervalSince1970))
        if try JSONDecoder().decode(VortxJSON.self, from: Data(replayResult.utf8))["ok"] == .bool(true) { return }
        // Only the private kernel decides which old-peer causal changes are supported. Older
        // artifacts reject this additive action and remain closed; there is no host reducer.
        var reconciliation: [String: VortxJSON] = ["type": .string("reconcile_legacy_sync"), "scope": .string(scope.account),
            "ownerProfileId": .string(scope.ownerProfileID), "material": try JSONDecoder().decode(VortxJSON.self, from: material)]
        if state["nativeSync"]?["legacyImport"]?["baseline"] == nil, let baselineMaterial {
            reconciliation["baselineMaterial"] = try JSONDecoder().decode(VortxJSON.self, from: baselineMaterial)
        }
        try apply(candidate, action: String(decoding: JSONEncoder().encode(VortxJSON.object(reconciliation)), as: UTF8.self))
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
    func hostPreferencesDocument() throws -> VortxJSON {
        try lease.withActive { try hostPreferences.document }
    }
    @discardableResult func dispatch(_ actions: [String], now: UInt64, legacyMaterial: Data? = nil,
                                    hostRemote: VortxJSON? = nil, hostEdits: [VortxNativeHostPreferences.Edit] = []) throws -> [String] {
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
        if let legacyMaterial { try Self.validateLegacyReceipt(candidate, scope: scope, material: legacyMaterial, baselineMaterial: legacyBaseline) }
        let updated = try candidate.stateJSON()
        let state = try scope.validateSnapshot(updated)
        var candidateHost = hostPreferences
        try candidateHost.merge(hostRemote, scope: scope)
        for edit in hostEdits {
            if let profile = edit.profileID {
                guard let record = state["roster"]?["profiles"]?[profile], record["deleted"] != .bool(true) else { throw VortxNativeError.invalidSnapshot }
            }
            try candidateHost.edit(profileID: edit.profileID, fields: edit.fields, scope: scope)
        }
        let hasHostChanges = hostRemote != nil || !hostEdits.isEmpty
        do {
            try lease.withActive {
                if hasHostChanges { try store.commit(updated, scope: scope, hostPreferences: candidateHost.encoded()) }
                else { try store.commit(updated, scope: scope) }
            }
        }
        catch VortxNativeError.closed { throw VortxNativeError.closed }
        catch {
            // A rename may have succeeded before a readback/fsync failure. Do not overwrite that
            // uncertain checkpoint with another transaction; reopen and validate it first.
            persistenceFailed = true; throw VortxNativeError.checkpointUncertain
        }
        let previous = runtime; runtime = candidate; hostPreferences = candidateHost; installed = true; previous.close()
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
            var accepted = append ? pages[name] ?? [] : []
            // A cancelled host publication can leave its already accepted page in this actor.
            // Retrying the identical source/path replaces that page instead of duplicating it.
            if let index = accepted.firstIndex(where: { $0.request == result.request && $0.sourceURLs == result.sourceURLs }) {
                accepted[index] = result
            } else { accepted.append(result) }
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
    /// Independent, non-UI metadata lookup for a deliberate library add. It cannot replace the
    /// detail screen or cancel another title's add; account/profile/registry invalidation still wins.
    func libraryMetadata(id: String, type: String, profileID: String, addons: [VortxResourceAddon]) async throws -> VortxJSON {
        let name = "library_lookup:" + UUID().uuidString
        let (bridge, ticket, capturedEpoch, profile) = try begin(name)
        defer { bridge.invalidate(); bridges.removeValue(forKey: name); tickets.removeValue(forKey: name); screens.removeValue(forKey: name) }
        guard profile == profileID else { throw VortxNativeError.superseded }
        let result = try await bridge.load(ownerID: profile, request: .init(resource: .meta, type: type, id: id), addons: addons)
        guard current(name, ticket, capturedEpoch), bridge.accepts(result) else { throw VortxNativeError.superseded }
        for addon in addons {
            guard let group = result.groups.first(where: { $0.addonId == addon.id }), group.status == .ready,
                  let meta = group.content?["meta"], meta["id"] == .string(id), meta["type"] == .string(type),
                  case .string(let title) = meta["name"], !title.isEmpty else { continue }
            return meta
        }
        throw VortxNativeError.invalidResponse
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
