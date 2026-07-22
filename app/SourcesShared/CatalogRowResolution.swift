// CatalogRowResolution: the two pure rules that decide what a browse/rail card carries when a TMDB discover
// row has been resolved. Kept here, Foundation-only and free of any app type, so the standalone test
// (app/Tests/CatalogRowResolutionTests.swift) compiles THESE EXACT functions rather than a mirror of them.
//
// Why it exists: JioHotstar (2336) and ZEE5 (232) are India-regional services whose TMDB catalog rows very
// often have NO IMDb `tt` id. The historic gate dropped every row without a `tt` id, so those provider grids
// and Home rails thinned to empty even though each row had a TMDB name + poster. A `tmdb:<id>` id is fully
// playable in this app (tvOS resolves it in the stream path directly; iOS/Mac resolve it fail-soft before
// pushing detail, exactly like the person filmography and franchise rows that already ship `tmdb:` cards),
// so a provider path can keep a `tt`-less title as `tmdb:<id>` instead of discarding it.
import Foundation

enum CatalogRowResolution {
    /// The engine-playable id for a discover row that already passed the poster check, or nil to DROP it.
    ///
    /// A real IMDb `tt` id always wins: Cinemeta meta, stream add-ons and the ratings service key on it, and
    /// iOS/Mac detail can skip the resolve round-trip. When TMDB has no `tt` id the general grids (genre,
    /// decade, Discover lists) still DROP the row, so they never surface a source-less foreign title. Only the
    /// PROVIDER paths pass `providerFallback: true`: there an India-regional title with no IMDb id falls back
    /// to the `tmdb:<id>` form the hub detail path already resolves and plays, so the title survives to the
    /// grid and stays tappable instead of vanishing and leaving the tile blank.
    static func playableID(imdbID: String?, tmdbID: Int, providerFallback: Bool) -> String? {
        if let imdbID, imdbID.hasPrefix("tt") { return imdbID }
        return providerFallback ? "tmdb:\(tmdbID)" : nil
    }

    /// The text a browse grid shows once it has finished loading with ZERO items. For a streaming SERVICE the
    /// user explicitly picked, an empty grid means the service just is not carried in the viewer's Discover
    /// region (an India-only service under a US/GB watch_region legitimately returns nothing, even after the
    /// in-region -> US retry), so point them at the region setting instead of a bare "Nothing here yet.". Every
    /// other target (genre / decade / Discover) keeps the neutral message.
    static func emptyGridMessage(isServiceTarget: Bool) -> String {
        isServiceTarget
            ? "Not available in your region. Change your Discover region in Settings."
            : "Nothing here yet."
    }
}
