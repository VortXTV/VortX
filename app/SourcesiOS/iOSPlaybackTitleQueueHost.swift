#if os(iOS) || os(macOS)
import SwiftUI

/// One queue presenter, outside each tab's independent NavigationStack. Source resolution remains in Detail.
/// Dismiss the previous detail only after its nested/hoisted player closes, then acknowledge that exact
/// dismissal before presenting a successor. A late nil binding can never consume a newer queue route.
@MainActor
struct iOSPlaybackTitleQueueHost: ViewModifier {
    private enum Destination: Identifiable {
        case editor(UUID)
        case detail(PlaybackTitleQueue.Route)
        var id: UUID {
            switch self { case .editor(let id): id; case .detail(let route): route.id }
        }
    }

    @ObservedObject private var queue = PlaybackTitleQueue.shared
    @ObservedObject private var gate = FullscreenPlaybackGate.shared
    @EnvironmentObject private var profiles: ProfileStore
    @State private var presented: Destination?
    @State private var dismissing: Destination?

    func body(content: Content) -> some View {
        content
            .sheet(item: presentation, onDismiss: didDismiss) { destination in
                NavigationStack {
                    switch destination {
                    case .editor:
                        PlaybackTitleQueueEditor()
                    case .detail(let route):
                        iOSDetailView(id: route.entry.candidate.contentID,
                                      type: route.entry.candidate.type,
                                      title: route.entry.candidate.title,
                                      autoPlayOnAppear: true,
                                      randomPickPlayIntent: route.intent,
                                      playbackQueueToken: route.token,
                                      initialVideoID: route.entry.candidate.videoIDHint)
                            .safeAreaInset(edge: .top) { PlaybackTitleQueueRouteActions(routeID: route.id) }
                    }
                }
                .interactiveDismissDisabled(gate.playerActive)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 600)
                #endif
            }
            .modifier(PlaybackTitleQueueBoundaryObserver())
            .onAppear { synchronize() }
            .onValueChange(of: queue.change) { _ in synchronize() }
            .onValueChange(of: gate.activePlayers) { _ in synchronize() }
            .onValueChange(of: profiles.needsPicker) { _ in synchronize() }
    }

    private var presentation: Binding<Destination?> {
        let expectedID = presented?.id
        return Binding(get: { presented }, set: { value in
            // SwiftUI writes nil for an interactive or environment-dismissal. Only this presentation
            // moves to the acknowledgement slot; replacement is never performed in this setter.
            guard case nil = value, let current = presented, current.id == expectedID else { return }
            dismissing = current
            presented = nil
            // Cancel at the user's dismissal action, not after the animation: source resolution may
            // otherwise finish in that interval. Host-initiated dismissals use synchronize directly.
            switch current {
            case .editor(let id): queue.dismissEditor(id)
            case .detail(let route): queue.dismissRoute(route.id)
            }
        })
    }

    private var requested: Destination? {
        if let id = queue.editorID { return .editor(id) }
        if let route = queue.route { return .detail(route) }
        return nil
    }

    private func synchronize() {
        queue.invalidateIfNeeded()
        guard !gate.playerActive else { return } // keep the exact outer Detail alive while its player owns it
        let desired = profiles.needsPicker ? nil : requested
        if let current = presented {
            guard current.id != desired?.id else { return }
            dismissing = current
            presented = nil
            return
        }
        guard case nil = dismissing else { return }
        presented = desired
    }

    private func didDismiss() {
        guard let old = dismissing else { return }
        dismissing = nil
        switch old {
        case .editor(let id): queue.dismissEditor(id)
        case .detail(let route): queue.dismissRoute(route.id)
        }
        synchronize()
    }
}
#endif
