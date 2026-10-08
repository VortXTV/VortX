import AppKit

@MainActor private final class ActionWindow: NSWindow {
    var closes = 0
    var minimizes = 0
    var zooms = 0
    override func close() { closes += 1 }
    override func miniaturize(_ sender: Any?) { minimizes += 1 }
    override func zoom(_ sender: Any?) { zooms += 1 }
    override func toggleFullScreen(_ sender: Any?) { zooms += 1 }
}

@main enum MacWindowControlsTests {
    @MainActor static func main() {
        // Never shown, ordered front, or used for playback; window action overrides are silent spies.
        _ = NSApplication.shared
        let window = ActionWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let frame = window.frame
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = kinds.map { window.standardWindowButton($0)! }
        let actions = buttons.map(\.action)
        let parents = buttons.map { $0.superview! }
        let frameView = window.contentView!.superview!
        let nativeContainer = parents[0].superview!

        // Reproduce a collapsed hidden-titlebar host above the content. The former height-only repair
        // turned y=500,h=0 into y=500,h=28, so its visible/enabled buttons still could not receive clicks.
        nativeContainer.frame = NSRect(x: 0, y: frameView.bounds.maxY, width: 800, height: 0)
        nativeContainer.isHidden = true
        nativeContainer.alphaValue = 0
        for button in buttons {
            button.isEnabled = false; button.alphaValue = 0; button.isHidden = true
        }
        MacWindowControls.restore(in: window)
        let host = buttons[0].superview!
        precondition(host !== parents[0], "buttons must escape the collapsed titlebar")
        precondition(nativeContainer.isHidden && nativeContainer.alphaValue == 0,
                     "do not resurrect the material/toolbar container")

        func assertHittable() {
            for (index, button) in buttons.enumerated() {
                let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView)
                precondition(frameView.bounds.contains(center), "button center must be inside the actual window")
                precondition(frameView.hitTest(center) === button, "mouse hit must reach the native button")
                precondition(window.standardWindowButton(kinds[index]) === button, "retain the actual native buttons")
                precondition(button.action == actions[index] && (button.target as? NSWindow) === window,
                             "native action and target must survive")
            }
        }
        assertHittable()
        for button in buttons {
            precondition(button.isEnabled && !button.isHidden && button.alphaValue == 1)
            precondition(button.superview?.alphaValue == 1)
        }
        // Resolve the pointer location through the real AppKit hit test, then dispatch that control.
        for button in buttons {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView)
            (frameView.hitTest(center) as! NSButton).performClick(nil)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(window.closes == 1 && window.minimizes == 1 && window.zooms == 1,
                     "close/minimize/zoom must dispatch their native window actions")

        // Empty parts of our host pass through, and full-size content cannot steal the buttons.
        let emptyPoint = host.convert(NSPoint(x: 27, y: 16), to: frameView)
        precondition(host.hitTest(emptyPoint) == nil, "button gaps must not eat content clicks")
        frameView.addSubview(window.contentView!, positioned: .above, relativeTo: nil)
        MacWindowControls.restore(in: window)
        assertHittable()
        precondition(window.frame == frame, "repeated restoration must not resize the window")

        let resizedFrame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.setFrame(resizedFrame, display: false)
        // Autoresizing must keep the controls anchored before a later didUpdate repair.
        precondition(host.frame.maxY == frameView.bounds.maxY)
        assertHittable()
        host.isHidden = true; host.alphaValue = 0 // player close / later SwiftUI chrome churn
        MacWindowControls.restore(in: window)
        precondition(window.frame == resizedFrame)
        assertHittable()

        MacWindowControls.prepareForFullScreen(in: window)
        for (index, button) in buttons.enumerated() {
            precondition(button.superview === parents[index], "native fullscreen must recover its original buttons")
        }
        MacWindowControls.restore(in: window) // exit fullscreen / cancelled transition
        assertHittable()

        precondition(window.toolbar == nil, "must not revive the crashing toolbar")
        precondition(!window.isVisible, "test must stay offscreen")
        print("PASS offscreen AppKit traffic lights: collapsed-host hit testing, native click actions, content pass-through, resize, fullscreen handoff, stable frame, no toolbar or playback")
    }
}
