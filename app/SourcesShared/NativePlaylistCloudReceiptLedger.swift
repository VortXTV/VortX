import CryptoKit
import Foundation

/// Non-secret immutable owner identity for one captured local playlist transaction.
struct NativePlaylistReceiptOwner: Hashable, Sendable {
    let credentialNamespace: String
    let credentialGeneration: UInt64
    let accountGeneration: UUID
    let profileID: UUID
    /// Preserve the actual canonical carrier key (UUID.uuidString spelling) from the captured binding.
    let profileKey: String
    let profileGeneration: UUID
    let sessionGeneration: UUID
}

/// Prepared off-main from one bounded exact register. Consumers cache this for the current row/edit;
/// status reads compare 32 bytes and never encode a 512 KiB register on a SwiftUI body pass.
struct NativePlaylistRegisterFingerprint: Hashable, Sendable {
    fileprivate let digest: Data
    init(canonicalRegister: Data) { digest = Data(SHA256.hash(data: canonicalRegister)) }
}

struct NativePlaylistReceiptKey: Hashable, Sendable {
    let owner: NativePlaylistReceiptOwner
    let field: String
}
struct NativePlaylistPendingReceipt: Equatable, Sendable {
    let edit: UUID
    let register: Data
    let fingerprint: NativePlaylistRegisterFingerprint
}
struct NativePlaylistAcceptedReceipt: Equatable, Sendable {
    let edit: UUID
    let fingerprint: NativePlaylistRegisterFingerprint
    let version: Int
}
struct NativePlaylistCandidateProjection: Sendable {
    let owner: NativePlaylistReceiptOwner
    let registers: [String: Data]
    /// The exact local edit generations captured before candidate projection suspended.
    let edits: [String: UUID]
}
enum NativePlaylistCloudReceiptState: Equatable, Sendable {
    case unknown
    case pending
    case saved(version: Int)
}

/// Bounded volatile ledger. Eviction forgets acknowledgement metadata only; native local register/draft
/// is never touched. Absence after eviction/relaunch is honestly reported as unknown.
struct NativePlaylistCloudReceiptLedger: Sendable {
    static let maximumEntries = 64
    static let maximumPendingRegisterBytes = 4 * 1024 * 1024
    static let maximumRegisterBytes = 513 * 1024

    private(set) var pending: [NativePlaylistReceiptKey: NativePlaylistPendingReceipt] = [:]
    private(set) var accepted: [NativePlaylistReceiptKey: NativePlaylistAcceptedReceipt] = [:]
    private var order: [NativePlaylistReceiptKey] = []

    mutating func register(owner: NativePlaylistReceiptOwner, field: String,
                           canonicalRegister: Data) -> (key: NativePlaylistReceiptKey, edit: UUID)? {
        guard field.hasPrefix(VortxNativePlaylist.v1Prefix),
              canonicalRegister.count <= Self.maximumRegisterBytes else { return nil }
        // Keep only one current selected owner, with a strict cap independent of live playlist count.
        pending = pending.filter { $0.key.owner == owner }
        accepted = accepted.filter { $0.key.owner == owner }
        order = order.filter { $0.owner == owner }
        let key = NativePlaylistReceiptKey(owner: owner, field: field)
        order.removeAll { $0 == key }
        let edit = UUID()
        pending[key] = .init(edit: edit, register: canonicalRegister,
            fingerprint: NativePlaylistRegisterFingerprint(canonicalRegister: canonicalRegister))
        accepted.removeValue(forKey: key)
        order.append(key)
        evictToBudget()
        guard pending[key]?.edit == edit else { return nil }
        return (key, edit)
    }

    func pending(credentialNamespace: String, generation: UInt64) -> [(NativePlaylistReceiptKey, NativePlaylistPendingReceipt)] {
        pending.filter { $0.key.owner.credentialNamespace == credentialNamespace
            && $0.key.owner.credentialGeneration == generation }.map { ($0.key, $0.value) }
    }

    func pending(_ key: NativePlaylistReceiptKey, edit: UUID) -> NativePlaylistPendingReceipt? {
        guard let current = pending[key], current.edit == edit else { return nil }
        return current
    }

    func isPending(_ key: NativePlaylistReceiptKey, edit: UUID) -> Bool {
        pending(key, edit: edit) != nil
    }

    mutating func acknowledge(_ key: NativePlaylistReceiptKey, edit: UUID,
                              exactAcceptedRegister: Data, version: Int) -> Bool {
        guard let current = pending[key], current.edit == edit,
              current.register == exactAcceptedRegister else { return false }
        pending.removeValue(forKey: key)
        accepted[key] = .init(edit: edit, fingerprint: current.fingerprint, version: version)
        return true
    }

    func state(owner: NativePlaylistReceiptOwner, field: String,
               current: NativePlaylistRegisterFingerprint) -> NativePlaylistCloudReceiptState {
        let key = NativePlaylistReceiptKey(owner: owner, field: field)
        if let pending = pending[key], pending.fingerprint == current { return .pending }
        if let accepted = accepted[key], accepted.fingerprint == current { return .saved(version: accepted.version) }
        return .unknown
    }

    @discardableResult
    mutating func invalidate(owner: NativePlaylistReceiptOwner? = nil) -> Bool {
        let oldCount = pending.count + accepted.count
        guard let owner else { pending.removeAll(); accepted.removeAll(); order.removeAll(); return oldCount != 0 }
        pending = pending.filter { $0.key.owner != owner }
        accepted = accepted.filter { $0.key.owner != owner }
        order.removeAll { $0.owner == owner }
        return pending.count + accepted.count != oldCount
    }

    private mutating func evictToBudget() {
        while order.count > Self.maximumEntries || pendingBytes > Self.maximumPendingRegisterBytes {
            guard !order.isEmpty else { break }
            let oldest = order.removeFirst()
            pending.removeValue(forKey: oldest)
            accepted.removeValue(forKey: oldest)
        }
    }

    private var pendingBytes: Int { pending.values.reduce(0) { $0 + $1.register.count } }
}
