import SwiftUI

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
}
