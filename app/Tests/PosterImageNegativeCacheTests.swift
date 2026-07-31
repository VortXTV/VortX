// Executable harness for PosterImageLoader's bounded negative-cache policy.
//
//   xcrun swiftc -D POSTER_NEGATIVE_CACHE_POLICY_TESTING -strict-concurrency=complete \
//     -warnings-as-errors -parse-as-library \
//     app/SourcesShared/PosterImageLoader.swift \
//     app/Tests/PosterImageNegativeCacheTests.swift \
//     -o /tmp/poster-negative-cache-tests && /tmp/poster-negative-cache-tests
//
// Run from the repository root. The behavioural checks call the production key, policy, and actor.
// The source gate keeps those decisions wired into both image variants without compiling the UI surface.

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func key(
    _ raw: String,
    variant: PosterImageNegativeCacheKey.Variant = .poster,
    maxPixel: Int = 900
) -> PosterImageNegativeCacheKey {
    guard let url = URL(string: raw) else {
        fatalError("invalid test URL: \(raw)")
    }
    return PosterImageNegativeCacheKey(url: url, variant: variant, maxPixel: maxPixel)
}

@main
@MainActor private enum PosterImageNegativeCacheTests {
    static func main() async {
        let canonical = key("HTTP://Example.COM:80/art/poster.jpg?width=900#ignored")
        let equivalent = key("http://example.com/art/poster.jpg?width=900")
        let differentQuery = key("http://example.com/art/poster.jpg?width=450")
        let differentSize = key("http://example.com/art/poster.jpg?width=900", maxPixel: 450)
        let differentVariant = key(
            "http://example.com/art/poster.jpg?width=900",
            variant: .averageColor,
            maxPixel: 32
        )

        check("normalization folds scheme, host, default port, and fragment", canonical == equivalent)
        check("query values remain part of the artwork identity", canonical != differentQuery)
        check("decode size remains part of the failure identity", canonical != differentSize)
        check("poster and average-color decode failures do not poison each other", canonical != differentVariant)
        check("cache keys retain only a digest, not the raw browsing URL",
              !canonical.normalizedURLDigest.contains("example.com")
                && canonical.normalizedURLDigest.count == 64)

        check("2xx responses are successful", PosterImageNegativeCachePolicy.failure(forHTTPStatus: 204) == nil)
        check("404 is a terminal response",
              PosterImageNegativeCachePolicy.failure(forHTTPStatus: 404) == .terminal)
        check("410 is a terminal response",
              PosterImageNegativeCachePolicy.failure(forHTTPStatus: 410) == .terminal)
        check("authorization can recover after short backoff",
              PosterImageNegativeCachePolicy.failure(forHTTPStatus: 401) == .transient)
        check("rate limits can recover after short backoff",
              PosterImageNegativeCachePolicy.failure(forHTTPStatus: 429) == .transient)
        check("server failures can recover after short backoff",
              PosterImageNegativeCachePolicy.failure(forHTTPStatus: 503) == .transient)
        check("task cancellation is never cached",
              PosterImageNegativeCachePolicy.failure(
                forNetworkError: URLError(.cancelled),
                taskIsCancelled: false
              ) == nil)
        check("caller cancellation is never cached",
              PosterImageNegativeCachePolicy.failure(
                forNetworkError: URLError(.timedOut),
                taskIsCancelled: true
              ) == nil)
        check("network timeout receives transient backoff",
              PosterImageNegativeCachePolicy.failure(
                forNetworkError: URLError(.timedOut),
                taskIsCancelled: false
              ) == .transient)
        check("terminal backoff is longer than transient backoff",
              PosterImageNegativeCachePolicy.ttl(for: .terminal)
                > PosterImageNegativeCachePolicy.ttl(for: .transient))

        let cache = PosterImageNegativeCache(capacity: 2)
        await cache.record(canonical, failure: .terminal, now: 100)
        check("terminal failure suppresses before expiry",
              await cache.shouldSuppress(canonical, now: 699.999))
        check("terminal failure expires at its deadline",
              !(await cache.shouldSuppress(canonical, now: 700)))

        await cache.record(canonical, failure: .transient, now: 1_000)
        check("transient failure suppresses during short backoff",
              await cache.shouldSuppress(canonical, now: 1_004.999))
        check("transient failure retries at short-backoff deadline",
              !(await cache.shouldSuppress(canonical, now: 1_005)))

        await cache.record(canonical, failure: .terminal, now: 2_000)
        await cache.clear(canonical)
        check("success clearing removes a prior negative record",
              !(await cache.shouldSuppress(canonical, now: 2_001)))

        let keyA = key("https://example.com/a.jpg")
        let keyB = key("https://example.com/b.jpg")
        let keyC = key("https://example.com/c.jpg")
        await cache.record(keyA, failure: .terminal, now: 3_000)
        await cache.record(keyB, failure: .terminal, now: 3_001)
        await cache.record(keyA, failure: .terminal, now: 3_002)
        await cache.record(keyC, failure: .terminal, now: 3_003)
        check("capacity remains bounded", await cache.entryCount(now: 3_004) == 2)
        check("refresh protects a still-failing recent key",
              await cache.shouldSuppress(keyA, now: 3_004))
        check("oldest unrefreshed key is evicted",
              !(await cache.shouldSuppress(keyB, now: 3_004)))
        check("newest key is retained", await cache.shouldSuppress(keyC, now: 3_004))

        runSourceGate()

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }

    private static func runSourceGate() {
        let path = "app/SourcesShared/PosterImageLoader.swift"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            check("source gate can read PosterImageLoader.swift", false)
            return
        }
        func section(from start: String, to end: String) -> String? {
            guard let startRange = source.range(of: start),
                  let endRange = source.range(
                    of: end,
                    range: startRange.upperBound..<source.endIndex
                  ) else { return nil }
            return String(source[startRange.lowerBound..<endRange.lowerBound])
        }
        guard let loadSource = section(
            from: "static func load(",
            to: "// MARK: dominant (average) color"
        ), let tintSource = section(
            from: "static func averageColor(",
            to: "/// Draw the (already tiny) image"
        ), let fetchSource = section(
            from: "private static func fetchData(",
            to: "/// Caps how many poster fetches run at once"
        ) else {
            check("source gate finds both loader variants", false)
            return
        }

        check("poster load consults the negative cache",
              loadSource.contains("negativeCache.shouldSuppress(key"))
        check("poster load routes bytes through the shared failure policy",
              loadSource.contains("fetchData(for: req, key: key, rawURL: raw)"))
        check("HTTP status is classified before image decode",
              fetchSource.contains("failure(forHTTPStatus: http.statusCode)"))
        check("failed responses are removed from URLCache before the eventual retry",
              fetchSource.contains("cache.removeCachedResponse(for: request)")
                && loadSource.contains("cache.removeCachedResponse(for: req)"))
        check("decode failures create terminal negative records",
              loadSource.contains("negativeCache.record(key, failure: .terminal"))
        check("network cancellation policy controls failure recording",
              fetchSource.contains("forNetworkError: error")
                && fetchSource.contains("taskIsCancelled: Task.isCancelled"))
        check("successful poster decode clears prior failure state",
              loadSource.contains("negativeCache.clear(key)"))
        check("average-color loads use an isolated failure variant",
              tintSource.contains("variant: .averageColor")
                && tintSource.contains("negativeCache.shouldSuppress(key)")
                && tintSource.contains("negativeCache.clear(key)"))
    }
}
