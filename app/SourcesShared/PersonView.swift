import SwiftUI

/// The Person page: tap a cast member on any detail screen and land here. The header paints the name and
/// headshot INSTANTLY from the tapped `CastMember` (no spinner on the thing you just tapped), then streams
/// the biography, birthday, birthplace and full filmography from TMDB through the SAME keyless catalog edge
/// the rest of the app uses (no user key required, fail-soft). Filmography tiles push straight back into a
/// title detail page, so you can walk actor -> film -> co-star -> ...
///
/// Lives in `SourcesShared` so tvOS, iOS and macOS share ONE implementation. The filmography grid and the
/// downstream detail push branch per platform exactly where the detail views already diverge: tvOS reuses
/// `PosterCard` (self-navigating to `DetailView`, its stream path tolerates a `tmdb:` id); iOS/macOS reuse
/// `PosterCardiOS` and resolve `tmdb:` -> `tt` BEFORE pushing `iOSDetailView` (the same fail-soft resolve the
/// hub grids use), so the pushed detail hero, ratings and Play button are not gated dark on a hub id.
struct PersonView: View {
    let personID: Int
    private let seedName: String
    private let seedProfileURL: String?

    @State private var detail: TMDBClient.PersonDetail?
    @State private var credits: [MetaPreview] = []
    @State private var didLoadDetail = false
    @State private var didLoadCredits = false
    @State private var bioExpanded = false

    // The filmography grid derives its column width from the user's Poster Style preset, so it stays in
    // lockstep with the hub grids (both platforms do this; PosterCard[iOS] read the same preset for card width).
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    #if !os(tvOS)
    // iOS / macOS resolve-before-push target for a tapped filmography tile.
    @State private var filmoTarget: MetaPreview?
    @State private var showFilmo = false
    @State private var resolvingFilmo = false
    #endif

    init(personID: Int, name: String, profileURL: String?) {
        self.personID = personID
        self.seedName = name
        self.seedProfileURL = profileURL
    }

    // The name/photo shown: the freshly loaded person record when it lands, else the seed we were handed,
    // so the header is fully painted the instant the page appears.
    private var displayName: String { detail?.name ?? seedName }
    private var photoURL: String? { detail?.profileURL ?? seedProfileURL }

    #if os(tvOS)
    private let photoSize: CGFloat = 200
    #else
    private let photoSize: CGFloat = 116
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                biographySection
                filmographySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { await load() }
        #if !os(tvOS)
        .navigationDestination(isPresented: $showFilmo) {
            if let m = filmoTarget {
                iOSDetailView(id: m.id, type: m.type, title: m.name)
            }
        }
        #endif
    }

    // MARK: Header (instant paint: photo + serif name, then bio meta streams in)

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            headshot
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let dept = detail?.knownForDepartment {
                    Text(dept.uppercased())
                        .font(Theme.Typography.eyebrow).tracking(1.5)
                        .foregroundStyle(Theme.Palette.accent)
                }
                // The serif name is the editorial signature, mirroring the detail-page hero title.
                Text(displayName)
                    .font(Theme.Typography.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(3).minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                if let born = bornLine {
                    Text(born)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var headshot: some View {
        AsyncImage(url: URL(string: photoURL ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Theme.Palette.surface2
                    Text(initials(displayName))
                        .font(Theme.Typography.sectionTitle.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .frame(width: photoSize, height: photoSize)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.Palette.textPrimary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    /// "Born Mar 1, 1970 · London, England", assembled from whichever parts TMDB returned.
    private var bornLine: String? {
        let parts = [detail?.birthday.map { "Born \($0)" }, detail?.placeOfBirth].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }

    // MARK: Biography (collapsible, mirrors the Cast & Crew disclosure interaction)

    @ViewBuilder private var biographySection: some View {
        if let bio = detail?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { bioExpanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        sectionHeader("Biography")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .rotationEffect(.degrees(bioExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Biography")
                .accessibilityHint(bioExpanded ? "Collapse" : "Expand")
                Text(bio)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Filmography (grid of the person's other titles)

    @ViewBuilder private var filmographySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionHeader("Filmography")
            if !credits.isEmpty {
                filmographyGrid
            } else if !didLoadCredits {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text("No filmography available.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(tvOS)
    // Fixed-cell columns matching the poster/landscape preset, so PosterCard fills its cell exactly (a
    // fixed-cell caller MUST pass its cell width, else the preset overflows and cards overlap: #28/#104).
    private var filmographyColumns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(TVGridMetrics.landscapeCellWidth), spacing: Theme.Space.lg), count: TVGridMetrics.landscapeColumns)
            : Array(repeating: GridItem(.fixed(TVGridMetrics.posterCellWidth), spacing: Theme.Space.lg), count: TVGridMetrics.posterColumns)
    }

    private var filmographyGrid: some View {
        LazyVGrid(columns: filmographyColumns, spacing: Theme.Space.xl) {
            ForEach(credits) { item in
                // PosterCard self-navigates to DetailView; the tvOS stream path resolves a tmdb: id directly.
                PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                           width: TVGridMetrics.posterCellWidth, landscapeWidth: TVGridMetrics.landscapeCellWidth)
            }
        }
    }
    #else
    // Adaptive columns whose track width is the SAME preset PosterCardiOS sizes its card from, so grid and
    // cards stay in lockstep and the column count recomputes from the user's Poster Style setting (mirrors
    // the hub grid at iOSCatalogGrid).
    private var filmographyColumns: [GridItem] {
        #if os(iOS)
        let compact = hSize == .compact
        #else
        let compact = false
        #endif
        let minTrack = iOSPillMetrics.gridPosterWidth(preset: catalogPrefs.posterWidth, compact: compact)
        return [GridItem(.adaptive(minimum: minTrack), spacing: Theme.Space.sm, alignment: .center)]
    }

    private var filmographyGrid: some View {
        LazyVGrid(columns: filmographyColumns, alignment: .center, spacing: Theme.Space.md) {
            ForEach(credits) { item in
                Button { openFilmography(item) } label: {
                    PosterCardiOS(id: item.id, type: item.type, name: item.name,
                                  poster: item.poster, progress: 0)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Resolve tmdb: -> tt BEFORE pushing, the same fail-soft resolve the hub grids use (push the unresolved
    /// id if the lookup fails, so the detail page still opens). Guarded so a rapid double-tap can't push twice.
    private func openFilmography(_ item: MetaPreview) {
        guard !resolvingFilmo else { return }
        resolvingFilmo = true
        Task { @MainActor in
            let tt = await TMDBClient.imdbID(forCatalogID: item.id, type: item.type)
            resolvingFilmo = false
            filmoTarget = tt.map {
                MetaPreview(id: $0, type: item.type, name: item.name,
                            poster: item.poster, posterShape: item.posterShape, popularity: item.popularity)
            } ?? item
            showFilmo = true
        }
    }
    #endif

    // MARK: Section header (self-contained; the per-platform rail headers are file-private)

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.sectionTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    // MARK: Load (fail-soft; header is already painted from the seed, so this only enriches)

    private func load() async {
        // Guard so a re-appear (e.g. returning from a pushed filmography title) does not refetch.
        if !didLoadDetail {
            let loaded = await TMDBClient.person(id: personID)
            await MainActor.run {
                if let loaded { detail = loaded }
                didLoadDetail = true
            }
        }
        if !didLoadCredits {
            let loaded = await TMDBClient.personCredits(id: personID)
            await MainActor.run {
                credits = loaded
                didLoadCredits = true
            }
        }
    }
}
