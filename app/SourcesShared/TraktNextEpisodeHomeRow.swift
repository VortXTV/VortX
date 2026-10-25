import SwiftUI

/// A navigation value retains the original accepted offer without making provider DTOs hashable.
struct TraktNextEpisodeHomeRoute: Identifiable, Hashable {
    let id = UUID()
    let offer: TraktNextEpisodeOffer

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// These read-only episode offers are separate from paused playback and never seed artwork or heroes.
struct TraktNextEpisodeHomeRow: View {
    let offers: [TraktNextEpisodeOffer]
    let onOpen: (TraktNextEpisodeOffer) -> Void
    @EnvironmentObject private var theme: ThemeManager

    @MainActor
    static func permitsOpening(_ offer: TraktNextEpisodeOffer) -> Bool {
        offer.isCurrent()
            && offer.intent.source == .trakt
            && offer.intent.traktSessionID == offer.sessionID
            && TraktAuth.storedSessionID == offer.sessionID
            && offer.intent.permitsDetails(id: offer.target.metaID, type: offer.target.type,
                                           videoID: offer.target.videoID)
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        Theme.Space.screenEdge
        #else
        Theme.Space.md
        #endif
    }

    private var tileWidth: CGFloat {
        #if os(tvOS)
        320
        #else
        240
        #endif
    }

    var body: some View {
        let currentOffers = offers.filter(Self.permitsOpening)
        if !currentOffers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Next episodes from Trakt")
                    .font(.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, horizontalPadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                        ForEach(currentOffers) { offer in
                            Button {
                                guard Self.permitsOpening(offer) else { return }
                                onOpen(offer)
                            } label: {
                                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                                    Text(offer.name)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text("Season \(offer.target.season), episode \(offer.target.episode)")
                                        .font(.subheadline)
                                    Text("From Trakt")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .frame(width: tileWidth, alignment: .leading)
                                .padding(Theme.Space.md)
                                .background(Theme.Palette.surface1,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                            }
                            .buttonStyle(CardFocusStyle())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(offer.name), season \(offer.target.season), episode \(offer.target.episode), from Trakt")
                            .accessibilityHint("Opens episode details without starting playback")
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, Theme.Space.md)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The host attaches this destination outside its lazy content and retains its normal back handling.
struct TraktNextEpisodeHomeDestination: View {
    let offer: TraktNextEpisodeOffer

    @ViewBuilder var body: some View {
        if TraktNextEpisodeHomeRow.permitsOpening(offer) {
            #if os(tvOS)
            DetailView(type: offer.target.type, id: offer.target.metaID,
                       initialResumeSeconds: nil, initialVideoID: offer.target.videoID,
                       initialTraktSessionID: offer.sessionID,
                       initialContinueWatchingIntent: offer.intent,
                       initialTraktNextEpisodeOffer: offer)
            #else
            iOSDetailView(id: offer.target.metaID, type: offer.target.type, title: offer.name,
                          autoPlayOnAppear: false, initialResumeSeconds: nil,
                          initialVideoID: offer.target.videoID,
                          initialTraktSessionID: offer.sessionID,
                          initialContinueWatchingIntent: offer.intent,
                          initialTraktNextEpisodeOffer: offer)
            #endif
        } else {
            Text("This episode offer is no longer current. Return to Home to refresh.")
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(Theme.Space.md)
        }
    }
}
