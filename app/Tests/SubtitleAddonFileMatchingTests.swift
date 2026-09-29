// Compile with SubtitleRequestMetadata.swift and SubtitleAddons.swift; the fixture descriptors below
// only satisfy the unused installation-store boundary. Requests and response decoding use production code.
import Foundation

struct CoreStreamBehaviorHints {
    let filename: String?
    let videoHash: String?
    let videoSize: Int64?
}
struct CoreDescriptor {
    struct Manifest { let name: String }
    let providesSubtitles: Bool
    let baseUrl: String
    let manifest: Manifest
}
struct AddonDescriptor {
    struct Manifest {
        struct Resource { let name: String }
        let name: String
        let resources: [Resource]
    }
    let baseUrl: String
    let manifest: Manifest
}
enum AddonTombstones { static func normalize(_ value: String) -> String { value } }

private final class SubtitleFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let exact = "https://subs.invalid/subtitles/series/tt123:1:9/videoHash=0123456789abcdef&videoSize=6750000000&filename=Episode%209%20%26%20%231%2F%25%3F.mkv.json"
        let matchesFile = request.url?.absoluteString == exact
        let body = matchesFile
            ? #"{"subtitles":[{"id":"matched","url":"https://cdn.invalid/matched.srt","lang":"eng","subtitleFileName":"Episode 9 SiGMA"},17,{"url":null},{"url":"https://cdn.invalid/other.srt","lang":null,"subtitleFileName":8}]}"#
            : #"{"subtitles":[{"url":"https://cdn.invalid/legacy.srt","lang":"eng"}]}"#
        let rejectsExtra = ["legacy.invalid", "legacy405.invalid"].contains(request.url?.host ?? "")
            && request.url!.path.contains("/filename=")
        let unavailable = request.url?.host == "unavailable.invalid"
        let rejectedStatus = request.url?.host == "legacy405.invalid" ? 405 : 404
        let response = HTTPURLResponse(url: request.url!, statusCode: rejectsExtra ? rejectedStatus : unavailable ? 502 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum SubtitleAddonFileMatchingTests {
    static func main() async {
        precondition(SubtitleRequestMetadata.effectiveVideoID(libraryID: "tmdb:456", videoID: "tmdb:456:1:2", cachedIMDbID: "tt789") == "tt789:1:2")
        precondition(SubtitleRequestMetadata.effectiveVideoID(libraryID: "tmdb:456", videoID: "tmdb:456", cachedIMDbID: "tt789") == "tt789")
        precondition(SubtitleRequestMetadata.effectiveVideoID(libraryID: "tmdb:456", videoID: "tmdb:456:1:2", cachedIMDbID: nil) == "tmdb:456:1:2")
        precondition(SubtitleRequestMetadata.effectiveVideoID(libraryID: "tt456", videoID: "tt456:1:2", cachedIMDbID: "tt789") == "tt456:1:2")
        precondition(SubtitleRequestMetadata.effectiveVideoID(libraryID: "tmdb:45", videoID: "tmdb:456:1:2", cachedIMDbID: "tt789") == "tmdb:456:1:2", "partial title-ID prefixes must not rewrite a different title")
        let metadata = SubtitleRequestMetadata(filename: "Episode 9 & #1/%?.mkv",
                                              videoHash: "0123456789abcdef", videoSize: 6_750_000_000)
        precondition(SubtitleRequestMetadata().resourcePath(type: "series", videoID: "tt123:1:9")
                     == "subtitles/series/tt123:1:9.json", "legacy request must stay unchanged")
        precondition(SubtitleRequestMetadata(videoSize: -1).resourcePath(type: "movie", videoID: "tt123")
                     == "subtitles/movie/tt123.json", "invalid byte count must not be sent")
        precondition(SubtitleRequestMetadata(filename: "é 日.mkv").resourcePath(type: "movie", videoID: "id/with?query#fragment")
                     == "subtitles/movie/id%2Fwith%3Fquery%23fragment/filename=%C3%A9%20%E6%97%A5.mkv.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubtitleFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let sources = [SubtitleAddonSource(baseUrl: "https://subs.invalid/", name: "Test Add-on")]
        let exact = await SubtitleAddonService.fetch(sources: sources, type: "series", videoId: "tt123:1:9",
                                                     metadata: metadata, session: session)
        precondition(exact.count == 2, "malformed optional entries must not erase valid tracks")
        precondition(exact[0].id == "matched" && exact[0].displayTitle == "Test Add-on · Episode 9 SiGMA",
                     "exact-file lookup and release display must use the selected file")
        precondition(exact[1].lang == "und" && exact[1].displayTitle == "Test Add-on")
        let legacy = await SubtitleAddonService.fetch(sources: sources, type: "series", videoId: "tt123:1:9", session: session)
        precondition(legacy.count == 1 && legacy[0].url == "https://cdn.invalid/legacy.srt")
        let changedFile = await SubtitleAddonService.fetch(sources: sources, type: "series", videoId: "tt123:1:9",
                                                           metadata: .init(filename: "other-file.mkv"), session: session)
        precondition(changedFile.first?.id != exact[0].id, "same-episode source switches must requery the file")
        for host in ["legacy.invalid", "legacy405.invalid"] {
            let legacyRouter = await SubtitleAddonService.fetch(
                sources: [.init(baseUrl: "https://" + host, name: "Old router")], type: "series", videoId: "tt123:1:9",
                metadata: .init(filename: "other-file.mkv"), session: session)
            precondition(legacyRouter.count == 1, "an ID-only add-on router must recover after rejecting the extra route")
        }
        let unavailable = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://unavailable.invalid", name: "Unavailable")], type: "movie", videoId: "tt123",
            metadata: .init(filename: "other-file.mkv"), session: session)
        precondition(unavailable.isEmpty, "server failures remain fail-soft, not a retry storm")
        print("PASS exact-file subtitle HTTP requests, Unicode/reserved encoding, legacy route, source changes and partial response recovery")
    }
}
