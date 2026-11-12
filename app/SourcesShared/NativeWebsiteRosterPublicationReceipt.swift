import CryptoKit
import Foundation

/// Authenticated local evidence for a detached website-roster compare-and-swap.
/// The manager owns the authenticated read, original lease, durable storage and submission.
/// This receipt cannot authenticate a server response or acknowledge an account write.
struct NativeWebsiteRosterPublicationReceipt: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case pending = "p"
        case definitivelyRejected = "r"
    }

    enum FullRosterReadback: Equatable, Sendable {
        case denied
        case exactCandidate
        case requiresIndependentAdmission
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidContext
        case invalidRecord
        case invalidAttempt
    }

    let state: State
    let baseRevision: Int
    let targetRevision: Int
    private let sourceDigest: Data
    private let candidateDigest: Data
    private let encoded: String

    private static let version = "v1"
    private static let maximumRevision = SyncDocumentRevisionPolicy.maximumSafeRevision
    private static let maximumRawBytes = 32 * 1024 * 1024
    private static let maximumEncodedBytes = 233
    private static let recordDomain = "vortx/apple/website-roster-publication/record/v1\u{0}"
    private static let keyDomain = Data("vortx/apple/website-roster-publication/key/v1".utf8)
    private static let slotDomain = "vortx/apple/website-roster-publication/slot/v1\u{0}"
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func storageSlot(accountNamespace: String, dataKey: Data) throws -> String {
        let key = try receiptKey(accountNamespace: accountNamespace, dataKey: dataKey)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: Data((slotDomain + accountNamespace).utf8), using: key))
        return "vortx.native.websiteRosterPublication." + accountNamespace + "." + hex(tag)
    }

    /// The first pending receipt must be committed and read back before the first send.
    static func pending(accountNamespace: String, dataKey: Data, baseRevision: Int,
                        source: Data, candidate: Data) throws -> Self {
        let key = try receiptKey(accountNamespace: accountNamespace, dataKey: dataKey)
        guard let target = SyncDocumentRevisionPolicy.next(after: baseRevision), bounded(source), bounded(candidate) else {
            throw Failure.invalidAttempt
        }
        return signed(state: .pending, baseRevision: baseRevision, targetRevision: target,
                      sourceDigest: digest(source), candidateDigest: digest(candidate),
                      accountNamespace: accountNamespace, key: key)
    }

    func encode() -> String { encoded }

    /// Invalid, unreadable or unauthentic existing bytes must fail closed.
    /// Only the manager's storage boundary can establish that a receipt is absent.
    static func decode(_ encoded: String, accountNamespace: String, dataKey: Data) throws -> Self {
        let key = try receiptKey(accountNamespace: accountNamespace, dataKey: dataKey)
        guard encoded.utf8.count <= maximumEncodedBytes else { throw Failure.invalidRecord }
        let fields = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 7, fields[0] == version,
              let state = State(rawValue: String(fields[1])),
              let base = parseRevision(fields[2]), let target = parseRevision(fields[3]),
              SyncDocumentRevisionPolicy.next(after: base) == target,
              let sourceDigest = parseDigest(fields[4]), let candidateDigest = parseDigest(fields[5]),
              let seal = parseDigest(fields[6]) else { throw Failure.invalidRecord }
        let body = fields.dropLast().joined(separator: ":")
        guard HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: framed(body, accountNamespace), using: key) else {
            throw Failure.invalidRecord
        }
        return Self(state: state, baseRevision: base, targetRevision: target,
                    sourceDigest: sourceDigest, candidateDigest: candidateDigest, encoded: encoded)
    }

    /// The caller may use this only for an explicit rejection of a fresh send with no
    /// preceding ambiguous submission. A rejection on replay does not settle an earlier send.
    func markingDefinitivelyRejected(accountNamespace: String, dataKey: Data) throws -> Self {
        try requireAuthenticated(accountNamespace: accountNamespace, dataKey: dataKey)
        if state == .definitivelyRejected { return self }
        return Self.signed(state: .definitivelyRejected, baseRevision: baseRevision, targetRevision: targetRevision,
                           sourceDigest: sourceDigest, candidateDigest: candidateDigest,
                           accountNamespace: accountNamespace,
                           key: try Self.receiptKey(accountNamespace: accountNamespace, dataKey: dataKey))
    }

    /// Requires both receipts to belong to the caller's same authenticated account and data key.
    /// A persisted pending attempt permits only the same revision, source bytes and candidate
    /// bytes. An explicitly rejected attempt may be replaced from a higher authenticated base.
    func permitsAttempt(_ next: Self, accountNamespace: String, dataKey: Data) throws -> Bool {
        try requireAuthenticated(accountNamespace: accountNamespace, dataKey: dataKey)
        try next.requireAuthenticated(accountNamespace: accountNamespace, dataKey: dataKey)
        guard next.state == .pending else { return false }
        if state == .definitivelyRejected { return next.baseRevision > baseRevision }
        return next.baseRevision == baseRevision && next.sourceDigest == sourceDigest && next.candidateDigest == candidateDigest
    }

    /// Call only after authenticating and independently classifying the GET as a full roster.
    /// An uncertain target is pinned to the exact submitted bytes. After a definitive rejection
    /// a different winner at that target, or at any later valid revision, still needs normal
    /// full-roster ownership admission. Neither result grants mount or applied-version authority.
    func classifyFullRosterReadback(revision: Int, raw: Data) -> FullRosterReadback {
        guard revision >= targetRevision, revision <= Self.maximumRevision, Self.bounded(raw) else { return .denied }
        if revision > targetRevision { return .requiresIndependentAdmission }
        if Self.digest(raw) == candidateDigest { return .exactCandidate }
        return state == .definitivelyRejected ? .requiresIndependentAdmission : .denied
    }

    private func requireAuthenticated(accountNamespace: String, dataKey: Data) throws {
        guard try Self.decode(encoded, accountNamespace: accountNamespace, dataKey: dataKey) == self else {
            throw Failure.invalidRecord
        }
    }

    private static func signed(state: State, baseRevision: Int, targetRevision: Int,
                               sourceDigest: Data, candidateDigest: Data,
                               accountNamespace: String, key: SymmetricKey) -> Self {
        let body = [version, state.rawValue, String(baseRevision), String(targetRevision),
                    hex(sourceDigest), hex(candidateDigest)].joined(separator: ":")
        let seal = Data(HMAC<SHA256>.authenticationCode(for: framed(body, accountNamespace), using: key))
        return Self(state: state, baseRevision: baseRevision, targetRevision: targetRevision,
                    sourceDigest: sourceDigest, candidateDigest: candidateDigest, encoded: body + ":" + hex(seal))
    }

    private static func receiptKey(accountNamespace: String, dataKey: Data) throws -> SymmetricKey {
        let prefix = "account."
        guard dataKey.count == 32, accountNamespace.utf8.count == 44, accountNamespace.hasPrefix(prefix) else {
            throw Failure.invalidContext
        }
        let account = String(accountNamespace.dropFirst(prefix.count))
        guard let id = UUID(uuidString: account), id.uuidString.lowercased() == account else {
            throw Failure.invalidContext
        }
        return SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: keyDomain, using: SymmetricKey(data: dataKey))))
    }

    private static func framed(_ body: String, _ accountNamespace: String) -> Data {
        // Domain has a NUL terminator, account has canonical fixed ASCII width, and
        // the body uses strict canonical fields. No caller-supplied delimiter is ambiguous.
        Data((recordDomain + accountNamespace + "\u{0}" + body).utf8)
    }

    private static func parseRevision(_ field: Substring) -> Int? {
        guard let revision = Int(field), revision >= 0, revision <= maximumRevision,
              String(revision) == field else { return nil }
        return revision
    }

    private static func bounded(_ raw: Data) -> Bool { !raw.isEmpty && raw.count <= maximumRawBytes }
    private static func digest(_ raw: Data) -> Data { Data(SHA256.hash(data: raw)) }

    private static func hex(_ bytes: Data) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func parseDigest(_ field: Substring) -> Data? {
        guard field.utf8.count == SHA256.Digest.byteCount * 2 else { return nil }
        let bytes = Array(field.utf8)
        var digest = Data(capacity: SHA256.Digest.byteCount)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 87
            default: return nil
            }
        }
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            digest.append((high << 4) | low)
        }
        return digest
    }
}
