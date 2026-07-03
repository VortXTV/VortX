import Foundation

/// Cross-platform "resolve a trailer to a playable URL" type, compiled into every target
/// (SourcesShared is in all of them). A meta's trailer is either a direct (non-YouTube) stream
/// URL or a YouTube id; this collapses both into one `playableURL` the players can hand to libmpv.
///
/// YouTube trailers are played through the embedded server's `/yt/:id` route (server.js: a 301
/// redirect to a direct media URL resolved by ytdl-core), so they need `StremioServer.canProxy`.
/// On the Lite build (no embedded server) a YouTube-only trailer has no `playableURL`, which is
/// what lets the tvOS Trailer button auto-hide there. `watchURL` is the public youtube.com link
/// for surfaces that can open a browser/external player instead (e.g. iOS/macOS).
struct TrailerRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let youTubeID: String?
    /// A non-YouTube `trailerStreams` url, if the meta carried a direct stream.
    let directURL: URL?
    /// Release year (4 digits) + media type ("movie"/"series"): the key the `/clip` resolver matches a
    /// trailer on (Apple iTunes preview, by title+year), since iTunes has no id we can pass. Defaulted so
    /// callers that lack a year/type (e.g. a home board-row hero) still build a title-only /clip request.
    var year: String? = nil
    var mediaType: String = "movie"
    /// IMDb id (`tt...`) when known: the `/clip` worker keys on it (KinoCheck) to fetch the exact
    /// trailer/clip, preferred over title+year matching. nil for tmdb:/kitsu: catalog ids.
    var imdbID: String? = nil

    /// The libmpv-playable URL for the muted, looping AMBIENT in-hero clip: a direct (non-YouTube) trailer
    /// stream when the meta carried one, else the `/yt/{id}` native resolver URL for the meta's YouTube id
    /// (`StremioServer.trailerResolverBase` + `/yt/{id}`, the SAME path the full Trailer button and our
    /// YouTube URL playback use). The R2 `trailer.vortx.tv/clip` ambient snippet has been RETIRED (owner
    /// directive): now that `/yt` plays the real trailer directly, the ambient background loop is that same
    /// full trailer, just played muted + looping. This is a thin ambient alias of `nativeFullTrailerURL()`.
    ///
    /// FAIL-SOFT: no direct stream and no YouTube id -> nil, and every consumer keeps its still backdrop (no
    /// error is surfaced). A 404 / timeout / undeployed resolver likewise surfaces to the player as
    /// `endFileError` -> still backdrop. A direct stream is always preferred over the resolver. Consumed by
    /// tvOS (`TVInHeroTrailerView` via the detail `heroTrailerLayer` + `HomeHeroTrailerModel`) and the iOS
    /// detail hero's last-resort ambient branch; the WKWebView IFrame (`InHeroYouTubeTrailerView`) using
    /// `youTubeID` is the no-server / Lite fallback where the `/yt` route is unavailable.
    var playableURL: URL? {
        nativeFullTrailerURL()
    }

    /// The public YouTube watch link, for surfaces that open trailers externally.
    var watchURL: URL? {
        youTubeID.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }

    /// The FULL-trailer NATIVE playback URL (owner FINAL architecture, HARD): a direct (non-YouTube) trailer
    /// stream when the meta carried one, else the embedded/remote server's `/yt/{id}` resolver (server.js:
    /// InnerTube ANDROID client -> a direct media URL that libmpv/AVPlayer plays natively). This is the SAME
    /// path our YouTube/Twitch URL playback already uses - NOT the trailer.vortx.tv/clip route (that is only
    /// the 10s ambient billboard snippet) and NOT any full-trailer R2 route (the owner rejected R2 full-trailer
    /// storage). Server-gated: on the Lite build (no embedded server) a YouTube-only trailer returns nil, so
    /// the caller falls back to the 10s ambient clip / hides the button - no error screen.
    ///
    /// `preferredYouTubeID` lets a caller pass a language-selected id (D11) that overrides the meta's default
    /// `youTubeID`; the `?lang=` hint carries the resolved base language so the resolver's own fallback chain
    /// (user-lang -> en -> original/any) matches the client pick. The shape MATCHES tvOS `resolveFullTrailerURL`
    /// exactly so a warmed resolve is shared across platforms.
    func nativeFullTrailerURL(preferredYouTubeID: String? = nil, languageCode: String? = nil) -> URL? {
        if let directURL { return directURL }
        let yt = (preferredYouTubeID?.isEmpty == false ? preferredYouTubeID : youTubeID)
        // The remote resolver (trailer.vortx.tv) works on EVERY scheme incl Lite, so no embedded-server gate.
        guard let yt, !yt.isEmpty else { return nil }
        var c = URLComponents(string: "\(StremioServer.trailerResolverBase)/yt/\(yt)")
        let lang = (languageCode?.isEmpty == false) ? languageCode : nil
        if let lang { c?.queryItems = [URLQueryItem(name: "lang", value: lang)] }
        return c?.url
    }

    /// Build from a resolved meta: prefer a direct (non-YouTube) trailer stream url, else fall
    /// back to the YouTube id (`trailerStreams` ytId, or a "Trailer" link). Nil when neither exists.
    static func from(meta: CoreMetaItem) -> TrailerRequest? {
        let direct = (meta.trailerStreams ?? [])
            .compactMap { $0.ytId == nil ? $0.url : nil }
            .compactMap { URL(string: $0) }
            .first
        let yt = meta.trailerYouTubeID
        guard direct != nil || yt != nil else { return nil }
        // 4-digit year from releaseInfo ("2024", "2024-2025", "2024-") so /clip can disambiguate the right
        // film/series; nil if not parseable. type is movie/series.
        let yr = (meta.releaseInfo?.prefix(4)).map(String.init)
        let year = (yr?.count == 4 && yr?.allSatisfy(\.isNumber) == true) ? yr : nil
        let imdbID = meta.id.hasPrefix("tt") ? meta.id : nil
        return TrailerRequest(title: meta.name, youTubeID: yt, directURL: direct,
                              year: year, mediaType: meta.type, imdbID: imdbID)
    }
}
