import SwiftUI

/// Live > TV guide on Apple TV: the shared guide grid; choosing a programme opens its channel's live page.
struct TVLiveGuideView: View {
    let channels: [LiveGuideChannel]
    @State private var opened: LiveGuideChannel?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("TV guide").screenTitleStyle()
            if channels.isEmpty {
                Text("No live channels yet. Add an IPTV playlist or a live TV add-on and its channels appear here.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            } else {
                LiveGuideGrid(channels: channels) { opened = $0 }
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge)
        .padding(.vertical, Theme.Space.lg)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationDestination(item: $opened) { channel in DetailView(type: channel.type, id: channel.id) }
    }
}
