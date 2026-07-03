import SwiftUI

/// tvOS Settings screen that tunes how catalog poster cards look: WIDTH preset, corner RADIUS preset, a
/// portrait-vs-landscape (16:9) art toggle, and a hide-labels toggle. A LIVE PREVIEW poster at the top
/// redraws as each control changes so the effect is visible before leaving the screen. Every control is
/// two-way bound to the shared `CatalogPreferences` (the SAME model + UserDefaults keys the iOS/Mac
/// `iOSPosterStyleView` binds), which persists and republishes so the real Home / Discover / Library grids
/// re-lay out immediately. Defaults reproduce today's look, so nothing changes unless the user opts in.
///
/// Focus-driven: mirrors `SettingsView`'s chip-scroller `choiceRow` pattern (each row its own focus section)
/// so D-pad focus steps cleanly between the width / radius / landscape / labels rows.
struct TVPosterStyleView: View {
    @ObservedObject private var prefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Poster Style").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)

                TVPosterStylePreview()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.screenEdge)

                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    // Poster width preset (`stremiox.catalog.posterWidthPreset`). Balanced = today's look.
                    choiceRow(String(localized: "Width"),
                              PosterWidthPreset.allCases.map { ($0.rawValue, $0.label) },
                              selection: Binding(get: { prefs.posterWidth.rawValue },
                                                 set: { prefs.posterWidth = PosterWidthPreset(rawValue: $0) ?? .balanced }))
                    // Poster corner-radius preset (`stremiox.catalog.posterRadiusPreset`). Rounded = today's look.
                    choiceRow(String(localized: "Corner radius"),
                              PosterRadiusPreset.allCases.map { ($0.rawValue, $0.label) },
                              selection: Binding(get: { prefs.posterRadius.rawValue },
                                                 set: { prefs.posterRadius = PosterRadiusPreset(rawValue: $0) ?? .rounded }))
                    Text("Width sets how large posters are and how many fit per row. Balanced and Rounded match the default look.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Space.screenEdge)

                    // Landscape 16:9 art (`stremiox.catalog.landscapeCards`) needs a TMDB key (a clean
                    // backdrop); without one the row is disabled and posters stay portrait, so keyless users
                    // never get a degraded composite. This is the SAME toggle surfaced inline in Appearance as
                    // "Cinematic catalog cards".
                    choiceRow(String(localized: "Landscape (16:9) art"),
                              [("1", String(localized: "On")), ("0", String(localized: "Off"))],
                              selection: Binding(get: { prefs.landscapeCards ? "1" : "0" },
                                                 set: { prefs.landscapeCards = ($0 == "1") }),
                              disabled: !apiKeys.hasTMDB)
                    // Hide the title label under each poster (`stremiox.catalog.hidePosterLabels`). Also
                    // surfaced standalone in Appearance so it is discoverable without opening this screen.
                    choiceRow(String(localized: "Hide poster labels"),
                              [("1", String(localized: "Hide")), ("0", String(localized: "Show"))],
                              selection: Binding(get: { prefs.hidePosterLabels ? "1" : "0" },
                                                 set: { prefs.hidePosterLabels = ($0 == "1") }))
                    Text(apiKeys.hasTMDB
                         ? "Landscape shows cinematic 16:9 backdrops instead of portrait posters where art is available. Hide labels for a cleaner, poster-only grid."
                         : "Landscape 16:9 art needs a TMDB key (add one under the Metadata keys). Hide labels for a cleaner, poster-only grid.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Space.screenEdge)
                }
            }
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    /// A segmented choice row (mirrors `SettingsView.choiceRow` so this screen matches the settings look).
    /// `disabled` dims the chips and blocks selection (used for the TMDB-gated landscape row).
    private func choiceRow(_ label: String, _ options: [(id: String, label: String)],
                           selection: Binding<String>, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(LocalizedStringKey(label))
                .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(options, id: \.id) { opt in
                        Button { if !disabled { selection.wrappedValue = opt.id } } label: { Text(LocalizedStringKey(opt.label)) }
                            .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                            .disabled(disabled)
                    }
                }
            }
        }
        .opacity(disabled ? 0.4 : 1)
        .padding(.horizontal, Theme.Space.screenEdge)
        // Each row is its own focus section so Down moves between stacked rows without first leveling
        // onto the chip beneath the focused one (matches SettingsView.choiceRow).
        .focusSection()
    }
}

/// The live sample poster shown at the top of `TVPosterStyleView`. Mirrors the real catalog card geometry
/// (preset width, aspect from the landscape toggle, preset corner radius, optional label) using a gradient
/// placeholder so it needs no network / metadata. Reads the shared `CatalogPreferences`, so it redraws the
/// instant any control changes. tvOS twin of the iOS `PosterStylePreview`.
private struct TVPosterStylePreview: View {
    @ObservedObject private var prefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    /// A comfortably large sample on the 10-foot UI. Fixed (the real grid uses its own metrics); this is
    /// just to show the width preset's relative scale, so it tracks the preset up to a legible ceiling.
    private var width: CGFloat { min(prefs.posterWidth.regularWidth * 1.4, 460) }
    private var landscape: Bool { prefs.landscapeCards && apiKeys.hasTMDB }
    private var height: CGFloat { landscape ? width * 9.0 / 16.0 : width * 3.0 / 2.0 }

    /// "Balanced · Rounded" (+ " · Landscape" when on), each piece localized. Built as a String so the
    /// width/radius preset names resolve through the catalog rather than being interpolated raw.
    private var previewCaption: String {
        let widthLabel = String(localized: LocalizedStringResource(stringLiteral: prefs.posterWidth.label))
        let radiusLabel = String(localized: LocalizedStringResource(stringLiteral: prefs.posterRadius.label))
        let base = "\(widthLabel) · \(radiusLabel)"
        return landscape ? "\(base) · \(String(localized: "Landscape"))" : base
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Theme.Palette.accent.opacity(0.85), Theme.Palette.surface2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(alignment: .center) {
                            Image(systemName: "film")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: prefs.posterRadius.radius, style: .continuous))
                    // A sample progress stripe, matching a Continue-Watching card, so the radius/width
                    // preview reads as a real poster rather than a bare rectangle.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Theme.Palette.accent).frame(width: geo.size.width * 0.4)
                        }
                    }
                    .frame(width: width, height: 5)
                }
                .frame(width: width, height: height)
                if !prefs.hidePosterLabels {
                    Text("Sample Title")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1).frame(width: width, alignment: .leading)
                }
            }
            Text(previewCaption)
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.vertical, Theme.Space.md)
        .animation(.easeOut(duration: 0.2), value: prefs.posterWidth)
        .animation(.easeOut(duration: 0.2), value: prefs.posterRadius)
        .animation(.easeOut(duration: 0.2), value: prefs.landscapeCards)
        .animation(.easeOut(duration: 0.2), value: prefs.hidePosterLabels)
    }
}
