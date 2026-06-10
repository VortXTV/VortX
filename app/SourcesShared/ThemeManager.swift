import SwiftUI
import UIKit

private func themeRGB(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
}

/// A selectable accent. `base` recolors focus / selection / primary / progress everywhere;
/// `bright` is the focus-glow peak.
struct AccentOption: Identifiable {
    let id: String
    let label: String
    let base: Color
    let bright: Color
}

/// The user-chosen theme (accent + chrome), persisted to `UserDefaults` and applied through
/// `Theme.Palette`, which reads `ThemeManager.shared`. The top-level screens observe this object so a
/// change repaints the app live, without a `.id` rebuild that would drop focus mid-pick.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accentID: String { didSet { UserDefaults.standard.set(accentID, forKey: Self.accentKey) } }
    @Published var oled: Bool { didSet { UserDefaults.standard.set(oled, forKey: Self.oledKey) } }

    private static let accentKey = "stremiox.theme.accent"
    private static let oledKey = "stremiox.theme.oled"

    private init() {
        accentID = UserDefaults.standard.string(forKey: Self.accentKey) ?? "ember"
        oled = UserDefaults.standard.bool(forKey: Self.oledKey)
    }

    /// Eight curated accents. Ember is the default and matches the original ember design.
    static let accents: [AccentOption] = [
        AccentOption(id: "ember",   label: "Ember",   base: themeRGB(0.949, 0.471, 0.294), bright: themeRGB(1.000, 0.569, 0.388)),
        AccentOption(id: "ocean",   label: "Ocean",   base: themeRGB(0.298, 0.565, 0.886), bright: themeRGB(0.435, 0.690, 0.984)),
        AccentOption(id: "forest",  label: "Forest",  base: themeRGB(0.376, 0.706, 0.443), bright: themeRGB(0.478, 0.831, 0.553)),
        AccentOption(id: "royal",   label: "Royal",   base: themeRGB(0.580, 0.451, 0.902), bright: themeRGB(0.694, 0.561, 0.984)),
        AccentOption(id: "crimson", label: "Crimson", base: themeRGB(0.886, 0.310, 0.357), bright: themeRGB(0.984, 0.420, 0.463)),
        AccentOption(id: "gold",    label: "Gold",    base: themeRGB(0.886, 0.706, 0.290), bright: themeRGB(0.980, 0.804, 0.400)),
        AccentOption(id: "rose",    label: "Rose",    base: themeRGB(0.929, 0.451, 0.620), bright: themeRGB(1.000, 0.561, 0.710)),
        AccentOption(id: "mono",    label: "Mono",    base: themeRGB(0.820, 0.800, 0.761), bright: themeRGB(0.922, 0.910, 0.882)),
    ]

    private var option: AccentOption { Self.accents.first { $0.id == accentID } ?? Self.accents[0] }

    var accent: Color { option.base }
    var accentBright: Color { option.bright }

    // Chrome: a dark near-black tinted toward the accent's hue (so "Warm" now follows the accent —
    // Ocean reads cool, Forest green, Mono near-neutral), or true black for OLED / AMOLED panels.
    var canvas: Color   { oled ? themeRGB(0, 0, 0)             : tintedDark(0.085) }
    var surface1: Color { oled ? themeRGB(0.055, 0.055, 0.057) : tintedDark(0.130) }
    var surface2: Color { oled ? themeRGB(0.094, 0.094, 0.098) : tintedDark(0.175) }
    var surface3: Color { oled ? themeRGB(0.141, 0.141, 0.149) : tintedDark(0.225) }
    var hairline: Color { oled ? themeRGB(0.196, 0.196, 0.204) : tintedDark(0.260) }

    /// A dark surface at `brightness`, hued toward the current accent. Subtle (like the original warm
    /// near-black) but it now shifts with the chosen accent. Saturation is half the accent's, capped, so
    /// vivid accents tint gently and Mono stays near-neutral.
    private func tintedDark(_ brightness: Double) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(accent).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return themeRGB(brightness, brightness, brightness)
        }
        return Color(hue: Double(h), saturation: min(Double(s) * 0.5, 0.34), brightness: brightness)
    }
}
