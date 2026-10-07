#if os(macOS)
import AppKit

/// Restore AppKit's own buttons without creating a toolbar or replacing their native actions.
@MainActor
enum MacWindowControls {
    static func restore(in window: NSWindow) {
        let needed: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if !window.styleMask.isSuperset(of: needed) { window.styleMask.formUnion(needed) }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = true
            var node = button.superview
            let contentHost = window.contentView?.superview
            while let view = node, view !== contentHost {
                view.isHidden = false
                view.alphaValue = 1
                if view.frame.height < 1 {
                    var frame = view.frame
                    frame.size.height = 28
                    view.frame = frame
                }
                // Reorder only existing siblings. Full-size content must not intercept these buttons.
                if let host = contentHost, view.superview === host,
                   let content = window.contentView,
                   let titleIndex = host.subviews.firstIndex(of: view),
                   let contentIndex = host.subviews.firstIndex(of: content), titleIndex < contentIndex {
                    host.addSubview(view, positioned: .above, relativeTo: content)
                }
                node = view.superview
            }
        }
    }
}
#endif
