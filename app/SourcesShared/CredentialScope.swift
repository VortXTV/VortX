import CryptoKit
import Foundation

/// The only owner identity accepted by credential-bearing state.
///
/// Remote accounts use one canonical spelling: a lowercase, hyphenated UUID.
/// Inputs that Foundation can parse but that are not canonical are rejected so
/// two textual identities cannot address the same credential namespace.
enum CredentialScope: Equatable, Hashable, Sendable {
    case signedOutDevice
    case account(UUID)

    init?(canonicalRemoteAccountID rawValue: String) {
        guard
            let uuid = UUID(uuidString: rawValue),
            rawValue == uuid.uuidString.lowercased()
        else {
            return nil
        }
        self = .account(uuid)
    }

    var storageNamespace: String {
        switch self {
        case .signedOutDevice:
            return "signed-out-device"
        case .account(let id):
            return "account.\(id.uuidString.lowercased())"
        }
    }
}

/// Injectable owner-scoped token storage. Production uses Keychain; race tests use a lock-backed in-memory
/// implementation so a failed guard remains observable even when simulator Keychain entitlements are absent.
struct CredentialTokenStorage: Sendable {
    let read: @Sendable (_ account: String, _ migrationGroup: String, _ scope: CredentialScope) -> String?
    let write: @Sendable (_ value: String?, _ account: String, _ scope: CredentialScope) -> Bool

    static let keychain = CredentialTokenStorage(
        read: { account, migrationGroup, scope in
            CredentialScopedKeychain.string(account, migrationGroup: migrationGroup, scope: scope)
        },
        write: { value, account, scope in
            CredentialScopedKeychain.set(value, for: account, scope: scope)
        }
    )
}

enum CredentialMutationDomain: String, CaseIterable, Sendable {
    case vortxAccount
    case trakt
    case simkl
    case stremio
    case debrid
    case apiKeys
    case mediaServers
    case iptv
    case profileSync
}

enum CredentialOperationDomain: String, CaseIterable, Sendable {
    case vortxRegister
    case vortxSignIn
    case vortxRecovery
    case vortxQR
    case traktDevicePoll
    case traktRefresh
    case traktRecovery
    case traktDisconnect
    case simklPinPoll
    case simklDisconnect
    case stremioSignIn
    case stremioLogout
    case coreCatalogMutation
    case profileSync

    fileprivate var family: CredentialMutationDomain {
        switch self {
        case .vortxRegister, .vortxSignIn, .vortxRecovery, .vortxQR:
            return .vortxAccount
        case .traktDevicePoll, .traktRefresh, .traktRecovery, .traktDisconnect:
            return .trakt
        case .simklPinPoll, .simklDisconnect:
            return .simkl
        case .stremioSignIn, .stremioLogout, .coreCatalogMutation:
            return .stremio
        case .profileSync:
            return .profileSync
        }
    }
}

struct CredentialScopeStamp: Equatable, Sendable {
    let scope: CredentialScope
    let generation: UInt64
}

struct CredentialOperationStamp: Equatable, Sendable {
    let domain: CredentialOperationDomain
    let familyGeneration: UInt64
    let scope: CredentialScopeStamp
}

struct CredentialStremioSlotStamp: Equatable, Sendable {
    let profileID: UUID
    let account: String
    let generation: UInt64
    let scope: CredentialScopeStamp
}

struct CredentialDocumentStamp: Equatable, Sendable {
    let version: Int
    let digest: String
    let generation: UInt64
    let scope: CredentialScopeStamp
    let stremioSlot: CredentialStremioSlotStamp?
}

struct CredentialCommitStamp: Equatable, Sendable {
    let scope: CredentialScopeStamp
    let stremioSlot: CredentialStremioSlotStamp?
    let document: CredentialDocumentStamp?
    let operation: CredentialOperationStamp?

    init(scope: CredentialScopeStamp) {
        self.scope = scope
        stremioSlot = nil
        document = nil
        operation = nil
    }

    init(operation: CredentialOperationStamp) {
        scope = operation.scope
        stremioSlot = nil
        document = nil
        self.operation = operation
    }

    init(document: CredentialDocumentStamp) {
        scope = document.scope
        stremioSlot = document.stremioSlot
        self.document = document
        operation = nil
    }

    init(
        scope: CredentialScopeStamp,
        stremioSlot: CredentialStremioSlotStamp?,
        document: CredentialDocumentStamp?,
        operation: CredentialOperationStamp?
    ) {
        self.scope = scope
        self.stremioSlot = stremioSlot
        self.document = document
        self.operation = operation
    }
}

/// Main-actor linearization point for every credential owner transition.
/// A caller captures a stamp before its first suspension point and must commit
/// through `commitIfCurrent` after every suspension point that can race logout,
/// account replacement, profile replacement, or a newer operation.
@MainActor
final class CredentialScopeAuthority {
    static let shared = CredentialScopeAuthority(
        initialScope: .signedOutDevice,
        publishesProcessScope: true
    )

    private(set) var currentScope: CredentialScope
    private var scopeGeneration: UInt64 = 1
    private var operationGenerations: [CredentialMutationDomain: UInt64] = [:]
    private var stremioSlotGeneration: UInt64 = 0
    private var currentStremioSlot: CredentialStremioSlotStamp?
    private var documentGeneration: UInt64 = 0
    private var currentDocument: CredentialDocumentStamp?
    private let publishesProcessScope: Bool

    init(initialScope: CredentialScope, publishesProcessScope: Bool = false) {
        currentScope = initialScope
        self.publishesProcessScope = publishesProcessScope
    }

    var currentScopeStamp: CredentialScopeStamp {
        CredentialScopeStamp(scope: currentScope, generation: scopeGeneration)
    }

    var currentStremioSlotStamp: CredentialStremioSlotStamp? {
        currentStremioSlot
    }

    var currentDocumentStamp: CredentialDocumentStamp? {
        currentDocument
    }

    @discardableResult
    func transition(to scope: CredentialScope) -> CredentialScopeStamp {
        scopeGeneration &+= 1
        currentScope = scope
        operationGenerations.removeAll(keepingCapacity: true)
        stremioSlotGeneration &+= 1
        currentStremioSlot = nil
        documentGeneration &+= 1
        currentDocument = nil
        if publishesProcessScope {
            CredentialScopeSnapshotStore.shared.publish(scope: scope, generation: scopeGeneration)
        }
        return currentScopeStamp
    }

    @discardableResult
    func beginOperation(_ domain: CredentialOperationDomain) -> CredentialOperationStamp {
        let family = domain.family
        let next = (operationGenerations[family] ?? 0) &+ 1
        operationGenerations[family] = next
        return CredentialOperationStamp(
            domain: domain,
            familyGeneration: next,
            scope: currentScopeStamp
        )
    }

    @discardableResult
    func transitionStremioSlot(profileID: UUID, account: String) -> CredentialStremioSlotStamp {
        stremioSlotGeneration &+= 1
        documentGeneration &+= 1
        currentDocument = nil
        let stamp = CredentialStremioSlotStamp(
            profileID: profileID,
            account: account,
            generation: stremioSlotGeneration,
            scope: currentScopeStamp
        )
        currentStremioSlot = stamp
        return stamp
    }

    @discardableResult
    func bindStremioSlot(profileID: UUID, account: String) -> CredentialStremioSlotStamp {
        if let currentStremioSlot,
           currentStremioSlot.profileID == profileID,
           currentStremioSlot.account == account,
           currentStremioSlot.scope == currentScopeStamp {
            return currentStremioSlot
        }
        return transitionStremioSlot(profileID: profileID, account: account)
    }

    @discardableResult
    func observePulledDocument(
        ciphertext: String,
        version: Int,
        stremioSlot: CredentialStremioSlotStamp? = nil
    ) -> CredentialDocumentStamp {
        documentGeneration &+= 1
        let digest = SHA256.hash(data: Data(ciphertext.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let resolvedSlot = stremioSlot ?? currentStremioSlot
        let stamp = CredentialDocumentStamp(
            version: version,
            digest: digest,
            generation: documentGeneration,
            scope: resolvedSlot?.scope ?? currentScopeStamp,
            stremioSlot: resolvedSlot
        )
        if resolvedSlot.map(isCurrent) ?? true {
            currentDocument = stamp
        }
        return stamp
    }

    func commitStamp() -> CredentialCommitStamp {
        CredentialCommitStamp(scope: currentScopeStamp)
    }

    func currentContextStamp(requireDocument: Bool = false) -> CredentialCommitStamp? {
        if requireDocument, currentDocument == nil { return nil }
        return CredentialCommitStamp(
            scope: currentScopeStamp,
            stremioSlot: currentStremioSlot,
            document: requireDocument ? currentDocument : nil,
            operation: nil
        )
    }

    func commitStamp(operation: CredentialOperationStamp) -> CredentialCommitStamp {
        CredentialCommitStamp(operation: operation)
    }

    func commitStamp(
        stremioSlot: CredentialStremioSlotStamp,
        operation: CredentialOperationStamp? = nil
    ) -> CredentialCommitStamp {
        CredentialCommitStamp(
            scope: stremioSlot.scope,
            stremioSlot: stremioSlot,
            document: nil,
            operation: operation
        )
    }

    func isCurrent(_ stamp: CredentialScopeStamp) -> Bool {
        stamp == currentScopeStamp
    }

    func isCurrent(_ stamp: CredentialOperationStamp) -> Bool {
        guard isCurrent(stamp.scope) else { return false }
        return operationGenerations[stamp.domain.family] == stamp.familyGeneration
    }

    func isCurrent(_ stamp: CredentialStremioSlotStamp) -> Bool {
        isCurrent(stamp.scope) && currentStremioSlot == stamp
    }

    func isCurrent(_ stamp: CredentialDocumentStamp) -> Bool {
        guard isCurrent(stamp.scope) else { return false }
        if let slot = stamp.stremioSlot, !isCurrent(slot) { return false }
        return currentDocument == stamp
    }

    func isCurrent(_ stamp: CredentialCommitStamp) -> Bool {
        guard isCurrent(stamp.scope) else { return false }
        if let slot = stamp.stremioSlot, !isCurrent(slot) { return false }
        if let document = stamp.document, !isCurrent(document) { return false }
        if let operation = stamp.operation, !isCurrent(operation) { return false }
        return true
    }

    @discardableResult
    func commitIfCurrent<Result>(
        _ stamp: CredentialCommitStamp,
        _ mutation: () throws -> Result
    ) rethrows -> Result? {
        guard isCurrent(stamp) else { return nil }
        return try mutation()
    }
}

/// Synchronous read-only mirror for actors that must choose the owner-specific
/// Keychain account before they can hop to the main actor. Only the shared
/// authority publishes here; isolated test authorities never change it.
final class CredentialScopeSnapshotStore: @unchecked Sendable {
    static let shared = CredentialScopeSnapshotStore()

    private let lock = NSLock()
    private var stamp = CredentialScopeStamp(scope: .signedOutDevice, generation: 1)

    private init() {}

    func load() -> CredentialScopeStamp {
        lock.lock()
        defer { lock.unlock() }
        return stamp
    }

    func publish(scope: CredentialScope, generation: UInt64) {
        lock.lock()
        stamp = CredentialScopeStamp(scope: scope, generation: generation)
        lock.unlock()
    }
}

/// Lock-backed primitive used when authorization and publication happen off the
/// main actor. The closure executes while the generation is locked, so checking
/// authority and issuing or publishing are one linearized turn.
final class CredentialLinearizationStore: @unchecked Sendable {
    struct Token: Sendable {
        fileprivate let store: CredentialLinearizationStore
        fileprivate let generation: UInt64

        @discardableResult
        func authorizeAndIssue(_ issue: () -> Void) -> Bool {
            store.performIfCurrent(generation, issue)
        }

        @discardableResult
        func compareAndPublish(_ publish: () -> Void) -> Bool {
            store.performIfCurrent(generation, publish)
        }
    }

    private let lock = NSLock()
    private var generation: UInt64

    init(initialGeneration: UInt64 = 1) {
        generation = initialGeneration
    }

    func token() -> Token {
        lock.lock()
        let value = generation
        lock.unlock()
        return Token(store: self, generation: value)
    }

    @discardableResult
    func publish(generation newGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard newGeneration > generation else { return false }
        generation = newGeneration
        return true
    }

    private func performIfCurrent(_ expected: UInt64, _ mutation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return false }
        mutation()
        return true
    }
}
