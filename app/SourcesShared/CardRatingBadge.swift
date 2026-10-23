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
/// only IMDb shows only IMDb (per-score fail-soft). Successful results are memoized per typed endpoint;
/// concurrent cards coalesce one request, while an offline/transient miss can retry on a later appearance.
///
/// The DRAWING lives in `RatingBadgePlate` below (marks from `RatingLogo`), which takes formatted tokens and nothing else. Splitting
/// it out is what lets the badge be rendered deterministically (a snapshot harness composes the real plate
/// over sample artwork with no network and no ratings service), which is how its type was tuned.
struct CardRatingBadge: View {
    let id: String
    let type: String
    /// Draw only when the ratings feature is on AND the visible art is not itself baked; the caller
    /// computes this so a genuinely baked poster is never double-badged.
    var active: Bool = true
    /// Rating text point size (the tvOS card is larger than the iOS/Mac tile); the marks scale with it.
    var textSize: CGFloat = 10
    /// An outright cap on the score count; nil shows every score that FITS the card. The badge measures
    /// itself against the card width and drops scores from the end of the `RatingsFormat` priority order
    /// (headline scores first), so a phone tile and a TV card both show as many as they can hold.
    var maxScores: Int? = nil
    /// Width kept clear at the trailing edge for the watched checkmark that owns the top-trailing corner.
    var reservedTrailing: CGFloat = 0
    var fallbackIMDb: String? = nil

    @State private var ratings: MDBListRatings?
    @State private var ratingsKey: RatingRequestKey?
    private var requestKey: RatingRequestKey { .init(id: id, type: type) }

    // A ZStack (a concrete layout container), NOT a bare Group: a `Group` whose only child is a false `if`
    // collapses to `EmptyView`, and SwiftUI does not run `.task` on an EmptyView, so the rating would never
    // be fetched and the badge would stay blank forever. The ZStack is always a real view with an appear
    // lifecycle, so the task fires on mount, resolves the rating, and the badge fades in.
    var body: some View {
        ZStack {
            if active, let displayed = RatingPresentationPolicy.merged(
                ratingsKey == requestKey ? ratings : nil, fallbackIMDb: fallbackIMDb),
               case let tokens = RatingsFormat.tokens(displayed, limit: maxScores), !tokens.isEmpty {
                RatingBadgeFit(tokens: tokens, textSize: textSize)
                    .padding(.trailing, reservedTrailing)
            }
        }
        // Key on id AND active so the lookup (re)runs when the card recycles to a new id and when `active`
        // flips true after the backdrop resolves; skips the network entirely while inactive.
        .task(id: BadgeKey(request: requestKey, active: active)) {
            let requested = requestKey
            ratingsKey = requested
            ratings = nil
            guard active, id.hasPrefix("tt") else { return }
            let value = await CardRatingStore.shared.ratings(id: id, type: type)
            guard !Task.isCancelled, ratingsKey == requested else { return }
            ratings = value
        }
    }

    private struct BadgeKey: Equatable { let request: RatingRequestKey; let active: Bool }
}

/// The plate at the largest score count that fits the width offered: every score when there is room, then
/// one fewer from the end at a time, down to the first score alone. `ViewThatFits` measures each candidate's
/// ideal width, so nothing is ever clipped or squeezed onto a second line.
struct RatingBadgeFit: View {
    let tokens: [RatingsFormat.Token]
    var textSize: CGFloat = 10

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(tokens.count, 1)).reversed(), id: \.self) { count in
                RatingBadgePlate(tokens: Array(tokens.prefix(count)), textSize: textSize)
            }
        }
    }
}

/// The badge itself: ONE capsule of VortXGlass, sized tight to its scores, floating over the artwork. Each
/// score is its service's mark beside the value (`RatingScore`), so the plate reads at a glance with no
/// lettermarks to decode. The glass is the app's own material, the same as the chips and player chrome, so
/// the badge sits on the art as part of the product rather than a sticker printed on it. Digits are
/// monospaced so a scrolling rail never reflows as values change width.
struct RatingBadgePlate: View {
    let tokens: [RatingsFormat.Token]
    var textSize: CGFloat = 10

    var body: some View {
        HStack(spacing: (textSize * 0.75).rounded()) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                RatingScore(token: token, textSize: textSize)
            }
        }
        .fixedSize()
        .padding(.leading, (textSize * 0.4).rounded())
        .padding(.trailing, (textSize * 0.7).rounded())
        .padding(.vertical, (textSize * 0.36).rounded())
        // The on-art badge glass: a warm near-black SCRIM plate so the values hold contrast over any
        // backdrop, with a lit top edge. On tvOS this drops to a cheap opaque capsule (see GlassStyle).
        .vortxGlass(in: Capsule(style: .continuous),
                    fillAlpha: VortXGlass.badgeFillAlpha,
                    highlight: 0.20,
                    shadow: .disc,
                    tone: .scrim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ratings: " + tokens.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
    }
}

/// Process-wide memoized ratings-by-id cache over the keyless VortX ratings service, so a rail of landscape
/// cards makes at most one request per id (misses cached too) and a recycled cell repaints from memory.
/// `@MainActor` so the maps are touched without locks; the network hop itself suspends off the actor inside
/// `VortXRatingsClient`.
@MainActor
final class CardRatingStore {
    static let shared = CardRatingStore()

    /// Keep successful values only. The client cannot distinguish an unrated title from a temporary
    /// transport failure, so remembering nil would prevent recovery on the next appearance.
    private var cache: [RatingRequestKey: MDBListRatings] = [:]
    private var inflight: [RatingRequestKey: Task<MDBListRatings?, Never>] = [:]
    private let load: @MainActor (String, String) async -> MDBListRatings?

    init(load: @escaping @MainActor (String, String) async -> MDBListRatings? = {
        await VortXRatingsClient.ratings(imdbID: $0, type: $1)
    }) { self.load = load }

    func ratings(id: String, type: String) async -> MDBListRatings? {
        let key = RatingRequestKey(id: id, type: type)
        guard key.enabled else { return nil }
        if let known = cache[key] { return known }
        if let task = inflight[key] { return await task.value }
        let task = Task<MDBListRatings?, Never> {
            await load(id, key.type)
        }
        inflight[key] = task
        let value = await task.value
        inflight[key] = nil
        if let value { cache[key] = value }
        return value
    }
}
