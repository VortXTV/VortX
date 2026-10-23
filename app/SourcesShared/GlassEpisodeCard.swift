import SwiftUI

/// The redesigned episode card (2026-10-15 mockups 6 and 7), shared by the phone rail, the iPad and Mac grid
/// and the Apple TV grid: the still at its own 16:9 on top (never zoomed), a frosted panel below that continues
/// the same art blurred, glass chips on the art (Watched or Up next, the episode's scores), a progress bar in the
/// accent, and in the panel the episode number with Top rated, title, a two-line synopsis, runtime and air date.
///
/// The caller owns the image loading (`artwork`) and the interaction (link, focus, menus); this view is pure
/// presentation. The blurred panel falls back to a flat surface when glass is switched off in Settings or
/// transparency is reduced, which also keeps it cheap on Apple TV.
struct GlassEpisodeCard: View {
    struct Model {
        var number: Int
        var title: String
        /// nil while spoiler-safe hides it; `spoilerHint` is shown instead.
        var overview: String?
        var spoilerHint: String? = nil
        var runtime: String? = nil
        var aired: String? = nil
        var isWatched = false
        var isUpNext = false
        var progress: Double = 0
        var remaining: String? = nil
        /// The episode's own scores (IMDb, TMDB, Trakt), drawn as the same glass plate the title cards use.
        var scores: MDBListRatings? = nil
        var topRated = false
    }

    let model: Model
    let width: CGFloat
    let artwork: AnyView
    var trailingStatus: AnyView? = nil
    /// Apple TV reads from across the room: larger type and chips.
    var tenFoot = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isFocused) private var isFocused
    /// A watched episode reads as done at a glance: the whole card dims and its art loses most of its colour,
    /// as the episode rows did before the glass cards. Focus (tvOS) lifts it back so it stays readable there.
    private var dulled: Bool { model.isWatched && !isFocused }
    private static let watchedSaturation: Double = 0.15
    private static let watchedShade: Double = 0.58

    private var artHeight: CGFloat { width * 9 / 16 }
    private var radius: CGFloat { tenFoot ? 24 : 22 }
    private var frosted: Bool { VisualEffects.glassEnabled && !reduceTransparency && contrast != .increased }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .frame(width: width, height: artHeight)
                .clipped()
                .overlay(alignment: .top) { chips }
                .overlay(alignment: .bottom) { progressBar }
            panel
        }
        .frame(width: width, alignment: .leading)
        .background { panelBackground }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(VortXGlass.highlight(0.16), lineWidth: 1)
        }
        // Dimmed as one opaque card: art and panel lose their colour together and one shade darkens them evenly.
        // Fading the card's opacity instead let the oversized blurred art behind the panel show through the
        // sharp art above it, a smeared double image, and left the panel's blur in full colour.
        .saturation(dulled ? Self.watchedSaturation : 1)
        .overlay {
            if dulled {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(Self.watchedShade))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Episode \(model.number): \(model.title)")
        .accessibilityValue(accessibilityStatus)
    }

    // MARK: Parts

    /// Status on the leading side, the episode's scores on the trailing side. When both do not fit at full
    /// size the Watched chip drops to its checkmark first, and only then does the plate drop scores.
    private var chips: some View {
        let tokens = model.scores.map { RatingsFormat.tokens($0) } ?? []
        return ViewThatFits(in: .horizontal) {
            chipRow(tokens: tokens, compactStatus: false, fitScores: false)
            chipRow(tokens: tokens, compactStatus: true, fitScores: false)
            chipRow(tokens: tokens, compactStatus: true, fitScores: true)
        }
        .padding(tenFoot ? 14 : 10)
    }

    private func chipRow(tokens: [RatingsFormat.Token], compactStatus: Bool, fitScores: Bool) -> some View {
        HStack(spacing: 8) {
            if model.isUpNext && !model.isWatched {
                GlassChip(text: "Up next", prominent: true, tenFoot: tenFoot)
            } else if model.isWatched {
                GlassChip(text: compactStatus ? "" : "Watched", systemImage: "checkmark", tenFoot: tenFoot)
            }
            Spacer(minLength: 0)
            if !tokens.isEmpty {
                let text: CGFloat = tenFoot ? 15 : 11
                if fitScores {
                    RatingBadgeFit(tokens: tokens, textSize: text)
                } else {
                    RatingBadgePlate(tokens: tokens, textSize: text)
                }
            }
        }
    }

    @ViewBuilder private var progressBar: some View {
        if !model.isWatched, model.progress > 0.01 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.22))
                    Rectangle().fill(Theme.Palette.accent)
                        .frame(width: geo.size.width * min(max(model.progress, 0), 1))
                        .shadow(color: Theme.Palette.accent.opacity(0.7), radius: 6)
                }
            }
            .frame(height: tenFoot ? 5 : 4)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: tenFoot ? 8 : 6) {
            HStack(spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: tenFoot ? 15 : 12, weight: .heavy))
                    .tracking(tenFoot ? 2 : 1.6)
                    .foregroundStyle(Color.white.opacity(0.72))
                if model.topRated {
                    Label("Top rated", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: tenFoot ? 15 : 12, weight: .heavy))
                        .tracking(tenFoot ? 1.6 : 1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Palette.accent)
                }
                Spacer(minLength: 0)
                if let trailingStatus { trailingStatus }
            }
            .lineLimit(1)
            .frame(height: tenFoot ? 24 : 18)
            // One title line and two reserved synopsis lines, so every card in a rail or grid is the same height.
            Text(model.title)
                .font(.system(size: tenFoot ? 26 : 19, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            ZStack(alignment: .topLeading) {
                Text(model.overview ?? " ")
                    .font(.system(size: tenFoot ? 19 : 14.5))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(2, reservesSpace: true)
                    .opacity(model.overview?.isEmpty == false ? 1 : 0)
                if model.overview?.isEmpty != false, let hint = model.spoilerHint {
                    Label(hint, systemImage: "eye.slash")
                        .font(.system(size: tenFoot ? 18 : 13.5))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .frame(height: ((tenFoot ? 19 : 14.5) * 1.25 * 2).rounded(.up), alignment: .topLeading)
            Text(footer ?? " ")
                .font(.system(size: tenFoot ? 17 : 13.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .frame(height: tenFoot ? 24 : 18, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(.horizontal, tenFoot ? 20 : 16)
        .padding(.top, tenFoot ? 16 : 13)
        .padding(.bottom, tenFoot ? 18 : 14)
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }

    /// The same art continued under the panel, blurred and dimmed: the frosted look of the mockups. A flat
    /// surface stands in when glass is off or transparency is reduced.
    @ViewBuilder private var panelBackground: some View {
        if frosted {
            ZStack {
                artwork
                    .frame(width: width, height: width)
                    .scaleEffect(1.6)
                    .blur(radius: tenFoot ? 26 : 30, opaque: true)
                    .saturation(1.3)
                Color.black.opacity(0.42)
                LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Theme.Palette.surface1
        }
    }

    // MARK: Text

    private var eyebrow: String {
        var parts = ["EPISODE \(model.number)"]
        if !model.isWatched, model.progress > 0.01, let remaining = model.remaining { parts.append(remaining.uppercased()) }
        return parts.joined(separator: " · ")
    }

    private var footer: String? {
        let parts = [model.runtime, model.aired].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityStatus: String {
        var parts: [String] = []
        if model.isWatched { parts.append("Watched") }
        else if model.isUpNext { parts.append("Up next") }
        if model.progress > 0.01, !model.isWatched { parts.append("\(Int((model.progress * 100).rounded())) percent watched") }
        if let scores = model.scores {
            parts.append(contentsOf: RatingsFormat.tokens(scores).map { "\($0.label) \($0.value)" })
        }
        if model.topRated { parts.append("Top rated") }
        if let footer { parts.append(footer) }
        return parts.joined(separator: ", ")
    }
}

/// A small Liquid Glass chip for labels laid over artwork: frosted, bright-rimmed, with a faint dark
/// underlayer so the white label stays legible on any art. `prominent` tints it with the accent (Up next).
struct GlassChip: View {
    let text: String
    var systemImage: String? = nil
    var prominent = false
    var tenFoot = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: tenFoot ? 8 : 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: tenFoot ? 15 : 11, weight: .bold))
            }
            if !text.isEmpty {
                Text(text).font(.system(size: tenFoot ? 17 : 13, weight: .semibold))
            }
        }
        .foregroundStyle(prominent ? Theme.Palette.onAccent : .white)
        .padding(.horizontal, tenFoot ? 14 : 10)
        .frame(height: tenFoot ? 38 : 28)
        .background {
            let shape = Capsule(style: .continuous)
            ZStack {
                if reduceTransparency || !VisualEffects.glassEnabled {
                    shape.fill(prominent ? Theme.Palette.accent : Color.black.opacity(0.72))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(prominent ? Theme.Palette.accent.opacity(0.86) : Color.black.opacity(0.36))
                    shape.fill(VortXGlass.sheen)
                }
            }
            .overlay { shape.strokeBorder(VortXGlass.highlight(0.18), lineWidth: 1) }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// An episode's air date for the card footer ("Jan 31, 2025"), from the add-on's ISO `released` string.
enum EpisodeAirDate {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func short(_ released: String?) -> String? {
        guard let released, released.count >= 10, let date = parser.date(from: String(released.prefix(10))) else { return nil }
        return display.string(from: date)
    }
}

/// One card in the Trailers & Extras row: the video's 16:9 thumbnail with its kind as a glass chip and a
/// glass play disc in the accent, then its name and kind. The caller owns the image loading and the tap.
struct TitleExtraCard: View {
    let video: TMDBClient.TitleVideo
    let width: CGFloat
    let artwork: AnyView
    var tenFoot = false

    private var radius: CGFloat { tenFoot ? 22 : 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: tenFoot ? 10 : 7) {
            artwork
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                .overlay(alignment: .topLeading) { GlassChip(text: video.kind, tenFoot: tenFoot).padding(tenFoot ? 14 : 10) }
                .overlay { GlassPlayDisc(size: tenFoot ? 76 : 54) }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(VortXGlass.highlight(0.16), lineWidth: 1)
                }
            Text(video.name)
                .font(.system(size: tenFoot ? 22 : 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            Text(video.kind)
                .font(.system(size: tenFoot ? 17 : 12.5))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(video.kind): \(video.name)")
        .accessibilityAddTraits(.isButton)
    }
}

/// The round glass play button over a thumbnail, tinted with the accent.
struct GlassPlayDisc: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency || !VisualEffects.glassEnabled {
                Circle().fill(Color.black.opacity(0.7))
            } else {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Theme.Palette.accent.opacity(0.30))
                Circle().fill(Color.black.opacity(0.22))
                Circle().fill(VortXGlass.sheen)
            }
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
        .overlay { Circle().strokeBorder(VortXGlass.highlight(0.2), lineWidth: 1) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}
