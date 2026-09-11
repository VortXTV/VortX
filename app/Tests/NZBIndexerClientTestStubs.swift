import Foundation
// Only platform storage/identity seams are stubbed. Store, validation and parser are real.
enum CredentialMutationResult: Equatable { case success, failure }
enum CredentialDurableReadResult { case value(String), missing, failure }
@MainActor enum Keychain {
    static var values: [String: String] = [:]
    static var failReads = false
    static var failWrites = false
    static func confirmedString(_ account: String) -> CredentialDurableReadResult {
        if failReads { return .failure }
        return values[account].map { .value($0) } ?? .missing
    }
    static func set(_ value: String?, for account: String) -> CredentialMutationResult {
        guard !failWrites else { return .failure }
        values[account] = value; return .success
    }
}
struct CredentialScope: Equatable, Sendable { var storageNamespace = "test" }
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    var generation: UInt64 = 0
    struct Capture: Equatable, Sendable {
        let scope = CredentialScope()
        let generation: UInt64
        var namespace: String { scope.storageNamespace }
    }
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}
@MainActor final class ProfileStore { static let shared = ProfileStore(); var activeID: UUID? = nil }
enum UserProfile { static let ownerID = UUID() }
