// Focused executable checks for the real Newznab parser and request builder.
// Run: xcrun swiftc app/Tests/NZBIndexerClientTestStubs.swift app/SourcesShared/NZBIndexerModels.swift app/SourcesShared/NZBIndexerClient.swift app/Tests/NZBIndexerClientTests.swift -o /tmp/nzb-indexer-tests && /tmp/nzb-indexer-tests
import Foundation

@main private enum NZBIndexerClientTests {
    @MainActor static func main() throws {
        let endpoint = URL(string: "https://api.nzbgeek.example/api")!
        let movie = NZBIndexerClient.Search(title: "A & B + C", imdbID: "tt123", season: nil, episode: nil, isSeries: false)
        let url = try require(NZBIndexerClient.requestURL(endpoint: endpoint, apiKey: "a&b=c", search: movie))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(query.first(where: { $0.name == "apikey" })?.value == "a&b=c", "API key query escaping")
        check(query.first(where: { $0.name == "imdbid" })?.value == "123", "movie request uses Newznab numeric imdb id")
        let series = NZBIndexerClient.Search(title: "Show", imdbID: nil, season: 2, episode: 7, isSeries: true)
        let seriesURL = try require(NZBIndexerClient.requestURL(endpoint: endpoint, apiKey: "key", search: series))
        let sq = URLComponents(url: seriesURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(sq.first(where: { $0.name == "t" })?.value == "tvsearch" && sq.first(where: { $0.name == "season" })?.value == "2" && sq.first(where: { $0.name == "ep" })?.value == "7", "series coordinates")
        let fallback = try require(NZBIndexerClient.requestURL(endpoint: endpoint, apiKey: "key", search: series, fallback: true))
        check(URLComponents(url: fallback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value == "search", "generic search fallback")
        let valid = Data("<rss><channel><item><title>Movie.2026.1080p</title><enclosure url='https://index.example/get/1' length='42'/></item><item><title>bad</title><enclosure url='file:///tmp/x'/></item></channel></rss>".utf8)
        let releases = try NZBIndexerClient.parse(data: valid)
        check(releases.count == 1 && releases[0].title == "Movie.2026.1080p" && releases[0].size == 42, "valid movie and unsafe enclosure rejection")
        for code in [100, 101] { do { _ = try NZBIndexerClient.parse(data: Data("<error code='\(code)'/>".utf8)); check(false, "API error \(code)") } catch NZBIndexerClient.Failure.api(let got) { check(got == code, "API error \(code)") } }
        do { _ = try NZBIndexerClient.parse(data: Data("<rss><item>".utf8)); check(false, "malformed XML") } catch { check(true, "malformed XML") }
        let unknown = NZBIndexerClient.Search(title: "Show", imdbID: nil, season: nil, episode: nil, isSeries: true)
        check(NZBIndexerClient.requestURL(endpoint: endpoint, apiKey: "key", search: unknown) == nil, "series without coordinates cannot search movies")
        for xml in ["<html>error</html>", "<!DOCTYPE rss [<!ENTITY test 'a'>]><rss/>"] {
            do { _ = try NZBIndexerClient.parse(data: Data(xml.utf8)); check(false, "reject non-RSS/entities") }
            catch { check(true, "reject non-RSS/entities") }
        }
        let unsafe = Data("<rss><channel><item><title>x</title><enclosure url='https://user:pass@example.com/a'/></item></channel></rss>".utf8)
        check(try NZBIndexerClient.parse(data: unsafe).isEmpty, "reject enclosure userinfo")
        let scope = NZBIndexerStore.captureScope()
        let config = NZBIndexerConfig(id: "one", name: "One", endpoint: endpoint.absoluteString)
        check(NZBIndexerStore.save(config, apiKey: "secret", scope: scope)?.indexers.count == 1, "secure save")
        check(NZBIndexerStore.save(config, apiKey: "", scope: scope) != nil && NZBIndexerStore.apiKey(for: "one", scope: scope) == "secret", "blank edit retains key")
        let account = NZBIndexerStore.metadataAccount(scope)
        let before = Keychain.values[account]
        ProfileStore.shared.activeID = UUID()
        check(NZBIndexerStore.save(config, apiKey: "changed", scope: scope) == nil && Keychain.values[account] == before, "profile-switch stale editor cannot write")
        check(NZBIndexerStore.apiKey(for: "one", scope: scope) == nil, "profile-switch stale search cannot read key")
        ProfileStore.shared.activeID = scope.profileID
        CredentialScopeRegistry.shared.generation += 1
        check(NZBIndexerStore.remove(indexerID: "one", scope: scope) == nil, "same-account new-session rejects stale remove")
        let fresh = NZBIndexerStore.captureScope()
        Keychain.failReads = true
        check(NZBIndexerStore.save(config, apiKey: "new", scope: fresh) == nil && Keychain.values[account] == before, "unreadable is not missing")
        Keychain.failReads = false
        Keychain.values[account] = "{bad JSON"
        check(NZBIndexerStore.save(config, apiKey: "new", scope: fresh) == nil && Keychain.values[account] == "{bad JSON", "corrupt document not overwritten")
        Keychain.values[account] = before
        Keychain.failWrites = true
        check(NZBIndexerStore.remove(indexerID: "one", scope: fresh) == nil && Keychain.values[account] == before, "failed secure write preserves record")
        Keychain.failWrites = false
        check(NZBIndexerStore.remove(indexerID: "one", scope: fresh)?.indexers.isEmpty == true && NZBIndexerStore.apiKey(for: "one", scope: fresh) == nil, "remove metadata and key atomically")
        if failures > 0 { exit(1) }
    }
    static var failures = 0
    static func check(_ condition: Bool, _ label: String) { if condition { print("PASS  \(label)") } else { failures += 1; print("FAIL  \(label)") } }
    static func require<T>(_ value: T?) throws -> T { guard let value else { throw NSError(domain: "NZBIndexerClientTests", code: 1) }; return value }
}
