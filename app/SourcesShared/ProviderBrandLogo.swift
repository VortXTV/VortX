import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Bundled, first-party brand marks for the "Streaming Services" tiles, shared by every native Apple target
/// (iOS/Mac via SourcesiOS, tvOS via SourcesTV). The owner rejected the TMDB-logo path: for the majors it
/// resolved to a square TMDB icon that fill-cropped badly (or, on a miss, collapsed to a single-letter
/// placeholder: "wtf are these logos"). This file ships REAL transparent-background brand PNGs under
/// `Resources/streaming-logos/` (bundled as a folder reference on all four targets) so a mapped major ALWAYS
/// renders its own logo instantly, with NO network and NO letters.
///
/// Two pieces live here so both UI layers (SourcesiOS `iOSServiceTile`, SourcesTV `TVServiceTile`) share one
/// source of truth:
///   - `bundledLogoName(for:)`: TMDB/JustWatch provider id -> logo slug (the PNG filename without extension),
///     or nil when we don't bundle a mark for that provider (the tile then falls back to the TMDB logoURL,
///     then to the letter placeholder as a last resort).
///   - `BundledLogo.image(named:)`: loads a bundled PNG from the `streaming-logos` subdirectory and returns a
///     SwiftUI `Image?` (NSImage on macOS, UIImage on iOS/tvOS), so the caller can aspect-fit it centered.
enum ProviderBrandLogo {

    /// TMDB/JustWatch provider id -> bundled logo slug. Alias ids (Prime 9/119, Max 1899/384, Apple 2/350,
    /// Discovery+ 520/524, Disney/Hotstar) all resolve to the same mark so a not-yet-deduped list still shows
    /// the right logo. Only the ids we actually ship a PNG for appear here; everything else returns nil.
    private static let idToSlug: [Int: String] = [
        8:    "netflix",        // Netflix
        9:    "primevideo",     // Amazon Prime Video
        119:  "primevideo",     // Amazon Prime Video (alias)
        337:  "disneyplus",     // Disney+
        122:  "hotstar",        // Disney+ Hotstar
        1899: "max",            // Max
        384:  "max",            // HBO Max (alias)
        350:  "appletv",        // Apple TV+
        2:    "appletv",        // Apple TV (store, aliased to +)
        531:  "paramountplus",  // Paramount+
        15:   "hulu",           // Hulu
        386:  "peacock",        // Peacock
        283:  "crunchyroll",    // Crunchyroll
        520:  "discoveryplus",  // Discovery+
        524:  "discoveryplus",  // Discovery+ (alias)
        43:   "starz",          // Starz
        37:   "showtime",       // Showtime
        526:  "amcplus",        // AMC+
        73:   "tubi",           // Tubi
        300:  "plutotv",        // Pluto TV
        38:   "bbciplayer",     // BBC iPlayer
        11:   "mubi",           // MUBI
        344:  "viki",           // Rakuten Viki
    ]

    /// The bundled logo slug for a provider, or nil when we don't ship a mark (fall back to TMDB logoURL).
    static func bundledLogoName(for providerID: Int) -> String? {
        idToSlug[providerID]
    }

    /// Whether we bundle a first-party logo for this provider (drives the "logo-first" branch in the tiles).
    static func hasBundledLogo(for providerID: Int) -> Bool { idToSlug[providerID] != nil }
}

/// Cross-platform loader for a bundled PNG in the `streaming-logos` subdirectory of the app bundle. Returns a
/// SwiftUI `Image?` so the tiles can aspect-fit it centered. NSImage on macOS, UIImage on iOS/tvOS.
enum BundledLogo {
    /// Load `streaming-logos/<name>.png` from the main bundle as a SwiftUI Image, or nil if it isn't present.
    static func image(named name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "streaming-logos")
        else { return nil }
        #if canImport(UIKit)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}
