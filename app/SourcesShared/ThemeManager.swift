import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    /// UI text scale, 0.80 to 1.40. @Published so a change repaints the whole app LIVE (every screen
    /// that observes ThemeManager), the same path the accent uses; Theme.Typography reads it per
    /// render via `Theme.scaled`. Static-let typography never updated because tvOS "Restart App"
    /// can't relaunch the process, so the frozen sizes stuck.
    ///
    /// The setter explicitly fans `objectWillChange` out FIRST and clamps in one place, so a write
    /// from any path (the iOS Stepper's `$theme.textScale` binding, the tvOS +/- buttons via
    /// `adjustTextScale`, a profile switch via `applyTheme`) invalidates observers deterministically.
    /// Reading `textScale` through `Theme.Typography` alone does NOT subscribe a view — a view must
    /// observe ThemeManager (`@EnvironmentObject theme`) for its fonts to repaint on change.
    @Published var textScale: Double {
        didSet {
            let clamped = min(max(textScale, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound)
            // Re-entrancy guard: only correct out-of-range writes (clamping fires didSet once more,
            // then the value already equals `clamped` and we stop), never loop on an in-range write.
            if clamped != textScale { textScale = clamped; return }
            UserDefaults.standard.set(textScale, forKey: Self.textScaleKey)
        }
    }

    static let textScaleRange: ClosedRange<Double> = 0.80...1.40
    static let textScaleStep: Double = 0.05

    private static let accentKey = "stremiox.theme.accent"
    private static let oledKey = "stremiox.theme.oled"
    private static let textScaleKey = "stremiox.theme.textScale"

    private init() {
        // New installs land on the VortX brand accent; anyone who already picked an accent keeps it.
        accentID = UserDefaults.standard.string(forKey: Self.accentKey) ?? "vortx"
        oled = UserDefaults.standard.bool(forKey: Self.oledKey)
        let saved = UserDefaults.standard.object(forKey: Self.textScaleKey) as? Double
        textScale = saved.map { min(max($0, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound) } ?? 1.0
    }

    /// Re-read the persisted theme into the published properties. This object reads these three keys ONLY
    /// in `init`, so anything that rewrites them behind it (an account settings pull, a backup file restore:
    /// both write `UserDefaults` directly, and `UserDefaults` KVO does not fire for DOTTED keys like these,
    /// so nothing else notices) leaves the singleton holding the PRE-restore values.
    ///
    /// That is not merely a stale repaint. Every property here re-persists itself in `didSet`, so the next
    /// write from ANY path (a profile switch through `applyTheme`, the iOS Stepper's `$theme.textScale`
    /// binding, the tvOS +/- buttons via `adjustTextScale`) flushes the STALE in-memory value straight back
    /// over the value the restore just wrote, and the restored theme is permanently gone. Re-reading first is
    /// what makes that write-back harmless: it can then only ever write the restored value back.
    ///
    /// Assigning re-fires each `didSet`, which re-persists the identical value it was just read from (a no-op
    /// write) and publishes, so observers repaint LIVE without a relaunch. Guarded per property so an
    /// unchanged value never churns `objectWillChange`. The defaults mirror `init` exactly, so a restore that
    /// omits a key lands on the same value a fresh launch would pick. Call on the main thread (the same
    /// contract as `SourcePreferences.reload`).
    func reloadFromDefaults() {
        let d = UserDefaults.standard
        let savedAccent = d.string(forKey: Self.accentKey) ?? "vortx"
        if accentID != savedAccent { accentID = savedAccent }
        let savedOLED = d.bool(forKey: Self.oledKey)
        if oled != savedOLED { oled = savedOLED }
        let savedScale = (d.object(forKey: Self.textScaleKey) as? Double)
            .map { min(max($0, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound) } ?? 1.0
        if textScale != savedScale { textScale = savedScale }
    }

    /// Nudge the text scale one step within range (the tvOS Settings +/- buttons; the iOS Settings
    /// Stepper writes `$theme.textScale` directly). Rounds to whole percent; the `textScale` setter
    /// clamps to range and publishes, so observers repaint live.
    func adjustTextScale(_ direction: Int) {
        let next = textScale + Double(direction) * Self.textScaleStep
        textScale = (next * 100).rounded() / 100
    }

    /// Nine curated accents. VortX (the brand gold/obsidian) is the default; Ember matches the original
    /// ember design and stays available for anyone who prefers the coral cast.
    static let accents: [AccentOption] = [
        AccentOption(id: "vortx",   label: "VortX",   base: themeRGB(0.851, 0.467, 0.024), bright: themeRGB(0.961, 0.620, 0.043)),
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

    /// Ink that sits ON the accent fill — primary-button labels (Watch/Play/Save/Sign In), on-accent
    /// spinners, the profile "current" check. It was a hardcoded warm-brown literal, so it kept an
    /// orange cast on top of ANY accent — the "still looks orange after switching to pink" report.
    /// Now derived from the accent's luminance: Ember keeps its signature warm-brown; every other
    /// accent gets a neutral near-black on light/mid fills or near-white on dark fills (max contrast,
    /// no stale hue). Re-reads live when the accent changes, like `accent` itself.
    var onAccent: Color {
        if accentID == "vortx" { return themeRGB(0.059, 0.051, 0.039) }   // brand obsidian ink on VortX gold
        if accentID == "ember" { return themeRGB(0.106, 0.067, 0.043) }   // signature warm ink on ember
        return accentLuminance > 0.5 ? themeRGB(0.10, 0.10, 0.11) : themeRGB(0.97, 0.97, 0.96)
    }

    /// Perceived (Rec. 709) luminance of the current accent, for picking the on-accent ink.
    private var accentLuminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        // Guard the sRGB conversion (matches tintedDark): without it a nil conversion leaves r/g/b at
        // 0, luminance reads 0, and every macOS accent would wrongly get the near-white ink.
        guard let srgb = NSColor(accent).usingColorSpace(.sRGB) else { return 0.55 }   // mid → neutral-dark ink
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }

    // Chrome: a dark near-black tinted toward the accent's hue (so "Warm" now follows the accent —
    // Ocean reads cool, Forest green, Mono near-neutral), or true black for OLED / AMOLED panels.
    var canvas: Color   { oled ? themeRGB(0, 0, 0)             : tintedDark(0.085) }
    var surface1: Color { oled ? themeRGB(0.055, 0.055, 0.057) : tintedDark(0.130) }
    var surface2: Color { oled ? themeRGB(0.094, 0.094, 0.098) : tintedDark(0.175) }
    var surface3: Color { oled ? themeRGB(0.141, 0.141, 0.149) : tintedDark(0.225) }
    var hairline: Color { oled ? themeRGB(0.196, 0.196, 0.204) : tintedDark(0.260) }

    /// The translucent glass VEIL: the tone `VortXGlass` composites over a backdrop to make a raised
    /// surface. It lives HERE, next to the surface ladder and behind the same `tintedDark` generator, on
    /// purpose: the veil is not a decorative film, it is the LIFT that puts a glass surface one step up the
    /// SAME ladder as `surface1` / `surface2` / `surface3`. Keeping it beside them (rather than as a private
    /// constant inside the glass file) is what stops it drifting away from the chrome again.
    ///
    /// Why it is a MID tone, not a near-black: a veil composites, so its tone decides which way the surface
    /// moves. A veil DARKER than the canvas can only ever push a surface DOWN toward (or below) the
    /// background, which is how the glass ended up reading as a dent with only its 1px highlight visible. A
    /// mid veil lifts a dark backdrop and pulls a bright one down, which is exactly what a real material
    /// does and why it reads on both.
    ///
    /// Why THESE numbers: they are derived, not picked. The brightness is the value that makes the EXISTING
    /// alpha ladder land back on the app's own surfaces, so glass and the opaque surfaces agree instead of
    /// being two unrelated systems:
    ///   warm: 0.265 * 0.50 + 0.085 * 0.50 = 0.175 = `surface2` (a pill / chip at `pillFillAlpha`)
    ///         0.265 * 0.74 + 0.085 * 0.26 = 0.218 ≈ `surface3` (a panel at `panelFillAlpha`)
    ///   oled: 0.188 * 0.50 + 0.000 * 0.50 = 0.094 = `surface2`
    ///         0.188 * 0.74 + 0.000 * 0.26 = 0.139 ≈ `surface3`
    ///
    /// Why it follows the ACCENT (unlike the fixed-warm scrim in `VortXGlass`): this tone's whole job is to
    /// be an elevation step OF the chrome, and the chrome is accent-hued (`tintedDark` follows the accent, so
    /// Ocean chrome is cool and Forest green). A hardcoded warm veil laid a brown film over cool chrome on
    /// Ocean / Forest / Royal / Mono. Sharing the generator keeps all 9 accents x 2 chrome modes coherent.
    /// OLED goes near-neutral to match the neutral OLED surfaces above.
    var glassVeil: Color { oled ? themeRGB(0.188, 0.188, 0.196) : tintedDark(0.265) }

    /// A dark surface at `brightness`, hued toward the current accent. Subtle (like the original warm
    /// near-black) but it now shifts with the chosen accent. Saturation is half the accent's, capped, so
    /// vivid accents tint gently and Mono stays near-neutral.
    private func tintedDark(_ brightness: Double) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        guard UIColor(accent).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return themeRGB(brightness, brightness, brightness)
        }
        #else
        guard let rgb = NSColor(accent).usingColorSpace(.sRGB) else {
            return themeRGB(brightness, brightness, brightness)
        }
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return Color(hue: Double(h), saturation: min(Double(s) * 0.5, 0.34), brightness: brightness)
    }
}
