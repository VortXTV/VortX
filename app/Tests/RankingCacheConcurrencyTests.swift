import Foundation
import os

// Peripheral URL routing and profile policy are not this test's scope. The whole actual ranker, actual
// CoreStream stored fields/NZB classification, actual SourcePreferences.Snapshot and real OS lock compile.
extension CoreStream {
    var playableURL: URL? { url.flatMap(URL.init(string:)) }
    var isYouTubeTrailer: Bool { url == nil && infoHash == nil && ytId != nil }
}
enum ProfileStore { static func activeIsKids() -> Bool { false } }
struct RankingAudioSnapshot { let audioLanguages: [String] }
enum TrackPreferences {
    @TaskLocal static var audioLanguagesOverride: [String]?
    static var current: RankingAudioSnapshot { RankingAudioSnapshot(audioLanguages: audioLanguagesOverride ?? []) }
}

private func prefs(order: [SourceType] = SourceType.allCases, prefer: [String] = [],
                   avoid: [String] = [], behavior: String = "hide", regex: NSRegularExpression? = nil,
                   regexMode: Bool = false) -> SourcePreferences.Snapshot {
    SourcePreferences.Snapshot(useAddonOrder: false, typeOrder: order, noFiltersActive: false,
        keywordsAreRegex: regexMode, excludeRegex: regex, includeRegex: nil,
        excludeTerms: avoid, includeTerms: [], preferTerms: prefer, avoidBehavior: behavior,
        autoPickBest: false, safetyMode: "off", instantOnly: false, hideDeadTorrents: false,
        excludeAV1: false, hdrOnly: false, maxResolution: 0, minResolution: 0,
        hideUnknownResolution: false, preferredAudioOnly: false, maxFileSizeGB: 0)
}
private func stream(_ json: String) throws -> CoreStream {
    try JSONDecoder().decode(CoreStream.self, from: Data(json.utf8))
}
private func score(_ stream: CoreStream, _ prefs: SourcePreferences.Snapshot,
                   language: [String] = [], cached: Set<String> = []) -> Int {
    SourcePreferences.readingOverride.withValue(prefs) {
        TrackPreferences.$audioLanguagesOverride.withValue(language) {
            StreamRanking.score(stream, debridCachedHashes: cached)
        }
    }
}
private func require(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), "FAIL: " + name)
    print("PASS: " + name)
}

@main enum RankingCacheConcurrencyTests {
    static func main() async throws {
        let base = try stream(#"{"url":"https://fixture.invalid/movie","name":"Film 2026 1080p WEB English"}"#)
        let plain = prefs(), preferred = prefs(prefer: ["web"])
        let baseline = score(base, plain)
        // Task.detached does not inherit the caller's task locals. Install the captured
        // snapshot inside its synchronous scope, then verify nested and final restoration.
        let detached = SourcePreferences.readingOverride.withValue(plain) {
            Task.detached {
                let startedEmpty = SourcePreferences.readingOverride.get() == nil
                let scores = SourcePreferences.readingOverride.withValue(preferred) {
                    let first = StreamRanking.score(base)
                    let nested = SourcePreferences.readingOverride.withValue(plain) {
                        StreamRanking.score(base)
                    }
                    return (first, nested, StreamRanking.score(base))
                }
                return (startedEmpty, scores, SourcePreferences.readingOverride.get() == nil)
            }
        }
        let detachedResult = await detached.value
        require(detachedResult.0 && detachedResult.1.0 == baseline + 2500 &&
                detachedResult.1.1 == baseline && detachedResult.1.2 == baseline + 2500 &&
                detachedResult.2 && SourcePreferences.readingOverride.get() == nil,
                "detached snapshot scopes isolate, nest and restore the actual TaskLocal key")
        let sameNameA = CoreStreamSourceGroup(id: "https://a.invalid/config", addon: "AIOStreams", streams: [base])
        let sameNameB = CoreStreamSourceGroup(id: "https://b.invalid/config", addon: "AIOStreams", streams: [base])
        let variantsA = SourcePreferences.readingOverride.withValue(plain) {
            StreamRanking.variantOptions([sameNameA, sameNameB], tier: "1080p")
        }
        let variantsB = SourcePreferences.readingOverride.withValue(plain) {
            StreamRanking.variantOptions([sameNameB, sameNameA], tier: "1080p")
        }
        require(variantsA.first?.groupID == sameNameA.id && variantsB.first?.groupID == sameNameB.id
                    && variantsA.first?.addon == "AIOStreams" && variantsB.first?.addon == "AIOStreams",
                "actual quality picker retains the selected configured identity when names and full streams are equal")
        require(score(base, preferred) == baseline + 2500 && score(base, plain) == baseline,
                "alternating captured prefer snapshots never share a score")

        let avoided = prefs(avoid: ["web"], behavior: "rank")
        require(score(base, avoided) == baseline - 20_000 && score(base, plain) == baseline,
                "Avoid edits apply immediately without an invalidate callback")
        let insensitive = try NSRegularExpression(pattern: "WEB", options: .caseInsensitive)
        let sensitive = try NSRegularExpression(pattern: "WEB")
        require(score(base, prefs(behavior: "rank", regex: insensitive, regexMode: true)) == baseline - 20_000 &&
                score(base, prefs(behavior: "rank", regex: sensitive, regexMode: true)) == baseline,
                "identical regex text with different options has distinct memo identity")
        require(score(base, prefs(avoid: ["web"], behavior: "hide")) == baseline &&
                score(base, prefs(behavior: "rank", regexMode: true)) == baseline,
                "hide mode and invalid/absent regex preserve the original score")

        let reordered = prefs(order: [.direct, .torrent, .usenet, .debrid, .mediaServer])
        let directOrderBaseline = score(base, reordered)
        require(directOrderBaseline != baseline && score(base, plain) == baseline,
                "source priority snapshots are isolated in both directions")
        let server = try stream(#"{"url":"https://fixture.invalid/movie","name":"Film 2026 1080p WEB English","vortxProvider":"fixture-server"}"#)
        require(score(server, plain) != baseline && score(base, plain) == baseline,
                "media-server provenance cannot reuse an otherwise identical stream score")

        let torrent = try stream(#"{"infoHash":"ABCDEF","name":"Film 2026 1080p WEB"}"#)
        let nzb = try stream(#"{"infoHash":"ABCDEF","name":"Film 2026 1080p WEB","nzbUrl":"https://fixture.invalid/a.nzb"}"#)
        require(score(torrent, plain) != score(nzb, plain), "NZB-aware torrent classification belongs to score identity")
        let torrentBaseline = score(torrent, plain)
        require(score(torrent, plain, cached: ["abcdef"]) == torrentBaseline + 8000 &&
                score(torrent, plain, cached: ["unrelated"]) == torrentBaseline,
                "confirmed cache membership belongs to this exact torrent")
        require(score(base, plain, language: ["fr"]) == baseline - 5000 &&
                score(base, plain, language: ["en", " EN ", ""]) == baseline,
                "canonical session audio remains part of score identity")

        let filename = try stream(#"{"url":"https://fixture.invalid/movie","behaviorHints":{"filename":"Film.2160p.Remux.mkv"}}"#)
        require(StreamRanking.qualityLabel(filename) == "4K" && StreamRanking.qualityLabel(base) == "1080p",
                "text and label memo use all exact parsing fields")
        require(StreamRanking.matches("a", "[") == false && StreamRanking.matches("a", "[") == false,
                "invalid fixed regex remains a harmless cached miss")

        let failures = OSAllocatedUnfairLock(initialState: 0)
        // One test process, two bounded workers: this exercises real cross-thread memo/TaskLocal access.
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for iteration in 0..<400 {
                let wantPreferred = (worker + iteration) % 2 == 0
                let actual = score(base, wantPreferred ? preferred : plain)
                if actual != baseline + (wantPreferred ? 2500 : 0) { failures.withLock { $0 += 1 } }
                if iteration % 20 == 0 { StreamRanking.invalidateCaches() }
            }
        }
        require(failures.withLock { $0 } == 0, "concurrent profile snapshots and invalidations keep all 800 scores correct")

        let memo = RankingMemo<String, Int>(capacity: 2)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let value = memo.value(for: "key") { entered.signal(); resume.wait(); return 1 }
            precondition(value == 1)
            done.signal()
        }
        require(entered.wait(timeout: .now() + 5) == .success, "in-flight miss reaches deterministic barrier")
        memo.invalidate()
        resume.signal()
        require(done.wait(timeout: .now() + 5) == .success, "invalidation never holds lock across computation")
        require(memo.value(for: "key") { 2 } == 2, "retired miss cannot repopulate a cleared cache")
        let optional = RankingMemo<String, Int?>(capacity: 2)
        require(optional.value(for: "nil") { nil } == nil && optional.value(for: "nil") { 5 } == nil,
                "optional nil is cached as a value, not mistaken for absence")
        _ = memo.value(for: "second") { 3 }
        _ = memo.value(for: "third") { 4 }
        require(memo.value(for: "key") { 9 } == 9, "bounded capacity retires old entries without changing computation")
        print("All ranking/cache groups passed; live stores, UI/native routing and full app Swift 6 remain separate gates.")
    }
}
