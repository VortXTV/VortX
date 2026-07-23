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
        static let sizeScale = "stremiox.sub.sizeScale"
        static let color = "stremiox.sub.color"
        static let background = "stremiox.sub.background"
        static let brightness = "stremiox.sub.brightness"
    }

    static let defaultFont = "modern"
    static let defaultSize = "m"
    static let defaultColor = "white"
    static let defaultBackground = "outline"
    /// 100% = full brightness, the no-op default: an existing viewer's subtitles are unchanged.
    static let defaultBrightness = "100"

    /// A fine +/- multiplier on top of the named size (Settings and the in-player stepper),
    /// so a viewer can nudge subtitles bigger or smaller without jumping a whole size step.
    static let sizeScaleRange: ClosedRange<Double> = 0.60...1.80
    static let sizeScaleStep: Double = 0.10

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
        // A genuinely OLED-friendly soft grey (~70% white). On HDR/Dolby Vision an all-white subtitle is
        // driven near peak nits and blooms on an OLED panel; a grey base sits far below peak while staying
        // clearly legible against the picture (#155).
        ("grey", "Grey", "#B3B3B3"),
    ]
    static let backgrounds: [(id: String, label: String)] = [
        ("outline", "Outline only"), ("shaded", "Shaded"), ("box", "Solid box"),
    ]

    /// Subtitle brightness: a multiplier on the chosen colour's luminance, so ANY preset (white, yellow,
    /// soft, grey) can be dimmed for OLED HDR/DV viewing without picking a different hue (#155). Discrete
    /// levels mirror the Colour row on every surface (a menu Picker on iOS, a choiceRow on tvOS, option rows
    /// in-player). The `id` is what's persisted; `factor` scales each RGB channel. 100% is the default no-op.
    static let brightnessLevels: [(id: String, label: String, factor: Double)] = [
        ("100", "100%", 1.0), ("80", "80%", 0.80), ("60", "60%", 0.60), ("40", "40%", 0.40),
    ]

    private static func current(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static var fontId: String { current(Key.font, defaultFont) }

    /// The fine size multiplier (default 1.0), clamped to range.
    static var sizeScale: Double {
        let raw = UserDefaults.standard.object(forKey: Key.sizeScale) as? Double ?? 1.0
        return min(max(raw, sizeScaleRange.lowerBound), sizeScaleRange.upperBound)
    }

    /// The named base size times the fine multiplier, the value handed to mpv's sub-font-size.
    static var fontSize: Int {
        let base = (sizes.first { $0.id == current(Key.size, defaultSize) } ?? sizes[1]).fontSize
        return Int((Double(base) * sizeScale).rounded())
    }
    static var brightnessId: String { current(Key.brightness, defaultBrightness) }

    /// The luminance multiplier for the chosen brightness level (1.0 = full, the default). An unknown stored
    /// id falls back to the first level (100%), so a bad value can never darken subtitles unexpectedly.
    static var brightnessFactor: Double {
        (brightnessLevels.first { $0.id == brightnessId } ?? brightnessLevels[0]).factor
    }

    /// The chosen preset colour AFTER the brightness multiplier, i.e. the exact `#RRGGBB` handed to every
    /// renderer (mpv `sub-color`, the AVPlayer overlay label, and the AVPlayer-native `AVTextStyleRule`). This
    /// is the ONE chokepoint the two engines share, so dimming applied here reaches both consistently. At 100%
    /// this is the untouched preset hex, so existing viewers see no change.
    static var colorHex: String {
        let base = (colors.first { $0.id == current(Key.color, defaultColor) } ?? colors[0]).hex
        return dimmedHex(base, factor: brightnessFactor)
    }

    /// Multiply each RGB channel of a `#RRGGBB` hex by `factor`, lowering luminance while preserving hue.
    /// `factor` is clamped to 0...1 (so a bad level can neither brighten past the preset nor go negative); at
    /// 1.0 the result equals the input colour. Malformed input (not exactly 6 hex digits) is returned
    /// unchanged so a caller never renders an empty colour. Pure and side-effect free for direct testing.
    static func dimmedHex(_ hex: String, factor: Double) -> String {
        let f = min(max(factor, 0.0), 1.0)
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return hex }
        let r = UInt32((Double((value >> 16) & 0xFF) * f).rounded())
        let g = UInt32((Double((value >> 8) & 0xFF) * f).rounded())
        let b = UInt32((Double(value & 0xFF) * f).rounded())
        return String(format: "#%02X%02X%02X", min(r, 255), min(g, 255), min(b, 255))
    }
    static var backgroundId: String { current(Key.background, defaultBackground) }

    /// The mpv face name for the chosen style. BOTH styles name a BUNDLED face on purpose:
    /// libass base-font selection is strictly name-based with no wildcard last resort, so a
    /// face that only exists through the CoreText provider (e.g. "Helvetica Neue") can fail
    /// per-device and silently render NO subtitles at all (seen in the field on 0.2.45, where
    /// Modern briefly named it). Bundled fonts load as libass memory fonts and cannot fail;
    /// CoreText then only serves per-glyph fallback, whose worst case is tofu, never absence.
    /// The Modern look comes from the thin-outline + shadow treatment, not the face.
    static var mpvFontName: String {
        if fontId == "modern" { return "Noto Sans" }
        return cjkFontBundled ? "Noto Sans CJK KR" : "Noto Sans"
    }

    /// Whether the CJK Noto made it into this bundle. Every build ships it today (the trimmed
    /// face is ~6.5 MB compressed; without it CJK subtitles are tofu, since libass's CoreText
    /// fallback does not cover CJK here), but the fonts folder is an optional resource, so
    /// check rather than assume. Both layouts are probed: "fonts" folder and bundle root.
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
