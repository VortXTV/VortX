import Foundation

/// User-tunable subtitle appearance, persisted in UserDefaults and applied to libmpv. Shared by the
/// iOS and tvOS players; configured from the tvOS Settings screen (iOS uses the defaults).
///
/// mpv colour note: colours are `#AARRGGBB` (alpha first). Opaque text/border colours use the plain
/// 6-digit `#RRGGBB` form to avoid alpha-order ambiguity; only the subtitle background uses the
/// 8-digit form, where the alpha byte is the whole point.
enum SubtitleStyle {
    /// UserDefaults keys, also bound by `@AppStorage` in the settings UI.
    enum Key {
        static let size = "stremiox.sub.size"
        static let color = "stremiox.sub.color"
        static let background = "stremiox.sub.background"
    }

    static let defaultSize = "m"
    static let defaultColor = "white"
    static let defaultBackground = "outline"

    /// Choices surfaced in Settings. The `id` is what's persisted.
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

    static var fontSize: Int { (sizes.first { $0.id == current(Key.size, defaultSize) } ?? sizes[1]).fontSize }
    static var colorHex: String { (colors.first { $0.id == current(Key.color, defaultColor) } ?? colors[0]).hex }
    static var backgroundId: String { current(Key.background, defaultBackground) }

    /// mpv option/property name → value pairs realizing the current style. Applied both at player
    /// setup (as options, before init) and live (as properties).
    static var mpvOptions: [(String, String)] {
        var opts: [(String, String)] = [
            ("sub-font-size", String(fontSize)),
            ("sub-color", colorHex),
            ("sub-border-size", "3"),
            ("sub-border-color", "#000000"),
        ]
        switch backgroundId {
        case "shaded": opts.append(("sub-back-color", "#80000000"))   // ~50% black box
        case "box":    opts.append(("sub-back-color", "#FF000000"))   // opaque black box
        default:       opts.append(("sub-back-color", "#00000000"))   // outline only (transparent)
        }
        return opts
    }
}
