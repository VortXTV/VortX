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

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && normalizedBase() != nil
    }

    /// The XRDB image URL for a title, or the `fallback` art when XRDB is off or the id is not
    /// renderable. `type` is "poster", "backdrop", "thumbnail", or "logo".
    static func imageURL(_ type: String = "poster", id: String, fallback: String?) -> String? {
        guard UserDefaults.standard.bool(forKey: enabledKey),
              let base = normalizedBase(),
              let rid = renderableID(id) else { return fallback }
        var url = "\(base)/\(type)/\(rid)"
        let alias = (UserDefaults.standard.string(forKey: aliasKey) ?? "").trimmingCharacters(in: .whitespaces)
        if !alias.isEmpty, let q = alias.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += "?config=\(q)"
        }
        return url
    }

    /// XRDB renders from IMDb (`tt…`) ids directly and from TMDB ids; other id schemes (`kitsu:`, custom
    /// add-on ids) cannot be rendered, so those keep their raw poster.
    private static func renderableID(_ id: String) -> String? {
        if id.hasPrefix("tt") { return id }
        if id.hasPrefix("tmdb:") { return String(id.dropFirst("tmdb:".count)) }
        return nil
    }

    /// Trimmed base URL, http(s) only, trailing slashes removed; nil if blank or not a web URL.
    private static func normalizedBase() -> String? {
        var s = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }
}

/// Settings screen to point VortX at an XRDB instance for ratings-on-posters. Shared by the tvOS and iOS
/// Settings. The values are not credentials (the admin key stays on the XRDB instance), so they live in
/// UserDefaults and ride the existing settings sync.
struct XRDBSettingsView: View {
    @AppStorage(XRDB.enabledKey) private var enabled = false
    @AppStorage(XRDB.baseKey) private var baseURL = ""
    @AppStorage(XRDB.aliasKey) private var alias = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Ratings on posters").screenTitleStyle()
                Text("XRDB (extendedratings.com) bakes ratings from up to 12 sources, quality badges, and streaming-provider logos onto your posters and backdrops. Run your own XRDB instance or use a hosted one, set its address and your profile alias, and VortX loads its artwork everywhere. Optional, and unrelated to debrid.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle("Use XRDB posters", isOn: $enabled)
                    .tint(Theme.Palette.accent)
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                field("Instance URL", text: $baseURL, hint: "e.g. https://xrdb.yourhost.com (or a hosted XRDB endpoint).", url: true)
                field("Profile alias", text: $alias, hint: "The config profile alias you saved in XRDB's Configurator.", url: false)
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
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
