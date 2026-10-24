import SwiftUI

extension RandomPickPolicy.EpisodeSource {
    init(_ meta: CoreMetaItem) {
        self.init(identity: .init(type: meta.type, id: meta.id), name: meta.name,
                  poster: meta.poster, background: meta.background, videos: meta.videos ?? [])
    }
}

struct RandomPickLibraryRoute {
    let ticket: RandomPickPolicy.Ticket
    let item: CoreCWItem
    let access: RandomPickUIAccess
    let autoPlay: Bool
    var intent: RandomPickPlayIntent? = nil
}

struct RandomPickEpisodeRoute {
    let ticket: RandomPickPolicy.Ticket
    let meta: CoreMetaItem
    let video: CoreVideo
    let orderedEpisodes: [CoreVideo]
    let access: RandomPickUIAccess
    let autoPlay: Bool
    var intent: RandomPickPlayIntent? = nil
}

/// Uses the existing theme and focusable button styles. Vertical actions also
/// accommodate compact phones, long labels and accessibility text sizes.
struct RandomPickPreviewCard: View {
    let ticket: RandomPickPolicy.Ticket
    let onOpen: () -> Void
    var onPlay: (() -> Void)? = nil
    let onPickAgain: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Label("Random pick", systemImage: "shuffle")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.accent)
                Text(ticket.record.title)
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ticket.record.subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Button(action: onOpen) { Label("Open", systemImage: "arrow.right") }
                        .buttonStyle(ChipButtonStyle())
                    if let onPlay {
                        Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(PrimaryActionStyle())
                    }
                    Button(action: onPickAgain) { Label("Pick again", systemImage: "shuffle") }
                        .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}
