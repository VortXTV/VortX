import SwiftUI

/// "Your rating" chip for the detail page: shows the score the user gave a title and opens a 1...10
/// picker to set or clear it. Cross-platform (iPhone / iPad / Mac / Apple TV) by construction: it lives
/// in SourcesShared and BOTH detail pages mount this same view, so neither surface can drift from the
/// other (settings parity).
///
/// READ SOURCE: `TraktRatingsStore`, the local shadow on disk, never a Trakt response. The chip is
/// therefore correct offline and paints instantly on a rating (no request in the interaction path).
///
/// GATING: rendered only when Trakt is configured, CONNECTED, the ratings toggle is on, and the title
/// carries a usable id. With empty build creds `TraktAuth.isConfigured` is false, so the chip does not
/// exist and nothing here touches the network, matching the rest of the external-services surface.
///
/// The picker is a `confirmationDialog`, the same primitive the tvOS quality picker uses, so the Apple TV
/// remote's focus handling comes for free instead of from a hand-rolled focus grid.
struct TraktRatingChip: View {
    /// The title's IMDb id ("tt…"), when known.
    let imdb: String?
    /// The title's numeric TMDB id, used when no tt id resolved (a tmdb-only catalog title).
    let tmdb: Int?
    /// True for a series (rates the SHOW, matching the title-level intent of the watchlist writes).
    let isSeries: Bool

    @AppStorage(ExternalSyncToggle.traktRatings) private var ratingsEnabled = true
    @State private var rating: Int?
    @State private var connected = false
    @State private var picking = false

    var body: some View {
        // `isConfigured` is a synchronous constant check, so a credential-less build costs nothing here.
        if TraktAuth.isConfigured, ratingsEnabled, hasUsableID {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if connected {
            Button { picking = true } label: {
                Label(label, systemImage: rating == nil ? "star" : "star.fill")
            }
            // Selected once rated, so the ember accent marks a title the user has scored, the same way a
            // selected filter chip reads elsewhere.
            .buttonStyle(ChipButtonStyle(selected: rating != nil))
            .confirmationDialog(dialogTitle, isPresented: $picking, titleVisibility: .visible) {
                ForEach(Array(TraktRatingsStore.validRange).reversed(), id: \.self) { value in
                    Button(buttonLabel(for: value)) { set(value) }
                }
                if rating != nil {
                    Button("Remove rating", role: .destructive) { clear() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task { refresh() }
            // Repaint when the store changes underneath: a converged read-back, or a disconnect wipe.
            .onReceive(NotificationCenter.default.publisher(for: TraktRatingsStore.changedNote)) { _ in
                refresh()
            }
        } else {
            // LOAD-BEARING, do not "simplify" this branch away. Sign-in lives behind an actor, so `connected`
            // starts false and can only be resolved asynchronously. Writing the whole chip as
            // `if connected { Button… .task { connected = await … } }` deadlocks itself: with `connected`
            // false the body renders nothing, so the `.task` never attaches, so `connected` never becomes
            // true, and the chip can never appear at all. This zero-sized placeholder is the thing that IS
            // in the hierarchy while disconnected, so its `.task` runs and the real chip can take over.
            // Cost: an HStack lays out its spacing around a 0x0 view, so a disconnected (but configured)
            // build carries one dead gap in the chip row. Cheap next to a chip that never shows up.
            Color.clear.frame(width: 0, height: 0)
                .task { connected = await TraktAuth.shared.isSignedIn; refresh() }
        }
    }

    private var hasUsableID: Bool { (imdb?.isEmpty == false) || (tmdb != nil) }

    private var label: String {
        guard let rating else { return String(localized: "Rate") }
        return String(localized: "Your rating · \(rating)")
    }

    private var dialogTitle: String {
        rating == nil ? String(localized: "Rate this title") : String(localized: "Change your rating")
    }

    /// Mark the current score in the list, so the dialog says what is already set without a checkmark
    /// (a `confirmationDialog` button cannot carry one).
    private func buttonLabel(for value: Int) -> String {
        value == rating ? String(localized: "\(value) · your rating") : "\(value)"
    }

    private func refresh() {
        rating = TraktRatingsStore.shared.rating(imdb: imdb, tmdb: tmdb)
    }

    private func set(_ value: Int) {
        TraktRatingsStore.shared.setRating(value, imdb: imdb, tmdb: tmdb, isSeries: isSeries)
        // Paint from the store rather than from `value`, so the chip always shows what was actually
        // recorded (the store refuses an out-of-range value instead of clamping it).
        refresh()
    }

    private func clear() {
        TraktRatingsStore.shared.clearRating(imdb: imdb, tmdb: tmdb, isSeries: isSeries)
        refresh()
    }
}
