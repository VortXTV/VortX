import SwiftUI

/// Curated brand treatment for the streaming-service tiles (H1). The owner rejected the earlier
/// blown-up fill-crop of the square TMDB logo ("ugly zoomed crop") and wants CLEAN, first-party-style
/// brand tiles: the provider's official mark at a sane medium size, centered on the brand's flat color,
/// NOT an edge-to-edge crop. This file owns the two curated maps that make that possible:
///
///   - `brandColor(for:)`: a flat background color for the majors (Netflix black, Prime blue, Disney
///     navy, Apple near-black, Max/HBO, Paramount blue, Peacock black, ...). Anything unmapped falls
///     back to the warm neutral `surface2` so a regional/long-tail provider still reads as a finished
///     tile (its own logo art usually already carries the brand color).
///   - `canonicalProviderID(for:)` + `dedupeProviders(_:)`: collapse TMDB's split provider entries that
///     the owner saw as duplicate tiles - most visibly TWO Apple TV tiles (id 2 "Apple TV" store vs
///     id 350 "Apple TV+" subscription), plus the Prime (9/119), Max/HBO Max (1899/384) and
///     Discovery+ (520/524) alias pairs. One brand -> one tile, keeping the first (higher-ranked) entry.
///
/// We ship NO copyrighted brand artwork: the logo image is always TMDB's official `logo_path` (already
/// used elsewhere). Only the flat brand COLOR lives here, which is not itself protectable art.
///
/// Region-awareness for H1 is handled upstream: `TMDBClient.regionProviders` already builds the list from
/// `watch/providers/{media}?watch_region=<region>`, so Sony LIV / Zee5 / JioCinema / Rakuten Viki and the
/// rest surface automatically wherever TMDB lists them for the user's (configurable) region. This file only
/// styles + dedupes whatever that region query returns.
enum ProviderBrandMap {

    /// Flat brand background color for the well-known majors, keyed by TMDB/JustWatch provider id.
    /// Values are the brand's signature flat color (approximate, hand-tuned to read well behind a white
    /// or full-color logo mark). Alias ids share a color so a not-yet-deduped list still looks uniform.
    private static let colors: [Int: Color] = {
        func hex(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
        }
        // Deep, premium brand tones. Kept in the brand's hue family but DARKENED so no tile reads as a
        // garish bright block next to the near-black Netflix/Apple tiles - the whole row stays a cohesive
        // dark set (the way the tvOS home-screen icons sit together), and TMDB's white-ish logo marks read
        // cleanly on top instead of a bright-on-bright clash. Deep enough that a full-color OR a white logo
        // both land well.
        return [
            8:    hex(18, 18, 18),     // Netflix - near-black (the red N reads on it)
            9:    hex(9, 58, 92),      // Amazon Prime Video - deep Prime blue (was a garish bright cyan)
            119:  hex(9, 58, 92),      // Amazon Prime Video (alias)
            337:  hex(17, 24, 66),     // Disney+ - deep navy
            122:  hex(17, 24, 66),     // Disney+ Hotstar - shares the Disney navy
            1899: hex(30, 17, 54),     // Max - dark violet
            384:  hex(30, 17, 54),     // HBO Max (alias)
            350:  hex(22, 22, 24),     // Apple TV+ - near-black
            2:    hex(22, 22, 24),     // Apple TV (store, aliased to +)
            531:  hex(10, 40, 92),     // Paramount+ - deep Paramount blue
            15:   hex(12, 74, 52),     // Hulu - deep Hulu green (was neon)
            386:  hex(14, 14, 16),     // Peacock - black (the color-burst logo carries the hue)
            283:  hex(150, 66, 20),    // Crunchyroll - deep Crunchyroll orange
            344:  hex(8, 66, 86),      // Rakuten Viki - deep Viki blue
            430:  hex(8, 66, 92),      // HiDive - deep HiDive blue
            43:   hex(12, 12, 12),     // Starz - black
            37:   hex(12, 12, 12),     // Showtime - black
            526:  hex(9, 27, 49),      // AMC+ - dark blue
            520:  hex(8, 52, 104),     // Discovery+ - deep Discovery blue
            524:  hex(8, 52, 104),     // Discovery+ (alias)
            38:   hex(18, 18, 18),     // BBC iPlayer - black
            73:   hex(18, 18, 18),     // Tubi - dark (the magenta wordmark reads on it)
            300:  hex(0, 30, 60),      // Pluto TV - dark blue
            11:   hex(12, 12, 12),     // MUBI - black
        ]
    }()

    /// The flat brand background for a provider, or the neutral surface fallback for the long tail
    /// (regional providers, small services) so every tile still reads as a finished brand card.
    static func brandColor(for providerID: Int) -> Color {
        colors[providerID] ?? Theme.Palette.surface2
    }

    /// Whether a brand color was explicitly curated for this provider (drives a subtle contrast tweak:
    /// mapped brands get a hairline, neutral fallbacks lean on their own logo art).
    static func hasBrandColor(_ providerID: Int) -> Bool { colors[providerID] != nil }

    /// TMDB splits some brands into two provider entries (a subscription tier and a transactional store,
    /// or a legacy + rebranded id). Map every alias to ONE canonical id so the row shows a single tile per
    /// brand (the owner's "two Apple TV+ tiles" report). Unlisted ids map to themselves.
    private static let aliasToCanonical: [Int: Int] = [
        2: 350,      // Apple TV (store)     -> Apple TV+
        119: 9,      // Amazon Prime (alias) -> Prime Video
        384: 1899,   // HBO Max              -> Max
        524: 520,    // Discovery+ (alias)   -> Discovery+
    ]

    /// The canonical provider id for a brand (collapses alias entries). Identity for unlisted ids.
    static func canonicalProviderID(for providerID: Int) -> Int {
        aliasToCanonical[providerID] ?? providerID
    }

    /// Collapse duplicate brand tiles (Apple TV / Apple TV+, Prime aliases, Max/HBO Max, Discovery+),
    /// keeping the FIRST occurrence of each canonical brand so the upstream ranking order is preserved.
    static func dedupeProviders(_ providers: [TMDBClient.ProviderTile]) -> [TMDBClient.ProviderTile] {
        var seen = Set<Int>()
        return providers.filter { seen.insert(canonicalProviderID(for: $0.providerID)).inserted }
    }

    /// The bundled first-party logo slug for a provider (the real brand PNG under Resources/streaming-logos),
    /// or nil when we don't ship a mark for it. Delegates to the cross-platform `ProviderBrandLogo` map in
    /// SourcesShared so iOS/Mac and tvOS resolve the SAME id -> slug table. This is what lets a mapped major
    /// render its own logo instantly (no network, no TMDB fill-crop, no single-letter placeholder).
    static func bundledLogoName(for providerID: Int) -> String? {
        ProviderBrandLogo.bundledLogoName(for: providerID)
    }
}
