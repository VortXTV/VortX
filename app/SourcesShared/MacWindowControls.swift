#if os(macOS)
import AppKit

/// Keep AppKit's own buttons reachable without reviving SwiftUI's collapsed titlebar or its toolbar.
@MainActor
enum MacWindowControls {
    static func restore(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let needed: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if !window.styleMask.isSuperset(of: needed) { window.styleMask.formUnion(needed) }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        guard let frameView = window.contentView?.superview else { return }
        let host = buttonHost(in: window) ?? ButtonHost(frame: .zero)
        host.installButtons(from: window)
        // The hidden-titlebar container can have height zero AND an origin above the window.
        // Unhiding it or expanding only its height leaves visible/enabled buttons outside hit testing.
        // This small independent host has no material/background and never changes those containers.
        let size = host.buttonRowSize
        let frame = NSRect(x: frameView.bounds.minX,
                           y: frameView.isFlipped ? frameView.bounds.minY : frameView.bounds.maxY - size.height,
                           width: size.width, height: size.height)
        if host.frame != frame { host.frame = frame }
        let resizing: NSView.AutoresizingMask = [frameView.isFlipped ? .maxYMargin : .minYMargin, .maxXMargin]
        if host.autoresizingMask != resizing { host.autoresizingMask = resizing }
        if frameView.subviews.last !== host {
            frameView.addSubview(host, positioned: .above, relativeTo: nil)
        }
        if host.isHidden { host.isHidden = false }
        if host.alphaValue != 1 { host.alphaValue = 1 }
    }

    /// Let AppKit own its native fullscreen titlebar and hover behavior during the entire transition.
    static func prepareForFullScreen(in window: NSWindow) {
        buttonHost(in: window)?.restoreNativePlacement()
    }

    private static func buttonHost(in window: NSWindow) -> ButtonHost? {
        window.contentView?.superview?.subviews.compactMap { $0 as? ButtonHost }.first
    }

    private final class ButtonHost: NSView {
        private struct Placement {
            let button: NSButton
            weak var parent: NSView?
            let frame: NSRect
            let autoresizingMask: NSView.AutoresizingMask
        }
        private var placements: [Placement] = []
        private(set) var buttonRowSize = NSSize.zero

        func installButtons(from window: NSWindow) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            // AppKit can replace its buttons when window chrome changes. Drop only stale owned views.
            placements.removeAll { placement in
                guard !buttons.contains(where: { $0 === placement.button }) else { return false }
                if placement.button.superview === self { placement.button.removeFromSuperview() }
                return true
            }
            let inset: CGFloat = 9
            let height = (buttons.map { $0.frame.height }.max() ?? 14) + 2 * inset
            var x = inset
            for button in buttons {
                if button.superview !== self {
                    placements.removeAll { $0.button === button }
                    placements.append(Placement(button: button, parent: button.superview,
                                                frame: button.frame, autoresizingMask: button.autoresizingMask))
                    addSubview(button)
                }
                let frame = NSRect(x: x, y: (height - button.frame.height) / 2,
                                   width: button.frame.width, height: button.frame.height)
                if button.frame != frame { button.frame = frame }
                if !button.autoresizingMask.isEmpty { button.autoresizingMask = [] }
                if button.isHidden { button.isHidden = false }
                if button.alphaValue != 1 { button.alphaValue = 1 }
                if !button.isEnabled { button.isEnabled = true }
                x = frame.maxX + inset
            }
            buttonRowSize = NSSize(width: x, height: height)
        }

        func restoreNativePlacement() {
            for placement in placements {
                guard let parent = placement.parent, parent.window === window else { continue }
                parent.addSubview(placement.button)
                placement.button.frame = placement.frame
                placement.button.autoresizingMask = placement.autoresizingMask
            }
            // Normally empty now; retaining an orphan until the next restore is safer than losing it.
            if subviews.isEmpty { removeFromSuperview() } else { isHidden = true }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            // Empty space between/around the buttons still belongs to the full-size SwiftUI content.
            return hit === self ? nil : hit
        }
    }
}
#endif
