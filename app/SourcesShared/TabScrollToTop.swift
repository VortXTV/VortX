import SwiftUI

/// Tap-the-active-tab-again -> scroll that tab's screen to the top (and, on tvOS, refocus the top).
///
/// A tiny shared signal: the root tab shells (iOS `iOSRootView`, tvOS `RootTabView`) call `bump(_:)`
/// with a stable per-tab key when the user selects the tab that is ALREADY active. Each scrollable
/// screen observes its own key's token via `.scrollToTopOnBump(_:)` and, when the token changes,
/// asks its `ScrollViewReader` to scroll to a top anchor. Switching tabs normally never bumps a
/// token, so routine navigation is untouched.
///
/// Keyed by a plain `String` (the tab's stable name) rather than the platform tab enums so the one
/// signal object serves both the iOS custom tab shell and the tvOS native `TabView` without leaking
/// either platform's `Tab` type into shared code.
@MainActor
final class TabScrollToTop: ObservableObject {
    static let shared = TabScrollToTop()
    private init() {}

    /// Monotonic per-tab counter. A screen observes its key and scrolls to top whenever its value
    /// changes; the value itself is meaningless beyond "it changed", so a simple increment suffices.
    @Published private(set) var tokens: [String: Int] = [:]

    /// The current token for a tab key (0 before the first bump). Screens compare this across renders.
    func token(_ key: String) -> Int { tokens[key] ?? 0 }

    /// Signal that the active tab `key` was re-selected: bump its token so the mounted screen scrolls up.
    func bump(_ key: String) { tokens[key, default: 0] += 1 }
}

/// The shared top-anchor id every opted-in scroll screen pins to its first child, so `scrollTo` has a
/// deterministic target. A single constant keeps the anchor consistent across screens.
enum ScrollToTopAnchor {
    static let id = "vortx.scrollToTop.anchor"
}

/// Stable per-tab keys for the scroll-to-top signal. The tab shells bump these when the active tab is
/// re-tapped; the mounted screens observe the same string. Central so the shell's `Tab` enum (private
/// to each root view) and the screen structs (which can't see that private enum) never drift apart.
enum TabScrollKeys {
    static let home = "vortx.tab.home"
    static let discover = "vortx.tab.discover"
    static let live = "vortx.tab.live"
    static let library = "vortx.tab.library"
    static let search = "vortx.tab.search"
    static let addons = "vortx.tab.addons"
    static let settings = "vortx.tab.settings"
}

extension View {
    /// Pin this view as the scroll-to-top anchor. Place it as the FIRST child inside the scroll content
    /// (e.g. above the hero) so scrolling to it lands at the very top. Zero-height so it adds no layout.
    func scrollToTopAnchor() -> some View {
        self.id(ScrollToTopAnchor.id)
    }
}

/// Wrap a scrollable screen so a re-tap of its (already active) tab scrolls it to the top.
///
/// The screen must expose a top anchor via `.scrollToTopAnchor()` on its first scroll child. This
/// modifier drives a `ScrollViewReader`-backed scroll to that anchor whenever the tab's token bumps,
/// animated gently and non-disruptively (a no-op unless the token actually changes).
struct ScrollToTopOnBump: ViewModifier {
    let key: String
    @ObservedObject private var signal = TabScrollToTop.shared

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: signal.token(key)) { _ in
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(ScrollToTopAnchor.id, anchor: .top)
                    }
                }
        }
    }
}

extension View {
    /// Scroll this screen to its `.scrollToTopAnchor()` when the tab `key` is re-tapped while active.
    /// Apply to the `ScrollView` (or a container wrapping it) so the injected `ScrollViewReader` sees it.
    func scrollToTopOnBump(_ key: String) -> some View {
        modifier(ScrollToTopOnBump(key: key))
    }
}

// MARK: - Pop-to-root on re-tap

/// Re-tapping the active tab also POPS its NavigationStack to root (then the scroll-to-top above lands
/// on the root screen's anchor). Only a RE-TAP bumps the token, so switching to a tab that has a pushed
/// detail keeps its stack intact — routine navigation is untouched. Two shapes because the tab screens
/// keep their paths as either an untyped `NavigationPath` or a typed `[Element]` array.
struct PopToRootOnBump: ViewModifier {
    let key: String
    @Binding var path: NavigationPath
    @ObservedObject private var signal = TabScrollToTop.shared

    init(key: String, path: Binding<NavigationPath>) {
        self.key = key
        self._path = path
    }

    func body(content: Content) -> some View {
        content.onChange(of: signal.token(key)) { _ in
            if !path.isEmpty { path.removeLast(path.count) }
        }
    }
}

/// The typed-path twin of `PopToRootOnBump` for screens whose path is a plain `[Element]` array.
struct PopToRootOnBumpTyped<Element>: ViewModifier {
    let key: String
    @Binding var path: [Element]
    @ObservedObject private var signal = TabScrollToTop.shared

    init(key: String, path: Binding<[Element]>) {
        self.key = key
        self._path = path
    }

    func body(content: Content) -> some View {
        content.onChange(of: signal.token(key)) { _ in
            if !path.isEmpty { path.removeAll() }
        }
    }
}

extension View {
    /// Pop this tab's `NavigationStack` to root when its tab `key` is re-tapped while active. Apply to
    /// the `NavigationStack` (or any ancestor of it) alongside `.scrollToTopOnBump(_:)`.
    func popToRootOnBump(_ key: String, path: Binding<NavigationPath>) -> some View {
        modifier(PopToRootOnBump(key: key, path: path))
    }

    /// Typed-path overload for screens that keep their path as a `[Element]` array.
    func popToRootOnBump<Element>(_ key: String, path: Binding<[Element]>) -> some View {
        modifier(PopToRootOnBumpTyped(key: key, path: path))
    }
}
