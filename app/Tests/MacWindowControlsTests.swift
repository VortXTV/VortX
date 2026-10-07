import AppKit

@main enum MacWindowControlsTests {
    @MainActor static func main() {
        // Never shown, ordered front, or used for playback; no live app is launched.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let frame = window.frame
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)!
            let action = button.action
            button.isEnabled = false; button.alphaValue = 0; button.isHidden = true
            button.superview?.alphaValue = 0
            MacWindowControls.restore(in: window)
            precondition(button.isEnabled && !button.isHidden && button.alphaValue == 1)
            precondition(button.superview?.alphaValue == 1)
            precondition(button.action == action, "native actions must not be replaced")
        }
        MacWindowControls.restore(in: window)
        precondition(window.frame == frame, "repeated restoration must not resize the window")
        precondition(window.toolbar == nil, "must not revive the crashing toolbar")
        precondition(!window.isVisible, "test must stay offscreen")
        print("PASS offscreen AppKit traffic lights enabled/visible, native actions, stable frame, no toolbar or app playback")
    }
}
