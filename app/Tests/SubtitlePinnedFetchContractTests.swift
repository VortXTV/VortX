// Focused executable contract for the pinned subtitle fetch wiring.
//
// Extract the fetcher + policy block, then compile it with the pinned transport and this harness:
//
//   { echo 'import Foundation'; echo ''; \
//     awk '/^enum SubtitleFileFetcher \{/{f=1} /^#if canImport\(UIKit\)/{f=0} f' \
//       app/Sources/Player/SubtitleCueRenderer.swift; } \
//     > /tmp/subtitle-fetch-policy.swift && \
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/JSProviders/JSProviderURLPolicy.swift \
//     app/SourcesShared/JSProviders/PinnedHTTPClient.swift \
//     /tmp/subtitle-fetch-policy.swift \
//     app/Tests/SubtitlePinnedFetchContractTests.swift \
//     -o /tmp/subtitle-pinned-fetch-tests && \
//   /tmp/subtitle-pinned-fetch-tests
//
// Every case here is deterministic: no live DNS and no sockets. The fail-closed gates must answer before
// any network work starts; the live TLS path of the pinned transport is covered separately by
// PinnedHTTPClientFunctionalProofTests and by physical-device smoke before a release cut.

import Foundation

@main
struct SubtitlePinnedFetchContractTests {
    @MainActor static var failures = 0

    @MainActor static func check(_ name: String, _ condition: Bool) {
        if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
    }

    /// Run one fetch and block until the callback fires exactly once, returning the delivered bytes.
    @MainActor static func awaitFetch(_ url: URL, timeout: TimeInterval = 5) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        SubtitleFileFetcher.fetch(url, timeout: timeout) { data in
            box.record(data)
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + 10)
        check("callback fired exactly once for \(url.absoluteString)", waitResult == .success && box.calls == 1)
        return box.value
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        private var count = 0
        var value: Data? { lock.lock(); defer { lock.unlock() }; return stored }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func record(_ data: Data?) { lock.lock(); count += 1; stored = data; lock.unlock() }
    }

    @MainActor static func main() {
        // 1. Local file round-trip: exact bytes, no network.
        let small = URL(fileURLWithPath: "/tmp/subtitle-contract-small.srt")
        let smallBytes = Data("1\n00:00:01,000 --> 00:00:02,000\nhello\n".utf8)
        try? smallBytes.write(to: small)
        check("file:// subtitle returns exact bytes", awaitFetch(small) == smallBytes)

        // 2. Local file above the 2 MiB ceiling fails closed.
        let big = URL(fileURLWithPath: "/tmp/subtitle-contract-big.bin")
        try? Data(count: 2 * 1024 * 1024 + 1).write(to: big)
        check("file:// subtitle above 2 MiB fails closed", awaitFetch(big) == nil)

        // 3. Plain HTTP fails closed: the pinned transport is HTTPS-only and there is no fallback path
        //    that lets URLSession re-resolve the hostname at connect time.
        check("http:// fails closed", awaitFetch(URL(string: "http://public.example/sub.srt")!) == nil)

        // 4-7. Private/loopback literals are rejected by the pre-filter before any network work.
        check("https loopback IPv4 fails closed", awaitFetch(URL(string: "https://127.0.0.1/sub.srt")!) == nil)
        check("https RFC1918 fails closed", awaitFetch(URL(string: "https://192.168.1.10/sub.srt")!) == nil)
        check("https CGNAT fails closed", awaitFetch(URL(string: "https://100.64.0.1/sub.srt")!) == nil)
        check("https link-local fails closed", awaitFetch(URL(string: "https://169.254.169.254/sub.srt")!) == nil)

        // 8-9. Hostname forms that must never reach a resolver from this gate.
        check("https localhost fails closed", awaitFetch(URL(string: "https://localhost/sub.srt")!) == nil)
        check("https IPv6 loopback fails closed", awaitFetch(URL(string: "https://[::1]/sub.srt")!) == nil)

        // 10. URLs carrying credentials fail closed before any network work.
        check("https with userinfo fails closed", awaitFetch(URL(string: "https://user:pass@public.example/sub.srt")!) == nil)

        // 11. Non-http(s) schemes fail closed.
        check("ftp scheme fails closed", awaitFetch(URL(string: "ftp://public.example/sub.srt")!) == nil)

        try? FileManager.default.removeItem(at: small)
        try? FileManager.default.removeItem(at: big)

        if failures == 0 { print("Subtitle pinned fetch contract: PASS") }
        else { print("Subtitle pinned fetch contract: \(failures) FAILURES"); exit(1) }
    }
}