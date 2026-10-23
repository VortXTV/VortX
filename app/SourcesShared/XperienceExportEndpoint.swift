import Foundation

/// A user-provided Share profile URL, never an install URL or a generic fetch target.
/// Values remain in memory/Keychain only. Descriptions deliberately omit private bytes.
struct XperienceExportEndpoint: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL // Transport-only. Never copy this into a shared host field or UI label.
    var description: String { "<Xperience profile export>" }
    var debugDescription: String { description }

    init(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= AddonPairingProtocol.maxManifestURLBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: text), parts.scheme == "https",
              parts.host == "xperience-app.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1,
              items[0].name == "key", let key = items[0].value, !key.isEmpty,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = parts.url else { throw XperienceExportFailure.invalidURL }
        let path = parts.percentEncodedPath
        let prefix = "/profile-export/", suffix = ".json"
        let profileID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard path.hasPrefix(prefix), path.hasSuffix(suffix), !path.contains("%"),
              UUID(uuidString: profileID)?.uuidString.lowercased() == profileID,
              url.absoluteString == text else { throw XperienceExportFailure.invalidURL }
        self.url = url
    }

    fileprivate var privateString: String { url.absoluteString }
    func acceptsResponseURL(_ other: URL?) -> Bool {
        other?.absoluteString.utf8.elementsEqual(url.absoluteString.utf8) == true
    }
}

enum XperienceExportFailure: Error, Equatable, LocalizedError {
    case invalidURL, unavailable, invalidResponse, revoked, tooLarge, unsafeContent
    case unsupportedVersion, unsupportedSource, unsupportedLayout, missingCollection
    case staleContext, staleRevision, credentialUnavailable, alreadyLinked, notLinked
    case savedNeedsConnection
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use the profile export URL from Xperience’s Share profile option."
        case .revoked: return "This export is no longer available. Reconnect its Share profile URL."
        case .tooLarge: return "This export exceeds the supported collection size."
        case .unsupportedVersion: return "This export uses a newer Xperience format."
        case .unsupportedSource: return "Install or review the add-ons used by this collection before linking it."
        case .unsupportedLayout: return "This collection uses a layout this version cannot apply."
        case .missingCollection: return "The linked collection is no longer in this export."
        case .staleContext, .staleRevision: return "This collection or profile changed. Open a fresh preview."
        case .credentialUnavailable: return "The private export URL could not be securely read or saved."
        case .savedNeedsConnection: return "The collection was saved in VortX, but its private URL could not be securely saved. Reconnect this device."
        case .alreadyLinked: return "This collection already has an upstream connection."
        case .notLinked: return "Connect this device to the collection’s Share profile URL first."
        case .unsafeContent: return "This export contains values that cannot be saved safely."
        case .invalidResponse: return "Xperience did not return a supported complete export."
        case .unavailable: return "Could not refresh from Xperience. The saved collection is unchanged."
        }
    }
}

/// Same injected certified-read/write seam as TraktAuth and SIMKLAuth. No defaults mirror.
struct XperienceExportCredentialStore: Sendable {
    let read: @Sendable (String) -> CredentialDurableReadResult
    let write: @Sendable (String?, String) -> CredentialMutationResult
    static let keychain = XperienceExportSystemKeychain.credentials
}

@MainActor final class XperienceExportCredentialVault {
    struct RepairTicket: Equatable, Sendable {
        fileprivate let slot: String
        fileprivate let owner: CredentialScopeRegistry.Capture
        fileprivate let epoch: UInt64
    }
    private final class Epochs: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: UInt64] = [:]
        func value(_ slot: String) -> UInt64 { lock.lock(); defer { lock.unlock() }; return values[slot, default: 0] }
        /// Every mutation attempt advances the shared epoch, even a failed attempt.
        func advance(_ slot: String, expected: UInt64? = nil) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let previous = values[slot, default: 0]
            values[slot] = previous &+ 1
            return expected == nil || expected == previous
        }
    }
    private static let epochs = Epochs()
    struct Record: Equatable, Sendable, CustomDebugStringConvertible {
        let endpoint: XperienceExportEndpoint
        let sourceID: String
        let sessionID: UUID
        var debugDescription: String { "<owner-scoped Xperience export credential>" }
    }
    private struct Wire: Codable {
        let url: String
        let sourceID: String
        let sessionID: UUID
    }
    private let store: XperienceExportCredentialStore
    private let authority: CredentialScopeRegistry
    init(store: XperienceExportCredentialStore = .keychain,
         authority: CredentialScopeRegistry = .shared) { self.store = store; self.authority = authority }

    static func slot(owner: CredentialScopeRegistry.Capture, profileID: UUID, collectionID: String) -> String {
        "vortx.xperience.profile-export.v1." + owner.namespace + ".profile."
            + profileID.uuidString.lowercased() + ".collection." + collectionID
    }
    func read(owner: CredentialScopeRegistry.Capture, profileID: UUID, collectionID: String) throws -> Record? {
        guard authority.isCurrent(owner), UUID(uuidString: collectionID)?.uuidString.lowercased() == collectionID else {
            throw XperienceExportFailure.staleContext
        }
        let result = store.read(Self.slot(owner: owner, profileID: profileID, collectionID: collectionID))
        guard authority.isCurrent(owner) else { throw XperienceExportFailure.staleContext }
        switch result {
        case .missing: return nil
        case .failure: throw XperienceExportFailure.credentialUnavailable
        case .value(let text):
            guard text.utf8.count <= 4096,
                  let wire = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)),
                  UUID(uuidString: wire.sourceID)?.uuidString.lowercased() == wire.sourceID,
                  let endpoint = try? XperienceExportEndpoint(wire.url) else {
                throw XperienceExportFailure.credentialUnavailable
            }
            return .init(endpoint: endpoint, sourceID: wire.sourceID, sessionID: wire.sessionID)
        }
    }
    /// Explicit reconnect may repair the exact owner slot left uncertified by a previous failed
    /// Keychain.set. Never recover a URL from volatile/legacy plaintext state or auto-fetch it.
    func prepareRepair(owner: CredentialScopeRegistry.Capture, profileID: UUID,
                       collectionID: String) throws -> RepairTicket {
        guard authority.isCurrent(owner), UUID(uuidString: collectionID)?.uuidString.lowercased() == collectionID else {
            throw XperienceExportFailure.staleContext
        }
        let slot = Self.slot(owner: owner, profileID: profileID, collectionID: collectionID)
        let epoch = Self.epochs.value(slot)
        guard store.read(slot) == .failure, authority.isCurrent(owner), Self.epochs.value(slot) == epoch else {
            throw XperienceExportFailure.credentialUnavailable
        }
        return .init(slot: slot, owner: owner, epoch: epoch)
    }
    func matches(_ expected: Record?, owner: CredentialScopeRegistry.Capture, profileID: UUID,
                 collectionID: String, repair: RepairTicket? = nil) throws -> Bool {
        guard let repair else { return try read(owner: owner, profileID: profileID, collectionID: collectionID) == expected }
        let slot = Self.slot(owner: owner, profileID: profileID, collectionID: collectionID)
        guard expected == nil, repair.slot == slot, repair.owner == owner,
              authority.isCurrent(owner), Self.epochs.value(slot) == repair.epoch else {
            throw XperienceExportFailure.staleContext
        }
        let result = store.read(slot)
        guard authority.isCurrent(owner), Self.epochs.value(slot) == repair.epoch else {
            throw XperienceExportFailure.staleContext
        }
        return result == .failure // Never treat an uncertain slot as a certified absence/value.
    }
    /// One slot plus certified readback; no cross-store publication or credential sync.
    /// CAS is against the original gesture's record. An intervening reconnect never gets replaced.
    func save(_ record: Record?, replacing expected: Record?, owner: CredentialScopeRegistry.Capture,
              profileID: UUID, collectionID: String, repair: RepairTicket? = nil) throws {
        let account = Self.slot(owner: owner, profileID: profileID, collectionID: collectionID)
        guard let mutation = CredentialPublicationOutbox.beginMutation() else {
            _ = Self.epochs.advance(account)
            throw XperienceExportFailure.credentialUnavailable
        }
        defer { CredentialPublicationOutbox.endMutation(mutation) }
        let baseline: Bool
        do {
            if authority.isCurrent(owner) {
                baseline = try matches(expected, owner: owner, profileID: profileID, collectionID: collectionID, repair: repair)
            } else { baseline = false }
        }
        catch { _ = Self.epochs.advance(account); throw error }
        let epochMatches = Self.epochs.advance(account, expected: repair?.epoch)
        guard baseline, epochMatches else {
            throw XperienceExportFailure.staleContext
        }
        let text: String?
        if let record {
            let encoded = try JSONEncoder().encode(Wire(url: record.endpoint.privateString,
                sourceID: record.sourceID, sessionID: record.sessionID))
            guard let value = String(data: encoded, encoding: .utf8) else { throw XperienceExportFailure.credentialUnavailable }
            text = value
        } else { text = nil }
        guard store.write(text, account) == .success,
              store.read(account) == (text.map(CredentialDurableReadResult.value) ?? .missing),
              authority.isCurrent(owner) else { throw XperienceExportFailure.credentialUnavailable }
    }
}
