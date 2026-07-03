import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether the CURRENT device + display can actually present Dolby Vision / HDR, so the engine router can honor
/// the owner DV mandate ("if there is Dolby Vision, play Dolby Vision") only where the hardware can deliver it
/// and fall back to libmpv's honest HDR10 tone-map otherwise.
///
/// Per-platform truth:
///   - tvOS: the Apple TV negotiates an HDR display mode over HDMI itself for HDR/DV content, so a 4K Apple TV
///     is treated as DV-capable. (A genuinely SDR-only panel just gets AVPlayer's own SDR conversion; the
///     AVPlayer -> libmpv .failed backstop still covers a hard failure.)
///   - iOS/iPadOS: modern iPhones/iPads are DV-capable displays (EDR). We read the main screen's EDR headroom
///     when available; when it can't be read we assume capable (these devices are, and the fallback protects us).
///   - macOS: TRUE DV needs Apple-silicon (the DV-capable VideoToolbox path) AND an EDR-capable display
///     (XDR/HDR panel or HDR-capable external). Both are checked; an Intel Mac or a non-EDR display reports
///     false, so DV MKVs there stay on libmpv (tone-mapped HDR10, honestly labeled).
///
/// Deliberately conservative + cheap; read at playback-start routing time only. Never crashes.
enum DVDisplaySupport {

    /// True when this hardware/display can present Dolby Vision. Consulted by `PlayerEngineRouter` to decide
    /// whether DV content should take the AVPlayer (remux) lane by default.
    @MainActor
    static var isCapable: Bool {
        #if os(tvOS)
        // The Apple TV switches the connected display into HDR/DV itself for HDR content; treat 4K-class boxes
        // as capable. (There is no per-title display-capability read on tvOS before playback.)
        return true
        #elseif os(iOS)
        // EDR headroom > 1 means the panel can show more than SDR white (DV/HDR capable). Fall back to true
        // when the screen can't be read (all DV-era iPhones/iPads are capable; the .failed backstop covers edge
        // cases like an SDR external display).
        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen }).first {
            return screen.potentialEDRHeadroom > 1.0
        }
        return UIScreen.main.potentialEDRHeadroom > 1.0
        #elseif os(macOS)
        // TRUE DV on the Mac needs BOTH Apple silicon (the DV-capable decode/display stack) and an EDR display.
        guard isAppleSilicon else { return false }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        // Any attached screen with EDR headroom > 1 can present HDR/DV (the window may be on that screen).
        return screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 }
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// True on Apple-silicon Macs (arm64). Cached; the Mac target is Apple-silicon-only in practice, but check
    /// honestly so a Rosetta/Intel context reports false and DV stays on libmpv there.
    static let isAppleSilicon: Bool = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        // Apple-silicon reports "arm64"; Rosetta-translated processes report "x86_64".
        return machine.lowercased().contains("arm64")
    }()
    #endif
}
