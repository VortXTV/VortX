import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if !os(macOS)
import Security
#endif

/// Failure policy shared by the Apple secure-credential adapters and their executable tests.
///
/// `string` remains the compatibility view for existing callers that intentionally retain a process-local
/// edit while a secure mutation is unavailable. `confirmedString` is the certification boundary: it only
/// returns a value or missing result from the backend itself, with no durable invalidation tombstone.
/// `durableString` deliberately bypasses that tombstone for legacy migration, which must be able to inspect a
/// source left behind by an uncertain delete and retry the claim.
final class KeychainFailureClosedStore: @unchecked Sendable {
    typealias ReadResult = CredentialDurableReadResult
    typealias MutationResult = CredentialMutationResult

    typealias ReadSecure = (_ account: String) -> ReadResult
    typealias WriteSecure = (_ value: String?, _ account: String) -> MutationResult
    typealias InvalidationAccount = (_ account: String) -> String
    typealias IsLegacyInvalidated = (_ account: String) -> Bool
    typealias ClearLegacyInvalidated = (_ account: String) -> Void
    typealias PurgeAllLegacy = () -> Void
    typealias PurgeLegacy = (_ account: String) -> Void

    private enum VolatileValue {
        case value(String)
        case deleted
    }

    private let readSecure: ReadSecure
    private let writeSecure: WriteSecure
    private let invalidationAccount: InvalidationAccount
    private let invalidationSentinel: String
    private let isLegacyInvalidated: IsLegacyInvalidated
    private let clearLegacyInvalidated: ClearLegacyInvalidated
    private let purgeAllLegacy: PurgeAllLegacy
    private let purgeLegacy: PurgeLegacy
    private let lock = NSLock()
    private var pendingOverrides: [String: VolatileValue] = [:]
    private var lastKnownValues: [String: VolatileValue] = [:]
    private var generations: [String: UInt64] = [:]
    // Per-account locks serialize the marker and secure-backend mutation sequence. The shared `lock` above
    // remains a short critical section for in-memory state only; it is never held across backend I/O.
    private var accountLocks: [String: NSLock] = [:]
    private var didSweepLegacy = false

    init(
        readSecure: @escaping ReadSecure,
        writeSecure: @escaping WriteSecure,
        invalidationAccount: @escaping InvalidationAccount,
        invalidationSentinel: String,
        isLegacyInvalidated: @escaping IsLegacyInvalidated,
        clearLegacyInvalidated: @escaping ClearLegacyInvalidated,
        purgeAllLegacy: @escaping PurgeAllLegacy,
        purgeLegacy: @escaping PurgeLegacy
    ) {
        self.readSecure = readSecure
        self.writeSecure = writeSecure
        self.invalidationAccount = invalidationAccount
        self.invalidationSentinel = invalidationSentinel
        self.isLegacyInvalidated = isLegacyInvalidated
        self.clearLegacyInvalidated = clearLegacyInvalidated
        self.purgeAllLegacy = purgeAllLegacy
        self.purgeLegacy = purgeLegacy
    }

    private func beginTransition(_ account: String) -> (generation: UInt64, needSweep: Bool) {
        lock.lock()
        let generation = (generations[account] ?? 0) &+ 1
        generations[account] = generation
        if accountLocks[account] == nil { accountLocks[account] = NSLock() }
        let needSweep = !didSweepLegacy
        didSweepLegacy = true
        lock.unlock()
        return (generation, needSweep)
    }

    private func accountLock(for account: String) -> NSLock {
        lock.lock()
        if let existing = accountLocks[account] {
            lock.unlock()
            return existing
        }
        let created = NSLock()
        accountLocks[account] = created
        lock.unlock()
        return created
    }

    private func isCurrent(_ account: String, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[account, default: 0] == generation
    }

    private func markerAndGenerationAreCurrent(_ account: String, generation: UInt64) -> Bool {
        let accountLock = accountLock(for: account)
        accountLock.lock()
        let markerIsClear = invalidationState(for: account) == .clear
        let current = isCurrent(account, generation: generation)
        accountLock.unlock()
        return current && markerIsClear
    }

    private enum InvalidationState: Equatable {
        case clear
        case invalidated
        case failure
    }

    /// Read or migrate the old defaults marker while the caller owns this credential account's lock. The
    /// durable marker is written and read back before the disposable legacy marker is removed, so a restart or
    /// reinstall can never turn an uncertain old mutation back into certified credential bytes.
    private func invalidationState(for account: String) -> InvalidationState {
        let markerAccount = invalidationAccount(account)
        switch readSecure(markerAccount) {
        case let .value(value):
            return value == invalidationSentinel ? .invalidated : .failure
        case .failure:
            return .failure
        case .missing:
            guard isLegacyInvalidated(account) else { return .clear }
            guard writeSecure(invalidationSentinel, markerAccount) == .success,
                  readSecure(markerAccount) == .value(invalidationSentinel) else {
                return .failure
            }
            clearLegacyInvalidated(account)
            return isLegacyInvalidated(account) ? .failure : .invalidated
        }
    }

    /// Phase one of every credential mutation. The tombstone is persisted again even when one already reads
    /// back, because an older writer may have returned before its bytes reached durable storage. Only this
    /// call's successful write plus exact readback can authorize the target mutation.
    private func markInvalidatedDurably(_ account: String) -> CredentialMutationResult {
        let markerAccount = invalidationAccount(account)
        guard writeSecure(invalidationSentinel, markerAccount) == .success,
              readSecure(markerAccount) == .value(invalidationSentinel) else {
            return .failure
        }

        if isLegacyInvalidated(account) {
            clearLegacyInvalidated(account)
            guard !isLegacyInvalidated(account) else { return .failure }
        }
        return .success
    }

    /// Phase three of a successful credential mutation. The caller has already exact-read verified the target.
    /// A delete may report failure after taking effect, so exact marker absence reconciles that after-effect;
    /// a retained marker or failed read remains failure-closed.
    private func clearInvalidationDurably(_ account: String) -> CredentialMutationResult {
        if isLegacyInvalidated(account) {
            clearLegacyInvalidated(account)
            guard !isLegacyInvalidated(account) else { return .failure }
        }
        let markerAccount = invalidationAccount(account)
        _ = writeSecure(nil, markerAccount)
        return readSecure(markerAccount) == .missing ? .success : .failure
    }

    private func cacheBackendResultIfCurrent(
        _ result: ReadResult,
        account: String,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        guard generations[account, default: 0] == generation else {
            lock.unlock()
            return false
        }
        switch result {
        case let .value(value):
            lastKnownValues[account] = .value(value)
        case .missing:
            lastKnownValues[account] = .deleted
        case .failure:
            break
        }
        lock.unlock()
        return true
    }

    private func cachedValueIfCurrent(
        _ cached: VolatileValue?,
        account: String,
        generation: UInt64
    ) -> String? {
        lock.lock()
        guard generations[account, default: 0] == generation else {
            lock.unlock()
            return nil
        }
        let value: String?
        if case let .value(cachedValue)? = cached {
            value = cachedValue
        } else {
            value = nil
        }
        lock.unlock()
        return value
    }

    private func finishFailedMutation(
        _ value: String?,
        account: String,
        generation: UInt64
    ) -> CredentialMutationResult {
        // The caller holds the per-account lock across the marker/backend sequence. Only the shared map lock
        // is taken here, and only for the pending override update.
        lock.lock()
        let current = generations[account, default: 0] == generation
        if current {
            pendingOverrides[account] = value.map { .value($0) } ?? .deleted
        }
        lock.unlock()
        return .failure
    }

    private func finishSuccessfulMutation(
        _ value: String?,
        account: String,
        generation: UInt64
    ) -> CredentialMutationResult {
        // The caller holds the per-account lock. This prevents another same-account mutation from writing
        // newer bytes between the secure write/readback and marker clear, while the shared map lock stays free.
        guard isCurrent(account, generation: generation) else {
            return .failure
        }

        guard clearInvalidationDurably(account) == .success else {
            return finishFailedMutation(value, account: account, generation: generation)
        }
        lock.lock()
        let current = generations[account, default: 0] == generation
        if current {
            pendingOverrides.removeValue(forKey: account)
            lastKnownValues[account] = value.map { .value($0) } ?? .deleted
        }
        lock.unlock()
        return current ? .success : .failure
    }

    // CRITICAL (FAIL-260731-tvwedge): the lock guards ONLY the in-memory maps below. It must NEVER be
    // held across Keychain (`SecItem*`) or UserDefaults I/O. An earlier version held this lock across
    // `purgeLegacySlots` (a UserDefaults write), and that write synchronously posts a change notification
    // whose observer blocks on a main-thread operation — while the main thread was itself blocked here
    // waiting for the lock. That lock-ordering inversion deadlocked the whole app at launch on a logged-in
    // Apple TV (the Home screen fans out dozens of concurrent Keychain reads: 35 continue-watching + 47
    // discover backdrop lookups via `ApiKeys.tmdbKey`, plus `WatchedIndex.rebuild` reading the SIMKL token
    // on the main thread). Keep every SecItem/UserDefaults call outside the critical section.
    func string(_ account: String) -> String? {
        // Snapshot in-memory state under the lock — no I/O.
        lock.lock()
        let override = pendingOverrides[account]
        let needSweep = !didSweepLegacy
        didSweepLegacy = true
        let cached = lastKnownValues[account]
        let generation = generations[account] ?? 0
        lock.unlock()

        purgeLegacySlots(for: account, fullSweep: needSweep)   // UserDefaults I/O, outside the lock

        if let override {
            guard isCurrent(account, generation: generation) else { return nil }
            switch override {
            case let .value(value): return value
            case .deleted: return nil
            }
        }

        guard markerAndGenerationAreCurrent(account, generation: generation) else { return nil }

        let result = readSecure(account)                        // SecItem read, outside the lock
        guard markerAndGenerationAreCurrent(account, generation: generation) else { return nil }

        switch result {
        case let .value(value):
            guard cacheBackendResultIfCurrent(.value(value), account: account, generation: generation) else {
                return nil
            }
            return value
        case .missing:
            guard cacheBackendResultIfCurrent(.missing, account: account, generation: generation) else {
                return nil
            }
            return nil
        case .failure:
            return cachedValueIfCurrent(cached, account: account, generation: generation)
        }
    }

    /// Certified backend read. A marker, backend read failure, or backend decode failure is never projected as
    /// either an old value or a confirmed missing key.
    func confirmedString(_ account: String) -> CredentialDurableReadResult {
        lock.lock()
        let needSweep = !didSweepLegacy
        didSweepLegacy = true
        let generation = generations[account] ?? 0
        lock.unlock()

        purgeLegacySlots(for: account, fullSweep: needSweep)
        guard markerAndGenerationAreCurrent(account, generation: generation) else { return .failure }
        let result = readSecure(account)
        guard markerAndGenerationAreCurrent(account, generation: generation) else { return .failure }
        return result
    }

    /// Direct durable read used only by legacy migration. It ignores the non-secret invalidation marker so a
    /// source whose delete was uncertain can still be re-claimed, but it never returns process-only state.
    func durableString(_ account: String) -> CredentialDurableReadResult {
        lock.lock()
        let needSweep = !didSweepLegacy
        didSweepLegacy = true
        lock.unlock()

        purgeLegacySlots(for: account, fullSweep: needSweep)
        return readSecure(account)
    }

    @discardableResult
    func set(_ value: String?, for account: String) -> CredentialMutationResult {
        let transition = beginTransition(account)

        purgeLegacySlots(for: account, fullSweep: transition.needSweep) // UserDefaults I/O, outside the lock
        let accountLock = accountLock(for: account)
        accountLock.lock()
        defer { accountLock.unlock() }
        guard isCurrent(account, generation: transition.generation) else {
            return .failure
        }
        guard markInvalidatedDurably(account) == .success else {
            return finishFailedMutation(value, account: account, generation: transition.generation)
        }
        switch writeSecure(value, account) {                   // SecItem write, serialized per account
        case .success:
            guard mutationReadBackMatches(value, account: account) else { // SecItem read, serialized per account
                return finishFailedMutation(value, account: account, generation: transition.generation)
            }
            return finishSuccessfulMutation(value, account: account, generation: transition.generation)
        case .failure:
            return finishFailedMutation(value, account: account, generation: transition.generation)
        }
    }

    private func mutationReadBackMatches(_ value: String?, account: String) -> Bool {
        switch (value, readSecure(account)) {
        case let (.some(expected), .value(actual)):
            return expected == actual
        case (.none, .missing):
            return true
        default:
            return false
        }
    }

    /// Legacy plaintext-slot cleanup. Runs entirely OUTSIDE the store lock (it does UserDefaults I/O that
    /// posts change notifications — see the deadlock note on `string(_:)`). `fullSweep` is computed once by
    /// the caller under the lock so the whole-store enumeration happens at most once per process.
    private func purgeLegacySlots(for account: String, fullSweep: Bool) {
        if fullSweep { purgeAllLegacy() }
        purgeLegacy(account)
    }
}

enum KeychainSecureItemStatus: Equatable {
    case success
    case notFound
    case failure
}

/// Non-destructive secure-item upsert policy. Existing values are updated in place; an add is attempted only
/// after the backend certifies absence. In particular, an existing tombstone survives an update failure.
enum KeychainSecureItemWriter {
    static func write(
        value: String?,
        update: (String) -> KeychainSecureItemStatus,
        add: (String) -> KeychainSecureItemStatus,
        delete: () -> KeychainSecureItemStatus
    ) -> CredentialMutationResult {
        guard let value else {
            switch delete() {
            case .success, .notFound: return .success
            case .failure: return .failure
            }
        }

        switch update(value) {
        case .success:
            return .success
        case .failure:
            return .failure
        case .notFound:
            return add(value) == .success ? .success : .failure
        }
    }
}

/// Durable owner-only replacement for the macOS credential map. The temporary inode is created 0600 before
/// secret bytes are written, synced, renamed within the same directory, and followed by a directory sync.
/// There is deliberately no fallible permission operation after the rename.
enum KeychainAtomicFileWriter {
    static func persist(
        _ data: Data,
        to fileURL: URL,
        fileManager: FileManager = .default,
        beforeRename: () throws -> Void = {}
    ) -> CredentialMutationResult {
#if canImport(Darwin)
        let directory = fileURL.deletingLastPathComponent()
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            NSLog("%@", "[Keychain] failed to prepare credentials directory: \(error)")
            return .failure
        }

        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            NSLog("%@", "[Keychain] failed to open credentials directory: errno \(errno)")
            return .failure
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        var temporaryExists = false
        var temporaryDescriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard temporaryDescriptor >= 0 else {
            NSLog("%@", "[Keychain] failed to create credentials temporary file: errno \(errno)")
            return .failure
        }
        temporaryExists = true
        defer {
            if temporaryDescriptor >= 0 { _ = Darwin.close(temporaryDescriptor) }
            if temporaryExists {
                temporaryURL.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0,
              writeFully(data, to: temporaryDescriptor),
              sync(temporaryDescriptor) else {
            NSLog("%@", "[Keychain] failed before credentials rename: errno \(errno)")
            return .failure
        }
        let closeResult = Darwin.close(temporaryDescriptor)
        temporaryDescriptor = -1
        guard closeResult == 0 else {
            NSLog("%@", "[Keychain] failed to close credentials temporary file: errno \(errno)")
            return .failure
        }

        do {
            try beforeRename()
        } catch {
            NSLog("%@", "[Keychain] credentials replacement interrupted before rename: \(error)")
            return .failure
        }

        let renamed = temporaryURL.path.withCString { sourcePath in
            fileURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renamed == 0 else {
            NSLog("%@", "[Keychain] failed to replace credentials file: errno \(errno)")
            return .failure
        }
        temporaryExists = false

        guard sync(directoryDescriptor) else {
            NSLog("%@", "[Keychain] failed to sync credentials directory: errno \(errno)")
            return .failure
        }
        return .success
#else
        return .failure
#endif
    }

#if canImport(Darwin)
    private static func writeFully(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func sync(_ descriptor: Int32) -> Bool {
        while Darwin.fsync(descriptor) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }
#endif
}

/// Failure-aware adapter for the macOS plist credential backend. The injected closures make the exact
/// persist/read/decode boundary executable without touching the user's real Application Support file.
final class KeychainFileAdapter: @unchecked Sendable {
    enum FileReadResult {
        case value([String: String])
        case missing
        case failure
    }

    typealias ReadFile = () -> FileReadResult
    typealias PersistFile = (_ values: [String: String]) -> CredentialMutationResult

    private let readFile: ReadFile
    private let persistFile: PersistFile
    private let lock = NSLock()

    init(readFile: @escaping ReadFile, persistFile: @escaping PersistFile) {
        self.readFile = readFile
        self.persistFile = persistFile
    }

    convenience init(fileURL: URL, fileManager: FileManager = .default) {
        self.init(
            readFile: {
                switch KeychainFileAdapter.readOwnerOnlyFile(at: fileURL) {
                case .missing:
                    return .missing
                case .failure:
                    return .failure
                case let .data(data):
                    guard let decoded = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil),
                          let values = decoded as? [String: String] else { return .failure }
                    return .value(values)
                }
            },
            persistFile: { values in
                guard let data = try? PropertyListSerialization.data(
                    fromPropertyList: values, format: .binary, options: 0) else { return .failure }
                return KeychainAtomicFileWriter.persist(
                    data, to: fileURL, fileManager: fileManager)
            })
    }

    private enum OwnerOnlyFileRead {
        case data(Data)
        case missing
        case failure
    }

    private static func readOwnerOnlyFile(at fileURL: URL) -> OwnerOnlyFileRead {
#if canImport(Darwin)
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .failure
        }
        defer { _ = Darwin.close(descriptor) }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else { return .failure }
        let mode = fileStatus.st_mode
        let owner = fileStatus.st_uid
        let effectiveOwner = Darwin.geteuid()
        guard (mode & S_IFMT) == S_IFREG,
              owner == effectiveOwner,
              (mode & 0o077) == 0,
              let data = readAll(from: descriptor) else { return .failure }
        return .data(data)
#else
        return .failure
#endif
    }

#if canImport(Darwin)
    private static func readAll(from descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
    }
#endif

    func read(_ account: String) -> CredentialDurableReadResult {
        lock.lock()
        defer { lock.unlock() }
        switch readFile() {
        case let .value(values):
            return values[account].map(CredentialDurableReadResult.value) ?? .missing
        case .missing:
            return .missing
        case .failure:
            return .failure
        }
    }

    @discardableResult
    func write(_ value: String?, for account: String) -> CredentialMutationResult {
        lock.lock()
        defer { lock.unlock() }

        let current: [String: String]
        switch readFile() {
        case let .value(values): current = values
        case .missing: current = [:]
        case .failure: return .failure
        }
        var next = current
        if let value {
            next[account] = value
        } else {
            next.removeValue(forKey: account)
        }
        return persistFile(next)
    }
}

/// Small-secret store for the Stremio auth token.
///
/// On iOS/tvOS this uses the Keychain (generic password, readable after first unlock, not iCloud-synced).
/// If Security.framework is unavailable, a mutation survives only in process memory and is lost at restart.
/// Legacy plaintext fallback slots are purged on every operation and are never read or written.
///
/// On macOS the app is ad-hoc signed (no Developer ID), so every `SecItem` access against the LOGIN
/// keychain pops the "StremioX wants to use confidential information stored in '…' in your keychain"
/// password prompt; the item's ACL can never match a stable signing identity. To avoid that prompt
/// entirely, macOS stores the SAME accounts in an owner-only file under Application Support instead of
/// the system keychain. The public API is identical across platforms, so no caller changes.
enum Keychain {
    /// Prefix of legacy UserDefaults fallback slots that current builds purge and SettingsBackup filters.
    ///
    /// Declared OUTSIDE the platform `#if`, and non-private, because `SettingsBackup.secretKeyPrefixes` has to
    /// exclude these keys from the synced blob and the backup export on EVERY platform, not just the ones that
    /// used to write them: a token leaked by an old iPhone build travels inside the account's document, so a Mac
    /// still has to refuse to carry or apply one. Single source of truth on purpose, so the exclusion cannot
    /// drift away from the thing it excludes.
    static let fallbackKeyPrefix = "kcfallback."

    /// Legacy device-local defaults marker for an account whose last Keychain mutation was not confirmed.
    ///
    /// Current builds migrate this marker into the secure backend before removing it. The prefix remains public
    /// so SettingsBackup keeps excluding markers written by older builds from sync and export.
    static let invalidationKeyPrefix = "kcinvalidated."

    /// Reserved non-secret records in the same durable backend as credential bytes. Encoding the target account
    /// keeps the namespace unambiguous without placing credential contents in the tombstone.
    static let durableInvalidationAccountPrefix = "vortx.keychain.invalidation.v1."
    static let durableInvalidationSentinel = "invalidated"

    private static func fallbackKey(_ account: String) -> String { fallbackKeyPrefix + account }
    private static func invalidationKey(_ account: String) -> String { invalidationKeyPrefix + account }
    static func durableInvalidationAccount(for account: String) -> String {
        durableInvalidationAccountPrefix + Data(account.utf8).base64EncodedString()
    }

#if os(macOS)
    // MARK: macOS file-backed store (no system keychain, no password prompt)

    /// `~/Library/Application Support/StremioX/credentials.plist`, a `[String: String]` map keyed by
    /// the same account names the Keychain path uses (e.g. "stremiox.authKey",
    /// "stremiox.authKey.<profileID>"). Owner-only: dir 0700, file 0600.
    private static let storeURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("StremioX", isDirectory: true)
            .appendingPathComponent("credentials.plist", isDirectory: false)
    }()

    private static let fileAdapter = KeychainFileAdapter(fileURL: storeURL)

    private static let secureStore = KeychainFailureClosedStore(
        readSecure: { account in fileAdapter.read(account) },
        writeSecure: { value, account in fileAdapter.write(value, for: account) },
        invalidationAccount: { account in durableInvalidationAccount(for: account) },
        invalidationSentinel: durableInvalidationSentinel,
        isLegacyInvalidated: { account in
            UserDefaults.standard.object(forKey: invalidationKey(account)) != nil
        },
        clearLegacyInvalidated: { account in
            UserDefaults.standard.removeObject(forKey: invalidationKey(account))
        },
        purgeAllLegacy: {
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(fallbackKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        },
        purgeLegacy: { account in
            let key = fallbackKey(account)
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    )
#else
    // MARK: iOS / tvOS system Keychain

    private static let secureStore = KeychainFailureClosedStore(
        readSecure: { account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data,
                      let value = String(data: data, encoding: .utf8)
                else { return .failure }
                return .value(value)
            case errSecItemNotFound:
                return .missing
            default:
                return .failure
            }
        },
        writeSecure: { value, account in
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
            ]
            return KeychainSecureItemWriter.write(
                value: value,
                update: { candidate in
                    guard let data = candidate.data(using: .utf8) else { return .failure }
                    let attributes: [String: Any] = [kSecValueData as String: data]
                    switch SecItemUpdate(base as CFDictionary, attributes as CFDictionary) {
                    case errSecSuccess: return .success
                    case errSecItemNotFound: return .notFound
                    default: return .failure
                    }
                },
                add: { candidate in
                    guard let data = candidate.data(using: .utf8) else { return .failure }
                    var add = base
                    add[kSecValueData as String] = data
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? .success : .failure
                },
                delete: {
                    switch SecItemDelete(base as CFDictionary) {
                    case errSecSuccess: return .success
                    case errSecItemNotFound: return .notFound
                    default: return .failure
                    }
                })
        },
        invalidationAccount: { account in durableInvalidationAccount(for: account) },
        invalidationSentinel: durableInvalidationSentinel,
        isLegacyInvalidated: { account in
            UserDefaults.standard.object(forKey: invalidationKey(account)) != nil
        },
        clearLegacyInvalidated: { account in
            UserDefaults.standard.removeObject(forKey: invalidationKey(account))
        },
        purgeAllLegacy: {
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(fallbackKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        },
        purgeLegacy: { account in
            // Only write (and thus post a UserDefaults change notification) when a legacy slot actually
            // exists. On every normal read the slot is already gone, so this stays a pure no-op.
            let key = fallbackKey(account)
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    )

#endif

    /// Compatibility read for existing credential callers. New runtime publication paths use `confirmedString`.
    static func string(_ account: String) -> String? {
        secureStore.string(account)
    }

    /// Direct durable read reserved for recovery and migration repair paths.
    static func durableString(_ account: String) -> CredentialDurableReadResult {
        secureStore.durableString(account)
    }

    /// Certified backend read for runtime consumers that must distinguish failure from missing.
    static func confirmedString(_ account: String) -> CredentialDurableReadResult {
        secureStore.confirmedString(account)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> CredentialMutationResult {
        secureStore.set(value, for: account)
    }
}
