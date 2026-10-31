import CryptoKit
import Darwin
import Foundation

/// A typed opaque filename component. Raw profile/account/PIN/email material never reaches the path.
struct PlaybackTitleQueuePartitionKey: Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    fileprivate var filename: String { "queue-v1-\(rawValue).json" }
}

/// Full live authority stays process-local. Only the SHA-256 partition key derived below reaches storage.
@MainActor
struct PlaybackTitleQueueDurabilityOwner {
    private struct StableDescriptor: Codable {
        let namespace: String
        let profileID: String
        let targetMode: String
        let isOwner: Bool
        let usesOwnAccount: Bool
        let isKids: Bool
        let hasPIN: Bool
        let legacyKeychainAccount: String?
        let legacyUID: String?
    }

    let access: RandomPickUIAccess
    let credential: CredentialScopeRegistry.Capture
    let partition: PlaybackTitleQueuePartitionKey
    private let legacyBinding: PlaybackMutationOwnershipPolicy.SettledAccountBinding?

    static func capture(access: RandomPickUIAccess, profiles: ProfileStore, core: CoreBridge)
        -> PlaybackTitleQueueDurabilityOwner? {
        let credential = CredentialScopeRegistry.shared.capture()
        guard access.isNavigationCurrent(profiles: profiles, core: core),
              access.target.stillOwnsCurrentContext(core: core),
              CredentialScopeRegistry.shared.isCurrent(credential),
              credentialIsEstablished(credential) else { return nil }

        let targetFacts = targetFacts(access: access, credential: credential, profiles: profiles, core: core)
        guard let targetFacts else { return nil }
        let descriptor = StableDescriptor(
            namespace: credential.namespace,
            profileID: access.profile.id.uuidString.lowercased(),
            targetMode: targetFacts.mode,
            isOwner: access.profile.isOwner,
            usesOwnAccount: access.profile.usesOwnAccount,
            isKids: access.profile.isKids,
            hasPIN: access.profile.hasPin,
            legacyKeychainAccount: targetFacts.legacyAccount,
            legacyUID: targetFacts.legacyUID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(descriptor) else { return nil }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard let partition = PlaybackTitleQueuePartitionKey(rawValue: digest) else { return nil }
        return .init(access: access, credential: credential, partition: partition,
                     legacyBinding: targetFacts.binding)
    }

    func isCurrent(profiles: ProfileStore, core: CoreBridge) -> Bool {
        guard access.isNavigationCurrent(profiles: profiles, core: core),
              access.target.stillOwnsCurrentContext(core: core),
              CredentialScopeRegistry.shared.isCurrent(credential),
              Self.credentialIsEstablished(credential),
              let current = Self.targetFacts(access: access, credential: credential,
                                             profiles: profiles, core: core) else { return false }
        return current.binding == legacyBinding
    }

    private static func credentialIsEstablished(_ credential: CredentialScopeRegistry.Capture) -> Bool {
        switch credential.scope {
        case .signedOutDevice:
            return CredentialScopeRegistry.shared.isCurrent(credential)
        case .account:
            return CredentialScopeRegistry.shared.isMigrationEligible(credential)
        }
    }

    private static func targetFacts(
        access: RandomPickUIAccess,
        credential: CredentialScopeRegistry.Capture,
        profiles: ProfileStore,
        core: CoreBridge
    ) -> (mode: String, legacyAccount: String?, legacyUID: String?,
          binding: PlaybackMutationOwnershipPolicy.SettledAccountBinding?)? {
        switch access.target {
        case .native(let binding?):
            guard binding.profileID == access.profile.id,
                  binding.credential == credential,
                  binding.accountGeneration != nil else { return nil }
            return ("native", nil, nil, nil)

        case .native(nil):
            return nil

        case .engine(let profileID, let keychainAccount, let uid, let historyCapture):
            guard profileID == access.profile.id,
                  profiles.activeID == access.profile.id,
                  profiles.activeKeychainAccount == keychainAccount,
                  historyCapture == Optional(credential) else { return nil }
            switch credential.scope {
            case .account:
                guard let uid,
                      let binding = core.settledActiveAccountBinding(),
                      binding.profileID == access.profile.id,
                      binding.keychainAccount == keychainAccount,
                      binding.uid == uid else { return nil }
                return ("legacy-engine", keychainAccount, uid, binding)
            case .signedOutDevice:
                guard uid == nil else { return nil }
                return ("legacy-engine-signed-out", keychainAccount, nil, nil)
            }

        case .overlay(let profileID):
            guard profileID == access.profile.id, profiles.activeID == profileID else { return nil }
            return ("legacy-overlay", nil, nil, nil)
        }
    }
}

enum PlaybackTitleQueuePersistencePhase: Equatable {
    case inactive
    case restoring
    case ready
    case saving(Int)
    case saved
    case failed(String)

    var allowsEditing: Bool {
        switch self {
        case .ready, .saving, .saved: return true
        case .inactive, .restoring, .failed: return false
        }
    }
}

/// One bounded serial lane for reads and writes. Jobs retain their original key, expected bytes, and payload;
/// switching owners can suppress a callback but can never retarget an already accepted write.
@MainActor
final class PlaybackTitleQueueDurability {
    static let maximumPendingWrites = 32

    struct Attachment: Hashable {
        let id: UUID
        let key: PlaybackTitleQueuePartitionKey
    }

    enum Event {
        case restored(attachment: Attachment, entries: [PlaybackTitleQueuePolicy.Entry], existed: Bool)
        case phase(attachment: Attachment, PlaybackTitleQueuePersistencePhase)
    }

    enum Admission {
        case accepted(PlaybackTitleQueuePersistencePhase)
        case rejected(String)
    }

    private enum Baseline: Equatable, Sendable {
        case missing
        case bytes(data: Data, sha256: String)

        static func bytes(_ data: Data) -> Baseline {
            .bytes(data: data, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    private struct KeyState {
        var certified: Baseline?
        var projected: Baseline?
        var pendingWrites = 0
        var loadFailure: String?
    }

    private struct LoadJob: Sendable {
        let attachmentID: UUID
        let key: PlaybackTitleQueuePartitionKey
    }

    private struct WriteIntent: Sendable {
        let id: UUID
        let attachmentID: UUID
        let key: PlaybackTitleQueuePartitionKey
        let expectedBefore: Baseline
        let payload: Data
    }

    private enum Job: Sendable {
        case load(LoadJob)
        case write(WriteIntent)

        var key: PlaybackTitleQueuePartitionKey {
            switch self {
            case .load(let job): return job.key
            case .write(let intent): return intent.key
            }
        }
    }

    private enum WorkResult: Sendable {
        case loaded(Baseline, [PlaybackTitleQueuePolicy.Entry], existed: Bool)
        case wrote
        case failed(String)
    }

    private let eventSink: @MainActor (Event) -> Void
    private var states: [PlaybackTitleQueuePartitionKey: KeyState] = [:]
    private var jobs: [Job] = []
    private var failedWrites: [PlaybackTitleQueuePartitionKey: WriteIntent] = [:]
    private var readyAttachments: [UUID: PlaybackTitleQueuePartitionKey] = [:]
    private var activeAttachments = Set<UUID>()
    private var outstandingWrites = 0
    private var drainTask: Task<Void, Never>?

    init(eventSink: @escaping @MainActor (Event) -> Void) {
        self.eventSink = eventSink
    }

    func attach(_ owner: PlaybackTitleQueueDurabilityOwner) -> (Attachment, PlaybackTitleQueuePersistencePhase) {
        let attachment = Attachment(id: UUID(), key: owner.partition)
        let state = states[owner.partition] ?? KeyState()
        activeAttachments.insert(attachment.id)
        if let failure = state.loadFailure {
            states[owner.partition] = state
            return (attachment, .failed(failure))
        }
        let load = Job.load(.init(attachmentID: attachment.id, key: attachment.key))
        jobs.append(load)
        states[owner.partition] = state
        startDrainIfNeeded()
        if failedWrites[owner.partition] != nil {
            return (attachment, .failed(StoreFailure.blockedByEarlierWrite.message))
        }
        return (attachment, .restoring)
    }

    /// Stop UI publication/admission for this attachment without cancelling immutable accepted jobs.
    func detach(_ attachment: Attachment) {
        activeAttachments.remove(attachment.id)
        readyAttachments.removeValue(forKey: attachment.id)
        // A detached read has no durable intent. Keep a running read and every accepted write intact.
        jobs.removeAll { job in
            if case .load(let load) = job { return load.attachmentID == attachment.id }
            return false
        }
        if states[attachment.key]?.pendingWrites == 0, failedWrites[attachment.key] == nil {
            states.removeValue(forKey: attachment.key)
        }
    }

    func canUseAttachment(_ attachment: Attachment) -> Bool {
        activeAttachments.contains(attachment.id)
            && readyAttachments[attachment.id] == attachment.key
            && failedWrites[attachment.key] == nil
            && states[attachment.key]?.loadFailure == nil
            && states[attachment.key]?.projected != nil
    }

    func canAcceptWrite(for attachment: Attachment) -> Bool {
        canUseAttachment(attachment) && outstandingWrites < Self.maximumPendingWrites
    }

    /// The caller supplies a canonically encoded value transaction. Admission appends its immutable write
    /// before the caller replaces live policy or performs route/token side effects.
    func admit(_ prepared: PlaybackTitleQueuePreparedMutation,
               attachment: Attachment,
               owner: PlaybackTitleQueueDurabilityOwner) -> Admission {
        guard attachment.key == owner.partition, owner.isCurrent(profiles: .shared, core: .shared),
              canUseAttachment(attachment), var state = states[attachment.key],
              let expected = state.projected else {
            return .rejected(StoreFailure.ownerOrAdmissionChanged.message)
        }
        let payload = prepared.payload
        guard !payload.isEmpty, payload.count <= PlaybackTitleQueueArchiveCodec.maximumBytes,
              let decoded = try? PlaybackTitleQueueArchiveCodec.decode(payload),
              decoded == prepared.policy.durableEntries else {
            return .rejected(StoreFailure.invalidPayload.message)
        }
        guard owner.isCurrent(profiles: .shared, core: .shared) else {
            return .rejected(StoreFailure.ownerOrAdmissionChanged.message)
        }
        switch PlaybackTitleQueueWriteAdmissionPolicy.decide(
            payloadMatchesProjected: expected == .bytes(payload),
            payloadMatchesCertified: state.certified == .bytes(payload),
            partitionPending: state.pendingWrites,
            totalPending: outstandingWrites,
            capacity: Self.maximumPendingWrites
        ) {
        case .reusePending(let count):
            return .accepted(.saving(count)) // Runtime-only transition; do not reset pending writes or claim saved.
        case .reuseSaved:
            return .accepted(.saved)
        case .reject:
            return .rejected(StoreFailure.ownerOrAdmissionChanged.message)
        case .appendWrite:
            break
        }
        let intent = WriteIntent(id: UUID(), attachmentID: attachment.id, key: attachment.key,
                                 expectedBefore: expected, payload: payload)
        state.projected = .bytes(payload)
        state.pendingWrites += 1
        state.loadFailure = nil
        states[attachment.key] = state
        outstandingWrites += 1
        jobs.append(.write(intent))
        startDrainIfNeeded()
        return .accepted(.saving(state.pendingWrites))
    }

    func retry(_ attachment: Attachment) -> PlaybackTitleQueuePersistencePhase {
        guard activeAttachments.contains(attachment.id) else {
            return .failed(StoreFailure.ownerOrAdmissionChanged.message)
        }
        if let failed = failedWrites.removeValue(forKey: attachment.key) {
            jobs.insert(.write(failed), at: 0)
            startDrainIfNeeded()
            return .saving(states[attachment.key]?.pendingWrites ?? 1)
        }
        guard var state = states[attachment.key] else { return .restoring }
        if state.loadFailure != nil {
            state.loadFailure = nil
            state.certified = nil
            state.projected = nil
            states[attachment.key] = state
            readyAttachments.removeValue(forKey: attachment.id)
            jobs.append(.load(.init(attachmentID: attachment.id, key: attachment.key)))
            startDrainIfNeeded()
            return .restoring
        }
        if state.pendingWrites > 0 { return .saving(state.pendingWrites) }
        return state.certified == nil ? .ready : .saved
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, firstRunnableJobIndex() != nil else { return }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    private func firstRunnableJobIndex() -> Int? {
        jobs.firstIndex { failedWrites[$0.key] == nil }
    }

    private func drain() async {
        while let index = firstRunnableJobIndex() {
            let job = jobs.remove(at: index)
            let result = await Task.detached(priority: .utility) {
                Self.perform(job)
            }.value
            handle(job, result: result)
        }
        drainTask = nil
        if firstRunnableJobIndex() != nil { startDrainIfNeeded() }
    }

    nonisolated private static func perform(_ job: Job) -> WorkResult {
        switch job {
        case .load(let load):
            return PlaybackTitleQueueDiskStore.load(load.key)
        case .write(let intent):
            return PlaybackTitleQueueDiskStore.write(
                key: intent.key, expectedBefore: intent.expectedBefore, payload: intent.payload
            )
        }
    }

    private func handle(_ job: Job, result: WorkResult) {
        if case .load(let load) = job, !activeAttachments.contains(load.attachmentID) {
            // A completed stale read cannot repopulate cached data or publish into a returning attachment.
            if states[load.key]?.pendingWrites == 0, failedWrites[load.key] == nil {
                states.removeValue(forKey: load.key)
            }
            return
        }
        switch (job, result) {
        case (.load(let load), .loaded(let baseline, let entries, let existed)):
            var state = states[load.key] ?? KeyState()
            guard state.pendingWrites == 0 else {
                state.loadFailure = StoreFailure.orderingViolation.message
                states[load.key] = state
                eventSink(.phase(attachment: .init(id: load.attachmentID, key: load.key),
                                 .failed(StoreFailure.orderingViolation.message)))
                return
            }
            state.certified = baseline
            state.projected = baseline
            state.loadFailure = nil
            states[load.key] = state
            if activeAttachments.contains(load.attachmentID) {
                readyAttachments[load.attachmentID] = load.key
            }
            eventSink(.restored(attachment: .init(id: load.attachmentID, key: load.key),
                                entries: entries, existed: existed))

        case (.load(let load), .failed(let message)):
            var state = states[load.key] ?? KeyState()
            state.certified = nil
            state.projected = nil
            state.loadFailure = message
            states[load.key] = state
            readyAttachments.removeValue(forKey: load.attachmentID)
            eventSink(.phase(attachment: .init(id: load.attachmentID, key: load.key), .failed(message)))

        case (.write(let intent), .wrote):
            var state = states[intent.key] ?? KeyState()
            state.certified = .bytes(intent.payload)
            state.pendingWrites = max(0, state.pendingWrites - 1)
            if state.pendingWrites == 0 { state.projected = .bytes(intent.payload) }
            if state.pendingWrites == 0,
               !activeAttachments.contains(intent.attachmentID),
               !readyAttachments.values.contains(intent.key),
               failedWrites[intent.key] == nil {
                // The accepted save is complete, but its old UI no longer owns this partition.
                // A returning attachment is still restoring behind these writes and reads disk afresh.
                // Decide before eventSink: its synchronous callback may attach or detach another owner.
                states.removeValue(forKey: intent.key)
            } else {
                states[intent.key] = state
            }
            outstandingWrites = max(0, outstandingWrites - 1)
            let phase: PlaybackTitleQueuePersistencePhase =
                state.pendingWrites == 0 ? .saved : .saving(state.pendingWrites)
            eventSink(.phase(attachment: .init(id: intent.attachmentID, key: intent.key), phase))

        case (.write(let intent), .failed(let message)):
            failedWrites[intent.key] = intent
            eventSink(.phase(attachment: .init(id: intent.attachmentID, key: intent.key), .failed(message)))
            // A returned A attachment may already be waiting behind this immutable failed A write.
            for queued in jobs {
                guard case .load(let load) = queued, load.key == intent.key else { continue }
                eventSink(.phase(attachment: .init(id: load.attachmentID, key: load.key),
                                 .failed(StoreFailure.blockedByEarlierWrite.message)))
            }

        case (.load(let load), .wrote):
            var state = states[load.key] ?? KeyState()
            state.loadFailure = StoreFailure.orderingViolation.message
            states[load.key] = state
            eventSink(.phase(attachment: .init(id: load.attachmentID, key: load.key),
                             .failed(StoreFailure.orderingViolation.message)))

        case (.write(let intent), .loaded):
            failedWrites[intent.key] = intent
            eventSink(.phase(attachment: .init(id: intent.attachmentID, key: intent.key),
                             .failed(StoreFailure.orderingViolation.message)))
        }
    }

    private enum StoreFailure: Sendable {
        case unavailableDirectory
        case unsafePath
        case lockBusy
        case oversizedArchive
        case unreadableArchive
        case unexpectedExistingBytes
        case writeFailed
        case readbackFailed
        case blockedByEarlierWrite
        case invalidPayload
        case ownerOrAdmissionChanged
        case orderingViolation

        var message: String {
            switch self {
            case .unavailableDirectory:
                return "We couldn’t open this device’s queue storage. Nothing was replaced."
            case .unsafePath:
                return "Queue storage could not be used safely. Nothing was replaced."
            case .lockBusy:
                return "Another VortX window is saving this queue. Try again."
            case .oversizedArchive:
                return "The saved queue on this device is too large to open. It was left unchanged."
            case .unreadableArchive:
                return "We couldn’t open the saved queue on this device. It was left unchanged."
            case .unexpectedExistingBytes:
                return "The saved queue changed unexpectedly. Nothing was overwritten."
            case .writeFailed:
                return "We couldn’t save the queue on this device. Retry saving before editing."
            case .readbackFailed:
                return "We couldn’t confirm the queue was saved. Retry saving before editing."
            case .blockedByEarlierWrite:
                return "An earlier queue save failed. Later changes are waiting for a retry."
            case .invalidPayload:
                return "We couldn’t prepare that queue change for saving. Nothing was written."
            case .ownerOrAdmissionChanged:
                return "The profile or playback session changed before this queue edit could be saved."
            case .orderingViolation:
                return "We couldn’t keep queue saves in order. Nothing further was written."
            }
        }
    }

    /// Every current VortX process uses this immutable per-partition lock contract. The lock file is never
    /// unlinked, and the exclusive lock remains held across read/compare/replace/readback. A same-UID process
    /// that deliberately ignores this contract remains outside the supported coordination model.
    private enum PlaybackTitleQueueDiskStore {
        private static let directoryName = ".vortx-playback-queues"
        private static let privateDirectoryMode = mode_t(0o700)
        private static let privateFileMode = mode_t(0o600)
        private static let permissionMask = mode_t(0o7777)

        private struct Directory {
            let supportURL: URL
            let supportFD: Int32
            let queueFD: Int32
        }

        private struct Lock {
            let fd: Int32
            let name: String
        }

        private struct StoreFailureError: Error {
            let failure: StoreFailure
        }

        static func load(_ key: PlaybackTitleQueuePartitionKey) -> WorkResult {
            do {
                return try withLockedDirectory(key) { directory, _ in
                    let baseline = try readExisting(key, in: directory)
                    switch baseline {
                    case .missing:
                        return .loaded(.missing, [], existed: false)
                    case .bytes(let data, _):
                        let entries: [PlaybackTitleQueuePolicy.Entry]
                        do {
                            entries = try PlaybackTitleQueueArchiveCodec.decode(data)
                        } catch let failure as PlaybackTitleQueueArchiveCodec.Failure {
                            throw StoreFailureError(failure: failure == .oversized
                                ? .oversizedArchive : .unreadableArchive)
                        } catch {
                            throw StoreFailureError(failure: .unreadableArchive)
                        }
                        return .loaded(baseline, entries, existed: true)
                    }
                }
            } catch let failure as StoreFailureError {
                return .failed(failure.failure.message)
            } catch {
                return .failed(StoreFailure.unreadableArchive.message)
            }
        }

        static func write(key: PlaybackTitleQueuePartitionKey,
                          expectedBefore: Baseline,
                          payload: Data) -> WorkResult {
            guard !payload.isEmpty, payload.count <= PlaybackTitleQueueArchiveCodec.maximumBytes else {
                return .failed(StoreFailure.invalidPayload.message)
            }
            do {
                return try withLockedDirectory(key) { directory, lock in
                    let current = try readExisting(key, in: directory)
                    // A prior attempt may have installed the immutable payload before reporting an uncertain
                    // sync/readback. Exact bytes can be confirmed without replacing them.
                    if current == .bytes(payload) {
                        try verifyDirectory(directory)
                        try verifyLock(lock, in: directory)
                        try sync(directory.queueFD, failure: .readbackFailed)
                        return .wrote
                    }
                    guard current == expectedBefore else {
                        throw StoreFailureError(failure: .unexpectedExistingBytes)
                    }
                    try install(
                        payload, key: key, expectedBefore: expectedBefore,
                        directory: directory, lock: lock
                    )
                    return .wrote
                }
            } catch let failure as StoreFailureError {
                return .failed(failure.failure.message)
            } catch {
                return .failed(StoreFailure.writeFailed.message)
            }
        }

        private static func withLockedDirectory<T>(
            _ key: PlaybackTitleQueuePartitionKey,
            operation: (Directory, Lock) throws -> T
        ) throws -> T {
            try withDirectory { directory in
                let lock = try acquireLock(key, in: directory)
                defer {
                    while systemFileLock(lock.fd, LOCK_UN) != 0 && errno == EINTR {}
                    _ = Darwin.close(lock.fd)
                }
                try verifyDirectory(directory)
                try verifyLock(lock, in: directory)
                let result = try operation(directory, lock)
                try verifyLock(lock, in: directory)
                try verifyDirectory(directory)
                return result
            }
        }

        private static func withDirectory<T>(_ operation: (Directory) throws -> T) throws -> T {
            let supportURL: URL
            do {
                #if os(tvOS)
                // Physical Apple TV uses the app's writable Caches root; the system may purge it.
                let storageRoot: FileManager.SearchPathDirectory = .cachesDirectory
                #else
                let storageRoot: FileManager.SearchPathDirectory = .applicationSupportDirectory
                #endif
                supportURL = try FileManager.default.url(
                    for: storageRoot,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            } catch {
                throw StoreFailureError(failure: .unavailableDirectory)
            }

            let supportFD = supportURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard supportFD >= 0 else {
                throw StoreFailureError(failure: .unavailableDirectory)
            }
            var queueFD: Int32 = -1
            defer {
                if queueFD >= 0 { _ = Darwin.close(queueFD) }
                _ = Darwin.close(supportFD)
            }

            var openedSupport = stat()
            var namedSupport = stat()
            guard Darwin.fstat(supportFD, &openedSupport) == 0,
                  supportURL.path.withCString({ Darwin.lstat($0, &namedSupport) }) == 0,
                  sameInode(openedSupport, namedSupport),
                  isDirectory(openedSupport),
                  openedSupport.st_uid == geteuid() else {
                throw StoreFailureError(failure: .unsafePath)
            }

            let created = directoryName.withCString {
                Darwin.mkdirat(supportFD, $0, privateDirectoryMode)
            } == 0
            if !created && errno != EEXIST {
                throw StoreFailureError(failure: .unavailableDirectory)
            }
            queueFD = directoryName.withCString {
                Darwin.openat(
                    supportFD, $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard queueFD >= 0 else {
                throw StoreFailureError(failure: .unsafePath)
            }

            let directory = Directory(
                supportURL: supportURL,
                supportFD: supportFD,
                queueFD: queueFD
            )
            try verifyDirectory(directory)
            if created {
                try sync(supportFD, failure: .unavailableDirectory)
            }
            return try operation(directory)
        }

        private static func acquireLock(
            _ key: PlaybackTitleQueuePartitionKey,
            in directory: Directory
        ) throws -> Lock {
            // This name deliberately has no schema/version component. Future durable formats for this
            // partition must acquire the same file before observing or replacing queue bytes.
            let name = "playback-queue-\(key.rawValue).lock"
            let fd = name.withCString {
                Darwin.openat(
                    directory.queueFD, $0,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    privateFileMode
                )
            }
            guard fd >= 0 else {
                throw StoreFailureError(failure: errno == ELOOP ? .unsafePath : .unavailableDirectory)
            }
            var keepOpen = false
            defer { if !keepOpen { _ = Darwin.close(fd) } }
            let lock = Lock(fd: fd, name: name)
            try verifyLock(lock, in: directory)

            var result: Int32
            repeat {
                result = systemFileLock(fd, LOCK_EX | LOCK_NB)
            } while result != 0 && errno == EINTR
            guard result == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw StoreFailureError(failure: .lockBusy)
                }
                throw StoreFailureError(failure: .unsafePath)
            }
            do {
                try verifyDirectory(directory)
                try verifyLock(lock, in: directory)
                try sync(fd, failure: .unavailableDirectory)
                try sync(directory.queueFD, failure: .unavailableDirectory)
            } catch {
                while systemFileLock(fd, LOCK_UN) != 0 && errno == EINTR {}
                throw error
            }
            keepOpen = true
            return lock
        }

        private static func install(
            _ payload: Data,
            key: PlaybackTitleQueuePartitionKey,
            expectedBefore: Baseline,
            directory: Directory,
            lock: Lock
        ) throws {
            let temp = try createTemp(key, in: directory)
            var installed = false
            var closed = false
            defer {
                if !installed {
                    cleanupFreshTemp(temp, in: directory)
                }
                if !closed { _ = Darwin.close(temp.fd) }
            }

            try writeAll(payload, to: temp.fd)
            try sync(temp.fd, failure: .writeFailed)
            try verifyPrivateRegular(
                descriptor: temp.fd,
                named: temp.name,
                in: directory,
                expectedSize: off_t(payload.count)
            )

            // Re-read under the same cooperating-process lock immediately before replacement. Unknown or
            // changed bytes are preserved. This is not a filesystem CAS against a hostile same-UID process.
            guard try readExisting(key, in: directory) == expectedBefore else {
                throw StoreFailureError(failure: .unexpectedExistingBytes)
            }
            try verifyDirectory(directory)
            try verifyLock(lock, in: directory)
            let renamed = temp.name.withCString { tempName in
                key.filename.withCString { finalName in
                    Darwin.renameat(directory.queueFD, tempName, directory.queueFD, finalName)
                }
            }
            guard renamed == 0 else {
                throw StoreFailureError(failure: .writeFailed)
            }
            installed = true

            try verifyPrivateRegular(
                descriptor: temp.fd,
                named: key.filename,
                in: directory,
                expectedSize: off_t(payload.count)
            )
            guard try readExisting(key, in: directory) == .bytes(payload) else {
                throw StoreFailureError(failure: .readbackFailed)
            }
            try verifyLock(lock, in: directory)
            try verifyDirectory(directory)
            try sync(directory.queueFD, failure: .readbackFailed)

            let closeResult = Darwin.close(temp.fd)
            closed = true
            guard closeResult == 0 else {
                throw StoreFailureError(failure: .readbackFailed)
            }
        }

        private struct Temp {
            let fd: Int32
            let name: String
        }

        private static func createTemp(
            _ key: PlaybackTitleQueuePartitionKey,
            in directory: Directory
        ) throws -> Temp {
            for _ in 0..<4 {
                let name = ".queue-\(key.rawValue).\(UUID().uuidString.lowercased()).tmp"
                let fd = name.withCString {
                    Darwin.openat(
                        directory.queueFD, $0,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                        privateFileMode
                    )
                }
                if fd >= 0 {
                    let temp = Temp(fd: fd, name: name)
                    do {
                        try verifyPrivateRegular(
                            descriptor: fd,
                            named: name,
                            in: directory,
                            expectedSize: 0
                        )
                        return temp
                    } catch {
                        cleanupFreshTemp(temp, in: directory)
                        _ = Darwin.close(fd)
                        throw error
                    }
                }
                if errno != EEXIST {
                    throw StoreFailureError(failure: .writeFailed)
                }
            }
            throw StoreFailureError(failure: .writeFailed)
        }

        private static func cleanupFreshTemp(_ temp: Temp, in directory: Directory) {
            // Only the exact inode exclusively created by this invocation may be removed.
            guard (try? verifyDirectory(directory)) != nil,
                  (try? verifyPrivateRegular(
                    descriptor: temp.fd,
                    named: temp.name,
                    in: directory,
                    expectedSize: nil
                  )) != nil else { return }
            _ = temp.name.withCString {
                Darwin.unlinkat(directory.queueFD, $0, 0)
            }
            try? sync(directory.queueFD, failure: .writeFailed)
        }

        private static func readExisting(
            _ key: PlaybackTitleQueuePartitionKey,
            in directory: Directory
        ) throws -> Baseline {
            try verifyDirectory(directory)
            let fd = key.filename.withCString {
                Darwin.openat(
                    directory.queueFD, $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            if fd < 0 {
                let openError = errno
                if openError == ENOENT {
                    var named = stat()
                    let lookup = key.filename.withCString {
                        Darwin.fstatat(directory.queueFD, $0, &named, AT_SYMLINK_NOFOLLOW)
                    }
                    let lookupError = errno
                    if lookup < 0 && lookupError == ENOENT {
                        try verifyDirectory(directory)
                        return .missing
                    }
                }
                if openError == ELOOP || openError == ENOTDIR {
                    throw StoreFailureError(failure: .unsafePath)
                }
                throw StoreFailureError(failure: .unreadableArchive)
            }
            defer { _ = Darwin.close(fd) }

            var before = stat()
            var namedBefore = stat()
            guard Darwin.fstat(fd, &before) == 0,
                  isPrivateRegular(before),
                  before.st_nlink == 1,
                  key.filename.withCString({
                      Darwin.fstatat(directory.queueFD, $0, &namedBefore, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  sameInode(before, namedBefore),
                  isPrivateRegular(namedBefore),
                  namedBefore.st_nlink == 1 else {
                throw StoreFailureError(failure: .unsafePath)
            }
            guard before.st_size >= 0 else {
                throw StoreFailureError(failure: .unsafePath)
            }
            guard before.st_size <= off_t(PlaybackTitleQueueArchiveCodec.maximumBytes) else {
                throw StoreFailureError(failure: .oversizedArchive)
            }

            let expectedCount = Int(before.st_size)
            var buffer = Data(count: expectedCount + 1)
            var count = 0
            try buffer.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw StoreFailureError(failure: .unreadableArchive)
                }
                while count < bytes.count {
                    let readCount = Darwin.read(
                        fd, base.advanced(by: count), bytes.count - count
                    )
                    if readCount < 0 && errno == EINTR { continue }
                    guard readCount >= 0 else {
                        throw StoreFailureError(failure: .unreadableArchive)
                    }
                    if readCount == 0 { break }
                    count += readCount
                }
            }
            guard count == expectedCount else {
                throw StoreFailureError(
                    failure: count > expectedCount ? .oversizedArchive : .unreadableArchive
                )
            }

            var after = stat()
            var namedAfter = stat()
            guard Darwin.fstat(fd, &after) == 0,
                  stableSnapshot(before, after),
                  key.filename.withCString({
                      Darwin.fstatat(directory.queueFD, $0, &namedAfter, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  sameInode(after, namedAfter),
                  isPrivateRegular(namedAfter),
                  namedAfter.st_nlink == 1 else {
                throw StoreFailureError(failure: .unreadableArchive)
            }
            try verifyDirectory(directory)
            return .bytes(Data(buffer.prefix(expectedCount)))
        }

        private static func verifyDirectory(_ directory: Directory) throws {
            var openedSupport = stat()
            var namedSupport = stat()
            var openedQueue = stat()
            var namedQueue = stat()
            guard Darwin.fstat(directory.supportFD, &openedSupport) == 0,
                  directory.supportURL.path.withCString({
                      Darwin.lstat($0, &namedSupport)
                  }) == 0,
                  sameInode(openedSupport, namedSupport),
                  isDirectory(openedSupport),
                  openedSupport.st_uid == geteuid(),
                  Darwin.fstat(directory.queueFD, &openedQueue) == 0,
                  directoryName.withCString({
                      Darwin.fstatat(
                        directory.supportFD, $0, &namedQueue, AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  sameInode(openedQueue, namedQueue),
                  isDirectory(openedQueue),
                  isDirectory(namedQueue),
                  openedQueue.st_uid == geteuid(),
                  namedQueue.st_uid == geteuid(),
                  openedQueue.st_mode & permissionMask == privateDirectoryMode,
                  namedQueue.st_mode & permissionMask == privateDirectoryMode else {
                throw StoreFailureError(failure: .unsafePath)
            }
        }

        private static func verifyLock(_ lock: Lock, in directory: Directory) throws {
            try verifyPrivateRegular(
                descriptor: lock.fd,
                named: lock.name,
                in: directory,
                expectedSize: 0
            )
        }

        private static func verifyPrivateRegular(
            descriptor: Int32,
            named name: String,
            in directory: Directory,
            expectedSize: off_t?
        ) throws {
            var opened = stat()
            var named = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  name.withCString({
                      Darwin.fstatat(directory.queueFD, $0, &named, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  sameInode(opened, named),
                  isPrivateRegular(opened),
                  isPrivateRegular(named),
                  opened.st_nlink == 1,
                  named.st_nlink == 1,
                  expectedSize.map({ opened.st_size == $0 && named.st_size == $0 }) ?? true else {
                throw StoreFailureError(failure: .unsafePath)
            }
        }

        private static func writeAll(_ data: Data, to descriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw StoreFailureError(failure: .writeFailed)
                }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        min(64 * 1024, bytes.count - offset)
                    )
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else {
                        throw StoreFailureError(failure: .writeFailed)
                    }
                    offset += written
                }
            }
        }

        private static func sync(_ descriptor: Int32, failure: StoreFailure) throws {
            while Darwin.fsync(descriptor) != 0 {
                if errno != EINTR {
                    throw StoreFailureError(failure: failure)
                }
            }
        }

        private static func sameInode(_ first: stat, _ second: stat) -> Bool {
            first.st_dev == second.st_dev && first.st_ino == second.st_ino
        }

        private static func isDirectory(_ value: stat) -> Bool {
            value.st_mode & S_IFMT == S_IFDIR
        }

        private static func isPrivateRegular(_ value: stat) -> Bool {
            value.st_mode & S_IFMT == S_IFREG
                && value.st_uid == geteuid()
                && value.st_mode & permissionMask == privateFileMode
        }

        private static func stableSnapshot(_ first: stat, _ second: stat) -> Bool {
            sameInode(first, second)
                && first.st_size == second.st_size
                && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
                && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
                && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
                && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
        }
    }

}

/// libc flock(2). Current SDKs resolve `Darwin.flock` to the `struct flock` record even with a
/// contextual function type, so bind the C symbol directly.
@_silgen_name("flock")
private func systemFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32
