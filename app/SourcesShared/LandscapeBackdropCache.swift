import Foundation

/// Resolves and caches each title's CLEAN landscape artwork (a textless 16:9 TMDB backdrop + a PNG
/// clearlogo) by id, so the cinematic landscape cards resolve it once per title instead of on every card
/// render. The image bytes are then loaded + cached by each platform's own image loader (posterMemoryCache /
/// CachedPosterImage); this only caches the resolved URLs.
///
/// The source is TMDB only (via `TMDBClient.landscapeImages`): a real 16:9 backdrop with no rating/quality
/// overlay. It deliberately does NOT fall back to the add-on `meta.background` (which is frequently a 2:3
/// poster URL, the source of the cropped/ugly landscape art that got the first attempt reverted). When TMDB
/// has nothing (no key set, or no TMDB art for the title), it returns nil and the card composites the poster
/// instead (a blurred fill behind a fit copy) so the 16:9 frame still looks intentional.
actor LandscapeBackdropCache {
    static let shared = LandscapeBackdropCache()

    private var cache: [String: (backdrop: String?, logo: String?)] = [:]
    /// In-flight resolves, so N cards of the same title on screen issue ONE TMDB lookup, not N.
    private var inflight: [String: Task<(backdrop: String?, logo: String?), Never>] = [:]

    /// The clean 16:9 backdrop URL for a title, or nil when TMDB has none (caller composites the poster).
    static func backdrop(id: String, type: String) async -> String? {
        await shared.resolve(id: id, type: type).backdrop
    }

    /// The clearlogo URL for a title (for the cinematic title overlay), or nil.
    static func logo(id: String, type: String) async -> String? {
        await shared.resolve(id: id, type: type).logo
    }

    private func resolve(id: String, type: String) async -> (backdrop: String?, logo: String?) {
        if let hit = cache[id] { return hit }
        if let task = inflight[id] { return await task.value }
        let task = Task { await TMDBClient.landscapeImages(metaID: id, type: type) }
        inflight[id] = task
        let result = await task.value
        // Only cache a POSITIVE result. A transient TMDB failure returns (nil, nil); caching that latched the
        // card into poster-fallback for the WHOLE session. Leaving a miss uncached lets a later appear retry.
        if result.backdrop != nil || result.logo != nil { cache[id] = result }
        inflight[id] = nil
        return result
    }
}
