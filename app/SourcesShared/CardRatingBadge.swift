import SwiftUI

/// A small rating-star badge for a catalog CARD whose visible artwork does NOT already carry a baked
/// rating. This is specifically the cinematic LANDSCAPE cards: they fill their 16:9 cell with a CLEAN,
/// textless TMDB backdrop (`LandscapeArt` / `LandscapeArtiOS`), which the poster-baking service never
/// touches. The portrait 2:3 poster gets its rating baked in server-side by poster.vortx.tv / ERDB, so
/// portrait cards never mount this. Landscape is the DEFAULT appearance, so without this a default user
/// who keeps (or enables) "Show ratings on posters" sees no rating on any card at all, even though the
/// feature is on and working -- the gap this closes.
///
/// The value is looked up by id from VortX's own keyless ratings service (ratings.vortx.tv, the SAME
/// numbers the baker uses), async and fail-soft: nothing shows until a rating resolves, and a miss
/// (non-`tt` id, offline, or no rating) simply shows nothing. Results are memoized per id for the process
/// so scrolling a rail never refetches and a recycled cell repaints instantly.
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

    @State private var rating: String?

    // A ZStack (a concrete layout container), NOT a bare Group: a `Group` whose only child is a false
    // `if` collapses to `EmptyView`, and SwiftUI does not run `.task` on an EmptyView, so the rating would
    // never be fetched and the badge would stay blank forever. The ZStack is always a real view with an
    // appear lifecycle, so the task fires on mount, resolves the rating, and the badge fades in.
    var body: some View {
        ZStack {
            if active, let rating, !rating.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill").font(.system(size: glyphSize))
                    Text(rating).font(.system(size: textSize, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                // Same on-art badge glass the portrait poster's native rating badge uses (iOS PosterCardiOS
                // and the tvOS resume timecode): a dark scrim plate so the white label holds contrast over
                // any backdrop. `.scrim` because it sits ON the artwork; on tvOS this drops to a cheap opaque
                // warm capsule automatically (see GlassStyle).
                .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.badgeFillAlpha, shadow: .flat, tone: .scrim)
                .accessibilityLabel("Rating \(rating)")
            }
        }
        // Key on id AND active so the lookup (re)runs when the card recycles to a new id and when `active`
        // flips true after the backdrop resolves; skips the network entirely while inactive.
        .task(id: BadgeKey(id: id, active: active)) {
            guard active, id.hasPrefix("tt") else { rating = nil; return }
            rating = await CardRatingStore.shared.rating(id: id, type: type)
        }
    }

    private struct BadgeKey: Equatable { let id: String; let active: Bool }
}

/// Process-wide memoized rating-by-id cache over the keyless VortX ratings service, so a rail of landscape
/// cards makes at most one request per id (misses cached too) and a recycled cell repaints from memory.
/// `@MainActor` so the maps are touched without locks; the network hop itself suspends off the actor inside
/// `VortXRatingsClient`.
@MainActor
final class CardRatingStore {
    static let shared = CardRatingStore()

    /// id -> formatted imdb rating, or nil for a remembered miss (so a title with no rating is not refetched
    /// on every reappear). The double optional from a dictionary read distinguishes "known miss" from "unseen".
    private var cache: [String: String?] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    func rating(id: String, type: String) async -> String? {
        if let known = cache[id] { return known }
        if let task = inflight[id] { return await task.value }
        let task = Task<String?, Never> {
            guard let r = await VortXRatingsClient.ratings(imdbID: id, type: type), let imdb = r.imdb else {
                return nil
            }
            return String(format: "%.1f", imdb)   // one decimal, matching the baked poster's IMDb badge
        }
        inflight[id] = task
        let value = await task.value
        inflight[id] = nil
        cache[id] = value
        return value
    }
}
