import SwiftUI

/// A small rating badge for a catalog CARD whose visible artwork does NOT already carry a baked rating.
/// This is specifically the cinematic LANDSCAPE cards: they fill their 16:9 cell with a CLEAN, textless
/// TMDB backdrop (`LandscapeArt` / `LandscapeArtiOS`), which the poster-baking service never touches. The
/// portrait 2:3 poster gets its rating baked in server-side by poster.vortx.tv / ERDB, so portrait cards
/// never mount this. Landscape is the DEFAULT appearance, so without this a default user who keeps (or
/// enables) "Show ratings on posters" sees no rating on any card at all, even though the feature is on and
/// working -- the gap this closes.
///
/// The badge renders the SAME cross-provider set the detail row and the baked poster do (IMDb + RT + MC +
/// TMDB, formatted once in `RatingsFormat`), capped by `maxScores` so a small iOS tile stays legible while a
/// larger tvOS card can carry the full set. Values are looked up by id from VortX's own keyless ratings
/// service (ratings.vortx.tv, the SAME numbers the baker uses), async and fail-soft: nothing shows until a
/// rating resolves, a miss (non-`tt` id, offline, or no rating) simply shows nothing, and a title carrying
/// only IMDb shows only IMDb (per-score fail-soft). Results are memoized per id for the process so scrolling
/// a rail never refetches and a recycled cell repaints instantly.
///
/// The DRAWING lives in `RatingBadgePlate` below, which takes formatted tokens and nothing else. Splitting
/// it out is what lets the badge be rendered deterministically (a snapshot harness composes the real plate
/// over sample artwork with no network and no ratings service), which is how its type was tuned.
struct CardRatingBadge: View {
    let id: String
    let type: String
    /// Draw only when the ratings feature is on AND the visible art is not itself baked; the caller
    /// computes this so a genuinely baked poster is never double-badged.
    var active: Bool = true
    /// Star glyph point size (the tvOS card is larger than the iOS/Mac tile).
    var glyphSize: CGFloat = 8
    /// Rating text point size.
    var textSize: CGFloat = 10
    /// How many scores this card size can carry legibly. A small iOS tile shows the two most salient (the
    /// star + one more, typically RT); a larger tvOS card asks for all four. Capped in `RatingsFormat`.
    var maxScores: Int = 2

    @State private var ratings: MDBListRatings?

    // A ZStack (a concrete layout container), NOT a bare Group: a `Group` whose only child is a false `if`
    // collapses to `EmptyView`, and SwiftUI does not run `.task` on an EmptyView, so the rating would never
    // be fetched and the badge would stay blank forever. The ZStack is always a real view with an appear
    // lifecycle, so the task fires on mount, resolves the rating, and the badge fades in.
    var body: some View {
        ZStack {
            if active, let ratings, case let tokens = RatingsFormat.tokens(ratings, limit: maxScores), !tokens.isEmpty {
                RatingBadgePlate(tokens: tokens, glyphSize: glyphSize, textSize: textSize)
            }
        }
        // Key on id AND active so the lookup (re)runs when the card recycles to a new id and when `active`
        // flips true after the backdrop resolves; skips the network entirely while inactive.
        .task(id: BadgeKey(id: id, active: active)) {
            guard active, id.hasPrefix("tt") else { ratings = nil; return }
            ratings = await CardRatingStore.shared.ratings(id: id, type: type)
        }
    }

    private struct BadgeKey: Equatable { let id: String; let active: Bool }
}

/// The badge itself: ONE capsule of VortXGlass, sized tight to its scores, floating over the artwork.
///
/// It is deliberately the app's OWN material rather than a rounded rectangle with a fill, because a badge
/// made of the same glass as the nav bar, the chips, and the player chrome reads as part of the product
/// sitting on the art, not as a sticker printed on top of it. The baked poster
/// (`cloudflare-poster/src/badges.ts`) draws the SAME composition server-side -- the same capsule, hairline
/// divider, split decimal and tracked lettermarks, over a real Gaussian-blurred, warm-washed copy of the
/// poster art -- so a landscape card and a portrait poster in the same rail are one idea rendered twice,
/// not two badges that happen to show the same numbers.
///
/// Inside, hierarchy is carried by SIZE, TRACKING, CASE and INK, never by a second colour (DESIGN.md's
/// one-accent law: the accent star is the only coloured thing here):
///   * the IMDb value is the ANCHOR, set a third larger, in `textPrimary`, with its DECIMAL dropped to
///     ~76% and into `textSecondary`, so the number reads as one considered figure rather than three even
///     digits;
///   * a hairline divider -- not a gap, not a middot -- separates the anchor from the aggregators;
///   * each provider is a tracked, uppercase lettermark in `textTertiary` (a LABEL) followed by its value
///     in `textSecondary` (the DATA), so the eye sorts them without a second colour. Letterforms only: a
///     third-party rating service's logo is never drawn or embedded here.
/// Insets are optically asymmetric (a trailing digit or `%` sits closer to its own edge than a star does)
/// and the gaps are not uniform (the divider owns more room than the gaps between aggregators), which is
/// what keeps the capsule from reading as evenly-padded boilerplate. Digits are monospaced so a scrolling
/// rail never reflows as values change width.
struct RatingBadgePlate: View {
    let tokens: [RatingsFormat.Token]
    var glyphSize: CGFloat = 8
    var textSize: CGFloat = 10

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                if index > 0 {
                    if tokens[index - 1].isIMDb {
                        divider.padding(.horizontal, dividerPad)
                    } else {
                        Spacer().frame(width: groupGap)
                    }
                }
                if token.isIMDb {
                    anchor(token)
                } else {
                    aggregator(token)
                }
            }
        }
        // Never let a narrow card compress the row: without this SwiftUI would rather wrap the decimal onto
        // a second line than let the badge exceed the cell it is overlaid on.
        .fixedSize()
        .padding(.leading, leadInset)
        .padding(.trailing, trailInset)
        .padding(.vertical, vInset)
        // The same on-art badge glass the portrait poster's rating badge and the resume timecode use: a
        // warm near-black SCRIM plate (`badgeFillAlpha`) at the pill radius so the label holds contrast over
        // any backdrop, with the 1px lit top edge raised a little above the chrome default because a capsule
        // this small has very little edge to catch light with. `.scrim` because it sits ON the artwork; on
        // tvOS this drops to a cheap opaque warm capsule automatically (see GlassStyle). The `.disc` shadow
        // is the tight, close one the round player buttons use: enough to ground the capsule on bright
        // artwork, too small to smear a halo around something this size.
        .vortxGlass(in: Capsule(style: .continuous),
                    fillAlpha: VortXGlass.badgeFillAlpha,
                    highlight: 0.20,
                    shadow: .disc,
                    tone: .scrim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The IMDb anchor: the accent star, then the value with its decimal set apart. The star is seated on
    /// the figure's optical centre rather than on the text baseline, so it reads as a mark ON the number
    /// instead of a bullet beside it.
    private func anchor(_ token: RatingsFormat.Token) -> some View {
        let parts = Self.splitDecimal(token.value)
        return HStack(alignment: .firstTextBaseline, spacing: starGap) {
            Image(systemName: "star.fill")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .alignmentGuide(.firstTextBaseline) { _ in glyphSize * 0.5 + figureSize * 0.24 }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(parts.head)
                    .font(.system(size: figureSize, weight: .semibold).monospacedDigit())
                    .tracking(-0.4)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !parts.tail.isEmpty {
                    Text(parts.tail)
                        .font(.system(size: decimalSize, weight: .semibold).monospacedDigit())
                        .tracking(-0.2)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    /// One aggregator: a tracked uppercase lettermark, then its value. Near enough the same optical size,
    /// but different tracking / case / ink, so the label never competes with the number it labels.
    private func aggregator(_ token: RatingsFormat.Token) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: markGap) {
            Text(token.label)
                .font(.system(size: markSize, weight: .semibold))
                .tracking(markSize * 0.14)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(token.value)
                .font(.system(size: valueSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// The hairline that sets the anchor apart from the rest. Its baseline guide is set by hand so it
    /// centres on the figure rather than hanging off the row's text baseline.
    private var divider: some View {
        Capsule(style: .continuous)
            .fill(Theme.Palette.textPrimary.opacity(0.22))
            .frame(width: 1, height: figureSize * 0.86)
            .alignmentGuide(.firstTextBaseline) { _ in figureSize * 0.72 }
    }

    // MARK: Layout (all derived from the caller's text size, so ONE badge scales from an iOS tile to a
    // tvOS card without a magic constant per platform)

    /// The anchor is set a third larger than the aggregators: the whole point of the composition is that
    /// one number leads and the rest support it.
    private var figureSize: CGFloat { (textSize * 1.3).rounded() }
    private var decimalSize: CGFloat { (figureSize * 0.76).rounded() }
    private var valueSize: CGFloat { max((textSize * 0.88).rounded(), 9) }
    private var markSize: CGFloat { max((textSize * 0.72).rounded(), 8) }
    private var starGap: CGFloat { (textSize * 0.3).rounded() }
    private var markGap: CGFloat { max((textSize * 0.2).rounded(), 2) }
    private var groupGap: CGFloat { (textSize * 0.6).rounded() }
    private var dividerPad: CGFloat { (textSize * 0.62).rounded() }
    private var leadInset: CGFloat { (textSize * 0.62).rounded() }
    /// Optically, not numerically, symmetric: the row ends on a digit or a `%`, which sits closer to its
    /// own edge than the star does, so the trailing inset is set wider to make the capsule LOOK even.
    private var trailInset: CGFloat { (textSize * 0.78).rounded() }
    private var vInset: CGFloat { (textSize * 0.34).rounded() }

    /// "8.3" -> ("8", ".3"); a percentage or a bare metascore comes back whole, so one call site handles
    /// every provider.
    static func splitDecimal(_ v: String) -> (head: String, tail: String) {
        guard let dot = v.firstIndex(of: ".") else { return (v, "") }
        return (String(v[v.startIndex..<dot]), String(v[dot...]))
    }

    private var accessibilityText: String {
        "Rating " + tokens.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
    }
}

/// Process-wide memoized ratings-by-id cache over the keyless VortX ratings service, so a rail of landscape
/// cards makes at most one request per id (misses cached too) and a recycled cell repaints from memory.
/// `@MainActor` so the maps are touched without locks; the network hop itself suspends off the actor inside
/// `VortXRatingsClient`.
@MainActor
final class CardRatingStore {
    static let shared = CardRatingStore()

    /// id -> the full cross-provider ratings model, or nil for a remembered miss (so a title with no rating
    /// is not refetched on every reappear). The double optional from a dictionary read distinguishes "known
    /// miss" from "unseen".
    private var cache: [String: MDBListRatings?] = [:]
    private var inflight: [String: Task<MDBListRatings?, Never>] = [:]

    func ratings(id: String, type: String) async -> MDBListRatings? {
        if let known = cache[id] { return known }
        if let task = inflight[id] { return await task.value }
        let task = Task<MDBListRatings?, Never> {
            await VortXRatingsClient.ratings(imdbID: id, type: type)
        }
        inflight[id] = task
        let value = await task.value
        inflight[id] = nil
        cache[id] = value
        return value
    }
}
