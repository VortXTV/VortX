// Fixture-driven executable proof for the community JavaScript add-on contract.
//
//   xcrun swiftc -framework JavaScriptCore -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/community-js-provider-proof \
//     app/SourcesShared/JSProviders/JSProviderURLPolicy.swift \
//     app/SourcesShared/JSProviders/JSProviderManifest.swift \
//     app/SourcesShared/JSProviders/JSProviderStreamMapping.swift \
//     app/SourcesShared/JSProviders/JSProviderRuntime.swift \
//     app/Tests/CommunityJSProviderFunctionalProofTests.swift && /tmp/community-js-provider-proof
//
// This uses a local, non-network fixture manifest and CommonJS provider. It proves that a strict manifest
// entry can produce a provider result, preserve required playback headers, map into the app's source shape,
// and yield a selectable HTTP stream URL.

import Foundation
import JavaScriptCore

enum VXProbe {
    static func log(_ channel: String, _ message: String) {}
}

struct CoreStreamBehaviorHints: Decodable, Equatable, Sendable {
    let proxyHeaders: CoreProxyHeaders?
}

struct CoreProxyHeaders: Decodable, Equatable, Sendable {
    let request: [String: String]?
}

struct CoreStream: Decodable, Equatable, Sendable {
    let url: String?
    let name: String?
    let description: String?
    let vortxProvider: String?
    let behaviorHints: CoreStreamBehaviorHints?
}

struct CoreStreamSourceGroup: Identifiable, Equatable, Sendable {
    let id: String
    let addon: String
    let streams: [CoreStream]
}

@main
struct CommunityJSProviderFunctionalProofTests {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let manifestData = Data("""
        {
          "name": "Local fixture",
          "version": "1",
          "scrapers": [{
            "id": "fixture-provider",
            "name": "Fixture provider",
            "supportedTypes": ["movie", "tv"],
            "filename": "providers/fixture-provider.js",
            "enabled": true
          }]
        }
        """.utf8)
        let manifest = try? JSONDecoder().decode(JSProviderManifest.self, from: manifestData)
        expect(manifest?.scrapers.count == 1, "fixture manifest decodes one provider")
        guard let entry = manifest?.scrapers.first else { exit(1) }
        expect(entry.isSafeForInstallation, "fixture entry passes strict validation")
        expect(JSProviderManifestLoader.manifestURL(from: "https://fixtures.example/addons")?.absoluteString
               == "https://fixtures.example/addons/manifest.json", "bare manifest root normalizes")
        expect(JSProviderManifestLoader.providerURL(
            for: entry, manifestURL: URL(string: "https://fixtures.example/addons/manifest.json")!
        )?.absoluteString == "https://fixtures.example/addons/providers/fixture-provider.js", "relative provider stays same-origin")

        let unsafe = JSProviderManifest.Entry(
            id: "../unsafe", name: nil, version: nil, supportedTypes: ["movie"],
            filename: "../private.js", enabled: true, hasSettings: nil, contentLanguage: nil, logo: nil
        )
        expect(!unsafe.isSafeForInstallation, "path traversal entry is refused")
        let escapedTraversal = JSProviderManifest.Entry(
            id: "escaped-unsafe", name: nil, version: nil, supportedTypes: ["movie"],
            filename: "%2E%2E/private.js", enabled: true, hasSettings: nil, contentLanguage: nil, logo: nil
        )
        expect(!escapedTraversal.isSafeForInstallation, "escaped path traversal entry is refused")
        expect(!JSProviderURLPolicy.default.isAllowed(URL(string: "http://127.0.0.1/private")!), "loopback playback URL is refused")

        let providerCode = """
        module.exports = {
          getStreams: function (tmdbId, mediaType, season, episode) {
            if (tmdbId !== '42' || mediaType !== 'movie' || season !== null || episode !== null) { return []; }
            return [{
              name: 'Fixture', title: 'Fixture Movie 1080p', quality: '1080p',
              url: 'https://media.example.test/movie.m3u8',
              headers: { 'Referer': 'https://fixtures.example/', 'User-Agent': 'Fixture/1.0' },
              size: 1048576
            }];
          }
        };
        """
        let context = JSContext()
        context?.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
        context?.evaluateScript(providerCode)
        let json = context?.evaluateScript("JSON.stringify(module.exports.getStreams('42', 'movie', null, null))")?.toString()
        let raw = json.flatMap { value in
            try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]]
        } ?? []
        expect(raw.count == 1, "CommonJS fixture emits one stream")

        let installed = JSInstalledProvider(id: entry.id, name: entry.displayName, version: nil,
                                            supportedTypes: ["movie", "tv"], hasSettings: false, code: providerCode)
        let group = JSProviderStreamMapping.group(from: raw, provider: installed)
        let stream = group?.streams.first
        expect(group?.addon == "Fixture provider", "mapped result retains provider grouping")
        expect(stream?.vortxProvider == "jsplugin:fixture-provider", "mapped result retains provenance")
        expect(stream?.behaviorHints?.proxyHeaders?.request?["Referer"] == "https://fixtures.example/",
               "mapped result preserves playback referer")
        expect(URL(string: stream?.url ?? "")?.scheme == "https", "mapped result exposes selectable HTTPS stream")

        if failures.isEmpty {
            print("Community JS provider functional proof: PASS (12 checks)")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
