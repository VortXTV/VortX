import Foundation

/// Native host-field transaction contracts shared by the app and the COMPLETE Session/Facade ABI
/// harnesses. No Xperience/parser, Keychain, VortXSyncCrypto or presentation dependency belongs here.
/// Optional external-source authentication lease. Its implementation linearizes credential
/// invalidation with the final checkpoint, without exposing credentials to the native runtime.
protocol VortxMutationAuthority: Sendable {
    func withActive(_ operation: () throws -> Void) throws
}

enum VortxNativeHostFieldMutationError: Error, Equatable {
    case staleRegister
    case cancelled
}

enum VortxNativeHostFieldEvidence {
    static func canonicalData(_ value: VortxJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func json(_ left: VortxJSON?, _ right: VortxJSON?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case (let left?, let right?):
            guard let a = try? canonicalData(left), let b = try? canonicalData(right) else { return false }
            return a == b
        default: return false
        }
    }
    static func registers(_ left: [String: VortxJSON]?, _ right: [String: VortxJSON]?) -> Bool {
        json(left.map(VortxJSON.object), right.map(VortxJSON.object))
    }
}

/// A generic ONE-field mutation. Existing native host validation still rejects reserved/unsafe
/// fields before persistence. Feature namespace/model admission remains the caller's pure policy.
struct VortxNativeHostFieldEdit: Sendable {
    let field: String
    let expectedRegister: VortxJSON?
    let value: VortxJSON
    let raw: VortxRawHostFieldEdit?
    init(field: String, expectedRegister: VortxJSON?, value: VortxJSON, raw: VortxRawHostFieldEdit? = nil) {
        self.field = field; self.expectedRegister = expectedRegister; self.value = value; self.raw = raw
    }
    func baselineMatches(_ current: VortxJSON?) -> Bool {
        VortxNativeHostFieldEvidence.json(current, expectedRegister)
    }
}

struct VortxHostFieldCAS: Sendable {
    let profileID: String
    let field: String
    let register: VortxJSON?
    let raw: VortxRawHostFieldEdit?
    init(profileID: String, field: String, register: VortxJSON?, raw: VortxRawHostFieldEdit? = nil) {
        self.profileID = profileID; self.field = field; self.register = register; self.raw = raw
    }
    func matches(_ host: VortxJSON) -> Bool {
        VortxNativeHostFieldEvidence.json(host["profiles"]?[profileID]?["fields"]?[field], register)
    }
}

/// The feature supplies its genuine prospective whole-export validator/authority. Default nil
/// preserves existing Session callers. This core seam never guesses a budget or imports UI data.
protocol VortxProspectiveCheckpointValidator: VortxMutationAuthority {
    func validate(native: VortxJSON, host: VortxJSON, profileEditResults: VortxJSON) throws
    func validateRawHost(native: VortxJSON, host: Data, profileEditResults: VortxJSON) throws
}
extension VortxProspectiveCheckpointValidator {
    // Compatibility for validators whose contract is typed. Xperience overrides this
    // requirement; the raw checkpoint never round-trips through its presentation DTO.
    func validateRawHost(native: VortxJSON, host: Data, profileEditResults: VortxJSON) throws {
        try validate(native: native, host: JSONDecoder().decode(VortxJSON.self, from: host), profileEditResults: profileEditResults)
    }
}

/// Immutable byte evidence prepared OUTSIDE final authority locks from an acknowledged
/// Session host carrier. Invalid/oversized semantic evidence has no canonical cache and
/// is retained as opaque data; it cannot become an editable namespace by decoding a DTO.
struct VortxRawHostRegister: Equatable, Sendable {
    static let maximumClock: UInt64 = 9_007_199_254_740_991
    let bytes: Data
    let canonical: Data?
    let value: Data
    let canonicalValue: Data?
    let metadata: Data?
    static func same(_ left: Self?, _ right: Self?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (a?, b?):
            if a.bytes == b.bytes { return true }
            guard let a = a.canonical, let b = b.canonical else { return false }; return a == b
        default: return false
        }
    }
}
struct VortxRawHostFieldEdit: Equatable, Sendable {
    let expectedRegister: VortxRawHostRegister?
    let value: Data
    let canonicalValue: Data
    func baselineMatches(_ current: VortxRawHostRegister?) -> Bool {
        VortxRawHostRegister.same(current, expectedRegister)
    }
}

/// Cancellation remains attached to the original operation, not the unstructured FIFO task.
/// Source authority and this latch enclose the entire final checkpoint operation without await.
final class VortxNativeHostFieldCommitLatch: VortxMutationAuthority, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private let source: any VortxMutationAuthority
    init(source: any VortxMutationAuthority) { self.source = source }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func withActive(_ operation: () throws -> Void) throws {
        try source.withActive {
            try lock.withLock {
                guard !cancelled else { throw VortxNativeHostFieldMutationError.cancelled }
                try operation()
            }
        }
    }
}
