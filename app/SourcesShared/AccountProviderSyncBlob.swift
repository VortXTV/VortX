import Foundation
import CryptoKit

/// Parsing/readback utilities only. No account capability, provider credential, ACK or receipt is
/// created here. Store-owned settlement methods preserve the original blob and choose merge policy.
enum AccountProviderSyncBlob {
    enum Failure: Error { case malformed, persistence }
    typealias Exact = OwnerHistoryExactJSON
    static let maximumBytes = 8 * 1024 * 1024
    static func digest(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }
    static func root(_ text: String) throws -> Exact.Object {
        let bytes = Data(text.utf8)
        guard bytes.count <= maximumBytes else { throw Failure.malformed }
        let root = try Exact.Object(bytes)
        if let version = root["v"] {
            guard version == Data("1".utf8) else { throw Failure.malformed }
        }
        return root
    }
    static func rows(_ root: Exact.Object, _ key: String) throws -> [Exact.Object] {
        guard let bytes = root[key] else { return [] }
        let values = try Exact.array(bytes)
        guard values.count <= 10_000 else { throw Failure.malformed }
        return try values.map(Exact.Object.init)
    }
    static func string(_ row: Exact.Object, _ key: String, default fallback: String? = nil) throws -> String {
        if let bytes = row[key] { return try JSONDecoder().decode(String.self, from: bytes) }
        guard let fallback else { throw Failure.malformed }; return fallback
    }
    static func optionalString(_ row: Exact.Object, _ key: String) throws -> String? {
        guard let bytes = row[key] else { return nil }
        if bytes == Data("null".utf8) { return nil }
        return try JSONDecoder().decode(String.self, from: bytes)
    }
    static func validDate(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1000
        return milliseconds.isFinite && abs(milliseconds) <= 9_007_199_254_740_991
    }
    static func date(_ row: Exact.Object, _ key: String) throws -> Date {
        let value = try JSONDecoder().decode(Double.self, from: row.required(key))
        guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else { throw Failure.malformed }
        return Date(timeIntervalSince1970: value / 1000)
    }
    static func removed(_ root: Exact.Object) throws -> [String: Double] {
        guard let bytes = root["removed"] else { return [:] }
        let fields = try Exact.Object(bytes)
        guard fields.fields.count <= 10_000 else { throw Failure.malformed }
        var result: [String: Double] = [:]
        for (key, bytes) in fields.fields {
            let value = try JSONDecoder().decode(Double.self, from: bytes)
            guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else { throw Failure.malformed }; result[key] = value
        }
        return result
    }
    static func defaultsData(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        guard let data = value as? Data else { throw Failure.persistence }; return data
    }
    static func defaultsRemoved(_ value: Any?) throws -> [String: Double] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw Failure.persistence
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode([String: Double].self, from: bytes)
        guard decoded.values.allSatisfy({ $0.isFinite && abs($0) <= 9_007_199_254_740_991 }) else { throw Failure.persistence }; return decoded
    }
    static func sameCredential(_ a: CredentialDurableReadResult, _ b: CredentialDurableReadResult) -> Bool {
        switch (a, b) {
        case (.missing, .missing): return true
        case let (.value(a), .value(b)): return Data(a.utf8) == Data(b.utf8)
        default: return false
        }
    }
    static func value(_ result: CredentialDurableReadResult) throws -> String? {
        switch result {
        case .missing: return nil
        case .value(let value): return value
        case .failure: throw Failure.persistence
        }
    }
}
