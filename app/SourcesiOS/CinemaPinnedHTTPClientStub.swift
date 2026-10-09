import Foundation

#if CINEMA_UI_SMOKE_RENDERER
/// Compile-only shape for subtitle-download call sites in the isolated renderer.
///
/// The production pinned transport lives with the excluded community-provider runtime and can create network
/// connections. The smoke surface contains neither a player nor a subtitle fetch, so any attempted request is
/// an invariant violation rather than a best-effort empty response.
enum PinnedHTTPClient {
    struct Limits: Sendable {
        var maximumBodyBytes = 16 * 1024 * 1024
        var maximumWireBytes = 17 * 1024 * 1024
        var maximumStreamBytes = Int.max
        var timeout: TimeInterval = 20
    }

    struct Request: Sendable {
        let url: URL

        init(url: URL) {
            self.url = url
        }
    }

    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    static func execute(_ request: Request, limits: Limits = .init()) async throws -> Response {
        preconditionFailure("Cinema UI renderer must not execute PinnedHTTPClient")
    }
}
#endif
