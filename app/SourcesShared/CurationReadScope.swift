import SwiftUI

/// Every pushed grid/All destination observes the original read owner itself. Clearing this content
/// does not depend on SwiftUI removing the ancestor NavigationLink that originally created it.
@MainActor struct CurationReadScope<Content: View>: View {
    let ticket: CurationReadTicket
    @ObservedObject private var lifetime: CurationReadLifetime
    @ObservedObject private var store = ForYouStore.shared
    let content: () -> Content

    init(ticket: CurationReadTicket, @ViewBuilder content: @escaping () -> Content) {
        self.ticket = ticket; self.content = content
        _lifetime = ObservedObject(wrappedValue: ticket.lifetime)
    }

    var body: some View {
        Group {
            if ticket.isCurrent && ticket.artworkLifetime.isActive && store.ready {
                content()
            } else {
                Text("These collections changed or belong to another profile. Return to Collections and reload.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(Theme.Space.screenInset)
            }
        }
        #if os(macOS)
        .macBackAffordance()
        #endif
    }
}
