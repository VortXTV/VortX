import Foundation

/// The pool download may suspend across Off, a source replacement, or an A-B-A episode round trip.
/// Equality of a content URL is never sufficient authority to begin a new engine transaction.
enum PooledSubtitleSelectionPolicy {
    struct Admission<Load: Equatable & Sendable>: Sendable {
        let engine: ObjectIdentifier
        let load: Load
        let revision: UInt64
        let presentation: UUID

        func permits(engine: ObjectIdentifier, load: Load?, revision: UInt64?, presentation: UUID) -> Bool {
            self.engine == engine && self.load == load && self.revision == revision
                && self.presentation == presentation
        }
    }
}

/// Immutable bytes from the already-authorized pool response. The URL is selection identity only:
/// engines must never fetch it or reopen a shared pool-cache file to consume this source.
/// Permission is rechecked on the actual engine mount/preparation path, after every async boundary.
struct PlayerLocalSubtitleSource: Sendable {
    let data: Data
    let format: String
    let identityURL: URL
    let permitsUse: @Sendable () -> Bool

    init?(data: Data, format: String, identityURL: URL,
          permitsUse: @escaping @Sendable () -> Bool) {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024,
              ["srt", "vtt", "ass"].contains(format),
              identityURL.scheme?.lowercased() == "https", identityURL.host != nil,
              identityURL.user == nil, identityURL.password == nil, permitsUse() else { return nil }
        self.data = data; self.format = format; self.identityURL = identityURL
        self.permitsUse = permitsUse
    }
}
