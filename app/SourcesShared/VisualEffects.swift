import Foundation

/// The viewer's effects choices for the TV interface (Settings > Effects and performance).
///
/// Every control stores "auto" or an explicit choice. Auto follows Performance: Reduced picks the light
/// option, Auto/Full on a capable device keeps the rich one. Choices stay on this device and are not
/// synced, since a weak box that needs still backdrops must not switch them off on a 4K Apple TV.
/// Android uses the same keys and values.
enum VisualEffects {
    enum Backdrop: String, CaseIterable, Sendable {
        /// The focused title's art fills the screen and crossfades as focus moves.
        case animated
        /// The art still follows focus but swaps without a crossfade.
        case still
        /// No focus art; the page keeps its plain backdrop and only the title details change.
        case off
    }

    static let backdropKey = "vortx.effects.backdrop"
    static let glassKey = "vortx.effects.glass"
    static let motionKey = "vortx.effects.motion"
    static let artworkKey = "vortx.effects.artwork"
    static let auto = "auto"

    // MARK: Policy (pure)

    static func backdrop(stored: String?, reduced: Bool) -> Backdrop {
        stored.flatMap(Backdrop.init(rawValue:)) ?? (reduced ? .still : .animated)
    }

    /// Translucent glass and blurred art fallbacks. Off renders the same opaque surfaces as the system's
    /// Reduce Transparency.
    static func glass(stored: String?, reduced: Bool) -> Bool { toggle(stored, reduced: reduced) }

    /// Interface animations: crossfades, focus and layout transitions. The system focus motion of tvOS
    /// itself is not affected.
    static func motion(stored: String?, reduced: Bool) -> Bool { toggle(stored, reduced: reduced) }

    /// True when hero art is capped at 1080p even on a 4K display, which keeps much less image data
    /// decoded and resident.
    static func hdArtworkOnly(stored: String?, reduced: Bool) -> Bool {
        switch stored {
        case "hd": return true
        case "full": return false
        default: return reduced
        }
    }

    private static func toggle(_ stored: String?, reduced: Bool) -> Bool {
        switch stored {
        case "on": return true
        case "off": return false
        default: return !reduced
        }
    }

    // MARK: Current values

    /// Auto only lightens the interface on Apple TV: Performance there detects the Apple TV HD, while an
    /// older iPhone or Mac keeps its effects unless they are switched off explicitly.
    static var reducedForAuto: Bool {
#if os(tvOS)
        PerformanceMode.reduced
#else
        false
#endif
    }

    private static func stored(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }

    static var currentBackdrop: Backdrop { backdrop(stored: stored(backdropKey), reduced: reducedForAuto) }
    static var glassEnabled: Bool { glass(stored: stored(glassKey), reduced: reducedForAuto) }
    static var motionEnabled: Bool { motion(stored: stored(motionKey), reduced: reducedForAuto) }
    static var hdArtworkOnly: Bool { hdArtworkOnly(stored: stored(artworkKey), reduced: reducedForAuto) }
}
