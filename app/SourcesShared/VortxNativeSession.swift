import Foundation
import CryptoKit
import Darwin
import Security

/// File errors carry private URLs and account paths in userInfo/localizedDescription. Keep only
/// allowlisted domains, numeric codes, and a static stage while rethrowing the original error.
enum VortxCheckpointDiagnostics {
    enum Stage: String {
        case validate, retainExisting = "retain_existing", seal, createDirectory = "create_directory"
        case stageWrite = "stage_write", stageSync = "stage_sync", stageReadback = "stage_readback"
        case install, directorySync = "directory_sync", installedReadback = "installed_readback"
        case transactionCommit = "transaction_commit"
    }
    static func summary(stage: Stage, error: Error) -> String {
        func code(_ error: Error) -> String {
            if error is VortxNativeError { return "domain=native code=" + VortxNativeError.diagnosticCode(error) }
            let value = error as NSError
            let domain: String
            switch value.domain {
            case NSCocoaErrorDomain: domain = "cocoa"
            case NSPOSIXErrorDomain: domain = "posix"
            case NSOSStatusErrorDomain: domain = "osstatus"
            default: domain = error is CryptoKitError ? "cryptokit" : "other"
            }
            return "domain=\(domain) code=\(value.code)"
        }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        return "stage=\(stage.rawValue) \(code(error))" + (underlying.map { " underlying_" + code($0) } ?? "")
    }
    static func report(stage: Stage, error: Error) {
        VXProbe.log("native-checkpoint", summary(stage: stage, error: error))
    }
}

/// Immutable, owner-only installation identity. Publication never replaces an existing key,
/// including when two independent app processes race. Legacy access is migration-only.
final class VortxNativeInstallationKeyFileStore: @unchecked Sendable {
    enum Boundary { case beforePublish, afterPublish }
    private let directory: URL
    private let legacyRead: () throws -> Data?
    private let randomBytes: () throws -> Data
    private let boundary: (Boundary) throws -> Void
    private let lock = NSLock()
    private var cached: Data?
    private let filename = "native-installation-v2.key"
    init(directory: URL, legacyRead: @escaping () throws -> Data?, randomBytes: @escaping () throws -> Data,
         boundary: @escaping (Boundary) throws -> Void = { _ in }) {
        self.directory = directory; self.legacyRead = legacyRead; self.randomBytes = randomBytes; self.boundary = boundary
    }
    private func openDirectory() throws -> Int32 {
        let parent = Darwin.open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw VortxNativeError.unavailable }
        defer { Darwin.close(parent) }
        let name = directory.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw VortxNativeError.unavailable }
        guard Darwin.mkdirat(parent, name, mode_t(0o700)) == 0 || errno == EEXIST else { throw VortxNativeError.unavailable }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw VortxNativeError.unavailable }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              Darwin.fchmod(fd, mode_t(0o700)) == 0, Darwin.fstat(fd, &info) == 0,
              info.st_mode & mode_t(0o7777) == mode_t(0o700), Darwin.fsync(parent) == 0 else {
            Darwin.close(fd); throw VortxNativeError.unavailable
        }
        return fd
    }
    private func readFinal(_ directoryFD: Int32) throws -> Data? {
        let fd = Darwin.openat(directoryFD, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw VortxNativeError.unavailable
        }
        var closed = false
        defer { if !closed { Darwin.close(fd) } }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & mode_t(0o7777) == mode_t(0o600), info.st_size == 32 else { throw VortxNativeError.unavailable }
        var bytes = Data(count: 33), count = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while count < 33 {
                let read = Darwin.read(fd, buffer.baseAddress!.advanced(by: count), 33 - count)
                if read < 0 && errno == EINTR { continue }
                guard read >= 0 else { throw VortxNativeError.unavailable }
                if read == 0 { break }
                count += read
            }
        }
        guard count == 32 else { throw VortxNativeError.unavailable }
        let result = Darwin.close(fd); closed = true
        guard result == 0 else { throw VortxNativeError.unavailable }
        return Data(bytes.prefix(count))
    }
    func loadOrCreateBytes() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let directoryFD = try openDirectory()
        defer { Darwin.close(directoryFD) }
        if let existing = try readFinal(directoryFD) {
            // Also heals a prior publication whose directory sync was interrupted.
            guard Darwin.fsync(directoryFD) == 0 else { throw VortxNativeError.unavailable }
            cached = existing; return existing
        }
        let legacy = try legacyRead(), candidate = try legacy ?? randomBytes()
        guard candidate.count == 32 else { throw VortxNativeError.unavailable }
        let stage = ".native-installation-\(UUID().uuidString).stage"
        let fd = Darwin.openat(directoryFD, stage, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw VortxNativeError.unavailable }
        var closed = false
        defer { if !closed { Darwin.close(fd) }; Darwin.unlinkat(directoryFD, stage, 0) }
        guard Darwin.fchmod(fd, mode_t(0o600)) == 0 else { throw VortxNativeError.unavailable }
        try candidate.withUnsafeBytes { buffer in
            var count = 0
            while count < candidate.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: count), candidate.count - count)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw VortxNativeError.unavailable }
                count += written
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw VortxNativeError.unavailable }
        let closeResult = Darwin.close(fd); closed = true
        guard closeResult == 0 else { throw VortxNativeError.unavailable }
        try boundary(.beforePublish)
        let linked = Darwin.linkat(directoryFD, stage, directoryFD, filename, 0)
        let collision = linked != 0 && errno == EEXIST
        guard linked == 0 || collision else { throw VortxNativeError.unavailable }
        try boundary(.afterPublish)
        guard Darwin.unlinkat(directoryFD, stage, 0) == 0, Darwin.fsync(directoryFD) == 0,
              let winner = try readFinal(directoryFD),
              (collision && legacy == nil) || winner == candidate else { throw VortxNativeError.unavailable }
        cached = winner; return winner
    }
}
// End immutable installation-key file store (mechanically extracted by its regression gate).

/// Root for the native account stores (checkpoints, preference intents). A physical Apple TV cannot
/// create Library/Application Support (the simulator can), so tvOS keeps them in Caches. Caches may be
/// purged under storage pressure; the encrypted cloud account stays authoritative, so a purge only means
/// the next launch re-adopts the account. The installation key stays in the tvOS Keychain.
enum VortxNativeStorage {
    static func root() throws -> URL {
        #if os(tvOS)
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
    }
}

/// This key authenticates only the local checkpoint inventory. Account ciphertext remains readable
/// with its independent account key after device-key loss; no installation identity is exported.
enum VortxNativeInstallationKey {
    private static let lock = NSLock()
    private static func readLegacy() throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tv.vortx.native-installation", kSecAttrAccount as String: "checkpoint-inventory-v2",
            kSecAttrSynchronizable as String: false]
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 else { throw VortxNativeError.unavailable }
        return bytes
    }
    private static func randomBytes() throws -> Data {
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw VortxNativeError.unavailable }
        return bytes
    }
    #if os(macOS)
    private static let fileStore = VortxNativeInstallationKeyFileStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VortX", isDirectory: true),
        legacyRead: { try readLegacy() }, randomBytes: { try randomBytes() })
    #endif
    static func loadOrCreate() throws -> SymmetricKey {
        #if os(macOS)
        return SymmetricKey(data: try fileStore.loadOrCreateBytes())
        #else
        lock.lock(); defer { lock.unlock() }
        if let existing = try readLegacy() { return SymmetricKey(data: existing) }
        let bytes = try randomBytes()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tv.vortx.native-installation", kSecAttrAccount as String: "checkpoint-inventory-v2",
            kSecAttrSynchronizable as String: false]
        var item = query; item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem, let confirmed = try readLegacy(),
              status == errSecDuplicateItem || confirmed == bytes else { throw VortxNativeError.unavailable }
        return SymmetricKey(data: confirmed)
        #endif
    }
}

/// Native-only exports cannot acknowledge legacy host edits they deliberately do not serialize.
enum VortxNativeSyncExportPolicy {
    static func acknowledgesSetting(_ key: String, syncable: Bool, profileProjection: Bool, projectionAcknowledged: Bool) -> Bool {
        if !syncable { return true } // Retire obsolete device-local stamps, never export their values.
        if VortxNativeHostPreferences.knownGlobals.contains(key) { return true }
        if profileProjection { return projectionAcknowledged }
        return ["stremiox.profiles.active", "stremiox.activeProfileId"].contains(key)
    }
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
                  Self.supportedNativeSyncSchema(sync["schemaVersion"]) else { throw VortxNativeError.invalidSnapshot }
        }
        return value
    }
    private static func supportedNativeSyncSchema(_ value: VortxJSON?) -> Bool {
        switch value {
        case .integer(let schema): return (1...5).contains(schema)
        case .unsigned(let schema): return (1...5).contains(schema)
        default: return false
        }
    }
    func validateHydration(from original: String, to hydrated: String) throws {
        let before = try validateSnapshot(original), after = try validateSnapshot(hydrated)
        guard before["nativeSync"] == after["nativeSync"] else { throw VortxNativeError.invalidSnapshot }
        guard case .object(let libraries) = before["libraries"] else { throw VortxNativeError.invalidSnapshot }
        for (profile, library) in libraries {
            if let context = library["watchContexts"] {
                let hydrated = after["libraries"]?[profile]?["watchContexts"]
                if case .object(let retained) = context, case .object(let projected)? = hydrated {
                    // The unchanged nativeSync authority can synthesize a missing context during
                    // hydration. Additions are lossless; every previously sealed entry must still
                    // survive exactly, including metadata and duration, before mounting/committing.
                    guard retained.allSatisfy({ projected[$0.key] == $0.value }) else { throw VortxNativeError.invalidSnapshot }
                } else {
                    guard context == hydrated else { throw VortxNativeError.invalidSnapshot }
                }
            }
        }
    }
}

/// A same-read, in-process receipt for one authenticated draft snapshot. No raw bytes are
/// decoded in withActive. Construction is restricted to this source file's real store.
struct VortxMigrationDraftRead: VortxMutationAuthority {
    let archive: Data?
    private let validate: @Sendable (() throws -> Void) throws -> Void
    fileprivate init(archive: Data?, validate: @escaping @Sendable (() throws -> Void) throws -> Void) {
        self.archive = archive; self.validate = validate
    }
    func withActive(_ operation: () throws -> Void) throws { try validate(operation) }
    /// Publication retains only the validator/store, not the potentially large raw archive.
    var authority: any VortxMutationAuthority { Authority(validate: validate) }
    private struct Authority: VortxMutationAuthority {
        let validate: @Sendable (() throws -> Void) throws -> Void
        func withActive(_ operation: () throws -> Void) throws { try validate(operation) }
    }
}

protocol VortxCheckpointStore: Sendable {
    /// nil means absent only. Corruption, inaccessible keys, wrong scope and I/O failures must throw.
    func read(scope: VortxAccountScope) throws -> String?
    /// Must atomically replace and read back before returning. Never log or write plaintext state.
    func commit(_ snapshot: String, scope: VortxAccountScope) throws
    func readHostPreferences(scope: VortxAccountScope) throws -> Data?
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data?
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON?
    func readMigrationDraft(scope: VortxAccountScope) throws -> Data?
    /// Authenticated immutable bytes + original process generation; strict replay remains cold.
    func captureMigrationDraft(scope: VortxAccountScope) throws -> VortxMigrationDraftRead
    /// A requirement, not extension-only dispatch: encrypted stores may snapshot under
    /// their file lock, then replay outside it. nil still means genuinely absent only.
    func readMigrationDraftCooperatively(scope: VortxAccountScope,
        isCurrent: @escaping @Sendable () -> Bool,
        checkpoint: (@Sendable () async throws -> Void)?) async throws -> Data?
    func retainMigrationDraft(_ archive: Data, scope: VortxAccountScope, expected: Data?, authority: any VortxMutationAuthority) throws
    /// The witness proves exact scoped bytes, never current ownership. Implementations
    /// must retain their atomic authority, expected-byte CAS and durable-readback checks.
    func retainValidatedMigrationDraft(_ draft: VortxNativeWatchedArchive.ValidatedDraft,
        scope: VortxAccountScope, expected: Data?, authority: any VortxMutationAuthority) throws
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws
}
// VortxMutationAuthority is declared in the shared native host-field transaction contracts.
extension VortxCheckpointStore {
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { nil }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { nil }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { nil }
    func readMigrationDraft(scope: VortxAccountScope) throws -> Data? { nil }
    func captureMigrationDraft(scope: VortxAccountScope) throws -> VortxMigrationDraftRead {
        throw VortxNativeError.unavailable // No absence/clear fallback for stores without a real receipt.
    }
    /// Existing stores keep their synchronous reader. Run it on the explicit recovery
    /// actor and strictly validate its result; never cast or trust unchecked raw bytes.
    func readMigrationDraftCooperatively(scope: VortxAccountScope,
        isCurrent: @escaping @Sendable () -> Bool,
        checkpoint: (@Sendable () async throws -> Void)? = nil) async throws -> Data? {
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: scope,
            isCurrent: isCurrent, checkpoint: checkpoint)
        return try await worker.readSynchronousDraft(self)
    }
    func retainMigrationDraft(_ archive: Data, scope: VortxAccountScope, expected: Data?, authority: any VortxMutationAuthority) throws {
        throw VortxNativeError.unavailable
    }
    /// Old protocol stores keep their existing strict synchronous writer, including
    /// any repeated replay cost. Only an explicit witness implementation may skip it.
    func retainValidatedMigrationDraft(_ draft: VortxNativeWatchedArchive.ValidatedDraft,
        scope: VortxAccountScope, expected: Data?, authority: any VortxMutationAuthority) throws {
        try retainMigrationDraft(draft.bytes(for: scope), scope: scope, expected: expected, authority: authority)
    }
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
        // Complete immutable raw-source journal + pending candidates. This is sealed in the
        // same ciphertext as state; it is not a capability or a public preference field.
        var ownerHistoryLocal: Data? = nil
        /// Full raw authenticated account base. Stored ONLY under the typed local format.
        var ownerHistoryAccountBase: Data? = nil
        var ownerHistoryReadUID: String? = nil
    }
    private let directory: URL
    private let key: SymmetricKey
    private let installationKey: SymmetricKey?
    private let lock = NSLock()
    private static let migrationDraftLock = NSLock()
    // Access only under migrationDraftLock, across all live store/probe instances.
    nonisolated(unsafe) private static var migrationDraftGenerations: [Data: UUID] = [:]
    private let migrationDraftDirectory: URL
    private var bootstraps: [VortxAccountScope: Data] = [:]
    private var accountBases: [VortxAccountScope: Data] = [:]
    /// The checkpoint this store last wrote or fully opened, per scope: the digest of the exact file bytes
    /// and the parts a commit carries forward. While the file still hashes the same, a commit skips the full
    /// decrypt and validation of it; a fresh store instance, or a file replaced underneath, opens it in full.
    private struct Installed {
        let format: String
        let accountBase: Data?
        let digest: SHA256.Digest
        let state: String
        let bootstrap: Data?
        let hostPreferences: Data?
        let ownerHistoryLocal: Data?
    }
    private var installed: [VortxAccountScope: Installed] = [:]
    private let ownerHistoryStoreID = UUID()

    struct OwnerHistoryRead: Sendable {
        let format: String
        let ownerHistoryAccountBase: Data?
        let preservedOwnerUID: String?
        let snapshot: Data
        let hostPreferences: Data?
        let ownerHistoryLocal: Data?
        fileprivate let storeID: UUID
        fileprivate let fileDigest: Data
        fileprivate let bootstrap: Data?
        fileprivate let scope: VortxAccountScope
        fileprivate init(snapshot: Data, hostPreferences: Data?, ownerHistoryLocal: Data?,
                         format: String, accountBase: Data?, preservedOwnerUID: String?,
                         storeID: UUID, fileDigest: Data, bootstrap: Data?, scope: VortxAccountScope) {
            self.snapshot = snapshot; self.hostPreferences = hostPreferences
            self.format = format; ownerHistoryAccountBase = accountBase
            self.preservedOwnerUID = preservedOwnerUID
            self.ownerHistoryLocal = ownerHistoryLocal; self.storeID = storeID
            self.fileDigest = fileDigest; self.bootstrap = bootstrap
            self.scope = scope
        }
    }

    /// One decrypt/read yields all parts and a store-bound exact ciphertext CAS. No schema6
    /// value is exposed through the old generic reader; the owned native session must complete
    /// its mandatory full replay/normalization callback before publishing this envelope.
    func readOwnerHistory(scope: VortxAccountScope) throws -> OwnerHistoryRead? {
        try lock.withLock {
            try scope.validate()
            let bytes: Data
            do { bytes = try Data(contentsOf: url(scope)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: accountCiphertext(bytes)),
                using: key, authenticating: scope.authenticatedData)
            let envelope = try JSONDecoder().decode(Envelope.self, from: plain)
            guard ["vortx-native-checkpoint-v1", "vortx-native-owner-history-checkpoint-v1"].contains(envelope.format),
                  envelope.state.utf8.count <= OwnerHistorySessionRuntime.maximumBytes else {
                throw VortxNativeError.invalidSnapshot
            }
            if let bootstrap = envelope.bootstrap { try VortxNativeBootstrapArchive.validate(bootstrap) }
            if let host = envelope.hostPreferences { try VortxNativeHostPreferences.validateSealed(host, scope: scope) }
            return OwnerHistoryRead(snapshot: Data(envelope.state.utf8), hostPreferences: envelope.hostPreferences,
                ownerHistoryLocal: envelope.ownerHistoryLocal,
                format: envelope.format, accountBase: envelope.ownerHistoryAccountBase,
                preservedOwnerUID: envelope.ownerHistoryReadUID, storeID: ownerHistoryStoreID,
                fileDigest: Data(SHA256.hash(data: bytes)), bootstrap: envelope.bootstrap, scope: scope)
        }
    }
    private func requireCurrentOwnerHistoryLocked(_ expected: OwnerHistoryRead, scope: VortxAccountScope) throws {
        guard expected.storeID == ownerHistoryStoreID, expected.scope == scope,
              Data(SHA256.hash(data: try Data(contentsOf: url(scope)))) == expected.fileDigest else {
            throw VortxNativeError.superseded
        }
    }
    func requireCurrentOwnerHistory(_ expected: OwnerHistoryRead, scope: VortxAccountScope) throws {
        try lock.withLock { try requireCurrentOwnerHistoryLocked(expected, scope: scope) }
    }

    /// The only new schema6-capable writer: accepts a non-constructible coordinator checkpoint,
    /// checks the original encrypted base under this file lock, and uses the real durableInstall
    /// staging/fsync/rename/directory-fsync/exact-installed-ciphertext readback implementation.
    /// The caller holds genuine whole-account + source + admitted FIFO authority throughout.
    func commitOwnerHistory(_ candidate: OwnerHistorySessionCoordinator.Checkpoint,
                            expected: OwnerHistoryRead, scope: VortxAccountScope) throws -> OwnerHistoryRead {
        try lock.withLock {
            do {
                try scope.validate()
                try requireCurrentOwnerHistoryLocked(expected, scope: scope)
                guard let state = String(data: candidate.snapshot, encoding: .utf8),
                      candidate.snapshot.count <= OwnerHistorySessionRuntime.maximumBytes else {
                    throw VortxNativeError.invalidSnapshot
                }
                try VortxNativeHostPreferences.validateSealed(candidate.hostPreferences, scope: scope)
                guard let accountBase = candidate.accountBase else { throw VortxNativeError.invalidSnapshot }
                // Even pending/schema5 ownership is not readable by beta2's generic writer.
                let envelope = Envelope(format: "vortx-native-owner-history-checkpoint-v1", state: state,
                    bootstrap: expected.bootstrap, hostPreferences: candidate.hostPreferences,
                    ownerHistoryLocal: candidate.ownerHistoryLocal, ownerHistoryAccountBase: accountBase,
                    ownerHistoryReadUID: candidate.preservedOwnerUID)
                let sealed = try AES.GCM.seal(JSONEncoder().encode(envelope), using: key,
                    authenticating: scope.authenticatedData)
                guard let combined = sealed.combined else { throw VortxNativeError.invalidSnapshot }
                let bytes = try indexedCiphertext(combined, scope: scope)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try durableInstall(bytes, at: url(scope))
                remember(bytes, envelope, scope: scope)
                return OwnerHistoryRead(snapshot: candidate.snapshot, hostPreferences: candidate.hostPreferences,
                    ownerHistoryLocal: candidate.ownerHistoryLocal,
                    format: envelope.format, accountBase: accountBase,
                    preservedOwnerUID: candidate.preservedOwnerUID, storeID: ownerHistoryStoreID,
                    fileDigest: Data(SHA256.hash(data: bytes)), bootstrap: expected.bootstrap, scope: scope)
            } catch {
                installed[scope] = nil
                throw error
            }
        }
    }
    /// Original authenticated absence/inventory token, retained across the cold replay.
    /// It is not constructible outside this store and never treats a read failure as absence.
    fileprivate struct OwnerHistoryAbsence {
        let scope: VortxAccountScope
        let storeID: UUID
        let files: [String: Data]
    }
    private func ownerHistoryInventoryLocked(scope: VortxAccountScope) throws -> [String: Data] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [:] }
        let covered = try authenticatedInventory(for: scope)
        guard files.filter({ $0.lastPathComponent.hasPrefix("native-state-v1-") })
            .allSatisfy({ covered.contains($0.path) }) else { throw VortxNativeError.invalidSnapshot }
        var result: [String: Data] = [:]
        for file in files where ["native-state-v1-", "native-account-v1-", "native-account-v2-"]
            .contains(where: file.lastPathComponent.hasPrefix) {
            result[file.lastPathComponent] = Data(SHA256.hash(data: try Data(contentsOf: file)))
        }
        return result
    }
    fileprivate func captureOwnerHistoryAbsence(scope: VortxAccountScope) throws -> OwnerHistoryAbsence {
        // Preserve existing owner/locator/key/inventory admission, including unknown files.
        guard try authenticatedCheckpoint(scope: scope) == nil else { throw VortxNativeError.superseded }
        return try lock.withLock {
            let files = try ownerHistoryInventoryLocked(scope: scope)
            guard files[url(scope).lastPathComponent] == nil,
                  files[locatorURL(scope.account).lastPathComponent] == nil,
                  files[indexURL(scope.account).lastPathComponent] == nil else { throw VortxNativeError.superseded }
            return .init(scope: scope, storeID: ownerHistoryStoreID, files: files)
        }
    }
    /// Only a full native cold candidate may create a typed envelope. The final hard link is
    /// create-only: another process winning this exact target is never overwritten.
    fileprivate func installColdOwnerHistory(_ candidate: OwnerHistorySessionCoordinator.Checkpoint,
        bootstrap: Data, expected: OwnerHistoryAbsence, scope: VortxAccountScope) throws -> OwnerHistoryRead {
        try lock.withLock {
            guard expected.scope == scope, expected.storeID == ownerHistoryStoreID,
                  try ownerHistoryInventoryLocked(scope: scope) == expected.files,
                  let state = String(data: candidate.snapshot, encoding: .utf8),
                  candidate.snapshot.count <= OwnerHistorySessionRuntime.maximumBytes,
                  let base = candidate.accountBase, !candidate.preservedOwnerUID.isEmpty else {
                throw VortxNativeError.superseded
            }
            try VortxNativeBootstrapArchive.validate(bootstrap)
            try VortxNativeHostPreferences.validateSealed(candidate.hostPreferences, scope: scope)
            let envelope = Envelope(format: "vortx-native-owner-history-checkpoint-v1", state: state,
                bootstrap: bootstrap, hostPreferences: candidate.hostPreferences,
                ownerHistoryLocal: candidate.ownerHistoryLocal, ownerHistoryAccountBase: base,
                ownerHistoryReadUID: candidate.preservedOwnerUID)
            guard let combined = try AES.GCM.seal(JSONEncoder().encode(envelope), using: key,
                authenticating: scope.authenticatedData).combined else { throw VortxNativeError.invalidSnapshot }
            let bytes = try indexedCiphertext(combined, scope: scope)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent(".native-checkpoint-\(UUID().uuidString).sealed")
            defer { try? FileManager.default.removeItem(at: staged) }
            try bytes.write(to: staged, options: [.withoutOverwriting, .completeFileProtection])
            let file = try FileHandle(forWritingTo: staged); defer { try? file.close() }
            try file.synchronize()
            guard try Data(contentsOf: staged) == bytes else { throw VortxNativeError.invalidSnapshot }
            guard Darwin.link(staged.path, url(scope).path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            // A successful link may already be durable if a later operation fails. Never
            // delete it or fall back to a generic baseline after this point.
            do {
                guard Darwin.unlink(staged.path) == 0 else { throw VortxNativeError.checkpointUncertain }
                let fd = Darwin.open(directory.path, O_RDONLY)
                guard fd >= 0 else { throw VortxNativeError.checkpointUncertain }
                defer { Darwin.close(fd) }
                guard Darwin.fsync(fd) == 0, try Data(contentsOf: url(scope)) == bytes else {
                    throw VortxNativeError.checkpointUncertain
                }
                // Check every original account inventory byte without requiring our new,
                // not-yet-located target to have acquired a public inventory index.
                for (name, digest) in expected.files {
                    guard Data(SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(name)))) == digest else {
                        throw VortxNativeError.checkpointUncertain
                    }
                }
                remember(bytes, envelope, scope: scope)
                return OwnerHistoryRead(snapshot: candidate.snapshot, hostPreferences: candidate.hostPreferences,
                    ownerHistoryLocal: candidate.ownerHistoryLocal, format: envelope.format,
                    accountBase: base, preservedOwnerUID: candidate.preservedOwnerUID,
                    storeID: ownerHistoryStoreID, fileDigest: Data(SHA256.hash(data: bytes)),
                    bootstrap: bootstrap, scope: scope)
            } catch { installed[scope] = nil; throw VortxNativeError.checkpointUncertain }
        }
    }

    private struct AccountLocator: Codable {
        let format: String
        let scope: VortxAccountScope
        var accountLocatorDigest: Data? = nil
    }
    private struct InventoryProof: Codable { let scope: VortxAccountScope; let ciphertextDigest: Data }
    private struct IndexedCiphertext: Codable { let format: String; let ciphertext: Data; let proof: Data }
    private static let indexedPrefix = Data("vortx-native-indexed-ciphertext-v2\n".utf8)
    struct Recovery {
        let scope: VortxAccountScope
        let state: String
        let bootstrap: Data
    }
    init(directory: URL, key: SymmetricKey, installationKey: SymmetricKey? = nil, bootstrap: Data? = nil, bootstrapScope: VortxAccountScope? = nil,
         ownerHistoryAccountBase: Data? = nil) throws {
        guard key.bitCount == 256, installationKey == nil || installationKey?.bitCount == 256 else { throw VortxNativeError.invalidSnapshot }
        if let bootstrap {
            guard let bootstrapScope else { throw VortxNativeError.invalidSnapshot }
            try bootstrapScope.validate(); try VortxNativeBootstrapArchive.validate(bootstrap)
            bootstraps[bootstrapScope] = bootstrap
        }
        if let ownerHistoryAccountBase {
            guard let bootstrapScope else { throw VortxNativeError.invalidSnapshot }
            _ = try OwnerHistoryAccountExport(completeAccountPlaintext: ownerHistoryAccountBase)
            accountBases[bootstrapScope] = ownerHistoryAccountBase
        }
        self.directory = directory; self.key = key; self.installationKey = installationKey
        migrationDraftDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func url(_ scope: VortxAccountScope) -> URL {
        let digest = SHA256.hash(data: scope.authenticatedData).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("native-state-v1-\(digest).sealed")
    }
    private func migrationDraftURL(_ scope: VortxAccountScope) -> URL {
        let digest = SHA256.hash(data: scope.authenticatedData).map { String(format: "%02x", $0) }.joined()
        return migrationDraftDirectory.appendingPathComponent("native-migration-draft-v1-\(digest).sealed")
    }
    private func migrationDraftAAD(_ scope: VortxAccountScope) -> Data {
        Data("vortx-native-migration-draft-v1\u{0}".utf8) + scope.authenticatedData
    }
    /// A draft cannot mount an account, pin an owner, or certify an import. It only retains exact
    /// authenticated recovery evidence before the first complete kernel checkpoint exists.
    func readMigrationDraft(scope: VortxAccountScope) throws -> Data? {
        guard let archive = try readMigrationDraftBytes(scope: scope) else { return nil }
        try VortxNativeWatchedArchive.validate(archive, scope: scope)
        return archive
    }
    /// File/decrypt work is synchronous under the file lock; strict replay is outside it.
    /// Ordinary readers replay strictly before returning. The receipt reader authenticates
    /// immutable bytes here; its cold worker then replays them before any eligibility use.
    private func readMigrationDraftBytes(scope: VortxAccountScope) throws -> Data? {
        try Self.migrationDraftLock.withLock { try readMigrationDraftBytesLocked(scope: scope) }
    }
    private func readMigrationDraftBytesLocked(scope: VortxAccountScope) throws -> Data? {
        try scope.validate()
        let bytes: Data
        do { bytes = try Data(contentsOf: migrationDraftURL(scope)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        let archive = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: migrationDraftAAD(scope))
        return archive
    }
    /// Cold-worker entry only: authenticate the raw snapshot and capture its generation
    /// together under the existing file lock. The worker performs strict replay afterward.
    func captureMigrationDraft(scope: VortxAccountScope) throws -> VortxMigrationDraftRead {
        try scope.validate()
        let identity = migrationDraftIdentity(scope)
        return try Self.migrationDraftLock.withLock {
            let archive = try readMigrationDraftBytesLocked(scope: scope)
            let generation = Self.migrationDraftGenerationLocked(identity)
            // Retaining this exact store instance also retains its original encryption key;
            // neither the key nor a caller-supplied new scope can be substituted at readback.
            return VortxMigrationDraftRead(archive: archive) { [self] operation in
                try withMigrationDraftGeneration(identity, generation: generation, operation)
            }
        }
    }
    private func withMigrationDraftGeneration(_ identity: Data, generation: UUID,
        _ operation: () throws -> Void) throws {
        try Self.migrationDraftLock.withLock {
            guard Self.migrationDraftGenerations[identity] == generation else { throw VortxNativeError.superseded }
            try Task.checkCancellation()
            try operation()
        }
    }
    /// One domain per canonical file URL + authenticated scope, shared by all store/probe
    /// instances. Key identity belongs to the retained store; different-key writes to the
    /// same file still retire every reader, and a wrong-key existing read throws at AES open.
    private func migrationDraftIdentity(_ scope: VortxAccountScope) -> Data {
        Data(migrationDraftURL(scope).path.utf8)
            + Data([0]) + scope.authenticatedData
    }
    private static func migrationDraftGenerationLocked(_ identity: Data) -> UUID {
        if let current = migrationDraftGenerations[identity] { return current }
        // Eviction fails old reads closed; it never reinstates a receipt. Bounded process state.
        if migrationDraftGenerations.count >= 128 { migrationDraftGenerations.removeAll() }
        let generation = UUID(); migrationDraftGenerations[identity] = generation
        return generation
    }

    func readMigrationDraftCooperatively(scope: VortxAccountScope,
        isCurrent: @escaping @Sendable () -> Bool,
        checkpoint: (@Sendable () async throws -> Void)? = nil) async throws -> Data? {
        try Task.checkCancellation()
        guard isCurrent() else { throw VortxNativeError.superseded }
        guard let archive = try readMigrationDraftBytes(scope: scope) else {
            try Task.checkCancellation()
            guard isCurrent() else { throw VortxNativeError.superseded }
            return nil
        }
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: scope, isCurrent: isCurrent, checkpoint: checkpoint)
        try await worker.validate(archive)
        return archive
    }
    func retainMigrationDraft(_ archive: Data, scope: VortxAccountScope, expected: Data? = nil, authority: any VortxMutationAuthority) throws {
        try scope.validate(); try VortxNativeWatchedArchive.validate(archive, scope: scope)
        try installValidatedMigrationDraft(archive, scope: scope, expected: expected, authority: authority)
    }
    func retainValidatedMigrationDraft(_ draft: VortxNativeWatchedArchive.ValidatedDraft,
        scope: VortxAccountScope, expected: Data?, authority: any VortxMutationAuthority) throws {
        try installValidatedMigrationDraft(draft.bytes(for: scope), scope: scope, expected: expected, authority: authority)
    }
    func retainMigrationDraftCooperatively(_ archive: Data, scope: VortxAccountScope, expected: Data? = nil,
        authority: any VortxMutationAuthority, checkpoint: (@Sendable () async throws -> Void)? = nil) async throws {
        try scope.validate()
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: scope,
            isCurrent: { (try? authority.withActive {}) != nil }, checkpoint: checkpoint)
        try await worker.validate(archive)
        try installValidatedMigrationDraft(archive, scope: scope, expected: expected, authority: authority)
    }
    /// Only fully validated immutable bytes reach this private sink. Validation never carries
    /// a file lock or publication lease over suspension; CAS and durable readback stay atomic.
    private func installValidatedMigrationDraft(_ archive: Data, scope: VortxAccountScope,
        expected: Data?, authority: any VortxMutationAuthority) throws {
        guard archive.count <= 48 * 1_024 * 1_024 else { throw VortxNativeError.invalidSnapshot }
        // All three writer entries, including the SyncManager probe, converge here.
        // Source precedes draft lock, compatible with lease -> source/FIFO -> draft reads.
        try authority.withActive {
            try Self.migrationDraftLock.withLock {
                try Task.checkCancellation()
                let current = try readMigrationDraftBytesLocked(scope: scope)
                guard current == expected else { throw VortxNativeError.superseded }
                let identity = migrationDraftIdentity(scope)
                _ = Self.migrationDraftGenerationLocked(identity)
                // Retire BEFORE the first possible write. Same bytes and ambiguous durable
                // outcomes never revive an old read (including A -> B -> A).
                Self.migrationDraftGenerations[identity] = UUID()
                try FileManager.default.createDirectory(at: migrationDraftDirectory, withIntermediateDirectories: true)
                let sealed = try AES.GCM.seal(archive, using: key, authenticating: migrationDraftAAD(scope))
                guard let bytes = sealed.combined else { throw VortxNativeError.invalidSnapshot }
                try durableInstall(bytes, at: migrationDraftURL(scope))
            }
        }
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
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        func isStaging(_ name: String) -> Bool {
            name.hasSuffix(".sealed") && [".native-checkpoint-", ".native-locator-", ".native-index-"].contains(where: name.hasPrefix)
        }
        // A durable stage may belong to an account whose final file/index was never published.
        // Ignore unrelated files, but never turn recognized interrupted transaction state into absence.
        guard !files.contains(where: { isStaging($0.lastPathComponent) }) else { throw VortxNativeError.invalidSnapshot }
        guard let installationKey else {
            guard !files.contains(where: { file in
                ["native-state-v1-", "native-account-v1-", "native-account-v2-"].contains(where: file.lastPathComponent.hasPrefix)
            }) else { throw VortxNativeError.invalidSnapshot }
            return []
        }
        var covered: Set<String> = []
        var authenticatedIndexes: Set<String> = []
        for file in files where file.lastPathComponent.hasPrefix("native-account-v2-") {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: installationKey,
                                         authenticating: indexAAD(file.lastPathComponent))
            let locator = try JSONDecoder().decode(AccountLocator.self, from: plain)
            try locator.scope.validate()
            guard locator.format == "vortx-native-account-locator-v2", indexURL(locator.scope.account).path == file.path else { throw VortxNativeError.invalidSnapshot }
            guard locator.scope.account != requestedScope.account || locator.scope == requestedScope else { throw VortxNativeError.invalidSnapshot }
            let accountLocator = try Data(contentsOf: locatorURL(locator.scope.account))
            guard locator.accountLocatorDigest == Data(SHA256.hash(data: accountLocator)) else { throw VortxNativeError.invalidSnapshot }
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
        try lock.withLock { try rememberAuthenticatedScopeLocked(scope, ownerHistoryRead: nil) }
    }
    /// Called only after the Session's full typed open, against its same original ciphertext.
    func rememberAuthenticatedOwnerHistoryScope(_ scope: VortxAccountScope, expected: OwnerHistoryRead) throws {
        try lock.withLock {
            try requireCurrentOwnerHistoryLocked(expected, scope: scope)
            try rememberAuthenticatedScopeLocked(scope, ownerHistoryRead: expected)
        }
    }
    private func rememberAuthenticatedScopeLocked(_ scope: VortxAccountScope, ownerHistoryRead: OwnerHistoryRead?) throws {
        try scope.validate()
        do {
            let prior = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: locatorURL(scope.account))),
                                         using: key, authenticating: locatorAAD(scope.account))
            let pinned = try JSONDecoder().decode(AccountLocator.self, from: prior)
            guard pinned.format == "vortx-native-account-locator-v1", pinned.scope == scope else { throw VortxNativeError.invalidSnapshot }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {}
        if let expected = ownerHistoryRead {
            guard expected.format == "vortx-native-owner-history-checkpoint-v1",
                  expected.bootstrap != nil, expected.ownerHistoryAccountBase != nil,
                  expected.preservedOwnerUID?.isEmpty == false else { throw VortxNativeError.invalidSnapshot }
        } else {
            let existing = try open(Data(contentsOf: url(scope)), scope: scope)
            guard existing.bootstrap != nil else { throw VortxNativeError.invalidSnapshot }
        }
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
            let existingBytes = try Data(contentsOf: url(scope))
            let ciphertext = try accountCiphertext(existingBytes)
            if ownerHistoryRead != nil {
                // Locator publication must not change this coordinator's ORIGINAL ciphertext
                // CAS. Typed commits already create a current-installation proof atomically.
                guard existingBytes.starts(with: Self.indexedPrefix) else { throw VortxNativeError.invalidSnapshot }
                let indexed = try JSONDecoder().decode(IndexedCiphertext.self,
                    from: existingBytes.dropFirst(Self.indexedPrefix.count))
                let proof = try JSONDecoder().decode(InventoryProof.self, from:
                    AES.GCM.open(AES.GCM.SealedBox(combined: indexed.proof), using: installationKey,
                        authenticating: indexAAD(url(scope).lastPathComponent)))
                guard proof.scope == scope, proof.ciphertextDigest == Data(SHA256.hash(data: ciphertext)) else {
                    throw VortxNativeError.invalidSnapshot
                }
            } else { try durableInstall(indexedCiphertext(ciphertext, scope: scope), at: url(scope)) }
            let indexPayload = try JSONEncoder().encode(AccountLocator(format: "vortx-native-account-locator-v2", scope: scope,
                                                                       accountLocatorDigest: Data(SHA256.hash(data: bytes))))
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
        let stateBytes = try Data(contentsOf: url(locator.scope))
        let envelope = try open(stateBytes, scope: locator.scope)
        guard let bootstrap = envelope.bootstrap else { throw VortxNativeError.invalidSnapshot }
        bootstraps[locator.scope] = bootstrap
        remember(stateBytes, envelope, scope: locator.scope)
        return Recovery(scope: locator.scope, state: envelope.state, bootstrap: bootstrap)
    }
    struct OwnerHistoryRecovery: Sendable {
        let scope: VortxAccountScope
        let checkpoint: OwnerHistoryRead
        let bootstrap: Data
    }
    /// Authenticate the original locator, then return one original raw envelope/CAS. Generic
    /// recovery remains unchanged and does not become a schema6/typed-format reader.
    func ownerHistoryRecovery(account: String) throws -> OwnerHistoryRecovery? {
        let scope: VortxAccountScope? = try lock.withLock {
            let bytes: Data
            do { bytes = try Data(contentsOf: locatorURL(account)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError { return nil }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes),
                using: key, authenticating: locatorAAD(account))
            let locator = try JSONDecoder().decode(AccountLocator.self, from: plain)
            guard locator.format == "vortx-native-account-locator-v1",
                  locator.scope.account == account else { throw VortxNativeError.invalidSnapshot }
            try locator.scope.validate()
            return locator.scope
        }
        guard let scope, let checkpoint = try readOwnerHistory(scope: scope) else { return nil }
        guard checkpoint.format == "vortx-native-owner-history-checkpoint-v1" else { return nil }
        guard let bootstrap = checkpoint.bootstrap, checkpoint.ownerHistoryAccountBase != nil,
              let uid = checkpoint.preservedOwnerUID, !uid.isEmpty,
              !uid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VortxNativeError.invalidSnapshot
        }
        return OwnerHistoryRecovery(scope: scope, checkpoint: checkpoint, bootstrap: bootstrap)
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
            let bytes = try Data(contentsOf: url(scope))
            let envelope = try open(bytes, scope: scope)
            if let retained = envelope.bootstrap { bootstraps[scope] = retained }
            remember(bytes, envelope, scope: scope)
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
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? {
        lock.lock(); defer { lock.unlock() }
        let bootstrap: Data?
        do { bootstrap = try open(Data(contentsOf: url(scope)), scope: scope).bootstrap }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { bootstrap = bootstraps[scope] }
        guard let bootstrap else { return nil }
        return try JSONDecoder().decode(VortxJSON.self, from: bootstrap)["hostDocument"]?["profileEdits"]
    }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try VortxNativeHostPreferences.validateSealed(hostPreferences, scope: scope)
        try commitSnapshot(snapshot, scope: scope, hostPreferences: hostPreferences)
    }
    private func remember(_ bytes: Data, _ envelope: Envelope, scope: VortxAccountScope) {
        installed[scope] = Installed(format: envelope.format, accountBase: envelope.ownerHistoryAccountBase, digest: SHA256.hash(data: bytes), state: envelope.state,
                                     bootstrap: envelope.bootstrap, hostPreferences: envelope.hostPreferences,
                                     ownerHistoryLocal: envelope.ownerHistoryLocal)
    }
    private func commitSnapshot(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        var stage = VortxCheckpointDiagnostics.Stage.validate
        do {
            try scope.validate(); _ = try scope.validateSnapshot(snapshot)
            var retainedHost = hostPreferences
            var retainedOwnerHistory: Data?
            var retainedAccountBase = accountBases[scope]
            stage = .retainExisting
            var existing: Data?
            do { existing = try Data(contentsOf: url(scope)) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {}
            if let existing {
                if let known = installed[scope], known.digest == SHA256.hash(data: existing) {
                    guard known.format == "vortx-native-checkpoint-v1" else { throw VortxNativeError.unavailable }
                    // The exact bytes this store last wrote or fully opened: carry their parts forward.
                    if let bootstrap = known.bootstrap { bootstraps[scope] = bootstrap }
                    if retainedHost == nil { retainedHost = known.hostPreferences }
                    retainedOwnerHistory = known.ownerHistoryLocal
                    if retainedAccountBase == nil { retainedAccountBase = known.accountBase }
                    // An obsolete generic runtime must never overwrite a schema6 checkpoint.
                    // Even with a cached encrypted read, the dedicated coordinator owns it.
                    if known.ownerHistoryLocal != nil,
                       try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(Data(known.state.utf8)).required("nativeSync")).required("schemaVersion") == Data("6".utf8) {
                        throw VortxNativeError.unavailable
                    }
                    // Nothing would change on disk, so there is nothing to write.
                    if known.state == snapshot, known.hostPreferences == retainedHost, known.bootstrap == bootstraps[scope], known.accountBase == retainedAccountBase { return }
                } else {
                    // The first migration source is immutable, even for a fresh store instance making a
                    // later commit. A decode/read failure must not replace it with a newer/empty carrier.
                    let retained = try open(existing, scope: scope)
                    if let bootstrap = retained.bootstrap { bootstraps[scope] = bootstrap }
                    if retainedHost == nil { retainedHost = retained.hostPreferences }
                    retainedOwnerHistory = retained.ownerHistoryLocal
                    if retainedAccountBase == nil { retainedAccountBase = retained.ownerHistoryAccountBase }
                }
            }
            let bootstrap = bootstraps[scope]
            if let base = retainedAccountBase {
                let raw = try OwnerHistoryAccountExport(completeAccountPlaintext: base)
                let state = try scope.validateSnapshot(snapshot)
                guard let native = state["nativeSync"], let retainedHost else { throw VortxNativeError.invalidSnapshot }
                let host = try OwnerHistoryAccountExport.hostProjection(retainedHost, scope: scope)
                retainedAccountBase = try raw.replacingOwned([
                    "nativeSync": JSONEncoder().encode(native), "nativeHostPreferences": host.document,
                    "profileEditResults": host.profileEditResults
                ]).encoded()
            }
            let envelope = Envelope(format: "vortx-native-checkpoint-v1", state: snapshot, bootstrap: bootstrap,
                hostPreferences: retainedHost, ownerHistoryLocal: retainedOwnerHistory,
                ownerHistoryAccountBase: retainedAccountBase)
            stage = .seal
            let sealed = try AES.GCM.seal(JSONEncoder().encode(envelope), using: key, authenticating: scope.authenticatedData)
            guard let combined = sealed.combined else { throw VortxNativeError.invalidSnapshot }
            let bytes = try indexedCiphertext(combined, scope: scope)
            stage = .createDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent(".native-checkpoint-\(UUID().uuidString).sealed")
            defer { try? FileManager.default.removeItem(at: staged) }
            stage = .stageWrite
            try bytes.write(to: staged, options: [.withoutOverwriting, .completeFileProtection])
            stage = .stageSync
            let file = try FileHandle(forWritingTo: staged); defer { try? file.close() }
            try file.synchronize()
            // The sealed bytes come from parts validated above, so decoding them again proves nothing new.
            // Byte equality proves the disk holds exactly what was sealed (as durableInstall checks).
            stage = .stageReadback
            guard try Data(contentsOf: staged) == bytes else { throw VortxNativeError.invalidSnapshot }
            stage = .install
            guard Darwin.rename(staged.path, url(scope).path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            stage = .directorySync
            let directoryFD = Darwin.open(directory.path, O_RDONLY)
            guard directoryFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { Darwin.close(directoryFD) }
            guard Darwin.fsync(directoryFD) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            stage = .installedReadback
            guard try Data(contentsOf: url(scope)) == bytes else { throw VortxNativeError.invalidSnapshot }
            installed[scope] = Installed(format: "vortx-native-checkpoint-v1", accountBase: retainedAccountBase, digest: SHA256.hash(data: bytes), state: snapshot, bootstrap: bootstrap,
                                         hostPreferences: retainedHost, ownerHistoryLocal: retainedOwnerHistory)
        } catch {
            // The file is uncertain now: the next commit opens it in full.
            installed[scope] = nil
            VortxCheckpointDiagnostics.report(stage: stage, error: error)
            throw error
        }
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
        // A failed native close is not retirement. Retain its handle and original lease
        // for this process lifetime; no replacement writer or automatic reopen is allowed.
        var unconfirmedRetirements: [String: VortxNativeRuntime] = [:]
        var ownerHistoryQuarantined: Set<String> = []
        var ownerHistoryHandles: [String: OwnerHistorySessionCoordinator] = [:]
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
    func retainUnconfirmedRetirement(_ runtime: VortxNativeRuntime) {
        lock.lock(); defer { lock.unlock() }
        precondition(!released)
        Self.registry.lock.withLock {
            if let retained = Self.registry.unconfirmedRetirements[scope.account] {
                precondition(retained === runtime)
            } else {
                Self.registry.unconfirmedRetirements[scope.account] = runtime
            }
        }
    }
    /// A typed constructor can retain its failed native runtime privately before throwing.
    /// Keep the ORIGINAL account reservation even when no coordinator value was returned.
    func quarantineOwnerHistoryRetirement(_ coordinator: OwnerHistorySessionCoordinator? = nil) {
        lock.withLock {
            precondition(!released)
            Self.registry.lock.withLock {
                Self.registry.ownerHistoryQuarantined.insert(scope.account)
                if let coordinator { Self.registry.ownerHistoryHandles[scope.account] = coordinator }
            }
        }
    }
    func release() {
        lock.lock(); defer { lock.unlock() }; guard !released else { return }
        released = Self.registry.lock.withLock {
            guard Self.registry.unconfirmedRetirements[scope.account] == nil,
                  !Self.registry.ownerHistoryQuarantined.contains(scope.account) else { return false }
            Self.registry.leases.removeValue(forKey: scope.account)
            return true
        }
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
/// Privacy-safe outline of a held legacy delta, for diagnostics: which material buckets changed for
/// which profile slot (owner, p1, p2…), entry counts, and the schema field names that differ.
/// Never titles, names, identifiers or values, so a device log can say what was held.
enum VortxLegacyDeltaSummary {
    private static let perProfile = ["addons", "libraries", "watches", "identityLinks", "ownAccountSources"]
    /// Same row identity the kernel reconciles on (watch: videoId, else metaId).
    private static let identityKeys = ["videoId", "metaId", "_id", "id", "key", "transportUrl"]
    private static let maxLength = 600

    static func describe(base: VortxJSON, next: VortxJSON, ownerProfileID: String) -> String {
        var parts: [String] = []
        if let before = number(base["rosterModifiedSeconds"]), let after = number(next["rosterModifiedSeconds"]), before != after {
            parts.append("rosterClock=" + (after < before ? "older" : "newer"))
        }
        if let change = diff(base["roster"], next["roster"]) { parts.append("roster(\(change))") }
        if let change = diff(base["deletedProfileIds"], next["deletedProfileIds"]) { parts.append("deletedProfiles(\(change))") }
        let slots = slotLabels(base: base, next: next, owner: ownerProfileID)
        for field in perProfile {
            let lhs = object(base[field]), rhs = object(next[field])
            for id in Set(lhs.keys).union(rhs.keys).sorted(by: { (slots[$0] ?? "px") < (slots[$1] ?? "px") }) {
                let slot = slots[id] ?? "px"
                if isObject(lhs[id]) || isObject(rhs[id]) {
                    let before = object(lhs[id]), after = object(rhs[id])
                    for sub in Set(before.keys).union(after.keys).sorted() {
                        if let change = diff(before[sub], after[sub]) { parts.append("\(field).\(sub):\(slot)(\(change))") }
                    }
                } else if let change = diff(lhs[id], rhs[id]) {
                    parts.append("\(field):\(slot)(\(change))")
                }
            }
        }
        let text = parts.isEmpty ? "none" : parts.joined(separator: ",")
        return text.count <= maxLength ? text : String(text.prefix(maxLength)) + "..."
    }

    /// `+added/-removed/~changed:fields`, `reordered`, or `~` for a changed scalar/object.
    private static func diff(_ lhs: VortxJSON?, _ rhs: VortxJSON?) -> String? {
        guard lhs != rhs else { return nil }
        guard isArrayOrAbsent(lhs), isArrayOrAbsent(rhs) else { return "~" }
        let before = keyed(lhs?.array ?? []), after = keyed(rhs?.array ?? [])
        let added = after.keys.filter { before[$0] == nil }.count
        let removed = before.keys.filter { after[$0] == nil }.count
        var changed = 0, fields = Set<String>()
        for (key, row) in after {
            guard let old = before[key], old != row else { continue }
            changed += 1
            let oldFields = object(old), newFields = object(row)
            fields.formUnion(Set(oldFields.keys).union(newFields.keys).filter { oldFields[$0] != newFields[$0] })
        }
        var out: [String] = []
        if added > 0 { out.append("+\(added)") }
        if removed > 0 { out.append("-\(removed)") }
        if changed > 0 { out.append("~\(changed)" + (fields.isEmpty ? "" : ":" + fields.sorted().prefix(6).joined(separator: "|"))) }
        return out.isEmpty ? "reordered" : out.joined(separator: "/")
    }
    private static func keyed(_ rows: [VortxJSON]) -> [String: VortxJSON] {
        var result: [String: VortxJSON] = [:]
        for row in rows { result[identity(row)] = row }
        return result
    }
    private static func identity(_ row: VortxJSON) -> String {
        for key in identityKeys { if case .string(let id)? = row[key] { return key + ":" + id } }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(row)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }
    private static func slotLabels(base: VortxJSON, next: VortxJSON, owner: String) -> [String: String] {
        var labels = [owner: "owner"], index = 0
        for row in (base["roster"]?.array ?? []) + (next["roster"]?.array ?? []) {
            guard case .string(let id)? = row["id"], labels[id] == nil else { continue }
            index += 1
            labels[id] = "p\(index)"
        }
        return labels
    }
    private static func object(_ value: VortxJSON?) -> [String: VortxJSON] {
        if case .object(let fields)? = value { return fields }
        return [:]
    }
    private static func isObject(_ value: VortxJSON?) -> Bool {
        if case .object? = value { return true }
        return false
    }
    private static func isArrayOrAbsent(_ value: VortxJSON?) -> Bool {
        switch value {
        case nil, .null?, .array?: return true
        default: return false
        }
    }
    private static func number(_ value: VortxJSON?) -> Double? {
        switch value {
        case .integer(let v)?: return Double(v)
        case .unsigned(let v)?: return Double(v)
        case .number(let v)?: return v
        default: return nil
        }
    }
}

actor VortxNativeSession {
    enum CatalogScreen: String, Sendable { case board, discover, search }
    /// Installed by the real opener, never synthesized from a later account capture.
    /// Unconfigured synthetic/generic sessions keep nil and cannot select the typed owner.
    typealias OwnerHistoryLocalCheckpointPreparation = @Sendable
        (Data, VortxAccountScope, any VortxMutationAuthority) async throws -> OwnerHistoryPreparedExport
    let scope: VortxAccountScope
    private let abi: any VortxRuntimeABI
    private let store: any VortxCheckpointStore
    private let transport: any VortxResourceTransport
    private let ownerHistoryLocalCheckpointPreparation: OwnerHistoryLocalCheckpointPreparation?
    // Quarantined before transfer retirement; no generic route may reuse it afterward.
    private var runtime: VortxNativeRuntime!
    private var genericRetirementUnconfirmed = false
    private var ownerHistory: OwnerHistorySessionCoordinator?
    // Actor-owned throughout warm validation; never sent from a local region into
    // actor state while a later authority closure still borrows that local region.
    private var ownerHistoryTransferCandidate: OwnerHistorySessionCoordinator?
    // Retained selector provenance only. Ordinary native edits/peer receive are authorized
    // by authenticated account + original Session/source/FIFO/CAS, not a device Stremio login.
    // NEW streaming-source imports still use the genuine credential-bound producer below.
    private var ownerHistoryReadOnly = false
    private var ownerHistoryRetirementPending = false
    private let ownerHistoryIdentity = UUID()
    private var hostPreferences: VortxNativeHostPreferences
    private let externalCWGeneration = VortxNativeExternalCW.Generation()
    private let legacyBaseline: Data?
    private let legacyProfileEdits: VortxJSON?
    /// Outcome of the latest legacy carrier offer (first adoption or dispatch); nil before one.
    private(set) var legacyReconciliation: LegacyReconciliation?
    /// Host diagnostics sink. Only outcome transitions are reported, never material bytes.
    private let diagnostics: (@Sendable (String) -> Void)?
    private var closed = false
    private var persistenceFailed = false
    // Playback position ticks are applied in memory at once but written to the sealed checkpoint at most
    // every 30 s. Every other mutation writes immediately and carries the latest position with it, and
    // flushPendingProgress writes a held-back position on pause, player close, background or quit. A crash
    // can lose at most the last 30 s of watch position, never anything else.
    private var pendingProgressCommit = false
    private var lastDurableCommit: TimeInterval?
    private var writeProgressUntil: TimeInterval = 0
    static let progressCommitInterval: TimeInterval = 30
    private static func isProgressAction(_ action: String) -> Bool {
        (try? JSONDecoder().decode(VortxJSON.self, from: Data(action.utf8)))?["type"] == .string("report_progress")
    }
    private var epoch = UUID()
    private var tickets: [String: UUID] = [:]
    private var bridges: [String: VortxResourceBridge] = [:]
    private var resourceBatchBridges: [String: [VortxResourceBridge]] = [:]
    private var catalogPlans: [String: VortxJSON] = [:]
    private var pages: [String: [VortxResourceSnapshot]] = [:]
    private var screens: [String: VortxNativeScreenState] = [:]
    private var catalogRegistries: [String: [VortxResourceAddon]] = [:]
    private nonisolated let lease = VortxSessionLease()
    private let writer: VortxScopeWriter

    /// Supplied only by the authenticated raw cloud admission. Its owner UID is a
    /// presentation selector; readOnly stays true until genuine account credentials exist.
    struct OwnerHistoryColdPeer: Sendable {
        let target: OwnerHistorySessionCoordinator.Target
        let preservedOwnerUID: String
        let nativeDocument: Data
        let localArchive: Data
        let hostPreferences: Data
        let bootstrap: Data
        let transaction: OwnerHistoryPreparedExport
        let readOnly: Bool
    }

    init(scope: VortxAccountScope, ownerName: String, abi: any VortxRuntimeABI,
         store: any VortxCheckpointStore, transport: any VortxResourceTransport,
         allowNewAccount: Bool = false, legacy: VortxLegacyImport? = nil,
         initialActions: [String] = [], hostActor: String = UUID().uuidString.lowercased(),
         sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil,
         initialLegacyMaterial: Data? = nil, diagnostics: (@Sendable (String) -> Void)? = nil,
         ownerHistoryColdTarget: OwnerHistorySessionCoordinator.Target? = nil,
         ownerHistoryColdCheckpoint: VortxEncryptedCheckpointStore.OwnerHistoryRead? = nil,
         ownerHistoryReadOnly: Bool = false,
         ownerHistoryColdPeer: OwnerHistoryColdPeer? = nil,
         ownerHistoryLocalCheckpointPreparation: OwnerHistoryLocalCheckpointPreparation? = nil) throws {
        try scope.validate()
        self.diagnostics = diagnostics
        guard legacy == nil || legacy?.scope == scope else { throw VortxNativeError.invalidSnapshot }
        self.scope = scope; self.abi = abi; self.store = store; self.transport = transport
        self.ownerHistoryLocalCheckpointPreparation = ownerHistoryLocalCheckpointPreparation
        if let input = ownerHistoryColdPeer {
            guard Self.ownerHistoryRoutingEnabled, ownerHistoryLocalCheckpointPreparation != nil, ownerHistoryColdCheckpoint == nil,
                  let encrypted = store as? VortxEncryptedCheckpointStore, let sourceAuthority,
                  initialActions.isEmpty, initialLegacyMaterial == nil, authenticatedSourceArchive == nil,
                  legacy == nil, !allowNewAccount else { throw VortxNativeError.unavailable }
            let bootstrap = try JSONDecoder().decode(VortxJSON.self, from: input.bootstrap)
            legacyBaseline = try bootstrap["legacyImportMaterial"].map { try JSONEncoder().encode($0) }
            legacyProfileEdits = bootstrap["hostDocument"]?["profileEdits"]
            hostPreferences = try VortxNativeHostPreferences(scope: scope, actor: hostActor, sealed: input.hostPreferences)
            // Reserve the existing account-wide sole-writer slot BEFORE replay/install/open.
            writer = try VortxScopeWriter(scope: scope, lease: lease)
            runtime = nil
            self.ownerHistoryReadOnly = input.readOnly
            do {
                let absence = try encrypted.captureOwnerHistoryAbsence(scope: scope)
                let candidate = try OwnerHistorySessionCoordinator.prepareColdPeer(scope: scope,
                    target: input.target, nativeDocument: input.nativeDocument, localArchive: input.localArchive,
                    hostPreferences: input.hostPreferences, preservedOwnerUID: input.preservedOwnerUID,
                    transaction: input.transaction, canonicalABI: abi, sessionABI: OwnerHistorySessionCABI(),
                    sourceAuthority: sourceAuthority)
                // Keep the synchronous installation closure independent of the partly
                // initialized actor; ownership is assigned only after this exact CAS.
                let coldLease = lease
                var checkpoint: VortxEncryptedCheckpointStore.OwnerHistoryRead?
                try input.transaction.withActive {
                    try coldLease.withActive { try sourceAuthority.withActive {
                        checkpoint = try encrypted.installColdOwnerHistory(candidate, bootstrap: input.bootstrap,
                            expected: absence, scope: scope)
                    } }
                }
                guard let checkpoint else { throw VortxNativeError.checkpointUncertain }
                ownerHistory = try OwnerHistorySessionCoordinator(scope: scope, target: input.target, store: encrypted,
                    abi: OwnerHistorySessionCABI(), canonicalABI: abi, sourceAuthority: sourceAuthority,
                    originalRead: checkpoint, initialOwnerReadUID: checkpoint.preservedOwnerUID)
                try sourceAuthority.withActive {
                    try encrypted.requireCurrentOwnerHistory(checkpoint, scope: scope)
                    try encrypted.rememberAuthenticatedOwnerHistoryScope(scope, expected: checkpoint)
                }
            } catch {
                let typedRetired = ownerHistory?.close() ?? true
                if !typedRetired || (error as? VortxNativeError) == .checkpointUncertain {
                    writer.quarantineOwnerHistoryRetirement(ownerHistory)
                    lease.revoke()
                    throw VortxNativeError.checkpointUncertain
                }
                lease.revoke()
                throw error
            }
            return
        }
        if let checkpoint = ownerHistoryColdCheckpoint {
            guard Self.ownerHistoryRoutingEnabled, ownerHistoryLocalCheckpointPreparation != nil,
                  let encrypted = store as? VortxEncryptedCheckpointStore,
                  checkpoint.format == "vortx-native-owner-history-checkpoint-v1",
                  let target = ownerHistoryColdTarget, let sourceAuthority,
                  let host = checkpoint.hostPreferences, checkpoint.ownerHistoryAccountBase != nil,
                  initialActions.isEmpty, initialLegacyMaterial == nil,
                  authenticatedSourceArchive == nil, legacy == nil, !allowNewAccount else {
                throw VortxNativeError.unavailable
            }
            if ownerHistoryReadOnly {
                let root = try OwnerHistoryExactJSON.Object(checkpoint.snapshot)
                let profiles = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(root.required("roster")).required("profiles"))
                let profile = try OwnerHistoryExactJSON.Object(profiles.required(target.profileID.uuidString))
                let native = try OwnerHistoryExactJSON.Object(root.required("nativeSync"))
                let activeBinding = try native["accountSlots"].flatMap {
                    try OwnerHistoryExactJSON.Object($0)[target.profileID.uuidString].flatMap {
                        try OwnerHistoryExactJSON.Object($0)["activeBinding"]
                    }
                }
                let accountBytes: Data
                if let activeBinding { accountBytes = try OwnerHistoryExactJSON.Object(activeBinding).required("account") }
                else { accountBytes = try profile.required("account") }
                let binding = try OwnerHistoryExactJSON.Object(accountBytes)
                let retainedUID: String?
                if try binding.text("kind") == "own" { retainedUID = try binding.text("value") }
                else { retainedUID = checkpoint.preservedOwnerUID }
                guard retainedUID.map({ OwnerHistoryExactJSON.sameText($0, target.verifiedUID) }) == true else {
                    throw VortxNativeError.superseded
                }
            }
            try sourceAuthority.withActive { try encrypted.requireCurrentOwnerHistory(checkpoint, scope: scope) }
            let bootstrap = try checkpoint.bootstrap.map { try JSONDecoder().decode(VortxJSON.self, from: $0) }
            legacyBaseline = try bootstrap?["legacyImportMaterial"].map { try JSONEncoder().encode($0) }
            legacyProfileEdits = bootstrap?["hostDocument"]?["profileEdits"]
            hostPreferences = try VortxNativeHostPreferences(scope: scope, actor: hostActor, sealed: host)
            writer = try VortxScopeWriter(scope: scope, lease: lease)
            runtime = nil
            self.ownerHistoryReadOnly = ownerHistoryReadOnly
            do {
                ownerHistory = try OwnerHistorySessionCoordinator(scope: scope, target: target, store: encrypted,
                    abi: OwnerHistorySessionCABI(), canonicalABI: abi, sourceAuthority: sourceAuthority,
                    originalRead: checkpoint)
                try sourceAuthority.withActive {
                    try encrypted.requireCurrentOwnerHistory(checkpoint, scope: scope)
                    try encrypted.rememberAuthenticatedOwnerHistoryScope(scope, expected: checkpoint)
                }
            } catch {
                let typedRetired = ownerHistory?.close() ?? true
                if !typedRetired || (error as? VortxNativeError) == .checkpointUncertain {
                    writer.quarantineOwnerHistoryRetirement(ownerHistory)
                    lease.revoke()
                    throw VortxNativeError.checkpointUncertain
                }
                lease.revoke()
                throw error
            }
            return
        }
        legacyBaseline = try store.readLegacyMaterial(scope: scope)
        legacyProfileEdits = try store.readLegacyProfileEdits(scope: scope)
        hostPreferences = try VortxNativeHostPreferences(scope: scope, actor: hostActor, sealed: store.readHostPreferences(scope: scope))
        try hostPreferences.retainAuthenticatedSourceArchive(authenticatedSourceArchive)
        let initialHost = try hostPreferences.encoded()
        writer = try VortxScopeWriter(scope: scope, lease: lease)
        if let captured = try store.read(scope: scope) {
            _ = try scope.validateSnapshot(captured)
            runtime = try VortxNativeRuntime(abi: abi, snapshot: captured)
            // Hydration may migrate projections. Commit that full state before publishing it.
            let hydrated = try runtime.stateJSON()
            try scope.validateHydration(from: captured, to: hydrated)
            try Self.bind(runtime, scope: scope)
            let bound = try runtime.stateJSON()
            try Self.validateAuthenticatedSources(authenticatedSourceArchive, state: scope.validateSnapshot(bound))
            try lease.withActive {
                func commit() throws {
                    if authenticatedSourceArchive != nil { try store.commit(bound, scope: scope, hostPreferences: initialHost) }
                    else { try store.commit(bound, scope: scope) }
                }
                if let sourceAuthority { try sourceAuthority.withActive(commit) } else { try commit() }
            }
        } else {
            guard allowNewAccount, legacy?.documents.isEmpty != false else { throw VortxNativeError.invalidSnapshot }
            runtime = try VortxNativeRuntime(abi: abi, ownerID: scope.ownerProfileID, ownerName: ownerName)
            try Self.bind(runtime, scope: scope)
            for action in initialActions { try Self.apply(runtime, action: action) }
            if let initialLegacyMaterial {
                let outcome = try Self.validateLegacyReceipt(runtime, scope: scope, material: initialLegacyMaterial, baselineMaterial: legacyBaseline, abi: abi)
                legacyReconciliation = outcome
                if case .held(let reason, let delta) = outcome {
                    diagnostics?("legacy_reconcile result=held stage=adoption reason=\(reason) delta=\(delta)")
                }
            }
            let bound = try runtime.stateJSON()
            _ = try scope.validateSnapshot(bound)
            try Self.validateAuthenticatedSources(authenticatedSourceArchive, state: scope.validateSnapshot(bound))
            try lease.withActive {
                func commit() throws {
                    if authenticatedSourceArchive != nil { try store.commit(bound, scope: scope, hostPreferences: initialHost) }
                    else { try store.commit(bound, scope: scope) }
                }
                if let sourceAuthority { try sourceAuthority.withActive(commit) } else { try commit() }
            }
        }
    }

    // MARK: - Explicit owner-history owner (activation remains disabled)
    enum OwnerHistoryRoutingFailure: Error, Equatable {
        case activationDisabled, alreadyActivated, pendingProgress, requiresEncryptedStore
        case unsupportedGenericRoute, notActivated, wrongSession, checkpointMismatch
    }
    /// This flag is not added to any build configuration by this proposal. It is independent
    /// from the SDK symbol flag; compiling an SDK alone does not activate host routing.
    nonisolated static var ownerHistoryRoutingEnabled: Bool {
        true
    }
    private final class OwnerHistorySourceAuthority: VortxMutationAuthority, @unchecked Sendable {
        let lease: VortxSessionLease
        let read: VortxNativeFIFOAdmission.ReadCapability
        init(lease: VortxSessionLease, read: VortxNativeFIFOAdmission.ReadCapability) {
            self.lease = lease; self.read = read
        }
        func withActive(_ operation: () throws -> Void) throws {
            // Same order as ordinary commits: whole-account witness -> Session lease ->
            // ORIGINAL credential/publication source -> ORIGINAL own FIFO member -> store.
            try lease.withActive { try read.withActive(operation) }
        }
    }
    struct OwnerHistoryCapture: Sendable {
        fileprivate let sessionID: UUID
        fileprivate let native: OwnerHistorySessionCoordinator.Capture
        fileprivate let read: VortxNativeFIFOAdmission.ReadCapability
        fileprivate init(sessionID: UUID, native: OwnerHistorySessionCoordinator.Capture,
                         read: VortxNativeFIFOAdmission.ReadCapability) {
            self.sessionID = sessionID; self.native = native; self.read = read
        }
        /// The returned bound value cannot be paired with a fresh read capability by a caller.
        /// Transport/metadata closures must be the existing actual producer dependencies.
        func prepare(source: VortxNativeOwnerHistorySource.Capture, authKey: String,
                     verify: VortxNativeOwnerHistorySource.Verify,
                     send: VortxNativeOwnerHistorySource.Send,
                     fetchMetadata: LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher) async throws -> OwnerHistoryBoundOutcome {
            let outcome = try await native.prepare(source: source, authKey: authKey,
                verify: verify, send: send, fetchMetadata: fetchMetadata)
            return .init(capture: self, native: outcome)
        }
    }
    struct OwnerHistoryBoundOutcome: Sendable {
        fileprivate let capture: OwnerHistoryCapture
        fileprivate let native: OwnerHistorySessionCoordinator.BoundOutcome
        fileprivate init(capture: OwnerHistoryCapture, native: OwnerHistorySessionCoordinator.BoundOutcome) {
            self.capture = capture; self.native = native
        }
        var isPending: Bool { native.isPending }
    }
    struct OwnerHistoryCommit: Sendable {
        let receipt: Data?
        let publication: OwnerHistorySessionPublication
        fileprivate init(receipt: Data?, publication: OwnerHistorySessionPublication) {
            self.receipt = receipt; self.publication = publication
        }
    }

    /// Session-created pairing of one acknowledged raw envelope and its ORIGINAL FIFO read.
    /// The exact encrypted base is retained privately for warm-transfer CAS, including an
    /// external same-plaintext ciphertext replacement. Public bytes are not write authority.
    struct OwnerHistoryAcknowledgedRead: Sendable {
        let source: VortxNativeOwnerHistorySource.Capture
        let originalRead: VortxNativeFIFOAdmission.ReadCapability
        fileprivate let sessionID: UUID
        fileprivate let stored: VortxEncryptedCheckpointStore.OwnerHistoryRead
        let hostPreferencesData: Data
        let readOwnerUID: String
        var snapshotData: Data { stored.snapshot }
        var accountBase: Data? { stored.ownerHistoryAccountBase }
        var ownerHistoryLocalData: Data? { stored.ownerHistoryLocal }

        fileprivate init(source: VortxNativeOwnerHistorySource.Capture,
            read: VortxNativeFIFOAdmission.ReadCapability, sessionID: UUID,
            stored: VortxEncryptedCheckpointStore.OwnerHistoryRead, hostPreferences: Data, readOwnerUID: String) {
            self.source = source; originalRead = read; self.sessionID = sessionID
            self.stored = stored; hostPreferencesData = hostPreferences; self.readOwnerUID = readOwnerUID
        }
    }

    /// Read-only. No await, flush, mutation, checkpoint write, replacement runtime, or new
    /// source admission. The original read must already have been captured by the Facade.
    /// Provider preparation receives this bundle, never independently assembled DTO fields.
    func captureOwnerHistoryAcknowledgedRead(target: OwnerHistorySessionCoordinator.Target,
        read: VortxNativeFIFOAdmission.ReadCapability) throws -> OwnerHistoryAcknowledgedRead {
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed, !ownerHistoryRetirementPending else {
            throw VortxNativeError.checkpointUncertain
        }
        // A held position is not acknowledged disk state. Its normal FIFO flush must settle
        // first; this reader must not flush it under a different/captured authority.
        guard !pendingProgressCommit else { throw OwnerHistoryRoutingFailure.pendingProgress }
        guard let encrypted = store as? VortxEncryptedCheckpointStore else {
            throw OwnerHistoryRoutingFailure.requiresEncryptedStore
        }
        let authority = OwnerHistorySourceAuthority(lease: lease, read: read)
        try authority.withActive {}
        let expectedSnapshot: Data
        let expectedHost: Data
        let expectedLocal: Data?
        let compareLocal: Bool
        if let ownerHistory {
            let captured = try ownerHistory.capture(target: target,
                sourceAuthority: authority, queueAuthority: read.queueAuthority)
            let checkpoint = try ownerHistory.checkpoint(capture: captured)
            expectedSnapshot = checkpoint.snapshot; expectedHost = checkpoint.hostPreferences
            // A warm coordinator may synthesize an empty in-memory journal before its first
            // write. Compare the ACTUAL installed optional sidecar, never nil to that encoding.
            expectedLocal = try ownerHistory.acknowledgedLocalSource(capture: captured)
            compareLocal = true
        } else {
            // Ordinary mode still uses its real current runtime, only as a raw read. Its
            // generic state/host DTO publication is not used as a persistence carrier here.
            expectedSnapshot = try lease.withActive { Data(try runtime.stateJSON().utf8) }
            expectedHost = try lease.withActive { try hostPreferences.encoded() }
            expectedLocal = nil; compareLocal = false
        }
        // One authenticated envelope read gives all parts plus one exact ciphertext CAS.
        guard let stored = try encrypted.readOwnerHistory(scope: scope),
              let storedHost = stored.hostPreferences else { throw VortxNativeError.unavailable }
        let source = try VortxNativeOwnerHistorySource.Capture(scope: scope,
            profileID: target.profileID, verifiedUID: target.verifiedUID, snapshotData: stored.snapshot)
        let readOwnerUID: String
        if let retained = stored.preservedOwnerUID, !retained.isEmpty { readOwnerUID = retained }
        else if let selected = try VortxNativeAccountCredentials.selectedOwnerIdentity(scope: scope.account,
            ownerProfileID: source.ownerProfileID, read: { key in
                switch Keychain.confirmedString(key) {
                case .value(let value): return value
                case .missing: return nil
                case .failure: throw VortxNativeError.unavailable
                }
            }) { readOwnerUID = selected.verifiedUID }
        else if source.profileID == source.ownerProfileID { readOwnerUID = source.verifiedUID }
        else { throw VortxNativeError.unavailable } // Never use own-secondary UID as owner UID.
        let bundle = OwnerHistoryAcknowledgedRead(source: source, read: read,
            sessionID: ownerHistoryIdentity, stored: stored, hostPreferences: storedHost, readOwnerUID: readOwnerUID)
        try authority.withActive {
            try requireOwnerHistoryAcknowledgedReadWithoutAuthority(bundle, read: read)
            guard !pendingProgressCommit,
                  try OwnerHistoryExactJSON.canonical(stored.snapshot)
                    == OwnerHistoryExactJSON.canonical(expectedSnapshot),
                  try OwnerHistoryExactJSON.canonical(storedHost)
                    == OwnerHistoryExactJSON.canonical(expectedHost),
                  !compareLocal || stored.ownerHistoryLocal == expectedLocal else {
                throw OwnerHistoryRoutingFailure.checkpointMismatch
            }
        }
        return bundle
    }

    /// Caller already holds the original whole-account -> lease -> source/FIFO authorities.
    /// Do not reacquire any of them here, and do not use this old CAS after a legitimate write.
    /// Warm transfer performs no write, so both its pre- and post-free checks must use this
    /// SAME base rather than accepting a newly read/rebound ciphertext.
    private func requireOwnerHistoryAcknowledgedReadWithoutAuthority(
        _ acknowledged: OwnerHistoryAcknowledgedRead,
        read: VortxNativeFIFOAdmission.ReadCapability) throws {
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        guard acknowledged.sessionID == ownerHistoryIdentity,
              acknowledged.originalRead === read,
              acknowledged.source.scope == scope.account,
              acknowledged.source.ownerProfileID.uuidString == scope.ownerProfileID,
              let encrypted = store as? VortxEncryptedCheckpointStore else {
            throw VortxNativeError.superseded
        }
        try encrypted.requireCurrentOwnerHistory(acknowledged.stored, scope: scope)
    }

    /// Warm transfer only. No await, no generic action, no schema admission change, no
    /// normalization checkpoint. Failure before quarantine leaves the existing owner intact.
    /// After quarantine there is no fallback: close must succeed outside authority locks,
    /// and the SAME authorities must still admit publication after synchronous free returns.
    /// Facade must call this from the admitted read's running FIFO task and publish the
    /// returned raw receipt before finishing that task. No call site is enabled here.
    func activateOwnerHistory(target: OwnerHistorySessionCoordinator.Target,
        preparation: OwnerHistoryAccountPreparation) throws -> OwnerHistorySessionPublication {
        let acknowledged = preparation.originalAcknowledgedRead
        guard acknowledged.sessionID == ownerHistoryIdentity,
              acknowledged.source.profileID == target.profileID,
              OwnerHistoryExactJSON.sameText(acknowledged.source.verifiedUID, target.verifiedUID) else {
            throw VortxNativeError.superseded
        }
        let bundle = OwnerHistoryCheckpointRead(scope: scope, read: acknowledged.originalRead,
            sessionID: acknowledged.sessionID, stored: acknowledged.stored)
        return try transferOwnerHistory(target: target, acknowledged: bundle,
            ownerReadUID: acknowledged.readOwnerUID,
            transaction: preparation.transaction(for: acknowledged.originalRead))
    }

    /// Ownership metadata only: the SAME writer/read/ciphertext before and after free().
    /// Neither a source import nor a peer intermediate state is published here.
    private func transferOwnerHistory(target: OwnerHistorySessionCoordinator.Target,
        acknowledged: OwnerHistoryCheckpointRead, ownerReadUID: String,
        transaction: OwnerHistoryPreparedExport,
        additionalSource: (any VortxMutationAuthority)? = nil) throws -> OwnerHistorySessionPublication {
        let read = acknowledged.originalRead
        guard Self.ownerHistoryRoutingEnabled else { throw OwnerHistoryRoutingFailure.activationDisabled }
        guard ownerHistoryLocalCheckpointPreparation != nil else { throw VortxNativeError.unavailable }
        try requireActiveRoute()
        guard ownerHistory == nil, ownerHistoryTransferCandidate == nil else {
            throw OwnerHistoryRoutingFailure.alreadyActivated
        }
        guard !pendingProgressCommit else { throw OwnerHistoryRoutingFailure.pendingProgress }
        guard let encrypted = store as? VortxEncryptedCheckpointStore else {
            throw OwnerHistoryRoutingFailure.requiresEncryptedStore
        }
        try Task.checkCancellation()
        try read.runningAuthority.withActive {}
        let source = OwnerHistoryOrdinarySource(lease: lease, source: read, member: read.queueAuthority,
            peerSource: additionalSource)
        try source.withActive { try requireOwnerHistoryCheckpointWithoutAuthority(acknowledged) }
        let original = Data(try runtime.stateJSON().utf8)
        guard try OwnerHistoryExactJSON.Object(original).text("activeProfileId") == target.profileID.uuidString else {
            throw VortxNativeError.superseded
        }
        let originalHost = try hostPreferences.encoded()
        do {
            ownerHistoryTransferCandidate = try OwnerHistorySessionCoordinator(scope: scope, target: target, store: encrypted,
                abi: OwnerHistorySessionCABI(), canonicalABI: abi, sourceAuthority: source,
                originalRead: acknowledged.stored, initialOwnerReadUID: ownerReadUID)
        } catch {
            if (error as? VortxNativeError) == .checkpointUncertain {
                writer.quarantineOwnerHistoryRetirement()
                close()
            }
            throw error
        }
        defer { ownerHistoryTransferCandidate = nil }
        guard let next = ownerHistoryTransferCandidate else { throw VortxNativeError.unavailable }
        var transferred = false
        do {
            let capture = try next.capture(target: target, sourceAuthority: source, queueAuthority: read.queueAuthority)
            let checkpoint = try next.checkpoint(capture: capture)
            guard try OwnerHistoryExactJSON.canonical(checkpoint.snapshot) == OwnerHistoryExactJSON.canonical(original),
                  try OwnerHistoryExactJSON.canonical(checkpoint.snapshot) == OwnerHistoryExactJSON.canonical(acknowledged.snapshotData),
                  try OwnerHistoryExactJSON.canonical(checkpoint.hostPreferences) == OwnerHistoryExactJSON.canonical(originalHost) else {
                throw OwnerHistoryRoutingFailure.checkpointMismatch
            }
            let publication = OwnerHistorySessionPublication(checkpoint: checkpoint, source: source)
            try transaction.withActive {
                try next.withCurrentCheckpoint(capture: capture) {
                    try Task.checkCancellation()
                    try transaction.validateCompleteAccount(checkpoint)
                    try requireOwnerHistoryCheckpointWithoutAuthority(acknowledged)
                    ownerHistoryRetirementPending = true
                    ownerHistory = ownerHistoryTransferCandidate
                    transferred = true
                }
            }
            // free() may synchronously re-enter revoke; never run it under original source,
            // whole-account, FIFO or store locks, and never resurrect the generic runtime.
            guard retireGenericRuntime() else { throw VortxNativeError.checkpointUncertain }
            try transaction.withActive {
                try next.withCurrentCheckpoint(capture: capture) {
                    try Task.checkCancellation()
                    try transaction.validateCompleteAccount(checkpoint)
                    try requireOwnerHistoryCheckpointWithoutAuthority(acknowledged)
                    ownerHistoryRetirementPending = false
                }
            }
            invalidateScreens()
            return publication
        } catch {
            if transferred { close() }
            else if !next.close() {
                writer.quarantineOwnerHistoryRetirement(next)
                persistenceFailed = true
                lease.revoke()
                throw VortxNativeError.checkpointUncertain
            }
            throw error
        }
    }
    private func requireOwnerHistory() throws -> OwnerHistorySessionCoordinator {
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed, !ownerHistoryRetirementPending else { throw VortxNativeError.checkpointUncertain }
        try lease.withActive {}
        guard let ownerHistory else { throw OwnerHistoryRoutingFailure.notActivated }
        return ownerHistory
    }
    func usesOwnerHistory() -> Bool { ownerHistory != nil }
    /// Ownership and health are separate after an irreversible generic-to-typed transfer.
    /// Inspect only actor-owned state: task cancellation is not session corruption.
    func ownerHistoryRouteStatus() -> (ownsHistory: Bool, requiresAuthenticatedReopen: Bool) {
        (ownerHistory != nil,
         closed || persistenceFailed || ownerHistoryRetirementPending || genericRetirementUnconfirmed
            || ownerHistory?.requiresAuthenticatedReopen == true)
    }
    func captureOwnerHistory(target: OwnerHistorySessionCoordinator.Target,
        read: VortxNativeFIFOAdmission.ReadCapability) throws -> OwnerHistoryCapture {
        let owner = try requireOwnerHistory()
        let authenticated = try currentOwnerHistoryTarget(profileID: target.profileID, requireCredential: true)
        guard OwnerHistoryExactJSON.sameText(authenticated.verifiedUID, target.verifiedUID) else {
            throw VortxNativeError.superseded
        }
        let source = OwnerHistorySourceAuthority(lease: lease, read: read)
        let captured = try owner.capture(target: target, sourceAuthority: source, queueAuthority: read.queueAuthority)
        return .init(sessionID: ownerHistoryIdentity, native: captured, read: read)
    }
    private func requireOwnerHistoryCapture(_ capture: OwnerHistoryCapture) throws {
        guard capture.sessionID == ownerHistoryIdentity else { throw OwnerHistoryRoutingFailure.wrongSession }
        try capture.native.withReadAuthority {}
    }
    func ownerHistoryPublication(capture: OwnerHistoryCapture) throws -> OwnerHistorySessionPublication {
        let owner = try requireOwnerHistory()
        try requireOwnerHistoryCapture(capture)
        return .init(checkpoint: try owner.checkpoint(capture: capture.native),
            source: OwnerHistorySourceAuthority(lease: lease, read: capture.read))
    }
    func ownerHistoryPresentation(capture: OwnerHistoryCapture) throws -> OwnerHistorySessionPublication.Presentation {
        let owner = try requireOwnerHistory()
        try requireOwnerHistoryCapture(capture)
        return try .init(view: owner.read(kind: "view", capture: capture.native), expectedFence: capture.native.fence)
    }
    /// No ordinary/current-clock action is accepted by this typed source-import entry point.
    /// Pending retention is not a source-import ACK: its receipt is explicitly nil.
    func applyOwnerHistory(_ bound: OwnerHistoryBoundOutcome,
        transaction: OwnerHistoryPreparedExport) throws -> OwnerHistoryCommit {
        let owner = try requireOwnerHistory()
        try requireOwnerHistoryCapture(bound.capture)
        try bound.capture.read.runningAuthority.withActive {}
        do {
            if bound.native.isPending {
                let checkpoint = try owner.retainPending(bound.native, transaction: transaction)
                return .init(receipt: nil, publication: .init(checkpoint: checkpoint,
                    source: OwnerHistorySourceAuthority(lease: lease, read: bound.capture.read)))
            }
            let imported = try owner.importPrepared(bound.native, transaction: transaction)
            return .init(receipt: imported.receipt, publication: .init(checkpoint: imported.checkpoint,
                source: OwnerHistorySourceAuthority(lease: lease, read: bound.capture.read)))
        } catch VortxNativeError.checkpointUncertain {
            persistenceFailed = true
            invalidateScreens()
            throw VortxNativeError.checkpointUncertain
        }
    }

    /// Generic raw checkpoint read, distinct from owner/shared-only import admission.
    /// Constructible only by this Session from one original ciphertext read.
    struct OwnerHistoryCheckpointRead: Sendable {
        let scope: VortxAccountScope
        let originalRead: VortxNativeFIFOAdmission.ReadCapability
        fileprivate let sessionID: UUID
        fileprivate let stored: VortxEncryptedCheckpointStore.OwnerHistoryRead
        var snapshotData: Data { stored.snapshot }
        var hostPreferencesData: Data { get throws {
            guard let host = stored.hostPreferences else { throw VortxNativeError.invalidSnapshot }; return host
        } }
        var ownerHistoryLocalData: Data? { stored.ownerHistoryLocal }
        var accountBase: Data { get throws {
            guard let base = stored.ownerHistoryAccountBase else { throw VortxNativeError.unavailable }; return base
        } }
        fileprivate init(scope: VortxAccountScope, read: VortxNativeFIFOAdmission.ReadCapability,
                         sessionID: UUID, stored: VortxEncryptedCheckpointStore.OwnerHistoryRead) {
            self.scope = scope; originalRead = read; self.sessionID = sessionID; self.stored = stored
        }
    }
    func captureOwnerHistoryCheckpointRead(read: VortxNativeFIFOAdmission.ReadCapability) throws -> OwnerHistoryCheckpointRead {
        try requireActiveRoute()
        guard !pendingProgressCommit, let encrypted = store as? VortxEncryptedCheckpointStore else {
            throw VortxNativeError.unavailable
        }
        let source = OwnerHistorySourceAuthority(lease: lease, read: read)
        let expectedSnapshot: Data
        let expectedHost: Data
        let expectedLocal: Data?
        let expectedBase: Data?
        let compareTyped: Bool
        if let ownerHistory {
            let capture = try ownerHistory.capture(target: currentOwnerHistoryTarget(requireCredential: false),
                sourceAuthority: source, queueAuthority: read.queueAuthority)
            let expected = try ownerHistory.checkpoint(capture: capture)
            expectedSnapshot = expected.snapshot; expectedHost = expected.hostPreferences
            expectedLocal = try ownerHistory.acknowledgedLocalSource(capture: capture)
            expectedBase = expected.accountBase; compareTyped = true
        } else {
            // Role-neutral original generic read. No owner-only Source.Capture, hydration,
            // bind, mutation, clock action or checkpoint write is introduced.
            expectedSnapshot = try lease.withActive { Data(try runtime.stateJSON().utf8) }
            expectedHost = try lease.withActive { try hostPreferences.encoded() }
            expectedLocal = nil; expectedBase = nil; compareTyped = false
        }
        guard let stored = try encrypted.readOwnerHistory(scope: scope), let host = stored.hostPreferences else {
            throw VortxNativeError.unavailable
        }
        let bundle = OwnerHistoryCheckpointRead(scope: scope, read: read,
            sessionID: ownerHistoryIdentity, stored: stored)
        try source.withActive {
            try requireOwnerHistoryCheckpointWithoutAuthority(bundle)
            guard try OwnerHistoryExactJSON.canonical(stored.snapshot) == OwnerHistoryExactJSON.canonical(expectedSnapshot),
                  try OwnerHistoryExactJSON.canonical(host) == OwnerHistoryExactJSON.canonical(expectedHost),
                  !compareTyped || (stored.ownerHistoryAccountBase == expectedBase && stored.ownerHistoryLocal == expectedLocal) else {
                throw VortxNativeError.superseded
            }
        }
        return bundle
    }
    private func requireOwnerHistoryCheckpointWithoutAuthority(_ bundle: OwnerHistoryCheckpointRead) throws {
        guard bundle.sessionID == ownerHistoryIdentity, bundle.scope == scope,
              let encrypted = store as? VortxEncryptedCheckpointStore else { throw VortxNativeError.superseded }
        try encrypted.requireCurrentOwnerHistory(bundle.stored, scope: scope)
    }
    func mergeOwnerHistoryPeer(_ preparation: OwnerHistoryPeerPreparation,
        hostEdits: [VortxNativeHostPreferences.Edit] = []) async throws -> OwnerHistorySessionPublication {
        let bundle = preparation.acknowledged, read = bundle.originalRead
        try read.runningAuthority.withActive {}
        let source = OwnerHistorySourceAuthority(lease: lease, read: read)
        try source.withActive { try requireOwnerHistoryCheckpointWithoutAuthority(bundle) }
        let warming = ownerHistory == nil
        if warming {
            guard let carrier = preparation.transaction.completeAccount.raw(OwnerHistoryAccountExport.archiveKey) else {
                throw VortxNativeError.invalidSnapshot
            }
            let ownerUID = try OwnerHistoryAccountExport.readOwnerUID(from: carrier, scope: scope)
            let root = try OwnerHistoryExactJSON.Object(bundle.snapshotData)
            guard let profile = try UUID(uuidString: root.text("activeProfileId")) else { throw VortxNativeError.invalidSnapshot }
            let profiles = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(root.required("roster")).required("profiles"))
            let record = try OwnerHistoryExactJSON.Object(profiles.required(profile.uuidString))
            let native = try OwnerHistoryExactJSON.Object(root.required("nativeSync"))
            let active = try native["accountSlots"].flatMap {
                try OwnerHistoryExactJSON.Object($0)[profile.uuidString].flatMap {
                    try OwnerHistoryExactJSON.Object($0)["activeBinding"]
                }
            }
            let accountBytes: Data
            if let active { accountBytes = try OwnerHistoryExactJSON.Object(active).required("account") }
            else { accountBytes = try record.required("account") }
            let binding = try OwnerHistoryExactJSON.Object(accountBytes)
            let uid = try binding.text("kind") == "own" ? binding.text("value") : ownerUID
            _ = try transferOwnerHistory(target: .init(profileID: profile, verifiedUID: uid),
                acknowledged: bundle, ownerReadUID: ownerUID, transaction: preparation.transaction,
                additionalSource: preparation.sourceAuthority)
        }
        do {
            let owner = try requireOwnerHistory()
            _ = try owner.capture(target: currentOwnerHistoryTarget(requireCredential: false),
                sourceAuthority: source, queueAuthority: read.queueAuthority)
            let remote: VortxJSON?
            if let rawHost = preparation.hostPreferencesData {
                let value = try JSONDecoder().decode(VortxJSON.self, from: rawHost)
                guard try OwnerHistoryExactJSON.canonical(rawHost) ==
                    OwnerHistoryExactJSON.canonical(VortxNativeHostFieldEvidence.canonicalData(value)) else {
                    throw VortxNativeError.invalidSnapshot
                }
                remote = value
            } else { remote = nil }
            _ = try await dispatch([], now: UInt64(Date().timeIntervalSince1970),
                legacyMaterial: preparation.legacyMaterial, hostRemote: remote, hostEdits: hostEdits,
                legacyWatchlists: preparation.legacyWatchlists,
                websiteEvents: preparation.websiteEvents, websiteAddonEvents: preparation.websiteAddonEvents,
                websiteBaseline: preparation.websiteBaseline, sourceAuthority: read,
                authenticatedSourceArchive: preparation.authenticatedSourceArchive,
                fifoAuthority: read.queueAuthority, typedPeer: preparation)
            // Fresh AFTER OUR OWN durable ACK, still under this same running original member.
            // Never recheck the old encrypted CAS after that legitimate commit.
            let current = try owner.capture(target: currentOwnerHistoryTarget(requireCredential: false),
                sourceAuthority: source, queueAuthority: read.queueAuthority)
            return .init(checkpoint: try owner.checkpoint(capture: current), source: source)
        } catch {
            // A failed peer after irreversible warm free has no generic resurrection or
            // intermediate ACK. Preserve its old sealed envelope and require real reopen.
            if warming { close() }
            throw error
        }
    }
    func ownerHistoryCompleteAccount(read: VortxNativeFIFOAdmission.ReadCapability, writeV2: Bool) throws -> Data {
        let bundle = try captureOwnerHistoryCheckpointRead(read: read)
        let base = try OwnerHistoryAccountExport(completeAccountPlaintext: bundle.accountBase)
        let bytes = try base.cloudPlaintext(writeV2: writeV2)
        try OwnerHistorySourceAuthority(lease: lease, read: read).withActive {
            try requireOwnerHistoryCheckpointWithoutAuthority(bundle)
        }
        return bytes
    }

    /// Same original prefetch read -> its own admitted FIFO member -> actual typed import.
    /// A pending archive is retained durably but never reported as an imported source.
    func applyOwnerHistoryLogin(_ prepared: OwnerHistoryLoginPreparation) throws -> OwnerHistoryCommit {
        let acknowledged = prepared.acknowledged
        let read = acknowledged.originalRead
        guard prepared.account.originalAcknowledgedRead.originalRead === read else {
            throw VortxNativeError.superseded
        }
        try read.runningAuthority.withActive {}
        let source = OwnerHistorySourceAuthority(lease: lease, read: read)
        try source.withActive {
            try requireOwnerHistoryAcknowledgedReadWithoutAuthority(acknowledged, read: read)
        }
        let target = OwnerHistorySessionCoordinator.Target(profileID: acknowledged.source.profileID,
            verifiedUID: acknowledged.source.verifiedUID)
        if ownerHistory == nil { _ = try activateOwnerHistory(target: target, preparation: prepared.account) }
        let owner = try requireOwnerHistory()
        let captured = try owner.capture(target: target, sourceAuthority: source, queueAuthority: read.queueAuthority)
        let bound = try owner.bind(prepared.outcome, source: acknowledged.source, capture: captured)
        let transaction = try prepared.account.transaction(for: read)
        do {
            if bound.isPending {
                let checkpoint = try owner.retainPending(bound, transaction: transaction)
                ownerHistoryReadOnly = false // Records genuine provider verification; pending is not an import ACK.
                return .init(receipt: nil, publication: .init(checkpoint: checkpoint, source: source))
            }
            let imported = try owner.importPrepared(bound, transaction: transaction)
            ownerHistoryReadOnly = false // Records this genuine credential-bound provider/source ACK.
            return .init(receipt: imported.receipt,
                publication: .init(checkpoint: imported.checkpoint, source: source))
        } catch VortxNativeError.checkpointUncertain {
            persistenceFailed = true; invalidateScreens()
            throw VortxNativeError.checkpointUncertain
        }
    }

    /// Mechanical ownership adapter for the unchanged host/website edit policy below.
    /// Both cases invoke their real native runtime; only the typed case can retain raw sources.
    private enum NativeCandidate {
        case generic(VortxNativeRuntime)
        case owner(OwnerHistorySessionCoordinator.Candidate)
        func stateJSON() throws -> String {
            switch self { case .generic(let value): return try value.stateJSON(); case .owner(let value): return try value.stateJSON() }
        }
        func state(scope: VortxAccountScope) throws -> VortxJSON {
            switch self {
            case .generic(let value): return try scope.validateSnapshot(value.stateJSON())
            case .owner(let value): return try JSONDecoder().decode(VortxJSON.self, from: Data(value.stateJSON().utf8))
            }
        }
        func dispatch(_ action: String, now: UInt64) throws -> String {
            switch self {
            case .generic(let value): return try value.dispatch(action, now: now)
            case .owner(let value): return try value.dispatch(action, now: now)
            }
        }
        func resolve(_ query: String) throws -> String {
            switch self { case .generic(let value): return try value.resolve(query); case .owner(let value): return try value.resolve(query) }
        }
        func copy(abi: any VortxRuntimeABI) throws -> Self {
            switch self {
            case .generic(let value): return .generic(try VortxNativeRuntime(abi: abi, snapshot: value.stateJSON()))
            case .owner(let value): return .owner(try value.copy())
            }
        }
        @discardableResult func close() -> Bool {
            switch self { case .generic(let value): return value.close(); case .owner(let value): return value.close() }
        }
    }
    private struct OwnerHistoryLeaseAuthority: VortxMutationAuthority {
        let lease: VortxSessionLease
        func withActive(_ operation: () throws -> Void) throws { try lease.withActive(operation) }
    }
    private struct OwnerHistoryAdditionalCheckpointAuthority: OwnerHistoryCompleteCheckpointAuthority {
        let raw: OwnerHistoryPreparedExport
        let additional: any VortxProspectiveCheckpointValidator
        func withActive(_ operation: () throws -> Void) throws {
            try additional.withActive { try raw.withActive(operation) }
        }
        func validateCompleteAccount(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws {
            try raw.validateCompleteAccount(checkpoint)
            // Legacy UI validator is an ADDITIONAL original witness only. Its partial DTO
            // cannot replace the exact raw complete-account budget above or enter persistence.
            let original = try OwnerHistoryExactJSON.Object(checkpoint.nativeSync)
            var visible = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
            for key in ["schemaVersion", "scope", "ownerProfileId", "profiles", "addons", "libraries", "watches",
                        "legacyImport", "accountSlots", "websiteAddonReceipts", "legacyProfileEditReceipts"] {
                if let value = original[key] { visible.set(key, value) }
            }
            try additional.validate(native: JSONDecoder().decode(VortxJSON.self, from: visible.encoded()),
                host: JSONDecoder().decode(VortxJSON.self, from: checkpoint.nativeHostPreferences),
                profileEditResults: JSONDecoder().decode(VortxJSON.self, from: checkpoint.profileEditResults))
        }
        func completeAccount(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws -> Data {
            try raw.completeAccount(checkpoint)
        }
    }
    private struct OwnerHistoryOrdinarySource: VortxMutationAuthority {
        let lease: VortxSessionLease
        let source: (any VortxMutationAuthority)?
        let member: any VortxMutationAuthority
        var peerSource: (any VortxMutationAuthority)? = nil
        func withActive(_ operation: () throws -> Void) throws {
            try lease.withActive {
                func original() throws {
                    if let source { try source.withActive { try member.withActive(operation) } }
                    else { try member.withActive(operation) }
                }
                if let peerSource { try peerSource.withActive(original) } else { try original() }
            }
        }
    }
    private func requireActiveRoute() throws {
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed, !ownerHistoryRetirementPending else { throw VortxNativeError.checkpointUncertain }
        try lease.withActive {}
    }
    /// Trusted native presentation copy ONLY; no caller may back-persist this DTO.
    private func presentationState() throws -> VortxJSON {
        if let ownerHistory {
            try requireActiveRoute()
            return try JSONDecoder().decode(VortxJSON.self, from: ownerHistory.presentationSnapshot())
        }
        return try scope.validateSnapshot(stateJSON())
    }
    private func currentOwnerHistoryTarget(profileID: UUID? = nil, requireCredential: Bool) throws
        -> OwnerHistorySessionCoordinator.Target {
        let owner = try requireOwnerHistory()
        let root = try OwnerHistoryExactJSON.Object(owner.acknowledgedSnapshot())
        let id: UUID?
        if let profileID { id = profileID }
        else { id = try UUID(uuidString: root.text("activeProfileId")) }
        guard let id, let ownerID = UUID(uuidString: scope.ownerProfileID) else { throw VortxNativeError.invalidSnapshot }
        let profiles = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(root.required("roster")).required("profiles"))
        let profile = try OwnerHistoryExactJSON.Object(profiles.required(id.uuidString))
        let native = try OwnerHistoryExactJSON.Object(root.required("nativeSync"))
        let activeBinding = try native["accountSlots"].flatMap {
            try OwnerHistoryExactJSON.Object($0)[id.uuidString].flatMap {
                try OwnerHistoryExactJSON.Object($0)["activeBinding"]
            }
        }
        let accountBytes: Data
        if let activeBinding { accountBytes = try OwnerHistoryExactJSON.Object(activeBinding).required("account") }
        else { accountBytes = try profile.required("account") }
        let account = try OwnerHistoryExactJSON.Object(accountBytes)
        if try account.text("kind") == "own" {
            let uid = try account.text("value")
            if requireCredential {
                let state = try presentationState()
                let binding = try VortxNativeProfiles.expectedBinding(state: state, profileID: id)
                guard let slot = try VortxNativeAccountCredentials.selectedSlot(scope: scope.account,
                    profileID: id, binding: binding.document),
                    case .value(let token) = Keychain.confirmedString(slot), !token.isEmpty else { throw VortxNativeError.unavailable }
            }
            return .init(profileID: id, verifiedUID: uid)
        }
        if let selection = try VortxNativeAccountCredentials.selectedOwnerIdentity(scope: scope.account,
            ownerProfileID: ownerID, read: { key in
                switch Keychain.confirmedString(key) {
                case .value(let value): return value
                case .missing: return nil
                case .failure: throw VortxNativeError.unavailable
                }
            }) {
            return .init(profileID: id, verifiedUID: selection.verifiedUID)
        }
        guard !requireCredential else { throw VortxNativeError.unavailable }
        // Originally authenticated UID from this encrypted checkpoint supports local read-only
        // preservation while disconnected. It never grants a new import or mutation authority.
        return .init(profileID: id, verifiedUID: owner.preservedReadUID)
    }
    private func ownerHistoryResolve(_ request: VortxJSON, target: OwnerHistorySessionCoordinator.Target? = nil) throws -> String {
        let owner = try requireOwnerHistory()
        let capture = try owner.capture(target: target ?? currentOwnerHistoryTarget(requireCredential: false),
            sourceAuthority: OwnerHistoryLeaseAuthority(lease: lease), queueAuthority: OwnerHistoryLeaseAuthority(lease: lease))
        let reply = try OwnerHistoryExactJSON.Object(owner.read(kind: "resolve", capture: capture,
            extra: ["request": JSONEncoder().encode(request)]))
        guard try reply.text("kind") == "resolved" else { throw VortxNativeError.invalidResponse }
        return String(decoding: try reply.required("result"), as: UTF8.self)
    }

    private static func bind(_ runtime: VortxNativeRuntime, scope: VortxAccountScope) throws {
        let action = VortxJSON.object(["type": .string("bind_sync_scope"), "scope": .string(scope.account)])
        try apply(runtime, action: String(decoding: JSONEncoder().encode(action), as: UTF8.self))
        let bound = try scope.validateSnapshot(runtime.stateJSON())
        guard bound["nativeSync"]?["scope"] == .string(scope.account) else { throw VortxNativeError.invalidSnapshot }
    }
    private static func validateAuthenticatedSources(_ archive: Data?, state: VortxJSON) throws {
        guard let archive else { return }
        try VortxNativeBootstrapArchive.validate(archive)
        guard case .string(let account) = state["nativeSync"]?["scope"],
              case .string(let owner) = state["nativeSync"]?["ownerProfileId"] else { throw VortxNativeError.invalidSnapshot }
        try VortxNativeWatchedArchive.validate(archive, scope: .init(account: account, ownerProfileID: owner))
        let decoded = try JSONDecoder().decode(VortxJSON.self, from: archive)
        _ = try VortxNativeUnattributedOverlayArchive.merge(nil,
            decoded["hostDocument"]?[VortxNativeUnattributedOverlayArchive.key],
            scope: .init(account: account, ownerProfileID: owner), state: state)
        guard case .object(let sources) = decoded["hostDocument"]?["ownAccountSources"] else { throw VortxNativeError.invalidSnapshot }
        for (id, value) in sources {
            guard case .object(let fields) = value, Set(fields.keys) == ["verifiedStreamingUid", "sourceDocumentBase64"],
                  case .string(let raw) = fields["sourceDocumentBase64"], let bytes = Data(base64Encoded: raw), bytes.base64EncodedString() == raw else { throw VortxNativeError.invalidSnapshot }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let legacy = state["nativeSync"]?["legacyImport"]
            let proof = legacy?["baseline"]?["ownAccountSources"]?[id]
            var paired = proof?["verifiedStreamingUid"] == fields["verifiedStreamingUid"] &&
                (proof?["sourceDocumentSha256"] == .string(digest) || legacy?["ownAccountSourceHistory"]?[id]?[digest] != nil)
            if let slots = state["nativeSync"]?["accountSlots"]?[id],
               case .object(let retained) = slots["slots"] {
                let matches = retained.values.filter { $0["account"] == slots["activeBinding"]?["account"] }
                guard matches.count == 1 else { throw VortxNativeError.invalidSnapshot }
                if matches[0]["sourceBaseline"]?["source"]?["verifiedStreamingUid"] == value["verifiedStreamingUid"] {
                    paired = paired || matches[0]["sourceBaseline"]?["source"]?["sourceDocumentSha256"] == .string(digest)
                        || matches[0]["sourceHistory"]?[digest] != nil
                }
            }
            guard paired else { throw VortxNativeError.invalidSnapshot }
        }
        if let pending = decoded["hostDocument"]?["ownAccountOverlayPending"] {
            guard case .object(let profiles) = pending else { throw VortxNativeError.invalidSnapshot }
            for (id, entry) in profiles {
                guard UUID(uuidString: id)?.uuidString == id, case .object(let fields) = entry,
                      Set(fields.keys) == ["verifiedStreamingUid", "sourceDocumentSha256", "profileOverlayBase64", "reason"]
                        || Set(fields.keys) == ["profileOverlayBase64", "reason"],
                      case .string(let reason) = fields["reason"], ["missing_witness", "changed_witness"].contains(reason),
                      case .string(let raw) = fields["profileOverlayBase64"], let bytes = Data(base64Encoded: raw), bytes.base64EncodedString() == raw,
                      (try? VortxProfileOverlayWitness.decodeObject(json: bytes)) != nil,
                      let overlay = try? JSONDecoder().decode(VortxJSON.self, from: bytes),
                      case .object(let root) = overlay, Set(root.keys).isSubset(of: ["vortx", "webProgress"]) else { throw VortxNativeError.invalidSnapshot }
                if let vortx = root["vortx"] {
                    guard case .object(let fields) = vortx, Set(fields.keys) == ["byProfile"],
                          case .object(let profiles) = fields["byProfile"], Set(profiles.keys) == [id] else { throw VortxNativeError.invalidSnapshot }
                }
                if let web = root["webProgress"] {
                    guard case .object(let fields) = web, Set(fields.keys) == ["removed"],
                          case .object(let removed) = fields["removed"], Set(removed.keys) == ["byProfile"],
                          case .object(let profiles) = removed["byProfile"], Set(profiles.keys) == [id] else { throw VortxNativeError.invalidSnapshot }
                }
                // Pending is not an import receipt. It may only refer to an already validated
                // source for this exact profile, including a dormant historical account slot.
                if fields["verifiedStreamingUid"] == nil {
                    guard reason == "missing_witness", state["roster"]?["profiles"]?[id] != nil else { throw VortxNativeError.invalidSnapshot }
                    continue // No attribution: no reconnect may consume this raw intent.
                }
                guard case .string(let uid) = fields["verifiedStreamingUid"], !uid.isEmpty,
                      case .string(let digest) = fields["sourceDocumentSha256"],
                      digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw VortxNativeError.invalidSnapshot }
                let receipt = state["nativeSync"]?["legacyImport"]
                let legacy = receipt?["baseline"]?["ownAccountSources"]?[id]
                var proven = legacy?["verifiedStreamingUid"] == .string(uid)
                    && (legacy?["sourceDocumentSha256"] == .string(digest) || receipt?["ownAccountSourceHistory"]?[id]?[digest] != nil)
                if case .object(let slots) = state["nativeSync"]?["accountSlots"]?[id]?["slots"] {
                    proven = proven || slots.values.contains {
                        $0["sourceBaseline"]?["source"]?["verifiedStreamingUid"] == .string(uid)
                            && ($0["sourceBaseline"]?["source"]?["sourceDocumentSha256"] == .string(digest) || $0["sourceHistory"]?[digest] != nil)
                    }
                }
                guard proven else { throw VortxNativeError.invalidSnapshot }
            }
        }
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
    nonisolated static func authenticatedOwnAccountBaseline(scope: VortxAccountScope, ownerName: String,
                                                            snapshot: String?, nativeSync: VortxJSON?,
                                                            abi: any VortxRuntimeABI) throws -> Data? {
        let sync = try authenticatedAccountSync(scope: scope, ownerName: ownerName, snapshot: snapshot, nativeSync: nativeSync, abi: abi)
        guard [.integer(3), .integer(4)].contains(sync?["schemaVersion"] ?? .null),
              sync?["legacyImport"]?["schemaVersion"] == .integer(2) else { return nil }
        guard let baseline = sync?["legacyImport"]?["baseline"], baseline["schemaVersion"] == .integer(2),
              case .object(let proofs) = baseline["ownAccountSources"], !proofs.isEmpty else { throw VortxNativeError.invalidSnapshot }
        return try JSONEncoder().encode(baseline)
    }
    nonisolated static func authenticatedAccountSync(scope: VortxAccountScope, ownerName: String,
                                                     snapshot: String?, nativeSync: VortxJSON?, abi: any VortxRuntimeABI) throws -> VortxJSON? {
        guard snapshot != nil || nativeSync != nil else { return nil }
        try scope.validate()
        let candidate: VortxNativeRuntime
        if let snapshot {
            _ = try scope.validateSnapshot(snapshot)
            candidate = try VortxNativeRuntime(abi: abi, snapshot: snapshot)
            try scope.validateHydration(from: snapshot, to: candidate.stateJSON())
        } else { candidate = try VortxNativeRuntime(abi: abi, ownerID: scope.ownerProfileID, ownerName: ownerName) }
        defer { candidate.close() }
        try bind(candidate, scope: scope)
        if let nativeSync {
            let action = VortxJSON.object(["type": .string("merge_native_sync"), "document": nativeSync])
            try apply(candidate, action: String(decoding: JSONEncoder().encode(action), as: UTF8.self))
        }
        return try scope.validateSnapshot(candidate.stateJSON())["nativeSync"]
    }
    enum LegacyCompatibilityStage: String { case scope, hydration, binding, nativeMerge = "native_merge", receipt, replay, reconciliation }
    /// The kernel's answer when offered the current legacy cloud carriers.
    enum LegacyReconciliation: Equatable, Sendable {
        case accepted
        /// The kernel rejected this legacy delta. Its reconcile is atomic, so nothing from it was
        /// imported; the immutable migration bootstrap is unchanged and the untouched legacy
        /// carriers are offered again on the next sync. Native state keeps mounting and syncing.
        /// `delta` is a `VortxLegacyDeltaSummary` outline of what was held.
        case held(reason: String, delta: String)
    }
    @discardableResult
    nonisolated static func validateLegacyCompatibility(scope: VortxAccountScope, ownerName: String,
                                                        snapshot: String?, nativeSync: VortxJSON?, material: Data,
                                                        abi: any VortxRuntimeABI, baselineMaterial: Data? = nil,
                                                        onStage: (LegacyCompatibilityStage) -> Void = { _ in }) throws -> LegacyReconciliation {
        onStage(.scope)
        try scope.validate()
        let candidate: VortxNativeRuntime
        if let snapshot {
            onStage(.hydration)
            _ = try scope.validateSnapshot(snapshot)
            candidate = try VortxNativeRuntime(abi: abi, snapshot: snapshot)
        } else { candidate = try VortxNativeRuntime(abi: abi, ownerID: scope.ownerProfileID, ownerName: ownerName) }
        defer { candidate.close() }
        onStage(.binding)
        try bind(candidate, scope: scope)
        if let nativeSync {
            onStage(.nativeMerge)
            let action: VortxJSON = .object(["type": .string("merge_native_sync"), "document": nativeSync])
            try apply(candidate, action: String(decoding: JSONEncoder().encode(action), as: UTF8.self))
        }
        return try validateLegacyReceipt(candidate, scope: scope, material: material, baselineMaterial: baselineMaterial, abi: abi, onStage: onStage)
    }
    @discardableResult
    private static func validateLegacyReceipt(_ candidate: VortxNativeRuntime, scope: VortxAccountScope, material: Data, baselineMaterial: Data?,
        abi: any VortxRuntimeABI, onStage: (LegacyCompatibilityStage) -> Void = { _ in }) throws -> LegacyReconciliation {
        try validateLegacyReceipt(.generic(candidate), scope: scope, material: material,
            baselineMaterial: baselineMaterial, abi: abi, onStage: onStage)
    }
    private static func validateLegacyReceipt(_ candidate: NativeCandidate, scope: VortxAccountScope, material: Data, baselineMaterial: Data?,
                                             abi: any VortxRuntimeABI,
                                             onStage: (LegacyCompatibilityStage) -> Void = { _ in }) throws -> LegacyReconciliation {
        onStage(.receipt)
        let state = try candidate.state(scope: scope)
        let nativeSchema = legacyImportSchema(state["nativeSync"]?["legacyImport"]?["schemaVersion"])
        let materialValue = try strictJSONObject(material)
        guard let nativeSchema, nativeSchema == legacyImportSchema(materialValue["schemaVersion"]), nativeSchema == 1 || nativeSchema == 2 else {
            throw VortxNativeError.invalidSnapshot
        }
        let replay: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account),
                                       "ownerProfileId": .string(scope.ownerProfileID),
                                       "material": materialValue])
        onStage(.replay)
        let replayResult = try candidate.dispatch(String(decoding: JSONEncoder().encode(replay), as: UTF8.self), now: UInt64(Date().timeIntervalSince1970))
        if try JSONDecoder().decode(VortxJSON.self, from: Data(replayResult.utf8))["ok"] == .bool(true) { return .accepted }
        // Only the private kernel decides which old-peer causal changes are supported. Older
        // artifacts reject this additive action and remain closed; there is no host reducer.
        var reconciliation: [String: VortxJSON] = ["type": .string("reconcile_legacy_sync"), "scope": .string(scope.account),
            "ownerProfileId": .string(scope.ownerProfileID), "material": materialValue]
        if state["nativeSync"]?["legacyImport"]?["baseline"] == nil, let baselineMaterial {
            reconciliation["baselineMaterial"] = try strictJSONObject(baselineMaterial)
        }
        onStage(.reconciliation)
        let result = try candidate.dispatch(String(decoding: JSONEncoder().encode(VortxJSON.object(reconciliation)), as: UTF8.self),
                                            now: UInt64(Date().timeIntervalSince1970))
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        if response["ok"] == .bool(true) { return .accepted }
        // A rejected legacy delta must not take native restore, export and receive down with it.
        let base = state["nativeSync"]?["legacyImport"]?["baseline"] ?? baselineMaterial.flatMap { canonicalLegacyMaterial($0, scope: scope, abi: abi) }
        let next = canonicalLegacyMaterial(material, scope: scope, abi: abi)
        let delta: String
        if let base, let next { delta = VortxLegacyDeltaSummary.describe(base: base, next: next, ownerProfileID: scope.ownerProfileID) }
        else { delta = base == nil ? "baseline_unavailable" : "canonical_unavailable" }
        return .held(reason: legacyRejectionCode(response["error"]), delta: delta)
    }
    /// The kernel's canonical form of a legacy material (what it stores as a receipt baseline), via a
    /// detached scratch import, so a held delta is outlined like-for-like rather than raw vs normalized.
    private static func canonicalLegacyMaterial(_ material: Data, scope: VortxAccountScope, abi: any VortxRuntimeABI) -> VortxJSON? {
        (try? detachedLegacySync(scope: scope, ownerName: "Owner", material: material, abi: abi))?["legacyImport"]?["baseline"]
    }
    /// The kernel's reconcile rejections are fixed lowercase phrases. Anything else (for example
    /// a serde message quoting material bytes) is reduced to a constant so no account data is logged.
    nonisolated static func legacyRejectionCode(_ error: VortxJSON?) -> String {
        guard case .string(let text) = error, text.count <= 120,
              text.range(of: "^[a-z][a-z0-9 /_-]*$", options: .regularExpression) != nil else { return "unclassified" }
        return text.replacingOccurrences(of: " ", with: "_")
    }
    /// Which profiles' saved Library lost titles across a sync merge, as `owner(n)` / `p<tag>(n)`, so a
    /// title that disappears can be traced to the sync that removed it. The tag is a short digest of the
    /// profile ID, stable across devices; titles and IDs are never logged. Nil when nothing was removed.
    nonisolated static func libraryShrink(from old: VortxJSON, to new: VortxJSON, ownerProfileID: String) -> String? {
        guard case .object(let before)? = old["libraries"] else { return nil }
        func members(_ library: VortxJSON?) -> Set<String> {
            Set((library?["items"]?.array ?? []).map { item in
                ["kind", "type", "id"].map { field in item[field].map { String(describing: $0) } ?? "" }.joined(separator: "|")
            })
        }
        let parts = before.keys.sorted().compactMap { id -> String? in
            let removed = members(before[id]).subtracting(members(new["libraries"]?[id])).count
            guard removed > 0 else { return nil }
            let tag = id == ownerProfileID ? "owner"
                : "p" + SHA256.hash(data: Data(id.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
            return "\(tag)(\(removed))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }
    private func recordLegacyReconciliation(_ outcome: LegacyReconciliation) {
        defer { legacyReconciliation = outcome }
        guard outcome != legacyReconciliation else { return }
        switch outcome {
        case .held(let reason, let delta): diagnostics?("legacy_reconcile result=held stage=sync reason=\(reason) delta=\(delta)")
        case .accepted where legacyReconciliation != nil: diagnostics?("legacy_reconcile result=accepted stage=sync")
        case .accepted: break
        }
    }
    private static func strictJSONObject(_ data: Data) throws -> VortxJSON {
        let object = try VortxProfileOverlayWitness.decodeObject(json: data)
        return try JSONDecoder().decode(VortxJSON.self,
                                       from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    private static func legacyImportSchema(_ value: VortxJSON?) -> Int? {
        switch value {
        case .integer(let schema): return schema >= 0 && schema <= Int64(Int.max) ? Int(schema) : nil
        case .unsigned(let schema): return schema <= UInt64(Int.max) ? Int(schema) : nil
        default: return nil
        }
    }
    /// Caller must be outside all authority/lease scopes. A false close is sticky; retain
    /// the original runtime and process-local writer reservation even if this Session dies.
    /// This exceptional quarantine has no retry/reset/reopen API.
    private func retireGenericRuntime() -> Bool {
        guard !genericRetirementUnconfirmed else { return false }
        guard let runtime else { return true }
        guard runtime.close() else {
            genericRetirementUnconfirmed = true
            persistenceFailed = true
            writer.retainUnconfirmedRetirement(runtime)
            return false
        }
        return true
    }
    func close() {
        revoke(); closed = true; invalidateScreens()
        let typedRetired = ownerHistory?.close() ?? true
        if !typedRetired { writer.quarantineOwnerHistoryRetirement(ownerHistory) }
        let genericRetired = retireGenericRuntime()
        if typedRetired && genericRetired { writer.release() }
    }
    /// Existing DTO/runtime routes cannot read or write a retired generic owner. They are
    /// intentionally unsupported after transfer until their typed routes are implemented.
    private func requireGenericRoute() throws {
        guard !closed else { throw VortxNativeError.closed }
        guard ownerHistory == nil, runtime != nil else { throw OwnerHistoryRoutingFailure.unsupportedGenericRoute }
    }

    /// Synchronous logout boundary: waits for an already-running atomic commit, then forbids later
    /// commits even before the actor processes close(). No outgoing account writes occur after return.
    nonisolated func revoke() { lease.revoke() }
    /// Also reaches an authenticated mount that has opened a checkpoint but has not yet installed
    /// its facade. Owner/profile boundaries therefore revoke writes during every bootstrap await.
    nonisolated static func revokeAllForOwnerBoundary() { VortxScopeWriter.revokeAll() }
    private func invalidateScreens() {
        epoch = UUID(); bridges.values.forEach { $0.invalidate() }
        resourceBatchBridges.values.flatMap { $0 }.forEach { $0.invalidate() }
        resourceBatchBridges.removeAll(); catalogPlans.removeAll()
        tickets.removeAll(); pages.removeAll(); screens.removeAll(); catalogRegistries.removeAll()
    }
    func invalidateResources() { invalidateScreens() }
    func stateJSON() throws -> String {
        try requireActiveRoute()
        if let ownerHistory {
            guard let value = String(data: try ownerHistory.presentationSnapshot(), encoding: .utf8) else {
                throw VortxNativeError.invalidSnapshot
            }
            return value
        }
        return try lease.withActive { try runtime.stateJSON() }
    }
    func playbackProjection() throws -> VortxJSON {
        let state = try presentationState()
        guard let profile = state["activeProfileId"] else { throw VortxNativeError.invalidSnapshot }
        let query = VortxJSON.object(["kind": .string("profile_playback"), "profileId": profile])
        let result = try ownerHistory != nil ? ownerHistoryResolve(query)
            : lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) }
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        guard response["kind"] == .string("profile_playback"), response["profileId"] == profile,
              response["continueWatching"]?.array != nil, response["history"]?.array != nil,
              case .object = response["watchedVideoIdsByTitle"], case .object = response["watchedTitles"],
              case .object = response["resumeById"] else { throw VortxNativeError.invalidResponse }
        return response
    }
    /// A read remains reading. Do not admit/finish a FIFO member to obtain a running view:
    /// that would retire the offer's original capability and its later click receipt.
    func externalCWEligibility(_ candidates: [VortxNativeExternalCW.Candidate], profileID: String,
        original: VortxNativeFIFOAdmission.ReadCapability) async throws -> VortxNativeExternalCW.Resolution {
        try Task.checkCancellation()
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        let bytes = try JSONEncoder().encode(VortxNativeExternalCW.Request(profileId: profileID, candidates: candidates))
        guard bytes.count <= 65_536 else { throw VortxNativeError.invalidResponse }
        var archive: Data?
        var generation: UUID?
        try lease.withActive {
            try original.withActive {
                archive = hostPreferences.local.authenticatedSourceArchive
                generation = externalCWGeneration.capture()
            }
        }
        guard let generation else { throw VortxNativeError.superseded }
        let lease = lease
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: scope, isCurrent: {
            (try? lease.withActive { try original.withActive {} }) != nil
        })
        // No lease, source/FIFO, draft, or runtime lock spans suspension. The worker owns
        // full parsing/replay; only its bounded denials and live receipt return here.
        let prepared = try await worker.externalCWDenials(archive, store: store, profileID: profileID, candidates: candidates)
        guard !closed else { throw VortxNativeError.closed }
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        let authority = ExternalCWAuthority(lease: lease, original: original, draft: prepared.draft.authority,
            generation: externalCWGeneration, expected: generation)
        var accepted: [VortxNativeExternalCW.Verdict]?
        // Established order: lease -> original source/FIFO -> draft receipt -> generation
        // -> runtime reservation. Draft validation here is scalar-only: no I/O/raw scan.
        if let ownerHistory {
            let source = OwnerHistorySourceAuthority(lease: lease, read: original)
            let target = try currentOwnerHistoryTarget(requireCredential: false)
            guard target.profileID.uuidString == profileID else { throw VortxNativeError.superseded }
            let captured = try ownerHistory.capture(target: target, sourceAuthority: source, queueAuthority: original.queueAuthority)
            let raw = try ownerHistory.atomicResolve(bytes, capture: captured, authority: authority)
            accepted = try prepared.denials.narrowing(VortxNativeExternalCW.decode(
                String(decoding: raw, as: UTF8.self), profileID: profileID, candidates: candidates))
        } else {
            try authority.withActive {
                try runtime.withReservation { reservation in
                    let state = try scope.validateSnapshot(reservation.stateJSON())
                    guard state["activeProfileId"] == .string(profileID) else { throw VortxNativeError.superseded }
                    let raw = try reservation.resolve(String(decoding: bytes, as: UTF8.self))
                    accepted = try prepared.denials.narrowing(VortxNativeExternalCW.decode(raw, profileID: profileID, candidates: candidates))
                }
            }
        }
        try Task.checkCancellation()
        guard let accepted else { throw VortxNativeError.invalidResponse }
        // Read retains this complete authority for publication and later offer use. A draft
        // A->B->A, direct Session mutation, source retirement or FIFO change cannot revive it.
        return .init(verdicts: accepted, authority: authority)
    }

    private struct ExternalCWAuthority: VortxMutationAuthority {
        let lease: VortxSessionLease
        let original: VortxNativeFIFOAdmission.ReadCapability
        let draft: any VortxMutationAuthority
        let generation: VortxNativeExternalCW.Generation
        let expected: UUID
        func withActive(_ operation: () throws -> Void) throws {
            try lease.withActive {
                try original.withActive {
                    try draft.withActive { try generation.withActive(expected, operation) }
                }
            }
        }
    }

    func resumeSeconds(id: String, profileID: String) throws -> Double {
        guard try presentationState()["activeProfileId"] == .string(profileID) else { throw VortxNativeError.superseded }
        let query = VortxJSON.object(["kind": .string("resume_point"), "id": .string(id)])
        let result = try ownerHistory != nil ? ownerHistoryResolve(query)
            : lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) }
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        guard response["kind"] == .string("resume_point") else { throw VortxNativeError.invalidResponse }
        if response["resume"] == .null { return 0 }
        guard let offset = try response["resume"]?["offsetMs"]?.decode(UInt64.self) else { throw VortxNativeError.invalidResponse }
        return Double(offset) / 1000
    }
    /// The kernel materializes membership/order; hosts do not reproduce its merge reducer.
    func addonSnapshot() throws -> (state: VortxJSON, inventories: [String: [VortxJSON]],
                                   ownerHistoryLibrary: OwnerHistorySessionPublication.Presentation?) {
        let state = try presentationState()
        guard case .object(let profiles) = state["roster"]?["profiles"] else { throw VortxNativeError.invalidSnapshot }
        var inventories: [String: [VortxJSON]] = [:]
        for (id, profile) in profiles where profile["deleted"] != .bool(true) {
            let query: VortxJSON = .object(["kind": .string("installed_addons"), "profileId": .string(id)])
            let raw: String
            if ownerHistory != nil {
                guard let profile = UUID(uuidString: id) else { throw VortxNativeError.invalidSnapshot }
                raw = try ownerHistoryResolve(query, target: currentOwnerHistoryTarget(profileID: profile, requireCredential: false))
            } else { raw = try lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) } }
            let result = try JSONDecoder().decode(VortxJSON.self, from: Data(raw.utf8))
            guard result["kind"] == .string("installed_addons"), result["profileId"] == .string(id), let rows = result["addons"]?.array else {
                throw VortxNativeError.invalidResponse
            }
            inventories[id] = rows
        }
        // The raw checkpoint's base libraries do not materialize imported owner-history sources.
        // Sample their composed native VIEW in this same actor turn. This disposable UI value never
        // becomes a checkpoint/export carrier, and native holds/removals stay authoritative.
        let ownerLibrary: OwnerHistorySessionPublication.Presentation?
        if let ownerHistory {
            let capture = try ownerHistory.capture(target: currentOwnerHistoryTarget(requireCredential: false),
                sourceAuthority: OwnerHistoryLeaseAuthority(lease: lease), queueAuthority: OwnerHistoryLeaseAuthority(lease: lease))
            let view = try OwnerHistorySessionPublication.Presentation(
                view: ownerHistory.read(kind: "view", capture: capture), expectedFence: capture.fence)
            guard state["activeProfileId"] == .string(view.profileID),
                  view.scope == scope.account, view.ownerProfileID == scope.ownerProfileID else {
                throw VortxNativeError.superseded
            }
            ownerLibrary = view
        } else { ownerLibrary = nil }
        return (state, inventories, ownerLibrary)
    }
    func resourceRegistry() throws -> [VortxResourceAddon] {
        let state = try presentationState()
        guard case .string(let active) = state["activeProfileId"], let profile = state["roster"]?["profiles"]?[active],
              let binding = profile["addons"], [.string("own"), .string("share_primary")].contains(binding) else { throw VortxNativeError.invalidSnapshot }
        let bucket = binding == .string("share_primary") ? scope.ownerProfileID : active
        let typed = ownerHistory != nil
        let query = typed
            ? VortxJSON.object(["kind": .string("profile_addons"), "profileId": .string(active), "bucketProfileId": .string(bucket)])
            : VortxJSON.object(["kind": .string("installed_addons"), "profileId": .string(bucket)])
        let result = try ownerHistory != nil ? ownerHistoryResolve(query)
            : lease.withActive { try runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)) }
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
        guard response["kind"] == .string(typed ? "profile_addons" : "installed_addons"),
              response["profileId"] == .string(typed ? active : bucket),
              !typed || response["bucketProfileId"] == .string(bucket),
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
        try requireActiveRoute()
        return try lease.withActive { try hostPreferences.document }
    }
    func websiteEditOutcome() throws -> VortxJSON {
        try requireActiveRoute()
        return try lease.withActive {
            guard case .object(var result) = try VortxNativeProfileEditHost.outcome(hostPreferences.local) else { throw VortxNativeError.invalidResponse }
            result["addonConflicts"] = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(hostPreferences.local.websiteAddonConflicts ?? []))
            return .object(result)
        }
    }
    func pendingOwnAccountOverlays() throws -> VortxJSON {
        try requireActiveRoute()
        return try lease.withActive {
            guard let archive = hostPreferences.local.authenticatedSourceArchive else { return .object([:]) }
            return try JSONDecoder().decode(VortxJSON.self, from: archive)["hostDocument"]?["ownAccountOverlayPending"] ?? .object([:])
        }
    }
    func authenticatedSourceArchive() throws -> Data? {
        try requireActiveRoute()
        return try lease.withActive { hostPreferences.local.authenticatedSourceArchive }
    }
    func migrationDraft(isCurrent: @escaping @Sendable () -> Bool = { true },
        checkpoint: (@Sendable () async throws -> Void)? = nil) async throws -> Data? {
        try requireActiveRoute()
        try lease.withActive {}
        let lease = lease
        let result = try await store.readMigrationDraftCooperatively(scope: scope,
            isCurrent: { (try? lease.withActive {}) != nil && isCurrent() }, checkpoint: checkpoint)
        try requireActiveRoute()
        try lease.withActive {}
        return result
    }
    func retainMigrationProgress(_ archive: Data, expected: Data?, authority: any VortxMutationAuthority,
        checkpoint: (@Sendable () async throws -> Void)? = nil) async throws {
        try requireActiveRoute()
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        try lease.withActive {}
        try authority.withActive {}
        let lease = lease
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: scope,
            isCurrent: { (try? lease.withActive {}) != nil && (try? authority.withActive {}) != nil },
            checkpoint: checkpoint)
        // No session/authority/file lock spans this suspension. The witness binds
        // strict validation to immutable bytes, not to a possibly retired admission.
        let draft = try await worker.validatedDraft(archive)
        try requireActiveRoute()
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        try lease.withActive {
            try Task.checkCancellation()
            // This lease belongs to this session instance and never reactivates on
            // same-account reopen. The store separately checks source authority and
            // exact current draft bytes inside its existing atomic durable sink.
            try store.retainValidatedMigrationDraft(draft, scope: scope, expected: expected, authority: authority)
        }
    }
    @discardableResult func dispatch(_ actions: [String], now: UInt64, legacyMaterial: Data? = nil,
                                    hostRemote: VortxJSON? = nil, hostEdits: [VortxNativeHostPreferences.Edit] = [],
                                    legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]] = [:],
                                    websiteEvents: [VortxJSON] = [], websiteAddonEvents: [VortxJSON] = [], websiteBaseline: VortxNativeProfileEditHost.Baselines = [:],
                                    sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil,
                                    hostFieldCAS: VortxHostFieldCAS? = nil,
                                    checkpointValidator: (any VortxProspectiveCheckpointValidator)? = nil,
                                    fifoAuthority: (any VortxMutationAuthority)? = nil,
                                    typedPeer: OwnerHistoryPeerPreparation? = nil) async throws -> [String] {
        try requireActiveRoute()
        // Retire at actual execution, not when a later FIFO member is merely enqueued.
        externalCWGeneration.retire()
        let old = try stateJSON()
        let typedCapture: OwnerHistorySessionCoordinator.Capture?
        let typedTransaction: (any OwnerHistoryCompleteCheckpointAuthority)?
        var candidate: NativeCandidate
        if let ownerHistory {
            // Account-native commands do not fetch/import Stremio data. The real original
            // account source, running FIFO member and complete-account CAS remain mandatory.
            guard let fifoAuthority else { throw VortxNativeError.superseded }
            guard let prepareLocalCheckpoint = ownerHistoryLocalCheckpointPreparation else { throw VortxNativeError.unavailable }
            let source = OwnerHistoryOrdinarySource(lease: lease, source: sourceAuthority, member: fifoAuthority,
                peerSource: typedPeer?.sourceAuthority)
            try source.withActive {}
            let target = try currentOwnerHistoryTarget(requireCredential: false)
            let capture = try ownerHistory.capture(target: target, sourceAuthority: source, queueAuthority: fifoAuthority)
            if let peer = typedPeer {
                guard peer.acknowledged.originalRead === (sourceAuthority as? VortxNativeFIFOAdmission.ReadCapability) else {
                    throw VortxNativeError.superseded
                }
                try source.withActive { try requireOwnerHistoryCheckpointWithoutAuthority(peer.acknowledged) }
                typedCapture = capture; typedTransaction = peer.transaction
                candidate = .owner(try ownerHistory.peerCandidate(nativeDocument: peer.nativeDocument,
                    localArchive: peer.localArchive, peerCapabilities: peer.peerCapabilities,
                    capture: capture, transaction: peer.transaction))
            } else {
                let base = try ownerHistory.acknowledgedAccountBase(capture: capture)
                let prepared = try await prepareLocalCheckpoint(base, scope, source)
                let transaction: any OwnerHistoryCompleteCheckpointAuthority
                if let checkpointValidator {
                    transaction = OwnerHistoryAdditionalCheckpointAuthority(raw: prepared, additional: checkpointValidator)
                } else { transaction = prepared }
                try source.withActive {}
                typedCapture = capture; typedTransaction = transaction
                candidate = .owner(try ownerHistory.candidate(capture: capture, transaction: transaction))
            }
        } else {
            typedCapture = nil; typedTransaction = nil
            let value = try VortxNativeRuntime(abi: abi, snapshot: old)
            try scope.validateHydration(from: old, to: value.stateJSON())
            candidate = .generic(value)
        }
        var installed = false
        defer { if !installed { candidate.close() } }
        var results: [String] = []
        for action in actions {
            let result = try candidate.dispatch(action, now: now)
            let value = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
            guard value["ok"] == .bool(true) else { throw VortxNativeError.invalidResponse }
            results.append(result)
        }
        if let legacyMaterial {
            recordLegacyReconciliation(try Self.validateLegacyReceipt(candidate, scope: scope, material: legacyMaterial, baselineMaterial: legacyBaseline, abi: abi))
        }
        var state = try candidate.state(scope: scope)
        if legacyMaterial != nil, let shrink = try? Self.libraryShrink(from: JSONDecoder().decode(VortxJSON.self, from: Data(old.utf8)),
                                                                       to: state, ownerProfileID: scope.ownerProfileID) {
            diagnostics?("library_shrink stage=sync removed=\(shrink)")
        }
        try Self.validateAuthenticatedSources(authenticatedSourceArchive, state: state)
        var candidateHost = hostPreferences
        try candidateHost.retainAuthenticatedSourceArchive(authenticatedSourceArchive)
        try candidateHost.merge(hostRemote, scope: scope)
        for (profile, entries) in legacyWatchlists {
            // The unchanged legacy roster may still carry a profile explicitly deleted by the
            // native peer. Preserve that old array in its source document, never resurrect the
            // profile or block unrelated sync because its historical ledger cannot be seeded.
            guard let record = state["roster"]?["profiles"]?[profile.uuidString], record["deleted"] != .bool(true) else { continue }
            try VortxNativeWatchlist.seed(entries, profileID: profile, into: &candidateHost)
        }
        if let hostFieldCAS, !hostFieldCAS.matches(try candidateHost.document) {
            throw VortxNativeHostFieldMutationError.staleRegister
        }
        for edit in hostEdits {
            if let profile = edit.profileID {
                guard let record = state["roster"]?["profiles"]?[profile], record["deleted"] != .bool(true) else { throw VortxNativeError.invalidSnapshot }
            }
            try candidateHost.edit(profileID: edit.profileID, fields: edit.fields, scope: scope)
        }
        let pending = candidateHost.local.websitePending ?? []
        let hasWebsiteWork = !websiteEvents.isEmpty || !pending.isEmpty
        if hasWebsiteWork {
            try VortxNativeProfileEditHost.validateSource(websiteEvents)
            // Preserve differing payloads sharing one ID: the kernel checks immutable identity;
            // a conflict must never replace a previously retained event silently.
            var queue = pending
            for event in websiteEvents where !queue.contains(event) { queue.append(event) }
            var retained: [VortxJSON] = [], conflicts: [VortxNativeProfileEditHost.Conflict] = []
            var receipts = candidateHost.local.websiteReceipts ?? [:]
            for event in queue {
                let eventID = (try? event["eventId"]?.decode(String.self)) ?? "invalid-event"
                let previousEventState = try candidate.state(scope: scope)
                let trial = try candidate.copy(abi: abi)
                var accepted = false
                defer { if !accepted { trial.close() } }
                do {
                    var authoredEvent = event
                    var requestFields: [String: VortxJSON] = ["type": .string("apply_legacy_profile_edits"),
                        "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID)]
                    if let aggregate = event["legacyAggregate"] {
                        guard aggregate == legacyProfileEdits, case .object(var fields) = aggregate,
                              let fingerprint = try candidate.state(scope: scope)["nativeSync"]?["legacyImport"]?["fingerprint"] else { throw VortxNativeError.invalidSnapshot }
                        fields["eventId"] = .string(eventID); authoredEvent = .object(fields)
                        requestFields["legacyBootstrapFingerprint"] = fingerprint
                    }
                    requestFields["event"] = authoredEvent
                    let request = VortxJSON.object(requestFields)
                    let response = try trial.dispatch(String(decoding: JSONEncoder().encode(request), as: UTF8.self), now: now)
                    let result = try JSONDecoder().decode(VortxJSON.self, from: Data(response.utf8))
                    guard result["ok"] == .bool(true), let applied = result["events"]?.array?.first,
                          applied["event"] == .string("legacy_profile_edits_applied"), let receipt = applied["receipt"],
                          receipt["eventId"] == .string(eventID), case .string(let fingerprint) = receipt["source"]?["fingerprint"],
                          let patch = applied["hostPatch"] else { throw VortxNativeError.invalidResponse }
                    let admitted = try VortxNativeProfileEditHost.admit(event: authoredEvent, hostPatch: patch,
                        preferences: candidateHost, scope: scope, baseline: websiteBaseline,
                        committedReplay: receipts[eventID] == fingerprint,
                        remoteReplay: previousEventState["nativeSync"]?["legacyProfileEditReceipts"]?[fingerprint] == receipt)
                    if let conflict = admitted.conflict { conflicts.append(conflict); retained.append(event); continue }
                    let next = try trial.state(scope: scope)
                    guard next["nativeSync"]?["legacyProfileEditReceipts"]?[fingerprint] == receipt else { throw VortxNativeError.invalidResponse }
                    candidate.close(); candidate = trial; accepted = true; candidateHost = admitted.preferences
                    receipts[eventID] = fingerprint; results.append(response)
                } catch {
                    retained.append(event)
                    conflicts.append(.init(eventId: eventID, code: "unsupported_or_invalid_event", paths: []))
                }
            }
            candidateHost.local.websitePending = retained
            candidateHost.local.websiteReceipts = receipts
            candidateHost.local.websiteConflicts = conflicts
            state = try candidate.state(scope: scope)
        }
        let addonPending = candidateHost.local.websiteAddonPending ?? []
        let hasAddonWork = !websiteAddonEvents.isEmpty || !addonPending.isEmpty
        if hasAddonWork {
            try VortxNativeWebsiteAddonEdits.validateSource(websiteAddonEvents)
            try VortxNativeWebsiteAddonEdits.validateIncomingIdentities(websiteAddonEvents)
            var queue = addonPending
            for event in websiteAddonEvents where !queue.contains(event) { queue.append(event) }
            try VortxNativeWebsiteAddonEdits.validateSource(queue)
            let collidingIDs = VortxNativeWebsiteAddonEdits.collidingIdentities(queue)
            var retained: [VortxJSON] = []
            var conflicts = candidateHost.local.websiteAddonConflicts ?? []
            var receipts = candidateHost.local.websiteAddonReceipts ?? [:]
            for event in queue {
                let eventID = (try? event["eventId"]?.decode(String.self)) ?? "invalid-event"
                if collidingIDs.contains(eventID) {
                    retained.append(event)
                    let conflict = VortxNativeWebsiteAddonEdits.Conflict(eventId: eventID, code: "conflicting_addon_event_id", paths: [])
                    if !conflicts.contains(conflict) { conflicts.append(conflict) }
                    continue
                }
                let trial = try candidate.copy(abi: abi)
                var accepted = false
                defer { if !accepted { trial.close() } }
                do {
                    let request = VortxNativeWebsiteAddonEdits.request(event: event, scope: scope)
                    let response = try trial.dispatch(String(decoding: JSONEncoder().encode(request), as: UTF8.self), now: now)
                    let result = try JSONDecoder().decode(VortxJSON.self, from: Data(response.utf8))
                    let next = try trial.state(scope: scope)
                    let receipt = try VortxNativeWebsiteAddonEdits.validatedReceipt(event: event, result: result, state: next, scope: scope)
                    if let conflict = try VortxNativeWebsiteAddonEdits.conflict(event: event, receipt: receipt, state: next, resolve: { try trial.resolve($0) }) {
                        if !conflicts.contains(conflict) { conflicts.append(conflict) }
                    }
                    // Even a losing event needs its native receipt durably retained. Its replay
                    // cannot acquire a new clock or undo a later native uninstall.
                    candidate.close(); candidate = trial; accepted = true
                    receipts[receipt.id] = receipt.fingerprint; results.append(response)
                } catch {
                    retained.append(event)
                    let conflict = VortxNativeWebsiteAddonEdits.Conflict(eventId: eventID, code: "unsupported_or_invalid_addon_event", paths: [])
                    if !conflicts.contains(conflict) { conflicts.append(conflict) }
                }
            }
            candidateHost.local.websiteAddonPending = retained
            candidateHost.local.websiteAddonReceipts = receipts
            candidateHost.local.websiteAddonConflicts = conflicts
            state = try candidate.state(scope: scope)
        }
        let updated = try candidate.stateJSON()
        let hasHostChanges = hostRemote != nil || !hostEdits.isEmpty || !legacyWatchlists.isEmpty || hasWebsiteWork || hasAddonWork || authenticatedSourceArchive != nil
        let encodedHost = hasHostChanges ? try candidateHost.encoded() : nil
        if case .owner(let value) = candidate {
            guard let ownerHistory, let typedTransaction, typedCapture != nil else { throw VortxNativeError.superseded }
            do {
                _ = try ownerHistory.commit(value, hostPreferences: candidateHost.encoded(), transaction: typedTransaction)
            } catch VortxNativeError.checkpointUncertain {
                persistenceFailed = true; invalidateScreens()
                throw VortxNativeError.checkpointUncertain
            }
            // Typed candidates never issue an in-memory durable ACK for uncheckpointed progress.
            // Facade duplicate admission remains unchanged; each admitted typed write is durable.
            hostPreferences = candidateHost; installed = true
            pendingProgressCommit = false; lastDurableCommit = ProcessInfo.processInfo.systemUptime
            if try JSONDecoder().decode(VortxJSON.self, from: Data(old.utf8))["activeProfileId"] != state["activeProfileId"] {
                invalidateScreens()
            }
            return results
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let progressOnly = !hasHostChanges && legacyMaterial == nil && sourceAuthority == nil && !actions.isEmpty
            && actions.allSatisfy(Self.isProgressAction)
        let holdBack = progressOnly && uptime >= writeProgressUntil
            && lastDurableCommit.map { uptime - $0 < Self.progressCommitInterval } == true
        if holdBack {
            pendingProgressCommit = true
        } else {
            var checkpointStarted = false
            do {
                func commit() throws {
                    // Complete-candidate preflight and checkpoint share every final authority.
                    if let checkpointValidator {
                        try validateProspectiveCheckpoint(candidateState: updated, candidateHost: candidateHost,
                            now: now, validator: checkpointValidator)
                    }
                    checkpointStarted = true
                    if let encodedHost { try store.commit(updated, scope: scope, hostPreferences: encodedHost) }
                    else { try store.commit(updated, scope: scope) }
                }
                func checkpoint() throws {
                    try lease.withActive {
                        if let sourceAuthority { try sourceAuthority.withActive(commit) } else { try commit() }
                    }
                }
                // Provider publications can synchronously read CoreBridge. Acquire their existing
                // store lock BEFORE the session/Bridge/facade locks, never in the reverse order.
                if let checkpointValidator { try checkpointValidator.withActive(checkpoint) }
                else { try checkpoint() }
            }
            catch VortxNativeError.closed { throw VortxNativeError.closed }
            catch VortxNativeError.superseded { throw VortxNativeError.superseded }
            catch {
                guard checkpointStarted else { throw error }
                // A rename may have succeeded before a readback/fsync failure. Do not overwrite that
                // uncertain checkpoint with another transaction; reopen and validate it first.
                VortxCheckpointDiagnostics.report(stage: .transactionCommit, error: error)
                persistenceFailed = true; throw VortxNativeError.checkpointUncertain
            }
            pendingProgressCommit = false
            lastDurableCommit = uptime
            if progressOnly { writeProgressUntil = 0 }
        }
        guard case .generic(let generic) = candidate else { throw VortxNativeError.invalidSnapshot }
        let previous = runtime!; runtime = generic; hostPreferences = candidateHost; installed = true; previous.close()
        if try scope.validateSnapshot(old)["activeProfileId"] != state["activeProfileId"] { invalidateScreens() }
        return results
    }
    /// The witness came from the complete existing sync/export pipeline after Save confirmation.
    /// Substitute the exact prospective candidate's three native export carriers. No partial
    /// kernel merge, guessed sibling allowance, pruning, upload or checkpoint occurs here.
    private func validateProspectiveCheckpoint(candidateState: String, candidateHost: VortxNativeHostPreferences,
        now: UInt64, validator: any VortxProspectiveCheckpointValidator) throws {
        let state = try scope.validateSnapshot(candidateState)
        guard let native = state["nativeSync"],
              case .object(var outcome) = try VortxNativeProfileEditHost.outcome(candidateHost.local) else {
            throw VortxNativeError.invalidSnapshot
        }
        outcome["addonConflicts"] = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(candidateHost.local.websiteAddonConflicts ?? []))
        try validator.validate(native: native, host: candidateHost.document, profileEditResults: .object(outcome))
    }

    /// Write a position the 30 s coalescing held back, and write the next position report at once too (it may
    /// still be on its way from the player). Failure is handled exactly like a failed commit in dispatch.
    func flushPendingProgress() throws {
        try requireActiveRoute()
        writeProgressUntil = ProcessInfo.processInfo.systemUptime + 10
        guard pendingProgressCommit else { return }
        guard !persistenceFailed else { throw VortxNativeError.checkpointUncertain }
        externalCWGeneration.retire()
        let current = try stateJSON()
        do { try lease.withActive { try store.commit(current, scope: scope) } }
        catch VortxNativeError.closed { throw VortxNativeError.closed }
        catch {
            VortxCheckpointDiagnostics.report(stage: .transactionCommit, error: error)
            persistenceFailed = true; throw VortxNativeError.checkpointUncertain
        }
        pendingProgressCommit = false
        lastDurableCommit = ProcessInfo.processInfo.systemUptime
    }
    func screen(_ name: String) -> VortxNativeScreenState? {
        guard !closed, !ownerHistoryRetirementPending else { return nil }
        return screens[name]
    }
    private func begin(_ name: String, expectedProfileID: String? = nil) throws -> (VortxResourceBridge, UUID, UUID, String) {
        try Task.checkCancellation()
        guard case .string(let profile) = try presentationState()["activeProfileId"] else { throw VortxNativeError.invalidSnapshot }
        guard expectedProfileID == nil || expectedProfileID == profile else { throw VortxNativeError.superseded }
        resourceBatchBridges.removeValue(forKey: name)?.forEach { $0.invalidate() }
        let ticket = UUID(); tickets[name] = ticket; screens[name] = .loading
        let bridge = bridges[name] ?? VortxResourceBridge(transport: transport); bridges[name] = bridge
        try lease.withActive {}; return (bridge, ticket, epoch, profile)
    }
    private func current(_ name: String, _ ticket: UUID, _ capturedEpoch: UUID) -> Bool {
        !closed && !ownerHistoryRetirementPending && epoch == capturedEpoch && tickets[name] == ticket && (try? lease.withActive { true }) == true
    }
    /// One screen operation owns the entire range. Individual bridges cannot supersede another
    /// catalog; the shared ticket/epoch/lease still retire every leg at an owner or query boundary.
    func loadCatalogs(_ screen: CatalogScreen, catalogs: [(VortxResourceAddon, VortxResourceRequest)],
                      selection: VortxJSON, range: ClosedRange<Int>, previous: VortxJSON?,
                      expectedProfileID: String,
                      onUpdate: @escaping @Sendable (VortxJSON) -> Void) async throws -> VortxJSON {
        guard catalogs.allSatisfy({ $0.1.resource == .catalog }) else { throw VortxNativeError.invalidResponse }
        let name = screen.rawValue
        let (priorBridge, ticket, capturedEpoch, profile) = try begin(name, expectedProfileID: expectedProfileID)
        priorBridge.invalidate()
        // A facade may have captured its rows just before this actor processed a profile change.
        // Reuse only this epoch's own plan, never presentation rows from a retired owner.
        let previousRows = previous == catalogPlans[name] && previous?["selected"] == selection ? previous?["catalogs"]?.array ?? [] : []
        var rows = try catalogs.enumerated().map { index, item -> VortxJSON in
            let request: VortxJSON = .object(["base": .string(item.0.transportUrl), "path": try VortxResourceProjection.path(item.1)])
            if index < previousRows.count, let first = previousRows[index].array?.first,
               first["request"] == request, [VortxJSON.string("Ready"), .string("Err")].contains(first["content"]?["type"] ?? .null) {
                return previousRows[index]
            }
            return .array([.object(["request": request, "content": range.contains(index) ? .object(["type": .string("Loading")]) : .null])])
        }
        // Preserve only pages still present in this exact plan (including already loaded skips).
        pages[name] = (pages[name] ?? []).filter { page in
            page.ownerID == profile && rows.contains { row in
                row.array?.contains { entry in
                    entry["request"]?["path"] == (try? VortxResourceProjection.path(page.request)) &&
                    page.sourceURLs.values.contains { entry["request"]?["base"] == .string($0) } &&
                    [VortxJSON.string("Ready"), .string("Err")].contains(entry["content"]?["type"] ?? .null)
                } == true
            }
        }
        var registry: [VortxResourceAddon] = []
        for (addon, _) in catalogs {
            if let existing = registry.first(where: { $0.id == addon.id }) {
                guard existing.transportUrl == addon.transportUrl else { throw VortxNativeError.invalidResponse }
            } else { registry.append(addon) }
        }
        catalogRegistries[name] = registry
        let pending = rows.indices.filter { range.contains($0) && rows[$0].array?.first?["content"]?["type"] == .string("Loading") }
        let workers = pending.map { _ in VortxResourceBridge(transport: transport) }
        resourceBatchBridges[name] = workers
        defer {
            workers.forEach { $0.invalidate() }
            if tickets[name] == ticket { resourceBatchBridges.removeValue(forKey: name) }
        }
        func publish() throws -> VortxJSON {
            try Task.checkCancellation()
            guard current(name, ticket, capturedEpoch) else { throw VortxNativeError.superseded }
            let board: VortxJSON = .object(["selected": selection, "catalogs": .array(rows)])
            catalogPlans[name] = board; screens[name] = .ready(board); onUpdate(board)
            return board
        }
        _ = try publish()
        return try await withThrowingTaskGroup(of: (Int, VortxResourceSnapshot?).self) { group in
            func schedule(_ offset: Int) {
                let item = catalogs[pending[offset]], bridge = workers[offset]
                group.addTask {
                    do { return (offset, try await bridge.load(ownerID: profile, request: item.1, addons: [item.0])) }
                    catch { return (offset, nil) }
                }
            }
            var scheduled = min(4, pending.count)
            for offset in 0..<scheduled { schedule(offset) }
            while let (offset, result) = try await group.next() {
                try Task.checkCancellation()
                guard current(name, ticket, capturedEpoch) else { throw VortxNativeError.superseded }
                let index = pending[offset], item = catalogs[index]
                let snapshot: VortxResourceSnapshot
                if let result {
                    guard workers[offset].accepts(result) else { throw VortxNativeError.superseded }
                    snapshot = result
                } else {
                    snapshot = .init(ownerID: profile, requestID: UUID().uuidString, generation: 0, request: item.1,
                        groups: [], sourceURLs: [item.0.id: item.0.transportUrl])
                }
                let failure = VortxResourceGroup(addonId: item.0.id, status: .error, content: nil, error: .init(code: "native_catalog_failed"))
                let content = snapshot.groups.first ?? failure
                let accepted = VortxResourceSnapshot(ownerID: snapshot.ownerID, requestID: snapshot.requestID,
                    generation: snapshot.generation, request: snapshot.request, groups: [content], sourceURLs: snapshot.sourceURLs)
                pages[name, default: []].append(accepted)
                rows[index] = .array([try VortxResourceProjection.entry(content, request: item.1, registry: registry)])
                _ = try publish()
                if scheduled < pending.count { schedule(scheduled); scheduled += 1 }
            }
            return .object(["selected": selection, "catalogs": .array(rows)])
        }
    }
    func loadCatalog(_ screen: CatalogScreen, request: VortxResourceRequest, addons: [VortxResourceAddon], append: Bool = false) async throws -> VortxJSON {
        guard request.resource == .catalog else { throw VortxNativeError.invalidResponse }
        let name = screen.rawValue
        let (bridge, ticket, capturedEpoch, profile) = try begin(name)
        do {
            let result: VortxResourceSnapshot
            do {
                let received = try await bridge.load(ownerID: profile, request: request, addons: addons)
                guard current(name, ticket, capturedEpoch), bridge.accepts(received) else { throw VortxNativeError.superseded }
                result = received
            } catch {
                try Task.checkCancellation()
                guard current(name, ticket, capturedEpoch) else { throw VortxNativeError.superseded }
                if case VortxNativeError.superseded = error { throw error }
                guard append else { throw error }
                // A failed page settles only its requested catalog. Keep prior pages and peers;
                // never replace the entire board with a generic operation-error envelope.
                let category = error is VortxNativeError ? VortxNativeError.diagnosticCode(error) : "transport_failed"
                NSLog("[VortXNative] resource=catalog result=failed category=%@", category)
                result = .init(ownerID: profile, requestID: UUID().uuidString, generation: 0, request: request,
                    groups: addons.map { .init(addonId: $0.id, status: .error, content: nil, error: .init(code: "native_catalog_failed")) },
                    sourceURLs: Dictionary(addons.map { ($0.id, $0.transportUrl) }, uniquingKeysWith: { first, _ in first }))
            }
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
            var projection = try VortxResourceProjection.board(pages: accepted, registry: registry)
            if append, let plan = catalogPlans[name], var rows = plan["catalogs"]?.array {
                // Pagination retains the full planned order and the selected query, even when a
                // different catalog completed first or an unrequested row still has nil content.
                for row in projection["catalogs"]?.array ?? [] {
                    guard let request = row.array?.first?["request"], let index = rows.firstIndex(where: {
                        let existing = $0.array?.first?["request"]
                        return existing?["base"] == request["base"] && existing?["path"]?["id"] == request["path"]?["id"] && existing?["path"]?["type"] == request["path"]?["type"]
                    }) else { continue }
                    rows[index] = row
                }
                projection = .object(["selected": plan["selected"] ?? .null, "catalogs": .array(rows)])
                catalogPlans[name] = projection
            } else { catalogPlans.removeValue(forKey: name) }
            catalogRegistries[name] = registry; pages[name] = accepted; screens[name] = .ready(projection); return projection
        } catch {
            if current(name, ticket, capturedEpoch) { screens[name] = .failed }; throw error
        }
    }
    func loadMeta(request: VortxResourceRequest, stream: VortxResourceRequest?, addons: [VortxResourceAddon],
                  expectedProfileID: String? = nil,
                  onUpdate: @escaping @Sendable (VortxJSON) -> Void = { _ in }) async throws -> VortxJSON {
        guard request.resource == .meta, stream == nil || (stream?.resource == .stream && stream?.type == request.type),
              addons.count <= 128, Set(addons.map(\.id)).count == addons.count else { throw VortxNativeError.invalidResponse }
        let name = "meta_details"
        let (priorBridge, ticket, capturedEpoch, profile) = try begin(name, expectedProfileID: expectedProfileID)
        priorBridge.invalidate()
        // A native multi-addon call spends its deadline waiting for its internal slots. Schedule
        // singleton calls here instead: each admitted leg receives its own network budget.
        // Metadata keeps 20s; stream aggregators may need up to 40s for upstream collection.
        // Separate two-meta/four-stream windows still bound work and publish fast peers early.
        // Queue time never consumes a leg's budget; changing screen/profile still cancels it.
        let jobs = addons.indices.flatMap { index -> [(Int, VortxResourceRequest)] in
            [(index, request)] + (stream.map { [(index, $0)] } ?? [])
        }
        let workers = jobs.map { _ in VortxResourceBridge(transport: transport) }
        resourceBatchBridges[name] = workers
        defer {
            workers.forEach { $0.invalidate() }
            if tickets[name] == ticket { resourceBatchBridges.removeValue(forKey: name) }
        }
        var metas = [VortxResourceGroup?](repeating: nil, count: addons.count)
        var streams = [VortxResourceGroup?](repeating: nil, count: stream == nil ? 0 : addons.count)
        var completed = 0
        var metaContentBudget = VortxResourceContentBudget(), streamContentBudget = VortxResourceContentBudget()
        let sourceURLs = Dictionary(uniqueKeysWithValues: addons.map { ($0.id, $0.transportUrl) })
        func snapshot(_ path: VortxResourceRequest, _ groups: [VortxResourceGroup?]) -> VortxResourceSnapshot {
            .init(ownerID: profile, requestID: ticket.uuidString, generation: 0, request: path,
                  groups: groups.compactMap { $0 }, sourceURLs: sourceURLs)
        }
        func rows(_ path: VortxResourceRequest, _ groups: [VortxResourceGroup?]) throws -> [VortxJSON] {
            try groups.enumerated().map { index, group in
                if let group { return try VortxResourceProjection.entry(group, request: path, registry: addons) }
                return .object(["request": .object(["base": .string(addons[index].transportUrl), "path": try VortxResourceProjection.path(path)]),
                                "content": .object(["type": .string("Loading")])])
            }
        }
        func publish(logStreams: Bool = false, settled: Bool = false) throws -> VortxJSON {
            try Task.checkCancellation()
            guard current(name, ticket, capturedEpoch) else { throw VortxNativeError.superseded }
            let projection = try VortxResourceProjection.metaDetails(meta: snapshot(request, metas),
                streams: stream.map { snapshot($0, streams) }, expectedStream: stream, registry: addons)
            let value: VortxJSON = .object(["selected": projection["selected"] ?? .null,
                "metaItems": .array(try rows(request, metas)), "streams": .array(try stream.map { try rows($0, streams) } ?? []),
                "metaStreams": projection["metaStreams"] ?? .array([])])
            screens[name] = completed == 0 && !jobs.isEmpty ? .loading : .ready(value)
            onUpdate(value)
            if logStreams, stream != nil {
                var ready = 0, empty = 0, failed = 0
                for case let group? in streams {
                    if group.status != .ready { failed += 1 }
                    else if (try? group.items(for: .stream).isEmpty) == true { empty += 1 }
                    else { ready += 1 }
                }
                NSLog("[VortXNative] resource=stream result=%@ ready=%d empty=%d error=%d loading=%d", settled ? "settled" : "partial", ready, empty, failed, streams.count - ready - empty - failed)
            }
            return value
        }
        _ = try publish(logStreams: true)
        return try await withThrowingTaskGroup(of: (Int, Result<VortxResourceSnapshot, VortxResourceGroup.Failure>).self) { group in
            func schedule(_ offset: Int) {
                let job = jobs[offset], bridge = workers[offset], addon = addons[job.0]
                group.addTask {
                    do { return (offset, .success(try await bridge.load(ownerID: profile, request: job.1, addons: [addon],
                        budgetMs: job.1.resource == .stream ? 40_000 : 20_000,
                        maxResponseBytes: 8_388_608, maxTotalResponseBytes: 33_554_432))) }
                    catch { return (offset, .failure(.from(error))) }
                }
            }
            let metaStride = stream == nil ? 1 : 2
            var scheduledMeta = min(2, addons.count), scheduledStreams = stream == nil ? 0 : min(4, addons.count)
            for index in 0..<scheduledMeta { schedule(index * metaStride) }
            for index in 0..<scheduledStreams { schedule(index * 2 + 1) }
            while let (offset, result) = try await group.next() {
                try Task.checkCancellation()
                guard current(name, ticket, capturedEpoch) else { throw VortxNativeError.superseded }
                let job = jobs[offset], addon = addons[job.0]
                var value: VortxResourceGroup
                switch result {
                case .success(let result):
                    guard workers[offset].accepts(result) else { throw VortxNativeError.superseded }
                    // Unsupported/empty singleton responses are terminal, not still-loading rows.
                    value = result.groups.first ?? .init(addonId: addon.id, status: .ready,
                        content: .object(job.1.resource == .meta ? ["meta": .null] : ["streams": .array([])]), error: nil)
                case .failure(let failure):
                    value = .failed(addonId: addon.id, failure: failure)
                }
                if value.status == .ready {
                    do {
                        // Validate embedded streams before they enter the combined projection;
                        // malformed metadata from one provider must not discard valid peers.
                        if job.1.resource == .meta {
                            _ = try VortxResourceProjection.metaDetails(meta: snapshot(request, [value]), streams: nil,
                                expectedStream: stream, registry: addons)
                        }
                        // Retain the incumbent32MiB normalized-content cap separately for meta
                        // and stream. This is not a consumed-wire-byte measure: the ABI does not
                        // report raw bytes for failed or whitespace-heavy responses.
                        let fits = try job.1.resource == .meta ? metaContentBudget.claim(value.content ?? .null) : streamContentBudget.claim(value.content ?? .null)
                        if !fits {
                            value = .init(addonId: addon.id, status: .error, content: nil, error: .init(code: "body_too_large"))
                        }
                    } catch {
                        value = .init(addonId: addon.id, status: .error, content: nil, error: .init(code: "invalid_response"))
                    }
                }
                if job.1.resource == .meta { metas[job.0] = value } else { streams[job.0] = value }
                completed += 1
                _ = try publish(logStreams: job.1.resource == .stream)
                // Publish/log the accepted terminal leg once, not every snapshot of prior legs.
                // No await separates these ownership checks from submitting the redacted receipt.
                try Task.checkCancellation()
                guard current(name, ticket, capturedEpoch) else { throw VortxNativeError.superseded }
                VXProbe.log("native-addon", value.terminalDiagnostic(requestID: ticket,
                    request: job.1, sourceOrdinal: job.0 + 1))
                if job.1.resource == .meta, scheduledMeta < addons.count {
                    schedule(scheduledMeta * metaStride); scheduledMeta += 1
                } else if job.1.resource == .stream, scheduledStreams < addons.count {
                    schedule(scheduledStreams * 2 + 1); scheduledStreams += 1
                }
            }
            return try publish(logStreams: true, settled: true)
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
