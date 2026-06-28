import SwiftUI

// Keyboard-browse focus for the macOS app ONLY. The Mac target reuses the touch-first SourcesiOS UI
// (not Catalyst, not the tvOS focus engine), so it ships with no way to browse without a mouse. This
// adds a NATIVE SwiftUI focus substrate (`.focusable()` + `@FocusState` + `.focusSection()`) so the
// Home rails and the bottom tab strip become arrow-navigable, with Enter activating the focused item
// and Escape dropping focus to the tab strip.
//
// Everything here is gated behind `#if os(macOS)`. iPhone / iPad (the same source) and tvOS (its own
// focus engine in SourcesTV) are untouched. The APIs used are all pre-macOS-14 (`.focusable` macOS 12,
// `@FocusState`/`.focused` macOS 12, `.focusSection` macOS 13, `.onExitCommand` macOS 10.15,
// `.defaultFocus` macOS 13) so there is no `if #available` and no `.onKeyPress` (macOS-14-only) CI risk.
#if os(macOS)

/// The identity of the currently keyboard-focused browse element. Keyed on the engine's STABLE item id
/// (`RailItem.id`), not an array index, so async catalog growth (`core.boardRows` hydrating after
/// `onAppear`) never invalidates the focused target. The tab strip is keyed by `iOSRootView.Tab`'s raw
/// value. `Hashable` is required by `@FocusState`/`.focused(_:equals:)`.
enum MacBrowseFocus: Hashable {
    /// A poster card in a Home rail, identified by its rail id (the rail title) plus the item id.
    case card(rail: String, item: String)
    /// A bottom tab-strip item, by `iOSRootView.Tab.rawValue`.
    case tab(Int)
}

extension View {
    /// A visible focus ring for the keyboard-focused poster / tab, using only Theme accent tokens and
    /// compositor-friendly properties (transform + opacity + a stroked overlay, never layout), per
    /// DESIGN.md. Applied only on macOS and only when `isFocused`, so touch / VoiceOver never sees a ring.
    @ViewBuilder func macFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        let ringed = self
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.accent, lineWidth: isFocused ? 3 : 0)
            }
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .shadow(color: isFocused ? Theme.Palette.accent.opacity(0.35) : .clear, radius: 16, y: 6)
            .animation(Theme.Motion.focus, value: isFocused)
        // Suppress AppKit's default blue/grey focus ring so our accent ring is the ONLY focus cue (the
        // reported "weird blue selected line"). `.focusEffectDisabled()` is macOS 14+; the Mac target
        // deploys to 14, and the guard keeps CI safe on an older slice.
        if #available(macOS 14.0, *) {
            ringed.focusEffectDisabled()
        } else {
            ringed
        }
    }
}

#endif
