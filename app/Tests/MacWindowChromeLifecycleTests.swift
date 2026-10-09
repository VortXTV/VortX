import AppKit

// A playback-presence sentinel only. This executable has no player, media, or app bootstrap.
@MainActor final class MacPlayerHost {
    static let shared = MacPlayerHost()
    var content: Bool?
}

@main enum MacWindowChromeLifecycleTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let first = makeWindow()
        let second = makeWindow()
        let coordinator = MacWindowChrome.Coordinator()
        let accessor = MacWindowChrome.WindowAccessor(frame: .zero)
        accessor.windowChanged = { coordinator.attach(to: $0) }
        let firstButton = first.standardWindowButton(.closeButton)!
        let firstNativeParent = firstButton.superview!
        first.contentView!.addSubview(accessor)
        let firstHost = firstButton.superview!
        precondition(firstHost !== firstNativeParent, "viewDidMoveToWindow must install controls")

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: first)
        precondition(firstButton.superview === firstNativeParent)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        precondition(firstButton.superview === firstNativeParent, "updates must not fight the fullscreen transition")
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: first)
        var restoredHost = firstButton.superview!
        precondition(restoredHost !== firstNativeParent)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: first)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.1))
        restoredHost = firstButton.superview!
        precondition(restoredHost !== firstNativeParent, "failed fullscreen entry must not suspend controls forever")

        MacPlayerHost.shared.content = true
        restoredHost.isHidden = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        precondition(restoredHost.isHidden, "playback must remain chrome-free")
        MacPlayerHost.shared.content = nil
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        precondition(!restoredHost.isHidden, "dismissal restores normal controls")

        accessor.removeFromSuperview()
        restoredHost.isHidden = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        precondition(restoredHost.isHidden, "detachment must remove old-window observers")
        let secondButton = second.standardWindowButton(.closeButton)!
        let secondNativeParent = secondButton.superview!
        second.contentView!.addSubview(accessor)
        precondition(secondButton.superview !== secondNativeParent, "reattachment must configure the new window")
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        precondition(restoredHost.isHidden, "old-window updates must stay detached")
        MacWindowChrome.dismantleNSView(accessor, coordinator: coordinator)
        let secondHost = secondButton.superview!
        secondHost.isHidden = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: second)
        precondition(secondHost.isHidden, "dismantle must remove observers and pending repairs")
        precondition(!first.isVisible && !second.isVisible && first.toolbar == nil && second.toolbar == nil)
        print("PASS offscreen MacWindowChrome lifecycle: real view attachment, fullscreen handoff/cancellation, player suppression/dismissal, detach/reattach, dismantle, no toolbar or playback")
    }
}
