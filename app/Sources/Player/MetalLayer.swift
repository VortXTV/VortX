import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

class MetalLayer: CAMetalLayer {

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
