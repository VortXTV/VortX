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
    static func main() async {
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
            "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
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
            filename: "../private.js", sha256: String(repeating: "0", count: 64), enabled: true, hasSettings: nil, contentLanguage: nil, logo: nil
        )
        expect(!unsafe.isSafeForInstallation, "path traversal entry is refused")
        let escapedTraversal = JSProviderManifest.Entry(
            id: "escaped-unsafe", name: nil, version: nil, supportedTypes: ["movie"],
            filename: "%2E%2E/private.js", sha256: String(repeating: "0", count: 64), enabled: true, hasSettings: nil, contentLanguage: nil, logo: nil
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
        let testBootstrap = JSProviderRuntime.Bootstrap(cryptoJS: "", cheerio: "", preamble: """
        globalThis.__vortx_run = function(code, paramsJSON) {
          var params = JSON.parse(paramsJSON);
          var module = { exports: {} }; var exports = module.exports;
          (new Function('module', 'exports', 'params', code))(module, exports, params);
          var result = (typeof module.exports.getStreams === 'function') ? module.exports.getStreams(params.tmdbId, params.mediaType, params.season, params.episode) : [];
          Promise.resolve(result).then(function(value) { __vortx_native_complete(JSON.stringify(value)); });
        };
        """)
        let invocation = JSProviderRuntime.Invocation(providerID: entry.id, code: providerCode, tmdbId: "42",
                                                      mediaType: "movie", season: nil, episode: nil, settingsJSON: "{}")
        let runtimeResult = await JSProviderRuntime.shared.getStreams(invocation, timeout: 1, bootstrapOverride: testBootstrap)
        let raw: [[String: Any]]
        if case let .success(value) = runtimeResult { raw = value } else { raw = [] }
        expect(raw.count == 1, "bounded native runtime executes the CommonJS fixture")

        let loop = JSProviderRuntime.Invocation(providerID: "loop", code: "module.exports.getStreams=function(){ while(true){} };",
                                                tmdbId: "42", mediaType: "movie", season: nil, episode: nil, settingsJSON: "{}")
        let loopResult = await JSProviderRuntime.shared.getStreams(loop, timeout: 0.05, bootstrapOverride: testBootstrap)
        if case .failure(.timedOut) = loopResult {} else { failures.append("native interrupt terminates a synchronous loop") }
        let heap = JSProviderRuntime.Invocation(providerID: "heap", code: "module.exports.getStreams=function(){ var x=[]; while(true){ x.push(new Array(10000).fill('x')); } };",
                                                tmdbId: "42", mediaType: "movie", season: nil, episode: nil, settingsJSON: "{}")
        let heapResult = await JSProviderRuntime.shared.getStreams(heap, timeout: 1, bootstrapOverride: testBootstrap)
        if case .success = heapResult { failures.append("native heap limit rejects unbounded allocation") }
        let cancellable = Task<Bool, Never> { @MainActor in
            let result = await JSProviderRuntime.shared.getStreams(loop, timeout: 5, bootstrapOverride: testBootstrap)
            if case .failure(.cancelled) = result { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(30))
        cancellable.cancel()
        if !(await cancellable.value) { failures.append("task cancellation interrupts native execution") }
        let privateFetch = JSProviderRuntime.Invocation(providerID: "private-fetch", code: """
        module.exports.getStreams = async function () {
          await new Promise(function(resolve, reject) { __vortx_native_fetch('http://127.0.0.1/private', '{}', resolve, reject); });
          return [];
        };
        """, tmdbId: "42", mediaType: "movie", season: nil, episode: nil, settingsJSON: "{}")
        let privateFetchResult = await JSProviderRuntime.shared.getStreams(privateFetch, timeout: 1, bootstrapOverride: testBootstrap)
        if case .success = privateFetchResult { failures.append("native fetch refuses private-network targets") }

        let installed = JSInstalledProvider(id: entry.id, name: entry.displayName, version: nil,
                                            supportedTypes: ["movie", "tv"], hasSettings: false, code: providerCode,
                                            codeDigest: String(repeating: "0", count: 64))
        let group = JSProviderStreamMapping.group(from: raw, provider: installed)
        let stream = group?.streams.first
        expect(group?.addon == "Fixture provider", "mapped result retains provider grouping")
        expect(stream?.vortxProvider == "jsplugin:fixture-provider", "mapped result retains provenance")
        expect(stream?.behaviorHints?.proxyHeaders?.request?["Referer"] == "https://fixtures.example/",
               "mapped result preserves playback referer")
        expect(URL(string: stream?.url ?? "")?.scheme == "https", "mapped result exposes selectable HTTPS stream")

        if failures.isEmpty {
            print("Community JS provider functional proof: PASS (17 checks)")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
