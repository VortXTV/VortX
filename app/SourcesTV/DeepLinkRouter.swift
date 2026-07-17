import SwiftUI

/// Routes an inbound `vortx://` link into the running shell.
///
/// Today the only source of these links is the Top Shelf extension handing back a tap, but the
/// scheme is the app's front door in general, so the plumbing is kept generic: `StremioTVApp`'s
/// `onOpenURL` parses the URL and parks the destination here, and `RootView` presents it.
///
/// A pending destination is held rather than acted on, because a link can arrive at ANY moment,
/// including during a cold launch triggered BY the link, before the shell has mounted or a profile
/// has been picked. Parking it lets the presenter decide when it is safe to show, and lets the
/// splash and the profile picker run first.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    private init() {}

    /// The title a link asked us to open, or nil. `RootView` presents this and clears it on dismiss.
    @Published var detailTarget: DeepLinkDetailTarget?

    /// Handle an inbound URL. Ignores anything that is not one of ours, so an unrelated URL handed to
    /// `onOpenURL` is a no-op.
    func handle(_ url: URL) {
        guard let link = TopShelfSnapshot.parse(url) else {
            DiagnosticsLog.log("deeplink", "ignored (not ours): \(url.scheme ?? "-")://\(url.host ?? "-")")
            return
        }
        switch link {
        case let .open(type, id):
            DiagnosticsLog.log("deeplink", "open detail type=\(type) id=\(id)")
            detailTarget = DeepLinkDetailTarget(id: id, type: type)
        }
    }
}

/// A detail page a deep link asked for. Mirrors `CWDetailTarget` (the Continue Watching rail's
/// long-press target); kept separate so the router owns a type that is not tied to a rail's view.
struct DeepLinkDetailTarget: Identifiable, Hashable {
    let id: String
    let type: String
}
