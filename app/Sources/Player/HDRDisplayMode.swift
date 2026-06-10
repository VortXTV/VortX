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
/// Match Content > Match Dynamic Range enabled; otherwise tvOS ignores it. Every
/// step logs to both the unified log and DiagnosticsLog, because this code can
/// only misbehave on real hardware where the unified log is hard to reach.
enum HDRDisplayMode {
    private static let log = Logger(subsystem: "com.stremiox.app", category: "hdr")

    private static func note(_ message: String) {
        log.log("\(message, privacy: .public)")
        DiagnosticsLog.log("hdr", message)
    }

#if os(tvOS)
    /// Ground truth on the HDMI renegotiation, straight from AVKit. Referencing
    /// these notification constants also creates the hard symbol dependency that
    /// keeps the linker from dropping AVKit (see project.yml).
    private static var observersInstalled = false

    @MainActor
    private static func installModeSwitchObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: .AVDisplayManagerModeSwitchStart, object: nil, queue: .main) { _ in
            DiagnosticsLog.logSync("hdr", "display mode switch STARTED (system notification)")
        }
        center.addObserver(forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: .main) { _ in
            DiagnosticsLog.logSync("hdr", "display mode switch ENDED (system notification)")
        }
    }

    /// Ask tvOS to switch the display into the mode matching the content.
    @MainActor
    static func request(_ range: ContentDynamicRange, fps: Double, width: Int, height: Int, in window: UIWindow?) {
        installModeSwitchObservers()
        guard let window = window ?? fallbackWindow else {
            note("display switch skipped: no window")
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
            note("display switch skipped: Match Dynamic Range is OFF (tvOS Settings > Video and Audio > Match Content)")
            return
        }
        let rate = Float(fps > 0 ? fps : 60)
        guard let criteria = makeCriteria(range: range, rate: rate, width: width, height: height) else {
            note("display switch failed: could not build criteria")
            return
        }
        let encoded = (criteria.value(forKey: "videoDynamicRange") as? Int) ?? -999
        manager.preferredDisplayCriteria = criteria
        note("display switch requested: \(range.rawValue) @\(rate)fps \(width)x\(height) criteriaRange=\(encoded) switchInProgress=\(manager.isDisplayModeSwitchInProgress)")
        // The HDMI renegotiation takes a beat; record whether tvOS actually started one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            note("display switch +2.5s: switchInProgress=\(manager.isDisplayModeSwitchInProgress) criteriaStillSet=\(manager.preferredDisplayCriteria != nil)")
        }
    }

    /// Build the criteria. The private integer initializer is preferred: it is what
    /// the field-proven tvOS players ship, while criteria built from synthetic format
    /// descriptions via the public initializer have been seen being ignored by tvOS.
    /// Falls back to the public path if the SPI ever disappears.
    @MainActor
    private static func makeCriteria(range: ContentDynamicRange, rate: Float, width: Int, height: Int) -> AVDisplayCriteria? {
        let sel = NSSelectorFromString("initWithRefreshRate:videoDynamicRange:")
        if AVDisplayCriteria.instancesRespond(to: sel) {
            let dynamicRange: Int32 = range == .hlg ? 3 : 2   // 2 = HDR10/PQ, 3 = HLG
            note("criteria via SPI int initializer, videoDynamicRange=\(dynamicRange)")
            return AVDisplayCriteria(refreshRate: rate, videoDynamicRange: dynamicRange)
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
            note("criteria fallback failed: CMVideoFormatDescriptionCreate err=\(status)")
            return nil
        }
        note("criteria via public formatDescription initializer (SPI unavailable)")
        return AVDisplayCriteria(refreshRate: rate, formatDescription: format)
    }

    /// Return the TV to its default display mode. Safe to call repeatedly.
    @MainActor
    static func reset(in window: UIWindow?) {
        guard let window = window ?? fallbackWindow,
              let manager = displayManager(of: window) else { return }
        if manager.preferredDisplayCriteria != nil {
            manager.preferredDisplayCriteria = nil
            note("display criteria cleared, back to default mode")
        }
    }

    /// The display manager, only where the runtime actually implements it.
    /// On the simulator this is a logged no-op instead of a crash.
    @MainActor
    private static func displayManager(of window: UIWindow) -> AVDisplayManager? {
#if targetEnvironment(simulator)
        note("display switch skipped: the simulator has no HDMI display modes")
        return nil
#else
        // The probe is load-bearing: avDisplayManager is an ObjC CATEGORY from
        // AVKit, and if AVKit is not loaded the access aborts with an
        // unrecognized selector. AVKit is now linked explicitly (project.yml),
        // so this should always pass; if a future build regresses the linkage,
        // this degrades to a logged no-op instead of a crash loop.
        guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
            note("display switch skipped: avDisplayManager category missing (AVKit not loaded?)")
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
