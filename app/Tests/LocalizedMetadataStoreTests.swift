import Foundation

// The runner compiles complete production LocalizedMetadata.swift. These types replace
// unrelated app singletons; URLProtocol intercepts every request before any network I/O.
enum AppLanguage {
    struct Language { let code: String }
    static var current: String? = "es"
    static let supported = [Language(code: "es"), Language(code: "de")]
}
enum TrackPreferences { static let deviceLanguages = ["es"] }
enum RemoteConfig {
    static let snapshot = Snapshot()
    struct Snapshot {
        let catalogsEndpoint = URL(string: "https://fixture.invalid/3")!
        func isFeatureOn(_ key: String, default fallback: Bool) -> Bool { fallback }
    }
}
enum ApiKeys { static func tmdbKey() -> String? { nil } }
enum VortXEdgeAuth { static func sign(_ request: inout URLRequest) {} }
enum Fixture {
    static var now = Date(timeIntervalSince1970: 1_700_000_000)
    static var cacheURL: URL?
    static var status = 503
    static var payload = Data()
    static var calls = 0
}
final class FakeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Fixture.calls += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Fixture.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

var failures = 0
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL: " + message) }
}
@MainActor func settle() async { try? await Task.sleep(nanoseconds: 230_000_000) }

@MainActor func run() async {
    guard let directory = ProcessInfo.processInfo.environment["VORTX_L10N_TEST_DIRECTORY"] else {
        fatalError("Run with scripts/test-localized-metadata.mjs")
    }
    Fixture.cacheURL = URL(fileURLWithPath: directory).appendingPathComponent("metadata-fixture.json")
    let miss = LocalizedMeta(title: "", posterPath: "", logoPath: "")
    let old = ["es|ttold": miss,
               "es|ttkeep": LocalizedMeta(title: "Conservar", posterPath: "", logoPath: "")]
    try! JSONEncoder().encode(old).write(to: Fixture.cacheURL!)
    let store = LocalizedMetadataStore()
    expect(store.title(for: "ttkeep") == "Conservar", "legacy positive disk cache retained")

    Fixture.status = 200
    Fixture.payload = Data(#"{"items":{"ttold":{"title":"Recovered legacy","posterPath":"","logoPath":""}}}"#.utf8)
    store.resolve(ids: ["ttold"]); await settle()
    expect(store.title(for: "ttold") == "Recovered legacy", "legacy empty disk record does not suppress recovery")

    Fixture.status = 503; Fixture.payload = Data()
    store.resolve(ids: ["ttfailure"]); await settle()
    let failedCalls = Fixture.calls
    store.resolve(ids: ["ttfailure"]); await settle()
    expect(Fixture.calls == failedCalls, "transient HTTP failure is throttled during retry delay")
    Fixture.now = Fixture.now.addingTimeInterval(31)
    Fixture.status = 200
    Fixture.payload = Data(#"{"items":{"ttfailure":{"title":"Recovered","posterPath":"","logoPath":""}}}"#.utf8)
    store.resolve(ids: ["ttfailure"]); await settle()
    expect(Fixture.calls == failedCalls + 1 && store.title(for: "ttfailure") == "Recovered",
           "transient HTTP failure retries and recovers after cooldown")

    Fixture.payload = Data(#"{"items":7}"#.utf8)
    store.resolve(ids: ["ttmalformed"]); await settle()
    let malformedCalls = Fixture.calls
    Fixture.now = Fixture.now.addingTimeInterval(31)
    Fixture.payload = Data(#"{"items":{"ttmalformed":{"title":"Valid later","posterPath":"","logoPath":""}}}"#.utf8)
    store.resolve(ids: ["ttmalformed"]); await settle()
    expect(Fixture.calls == malformedCalls + 1 && store.title(for: "ttmalformed") == "Valid later",
           "malformed pool envelope does not become a permanent miss")

    Fixture.payload = Data(#"{"items":{"ttmiss":null}}"#.utf8)
    store.resolve(ids: ["ttmiss"]); await settle()
    let missCalls = Fixture.calls
    let saved = try! JSONDecoder().decode([String: LocalizedMeta].self, from: Data(contentsOf: Fixture.cacheURL!))
    expect(saved["es|ttmiss"] == nil && saved.values.allSatisfy { !$0.isEmpty },
           "disk cache persists positive metadata and excludes timestamp-less negatives")
    Fixture.now = Fixture.now.addingTimeInterval(31)
    store.resolve(ids: ["ttmiss"]); await settle()
    expect(Fixture.calls == missCalls, "accepted miss has a longer retry delay")
    Fixture.now = Fixture.now.addingTimeInterval(3601)
    Fixture.payload = Data(#"{"items":{"ttmiss":{"title":"New contribution","posterPath":"","logoPath":""}}}"#.utf8)
    store.resolve(ids: ["ttmiss"]); await settle()
    expect(store.title(for: "ttmiss") == "New contribution", "accepted miss expires for a later pool contribution")

    AppLanguage.current = "de"
    Fixture.payload = Data(#"{"items":{"ttfailure":{"title":"Wiederhergestellt","posterPath":"","logoPath":""}}}"#.utf8)
    store.resolve(ids: ["ttfailure"]); await settle()
    expect(store.title(for: "ttfailure") == "Wiederhergestellt", "another language has independent metadata and retry scope")
    AppLanguage.current = "es"
    expect(store.title(for: "ttfailure") == "Recovered", "switching language preserves its matching positive metadata")

    print("localized metadata: \(checks) checks, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in await run() }
dispatchMain()
