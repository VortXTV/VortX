import Foundation

/// User-tunable subtitle appearance, persisted in UserDefaults and applied to libmpv. Shared by the
/// iOS and tvOS players; configured from the tvOS Settings screen (iOS uses the defaults).
///
/// mpv colour note: colours are `#AARRGGBB` (alpha first). Opaque text/border colours use the plain
/// 6-digit `#RRGGBB` form to avoid alpha-order ambiguity; the subtitle background and shadow use the
/// 8-digit form, where the alpha byte is the whole point.
enum SubtitleStyle {
    /// UserDefaults keys, also bound by `@AppStorage` in the settings UI.
    enum Key {
        static let font = "stremiox.sub.font"
        static let size = "stremiox.sub.size"
        static let color = "stremiox.sub.color"
        static let background = "stremiox.sub.background"
    }

    static let defaultFont = "modern"
    static let defaultSize = "m"
    static let defaultColor = "white"
    static let defaultBackground = "outline"

    /// Choices surfaced in Settings. The `id` is what's persisted.
    ///
    /// "Modern" is the streaming-service look: a clean grotesque sans with a thin outline and a
    /// soft drop shadow. Helvetica Neue resolves through libass's CoreText provider (built into
    /// iOS/tvOS, no bundled file), and non-Latin glyphs still reach the bundled Noto fallback via
    /// `sub-fonts-dir` + `subs-fallback`. "Classic" keeps the heavier all-Noto look.
    static let fonts: [(id: String, label: String)] = [
        ("modern", "Modern"),
        ("classic", "Classic"),
    ]
    static let sizes: [(id: String, label: String, fontSize: Int)] = [
        ("s", "Small", 40), ("m", "Medium", 55), ("l", "Large", 72), ("xl", "Extra Large", 92),
    ]
    static let colors: [(id: String, label: String, hex: String)] = [
        ("white", "White", "#FFFFFF"), ("yellow", "Yellow", "#FFFF00"), ("soft", "Soft", "#F2F2F2"),
    ]
    static let backgrounds: [(id: String, label: String)] = [
        ("outline", "Outline only"), ("shaded", "Shaded"), ("box", "Solid box"),
    ]

    private static func current(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static var fontId: String { current(Key.font, defaultFont) }
    static var fontSize: Int { (sizes.first { $0.id == current(Key.size, defaultSize) } ?? sizes[1]).fontSize }
    static var colorHex: String { (colors.first { $0.id == current(Key.color, defaultColor) } ?? colors[0]).hex }
    static var backgroundId: String { current(Key.background, defaultBackground) }

    /// The mpv face name for the chosen style. Classic prefers the bundled CJK Noto, but the Lite
    /// build ships without it (the ~14 MB font is Full-only), so Classic degrades to plain Noto
    /// Sans there; CJK glyphs still render through `subs-fallback`.
    static var mpvFontName: String {
        if fontId == "modern" { return "Helvetica Neue" }
        return cjkFontBundled ? "Noto Sans CJK KR" : "Noto Sans"
    }

    /// Whether the big CJK Noto ships in this build. Full bundles fonts in a "fonts" folder
    /// reference; Lite copies the small fonts to the bundle root and drops the CJK one.
    static var cjkFontBundled: Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        return FileManager.default.fileExists(atPath: res + "/fonts/NotoSansCJK.otf")
            || FileManager.default.fileExists(atPath: res + "/NotoSansCJK.otf")
    }

    /// mpv option/property name → value pairs realizing the current style. Applied both at player
    /// setup (as options, before init) and live (as properties). Every option that differs between
    /// font styles appears in both branches, so a live switch fully overwrites the previous one.
    static var mpvOptions: [(String, String)] {
        var opts: [(String, String)] = [
            ("sub-font", mpvFontName),
            ("sub-font-size", String(fontSize)),
            ("sub-color", colorHex),
            ("sub-border-color", "#000000"),
        ]
        if fontId == "modern" {
            // Thin outline plus a soft offset shadow carries the contrast instead of a heavy border.
            opts.append(("sub-border-size", "2"))
            opts.append(("sub-shadow-offset", "2"))
            opts.append(("sub-shadow-color", "#80000000"))
        } else {
            opts.append(("sub-border-size", "3"))
            opts.append(("sub-shadow-offset", "0"))
            opts.append(("sub-shadow-color", "#00000000"))
        }
        switch backgroundId {
        case "shaded": opts.append(("sub-back-color", "#80000000"))   // ~50% black box
        case "box":    opts.append(("sub-back-color", "#FF000000"))   // opaque black box
        default:       opts.append(("sub-back-color", "#00000000"))   // outline only (transparent)
        }
        return opts
    }
}
