/// Pure Home-board range decisions.
///
/// The engine board keeps every catalog index, while Home deliberately omits
/// hidden, disabled, empty, and failed rows. Visible rows therefore cannot be
/// used as the range boundary.
enum HomeCatalogLoadPolicy {
    static func hasNextPage(loaded: Int, engineCatalogTotal: Int) -> Bool {
        loaded < engineCatalogTotal
    }

    /// Cover the best available raw total while preserving a wider range that
    /// was already opened. The installed-manifest count is the startup fallback
    /// before the engine board has emitted its authoritative raw total.
    static func fullLoadDepth(
        current: Int,
        engineCatalogTotal: Int,
        installedCatalogTotal: Int,
        minimum: Int = 30
    ) -> Int {
        max(minimum, current, engineCatalogTotal, installedCatalogTotal)
    }
}
