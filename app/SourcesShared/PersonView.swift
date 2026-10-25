import SwiftUI

/// The Person page: tap a cast member on any detail screen and land here. The header paints the name and
/// headshot INSTANTLY from the tapped `CastMember` (no spinner on the thing you just tapped), then streams
/// the biography, birth details, links and full filmography from TMDB through the SAME keyless catalog edge
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
    @State private var credits: [TMDBClient.PersonCredit] = []
    @State private var didLoadDetail = false
    @State private var didLoadCredits = false
    @State private var bioExpanded = false
    @State private var filter: FilmographyFilter = .all

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
    /// The page width, published to the cards so a landscape Poster Style sizes them like the catalogue grid.
    @State private var viewportWidth: CGFloat = 0
    #endif

    init(personID: Int, name: String, profileURL: String?) {
        self.personID = personID
        self.seedName = name
        self.seedProfileURL = profileURL
    }

    enum FilmographyFilter: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", shows = "Shows"
        var id: String { rawValue }
        func admits(_ credit: TMDBClient.PersonCredit) -> Bool {
            switch self {
            case .all: return true
            case .movies: return credit.preview.type == "movie"
            case .shows: return credit.preview.type == "series"
            }
        }
    }

    // The name/photo shown: the freshly loaded person record when it lands, else the seed we were handed,
    // so the header is fully painted the instant the page appears.
    private var displayName: String { detail?.name ?? seedName }
    private var photoURL: String? { detail?.profileURL ?? seedProfileURL }
    private var visibleCredits: [TMDBClient.PersonCredit] { credits.filter(filter.admits) }
    /// The filter only appears when it can actually narrow the list (a person with both movies and shows).
    private var offersFilter: Bool {
        credits.contains { $0.preview.type == "movie" } && credits.contains { $0.preview.type == "series" }
    }

    private var isCompact: Bool {
        #if os(iOS)
        return hSize == .compact
        #else
        return false
        #endif
    }

    #if os(tvOS)
    private let portraitWidth: CGFloat = 260
    #else
    private var portraitWidth: CGFloat { isCompact ? 112 : 200 }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
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
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { viewportWidth = geometry.size.width }
                    .onValueChange(of: geometry.size.width) { viewportWidth = $0 }
            }
        }
        .environment(\.cinemaCardViewportWidth, viewportWidth)
        .navigationDestination(isPresented: $showFilmo) {
            if let m = filmoTarget {
                iOSDetailView(id: m.id, type: m.type, title: m.name)
            }
        }
        #endif
    }

    // MARK: Header (instant paint: portrait + serif name, then birth details, links and biography stream in)

    @ViewBuilder private var header: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    portrait
                    identity
                }
                biography
            }
        } else {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                portrait
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    identity
                    biography
                }
                .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    private var identity: some View {
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
            if let born = PersonLifeLine.describe(detail) {
                Text(born)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            links
        }
    }

    /// A 2:3 portrait card, the same shape as the posters below it, so the page reads as one gallery.
    private var portrait: some View {
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
        .frame(width: portraitWidth, height: portraitWidth * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.Palette.textPrimary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .accessibilityHidden(true)
    }

    /// IMDb and TMDB pages for the person. Apple TV has no browser, so the links are touch/pointer only.
    @ViewBuilder private var links: some View {
        #if !os(tvOS)
        let imdb = detail?.imdbID.flatMap { URL(string: "https://www.imdb.com/name/\($0)/") }
        let tmdb = personID > 0 ? URL(string: "https://www.themoviedb.org/person/\(personID)") : nil
        if imdb != nil || tmdb != nil {
            HStack(spacing: Theme.Space.sm) {
                if let imdb { Link("IMDb", destination: imdb).buttonStyle(ChipButtonStyle(selected: false)) }
                if let tmdb { Link("TMDB", destination: tmdb).buttonStyle(ChipButtonStyle(selected: false)) }
            }
            .padding(.top, Theme.Space.xs)
        }
        #endif
    }

    @ViewBuilder private var biography: some View {
        if let bio = detail?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(bio)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(bioExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                if bio.count > 320 {
                    Button(bioExpanded ? "Less" : "More") {
                        withAnimation(.easeOut(duration: 0.25)) { bioExpanded.toggle() }
                    }
                    .font(Theme.Typography.label.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    // tvOS: the ember ring is the focus affordance of this text-only control.
                    .vortxCardButton(radius: Theme.Radius.chip)
                    .accessibilityHint(bioExpanded ? "Shows less of the biography" : "Shows the full biography")
                }
            }
        }
    }

    // MARK: Filmography (count, All / Movies / Shows, newest first)

    @ViewBuilder private var filmographySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text("Filmography")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !credits.isEmpty {
                    Text("\(visibleCredits.count)")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: Theme.Space.md)
                if offersFilter { filterControl }
            }
            if !visibleCredits.isEmpty {
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

    private var filterControl: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(FilmographyFilter.allCases) { option in
                Button(LocalizedStringKey(option.rawValue)) {
                    withAnimation(.easeOut(duration: 0.2)) { filter = option }
                }
                .buttonStyle(ChipButtonStyle(selected: filter == option))
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filmography filter")
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
            ForEach(visibleCredits) { credit in
                let item = credit.preview
                // PosterCard self-navigates to DetailView; the tvOS stream path resolves a tmdb: id directly.
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                               width: TVGridMetrics.posterCellWidth, landscapeWidth: TVGridMetrics.landscapeCellWidth)
                    if let year = credit.year {
                        Text(year)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
        }
    }
    #else
    // Adaptive columns whose track width is the SAME preset PosterCardiOS sizes its card from, so grid and
    // cards stay in lockstep and the column count recomputes from the user's Poster Style setting (mirrors
    // the hub grid at iOSCatalogGrid).
    private var filmographyColumns: [GridItem] {
        // Landscape follows the user's Poster Style exactly like the catalogue grid (16:9 backdrops resolved
        // by id); portrait keeps the preset poster width.
        let minTrack = iOSPillMetrics.gridPosterWidth(preset: catalogPrefs.posterWidth, compact: isCompact,
                                                      container: viewportWidth,
                                                      landscape: catalogPrefs.landscapeCards && apiKeys.hasTMDB)
        return [GridItem(.adaptive(minimum: minTrack), spacing: Theme.Space.sm, alignment: .top)]
    }

    private var filmographyGrid: some View {
        LazyVGrid(columns: filmographyColumns, alignment: .center, spacing: Theme.Space.md) {
            ForEach(visibleCredits) { credit in
                let item = credit.preview
                Button { openFilmography(item) } label: {
                    PosterCardiOS(id: item.id, type: item.type, name: item.name,
                                  poster: item.poster, releaseInfo: credit.year, progress: 0)
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

/// "Born 1 September 1996 (age 30) in Oakland, California, USA", or "Born … in … · Died … (aged 67)",
/// assembled from whichever parts TMDB returned. Pure, so the age arithmetic is testable.
enum PersonLifeLine {
    static func describe(_ detail: TMDBClient.PersonDetail?, now: Date = Date(),
                         calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        guard let detail else { return nil }
        let born = date(detail.birthdayISO)
        let died = date(detail.deathdayISO)
        var birth: [String] = []
        if let born {
            var text = "Born \(display(born))"
            if died == nil, let age = years(from: born, to: now, calendar: calendar) { text += " (age \(age))" }
            birth.append(text)
        } else if let pretty = detail.birthday {
            birth.append("Born \(pretty)")
        }
        if let place = detail.placeOfBirth {
            birth.append(birth.isEmpty ? place : "in \(place)")
        }
        var parts: [String] = []
        if !birth.isEmpty { parts.append(birth.joined(separator: " ")) }
        if let died {
            var text = "Died \(display(died))"
            if let born, let age = years(from: born, to: died, calendar: calendar) { text += " (aged \(age))" }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }

    static func years(from start: Date, to end: Date, calendar: Calendar) -> Int? {
        guard end >= start else { return nil }
        return calendar.dateComponents([.year], from: start, to: end).year
    }

    private static func date(_ iso: String?) -> Date? {
        guard let iso, iso.count == 10 else { return nil }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: iso)
    }

    private static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
