import Foundation

/// Resolve an IMDb `tt…` id to a `MetaPreview` (poster + name) through Cinemeta, the same host the rest
/// of the app already reads meta from.
///
/// WHY THIS EXISTS: every client-side rail that seeds from an EXTERNAL service (Trakt watchlist, the
/// media-server "recently added" rails, the SIMKL plan-to-watch rail) has the same last mile: it holds a
/// tt id plus a bare title, and it needs the app's own artwork so the cards match every other rail and no
/// third-party token or CDN URL rides in an image request. That last mile was being copy-pasted per rail,
/// which is exactly how two copies drift into two behaviors. New rails resolve through here.
///
/// Fail-soft by construction: a Cinemeta miss (offline, 404, unparseable) still returns a poster-less
/// preview so the title lists with its gradient card rather than vanishing from the rail. Only a
/// non-tt id or a title-less miss yields nil, because both are unrenderable.
enum CinemetaPreviewResolver {
    /// Resolve one title. `type` is normalized to Cinemeta's "series"/"movie"; anything that is not
    /// "series" is treated as a movie. `fallbackTitle` carries the external service's own title, used when
    /// Cinemeta has no name for the id.
    ///
    /// The `tt` prefix is REQUIRED: Cinemeta's meta endpoint is tt-keyed, so a tmdb-only / kitsu-only /
    /// service-internal id would build a URL that 404s and then fall back to a card whose `id` the detail
    /// page cannot open. Dropping it here is better than rendering a card that dead-ends on tap.
    static func preview(imdb: String, type: String, fallbackTitle: String) async -> MetaPreview? {
        let safeType = (type == "series") ? "series" : "movie"
        guard imdb.hasPrefix("tt"), let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(safeType)/\(imdb).json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else {
            guard imdb.hasPrefix("tt"), !fallbackTitle.isEmpty else { return nil }
            return MetaPreview(id: imdb, type: safeType, name: fallbackTitle, poster: nil, posterShape: nil, popularity: nil)
        }
        let name = (meta["name"] as? String) ?? fallbackTitle
        guard !name.isEmpty else { return nil }
        return MetaPreview(id: imdb, type: safeType, name: name,
                           poster: meta["poster"] as? String, posterShape: nil, popularity: nil)
    }
}
