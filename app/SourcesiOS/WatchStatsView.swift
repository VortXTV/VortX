import SwiftUI

/// Personal watch stats / year in review, reached from Settings on iPhone / iPad / Mac (SourcesiOS, which
/// the VortXMac target reuses). Everything it shows is computed READ ONLY from the active profile's existing
/// watch history by `WatchStatsModel`; this screen never marks, resumes, or writes any watched state.
///
/// Editorial layout: a big serif headline number (hours watched) anchors the scope, a compact stat grid
/// gives the movie / series / episode split, then the longest binge, the top genres, and the most-watched
/// titles. A scope menu switches between all-time and any year present in the history.
struct WatchStatsView: View {
    @StateObject private var model = WatchStatsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                scopePicker

                if model.isLoading && model.stats == nil {
                    loading
                } else if let stats = model.stats, stats.hasData {
                    hero(stats)
                    statGrid(stats)
                    if let binge = stats.longestBinge { bingeCard(binge) }
                    if !stats.topGenres.isEmpty { genresCard(stats) }
                    if !stats.topTitles.isEmpty { mostWatchedCard(stats) }
                } else {
                    emptyState
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Watch Stats")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { model.load() }
    }

    // MARK: Scope

    private var scopeLabel: String { model.selectedYear.map(String.init) ?? String(localized: "All time") }

    private var scopePicker: some View {
        Menu {
            Button(String(localized: "All time")) { model.selectedYear = nil }
            if !model.availableYears.isEmpty { Divider() }
            ForEach(model.availableYears, id: \.self) { year in
                Button(String(year)) { model.selectedYear = year }
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "calendar")
                Text(scopeLabel)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(Theme.Typography.label.weight(.semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
            .background(
                Capsule(style: .continuous).fill(Theme.Palette.surface2)
                    .overlay(Capsule(style: .continuous).stroke(Theme.Palette.hairline, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: Hero

    private func hero(_ stats: WatchStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stats.scopeLabel.uppercased())
                .eyebrowStyle(Theme.Palette.accent)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(heroValue(stats.totalWatchSeconds))
                    .font(Theme.Typography.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(heroUnit(stats.totalWatchSeconds))
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text("watched across \(stats.titlesCount) \(stats.titlesCount == 1 ? "title" : "titles")")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Stat grid

    private func statGrid(_ stats: WatchStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm),
                            GridItem(.flexible(), spacing: Theme.Space.sm)], spacing: Theme.Space.sm) {
            statTile(value: "\(stats.moviesCount)", label: "Movies", icon: "film")
            statTile(value: "\(stats.seriesCount)", label: "Series", icon: "tv")
            statTile(value: "\(stats.episodesCount)", label: "Episodes", icon: "rectangle.stack.fill")
            statTile(value: compactHM(stats.totalWatchSeconds), label: "Total time", icon: "clock")
        }
    }

    private func statTile(value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(value)
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(Theme.Space.sm)
        .background(cardBackground)
    }

    // MARK: Longest binge

    private func bingeCard(_ binge: BingeStat) -> some View {
        card(title: "Longest Binge", icon: "flame.fill") {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(binge.name)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                    Text(bingeSubtitle(binge))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: binge.type == "series" ? "tv" : "film")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.Palette.accentSoft)
            }
        }
    }

    private func bingeSubtitle(_ binge: BingeStat) -> String {
        if binge.episodes > 0 {
            return "\(binge.episodes) \(binge.episodes == 1 ? "episode" : "episodes") · \(compactHM(binge.seconds))"
        }
        return compactHM(binge.seconds)
    }

    // MARK: Top genres

    private func genresCard(_ stats: WatchStats) -> some View {
        let peak = stats.topGenres.map(\.seconds).max() ?? 1
        return card(title: "Top Genres", icon: "theatermasks.fill") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(stats.topGenres) { genre in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(genre.name)
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                            Text(compactHM(genre.seconds))
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        StatBar(fraction: peak > 0 ? genre.seconds / peak : 0)
                    }
                }
                if stats.genreCoverage < stats.titlesCount {
                    Text("Based on the \(stats.genreCoverage) of \(stats.titlesCount) titles VortX has genre data for.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Most watched

    private func mostWatchedCard(_ stats: WatchStats) -> some View {
        card(title: "Most Watched", icon: "chart.bar.fill") {
            VStack(spacing: 0) {
                ForEach(Array(stats.topTitles.enumerated()), id: \.element.id) { index, title in
                    if index > 0 { Divider().overlay(Theme.Palette.hairline) }
                    mostWatchedRow(rank: index + 1, title: title)
                }
            }
        }
    }

    private func mostWatchedRow(rank: Int, title: TitleStat) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text("\(rank)")
                .font(Theme.Typography.cardTitle.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 22, alignment: .trailing)
            PosterThumb(poster: title.poster)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.name)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(rowSubtitle(title))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer(minLength: 0)
            Text(compactHM(title.seconds))
                .font(Theme.Typography.label.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.accent)
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func rowSubtitle(_ title: TitleStat) -> String {
        if title.type == "series" {
            return "\(title.plays) \(title.plays == 1 ? "episode" : "episodes")"
        }
        return title.plays > 1 ? "Movie · \(title.plays)×" : "Movie"
    }

    // MARK: States

    private var loading: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "chart.pie")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No watch history yet")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(emptyMessage)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(Theme.Space.lg)
    }

    private var emptyMessage: String {
        model.selectedYear == nil
            ? String(localized: "Watch something and your stats will show up here.")
            : String(localized: "Nothing watched in \(scopeLabel). Try another year.")
    }

    // MARK: Card chrome

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.Palette.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.Palette.hairline, lineWidth: 1)
            )
    }

    private func card<Content: View>(title: LocalizedStringKey, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(title).eyebrowStyle()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(cardBackground)
    }

    // MARK: Formatting

    /// The big headline number: hours when there is at least an hour (one decimal below 10h, whole above),
    /// otherwise minutes. Pairs with `heroUnit`.
    private func heroValue(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 1 {
            return hours >= 10 ? String(Int(hours.rounded())) : String(format: "%.1f", hours)
        }
        return String(Int((seconds / 60).rounded()))
    }

    private func heroUnit(_ seconds: Double) -> String {
        seconds >= 3600 ? String(localized: "hours") : String(localized: "minutes")
    }

    /// Compact "12h 30m" / "45m" / "0m" for a duration in seconds. Used on cards and rows.
    private func compactHM(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Small subviews

/// A horizontal magnitude bar (track + accent fill) for the top-genres card.
private struct StatBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Theme.Palette.surface2)
                Capsule(style: .continuous).fill(Theme.Palette.accent)
                    .frame(width: max(6, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 8)
    }
}

/// A small poster thumbnail for the most-watched rows, with a neutral placeholder while / if the image is
/// missing. Uses `AsyncImage` (the app's standard remote-image loader for incidental art).
private struct PosterThumb: View {
    let poster: String?

    var body: some View {
        AsyncImage(url: poster.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(Theme.Palette.surface2)
                    .overlay(Image(systemName: "film").font(.footnote).foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: 42, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.Palette.hairline, lineWidth: 1))
    }
}
