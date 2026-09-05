// Executable contract for bounded Apple NZB playback routing and add-on metadata preservation.
//
// Run from repository root:
// swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//   -o /tmp/usenet-node-routing app/Tests/UsenetNodeRoutingContractTests.swift && /tmp/usenet-node-routing

import Foundation

private struct AddonNZBFixture: Decodable {
    let nzbUrl: String?
    let nzbUrls: [String]?
    let servers: [String]?
    let fileMustInclude: String?

    var nzbs: [String] {
        ([nzbUrl].compactMap { $0 } + (nzbUrls ?? [])).filter { value in
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
        }
    }

    var nntpServers: [String] {
        (servers ?? []).filter { value in
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "nntp" || scheme == "nntps") && url.host?.isEmpty == false
        }
    }
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
        let coordinator = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/DebridResolver.swift"), encoding: .utf8)

        let json = #"{"nzbUrl":"https://one.example/show.nzb","nzbUrls":["https://two.example/show.nzb","file:///not-an-nzb"],"servers":["nntps://user:secret@news.example:563/10","https://not-nntp.example"],"fileMustInclude":"S01E02"}"#
        let decoded = try JSONDecoder().decode(AddonNZBFixture.self, from: Data(json.utf8))
        check("decodes singular and plural NZB fields", decoded.nzbUrl != nil && decoded.nzbUrls?.count == 2)
        check("keeps fileMustInclude as a string", decoded.fileMustInclude == "S01E02")
        check("validates NZB mirrors and NNTP endpoints", decoded.nzbs.count == 2 && decoded.nntpServers.count == 1)

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
              && resolver.contains("\"nzbUrls\": validNZBs") && !resolver.contains("let base = StremioServer.embedded"))
        check("add-on server ordering does not silently mix saved credentials", resolver.contains("if localServers.isEmpty, let credentials, credentials.isValid"))
        check("resolver returns Node redirect endpoint rather than raw NZB", resolver.contains("/nzb/stream?key="))
        check("coordinator supplies add-on mirrors and servers", coordinator.contains("nzbURLs: stream.usenetURLs, servers: stream.usenetServers"))
        check("explicit NZB playback has a typed result while auto retains optional resolution", coordinator.contains("enum ExplicitUsenetResolution")
              && coordinator.contains("func resolveExplicitUsenetPlayback") && coordinator.contains("func resolvedPlaybackRef"))
        check("CoreBridge server data stays on the private engine-player path", bridge.contains("private func rawStreamDict")
              && bridge.contains("func loadEnginePlayer(for stream: CoreStream"))

        if failures > 0 { throw NSError(domain: "UsenetNodeRoutingContract", code: failures) }
    }
}
