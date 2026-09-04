import Foundation

/// The hero is the only artwork surface allowed to request a large decode. Catalog cards stay on their
/// existing conservative caps so moving focus cannot create a 4K prefetch queue.
enum HeroArtworkQualityPolicy {
    enum Surface: Sendable {
        case tvOS
        case macOS
        case mobile
    }

    static let ultraHDLongEdge = 3_840
    static let fullHDLongEdge = 1_920
    static let mobileLongEdge = 1_280
    static let minimumHighResolutionMacLongEdge = 3_000
    static let maximumResident4KImages = 2
    static let maximumDecodedCacheBytes = 256 * 1024 * 1024
    static let ultraHDDecodedCacheBytes = 72 * 1024 * 1024
    static let standardDecodedCacheBytes = maximumDecodedCacheBytes - ultraHDDecodedCacheBytes

    static func maxPixel(for surface: Surface, displayLongEdge: Int) -> Int {
        switch surface {
        case .tvOS:
            guard displayLongEdge >= ultraHDLongEdge else {
                return min(fullHDLongEdge, max(mobileLongEdge, displayLongEdge))
            }
            return ultraHDLongEdge
        case .macOS:
            return displayLongEdge >= minimumHighResolutionMacLongEdge ? ultraHDLongEdge : fullHDLongEdge
        case .mobile:
            return mobileLongEdge
        }
    }

    /// TMDB documents `original` as its provider-selected original image size. Explicit TMDB w300, w780, and
    /// w1280 backdrops are upgraded only when this policy is actually selecting a 4K decode. Add-on and
    /// Metahub URLs stay byte-for-byte unchanged because they have no shared, proven size contract here.
    static func preferredURL(_ raw: String?, maxPixel: Int) -> String? {
        guard let raw, maxPixel >= ultraHDLongEdge,
              var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "image.tmdb.org" else { return raw }
        var path = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count > 4, path[1] == "t", path[2] == "p",
              ["w300", "w780", "w1280"].contains(String(path[3])) else { return raw }
        path[3] = "original"
        components.path = path.joined(separator: "/")
        return components.string ?? raw
    }

    /// Variant identity keeps a smaller warm decode from satisfying a large hero request.
    static func decodedCacheIdentity(url: URL, maxPixel: Int) -> String {
        "\(url.absoluteString)#px=\(maxPixel)"
    }
}
