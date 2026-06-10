import AVFoundation
import AVKit
import CoreMedia
import UIKit
import os

/// The dynamic range mpv reports for the playing file, reduced to the modes the
/// Apple TV display pipeline can be asked to match. Dolby Vision content renders
/// through mpv's PQ path, so it requests the HDR10 display mode.
enum ContentDynamicRange: String {
    case sdr
    case hdr10
    case hlg
}

/// Drives the Apple TV's HDMI display-mode switch so HDR content lights the TV's
/// HDR mode instead of being tone-mapped to SDR.
///
/// tvOS has no extended-dynamic-range flag on CAMetalLayer (that API is iOS and
/// macOS only). The only HDR output path is asking AVDisplayManager to renegotiate
/// the HDMI link into an HDR mode, then rendering PQ or HLG into a layer tagged
/// with the matching colorspace (MPVMetalViewController does both halves).
///
/// The request is honored only when the user has Settings > Video and Audio >
/// Match Content > Match Dynamic Range enabled; otherwise tvOS ignores it. That
/// case is logged so a "still SDR" report is diagnosable from the console.
enum HDRDisplayMode {
    private static let log = Logger(subsystem: "com.stremiox.app", category: "hdr")

#if os(tvOS)
    /// Ask tvOS to switch the display into the mode matching the content. The
    /// dynamic range travels as colour attachments (PQ or HLG transfer over
    /// BT.2020) on a CMFormatDescription, which is the public way to build
    /// AVDisplayCriteria.
    @MainActor
    static func request(_ range: ContentDynamicRange, fps: Double, width: Int, height: Int, in window: UIWindow?) {
        guard let window = window ?? fallbackWindow else {
            log.error("display switch skipped: no window")
            return
        }
        // UIWindow.avDisplayManager is declared in the SDK for all of tvOS but the
        // SIMULATOR runtime does not implement it: touching the property throws an
        // unrecognized-selector exception and aborts the app (two live crashes,
        // 2026-06-10, .ips on file). Real hardware has it since tvOS 11.2. Guard at
        // runtime too in case some device variant ever lacks it.
        guard let manager = displayManager(of: window) else { return }
        guard range != .sdr else {
            reset(in: window)
            return
        }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            log.warning("display switch skipped: Match Dynamic Range is OFF (tvOS Settings > Video and Audio > Match Content)")
            return
        }
        let transfer: CFString = range == .hlg
            ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(max(width, 1)),
            height: Int32(max(height, 1)),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            log.error("display switch failed: CMVideoFormatDescriptionCreate err=\(status)")
            return
        }
        let rate = Float(fps > 0 ? fps : 60)
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format)
        log.log("display switch requested: \(range.rawValue, privacy: .public) @\(rate, privacy: .public)fps \(width)x\(height)")
    }

    /// Return the TV to its default display mode. Safe to call repeatedly.
    @MainActor
    static func reset(in window: UIWindow?) {
        guard let window = window ?? fallbackWindow,
              let manager = displayManager(of: window) else { return }
        if manager.preferredDisplayCriteria != nil {
            manager.preferredDisplayCriteria = nil
            log.log("display criteria cleared, back to default mode")
        }
    }

    /// The display manager, only where the runtime actually implements it.
    /// On the simulator this is a logged no-op instead of a crash.
    @MainActor
    private static func displayManager(of window: UIWindow) -> AVDisplayManager? {
#if targetEnvironment(simulator)
        log.log("display switch skipped: the simulator has no HDMI display modes")
        return nil
#else
        guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
            log.warning("display switch skipped: avDisplayManager unavailable on this device")
            return nil
        }
        return window.avDisplayManager
#endif
    }

    /// The player view can already be detached from its window during teardown,
    /// which would otherwise leave the TV stuck in HDR mode after close.
    @MainActor
    private static var fallbackWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first }
            .first
    }
#endif
}
