import SwiftUI

/// ERDB (Easy Ratings Database, easyratingsdb.com, open-source at github.com/realbestia1/erdb) renders
/// posters, backdrops, LOGOS, and episode thumbnails with rating badges and quality overlays baked in. It
/// is token-based: the user pastes their `Tk-...` token (which carries their saved providers, layout, and
/// rating placement server-side), and the renderer URL is simply `{base}/{token}/{type}/{id}.jpg` with NO
/// query string. The base URL is configurable so VortX can later point at a self-hosted instance (e.g. a
/// Cloudflare Worker) instead of easyratingsdb.com.
///
/// Unlike the per-image XRDB transformer, ERDB is the only one of our art providers that also serves a
/// rating-baked LOGO by id, which is exactly what add-on authors asked for.
enum ERDB {
    static let enabledKey = "stremiox.erdb.enabled"   // absent = OFF (opt-in: it replaces every poster)
    static let tokenKey = "stremiox.erdb.token"
    static let baseKey = "stremiox.erdb.baseURL"
    static let fanartPostersKey = "stremiox.erdb.fanartPosters"   // absent = off
    static let defaultBase = "https://erdb.vortx.tv"

    static var token: String {
        (UserDefaults.standard.string(forKey: tokenKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// ERDB drives artwork whenever the toggle is on. The hosted erdb.vortx.tv is KEYLESS, so no token is
    /// required: a tokenless request ({base}/{type}/{id}.jpg) returns VortX-styled, rating-baked art. A token
    /// is only for a custom self-hosted instance that carries the user's own providers/layout. Opt-in
    /// (default off) because turning it on replaces every poster, backdrop, and logo with a baked render.
    static var isActive: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// Opt-in: request fanart.tv posters from the image service (it appends ?art=fanart, using the user's own
    /// fanart key when set, else the VortX service key). Posters only; backdrops and logos are unaffected.
    static var fanartPosters: Bool {
        UserDefaults.standard.bool(forKey: fanartPostersKey)
    }

    /// The renderer URL for a title, or the `fallback` art when inactive or the id is not renderable. `type`
    /// is "poster", "backdrop", "logo", or "thumbnail". The id keeps its scheme (ERDB accepts the colons in
    /// `tmdb:movie:603` / `tt0944947:1:1` directly in the path), so it is inserted raw.
    static func imageURL(_ type: String, id: String, fallback: String?) -> String? {
        guard isActive, let rid = renderableID(id) else { return fallback }
        let tk = token
        let tokenSeg = tk.isEmpty ? "" : "\(tk)/"   // tokenless self-host form when no token is set
        var u = "\(normalizedBase())/\(tokenSeg)\(type)/\(rid).jpg"
        if type == "poster", fanartPosters {
            u += "?art=fanart"
            if let fk = ApiKeys.fanartKey(), let enc = fk.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                u += "&fk=\(enc)"
            }
        }
        return u
    }

    /// True when ERDB can render (and therefore bake a rating onto) this id. Mirror of the `renderableID`
    /// gate `imageURL` uses, exposed so a per-poster badge site can tell whether a baked rating will arrive.
    static func canRender(id: String) -> Bool { renderableID(id) != nil }

    /// ERDB resolves IMDb, TMDB, TVDB, and the anime id schemes. A custom add-on id it cannot map keeps its
    /// original artwork (return nil so the caller uses the fallback).
    private static func renderableID(_ id: String) -> String? {
        if id.hasPrefix("tt") { return id }
        for scheme in ["tmdb:", "tvdb:", "kitsu:", "anilist:", "mal:", "anidb:", "realimdb:"] where id.hasPrefix(scheme) {
            return id
        }
        return nil
    }

    /// Trimmed base URL, http(s) only, trailing slashes removed; defaults to easyratingsdb.com (or a future
    /// VortX-hosted instance) when the user has not set a custom one.
    private static func normalizedBase() -> String {
        var s = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty || !(s.hasPrefix("http://") || s.hasPrefix("https://")) { return defaultBase }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? defaultBase : s
    }
}

/// fanart.tv as a DIRECT art provider, INDEPENDENT of ERDB. Off by default. When on, the async art sites
/// prefer fanart.tv's community clearlogo / clearart / poster / background (resolved via `FanartClient`
/// using the user's fanart.tv key from Metadata keys) over the add-on/metahub art, WITHOUT enabling ERDB's
/// rating-baked renders. Resolution is async (network), so callers await it from already-async art sites
/// (e.g. the hero logo); it never blocks the synchronous `PosterArtwork` URL builders.
enum Fanart {
    static let enabledKey = "stremiox.fanart.enabled"   // absent = OFF (opt-in, independent of ERDB)
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }

    /// The fanart.tv clearlogo URL for a title, or nil when disabled / fanart has none. Async (one cached
    /// fanart.tv lookup per id); fail-soft so the caller keeps its existing logo on any miss.
    static func logo(id: String, type: String) async -> String? {
        guard isEnabled else { return nil }
        return await FanartClient.art(id: id, type: type).logo
    }

    /// The fanart.tv poster URL for a title, or nil when disabled / fanart has none. Async, fail-soft.
    static func poster(id: String, type: String) async -> String? {
        guard isEnabled else { return nil }
        return await FanartClient.art(id: id, type: type).poster
    }

    /// The fanart.tv background (16:9) URL for a title, or nil when disabled / fanart has none. Async, fail-soft.
    static func background(id: String, type: String) async -> String? {
        guard isEnabled else { return nil }
        return await FanartClient.art(id: id, type: type).background
    }
}

/// The single place every poster / backdrop / logo URL is resolved, so the active art provider is chosen
/// once. Precedence: ERDB (when the user set a token) wins, then the VortX / XRDB poster service, then the
/// original add-on artwork. Keeps the three poster call sites and the two logo slots from each re-deciding.
enum PosterArtwork {
    /// True when an art provider bakes ratings onto the image, so the app must NOT also draw its own rating
    /// badge (avoids a double badge). This is the PROVIDER-LEVEL flag: it says a baking provider is switched
    /// on, NOT that it can render any given id. Prefer `bakesRatings(forID:)` at a per-poster badge site.
    static var bakesRatings: Bool { ERDB.isActive || XRDB.isEnabled }

    /// Whether the active art provider will ACTUALLY bake a rating onto THIS id's poster. Mirrors the
    /// `poster(id:fallback:)` precedence exactly: when ERDB is active it must be able to render the id, else
    /// the VortX/XRDB service must. A non-renderable id (a custom add-on scheme like `hive:…` that neither
    /// service maps) yields false, so the caller draws its OWN rating badge instead of suppressing it for a
    /// baked rating that never arrives -- the bug where an add-on catalog card showed no rating at all because
    /// the global flag assumed a bake the unrenderable id could not produce.
    static func bakesRatings(forID id: String?) -> Bool {
        guard let id else { return bakesRatings }
        if ERDB.isActive { return ERDB.canRender(id: id) }
        if XRDB.isEnabled { return XRDB.canRender(id: id) }
        return false
    }

    /// Poster image URL for a title id. ERDB token wins, then VortX / XRDB, then the original poster.
    static func poster(id: String, fallback: String?) -> String? {
        if ERDB.isActive { return ERDB.imageURL("poster", id: id, fallback: fallback) }
        return XRDB.imageURL(id: id, fallback: fallback)
    }

    /// Backdrop image URL. ERDB when active (it bakes ratings/quality on backdrops too), else the original.
    static func backdrop(id: String, fallback: String?) -> String? {
        ERDB.isActive ? ERDB.imageURL("backdrop", id: id, fallback: fallback) : fallback
    }

    /// Title clearart LOGO URL. ERDB serves a rating-baked logo by id when active; otherwise the caller's
    /// existing logo (the add-on `meta.logo` or the metahub clearart) is used unchanged.
    static func logo(id: String?, fallback: String?) -> String? {
        if ERDB.isActive, let id, let url = ERDB.imageURL("logo", id: id, fallback: nil) { return url }
        return fallback
    }

    /// Async logo resolution shared by EVERY hero/detail logo slot: fanart.tv clearlogo first (when the
    /// fanart toggle is on), else the synchronous ERDB-aware add-on/metahub logo. Keeps the fanart precedence
    /// identical on tvOS, iOS, and Mac so no platform's logo diverges.
    static func resolvedLogo(id: String?, type: String, fallback: String?) async -> String? {
        guard let id else { return fallback }
        if let f = await Fanart.logo(id: id, type: type) { return f }
        return logo(id: id, fallback: fallback)
    }
}

/// A title's clearlogo resolved ASYNC by id (`PosterArtwork.resolvedLogo`: fanart.tv first when enabled,
/// else the ERDB-aware add-on/metahub logo), rendered as an image with a styled title-text fallback. EVERY
/// hero/detail logo slot on tvOS, iOS, and Mac uses this so fanart + the logo precedence are IDENTICAL on
/// all platforms (no per-platform divergence). The title text shows immediately and the logo swaps in once
/// resolved (instant when fanart is off - no network; one hop when on), so the band never blanks.
struct ResolvedTitleLogo<TitleText: View>: View {
    let id: String?
    let type: String
    let fallbackLogo: String?
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var shadowOpacity: Double = 0.45
    var shadowRadius: CGFloat = 10
    var shadowY: CGFloat = 4
    var accessibilityName: String = ""
    @ViewBuilder var titleText: () -> TitleText
    @State private var logoURL: String?

    var body: some View {
        Group {
            if let logoURL, !logoURL.isEmpty, let rawURL = URL(string: logoURL) {
                // AsyncImage cannot attach headers, so a rating-baked ERDB logo (erdb.vortx.tv, a gated host)
                // is signed via query params (`vts`/`vkid`/`vsig`) instead. `signedURL` MEMOIZES per raw URL
                // (reuse within half the 300s worker window), so this body re-evaluating on focus/scroll/
                // progress ticks returns the SAME signed URL: AsyncImage keeps its identity (no phase reset,
                // no flicker) and URLCache stays warm, instead of a new per-second `vts` busting both. Fails
                // open: a fanart.tv / metahub / add-on logo (non-gated host) or an unprovisioned build is
                // returned unchanged and loads normally.
                let url = VortXEdgeAuth.signedURL(rawURL)
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
                            .accessibilityLabel(accessibilityName)
                    } else {
                        titleText()
                    }
                }
            } else {
                titleText()
            }
        }
        .task(id: id) { logoURL = await PosterArtwork.resolvedLogo(id: id, type: type, fallback: fallbackLogo) }
    }
}
