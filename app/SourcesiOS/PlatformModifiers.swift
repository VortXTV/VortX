import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
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

    /// URL-oriented text field tuning: disables correction everywhere, and disables automatic
    /// capitalization only on iOS where the API exists.
    @ViewBuilder func urlFieldStyle(alignment: TextAlignment = .leading) -> some View {
        #if os(iOS)
        self
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .multilineTextAlignment(alignment)
        #else
        self
            .autocorrectionDisabled()
            .multilineTextAlignment(alignment)
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
            content(value).frame(
                width: Self.macPlayerCoverSize.width,
                height: Self.macPlayerCoverSize.height)
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
