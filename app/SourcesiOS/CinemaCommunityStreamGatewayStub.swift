import Foundation

#if CINEMA_UI_SMOKE_RENDERER
/// Compile-only gateway shape for shared model helpers.
///
/// The real gateway owns a loopback listener and pinned upstream transport. It is excluded from the smoke
/// target, which renders static presentation only; each operational entry point therefore traps if an
/// unrelated code path attempts to use it.
final class CommunityStreamGateway: @unchecked Sendable {
    static let shared = CommunityStreamGateway()

    private init() {}

    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? {
        preconditionFailure("Cinema UI renderer must not resolve CommunityStreamGateway")
    }

    func registerNativeDebrid(upstream: URL) async throws -> URL {
        preconditionFailure("Cinema UI renderer must not register CommunityStreamGateway")
    }
}
#endif
