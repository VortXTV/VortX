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
/// HDR mode instead of being tone-mapped to SDR, and (opt-in) so SDR content is sent
/// at its own frame rate instead of the panel's default.
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

    /// Posted (once per process, per kind) when a display-mode request is refused because the user has the
    /// matching tvOS Match Content setting OFF, so the player chrome can surface an actionable hint instead
    /// of the request dying silently in the log. `userInfo["message"]` carries the display text.
    static let userHintNotification = Notification.Name("vortx.hdr.userHint")

    /// Match Frame Rate. When ON, an SDR file whose frame rate is known asks the Apple TV for an SDR display
    /// mode that CARRIES that rate, so a 24p film runs at a 24Hz-family mode instead of being pulled to the
    /// panel's default 60Hz (the 3:2 pulldown judder in pans). When OFF, an SDR file resets the display mode
    /// exactly as it always has.
    ///
    /// Declared OUTSIDE the `#if os(tvOS)` block on purpose: only tvOS renegotiates an HDMI mode, but the
    /// iOS/Mac Settings screens bind the same key so the preference exists identically on every app (and the
    /// account restores one key, not one per platform).
    static let matchFrameRateKey = "vortx.player.matchFrameRate"
    static let defaultMatchFrameRate = false

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

    /// The pending "no switch is coming" timer and a monotonically increasing epoch, both guarded by the
    /// shared `switchLock`. The timer exists because tvOS posts no mode-switch notifications when the panel
    /// is already in the target mode (see `request`); the epoch stops a superseded timer from settling a
    /// gate a newer request opened.
    private static var noSwitchTimeout: DispatchWorkItem?
    private static var switchEpoch: UInt64 = 0

    /// Window after the criteria are set within which a real switch's `AVDisplayManagerModeSwitchStart` is
    /// expected to post. It sits above the sub-second main-runloop + AVKit delivery latency of a genuine
    /// switch's Start, and below the +2.5s in-progress checkpoint in `request`, so a real switch trips Start
    /// and cancels the timer first; only a genuinely absent switch (panel already in the target mode) lets
    /// the timer fire and settle the gate. Caps the common-case (back-to-back Dolby Vision) master wait near
    /// this value instead of the 6s serveMaster fail-open.
    private static let noSwitchSettleSeconds: TimeInterval = 1.0

    /// How long the master gate is held PAST `AVDisplayManagerModeSwitchEnd` before it settles (#148). The
    /// panel switch has finished when End posts, but AVFoundation's internal pipeline-HDR state lags that
    /// notification by a variable margin (tens of ms observed: a working case latched the DV variant +94ms
    /// after End, a failing case latched the range-less lifeboat +65ms after End). Releasing the gate the
    /// instant End posts (zero dwell) let the master be parsed before the pipeline was provably HDR, so
    /// AVFoundation dropped the explicit-PQ DV variant and latched the lifeboat -> CoreMedia -12927 on
    /// /init-hdr.mp4. A short dwell past End lets the pipeline reach provably-HDR first; well under the 6s
    /// serveMaster fail-open so a wedged switch still yields a playable variant.
    private static let modeSwitchSettleDwellSeconds: TimeInterval = 0.3

    @MainActor
    private static func installModeSwitchObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: .AVDisplayManagerModeSwitchStart, object: nil, queue: .main) { _ in
            // A real HDMI renegotiation is underway: drop the no-switch timer and keep the gate closed until
            // ModeSwitchEnd, exactly as before. When the panel is already in the target mode no Start posts,
            // and the no-switch timer settles the gate instead.
            cancelNoSwitchTimeout()
            DiagnosticsLog.logSync("hdr", "display mode switch STARTED (system notification)")
        }
        center.addObserver(forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: .main) { _ in
            // The panel switch has ENDED, but AVFoundation's pipeline-HDR state lags this notification by a
            // variable margin, so releasing the master gate here with ZERO dwell let the master be parsed a
            // hair before the pipeline was provably HDR: AVFoundation dropped the explicit-PQ DV variant and
            // latched the range-less lifeboat -> -12927 on ~7/9 DV titles (#148). Hold the gate a short DWELL
            // past ModeSwitchEnd instead, reusing the SAME epoch/timer machinery as the no-switch settle so a
            // newer request() (or reset()) supersedes this pending settle by advancing the epoch.
            // beginNoSwitchWindow() cancels any lingering no-switch timer and advances the epoch exactly as
            // the old cancelNoSwitchTimeout() did; `switchSettled` stays false (set in request) until the
            // dwell fires, and the 6s serveMaster fail-open still bounds the total wait.
            let epoch = beginNoSwitchWindow()
            let dwellTimer = DispatchWorkItem { settleSwitchEndIfCurrent(epoch: epoch) }
            armNoSwitchTimer(dwellTimer)
            DispatchQueue.main.asyncAfter(deadline: .now() + modeSwitchSettleDwellSeconds, execute: dwellTimer)
            DiagnosticsLog.logSync("hdr", "display mode switch ENDED (system notification); settling master gate in \(modeSwitchSettleDwellSeconds)s")
        }
    }

    /// Cancel any pending no-switch timer and advance the epoch so a timer already dequeued cannot settle a
    /// gate a newer request opened. Returns the epoch the caller's fresh timer must carry. Non-isolated (like
    /// `setSwitchSettled`) so the main-queue notification observers can call it without actor friction.
    private static func beginNoSwitchWindow() -> UInt64 {
        switchLock.lock()
        noSwitchTimeout?.cancel()
        noSwitchTimeout = nil
        switchEpoch &+= 1
        let epoch = switchEpoch
        switchLock.unlock()
        return epoch
    }

    private static func armNoSwitchTimer(_ item: DispatchWorkItem) {
        switchLock.lock(); noSwitchTimeout = item; switchLock.unlock()
    }

    /// Cancel and forget any pending no-switch timer and advance the epoch. Used by ModeSwitchStart (a real
    /// switch is underway, so wait for ModeSwitchEnd instead) and by `reset` (teardown / SDR).
    private static func cancelNoSwitchTimeout() {
        switchLock.lock()
        noSwitchTimeout?.cancel()
        noSwitchTimeout = nil
        switchEpoch &+= 1
        switchLock.unlock()
    }

    /// The no-switch timer fired: settle the master gate only if no later request superseded this timer.
    private static func settleNoSwitchIfCurrent(epoch: UInt64) {
        switchLock.lock()
        let current = (epoch == switchEpoch)
        if current {
            switchSettled = true
            noSwitchTimeout = nil
        }
        switchLock.unlock()
        if current {
            note("display switch: no ModeSwitchStart within \(noSwitchSettleSeconds)s, panel already in target mode; master gate settled")
        }
    }

    /// The post-ModeSwitchEnd dwell timer fired (#148): settle the master gate only if no later request or
    /// reset superseded this timer (the same epoch guard as `settleNoSwitchIfCurrent`). Holding the gate a
    /// short dwell past ModeSwitchEnd lets AVFoundation's pipeline reach provably-HDR before it parses the HLS
    /// master, so it latches the DV variant instead of the range-less lifeboat that -12927s on /init-hdr.mp4.
    private static func settleSwitchEndIfCurrent(epoch: UInt64) {
        switchLock.lock()
        let current = (epoch == switchEpoch)
        if current {
            switchSettled = true
            noSwitchTimeout = nil
        }
        switchLock.unlock()
        if current {
            note("display switch settled \(modeSwitchSettleDwellSeconds)s after ModeSwitchEnd; master gate released")
        }
    }

    /// Pending and applied request memory, scoped to the AVDisplayManager that received it.
    ///
    /// Why this exists: assigning `preferredDisplayCriteria` makes tvOS renegotiate the HDMI link, and a
    /// renegotiation is a visible flick. Several paths can ask for the SAME mode during one start (the remux
    /// server's deferred request once DV signaling is published, and the readyToPlay re-assert once the real
    /// rate is known), so a start could renegotiate repeatedly for no change at all. Field reports of four to
    /// five flickers on a single Dolby Vision start are this.
    ///
    /// A request becomes applied only after the manager exposes non-nil preferred criteria. A failed assignment
    /// remains retryable, and a replacement manager always receives its own first request.
    @MainActor
    private static var displayRequestLedger = DVPlaybackPolicy.DisplayRequestLedger()
    @MainActor
    private static weak var nativeCriteriaManager: AVDisplayManager?
    @MainActor
    private static weak var nativeCriteriaSource: AVDisplayCriteria?

    /// Apply the exact criteria Apple derived from the native asset. Custom AVPlayer hosts are expected to
    /// load `AVAsset.preferredDisplayCriteria` and assign that object before attaching the item; constructing a
    /// replacement from guessed rate/range metadata defeats the API. Reapply only when the window's display
    /// manager changed or lost its stored criteria.
    @MainActor
    @discardableResult
    static func applyNativePreferredCriteria(_ criteria: AVDisplayCriteria, in window: UIWindow?) -> Bool {
        installModeSwitchObservers()
        guard let window = window ?? fallbackWindow else {
            note("native display criteria skipped: no window")
            return false
        }
        guard let manager = displayManager(of: window) else { return false }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            note("native display criteria skipped: Match Dynamic Range is OFF (tvOS Settings > Video and Audio > Match Content)")
            if !matchRangeHintPosted {
                matchRangeHintPosted = true
                NotificationCenter.default.post(
                    name: userHintNotification, object: nil,
                    userInfo: ["message": "Turn on Settings > Video and Audio > Match Content > Match Dynamic Range for Dolby Vision / HDR output"])
            }
            return false
        }
        if nativeCriteriaManager === manager,
           nativeCriteriaSource === criteria,
           manager.preferredDisplayCriteria != nil {
            note("native display criteria skipped: same loaded criteria already applied to this manager")
            return true
        }
        let previousCriteria = manager.preferredDisplayCriteria
        manager.preferredDisplayCriteria = criteria
        let readbackCriteria = manager.preferredDisplayCriteria
        let applied = readbackCriteria != nil && readbackCriteria !== previousCriteria
        guard applied else {
            note("native display criteria failed: display manager rejected the asset-owned criteria")
            return false
        }
        nativeCriteriaManager = manager
        nativeCriteriaSource = criteria
        setSwitchSettled(false)
        let epoch = beginNoSwitchWindow()
        let noSwitchTimer = DispatchWorkItem { settleNoSwitchIfCurrent(epoch: epoch) }
        armNoSwitchTimer(noSwitchTimer)
        DispatchQueue.main.asyncAfter(deadline: .now() + noSwitchSettleSeconds, execute: noSwitchTimer)
        note("native asset-owned display criteria applied before AVPlayerItem attach; switchInProgress=\(manager.isDisplayModeSwitchInProgress)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            note("native display criteria +2.5s: switchInProgress=\(manager.isDisplayModeSwitchInProgress) criteriaStillSet=\(manager.preferredDisplayCriteria != nil)")
        }
        return true
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
        // SDR: historically an unconditional reset (clear the criteria, let the panel sit in its default
        // mode). With Match Frame Rate ON and a KNOWN frame rate we instead fall through to the criteria
        // path below, which builds an SDR criteria carrying `fps` so 24p films stop juddering. Toggle OFF,
        // or an unknown/absent frame rate (nothing to match), keeps the historical reset unchanged: there is
        // no rate to ask for, and defaulting to 60 like the HDR path does would be a made-up request.
        let isFrameRateMatch = (range == .sdr)
        if isFrameRateMatch, !(matchFrameRateEnabled && fps > 0) {
            reset(in: window)
            return
        }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            // Same silent-refusal guardrail for both kinds of request, but the actionable setting differs, so
            // the hint names the one the user actually has to turn on. tvOS exposes ONE combined flag here
            // (there is no per-axis API), so a frame-rate request can also be refused while only Match Frame
            // Rate is off and Match Dynamic Range is on; naming Match Frame Rate is still the right advice
            // for an SDR request. Each kind gets its OWN one-shot flag so an SDR hint cannot swallow the
            // Dolby Vision / HDR hint later in the same process. Fail-soft: message-only, playback untouched.
            if isFrameRateMatch {
                note("frame-rate match skipped: Match Content is OFF (tvOS Settings > Video and Audio > Match Content)")
                if !matchFrameRateHintPosted {
                    matchFrameRateHintPosted = true
                    NotificationCenter.default.post(
                        name: userHintNotification, object: nil,
                        userInfo: ["message": "Turn on Settings > Video and Audio > Match Content > Match Frame Rate to play this title at its own frame rate"])
                }
                reset(in: window)   // refused: land exactly where the toggle-off path lands
                return
            }
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
        // Never manufacture 60Hz for an unknown track. The remux master carries the classifier's authoritative
        // session rate, and AVPlayerEngine preserves that value when its local HLS asset exposes no track rate.
        guard let resolvedRate = DVPlaybackPolicy.frameRate(classified: fps, assetTrack: 0) else {
            note("display switch deferred: frame rate is unknown")
            return
        }
        let rate = Float(resolvedRate)
        guard let criteria = makeCriteria(range: range, rate: rate, width: width, height: height) else {
            note("display switch failed: could not build criteria")
            return
        }
        let encoded = (criteria.value(forKey: "videoDynamicRange") as? Int) ?? -999
        // Skip only a pending or successfully applied request on this exact manager. Criteria-build failures and
        // manager replacements remain eligible.
        let thisRequest = DVPlaybackPolicy.DisplayRequest(
            range: range.rawValue, rate: rate, width: width, height: height)
        if !displayRequestLedger.begin(thisRequest, manager: manager) {
            note("display switch skipped: already asking for \(range.rawValue) @\(rate)fps \(width)x\(height)")
            return
        }
        // AVDisplayManager declares this property `copy` in the tvOS SDK. Capture its prior stored object so a
        // rejected setter that leaves an old non-nil criterion in place cannot masquerade as this request's
        // success; an accepted copy has a distinct manager readback even when it is not identical to `criteria`.
        let previousCriteria = manager.preferredDisplayCriteria
        manager.preferredDisplayCriteria = criteria
        let readbackCriteria = manager.preferredDisplayCriteria
        let applied = readbackCriteria != nil && readbackCriteria !== previousCriteria
        displayRequestLedger.complete(thisRequest, manager: manager, applied: applied)
        guard applied else {
            note("display switch failed: display manager rejected preferred criteria")
            return
        }
        // Close the master-parse race at its earliest point: a switch is now pending but the ModeSwitchStart
        // notification has not necessarily fired yet, so mark unsettled here rather than waiting on Start. The
        // early returns above (no window, SDR reset, Match Dynamic Range OFF, criteria build failure) never
        // reach this line, so the gate stays a no-op whenever no switch is actually requested.
        setSwitchSettled(false)
        // tvOS posts ModeSwitchStart/End only when it actually renegotiates the HDMI link. When the panel is
        // already in the target mode (a second Dolby Vision play in a row, or a TV already in Dolby Vision
        // mode) it renegotiates nothing and posts neither, so the flag set false just above would never
        // return to true and every later master fetch would eat the full serveMaster fail-open. Arm a short
        // timer: if Start has not posted within the window no switch is needed and the gate settles; if Start
        // does post it cancels this timer and the ModeSwitchEnd path settles the gate as before, so the
        // pre-Start race stays closed either way.
        let epoch = beginNoSwitchWindow()
        let noSwitchTimer = DispatchWorkItem { settleNoSwitchIfCurrent(epoch: epoch) }
        armNoSwitchTimer(noSwitchTimer)
        DispatchQueue.main.asyncAfter(deadline: .now() + noSwitchSettleSeconds, execute: noSwitchTimer)
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
        // Exhaustive on purpose. This used to be `default: 4` with a "sdr never reaches here" note, which the
        // Match Frame Rate path makes false: an SDR request landing on `default` would ask the panel for
        // HDR10 and light its HDR mode over SDR pixels. Listing every case makes the compiler, not a comment,
        // enforce that a new ContentDynamicRange gets a deliberate integer.
        let dynamicRange: Int32
        switch range {
        case .sdr:         dynamicRange = 1
        case .hlg:         dynamicRange = 2
        case .hdr10:       dynamicRange = 4   // PQ
        case .dolbyVision: dynamicRange = 5
        }
        note("criteria via SPI int initializer, videoDynamicRange=\(dynamicRange)")
        return AVDisplayCriteria(refreshRate: rate, videoDynamicRange: dynamicRange)
    }

    /// A synthetic CMVideoFormatDescription describing the content for the public criteria initializer.
    /// Dolby Vision uses the 'dvh1' codec type (this is what flips videoDynamicRange to 5, the panel's DV
    /// mode); HDR10 is HEVC+PQ (=4); HLG is HEVC+HLG (=2). Those three are BT.2020, matching real DV/HDR
    /// bitstreams. SDR (=1, the Match Frame Rate path) is BT.709 end to end instead: the criteria then says
    /// "keep the panel in SDR, just take this refresh rate", which is the whole point of the frame-rate
    /// request. Describing SDR content with the BT.2020/PQ extensions would ask for an HDR mode.
    private static func makeFormatDescription(range: ContentDynamicRange, width: Int, height: Int) -> CMFormatDescription? {
        let extensions: [CFString: Any]
        if range == .sdr {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            ]
        } else {
            let transfer: CFString = range == .hlg
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: transfer,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        }
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

    /// One user-visible Match-Frame-Rate hint per process, kept separate from `matchRangeHintPosted` so the
    /// two kinds of refusal cannot suppress each other.
    @MainActor
    private static var matchFrameRateHintPosted = false

    /// The user's Match Frame Rate preference. Read straight off UserDefaults on each request (rather than
    /// cached) so a change applies to the next title without an app restart, exactly like the tone-map mode
    /// the mpv lane reads. `object(forKey:) as? Bool` distinguishes "never set" from "set to false", so the
    /// default lives in one place instead of relying on `bool(forKey:)` returning false for an absent key.
    private static var matchFrameRateEnabled: Bool {
        UserDefaults.standard.object(forKey: matchFrameRateKey) as? Bool ?? defaultMatchFrameRate
    }

    /// Return the TV to its default display mode. Safe to call repeatedly.
    @MainActor
    static func reset(in window: UIWindow?) {
        // Teardown or an SDR request must never leave the master gate closed for the next playback. Cancel any
        // pending no-switch timer and settle the flag up front, ahead of the window/manager guards below that
        // can return early (the player view is often already detached from its window during teardown).
        cancelNoSwitchTimeout()
        setSwitchSettled(true)
        // Clear request memory even when teardown has already detached the window. The ledger is manager-owned,
        // so a replacement manager can never inherit a stale successful or pending request.
        displayRequestLedger.reset()
        nativeCriteriaManager = nil
        nativeCriteriaSource = nil
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
