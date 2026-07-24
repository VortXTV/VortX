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
                HStack(spacing: groupSpacing) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        // A hairline sets the IMDb anchor apart from the quieter aggregator scores, so the badge
                        // reads as "your star rating, then the rest" instead of one flat run of numbers. Only
                        // when IMDb actually leads (a title missing IMDb has no anchor to divide from).
                        if index == 1, tokens.first?.isIMDb == true {
                            Capsule(style: .continuous)
                                .fill(Theme.Palette.textPrimary.opacity(0.22))
                                .frame(width: 1, height: glyphSize + 3)
                        }
                        scoreView(token)
                    }
                }
                .padding(.horizontal, hInset).padding(.vertical, vInset)
                // The same on-art badge glass the portrait poster's rating badge and the resume timecode use:
                // a warm near-black SCRIM plate (`badgeFillAlpha`) at the pill radius so the label holds
                // contrast over any backdrop. `.scrim` because it sits ON the artwork; on tvOS this drops to a
                // cheap opaque warm capsule automatically (see GlassStyle).
                .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.badgeFillAlpha, shadow: .flat, tone: .scrim)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(tokens))
            }
        }
        // Key on id AND active so the lookup (re)runs when the card recycles to a new id and when `active`
        // flips true after the backdrop resolves; skips the network entirely while inactive.
        .task(id: BadgeKey(id: id, active: active)) {
            guard active, id.hasPrefix("tt") else { ratings = nil; return }
            ratings = await CardRatingStore.shared.ratings(id: id, type: type)
        }
    }

    /// One score. The IMDb token is the ANCHOR: the app's single ember accent on the star (per DESIGN.md's
    /// one-accent rule) with the value bright in `textPrimary`, the exact lead the detail page's rating row
    /// uses, so a card and the detail page read as one system. Every other provider prints a quieter, a-notch
    /// smaller label + value (muted `textTertiary` / `textSecondary`) so they support the anchor rather than
    /// crowd it. Digits are monospaced so a scrolling rail of badges does not jitter as values change width.
    @ViewBuilder private func scoreView(_ token: RatingsFormat.Token) -> some View {
        if token.isIMDb {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(token.value)
                    .font(.system(size: textSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        } else {
            HStack(spacing: 2) {
                Text(token.label)
                    .font(.system(size: secondarySize, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(token.value)
                    .font(.system(size: secondarySize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    // MARK: Layout (tracks the card's own text size, so ONE badge scales from an iOS tile to a tvOS card)

    /// Aggregator scores sit a couple of points below the IMDb value so the anchor stays dominant.
    private var secondarySize: CGFloat { max(textSize - 2, 9) }
    /// Gap between score groups, and the pill's insets, tracked to the text size so the badge stays tight on a
    /// small iOS tile and breathes on a 10-foot tvOS card without a magic constant per platform.
    private var groupSpacing: CGFloat { (textSize * 0.5).rounded() }
    private var hInset: CGFloat { (textSize * 0.62).rounded() }
    private var vInset: CGFloat { (textSize * 0.3).rounded() }

    private func accessibilityText(_ tokens: [RatingsFormat.Token]) -> String {
        "Rating " + tokens.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
    }

    private struct BadgeKey: Equatable { let id: String; let active: Bool }
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
