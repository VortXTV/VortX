import Foundation

/// Compile-only type shape for the UNUSED owner-history case of the verbatim
/// NativeCandidate enum. The tested cold helper constructs .generic exclusively.
/// Every method aborts: this cannot serve as successful native/restore evidence.
/// The real VortxCABI and generic runtime/import/replay are compiled unchanged.
enum OwnerHistorySessionCoordinator {
    final class Candidate: @unchecked Sendable {
        private init() { preconditionFailure("owner-history case is outside this cold fixture") }
        func stateJSON() throws -> String { preconditionFailure("unexpected owner-history state") }
        func dispatch(_ action: String, now: UInt64) throws -> String { preconditionFailure("unexpected owner-history dispatch") }
        func resolve(_ query: String) throws -> String { preconditionFailure("unexpected owner-history resolve") }
        func copy() throws -> Candidate { preconditionFailure("unexpected owner-history copy") }
        func close() -> Bool { preconditionFailure("unexpected owner-history close") }
    }
}
