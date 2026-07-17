import SwiftUI

/// The "I'm watching this" detail-page action: tell Trakt you are watching this RIGHT NOW, somewhere
/// VortX cannot see. A cinema, a friend's TV, a broadcast.
///
/// Cross-platform by construction (iPhone / iPad / Mac / Apple TV): it lives in `SourcesShared`, which is
/// compiled into every app target, and both detail pages mount this same view, so there is no per-platform
/// copy to keep in step.
///
/// DORMANCY: renders nothing unless Trakt is configured, connected, the user turned the action on, and the
/// title carries an id Trakt can match. On the shipped credential-less build it is invisible and silent.
///
/// It never fires by itself. In-app playback is already covered end to end by the scrobble path, which
/// owns every play VortX can observe; this exists only for the plays it cannot.
struct TraktCheckinChip: View {
    /// Season + episode of the episode to check into. Series only: Trakt checks into an EPISODE, never a
    /// whole show, so a series page passes the same episode its Play button would start, and the chip
    /// hides when none has resolved. Movies pass nil.
    var season: Int?
    var episode: Int?

    @EnvironmentObject private var core: CoreBridge
    @ObservedObject private var model = TraktCheckinModel.shared

    /// Default MUST stay `false` to match `ExternalSyncToggle.traktCheckin`'s documented default, or a
    /// never-touched switch and the runtime gate would disagree.
    @AppStorage(ExternalSyncToggle.traktCheckin) private var enabled = false

    @State private var connected = false
    @State private var conflictUntil: Date?
    @State private var showConflict = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        if enabled, connected, let meta = core.metaDetails?.meta,
           TraktCheckinModel.canOffer(isSeries: meta.type == "series", season: season, episode: episode) {
            let key = TraktCheckinModel.key(id: meta.id, season: season, episode: episode)
            let isActive = model.isActive(key)
            Button { act(meta, isActive: isActive) } label: {
                Label(label(isActive: isActive), systemImage: isActive ? "eye.fill" : "eye")
            }
            .buttonStyle(ChipButtonStyle(selected: isActive))
            .disabled(model.working)
            .alert("Already watching something", isPresented: $showConflict) {
                Button("Keep it", role: .cancel) {}
                Button("Check in here") { replace(meta) }
            } message: {
                Text(conflictMessage)
            }
            .alert("Could not check in", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Trakt could not be reached.")
            }
            // Sign-in lives behind an actor, so it is resolved once the chip appears rather than read
            // synchronously in `body`.
            .task { connected = await TraktAuth.shared.isSignedIn }
        }
    }

    private func label(isActive: Bool) -> String {
        guard isActive else { return "I'm watching this" }
        if let until = model.active?.expiresAt {
            return "Watching until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "Watching"
    }

    /// The conflict copy names the obstacle and its clock, so "Check in here" is a decision rather than a
    /// guess. The vaguer no-expiry wording is used when Trakt did not tell us when the slot frees.
    private var conflictMessage: String {
        guard let until = conflictUntil else {
            return "Trakt already shows you as watching something else. Checking in here will stop that."
        }
        return "Trakt already shows you as watching something else until \(until.formatted(date: .omitted, time: .shortened)). Checking in here will stop that."
    }

    private func act(_ meta: CoreMetaItem, isActive: Bool) {
        Task {
            if isActive {
                await model.cancelActive()
                return
            }
            let outcome = await model.checkIn(id: meta.id, isSeries: meta.type == "series",
                                              season: season, episode: episode, title: meta.name)
            handle(outcome)
        }
    }

    private func replace(_ meta: CoreMetaItem) {
        Task {
            let outcome = await model.replaceActive(id: meta.id, isSeries: meta.type == "series",
                                                    season: season, episode: episode, title: meta.name)
            handle(outcome)
        }
    }

    private func handle(_ outcome: TraktCheckinOutcome) {
        switch outcome {
        case .checkedIn:
            // The chip's own label flips to "Watching until …", which is the confirmation. No extra popup.
            break
        case .conflict(let until):
            conflictUntil = until
            showConflict = true
        case .failed(let message):
            errorMessage = message
            showError = true
        case .unavailable:
            // The action should not have been offered; saying nothing beats a popup the user cannot act on.
            break
        }
    }
}
