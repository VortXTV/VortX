import SwiftUI

/// XRDB (eXtended Ratings DataBase, extendedratings.com / IbbyLabs/XRDB) renders posters and backdrops
/// with rating badges baked in from up to 12 sources (IMDb, TMDB, Rotten Tomatoes, Metacritic,
/// Letterboxd, MDBList, Trakt, SIMKL, MyAnimeList, AniList, Kitsu) plus quality badges (4K/HDR/DV), age
/// rating, genres, and streaming-provider logos. It is an IMAGE service: point VortX at a self-hosted or
/// hosted instance and it routes poster/backdrop image URLs through `{base}/{type}/{id}?config={alias}`.
/// This is the artwork layer, NOT debrid (the acronym is unrelated to Real-Debrid and friends).
enum XRDB {
    static let baseKey = "stremiox.xrdb.baseURL"
    static let aliasKey = "stremiox.xrdb.configAlias"
    static let enabledKey = "stremiox.xrdb.enabled"

    /// On by default: VortX now hosts its own baked-poster service (poster.vortx.tv), so ratings on
    /// posters work out of the box. A user can turn it off, or point at their own instance.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var isEnabled: Bool { enabled && normalizedBase() != nil }

    /// The poster-service image URL for a title, or the `fallback` art when disabled or the id is not
    /// renderable. `type` is "poster", "backdrop", "thumbnail", or "logo". The original poster is passed
    /// as `fb` so the service can fail-soft to it (and so a non-IMDb id gracefully shows the plain poster).
    static func imageURL(_ type: String = "poster", id: String, fallback: String?) -> String? {
        guard enabled, let base = normalizedBase(), let rid = renderableID(id) else { return fallback }
        var url = "\(base)/\(type)/\(rid)"
        let alias = (UserDefaults.standard.string(forKey: aliasKey) ?? "").trimmingCharacters(in: .whitespaces)
        if !alias.isEmpty, let q = alias.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += "?config=\(q)"
        }
        if let fb = fallback, let e = fb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += (url.contains("?") ? "&" : "?") + "fb=\(e)"
        }
        return url
    }

    /// True when the poster service can render (and therefore bake a rating onto) this id. Mirror of the
    /// `renderableID` gate `imageURL` uses, exposed so a per-poster badge site can tell whether a baked
    /// rating will arrive for this id (only `tt…` / `tmdb:` do).
    static func canRender(id: String) -> Bool { renderableID(id) != nil }

    /// XRDB renders from IMDb (`tt…`) ids directly and from TMDB ids; other id schemes (`kitsu:`, custom
    /// add-on ids) cannot be rendered, so those keep their raw poster.
    private static func renderableID(_ id: String) -> String? {
        if id.hasPrefix("tt") { return id }
        if id.hasPrefix("tmdb:") { return String(id.dropFirst("tmdb:".count)) }
        return nil
    }

    /// Trimmed base URL, http(s) only, trailing slashes removed. Defaults to VortX's own poster service
    /// when the user has not set a custom instance, so ratings-on-posters ships by default.
    static let defaultBase = "https://poster.vortx.tv"
    private static func normalizedBase() -> String? {
        var s = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return defaultBase }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? defaultBase : s
    }
}

/// Settings screen to point VortX at an XRDB instance for ratings-on-posters. Shared by the tvOS and iOS
/// Settings. The values are not credentials (the admin key stays on the XRDB instance), so they live in
/// UserDefaults and ride the existing settings sync.
struct XRDBSettingsView: View {
    @AppStorage(XRDB.enabledKey) private var enabled = true
    @AppStorage(XRDB.baseKey) private var baseURL = ""
    @AppStorage(XRDB.aliasKey) private var alias = ""
    @AppStorage(ERDB.enabledKey) private var erdbEnabled = false
    @AppStorage(ERDB.tokenKey) private var erdbToken = ""
    @AppStorage(ERDB.baseKey) private var erdbBase = ""
    @AppStorage(ERDB.fanartPostersKey) private var erdbFanartPosters = false
    @AppStorage(Fanart.enabledKey) private var fanartEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Poster artwork & ratings").screenTitleStyle()
                Text("VortX bakes the rating onto your posters using its own service, no setup and no key needed. It is on by default. Advanced: point at your own XRDB-compatible instance (and profile alias) to use richer multi-source artwork instead. Unrelated to debrid.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle(isOn: $enabled) {
                    Text("Show ratings on posters")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vortxSettingsCard()
                field("Custom instance URL (optional)", text: $baseURL, hint: "Leave blank to use VortX's own service. Or set your own XRDB-compatible endpoint.", url: true)
                field("Profile alias (optional)", text: $alias, hint: "Only used with a custom instance: the config profile alias from its Configurator.", url: false)

                Text("ERDB (posters + logos)")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("ERDB renders posters, backdrops, and rating-baked LOGOS and overrides the VortX poster service above when on. It uses VortX's own keyless service, so no token is needed, just turn it on. Advanced: add a Tk- token (or a self-hosted base URL) to use your own ERDB configuration instead.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle(isOn: $erdbEnabled) {
                    Text("Use ERDB (overrides the above)")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vortxSettingsCard()
                Toggle(isOn: $erdbFanartPosters) {
                    Text("Use fanart posters")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vortxSettingsCard()
                Text("Pull posters from fanart.tv instead of the default source (requires ERDB on). Uses your fanart key from Metadata keys if you set one, otherwise VortX's own key.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                field("ERDB token (optional)", text: $erdbToken, hint: "Not required: ERDB works keyless. Only for your own ERDB configurator profile. Stored on this device and synced, encrypted, to your VortX account.", url: false)
                field("ERDB base URL (optional)", text: $erdbBase, hint: "Leave blank to use easyratingsdb.com. Or set a self-hosted ERDB instance.", url: true)

                Text("fanart.tv artwork")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Use community clearlogos from fanart.tv for the hero, INDEPENDENT of ERDB (no rating-baked posters). Uses your fanart.tv key from Metadata keys. More fanart art (clearart, posters, backgrounds) follows.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle(isOn: $fanartEnabled) {
                    Text("Use fanart.tv logos")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vortxSettingsCard()
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder private func field(_ title: String, text: Binding<String>, hint: String, url: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            TextField(url ? "https://…" : "alias", text: text)
                .font(.system(size: 15, design: .monospaced))
                .disableAutocorrection(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
                #endif
            Text(hint).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }
}
