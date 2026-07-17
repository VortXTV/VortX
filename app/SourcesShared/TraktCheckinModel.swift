import Foundation

/// The user-initiated Trakt CHECK-IN: "I'm watching this right now", for viewing that happens somewhere
/// VortX cannot see it. A cinema, someone else's TV, a broadcast. The title is on Trakt, the watching is
/// not on this device, and the only way Trakt can know is if the user says so.
///
/// WHY THIS IS NOT IN `ScrobbleCoordinator`: everything there is automatic, fire-and-forget and
/// result-less, driven by the player and the library actions. A check-in is the opposite on every axis:
/// a person asks for it explicitly, and they have to be told what happened, because it is the one Trakt
/// write that can legitimately be refused (see the conflict rules below). It still reuses the
/// coordinator's identity resolver and reads the same OWNER gate, so no policy is duplicated.
///
/// AUTHORITY (the independence directive): the VortX account is PRIMARY and owns all VortX data; Trakt is
/// an optional mirror, never a source of truth. Nothing in this file reads or writes ANY VortX state: no
/// engine `libraryItem`, no watched index, no resume position, no account doc, no UserDefaults beyond the
/// one toggle that decides whether the action is offered at all. A check-in is a statement made TO Trakt
/// about the outside world; it lives only on Trakt's endpoint. There is therefore no second writer to
/// VortX's data here and nothing to reconcile, which is exactly why this feature cannot corrupt anything
/// the way a two-way mirror of a field both systems claim to own could.
///
/// The one path by which a check-in can ever reach a VortX surface is indirect and pre-existing: when a
/// check-in expires, Trakt records the watch in the user's Trakt history, and IF the user has separately
/// opted into `traktImportWatched`, that history shows through the additive-read shadow cache. That path
/// never writes an engine `libraryItem`. It is also correct: they did watch it.
@MainActor
final class TraktCheckinModel: ObservableObject {
    static let shared = TraktCheckinModel()

    private init() {}

    // MARK: - State

    /// The check-in THIS app instance last made, so the button can offer to cancel it and can show when it
    /// runs out.
    ///
    /// DELIBERATELY IN-MEMORY AND NEVER PERSISTED. This is a UI convenience, NOT a mirror of Trakt's state,
    /// and treating it as one is precisely the trap: Trakt has no "read my active check-in" endpoint, the
    /// slot can be taken or freed by any other device at any moment, and a check-in expires on its own
    /// clock. A persisted copy would therefore drift out of agreement with Trakt with no way to notice, and
    /// then two records would disagree about the same fact. Instead Trakt stays the sole authority: this is
    /// dropped on relaunch, and the HTTP 409 corrects us for free whenever we are wrong.
    @Published private(set) var active: Active?

    /// True while a call is in flight, so the button can disable itself rather than fire twice.
    @Published private(set) var working = false

    struct Active: Equatable, Sendable {
        /// The item this instance checked into, so a detail page for a DIFFERENT title does not show a
        /// "cancel" affordance for something else.
        let key: String
        /// When Trakt says it auto-expires (nil when Trakt sent no readable expiry).
        let expiresAt: Date?
    }

    /// A stable per-item key, matching the granularity Trakt checks into: a movie, or one episode.
    static func key(id: String, season: Int?, episode: Int?) -> String {
        "\(id)|\(season.map(String.init) ?? "")|\(episode.map(String.init) ?? "")"
    }

    /// True when `key` is the item this instance currently believes it is checked into.
    func isActive(_ key: String) -> Bool { active?.key == key }

    // MARK: - Gates

    /// Whether the action may be OFFERED for this shape of title, before any network call.
    ///
    /// The async sign-in check is deliberately not here: this is the synchronous part the view can call
    /// while rendering. `checkIn` re-checks everything including sign-in.
    ///
    /// A series needs a concrete season + episode: Trakt checks into an EPISODE, never a whole show, so a
    /// series page with no resolved episode has nothing to send and must not offer the action.
    static func canOffer(isSeries: Bool, season: Int?, episode: Int?) -> Bool {
        guard TraktAuth.isConfigured else { return false }                      // dormant with no build creds
        guard ExternalSyncToggle.isOn(traktCheckinKey, default: false) else { return false }
        guard ProfileStore.shared.activeUsesEngineHistory else { return false } // OVERLAY/GUEST gate
        if isSeries { return season != nil && episode != nil }
        return true
    }

    /// Local alias so the default (`false`) can never drift from the key's documented default.
    private static let traktCheckinKey = ExternalSyncToggle.traktCheckin

    // MARK: - Actions

    /// Check in, reporting what happened.
    ///
    /// On HTTP 409 this returns `.conflict` and CHANGES NOTHING. It never quietly cancels whatever holds
    /// Trakt's single watching slot, because that incumbent may be a live scrobble of a real play on
    /// another device, and evicting it would destroy the record of something actually being watched. Only
    /// the user, told what is in the way and when it clears, may choose `replaceActive`.
    func checkIn(id: String, isSeries: Bool, season: Int?, episode: Int?, title: String?) async -> TraktCheckinOutcome {
        guard Self.canOffer(isSeries: isSeries, season: season, episode: episode) else { return .unavailable }
        guard await TraktAuth.shared.isSignedIn else { return .unavailable }
        guard !working else { return .unavailable }
        working = true
        defer { working = false }
        return await send(id: id, isSeries: isSeries, season: season, episode: episode, title: title)
    }

    /// Cancel whatever holds the slot, then check into this title. ONLY ever called from an explicit user
    /// confirmation that names what is being replaced: this is the single path allowed to discard another
    /// watch record, and it exists so that decision is always a person's, never a heuristic's.
    func replaceActive(id: String, isSeries: Bool, season: Int?, episode: Int?, title: String?) async -> TraktCheckinOutcome {
        guard Self.canOffer(isSeries: isSeries, season: season, episode: episode) else { return .unavailable }
        guard await TraktAuth.shared.isSignedIn else { return .unavailable }
        guard !working else { return .unavailable }
        working = true
        defer { working = false }
        do { try await TraktService.shared.cancelCheckIn() }
        catch { return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        active = nil
        return await send(id: id, isSeries: isSeries, season: season, episode: episode, title: title)
    }

    /// Cancel the active check-in (`DELETE /checkin`). Returns false when Trakt refused, so the caller can
    /// leave the button alone rather than lie about the state.
    @discardableResult
    func cancelActive() async -> Bool {
        guard TraktAuth.isConfigured, await TraktAuth.shared.isSignedIn else { return false }
        guard !working else { return false }
        working = true
        defer { working = false }
        do {
            try await TraktService.shared.cancelCheckIn()
            active = nil
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internals

    /// Resolve identity through the shared resolver, map it the same way the scrobble path does, and post.
    private func send(id: String, isSeries: Bool, season: Int?, episode: Int?, title: String?) async -> TraktCheckinOutcome {
        guard let ref = await ScrobbleCoordinator.makeRef(libraryId: id, isSeries: isSeries,
                                                          season: season, episode: episode,
                                                          title: title, progress: 0),
              let item = TraktProvider.scrobbleItem(ref) else { return .unavailable }
        do {
            let response = try await TraktService.shared.checkIn(item: item)
            let expires = TraktDate.parse(response.expiresAt)
            active = Active(key: Self.key(id: id, season: season, episode: episode), expiresAt: expires)
            return .checkedIn(until: expires)
        } catch let error as TraktServiceError {
            if case .alreadyCheckedIn(let until) = error {
                // `active` is deliberately left alone. A 409 says the slot is held; it does NOT say by
                // what. The incumbent is quite often this instance's OWN earlier check-in still running,
                // so clearing `active` here would throw away a belief that is probably right and take the
                // user's cancel button with it. Report the conflict and change nothing.
                return .conflict(until: until)
            }
            return .failed(error.errorDescription ?? "\(error)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What a check-in attempt did. `Equatable` so a view can drive state off it without identity games.
enum TraktCheckinOutcome: Sendable, Equatable {
    /// Trakt accepted it. `until` is when it auto-expires (nil when Trakt sent no readable expiry).
    case checkedIn(until: Date?)
    /// Trakt's single watching slot is already held. `until` is when it frees up (nil when unknown).
    /// NOTHING was changed on Trakt: the caller decides whether to ask the user about replacing it.
    case conflict(until: Date?)
    /// Not possible or not offered: no build creds, toggle off, overlay/guest profile, signed out, or the
    /// title carries no id Trakt could match. Callers report nothing; the action should not have shown.
    case unavailable
    /// Trakt refused or the network failed; the message is user-facing.
    case failed(String)
}
