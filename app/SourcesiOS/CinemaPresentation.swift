import SwiftUI

/// The compact, data-honest title preview used by catalog cards. It deliberately renders only fields
/// already present on `RailItem`; the sheet is a navigation affordance, never a metadata fetcher.
struct CinemaQuickView: View {
    let item: RailItem
    let onWatch: () -> Void
    let onDetails: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var watchlistStatus: String?

    private var facts: [String] {
        [item.releaseInfo, item.imdbRating.map { "★ \($0)" }, item.type.capitalized]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                wideLayout
                compactLayout
            }
            .padding(Theme.Space.md)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick view for \(item.name)")
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            artwork
                .frame(width: 260, height: 390)
            copy
        }
        .frame(minWidth: 540, alignment: .leading)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            artwork.frame(maxWidth: .infinity).frame(height: 230)
            copy
        }
    }

    private var artwork: some View {
        ZStack {
            CachedPosterImage(url: item.background ?? item.poster)
                .scaledToFill()
                .overlay(Color.black.opacity(0.32))
            if let poster = item.poster, !poster.isEmpty {
                CachedPosterImage(url: poster)
                    .scaledToFill()
                    .frame(width: 132, height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(item.type.capitalized)
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.accent)
                .textCase(.uppercase)
            Text(item.name)
                .font(Theme.Typography.hero)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !facts.isEmpty {
                FlowLayout(spacing: Theme.Space.xs) {
                    ForEach(facts, id: \.self) { fact in
                        Text(fact)
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.horizontal, Theme.Space.sm)
                            .frame(minHeight: 30)
                            .vortxGlassChip(selected: false)
                    }
                }
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                Button {
                    dismiss()
                    onWatch()
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .vortxGlassProminent(in: Capsule())
                .accessibilityHint("Opens this title's playback options")

                Button {
                    let accepted = CoreBridge.shared.addToLibrary(
                        metaId: item.id,
                        expectedType: item.type,
                        fallbackPreview: .init(id: item.id, type: item.type, name: item.name, poster: item.poster)
                    )
                    // `addToLibrary` intentionally returns false for an overlay after it has updated that
                    // profile's local library. Report that route truthfully instead of presenting a false
                    // failure merely because no account-engine dispatch occurred.
                    watchlistStatus = accepted || !ProfileStore.shared.activeUsesEngineHistory
                        ? "Added to Watchlist"
                        : "Couldn't add to Watchlist"
                } label: {
                    Label("Watchlist", systemImage: "bookmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
                .accessibilityHint("Adds this title to your library")
            }
            if let watchlistStatus {
                Text(watchlistStatus)
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(watchlistStatus.hasPrefix("Added") ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            Button {
                dismiss()
                onDetails()
            } label: {
                Label("Details", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textSecondary)
            .accessibilityHint("Opens the full title page")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: item.id)
    }
}

/// A big, glass-backed entry card for Library destinations. The caller owns navigation; this type is only
/// presentation, so Downloads and future profile/library routes keep their existing values and actions.
struct CinemaLibraryEntryCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 52, height: 52)
                .vortxGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), shadow: .flat)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let badge { Text(badge).font(Theme.Typography.eyebrow).foregroundStyle(Theme.Palette.accent) }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .vortxCinemaCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Home's compact doorway into the existing Discover navigation stack. It is intentionally presentation
/// only: callers retain the real `HubTarget` value so pagination, category pills, and filter behavior live
/// in their established browse owner.
struct CinemaBrowseEntry: View {
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "safari.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 52, height: 52)
                .vortxGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), shadow: .flat)
            VStack(alignment: .leading, spacing: 3) {
                Text("Discover").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("Browse genres, services, and catalog filters")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .vortxCinemaCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
    }
}

/// Search is deliberately a result surface rather than another poster rail: its cards keep the actual
/// wide artwork, title, available facts, and synopsis together under the image at a readable scale.
struct CinemaSearchResults: View {
    let items: [RailItem]
    let onOpen: (RailItem) -> Void
    @AppStorage("vortx.quickViewEnabled") private var quickViewEnabled = true
    @State private var quickViewItem: RailItem?

    var body: some View {
        LazyVStack(spacing: Theme.Space.md) {
            ForEach(items) { item in
                Button {
                    if quickViewEnabled { quickViewItem = item } else { onOpen(item) }
                } label: {
                    CinemaSearchResultCard(item: item)
                }
                .buttonStyle(CardFocusStyle(scale: 1.015))
                .accessibilityLabel(item.name)
                .accessibilityHint(quickViewEnabled ? "Opens quick view" : "Opens details")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .sheet(item: $quickViewItem) { item in
            CinemaQuickView(item: item, onWatch: { onOpen(item) }, onDetails: { onOpen(item) })
        }
    }
}

private struct CinemaSearchResultCard: View {
    let item: RailItem

    private var facts: [String] {
        [item.releaseInfo, item.imdbRating.map { "★ \($0)" }, item.type.capitalized]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                artwork.frame(width: 260, height: 146)
                copy
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                artwork.frame(maxWidth: .infinity).frame(height: 190)
                copy
            }
        }
        .padding(Theme.Space.sm)
        .vortxCinemaCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
    }

    private var artwork: some View {
        CachedPosterImage(url: item.background ?? item.poster)
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.42)], startPoint: .center, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(Theme.Typography.eyebrow).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            if let description = item.description, !description.isEmpty {
                Text(description).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
