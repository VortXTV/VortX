import SwiftUI

/// "SIMKL rating" chip for the detail page: shows the score the user gave a title ON SIMKL and opens a 1...10
/// picker to set or clear it. The SIMKL peer of `TraktRatingChip`, and deliberately the same shape (same
/// `confirmationDialog` primitive so the tvOS remote's focus handling comes for free, same instant local paint,
/// same cross-platform single view mounted by BOTH detail pages).
///
/// WHY A SEPARATE CHIP, not a merge into the Trakt chip: a title's SIMKL rating and Trakt rating are INDEPENDENT
/// data (the user can score 8 on one and 7 on the other), and each service is gated on its OWN connection +
/// toggle. Keeping them parallel means a SIMKL-only user finally gets a rating control (the Trakt chip never
/// renders for them), a both-connected user sees each service's own score, and the just-shipped Trakt ratings
/// lane is left completely untouched. The chip labels itself "SIMKL" so two chips are never ambiguous.
///
/// READ SOURCE: `SIMKLRatingsStore`, the local shadow on disk, never a SIMKL response, so it is correct offline
/// and paints instantly on a rating. GATING: rendered only when SIMKL is configured, CONNECTED, the SIMKL
/// ratings toggle is on, and the title carries a usable id; with empty build creds `SIMKLAuth.isConfigured` is
/// false, so the chip does not exist and nothing here touches the network.
struct SIMKLRatingChip: View {
    /// The title's IMDb id ("tt…"), when known.
    let imdb: String?
    /// The title's numeric TMDB id, used when no tt id resolved (a tmdb-only catalog title).
    let tmdb: Int?
    /// True for a series/anime (rates the SHOW, matching SIMKL's title-level rating).
    let isSeries: Bool

    @AppStorage(ExternalSyncToggle.simklRatings) private var ratingsEnabled = true
    @State private var rating: Int?
    @State private var connected = false
    @State private var picking = false

    var body: some View {
        // `isConfigured` is a synchronous constant check, so a credential-less build costs nothing here.
        if SIMKLAuth.isConfigured, ratingsEnabled, hasUsableID {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if connected {
            Button { picking = true } label: {
                Label(label, systemImage: rating == nil ? "star" : "star.fill")
            }
            .buttonStyle(ChipButtonStyle(selected: rating != nil))
            .confirmationDialog(dialogTitle, isPresented: $picking, titleVisibility: .visible) {
                ForEach(Array(SIMKLRatingsStore.validRange).reversed(), id: \.self) { value in
                    Button(buttonLabel(for: value)) { set(value) }
                }
                if rating != nil {
                    Button("Remove rating", role: .destructive) { clear() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task { refresh(); SIMKLRatingsStore.shared.refreshIfStale() }
            // Repaint when the store changes underneath: a converged read-back, or a disconnect wipe.
            .onReceive(NotificationCenter.default.publisher(for: SIMKLRatingsStore.changedNote)) { _ in
                refresh()
            }
        } else {
            // LOAD-BEARING placeholder, same reason as `TraktRatingChip`: sign-in lives behind an actor, so
            // `connected` starts false and the chip renders nothing; this zero-sized view is what IS in the
            // hierarchy while disconnected, so its `.task` runs, resolves sign-in, and the real chip takes over.
            Color.clear.frame(width: 0, height: 0)
                .task {
                    connected = await SIMKLAuth.shared.isSignedIn
                    refresh()
                    if connected { SIMKLRatingsStore.shared.refreshIfStale() }
                }
        }
    }

    private var hasUsableID: Bool { (imdb?.isEmpty == false) || (tmdb != nil) }

    private var label: String {
        guard let rating else { return String(localized: "Rate on SIMKL") }
        return String(localized: "SIMKL rating · \(rating)")
    }

    private var dialogTitle: String {
        rating == nil ? String(localized: "Rate this title on SIMKL") : String(localized: "Change your SIMKL rating")
    }

    private func buttonLabel(for value: Int) -> String {
        value == rating ? String(localized: "\(value) · your rating") : "\(value)"
    }

    private func refresh() {
        rating = SIMKLRatingsStore.shared.rating(imdb: imdb, tmdb: tmdb)
    }

    private func set(_ value: Int) {
        SIMKLRatingsStore.shared.setRating(value, imdb: imdb, tmdb: tmdb, isSeries: isSeries)
        // Paint from the store rather than from `value`, so the chip shows what was actually recorded.
        refresh()
    }

    private func clear() {
        SIMKLRatingsStore.shared.clearRating(imdb: imdb, tmdb: tmdb, isSeries: isSeries)
        refresh()
    }
}
