import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Serializes access to the reusable capture texture across GPU production and CPU consumption.
/// A token remains active until the consumer explicitly releases its lease. Stale or repeated releases
/// cannot unlock a newer capture.
final class MetalCaptureLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextToken: UInt64 = 0
    private var activeToken: UInt64?

    func acquire() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    func release(token: UInt64) {
        lock.lock()
        if activeToken == token {
            activeToken = nil
        }
        lock.unlock()
    }
}

/// A single-owner view of the capture texture. `release` is idempotent, and deinit is a final
/// safety net so an abandoned callback cannot permanently stall later capture requests.
final class MetalCaptureTextureLease: @unchecked Sendable {
    let texture: MTLTexture
    private let state: MetalCaptureLeaseState
    private let token: UInt64

    init(texture: MTLTexture, state: MetalCaptureLeaseState, token: UInt64) {
        self.texture = texture
        self.state = state
        self.token = token
    }

    func release() {
        state.release(token: token)
    }

    deinit {
        release()
    }
}

/// Owns one callback and its prepared lease across Metal's @Sendable completion boundary.
/// Every mutable field is lock-protected, and `complete` consumes the callback before invoking it,
/// so replacement, submission failure, and GPU completion can never deliver more than once.
private final class CaptureDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((MetalCaptureTextureLease?) -> Void)?
    private var texture: MTLTexture?
    private var leaseState: MetalCaptureLeaseState?
    private var leaseToken: UInt64?

    init(handler: @escaping (MetalCaptureTextureLease?) -> Void) {
        self.handler = handler
    }

    func prepare(texture: MTLTexture, leaseState: MetalCaptureLeaseState, leaseToken: UInt64) {
        var releaseUnusedToken = false
        lock.lock()
        if handler != nil {
            self.texture = texture
            self.leaseState = leaseState
            self.leaseToken = leaseToken
        } else {
            releaseUnusedToken = true
        }
        lock.unlock()
        if releaseUnusedToken {
            leaseState.release(token: leaseToken)
        }
    }

    func complete(succeeded: Bool) {
        lock.lock()
        guard let handler else {
            lock.unlock()
            return
        }
        self.handler = nil
        let preparedTexture = texture
        let preparedLeaseState = leaseState
        let preparedLeaseToken = leaseToken
        texture = nil
        leaseState = nil
        leaseToken = nil
        lock.unlock()

        let lease: MetalCaptureTextureLease?
        if succeeded,
           let preparedTexture,
           let preparedLeaseState,
           let preparedLeaseToken {
            lease = MetalCaptureTextureLease(
                texture: preparedTexture,
                state: preparedLeaseState,
                token: preparedLeaseToken
            )
        } else {
            if let preparedLeaseState, let preparedLeaseToken {
                preparedLeaseState.release(token: preparedLeaseToken)
            }
            lease = nil
        }
        handler(lease)
    }
}

class MetalLayer: CAMetalLayer {

    #if os(tvOS) && VORTX_FRAME_PRESENTATION_TESTER
    /// Owned by the player controller. Kept weak so the layer and late drawable
    /// callbacks cannot extend a finished playback generation.
    weak var presentationDiagnostics: FramePresentationDiagnosticsAccumulator?
    #endif

    // Trickplay capture: when a capture is requested, the next nextDrawable() call scales the
    // newly acquired drawable's texture into captureTexture before returning the drawable to mpv.
    // Normal trickplay requests 480px width; explicit frame grabs may request a wider bounded target.
    // The newly acquired drawable holds the frame from 2+ renders ago, valid and not in transition,
    // unlike the previous drawable which MoltenVK may recycle inside super.nextDrawable().
    // All fields protected by captureLock (VO thread vs main thread).
    private let captureLock = NSLock()
    private var captureCommandQueue: MTLCommandQueue?
    private var captureScaler: MPSImageBilinearScale?
    private var captureTexture: MTLTexture?
    private let captureLeaseState = MetalCaptureLeaseState()
    private var captureMaxWidth = 1
    // Delivery receives a leased texture on success, or nil if the GPU scale could not be submitted.
    // Caller MUST release a successful lease after its final texture read.
    private var captureDelivery: CaptureDelivery?

    func setupCaptureQueue(_ queue: MTLCommandQueue) {
        captureLock.lock()
        captureCommandQueue = queue
        captureScaler = MPSImageBilinearScale(device: queue.device)
        // updateCapturePipeline calls this when CAMetalLayer moves to a different device. Never
        // carry a texture allocated by the old device into the new command queue.
        captureTexture = nil
        captureLock.unlock()
    }

    /// Schedule a single frame capture. handler(lease) fires on a Metal completion thread when
    /// the GPU scale finishes, or handler(nil) fires immediately if it cannot be submitted. A successful
    /// handler must release its lease after the final texture read.
    /// Replaces any pending unserviced handler (best-effort, no backlog); that replaced handler is
    /// fired with nil so its caller's in-flight guard is never left stuck.
    func requestCapture(maxWidth: Int, handler: @escaping (MetalCaptureTextureLease?) -> Void) {
        let delivery = CaptureDelivery(handler: handler)
        captureLock.lock()
        let previous = captureDelivery
        captureDelivery = delivery
        captureMaxWidth = max(1, maxWidth)
        captureLock.unlock()
        // Honor the always-fires contract for a still-pending handler this request replaces (no drawable
        // serviced it yet). Invoked OUTSIDE the lock so the callback can never re-enter captureLock.
        previous?.complete(succeeded: false)
    }

    override func nextDrawable() -> (any CAMetalDrawable)? {
        #if os(tvOS) && VORTX_FRAME_PRESENTATION_TESTER
        let drawableWaitStartedAt = CACurrentMediaTime()
        #endif
        let d = super.nextDrawable()
        #if os(tvOS) && VORTX_FRAME_PRESENTATION_TESTER
        let drawableAcquiredAt = CACurrentMediaTime()
        let presentationDiagnostics = presentationDiagnostics
        let presentationGeneration = presentationDiagnostics?.recordDrawable(
            wait: drawableAcquiredAt - drawableWaitStartedAt,
            returned: d != nil
        )
        if let d, let presentationGeneration {
            d.addPresentedHandler { [weak presentationDiagnostics] drawable in
                let presentedTime = drawable.presentedTime
                let latency = presentedTime > 0
                    ? presentedTime - drawableAcquiredAt
                    : nil
                presentationDiagnostics?.recordPresented(
                    generation: presentationGeneration,
                    latency: latency
                )
            }
        }
        #endif
        guard let d else { return nil }

        captureLock.lock()
        let leaseToken = captureDelivery == nil ? nil : captureLeaseState.acquire()
        let delivery = leaseToken == nil ? nil : captureDelivery
        if delivery != nil {
            captureDelivery = nil
        }
        let queue = delivery == nil ? nil : captureCommandQueue
        let scaler = delivery == nil ? nil : captureScaler
        let maxWidth = delivery == nil ? 1 : captureMaxWidth
        let initialDst = delivery == nil ? nil : captureTexture
        captureLock.unlock()

        if let delivery, let leaseToken {
            var committed = false
            if let queue, let scaler, let cmd = queue.makeCommandBuffer() {
                let src = d.texture
                guard ObjectIdentifier(src.device) == ObjectIdentifier(queue.device) else {
                    // The layer swapped devices after request setup. Fail this capture only; the
                    // normal cadence will rebuild the pipeline and retry without blocking the VO.
                    captureLeaseState.release(token: leaseToken)
                    delivery.complete(succeeded: false)
                    return d
                }
                let targetWidth = min(src.width, maxWidth)
                let targetHeight = max(1, Int(
                    (Double(src.height) * Double(targetWidth) / Double(src.width)).rounded()
                ))
                var dst = initialDst
                if let existing = dst,
                   ObjectIdentifier(existing.device) == ObjectIdentifier(queue.device),
                   existing.width == targetWidth,
                   existing.height == targetHeight,
                   existing.pixelFormat == src.pixelFormat {
                    dst = existing
                } else {
                    dst = nil
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: src.pixelFormat,
                        width: targetWidth,
                        height: targetHeight,
                        mipmapped: false
                    )
                    desc.usage = [.shaderRead, .shaderWrite]
                    desc.storageMode = .shared
                    if let realloc = queue.device.makeTexture(descriptor: desc) {
                        realloc.label = "VortX capture \(targetWidth)x\(targetHeight) from \(src.width)x\(src.height)"
                        dst = realloc
                        captureLock.lock()
                        if let activeQueue = captureCommandQueue,
                           ObjectIdentifier(activeQueue.device) == ObjectIdentifier(queue.device) {
                            captureTexture = realloc
                        }
                        captureLock.unlock()
                    }
                }
                if let dst {
                    // MPS keeps the source pixel format, so HDR captures retain the same component
                    // representation while the GPU writes only the requested thumbnail dimensions.
                    scaler.encode(commandBuffer: cmd, sourceTexture: src, destinationTexture: dst)
                    delivery.prepare(
                        texture: dst,
                        leaseState: captureLeaseState,
                        leaseToken: leaseToken
                    )
                    cmd.addCompletedHandler { buffer in
                        delivery.complete(succeeded: buffer.status == .completed)
                    }
                    cmd.commit()
                    committed = true
                }
            }
            // Always unblock the caller so its in-flight guard never gets stuck.
            if !committed {
                captureLeaseState.release(token: leaseToken)
                delivery.complete(succeeded: false)
            }
        }

        return d
    }

    // workaround for a MoltenVK that sets the drawableSize to 1x1 to forcefully complete
    // the presentation, this causes flicker and the drawableSize possibly staying at 1x1
    // https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR layer control exists on iOS 16+/macOS only; CAMetalLayer has no
    // wantsExtendedDynamicRangeContent on tvOS at all. tvOS HDR is driven by
    // HDRDisplayMode (an AVDisplayManager HDMI display-mode switch) plus the
    // PQ/HLG colorspace tag applied in MPVMetalViewController.
    // The setter must run on the main thread to activate screen EDR mode.
    #if os(iOS) || os(macOS)
    override var wantsExtendedDynamicRangeContent: Bool  {
        get {
            return super.wantsExtendedDynamicRangeContent
        }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                // CRITICAL: must NOT block the calling thread on the main thread. MoltenVK sets this
                // property from mpv's video-output (vo) thread WHILE holding the CAMetalLayer's
                // per-layer lock; the main thread is concurrently mutating the same layer
                // (drawableSize/frame in layoutDrawable, colorspace in syncDisplayDynamicRange) and so
                // is waiting to take that same lock. A `DispatchQueue.main.sync` here parks the vo
                // thread on the main thread while it holds the lock the main thread needs → a hard
                // two-lock deadlock that froze the whole app (the 743s macOS hang, video stuck at 0:00,
                // even Quit dead). Hop to main ASYNC so the vo thread returns immediately and releases
                // the layer lock; EDR activating one runloop later is imperceptible. Re-entering the
                // setter on the main thread takes the `isMainThread` branch above (no recursion).
                DispatchQueue.main.async { [weak self] in
                    self?.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
    #endif
}
