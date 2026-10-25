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


/// Presentation-only preview from Home's resident public shelves. No source or playback authority.
struct HomeSurpriseItem {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let releaseInfo: String?

    init(_ meta: CoreMeta) {
        id = meta.id; type = meta.type; name = meta.name; poster = meta.poster
        background = meta.background; logo = meta.logo; releaseInfo = meta.releaseInfo
    }
    init(_ meta: MetaPreview) {
        id = meta.id; type = meta.type; name = meta.name; poster = meta.poster
        background = nil; logo = nil; releaseInfo = nil
    }
    var homeRecord: RandomPickPolicy.HomeRecord {
        .init(record: .init(identity: .init(type: type, id: id), title: name,
                            subtitle: type.capitalized, metadata: [poster, background, logo, releaseInfo]),
              releaseInfo: releaseInfo)
    }
}

struct HomeSurprisePool {
    var recommendations: [HomeSurpriseItem] = []
    var catalogs: [HomeSurpriseItem] = []
}

struct HomeSurpriseRoute: Identifiable, Hashable {
    let id = UUID()
    let item: HomeSurpriseItem
    let access: RandomPickUIAccess
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Shared touch/desktop/TV action. Build the pool only on a deliberate tap, never in body.
/// A choice opens the normal detail screen; it neither resolves nor auto-plays a source.
struct HomeSurpriseButton: View {
    var isActive = true
    let candidates: () -> HomeSurprisePool
    let onOpen: (HomeSurpriseRoute) -> Void
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var core: CoreBridge
    @State private var session = RandomPickPolicy.Session()
    @State private var message: String?

    var body: some View {
        Button(action: choose) { Label("Surprise me", systemImage: "shuffle") }
            .buttonStyle(ChipButtonStyle())
            .disabled(!isActive)
            .accessibilityHint(Text("Let VortX choose a movie or show from your Home recommendations and catalogs"))
            .alert("Surprise me", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
    }

    private func choose() {
        guard isActive, let access = RandomPickUIAccess.capture(profiles: profiles, core: core) else {
            message = String(localized: "Choose a profile and let Home finish loading, then try again.")
            return
        }
        let pool = candidates()
        let records = RandomPickPolicy.homeRecords(recommendations: pool.recommendations.map(\.homeRecord),
            catalogs: pool.catalogs.map(\.homeRecord), watchedIDs: WatchedIndex.shared.ids, now: Date())
        var generator = SystemRandomNumberGenerator()
        guard let ticket = session.select(records, profileID: profiles.activeID, scope: "home", using: &generator),
              let item = (pool.recommendations + pool.catalogs).first(where: { $0.homeRecord.record == ticket.record }),
              access.isCurrent(profiles: profiles, core: core) else {
            message = String(localized: "No unwatched movies or shows are ready on Home yet. Let your catalogs load, then try again.")
            return
        }
        onOpen(HomeSurpriseRoute(item: item, access: access))
    }
}

/// Retire an accepted route on account/profile/Kids/PIN changes, like the existing Library pick.
struct HomeSurpriseDestination: View {
    let route: HomeSurpriseRoute
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var core: CoreBridge
    var body: some View {
        if route.access.isNavigationCurrent(profiles: profiles, core: core) {
            #if os(tvOS)
            DetailView(type: route.item.type, id: route.item.id)
            #else
            iOSDetailView(id: route.item.id, type: route.item.type, title: route.item.name,
                          seedBackdrop: route.item.background, seedLogo: route.item.logo)
            #endif
        }
    }
}
