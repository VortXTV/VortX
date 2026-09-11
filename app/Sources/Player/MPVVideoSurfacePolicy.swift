import Foundation
import CoreGraphics

/// A drawable that was already valid before mpv opened does not need a decoder reset at first
/// layout. Only an actual unsized-to-sized transition needs the embedded-preview recovery.
struct MPVVideoSurfacePolicy {
    private(set) var needsInitialRebuild = true

    mutating func prepare(bounds: CGSize, scale: CGFloat) -> CGSize? {
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard bounds.width.isFinite, bounds.height.isFinite, scale.isFinite,
              bounds.width > 1, bounds.height > 1, scale > 0,
              pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 1, pixels.height > 1 else {
            needsInitialRebuild = true
            return nil
        }
        needsInitialRebuild = false
        return pixels
    }

    mutating func consumeInitialRebuild() -> Bool {
        let needed = needsInitialRebuild
        needsInitialRebuild = false
        return needed
    }
}
