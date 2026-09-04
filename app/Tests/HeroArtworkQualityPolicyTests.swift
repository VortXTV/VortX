// Executable contract for adaptive Apple hero artwork.
//
//   xcrun swiftc -D POSTER_NEGATIVE_CACHE_POLICY_TESTING -parse-as-library \
//     app/SourcesShared/PosterImageLoader.swift app/SourcesShared/HeroArtworkQualityPolicy.swift \
//     app/Tests/HeroArtworkQualityPolicyTests.swift -o /tmp/hero-artwork-policy-tests && \
//     /tmp/hero-artwork-policy-tests

import Foundation

/// Strict-concurrency probe for the same static-cache shape used by the production decoded-image partitions.
/// `NSObject` stands in for UIImage/NSImage, which are reference values and need the LRU's locked boundary.
private enum DecodedImageLRUConcurrencyProbe {
    static let cache = DecodedImageLRU<NSObject>(countCapacity: 2, byteCapacity: 16)
}

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor private enum HeroArtworkQualityPolicyTests {
    static func main() {
        check("4K tvOS output requests a 3840 px hero decode",
              HeroArtworkQualityPolicy.maxPixel(for: .tvOS, displayLongEdge: 3_840) == 3_840)
        check("1080p tvOS output keeps a 1920 px hero decode",
              HeroArtworkQualityPolicy.maxPixel(for: .tvOS, displayLongEdge: 1_920) == 1_920)
        check("lower tvOS output is bounded to its conservative 1280 px floor",
              HeroArtworkQualityPolicy.maxPixel(for: .tvOS, displayLongEdge: 720) == 1_280)
        check("high-resolution Mac surface requests a 3840 px hero decode",
              HeroArtworkQualityPolicy.maxPixel(for: .macOS, displayLongEdge: 3_456) == 3_840)
        check("HD Mac surface keeps a 1920 px hero decode",
              HeroArtworkQualityPolicy.maxPixel(for: .macOS, displayLongEdge: 2_560) == 1_920)
        check("mobile remains on its conservative 1280 px fallback",
              HeroArtworkQualityPolicy.maxPixel(for: .mobile, displayLongEdge: 3_840) == 1_280)

        let url = URL(string: "https://image.tmdb.org/t/p/w780/hero.jpg")!
        let original = HeroArtworkQualityPolicy.preferredURL(url.absoluteString, maxPixel: 3_840)
        check("4K TMDB hero upgrades the documented w780 variant to original",
              original == "https://image.tmdb.org/t/p/original/hero.jpg")
        let w1280 = "https://image.tmdb.org/t/p/w1280/hero.jpg"
        check("4K TMDB hero upgrades the documented w1280 variant to original",
              HeroArtworkQualityPolicy.preferredURL(w1280, maxPixel: 3_840)
                == "https://image.tmdb.org/t/p/original/hero.jpg")
        check("HD TMDB hero retains its existing URL",
              HeroArtworkQualityPolicy.preferredURL(url.absoluteString, maxPixel: 1_920) == url.absoluteString)
        let metahub = "https://images.metahub.space/background/big/tt123/img"
        check("non-TMDB providers are unchanged",
              HeroArtworkQualityPolicy.preferredURL(metahub, maxPixel: 3_840) == metahub)
        let lookalike = "https://image.tmdb.org.evil.example/t/p/w780/hero.jpg"
        check("lookalike TMDB host is unchanged",
              HeroArtworkQualityPolicy.preferredURL(lookalike, maxPixel: 3_840) == lookalike)

        let small = HeroArtworkQualityPolicy.decodedCacheIdentity(url: url, maxPixel: 1_280)
        let large = HeroArtworkQualityPolicy.decodedCacheIdentity(url: url, maxPixel: 3_840)
        check("decoded cache separates 1280 and 4K variants", small != large)
        check("4K residency is limited to active plus one replacement",
              HeroArtworkQualityPolicy.maximumResident4KImages == 2)
        check("combined decoded artwork budget does not exceed the prior 256 MiB ceiling",
              HeroArtworkQualityPolicy.standardDecodedCacheBytes
                + HeroArtworkQualityPolicy.ultraHDDecodedCacheBytes
                == HeroArtworkQualityPolicy.maximumDecodedCacheBytes)

        let byteLRU = DecodedImageLRU<Int>(countCapacity: 3, byteCapacity: 10)
        check("locked LRU supports a strict-concurrency static image-cache declaration",
              DecodedImageLRUConcurrencyProbe.cache.residentCount() == 0)
        check("LRU accepts the first decoded image", byteLRU.insert(1, forKey: "a", cost: 4))
        check("LRU accepts the second decoded image", byteLRU.insert(2, forKey: "b", cost: 4))
        _ = byteLRU.value(forKey: "a")
        check("LRU evicts the least-recently-used image for a byte-bound insert",
              byteLRU.insert(3, forKey: "c", cost: 4)
                && byteLRU.value(forKey: "a") == 1
                && byteLRU.value(forKey: "b") == nil
                && byteLRU.value(forKey: "c") == 3
                && byteLRU.residentCost() == 8)
        let countLRU = DecodedImageLRU<Int>(countCapacity: 2, byteCapacity: 20)
        _ = countLRU.insert(1, forKey: "a", cost: 3)
        _ = countLRU.insert(2, forKey: "b", cost: 3)
        check("LRU evicts for its hard count limit",
              countLRU.insert(3, forKey: "c", cost: 3)
                && countLRU.residentCount() == 2
                && countLRU.value(forKey: "a") == nil)
        check("LRU rejects a single image over its byte budget without evicting residents",
              !countLRU.insert(4, forKey: "oversize", cost: 21)
                && countLRU.residentCount() == 2
                && countLRU.residentCost() == 6)
        let replacementLRU = DecodedImageLRU<Int>(countCapacity: 2, byteCapacity: 10)
        _ = replacementLRU.insert(1, forKey: "same", cost: 8)
        check("LRU subtracts a replacement before enforcing its byte budget",
              replacementLRU.insert(2, forKey: "same", cost: 4)
                && replacementLRU.insert(3, forKey: "other", cost: 6)
                && replacementLRU.residentCost() == 10)

        let detailSource = try? String(contentsOfFile: "app/SourcesTV/DetailView.swift", encoding: .utf8)
        check("series poster fallback explicitly opts out of ultra-HD",
              detailSource?.contains("allowsUltraHD: meta.background != nil") == true)
        check("non-ultra-HD hero keeps lower output modes below 1920 px",
              detailSource?.contains("min(requested, HeroArtworkQualityPolicy.fullHDLongEdge)") == true)
        let featuredSource = try? String(contentsOfFile: "app/SourcesiOS/FeaturedHeroView.swift", encoding: .utf8)
        check("portrait hero fallback stays at the mobile decode ceiling",
              featuredSource?.contains("maxPixel: CGFloat(HeroArtworkQualityPolicy.mobileLongEdge)") == true)
        check("macOS screen-change handler is refreshed for every SwiftUI update",
              featuredSource?.components(
                  separatedBy: "installScreenChangeHandler(on: view, coordinator: context.coordinator)"
              ).count == 3)
        let cachePeekContracts: [(String, String)] = [
            ("app/SourcesiOS/iOSBrowseGridView.swift", "cached(u, maxPixel: maxPixel)"),
            ("app/SourcesShared/AddonsView.swift", "cached(u, maxPixel: 168)"),
            ("app/SourcesiOS/iOSDetailView.swift", "cached(parsed, maxPixel: Self.maxPixel)"),
            ("app/SourcesTV/DetailView.swift", "cached(parsed, maxPixel: Self.maxPixel)"),
            ("app/SourcesShared/ReleaseCalendarModel.swift", "cached(parsed, maxPixel: 132)"),
        ]
        check("all non-default decoded-cache peeks use their matching decode ceiling",
              cachePeekContracts.allSatisfy { path, token in
                  (try? String(contentsOfFile: path, encoding: .utf8))?.contains(token) == true
              })

        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
