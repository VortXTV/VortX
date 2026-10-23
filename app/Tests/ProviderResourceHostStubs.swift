import Foundation

// Controlled host admission only. Production JSON models, projections and trailer decisions
// are extracted verbatim; this fixture never constructs app/storage/transport/player owners.
enum ProfileStore {
    static func activeDisabledAddons() -> Set<String> { [] }
    static func activeAddonOrder(accountOrder: [String]) -> [String] { accountOrder }
}
enum VortXSyncManager { static let appliedAddonOrder: [String] = [] }
enum StremioServer {
    static let trailerResolverBase = "https://trailer.vortx.tv"
    static var base: String { preconditionFailure("Fixture must not enter torrent transport") }
}
enum PlaybackSettings {
    static var torrentsDisabled: Bool { preconditionFailure("Fixture must not read playback preferences") }
}
enum UsenetProviderStore {
    static var isConfigured: Bool { preconditionFailure("Fixture must not read credentials") }
}
final class CommunityStreamGateway: @unchecked Sendable {
    static let shared = CommunityStreamGateway()
    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? {
        preconditionFailure("Fixture must not enter a community gateway")
    }
}
final class DebridPlaybackAvailability: @unchecked Sendable {
    static let shared = DebridPlaybackAvailability()
    func canResolveUsenet(savedProviderConfigured: @autoclosure () -> Bool,
                          addonServersAvailable: @autoclosure () -> Bool) -> Bool {
        preconditionFailure("Fixture must not enter debrid resolution")
    }
}

