// Compile with AddonURLGuard.swift, SubtitleRequestMetadata.swift and SubtitleAddons.swift. The fixture
// descriptors below satisfy only the unused installation-store boundary. Every fixture URL still traverses
// the production guard's validation, redirect, timeout and body-cap logic before URLProtocol answers it.
import Foundation

enum AddonPairingProtocol { static let maxManifestURLBytes = 2_048 }

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
        let exact = "https://127.0.0.1/subtitles/series/tt123:1:9/videoHash=0123456789abcdef&videoSize=6750000000&filename=Episode%209%20%26%20%231%2F%25%3F.mkv.json"
        let matchesFile = request.url?.absoluteString == exact
        let host = request.url?.host ?? ""
        let hasMetadata = request.url?.path.contains("/filename=") ?? false
        let body: String
        if host == "127.0.0.16" {
            body = #"{"subtitles":[{"url":"../captions/en.srt"},{"url":"//127.0.0.99/foreign.srt"},{"url":"file:///private/invalid.srt"},{"url":"bad.srt#fragment"}]}"#
        } else if host == "127.0.0.20" {
            body = "{\"subtitles\":[" + (0..<1_024).map { "{\"url\":\"part-\($0).srt\"}" }.joined(separator: ",") + "]}"
        } else if host == "127.0.0.5" && hasMetadata {
            body = #"{"subtitles":[]}"#
        } else if matchesFile {
            body = #"{"subtitles":[{"id":"matched","url":"https://cdn.invalid/matched.srt","lang":"eng","subtitleFileName":"Episode 9 SiGMA"},17,{"url":null},{"url":"https://cdn.invalid/other.srt","lang":null,"subtitleFileName":8}]}"#
        } else {
            body = #"{"subtitles":[{"url":"https://cdn.invalid/legacy.srt","lang":"eng"}]}"#
        }
        let rejectRoute = ["127.0.0.2", "127.0.0.3"].contains(host) && hasMetadata
        let rejectedStatus = host == "127.0.0.3" ? 405 : 404
        var status: Int
        switch (host, hasMetadata) {
        case ("127.0.0.4", true): status = 502
        case ("127.0.0.6", true): status = 401
        case ("127.0.0.7", true): status = 403
        case ("127.0.0.8", true): status = 500
        default: status = rejectRoute ? rejectedStatus : 200
        }
        var headers: [String: String]? = nil
        let responseURL = request.url!
        if request.value(forHTTPHeaderField: "Accept") != "application/json" { status = 500 }
        if host == "127.0.0.16" && hasMetadata {
            headers = ["Location": "/relocated/deep/index.json"]
            status = 302
        } else if host == "127.0.0.9" && hasMetadata {
            headers = ["Location": "https://127.0.0.10/subtitles/series/tt123:1:9/redirected.json"]
            status = 302
        } else if host == "127.0.0.11" && hasMetadata {
            headers = ["Location": "/subtitles/series/tt123:1:9/redirected.json"]
            status = 302
        } else if host == "127.0.0.12" && hasMetadata {
            headers = ["Location": "file:///tmp/should-not-be-requested.json"]
            status = 302
        }
        let response = HTTPURLResponse(url: responseURL, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
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
        let fixtures = AddonURLGuard.TestURLProtocolClasses([SubtitleFixture.self])
        let sources = [SubtitleAddonSource(baseUrl: "https://127.0.0.1/", name: "Test Add-on")]
        let exact = await SubtitleAddonService.fetch(sources: sources, type: "series", videoId: "tt123:1:9",
                                                     metadata: metadata, testURLProtocolClasses: fixtures)
        precondition(exact.count == 2, "malformed optional entries must not erase valid tracks")
        precondition(exact[0].id == "matched" && exact[0].displayTitle == "Test Add-on · Episode 9 SiGMA",
                     "exact-file lookup and release display must use the selected file")
        precondition(exact[1].lang == "und" && exact[1].displayTitle == "Test Add-on")
        precondition(exact[0].installedBaseURL.absoluteString == "https://127.0.0.1/",
                     "subtitle rows retain the original installed source, not the returned CDN URL")
        let legacy = await SubtitleAddonService.fetch(sources: sources, type: "series", videoId: "tt123:1:9",
                                                     testURLProtocolClasses: fixtures)
        precondition(legacy.count == 1 && legacy[0].url == "https://cdn.invalid/legacy.srt")
        let changedFile = await SubtitleAddonService.fetch(sources: sources, type: "series", videoId: "tt123:1:9",
                                                           metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
        precondition(changedFile.first?.id != exact[0].id, "same-episode source switches must requery the file")
        for host in ["127.0.0.2", "127.0.0.3"] {
            let legacyRouter = await SubtitleAddonService.fetch(
                sources: [.init(baseUrl: "https://" + host, name: "Old router")], type: "series", videoId: "tt123:1:9",
                metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
            precondition(legacyRouter.count == 1, "an ID-only add-on router must recover after rejecting the extra route")
        }
        let unavailable = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.4", name: "Unavailable")], type: "movie", videoId: "tt123",
            metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
        precondition(unavailable.isEmpty, "server failures remain fail-soft, not a retry storm")
        for host in ["127.0.0.6", "127.0.0.7", "127.0.0.8"] {
            let noFallback = await SubtitleAddonService.fetch(
                sources: [.init(baseUrl: "https://" + host, name: "Rejected")], type: "series", videoId: "tt123:1:9",
                metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
            precondition(noFallback.isEmpty, "401/403/5xx must not retry the legacy route")
        }
        let emptySuccess = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.5", name: "Empty")], type: "series", videoId: "tt123:1:9",
            metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
        precondition(emptySuccess.isEmpty, "empty 200 must not retry the legacy route")
        let sameOriginRedirect = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.11", name: "Redirect")], type: "series", videoId: "tt123:1:9",
            metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
        precondition(sameOriginRedirect.count == 1 && sameOriginRedirect[0].installedBaseURL.host == "127.0.0.11",
                     "same-origin redirect keeps installed-source provenance")
        let relativeResult = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.16", name: "Relative links")],
            type: "series", videoId: "tt123:1:9", metadata: .init(filename: "relative.mkv"),
            testURLProtocolClasses: fixtures)
        precondition(relativeResult.count == 2,
                     "relative HTTP(S) links resolve; file/fragment references never become selectable")
        precondition(relativeResult[0].url == "https://127.0.0.16/relocated/captions/en.srt",
                     "relative file references use the actual redirected index URL")
        precondition(relativeResult.allSatisfy { $0.installedBaseURL.absoluteString == "https://127.0.0.16" },
                     "final index and returned file hosts never replace installed-origin authority")
        let foreignScope = AddonURLGuard.AccessScope.addon(origin: relativeResult[1].installedBaseURL)
        let foreignRejection = await AddonURLGuard.validate(URL(string: relativeResult[1].url)!,
            access: foreignScope, context: .subtitleFile)
        precondition(foreignRejection != nil, "resolving a scheme-relative URL does not authorize a foreign private file")
        let expanded = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.20/" + String(repeating: "a", count: 4_000), name: "Long origin")],
            type: "series", videoId: "tt123:1:9", metadata: .init(filename: "large-list.mkv"),
            testURLProtocolClasses: fixtures)
        precondition(!expanded.isEmpty && expanded.count < 1_024,
                     "relative-URL expansion must stop at a finite aggregate budget")
        precondition(expanded.reduce(0) { $0 + $1.url.utf8.count }
                     <= AddonURLGuard.ResponseContext.subtitleIndex.maximumBytes)
        let changedOriginRedirect = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.9", name: "Redirect")], type: "series", videoId: "tt123:1:9",
            metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
        precondition(changedOriginRedirect.isEmpty, "redirect to a different private origin must fail")
        let nonHTTPRedirect = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.12", name: "Redirect")], type: "series", videoId: "tt123:1:9",
            metadata: .init(filename: "other-file.mkv"), testURLProtocolClasses: fixtures)
        precondition(nonHTTPRedirect.isEmpty, "non-HTTP redirect target must fail guard validation")
        // A valid installed endpoint may fit the QR envelope while its metadata resource does not.
        let longBase = "https://127.0.0.15/" + String(repeating: "a", count: 1_950)
        let longMetadata = SubtitleRequestMetadata(filename: String(repeating: "é", count: 80) + ".mkv")
        let longRequest = URL(string: longBase + "/" + longMetadata.resourcePath(type: "series", videoID: "tt123:1:9"))!
        precondition(longBase.utf8.count < AddonPairingProtocol.maxManifestURLBytes &&
                     longRequest.absoluteString.utf8.count > AddonPairingProtocol.maxManifestURLBytes)
        let longResult = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: longBase, name: "Configured router")], type: "series", videoId: "tt123:1:9",
            metadata: longMetadata, testURLProtocolClasses: fixtures)
        precondition(longResult.count == 1 && longResult[0].installedBaseURL.absoluteString == longBase,
                     "encoded metadata must use the subtitle resource budget, not the QR manifest budget")
        let normalScope = AddonURLGuard.AccessScope.addon(origin: URL(string: longBase)!)
        let manifestRejection = await AddonURLGuard.validate(longRequest, access: normalScope)
        precondition(manifestRejection != nil, "manifest URL budget remains unchanged")
        let oversizedURL = URL(string: "https://127.0.0.15/" +
                               String(repeating: "b", count: AddonURLGuard.ResponseContext.subtitleIndex.maximumURLBytes))!
        let resourceRejection = await AddonURLGuard.validate(oversizedURL, access: normalScope, context: .subtitleIndex)
        precondition(resourceRejection != nil, "subtitle resource URL budget remains finite")
        let duplicateSources = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.13", name: "First"),
                      .init(baseUrl: "https://127.0.0.14", name: "Second")],
            type: "series", videoId: "tt123:1:9", metadata: .init(filename: "same-file.mkv"),
            testURLProtocolClasses: fixtures)
        precondition(duplicateSources.count == 1 && duplicateSources[0].addonName == "First"
                     && duplicateSources[0].installedBaseURL.host == "127.0.0.13",
                     "first source keeps dedup winner and its original provenance")
        print("PASS bounded guarded subtitle-index fixture contracts")
    }
}
