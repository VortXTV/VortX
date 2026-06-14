import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Cross-platform shims for iOS-only SwiftUI modifiers, so the shared SourcesiOS views compile on
/// macOS too (where these modifiers do not exist). On iOS they apply exactly as before; on macOS
/// they are no-ops or the nearest macOS equivalent.
extension View {
    /// Inline navigation title bar on iOS; no-op on macOS (macOS has no display-mode modifier).
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Email-style text field tuning on iOS; no-op on macOS.
    @ViewBuilder func emailFieldStyle() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Full-screen cover on iOS; a sheet on macOS (which has no fullScreenCover).
    @ViewBuilder func platformFullScreenCover<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }

    /// Like `platformFullScreenCover`, but on macOS the presented content is sized to fill the screen
    /// so the player / trailer reads as a large, window-filling, in-app surface — NOT the tiny floating
    /// sheet a `.sheet` collapses to around full-bleed (`Color.black.ignoresSafeArea`) content with no
    /// intrinsic size. On iOS / iPadOS this is identical to `platformFullScreenCover` (the system
    /// already presents `fullScreenCover` edge-to-edge). Use this ONLY for media covers (player /
    /// trailer); ordinary form sheets (e.g. the profile editor) should stay on `platformFullScreenCover`.
    @ViewBuilder func platformFullScreenPlayerCover<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item) { value in
            content(value)
                .frame(width: Self.macPlayerCoverSize.width, height: Self.macPlayerCoverSize.height)
                // Hide the host window's titlebar + toolbar while the player is up, so the nav chrome
                // hoisted there (back button, title, the .searchable field) cannot float over the video.
                .background(MacPlayerChromeHider())
        }
        #endif
    }

    #if os(macOS)
    /// The near-full-screen size for a macOS media cover: the main screen's visible frame (excludes the
    /// menu bar / Dock), with a sensible fallback if no screen is reported. Large enough that the player
    /// fills the window and stops reading as a separate little app.
    private static var macPlayerCoverSize: CGSize {
        if let visible = NSScreen.main?.visibleFrame.size, visible.width > 0, visible.height > 0 {
            return CGSize(width: visible.width, height: visible.height)
        }
        return CGSize(width: 1280, height: 800)
    }
    #endif
}

#if os(macOS)
/// While a player / trailer cover is presented, strip the HOST window's titlebar + toolbar so the
/// hoisted navigation chrome (back button, title, the Search field) stops floating in a strip above
/// the video (the macOS "weird middle way"). The sheet covers the content area; this removes the
/// strip on top. Everything is restored when the cover dismisses, so browsing chrome returns intact.
private struct MacPlayerChromeHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view is hosted in the SHEET window. A SwiftUI macOS .sheet is NOT an attached NSWindow
        // sheet, so .sheetParent is nil; the chrome we need to hide lives on the MAIN titled app window.
        // Find that window directly (the titled, visible window that is not this sheet). Defer one
        // runloop so the window hierarchy is attached.
        DispatchQueue.main.async { [weak view] in
            let sheetWindow = view?.window
            let host = NSApp.windows.first { w in
                w != sheetWindow && w.isVisible && w.styleMask.contains(.titled)
            } ?? sheetWindow
            guard let host else { return }
            let c = context.coordinator
            c.host = host
            c.savedStyleMask = host.styleMask
            c.savedTitleVisibility = host.titleVisibility
            c.savedTitlebarTransparent = host.titlebarAppearsTransparent
            c.savedToolbarVisible = host.toolbar?.isVisible
            host.titleVisibility = .hidden
            host.titlebarAppearsTransparent = true
            host.styleMask.insert(.fullSizeContentView)
            host.toolbar?.isVisible = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard let host = coordinator.host else { return }
        host.titleVisibility = coordinator.savedTitleVisibility
        host.titlebarAppearsTransparent = coordinator.savedTitlebarTransparent
        host.styleMask = coordinator.savedStyleMask
        if let v = coordinator.savedToolbarVisible { host.toolbar?.isVisible = v }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: NSWindow?
        var savedStyleMask: NSWindow.StyleMask = []
        var savedTitleVisibility: NSWindow.TitleVisibility = .visible
        var savedTitlebarTransparent = false
        var savedToolbarVisible: Bool?
    }
}
#endif
