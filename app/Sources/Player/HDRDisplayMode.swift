import AVFoundation
import AVKit
import CoreMedia
#if canImport(UIKit)
import UIKit   // all UIKit/UIWindow usage below is inside #if os(tvOS); macOS just needs the import gated
#endif
import os

/// The dynamic range the playing file carries, reduced to the modes the Apple TV display pipeline can be
/// asked to match. When content plays through the libmpv/PQ lane (which tone-maps Dolby Vision) it requests
/// the `hdr10` mode; when true Dolby Vision plays through the AVPlayer remux lane, it requests `dolbyVision`
/// so the TV lights its Dolby Vision mode instead of HDR10.
enum ContentDynamicRange: String {
    case sdr
    case hdr10
    case hlg
    case dolbyVision
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

    /// Posted (once per process) when a display-mode request is refused because the user has
    /// Match Dynamic Range OFF, so the player chrome can surface an actionable hint instead of the
    /// request dying silently in the log. `userInfo["message"]` carries the display text.
    static let userHintNotification = Notification.Name("vortx.hdr.userHint")

    private static func note(_ message: String) {
        log.log("\(message, privacy: .public)")
        DiagnosticsLog.log("hdr", message)
    }

    /// Serialized access to the switch-settle flag: written on the main queue by the mode-switch observers,
    /// read on the HLS server's background serve queue. Declared OUTSIDE `#if os(tvOS)` because
    /// VortXRemuxHLSServer compiles for iOS and macOS too and reads `isSwitchSettled` there; those platforms
    /// never renegotiate an HDMI display mode, so the flag simply stays true for them.
    private static let switchLock = NSLock()
    private static var switchSettled = true

    /// False from the instant a Dolby Vision / HDR display-mode switch is requested until the HDMI
    /// renegotiation ends. The HLS master answer holds until this reads true (bounded, fail-open) so
    /// AVFoundation parses the master AFTER the pipeline is provably HDR, not mid-switch where it would drop
    /// the explicit-PQ DV variant for the whole session. Always true on iOS/macOS and whenever no switch was
    /// requested (Match Dynamic Range OFF, or an SDR request that resets instead of switching).
    static var isSwitchSettled: Bool {
        switchLock.lock(); defer { switchLock.unlock() }
        return switchSettled
    }

    private static func setSwitchSettled(_ value: Bool) {
        switchLock.lock(); switchSettled = value; switchLock.unlock()
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
            setSwitchSettled(true)   // release the HLS master gate: the pipeline is now provably HDR
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
            // Guardrail: this silent refusal is the #1 real-world reason "DV/HDR never engages" (Match
            // Dynamic Range is OFF by default on every Apple TV). Surface ONE user-visible hint per process
            // so the user learns the exact setting; fail-soft, message-only, playback is untouched.
            if !matchRangeHintPosted {
                matchRangeHintPosted = true
                NotificationCenter.default.post(
                    name: userHintNotification, object: nil,
                    userInfo: ["message": "Turn on Settings > Video and Audio > Match Content > Match Dynamic Range for Dolby Vision / HDR output"])
            }
            return
        }
        let rate = Float(fps > 0 ? fps : 60)
        guard let criteria = makeCriteria(range: range, rate: rate, width: width, height: height) else {
            note("display switch failed: could not build criteria")
            return
        }
        let encoded = (criteria.value(forKey: "videoDynamicRange") as? Int) ?? -999
        manager.preferredDisplayCriteria = criteria
        // Close the master-parse race at its earliest point: a switch is now pending but the ModeSwitchStart
        // notification has not necessarily fired yet, so mark unsettled here rather than waiting on Start. The
        // early returns above (no window, SDR reset, Match Dynamic Range OFF, criteria build failure) never
        // reach this line, so the gate stays a no-op whenever no switch is actually requested.
        setSwitchSettled(false)
        note("display switch requested: \(range.rawValue) @\(rate)fps \(width)x\(height) criteriaRange=\(encoded) switchInProgress=\(manager.isDisplayModeSwitchInProgress)")
        // The HDMI renegotiation takes a beat; record whether tvOS actually started one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            note("display switch +2.5s: switchInProgress=\(manager.isDisplayModeSwitchInProgress) criteriaStillSet=\(manager.preferredDisplayCriteria != nil)")
        }
    }

    /// Build the criteria. The PUBLIC `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17+) is
    /// preferred: built with a `kCMVideoCodecType_DolbyVisionHEVC` ('dvh1') format description it is the
    /// documented, future-proof way to request Dolby Vision mode. Empirical KVC readback of criteria built
    /// this way on tvOS 26.5 gives videoDynamicRange SDR=1, HLG=2, HDR10=4, DV=5, which proves the old
    /// SPI integer table this code shipped (2=HDR10, 3=HLG, 4=DV, from tvOS 11-13-era Kodi/MrMC console
    /// logs) is STALE on current tvOS: sending 4 today requests HDR10, so the previous "DV" request was
    /// literally asking the panel for HDR10 (and "HDR10"=2 was asking for HLG). The SPI int initializer is
    /// retained only as a fallback for pre-tvOS-17 / a failed format-description build, using the
    /// empirically corrected integers.
    @MainActor
    private static func makeCriteria(range: ContentDynamicRange, rate: Float, width: Int, height: Int) -> AVDisplayCriteria? {
        if #available(tvOS 17.0, *) {
            if let format = makeFormatDescription(range: range, width: width, height: height) {
                note("criteria via public formatDescription initializer, codec=\(range == .dolbyVision ? "dvh1" : "hvc1") range=\(range.rawValue)")
                return AVDisplayCriteria(refreshRate: rate, formatDescription: format)
            }
            note("public formatDescription build failed; falling back to SPI int initializer")
        }
        // SPI fallback (pre-tvOS-17, or the format-description build failed). Empirically corrected
        // videoDynamicRange integers for CURRENT tvOS (KVC readback of public-built criteria, tvOS 26.5):
        // 1 = SDR, 2 = HLG, 4 = HDR10/PQ, 5 = Dolby Vision (dvh1). The old 2/3/4 table requested the
        // wrong modes on modern tvOS. The +2.5s switch-in-progress log remains the on-device confirmation.
        let sel = NSSelectorFromString("initWithRefreshRate:videoDynamicRange:")
        guard AVDisplayCriteria.instancesRespond(to: sel) else {
            note("criteria failed: SPI initializer unavailable and public path failed")
            return nil
        }
        let dynamicRange: Int32
        switch range {
        case .hlg:         dynamicRange = 2
        case .dolbyVision: dynamicRange = 5
        default:           dynamicRange = 4   // hdr10 / PQ (sdr never reaches here, it resets above)
        }
        note("criteria via SPI int initializer, videoDynamicRange=\(dynamicRange)")
        return AVDisplayCriteria(refreshRate: rate, videoDynamicRange: dynamicRange)
    }

    /// A synthetic CMVideoFormatDescription describing the content for the public criteria initializer.
    /// Dolby Vision uses the 'dvh1' codec type (this is what flips videoDynamicRange to 5, the panel's DV
    /// mode); HDR10 is HEVC+PQ (=4); HLG is HEVC+HLG (=2). All BT.2020, matching real DV/HDR bitstreams.
    private static func makeFormatDescription(range: ContentDynamicRange, width: Int, height: Int) -> CMFormatDescription? {
        let transfer: CFString = range == .hlg
            ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        let codec: CMVideoCodecType = range == .dolbyVision
            ? kCMVideoCodecType_DolbyVisionHEVC   // 'dvh1', the DV sample-entry codec type
            : kCMVideoCodecType_HEVC
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: Int32(max(width, 1)),
            height: Int32(max(height, 1)),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            note("CMVideoFormatDescriptionCreate failed err=\(status) range=\(range.rawValue)")
            return nil
        }
        return format
    }

    /// One user-visible Match-Dynamic-Range hint per process (see the guard in `request`).
    @MainActor
    private static var matchRangeHintPosted = false

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
