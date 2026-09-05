// Executable contract for bounded Apple NZB playback routing and add-on metadata preservation.
//
// Run from repository root:
// swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//   -o /tmp/usenet-node-routing app/SourcesShared/UsenetStreamValidation.swift \
//   app/Tests/UsenetNodeRoutingContractTests.swift && /tmp/usenet-node-routing

import Foundation

private struct AddonNZBFixture: Decodable {
    let nzbUrl: String?
    let nzbUrls: [String]?
    let servers: [String]?
    let fileMustInclude: String?

}

@main @MainActor
private enum UsenetNodeRoutingContractTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let models = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/CoreModels.swift"), encoding: .utf8)
        let bridge = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/CoreBridge.swift"), encoding: .utf8)
        let server = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/StremioServer.swift"), encoding: .utf8)
        let resolver = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/UsenetProvider.swift"), encoding: .utf8)
        let nodeClient = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/UsenetNodeClient.swift"), encoding: .utf8)
        let coordinator = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/DebridResolver.swift"), encoding: .utf8)

        let json = #"{"nzbUrl":"https://one.example/show.nzb","nzbUrls":["https://two.example/show.nzb","https://user:secret@private.example/show.nzb","file:///not-an-nzb"],"servers":["nntps://user:secret@news.example:563/10","https://not-nntp.example"],"fileMustInclude":"S01E02"}"#
        let decoded = try JSONDecoder().decode(AddonNZBFixture.self, from: Data(json.utf8))
        check("decodes singular and plural NZB fields", decoded.nzbUrl != nil && decoded.nzbUrls?.count == 3)
        check("keeps fileMustInclude as a string", decoded.fileMustInclude == "S01E02")
        let nzbs = UsenetStreamValidation.nzbURLs(singular: decoded.nzbUrl, plural: decoded.nzbUrls)
        let servers = UsenetStreamValidation.nntpServers(decoded.servers)
        check("production validation rejects credential-bearing NZB URLs and keeps NNTP credentials", nzbs.count == 2 && servers.count == 1)
        check("production validation rejects host-only or malformed Node NNTP hints",
              UsenetStreamValidation.nntpServers(["nntps://news.example", "nntps://u:p@news.example:563", "nntps://u:p@news.example:563/0"]).isEmpty)
        check("Node TLS scheme and credential delimiters are canonicalized without changing credentials",
              UsenetStreamValidation.nntpServers(["NNTPS://u:p%3Aa%40b@NEWS.example:563/4"])
                == ["nntps://u:p%3Aa%40b@news.example:563/4"])
        check("unsupported Node IPv6 host does not reach the parser",
              UsenetStreamValidation.nntpServers(["nntps://u:p@[::1]:563/4"]).isEmpty)
        check("production validation preserves plural-only identity", UsenetStreamValidation.nzbURLs(singular: nil, plural: ["https://only.example/a.nzb"]) == ["https://only.example/a.nzb"])
        check("plural-only NZB plus infohash is Usenet, never both Usenet and torrent", UsenetStreamValidation.isUsenet(url: nil, singular: nil, plural: ["https://only.example/a.nzb"])
              && !UsenetStreamValidation.isTorrent(url: nil, infoHash: "abc", singular: nil, plural: ["https://only.example/a.nzb"]))
        check("plural-only NZB has a stable non-placeholder identity", UsenetStreamValidation.streamIdentity(url: nil, externalURL: nil, infoHash: nil, singular: nil, plural: ["https://only.example/a.nzb"]) == "https://only.example/a.nzb")
        check("NZB identity wins over a redundant torrent hash", UsenetStreamValidation.streamIdentity(url: nil, externalURL: nil, infoHash: "same-hash", singular: nil, plural: ["https://only.example/a.nzb"]) != UsenetStreamValidation.streamIdentity(url: nil, externalURL: nil, infoHash: "same-hash", singular: nil, plural: ["https://only.example/b.nzb"]))

        check("production stream preserves add-on fields", models.contains("let nzbUrls: [String]?")
              && models.contains("let servers: [String]?") && models.contains("let fileMustInclude: String?"))
        check("production stream validates before local use", models.contains("var usenetURLs: [String]")
              && models.contains("var usenetServers: [String]"))
        check("CoreBridge round-trips plural NZBs and servers", bridge.contains("raw[\"nzbUrls\"] = nzbs")
              && bridge.contains("raw[\"servers\"] = servers"))
        check("NZB control route is Node-only and follows the discovered port", server.contains("static var usenetNodeBase: String?")
              && server.contains("if let port = NodeServer.discoveredPort")
              && server.contains("never guess 11470 while native is active"))
        check("resolver posts the Node NZB contract and never generic embedded", resolver.contains("StremioServer.usenetNodeBase")
              && resolver.contains("UsenetNodeClient.createStream") && nodeClient.contains("\"nzbUrls\": nzbURLs")
              && !resolver.contains("let base = StremioServer.embedded"))
        check("add-on server order is tried before a sequential saved-provider fallback",
              resolver.contains("UsenetRoutingPolicy.localAttempts") && resolver.contains("UsenetRoutingPolicy.firstSuccessful(attempts"))
        check("local Node work is leased to its credential authority", coordinator.contains("runProvider(capture: usenetCapture, revision: usenetRevision)")
              && coordinator.contains("guard isCurrent(usenetCapture, revision: usenetRevision) else { return nil }"))
        for path in ["app/Sources/PlayerScreen.swift", "app/SourcesTV/TVPlayerView.swift"] {
            let player = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            check("\(path) uses the current NZB route for bounded recovery",
                  player.contains("ref.usenetRoute != nil && retrySource?.isUsenet == true")
                    && player.contains("ref.url != curURL { return false }")
                    && player.contains("DebridCoordinator.shared.recoverUsenetPlayback(")
                    && player.contains("if let freshRef = resolvedRef"))
        }
        check("resolver returns Node redirect endpoint rather than raw NZB", resolver.contains("/nzb/stream?key="))
        check("coordinator supplies add-on mirrors and servers", coordinator.contains("nzbURLs: stream.usenetURLs, servers: stream.usenetServers"))
        check("explicit NZB playback has a typed result while auto retains optional resolution", coordinator.contains("enum ExplicitUsenetResolution")
              && coordinator.contains("func resolveExplicitUsenetPlayback") && coordinator.contains("func resolvedPlaybackRef"))
        check("CoreBridge server data stays on the private engine-player path", bridge.contains("private func rawStreamDict")
              && bridge.contains("func loadEnginePlayer(for stream: CoreStream"))

        if failures > 0 { throw NSError(domain: "UsenetNodeRoutingContract", code: failures) }
    }
}
