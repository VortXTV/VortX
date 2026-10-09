#if os(iOS)
import AVKit
import CoreMedia
import SwiftUI

/// Independent of the mpv handle: callbacks and disposal remain safe after quit.
private final class MPVNativeFrameLease: @unchecked Sendable {
    let session: UnsafeMutableRawPointer
    let frame: VortXMPVNativeFrame
    init(session: UnsafeMutableRawPointer, frame: VortXMPVNativeFrame) {
        self.session = session
        self.frame = frame
        VortXMPVNativeRetain(session)
    }
    deinit {
        VortXMPVNativeReleaseFrame(session, frame.lease)
        VortXMPVNativeRelease(session)
    }
}

/// One replaceable pending packet and one scheduled delivery, not one Task per
/// decoded frame. Native limits all outstanding leases (including delivery) to two.
private final class MPVNativeFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: MPVNativeFrameLease?
    private var scheduled = false
    private var closed = false
    private let deliver: @MainActor (MPVNativeFrameLease) -> Void

    init(deliver: @escaping @MainActor (MPVNativeFrameLease) -> Void) {
        self.deliver = deliver
    }

    func offer(_ packet: MPVNativeFrameLease) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let discarded = pending
        pending = packet
        let needsDelivery = !scheduled
        scheduled = true
        lock.unlock()
        withExtendedLifetime(discarded) {} // release native resources outside lock
        if needsDelivery {
            DispatchQueue.main.async { [self] in
                if let packet = take() { deliver(packet) }
            }
        }
    }

    private func take() -> MPVNativeFrameLease? {
        lock.lock(); defer { lock.unlock() }
        let packet = pending
        pending = nil
        scheduled = false
        return closed ? nil : packet
    }

    func close() {
        lock.lock()
        closed = true
        let discarded = pending
        pending = nil
        lock.unlock()
        withExtendedLifetime(discarded) {}
    }
}

final class MPVNativeFrameSubscription: @unchecked Sendable {
    let session: UnsafeMutableRawPointer
    let cookie: UInt64
    let owner: PlayerLoadToken
    private let lock = NSLock()
    private var closed = false
    init(session: UnsafeMutableRawPointer, cookie: UInt64, owner: PlayerLoadToken) {
        self.session = session; self.cookie = cookie; self.owner = owner
    }
    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }
    func close() {
        lock.lock()
        let shouldDetach = !closed
        closed = true
        lock.unlock()
        if shouldDetach { VortXMPVNativeDetach(session, cookie) }
    }
    deinit { close(); VortXMPVNativeRelease(session) }
}

/// iPhone/iPad sample-buffer PiP for the SAME MPV decoder and playback owner.
/// The existing vendor lacks the ABI: the UI explains this and never substitutes AVPlayer.
@MainActor
final class MPVSampleBufferPiPController: NSObject, ObservableObject,
    AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    enum Phase { case idle, preparing, retiring, starting, active, stopping, restoring }
    enum Disappearance { case presentation, screen }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var reason: String?
    let displayLayer = AVSampleBufferDisplayLayer()
    private weak var owner: MPVMetalViewController?
    private var retainedOwner: MPVMetalViewController?
    private var subscription: MPVNativeFrameSubscription?
    private var mailbox: MPVNativeFrameMailbox?
    private var controller: AVPictureInPictureController?
    private var possibility: NSKeyValueObservation?
    private var timebase: CMTimebase?
    private var lastEpoch: (UInt64, UInt64)?
    private var generation: UInt64 = 0
    private var numericOwner: UInt64 = 0
    private var preparationDeadline: DispatchWorkItem?
    private var statusTimer: Timer?
    private var restoration: ((Bool) -> Void)?
    private var skipCompletion: (() -> Void)?
    private var skipTicket: MPVResumeSeekTicket<PlayerLoadToken>?
    // Only while a skip is pending: an epoch witness using ONE of the native
    // two permitted leases. New consumption replaces it; every exit releases it.
    private var skipDisplayedFrame: MPVNativeFrameLease?
    private var skipPriorEpoch: (UInt64, UInt64)?
    private var consumedFrameSerial: UInt64 = 0
    private var skipFrameSerialFloor: UInt64 = 0
    private var skipDeadline: DispatchWorkItem?
    private var inlineDetached = false
    private var needsForegroundRestore = false
    private var restoreInFlight = false
    private var restoreAttempt: UInt64 = 0
    private var restoreAcknowledged = false
    private var restorePresented = false
    private var restoreDeadline: DispatchWorkItem?
    private var blockedSeekEpoch: (UInt64, UInt64)?
    private var disappearanceCleanup: [Disappearance: () -> Void] = [:]

    init(owner: MPVMetalViewController) {
        self.owner = owner
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.isHidden = true
        if !VortXMPVNativeFramesAvailable() {
            reason = "Picture in Picture needs the native-frame player update. This build does not include it."
        }
    }

    var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var active: Bool { phase == .active }
    var transitioning: Bool { phase != .idle && phase != .active }
    private var ownsCurrentSource: Bool {
        guard let owner, let subscription, !subscription.isClosed,
              owner.activeLoadToken == subscription.owner else { return false }
        return true
    }
    var retainsPlayback: Bool {
        guard ownsCurrentSource else { return false }
        return phase == .starting || phase == .active || phase == .stopping || phase == .restoring
    }

    func attachInline() {
        guard let owner, owner.isViewLoaded else { return }
        inlineDetached = false
        if displayLayer.superlayer !== owner.view.layer { owner.view.layer.addSublayer(displayLayer) }
        displayLayer.frame = owner.view.bounds
    }

    func detachInline() -> Bool {
        guard retainsPlayback else { return false }
        inlineDetached = true
        return true
    }

    func retainDisappearance(_ kind: Disappearance, finish: @escaping () -> Void) -> Bool {
        guard retainsPlayback else { return false }
        if disappearanceCleanup[kind] == nil { disappearanceCleanup[kind] = finish }
        return true
    }

    func resumeDisappearance(_ kind: Disappearance) -> Bool {
        guard retainsPlayback else { return false }
        return disappearanceCleanup.removeValue(forKey: kind) != nil
    }

    /// Called only from the custom PiP button. Preparation alone cannot start PiP.
    func start() {
        guard phase == .idle, supported, let owner,
              UIApplication.shared.applicationState == .active,
              !owner.startMuted, owner.probeChannel.description == "player" else { return }
        guard VortXMPVNativeFramesAvailable() else {
            reason = "Picture in Picture needs the native-frame player update. This build does not include it."
            return
        }
        guard let token = owner.pipLoadedOwner else { reason = "Wait for this video to load."; return }
        guard owner.preparePiPCaptureAdmission() else {
            reason = "A video thumbnail is still being processed. Try Picture in Picture again."
            return
        }
        generation &+= 1
        numericOwner &+= 1
        let request = generation
        phase = .preparing
        reason = nil
        attachInline()
        let receiver = MPVNativeFrameMailbox { [weak self] packet in self?.consume(packet, request: request) }
        mailbox = receiver
        let context = Unmanaged.passRetained(receiver).toOpaque()
        subscription = owner.subscribePiP(owner: token, numericOwner: numericOwner, context: context,
            callback: { context, session, frame in
                guard let context, let session, let frame else { return }
                let mailbox = Unmanaged<MPVNativeFrameMailbox>.fromOpaque(context).takeUnretainedValue()
                mailbox.offer(MPVNativeFrameLease(session: session, frame: frame.pointee))
            }, destroy: { context in
                if let context { Unmanaged<MPVNativeFrameMailbox>.fromOpaque(context).release() }
            })
        guard subscription != nil else {
            // Failed subscribe never adopts the context.
            Unmanaged<MPVNativeFrameMailbox>.fromOpaque(context).release()
            finish(reason: "The current video cannot provide native frames.")
            return
        }
        retainedOwner = owner
        var clock: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr,
              let clock else { finish(reason: "The video clock could not be prepared."); return }
        timebase = clock
        displayLayer.controlTimebase = clock
        controller = AVPictureInPictureController(contentSource: .init(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        possibility = controller?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startIfReady(request: request) }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request, self.phase == .preparing else { return }
            self.finish(reason: self.nativeReason() ?? "Picture in Picture is not possible for this video right now.")
        }
        preparationDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }
    }

    private func consume(_ packet: MPVNativeFrameLease, request: UInt64) {
        let frame = packet.frame
        guard request == generation, let owner, let subscription, !subscription.isClosed,
              owner.activeLoadToken == subscription.owner, frame.owner == numericOwner,
              frame.subscription == subscription.cookie, frame.abi_version == 1,
              frame.reason == 0, VortXMPVNativeIsCurrent(packet.session, frame.lease),
              let pixels = frame.pixel_buffer, let timebase,
              frame.media_pts.isFinite, frame.media_pts >= 0,
              frame.media_rate.isFinite, frame.media_rate > 0,
              frame.host_observed_ns <= UInt64(Int64.max),
              frame.host_deadline_ns <= UInt64(Int64.max) else { return }
        let epoch = (frame.file_epoch, frame.timeline_epoch)
        if let blockedSeekEpoch, blockedSeekEpoch.0 == epoch.0 && blockedSeekEpoch.1 == epoch.1 { return }
        if lastEpoch?.0 != epoch.0 || lastEpoch?.1 != epoch.1 {
            displayLayer.flushAndRemoveImage()
            lastEpoch = epoch
        }
        guard displayLayer.status != .failed else { finish(reason: "The native frame display failed."); return }
        guard displayLayer.isReadyForMoreMediaData else { return }
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixels).takeUnretainedValue()
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr, let format else { return }
        let pts = CMTime(seconds: frame.media_pts, preferredTimescale: 1_000_000)
        guard pts.isNumeric else { return }
        var timing = CMSampleTimingInfo(
            duration: frame.media_duration > 0 ? CMTime(seconds: frame.media_duration, preferredTimescale: 1_000_000) : .invalid,
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        // mpv timer-darwin uses mach_absolute_time converted to nanoseconds, the
        // SAME host clock as CMClockGetHostTimeClock. Do not anchor at callback arrival.
        let paused = frame.paused || owner.getFlag(MPVProperty.pause) || owner.getFlag(MPVProperty.pausedForCache)
        let host = paused ? frame.host_observed_ns : frame.host_deadline_ns
        guard host > 0 else { return }
        guard CMTimebaseSetRateAndAnchorTime(timebase, rate: paused ? 0 : frame.media_rate,
            anchorTime: pts, immediateSourceTime: CMTime(value: Int64(host), timescale: 1_000_000_000)) == noErr else { return }
        displayLayer.enqueue(sample)
        consumedFrameSerial &+= 1
        if skipTicket != nil { skipDisplayedFrame = packet }
        displayLayer.isHidden = false
        controller?.invalidatePlaybackState()
        startIfReady(request: request)
    }

    private func startIfReady(request: UInt64) {
        guard request == generation, phase == .preparing, lastEpoch != nil,
              UIApplication.shared.applicationState == .active,
              controller?.isPictureInPicturePossible == true,
              let owner, let subscription, owner.activeLoadToken == subscription.owner else { return }
        phase = .retiring
        preparationDeadline?.cancel(); preparationDeadline = nil
        owner.setPiPHeadless(subscription, headless: true) { [weak self] result in
            guard let self, self.generation == request, self.subscription === subscription,
                  !subscription.isClosed, self.owner?.activeLoadToken == subscription.owner else { return }
            guard result == 0 else { self.finish(reason: self.nativeReason() ?? "The renderer is busy. Try again."); return }
            self.needsForegroundRestore = true
            guard UIApplication.shared.applicationState == .active,
                  self.controller?.isPictureInPicturePossible == true else {
                self.finish(reason: "Picture in Picture was interrupted before it started.")
                return
            }
            self.phase = .starting
            self.controller?.startPictureInPicture()
        }
    }

    func stop() {
        guard phase != .idle else { return }
        if controller?.isPictureInPictureActive == true || phase == .starting {
            phase = .stopping
            controller?.stopPictureInPicture()
        } else { finish(reason: nil) }
    }

    func retireForSourceReplacement() -> Bool {
        guard let owner else { return true }
        guard phase != .idle, let subscription else {
            guard !owner.piPHasRetiredGPU else {
                reason = "This retired Picture in Picture owner cannot accept another source. Close and reopen the player."
                return false
            }
            return true
        }
        guard UIApplication.shared.applicationState == .active else {
            reason = "Return to VortX before changing this Picture in Picture source."
            return false
        }
        guard !inlineDetached, disappearanceCleanup.isEmpty else {
            // invalidate() consumes these terminal screen closures, including
            // old load provenance. Do not run them before a new load is accepted.
            reason = "Return to this video's player before changing the Picture in Picture source."
            return false
        }
        // Drains any in-flight retirement first, while this subscription still
        // owns the native file. Never request a new VO or change the pause flag.
        guard owner.restorePiPBeforeReplacement(subscription) else {
            reason = "The inline renderer could not be restored. Close this video before changing source."
            return false
        }
        invalidate()
        return true
    }

    var currentFrameEpoch: (UInt64, UInt64)? { lastEpoch }

    func seekAccepted(previousEpoch: (UInt64, UInt64)?) {
        guard ownsCurrentSource else { return }
        // The requested timestamp is never a displayed clock. Freeze/flush the
        // old queue until native RESET stamps a different achieved frame epoch.
        blockedSeekEpoch = previousEpoch
        displayLayer.flushAndRemoveImage()
        if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
    }

    /// Explicit media retirement is terminal, including a late native acknowledgement.
    func invalidate() {
        generation &+= 1
        completeSkip()
        completeRestoration(false)
        preparationDeadline?.cancel(); preparationDeadline = nil
        statusTimer?.invalidate(); statusTimer = nil
        restoreDeadline?.cancel(); restoreDeadline = nil
        owner?.metalLayer.cancelPiPPresentation()
        mailbox?.close(); mailbox = nil
        subscription?.close(); subscription = nil
        possibility = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture(); controller = nil
        displayLayer.flushAndRemoveImage()
        displayLayer.isHidden = true
        timebase = nil; lastEpoch = nil
        restoreInFlight = false
        restoreAttempt &+= 1
        restoreAcknowledged = false; restorePresented = false
        blockedSeekEpoch = nil
        needsForegroundRestore = false
        retainedOwner = nil
        owner?.releasePiPCaptureAdmission()
        if let owner, let coordinator = owner.playDelegate as? MPVMetalPlayerView.Coordinator,
           coordinator.pictureInPictureOwner === owner {
            coordinator.pictureInPictureOwner = nil
        }
        phase = .idle
        // Consume BEFORE invoking: screen cleanup invalidates the load again.
        // A same-owner remount already took its lease, so it is not ended here.
        let cleanup = disappearanceCleanup
        disappearanceCleanup.removeAll()
        cleanup.values.forEach { $0() }
    }

    func willResignActive() {
        guard phase != .idle, let owner else { return }
        // Synchronous event-queue barrier: no pending retirement or recreation
        // can cross the UIKit lifecycle return. No callback synchronously needs main.
        if phase == .restoring {
            restoreAttempt &+= 1
            restoreInFlight = false
            restoreDeadline?.cancel(); restoreDeadline = nil
            owner.metalLayer.cancelPiPPresentation()
        }
        guard owner.closePiPForegroundAuthority(subscription: subscription, preserveVideo: retainsPlayback) else {
            reason = "The renderer could not safely enter the background. Reopen this video."
            return
        }
        if phase == .preparing || phase == .retiring { finish(reason: "Picture in Picture start was interrupted.") }
    }

    func becameActive() {
        guard let owner else { return }
        owner.openPiPForegroundAuthority()
        if phase == .idle { owner.releasePiPCaptureAdmission() }
        if needsForegroundRestore && phase != .active && phase != .starting { finish(reason: reason) }
    }

    private func finish(reason: String?) {
        self.reason = reason
        completeSkip()
        preparationDeadline?.cancel(); preparationDeadline = nil
        statusTimer?.invalidate(); statusTimer = nil
        guard let owner, let subscription, !subscription.isClosed,
              owner.activeLoadToken == subscription.owner else { invalidate(); return }
        if owner.piPHasRetiredGPU {
            needsForegroundRestore = true
            guard UIApplication.shared.applicationState == .active else {
                phase = .restoring
                if !PlaybackSettings.keepPlayingInBackground { owner.pause() }
                return
            }
            phase = .restoring
            guard !restoreInFlight else { return }
            restoreInFlight = true
            restoreAttempt &+= 1
            let attempt = restoreAttempt
            let request = generation
            restoreAcknowledged = false; restorePresented = false
            owner.metalLayer.requestPiPPresentation { [weak self] presented in
                DispatchQueue.main.async {
                    guard let self, self.generation == request, self.restoreAttempt == attempt,
                          self.restoreInFlight, presented else { return }
                    self.restorePresented = true
                    self.completeInlineRestoreIfReady(request: request)
                }
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == request, self.restoreAttempt == attempt, self.restoreInFlight else { return }
                self.endInlineRestore(succeeded: false)
            }
            restoreDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
            owner.openPiPForegroundAuthority()
            owner.setPiPHeadless(subscription, headless: false) { [weak self] result in
                guard let self, self.generation == request, self.restoreAttempt == attempt, self.restoreInFlight else { return }
                guard self.ownsCurrentSource, self.subscription === subscription else { self.invalidate(); return }
                guard result == 0 else { self.endInlineRestore(succeeded: false); return }
                self.restoreAcknowledged = true
                self.completeInlineRestoreIfReady(request: request)
            }
        } else {
            completeRestoration(!inlineDetached && owner.viewIfLoaded?.window != nil)
            let stopDetached = inlineDetached
            invalidate()
            if stopDetached { owner.stop() }
        }
    }

    private func completeInlineRestoreIfReady(request: UInt64) {
        guard generation == request, ownsCurrentSource, restoreInFlight, restoreAcknowledged, restorePresented,
              UIApplication.shared.applicationState == .active else { return }
        endInlineRestore(succeeded: true)
    }

    private func endInlineRestore(succeeded: Bool) {
        guard let owner else { invalidate(); return }
        completeRestoration(succeeded && ownsCurrentSource && !inlineDetached && owner.viewIfLoaded?.window != nil)
        let stopDetached = inlineDetached
        if succeeded {
            needsForegroundRestore = false
            invalidate()
        } else {
            // Preserve the ONLY native recovery authority while the GPU can
            // still be retired. A new load must restore this subscription first.
            restoreAttempt &+= 1
            restoreInFlight = false
            needsForegroundRestore = true
            restoreDeadline?.cancel(); restoreDeadline = nil
            owner.metalLayer.cancelPiPPresentation()
            controller?.delegate = nil
            controller?.stopPictureInPicture(); controller = nil
            possibility = nil
            phase = .restoring
            reason = "The inline renderer did not return a presented frame. Close this video or retry the source in VortX."
        }
        if stopDetached { owner.stop() }
    }

    private func nativeReason() -> String? {
        guard let subscription else { return nil }
        switch VortXMPVNativeReason(subscription.session) {
        case 0: return nil
        case 1: return "Waiting for a native video frame."
        case 2, 10: return "This playback owner has ended."
        case 3: return "Picture in Picture currently requires VideoToolbox hardware frames."
        case 4: return "Dolby Vision Picture in Picture is not supported by this native-frame implementation yet."
        case 5: return "Picture in Picture cannot preserve the active video filters or colour transform."
        case 6: return "Picture in Picture cannot preserve the selected captions yet."
        case 7: return "This video's colour metadata is not supported for Picture in Picture yet."
        case 8: return "This video's timing mode is not supported for Picture in Picture yet."
        default: return "The renderer is busy. Try Picture in Picture again."
        }
    }

    private func refreshStatus() {
        guard let owner, let subscription, !subscription.isClosed,
              owner.activeLoadToken == subscription.owner else { invalidate(); return }
        if phase == .active, let failure = nativeReason() { stop(); reason = failure }
        if owner.getFlag(MPVProperty.pause) || owner.getFlag(MPVProperty.pausedForCache) || owner.getFlag("seeking") {
            if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
        }
        controller?.invalidatePlaybackState()
        if let skipTicket, owner.piPSeekHasSettled(skipTicket),
           consumedFrameSerial > skipFrameSerialFloor, let lastEpoch,
           skipPriorEpoch == nil || skipPriorEpoch?.0 != lastEpoch.0 || skipPriorEpoch?.1 != lastEpoch.1,
           let skipDisplayedFrame,
           VortXMPVNativeIsCurrent(skipDisplayedFrame.session, skipDisplayedFrame.frame.lease) {
            // Native settlement may outrun a queued frame callback. AVKit must
            // see the CURRENT achieved sample, not the preceding seek's frame
            // which reached main just before the latest native RESET/settlement.
            completeSkip()
        }
    }

    private func completeSkip() {
        let completion = skipCompletion
        skipCompletion = nil; skipTicket = nil; skipPriorEpoch = nil
        skipDisplayedFrame = nil
        skipDeadline?.cancel(); skipDeadline = nil
        completion?()
    }
    private func completeRestoration(_ succeeded: Bool) {
        let completion = restoration; restoration = nil
        completion?(succeeded)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller, retainsPlayback else { controller.stopPictureInPicture(); return }
        phase = .active
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        finish(reason: reason)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard self.controller === controller else { return }
        finish(reason: "Picture in Picture could not start: \(error.localizedDescription)")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard self.controller === controller, retainsPlayback, !inlineDetached,
              owner?.viewIfLoaded?.window != nil else { completionHandler(false); return }
        completeRestoration(false)
        restoration = completionHandler
        // Restore is completed by the exact foreground renderer acknowledgement,
        // never by presenting a second decoder or an unrelated bare controller.
        finish(reason: nil)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard self.controller === controller, retainsPlayback, let owner else { return }
        if playing { owner.play() } else {
            owner.pause()
            if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
        }
        controller.invalidatePlaybackState()
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        guard let owner, ownsCurrentSource else { return .invalid }
        if owner.playUrlLive { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        let duration = owner.getDouble(MPVProperty.duration)
        guard duration.isFinite, duration > 0 else { return .invalid }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        !ownsCurrentSource || owner?.requestedPauseIntent != false
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime, completion: @escaping () -> Void) {
        completeSkip()
        let previousEpoch = lastEpoch
        let previousFrameSerial = consumedFrameSerial
        guard self.controller === controller, retainsPlayback, let owner, let subscription,
              interval.seconds.isFinite, !owner.playUrlLive,
              let ticket = owner.seekForPiP(by: interval.seconds, owner: subscription.owner) else { completion(); return }
        skipCompletion = completion
        skipTicket = ticket
        skipPriorEpoch = previousEpoch
        skipFrameSerialFloor = previousFrameSerial
        let deadline = DispatchWorkItem { [weak self] in self?.completeSkip() }
        skipDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
    }
}

struct MPVPictureInPictureButton: View {
    @ObservedObject var controller: MPVSampleBufferPiPController
    let onInteraction: () -> Void
    @State private var showsReason = false
    var body: some View {
        if controller.supported {
            Button {
                if controller.active { controller.stop() } else { controller.start() }
                if controller.reason != nil { showsReason = true }
                onInteraction()
            } label: {
                Group {
                    if controller.transitioning { ProgressView() }
                    else { Image(systemName: controller.active ? "pip.exit" : "pip.enter") }
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .playerControlSurface(in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(controller.transitioning)
            .accessibilityLabel(controller.active ? "Exit Picture in Picture" : "Enter Picture in Picture")
            .onChange(of: controller.reason) { if $0 != nil { showsReason = true } }
            .alert("Picture in Picture", isPresented: $showsReason) {
                Button("OK", role: .cancel) {}
            } message: { Text(controller.reason ?? "Picture in Picture is unavailable.") }
        }
    }
}
#endif
