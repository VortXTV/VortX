import SwiftUI

/// Live > TV guide on iPhone, iPad and Mac: the shared guide grid; tapping a programme opens its channel.
struct iOSLiveGuideView: View {
    let channels: [LiveGuideChannel]
    let onOpen: (LiveGuideChannel) -> Void

    var body: some View {
        Group {
            if channels.isEmpty {
                Text("No live channels yet. Add an IPTV playlist or a live TV add-on and its channels appear here.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                LiveGuideGrid(channels: channels, onOpen: onOpen)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(Text("TV guide"))
    }
}
