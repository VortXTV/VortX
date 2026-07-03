import Foundation
import Metal
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

class MetalLayer: CAMetalLayer {

    // Trickplay capture: when a capture is requested, the next nextDrawable() call blits the
    // newly acquired drawable's texture into captureTexture before returning the drawable to mpv.
    // The newly acquired drawable holds the frame from 2+ renders ago — valid and not in transition,
    // unlike the previous drawable which MoltenVK may recycle inside super.nextDrawable().
    // All fields protected by captureLock (VO thread vs main thread).
    private let captureLock = NSLock()
    private var captureCommandQueue: MTLCommandQueue?
    private var captureTexture: MTLTexture?
    // Handler receives the texture on success, or nil if the blit could not be submitted
    // (pipeline not ready, size mismatch). Caller MUST handle nil to unblock its in-flight guard.
    private var _captureHandler: ((MTLTexture?) -> Void)?

    func setupCaptureQueue(_ queue: MTLCommandQueue) {
        captureLock.lock()
        captureCommandQueue = queue
        captureLock.unlock()
    }

    func updateCaptureTexture(_ texture: MTLTexture?) {
        captureLock.lock()
        captureTexture = texture
        captureLock.unlock()
    }

    /// Schedule a single frame capture. handler(texture) fires on a Metal completion thread when
    /// the GPU blit finishes, or handler(nil) fires immediately if the blit cannot be submitted.
    /// Replaces any pending unserviced handler (best-effort, no backlog).
    func requestCapture(handler: @escaping (MTLTexture?) -> Void) {
        captureLock.lock()
        _captureHandler = handler
        captureLock.unlock()
    }

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let d = super.nextDrawable()
        guard let d else { return nil }

        captureLock.lock()
        let handler = _captureHandler
        _captureHandler = nil
        let queue = captureCommandQueue
        let initialDst = captureTexture   // read under the lock (class contract: all fields captureLock-guarded)
        captureLock.unlock()

        if let handler {
            var committed = false
            if let queue, let cmd = queue.makeCommandBuffer(),
               let blit = cmd.makeBlitCommandEncoder() {
                let src = d.texture
                // The capture texture is pre-allocated to an SDR/HD descriptor, but a 4K/HDR/DV drawable
                // arrives with a different size AND pixelFormat (e.g. bgr10a2 / rgba16Float). The old code
                // required an exact match and otherwise dropped the frame (handler(nil)) -> EVERY 4K/HDR/DV
                // frame was silently lost, so those titles never captured trickplay. Instead, reallocate the
                // capture texture to match the source drawable's descriptor on a mismatch, then blit into it.
                var dst = initialDst
                if dst == nil || dst!.width != src.width || dst!.height != src.height || dst!.pixelFormat != src.pixelFormat {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
                    desc.usage = [.shaderRead]
                    // .shared on EVERY platform (the Mac target is Apple-Silicon-only = unified memory). A
                    // .managed texture keeps a separate CPU mirror that is NOT valid after a GPU blit until an
                    // explicit blit.synchronize(resource:) - which this capture path never issues - so on macOS
                    // the completion's CIImage(mtlTexture:) read a stale/empty mirror and the JPEG encode
                    // silently returned nil, capturing ZERO community-trickplay frames for 4K/HDR/DV titles (the
                    // reallocation branch ALWAYS fires for those, since the pre-allocated SDR/HD texture never
                    // matches a 4K bgr10a2/rgba16F drawable). .shared has no CPU-sync gap and matches the sibling
                    // allocator in MPVMetalViewController.updateCapturePipeline(), so both sites now agree.
                    desc.storageMode = .shared
                    if let realloc = device?.makeTexture(descriptor: desc) {
                        dst = realloc
                        captureLock.lock(); captureTexture = realloc; captureLock.unlock()
                    }
                }
                if let dst {
                    blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                              to: dst, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                    cmd.addCompletedHandler { _ in handler(dst) }
                    cmd.commit()
                    committed = true
                } else {
                    blit.endEncoding()
                }
            }
            // Always unblock the caller so its in-flight guard never gets stuck.
            if !committed { handler(nil) }
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
