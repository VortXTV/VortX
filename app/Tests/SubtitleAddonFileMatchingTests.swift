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
        let encodedPath = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        } ?? ""
        let resourceComponent = encodedPath.split(separator: "/").last ?? ""
        // Metadata extras share one final route component. Hash/size precede filename when
        // present; inspect the encoded component so an escaped filename slash cannot split it.
        let hasMetadata = ["videoHash=", "videoSize=", "filename="].contains {
            resourceComponent.hasPrefix($0)
        }
        if host == "127.0.0.22" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let body: String
        if host == "127.0.0.21" {
            body = "{invalid-json"
        } else if host == "127.0.0.24" {
            body = #"{"error":"fixture-unavailable"}"#
        } else if host == "127.0.0.16" {
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
        let nonemptyLegacyForEmptySource = await SubtitleAddonService.fetch(
            sources: [.init(baseUrl: "https://127.0.0.5", name: "Empty")], type: "series", videoId: "tt123:1:9",
            testURLProtocolClasses: fixtures)
        precondition(nonemptyLegacyForEmptySource.count == 1
                     && nonemptyLegacyForEmptySource[0].url == "https://cdn.invalid/legacy.srt",
                     "Empty metadata success must retain a nonempty legacy-route negative control")
        for requestMetadata in [SubtitleRequestMetadata(videoHash: "0123456789abcdef"),
                         SubtitleRequestMetadata(videoSize: 6_750_000_000), metadata] {
            let emptyOutcome = await SubtitleAddonService.fetchOutcome(
                sources: [.init(baseUrl: "https://127.0.0.5", name: "Empty")], type: "series", videoId: "tt123:1:9",
                metadata: requestMetadata, testURLProtocolClasses: fixtures)
            precondition(emptyOutcome.sources.count == 1 && emptyOutcome.subtitles.isEmpty)
            if case .success(let rows) = emptyOutcome.sources[0].status { precondition(rows.isEmpty) }
            else { preconditionFailure("Valid empty hash/size/full-metadata response became a failure") }
        }
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
        let outcomeSources = [
            SubtitleAddonSource(baseUrl: "https://127.0.0.1/", name: "Success"),
            SubtitleAddonSource(baseUrl: "https://127.0.0.5/", name: "Empty success"),
            SubtitleAddonSource(baseUrl: "https://127.0.0.21/", name: "Malformed response"),
            SubtitleAddonSource(baseUrl: "https://127.0.0.22/", name: "Transport failure"),
            SubtitleAddonSource(baseUrl: "https://127.0.0.24/", name: "Invalid response shape"),
        ]
        let outcome = await SubtitleAddonService.fetchOutcome(sources: outcomeSources, type: "series", videoId: "tt123:1:9",
            metadata: metadata, testURLProtocolClasses: fixtures)
        precondition(outcome.sources.count == 5 && outcome.subtitles.count == 2)
        if case .success(let empty) = outcome.sources[1].status { precondition(empty.isEmpty) }
        else { preconditionFailure("Successful empty list became a retryable failure") }
        for index in 2..<outcome.sources.count {
            if case .failed = outcome.sources[index].status {} else { preconditionFailure("Failure became empty success") }
        }
        verifyDiscoveryState(outcome: outcome)
        verifyResolutionState()
        verifyDiscoveryCallerContracts()
        print("PASS bounded guarded subtitle-index fixture contracts")
    }
    private static func verifyDiscoveryState(outcome: SubtitleAddonService.FetchOutcome) {
        let sources = outcome.sources.map(\.source)
        var state = SubtitleAddonService.DiscoveryState()
        let first = state.begin(key: "title-file", sources: sources, retryFailures: false)!
        precondition(state.begin(key: "title-file", sources: sources, retryFailures: true) == nil,
            "Panel reopen duplicated an in-flight batch")
        var renamed = sources
        renamed[0] = SubtitleAddonSource(baseUrl: sources[0].baseUrl, name: "Updated display name")
        precondition(state.begin(key: "title-file", sources: renamed, retryFailures: true) == nil,
            "Display-name change duplicated an installed endpoint in flight")
        precondition(state.finish(first, outcome: outcome))
        precondition(outcome.failedSourceCount == 3 && state.failedSourceCount == 3)
        let successful = state.subtitles
        precondition(state.begin(key: "title-file", sources: sources, retryFailures: false) == nil,
            "Ordinary reconciliation retried failures")
        let retry = state.begin(key: "title-file", sources: sources, retryFailures: true)!
        precondition(retry.sources == Array(sources.dropFirst(2)), "Retry must exclude success AND empty success")
        precondition(state.subtitles == successful, "Retry erased a successful source's candidates")
        precondition(state.begin(key: "title-file", sources: sources, retryFailures: true) == nil)
        precondition(state.finish(retry, outcome: .init(sources: retry.sources.map { .init(source: $0, status: .success([])) })))
        precondition(state.begin(key: "title-file", sources: sources, retryFailures: true) == nil)
        state.updateSources(Array(sources.dropFirst()))
        precondition(state.subtitles.isEmpty, "Removed source remained visible")
        precondition(state.begin(key: "title-file", sources: sources, retryFailures: false) == nil)
        precondition(state.subtitles == successful)
        let configSources = [
            SubtitleAddonSource(baseUrl: "https://127.0.0.30/Config/A?token=Upper", name: "Same label"),
            SubtitleAddonSource(baseUrl: "https://127.0.0.30/Config/a?token=Upper", name: "Same label"),
            SubtitleAddonSource(baseUrl: "https://127.0.0.30/Config/A?token=upper", name: "Same label"),
        ]
        var configured = SubtitleAddonService.DiscoveryState()
        precondition(configured.begin(key: "same-title", sources: configSources, retryFailures: false)?.sources == configSources,
            "Case-sensitive path or complete configuration query was lost from endpoint identity")
        let added = SubtitleAddonSource(baseUrl: "https://127.0.0.23/", name: "Late installation")
        let late = state.begin(key: "title-file", sources: sources + [added], retryFailures: false)!
        precondition(late.sources == [added] && state.subtitles == successful)
        state.updateSources(sources) // Removal hides rows but must not duplicate in-flight work on re-add.
        precondition(state.begin(key: "title-file", sources: sources + [added], retryFailures: true) == nil)
        let next = state.begin(key: "next-title-file", sources: sources, retryFailures: false)!
        precondition(!state.finish(late, outcome: .init(sources: [.init(source: added, status: .success(successful))])),
            "Prior title/resource completion crossed generation")
        state.reset() // Caller resets on account/profile/player/load generation change.
        precondition(!state.finish(next, outcome: outcome), "Retired owner completion republished candidates")
    }

    private static func verifyResolutionState() {
        let old = SubtitleAddonService.QueryIdentity(type: "movie", libraryID: "tmdb:1", videoID: "tmdb:1")
        let next = SubtitleAddonService.QueryIdentity(type: "series", libraryID: "tmdb:2", videoID: "tmdb:2:1:1")
        precondition(old != next)
        var state = SubtitleAddonService.ResolutionState()
        let first = state.begin(query: old)!
        precondition(state.begin(query: old) == nil, "Duplicate media resolver admitted")
        state.reset() // The real caller's query-aware owner resets BEFORE its pending resolver guard.
        let second = state.begin(query: next)!
        precondition(!state.finish(first, currentQuery: next), "Stale resolver published another media query")
        precondition(state.pending == second, "Stale resolver cleared the next media's pending request")
        precondition(state.finish(second, currentQuery: next))
        let third = state.begin(query: old)!
        precondition(!state.finish(third, currentQuery: next) && state.pending == nil,
            "Exact old request mismatch left a permanent resolver latch")
    }

    private static func verifyDiscoveryCallerContracts() {
        for relative in ["app/Sources/PlayerScreen.swift", "app/SourcesTV/TVPlayerView.swift"] {
            let source = try! String(contentsOfFile: relative, encoding: .utf8)
            let start = source.range(of: "    private func fetchAddonSubtitles(retryFailures:")!.lowerBound
            let end = source.range(of: "    /// Auto-load an ADD-ON subtitle", range: start..<source.endIndex)!.lowerBound
            let caller = String(source[start..<end])
            let ownerStart = source.range(of: "    private struct AddonSubtitleFetchOwner:")!.lowerBound
            let ownerEnd = source.range(of: "    @State private var addonSubsOwner", range: ownerStart..<source.endIndex)!.lowerBound
            let owner = String(source[ownerStart..<ownerEnd])
            precondition(owner.contains("let query: SubtitleAddonService.QueryIdentity"), "Resolver owner lost media identity")
            precondition(caller.contains("query: .init(type: m.type, libraryID: m.libraryId, videoID: m.videoId)"))
            let reset = caller.range(of: "addonSubsResolution.reset()")!.lowerBound
            let pending = caller.range(of: "guard addonSubsResolution.pending == nil")!.lowerBound
            precondition(reset < pending, "New media must retire old resolver before checking its latch")
            precondition(caller.contains("addonSubsResolution.pending == request"))
            precondition(caller.contains("addonSubsResolution.finish(request, currentQuery: owner.query)"))
            let fetch = caller.range(of: "let outcome = await SubtitleAddonService.fetchOutcome")!.lowerBound
            let completion = String(caller[fetch...])
            precondition(discoveryPublicationIsFenced(completion), "Missing subtitle discovery publication fence")
            for fence in discoveryPublicationFences {
                precondition(!discoveryPublicationIsFenced(completion.replacingOccurrences(of: fence, with: "true")),
                    "Missing discovery fence was accepted by the contract")
            }
            precondition(!completion.contains("addedSubURLs = []"), "Retry completion cleared already loaded URLs")
            precondition(source.contains("fetchAddonSubtitles(retryFailures: true)"), "Explicit panel retry missing")
            precondition(caller.contains("fetchAddonSubtitles()"), "New installed source reconciliation missing")
        }
    }

    private static let discoveryPublicationFences = [
        "!Task.isCancelled", "addonSubsOwner == owner", "addonSubsKey == key", "player === coordinator.player",
        "player.activeLoadToken == load", "target.stillOwnsCurrentContext(core: core)",
        "loadLifetime?.isCurrent != false", "CredentialScopeRegistry.shared.isCurrent(credential)",
        "LegacyWatchOwnership.applicationEpochIsCurrent(applicationEpoch)", "curMeta?.type == m.type",
        "curMeta?.videoId == m.videoId", "curMeta?.libraryId == m.libraryId", "subtitleMetadata ?? .init()) == metadata",
    ]
    private static func discoveryPublicationIsFenced(_ completion: String) -> Bool {
        guard let finish = completion.range(of: "addonSubsRequests.finish(request, outcome: outcome)")?.lowerBound,
              let publication = completion.range(of: "addonSubs = addonSubsRequests.subtitles")?.lowerBound,
              finish < publication else { return false }
        let admission = String(completion[..<finish])
        return discoveryPublicationFences.allSatisfy { admission.contains($0) }
    }

}
