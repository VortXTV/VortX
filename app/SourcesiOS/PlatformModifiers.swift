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
        // macOS has no fullScreenCover, and a .sheet renders as a separate, mis-positioned window that
        // floats OUTSIDE the app (titlebar + nav chrome leak above the video, controls under the Dock).
        // Lift the player to the app window's ROOT via MacPlayerHost; MacRootPlayerOverlay (applied once
        // at the WindowGroup scene root, ABOVE any sheet) renders it full-window edge-to-edge. The bridge
        // only mirrors `item` into the host.
        self.background(MacPlayerCoverBridge(item: item, content: content))
        #endif
    }
}

#if os(macOS)
/// Holds the macOS player view to present at the app window's ROOT. A SwiftUI `.sheet` on macOS becomes
/// a separate, mis-positioned window; this singleton lets the deep `platformFullScreenPlayerCover` call
/// sites hand their player up to `MacRootPlayerOverlay` so it fills the actual app window instead.
final class MacPlayerHost: ObservableObject {
    static let shared = MacPlayerHost()
    @Published var content: AnyView?
    /// Identity of the cover bridge currently presenting. Several call sites (Search, the detail page,
    /// Continue-Watching resume) each attach a bridge and all feed THIS one host, so a bridge must only
    /// ever clear the player IT put up — never one another bridge owns — and a bridge being torn down
    /// (e.g. its detail page popped while the player was up) must be able to clean up after itself.
    private var ownerID: UUID?
    private init() {}

    func present(_ view: AnyView, owner: UUID) {
        ownerID = owner
        content = view
    }

    /// Clear the player only if `owner` is the one currently presenting; a stale bridge tearing down must
    /// not yank a player a newer bridge owns.
    func dismiss(owner: UUID) {
        guard ownerID == owner else { return }
        ownerID = nil
        content = nil
    }
}

/// Mirrors a player cover's `item` into `MacPlayerHost`: set the binding -> snapshot the player into the
/// host; clear it (or leave the view tree) -> remove it. A clear background so it lives in the call site's
/// view tree (so its `onChange` fires when the player closes) without drawing anything itself.
private struct MacPlayerCoverBridge<Item: Identifiable, C: View>: View {
    @Binding var item: Item?
    @ViewBuilder let content: (Item) -> C
    /// Stable per-instance identity (persisted across re-renders by @State) so the host knows which bridge
    /// owns the on-screen player and a torn-down bridge clears only its own — see MacPlayerHost.ownerID.
    @State private var ownerID = UUID()
    var body: some View {
        Color.clear
            .onChange(of: item?.id) { _, _ in sync() }
            .onAppear { if item != nil { sync() } }
            // If this bridge leaves the tree while its player is still up (e.g. a detail page popped via a
            // menu/keyboard path), clear the host so the overlay can't strand a player over the disabled app.
            .onDisappear { MacPlayerHost.shared.dismiss(owner: ownerID) }
    }
    private func sync() {
        if let item {
            MacPlayerHost.shared.present(AnyView(content(item)), owner: ownerID)
        } else {
            MacPlayerHost.shared.dismiss(owner: ownerID)
        }
    }
}

/// Applied ONCE at the WindowGroup scene root (StremioXiOSApp, macOS only) so it sits ABOVE any sheet
/// (SignIn / OpenLink) or cover: renders the active MacPlayerHost player full-window over the dimmed +
/// disabled app, and hides the window titlebar while it is up so no nav chrome floats over the video.
/// Full-window edge-to-edge, matching the v0.1.6 WebView build. The macOS twin of the tvOS root player.
struct MacRootPlayerOverlay: ViewModifier {
    @ObservedObject private var host = MacPlayerHost.shared
    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(host.content == nil ? 1 : 0)
                .disabled(host.content != nil)
            if let player = host.content {
                player
                    .ignoresSafeArea()
                    .background(MacPlayerChromeHider())
            }
        }
    }
}

/// While the root player overlay is up, hide the window's title + toolbar so the hoisted nav chrome
/// (back button, title, the Search field) cannot float in a strip above the video. Restored on dismiss.
/// Deliberately does NOT touch `styleMask` / `.fullSizeContentView`: reassigning the styleMask on restore
/// collapsed the window to its minimum size (observed on-device). Only title + toolbar visibility are
/// toggled, which leaves a thin traffic-light strip at top but never resizes the window.
private struct MacPlayerChromeHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let c = context.coordinator
        // The window isn't attached yet, so defer one runloop turn to find + mutate it. If the view is
        // dismantled BEFORE this runs (rapid present-then-dismiss in the same cycle), `c.cancelled` is
        // already set, so we bail without hiding the titlebar — otherwise we'd hide it with nothing left
        // to restore it and the window would lose its titlebar permanently.
        DispatchQueue.main.async { [weak view] in
            guard !c.cancelled, let host = view?.window else { return }
            c.host = host
            c.savedTitleVisibility = host.titleVisibility
            c.savedTitlebarTransparent = host.titlebarAppearsTransparent
            host.titleVisibility = .hidden
            host.titlebarAppearsTransparent = true
            // DO NOT toggle `host.toolbar?.isVisible`. That NSToolbar is OWNED by SwiftUI's ToolbarBridge;
            // mutating its visibility here corrupts the bridge, so the NEXT SwiftUI-driven toolbar rebuild
            // (navigating into a Settings sub-screen after the player has been up) crashed in
            // -[NSToolbar _insertNewItemWithItemIdentifier:...] (EXC_BREAKPOINT). Live-repro'd 2026-07-05:
            // play -> close -> open "VortX account & sync" crashed; a fresh navigation never did. The
            // transparent titlebar + hidden title already keep chrome off the full-window player cover.
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancelled = true   // stops a not-yet-run makeNSView async block from hiding the titlebar
        guard let host = coordinator.host else { return }
        host.titleVisibility = coordinator.savedTitleVisibility
        host.titlebarAppearsTransparent = coordinator.savedTitlebarTransparent
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: NSWindow?
        var cancelled = false
        var savedTitleVisibility: NSWindow.TitleVisibility = .visible
        var savedTitlebarTransparent = false
        var savedToolbarVisible: Bool?
    }
}
#endif
