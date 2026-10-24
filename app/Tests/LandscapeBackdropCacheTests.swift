import Foundation

actor ArtworkRecorder {
    private var calls: [String: Int] = [:]
    func resolve(id: String, type: String) async -> (backdrop: String?, logo: String?) {
        let key = id + "|" + type
        calls[key, default: 0] += 1
        let attempt = calls[key]!
        try? await Task.sleep(nanoseconds: 30_000_000)
        if id == "retry" && attempt == 1 { return (nil, nil) }
        return ("backdrop:\(type):\(id)", "logo:\(type):\(id)")
    }
    func count(id: String, type: String) -> Int { calls[id + "|" + type, default: 0] }
}
enum TMDBClient {
    static let recorder = ArtworkRecorder()
    static func landscapeImages(metaID: String, type: String) async -> (backdrop: String?, logo: String?) {
        await recorder.resolve(id: metaID, type: type)
    }
}

actor CheckState {
    private var checks = 0
    private var failures = 0
    func record(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: " + message) }
    }
    func summary() -> (checks: Int, failures: Int) { (checks, failures) }
}
func run() async -> Int {
    let state = CheckState()
    async let movie = LandscapeBackdropCache.backdrop(id: "same-raw-id", type: "movie")
    async let series = LandscapeBackdropCache.backdrop(id: "same-raw-id", type: "series")
    let pair = await (movie, series)
    await state.record(pair.0 == "backdrop:movie:same-raw-id", "movie lookup retains its media type")
    await state.record(pair.1 == "backdrop:series:same-raw-id", "series lookup cannot join the movie's in-flight request")
    let movieCalls = await TMDBClient.recorder.count(id: "same-raw-id", type: "movie")
    let seriesCalls = await TMDBClient.recorder.count(id: "same-raw-id", type: "series")
    await state.record(movieCalls == 1 && seriesCalls == 1, "distinct media inputs resolve independently")
    let movieLogo = await LandscapeBackdropCache.logo(id: "same-raw-id", type: "movie")
    let seriesLogo = await LandscapeBackdropCache.logo(id: "same-raw-id", type: "series")
    await state.record(movieLogo == "logo:movie:same-raw-id" && seriesLogo == "logo:series:same-raw-id", "positive cache retains both typed results")

    async let one = LandscapeBackdropCache.backdrop(id: "coalesce", type: "movie")
    async let two = LandscapeBackdropCache.logo(id: "coalesce", type: "movie")
    _ = await (one, two)
    let sharedCalls = await TMDBClient.recorder.count(id: "coalesce", type: "movie")
    await state.record(sharedCalls == 1, "identical typed backdrop and logo requests share one resolve")
    let first = await LandscapeBackdropCache.backdrop(id: "retry", type: "movie")
    let second = await LandscapeBackdropCache.backdrop(id: "retry", type: "movie")
    let retryCalls = await TMDBClient.recorder.count(id: "retry", type: "movie")
    await state.record(first == nil && second == "backdrop:movie:retry" && retryCalls == 2, "empty transient result remains retryable")
    let result = await state.summary()
    print("landscape backdrop cache: \(result.checks) checks, \(result.failures) failed")
    return result.failures
}
@main enum LandscapeBackdropCacheTests {
    static func main() async {
        let failures = await run()
        exit(failures == 0 ? 0 : 1)
    }
}
