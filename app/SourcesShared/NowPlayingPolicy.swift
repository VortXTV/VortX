import Foundation

/// One item's identity + display metadata for the system Now Playing surface (the Apple TV Control Center
/// widget, the iOS Lock Screen, the Mac menu bar).
///
/// Deliberately a plain Foundation value type: no MediaPlayer, no SwiftUI, no engine. That is what lets
/// `NowPlayingPolicy` below (every decision that shapes what the system shows) be exercised by a standalone
/// `swiftc` harness instead of only inside PlayerScreen / TVPlayerView, which drag in SwiftUI + AVFoundation.
struct NowPlayingItem: Equatable {
    /// The chrome's own title for what is playing (an episode label for a series, the film name for a movie).
    var title: String
    /// The series name, when this is an episode. `nil` for a movie / a one-off stream.
    var showName: String?
    var season: Int?
    var episode: Int?
    /// Poster / art URL string, loaded asynchronously and attached once (never blocks a push).
    var artworkURL: String?
    /// Live content has no meaningful duration or scrub position, so the system is told so explicitly.
    var isLive: Bool

    init(title: String,
         showName: String? = nil,
         season: Int? = nil,
         episode: Int? = nil,
         artworkURL: String? = nil,
         isLive: Bool = false) {
        self.title = title
        self.showName = showName
        self.season = season
        self.episode = episode
        self.artworkURL = artworkURL
        self.isLive = isLive
    }

    /// Stable key for "is the system still being told about the SAME thing?". A binge advance changes the
    /// episode fields, which is exactly when the Now Playing surface must be re-pushed in full (new title,
    /// new artwork) instead of being throttled as an ordinary position tick. Uses a control character as the
    /// separator so a title containing the separator can never forge another item's identity.
    var identity: String {
        [showName ?? "", title, season.map(String.init) ?? "", episode.map(String.init) ?? ""]
            .joined(separator: "\u{1}")
    }
}

/// Every decision that shapes the system Now Playing surface, kept pure so it is testable and identical on
/// tvOS, iOS and macOS. `NowPlayingCenter` is the thin MediaPlayer shell that applies these.
enum NowPlayingPolicy {
    /// Minimum wall-clock gap between two pushes of an OTHERWISE UNCHANGED item. The system extrapolates the
    /// elapsed time from the last (elapsed, rate) pair it was given, so pushing a fresh dictionary at the
    /// player's 4 Hz tick rate is pure XPC churn: MPNowPlayingInfoCenter's own header says updating elapsed
    /// frequently "is not required (or recommended)". A push every couple of seconds keeps the widget's
    /// clock honest after seeks and rate changes without the churn.
    static let refreshInterval: Double = 2.0

    /// How far the system's EXTRAPOLATED play head may drift from the player's real position before a fresh
    /// push is required. This is what makes every seek path self-correcting without a single call site having
    /// to announce itself: a ±10s skip, a scrub commit, a skip-intro jump, a chapter jump and a restart all
    /// land far outside this window, so the very next tick re-publishes, while ordinary playback (where the
    /// extrapolation is right to within the tick interval) stays throttled.
    static let driftTolerance: Double = 1.5

    /// Whether the position the system is currently extrapolating has diverged from reality. `lastElapsed`
    /// and `lastPush` are the (position, wall clock) pair the system was last given; it advances that pair at
    /// `rate`, so this reconstructs what it believes and compares.
    static func positionDrifted(elapsed: Double,
                                lastElapsed: Double,
                                lastPush: Double,
                                now: Double,
                                rate: Double) -> Bool {
        guard lastPush > 0, elapsed.isFinite, lastElapsed.isFinite, now >= lastPush else { return true }
        let extrapolated = lastElapsed + rate * (now - lastPush)
        return abs(elapsed - extrapolated) > driftTolerance
    }

    /// Whether this tick should actually reach `MPNowPlayingInfoCenter`.
    /// - `itemChanged`: a different title/episode is playing (binge advance, in-player source hop).
    /// - `stateChanged`: play/pause, speed, or a newly known duration - all things the system cannot
    ///   extrapolate and must be told about immediately.
    /// - `force`: a committed seek, where the extrapolated position is now wrong by the seek distance.
    static func shouldPush(now: Double,
                           lastPush: Double,
                           itemChanged: Bool,
                           stateChanged: Bool,
                           force: Bool = false) -> Bool {
        if force || itemChanged || stateChanged { return true }
        if lastPush <= 0 { return true }          // nothing pushed yet this playback
        if now < lastPush { return true }         // clock moved backwards: never stall on a bad stamp
        return now - lastPush >= refreshInterval
    }

    /// The title line. Falls back to the show name, then to the product name, because an EMPTY title reads
    /// as a broken Now Playing card rather than as "no metadata".
    static func primaryTitle(for item: NowPlayingItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let show = (item.showName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return show.isEmpty ? "VortX" : show
    }

    /// The secondary line (the artist slot on every Apple Now Playing surface): the show name plus the
    /// episode code. The show name is dropped when the title already carries it, so a chrome title like
    /// "Severance - S02E03" does not render as "Severance - S02E03 / Severance - S02E03".
    static func secondaryLine(for item: NowPlayingItem) -> String? {
        var parts: [String] = []
        let show = (item.showName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !show.isEmpty, !item.title.localizedCaseInsensitiveContains(show) { parts.append(show) }
        if let code = episodeCode(season: item.season, episode: item.episode) { parts.append(code) }
        let line = parts.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// "S02E03" / "E03", or nil when this is not an episode. Zero and negative numbers are treated as absent
    /// (add-on metadata routinely carries 0 for "unknown"), so a movie never gets a bogus "S00E00".
    static func episodeCode(season: Int?, episode: Int?) -> String? {
        guard let episode, episode > 0 else { return nil }
        if let season, season > 0 { return String(format: "S%02dE%02d", season, episode) }
        return String(format: "E%02d", episode)
    }

    /// The album slot: the season, when there is one. Never invented for a movie.
    static func seasonLine(for item: NowPlayingItem) -> String? {
        guard let season = item.season, season > 0, item.episode != nil else { return nil }
        return "Season \(season)"
    }

    /// The rate the system should extrapolate the play head with. 0 means paused (which is how EVERY Apple
    /// Now Playing surface renders the pause state), and the player's own speed setting is carried through so
    /// a 1.5x watch does not drift against the widget's clock.
    static func rate(paused: Bool, speed: Double) -> Double {
        guard !paused else { return 0 }
        guard speed.isFinite, speed > 0 else { return 1 }
        return speed
    }

    /// The duration to publish, or nil when there is none to publish. A live stream deliberately publishes no
    /// duration: its "position" is elapsed wall clock of the buffer, and a duration would make the widget
    /// render a bogus, scrubbable progress bar. A durationless VOD (many debrid direct-HTTP MKVs never deliver
    /// the duration event) simply omits it until a real value lands.
    static func publishableDuration(_ duration: Double, isLive: Bool) -> Double? {
        guard !isLive, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// The elapsed time to publish: never negative, never past a known duration, never NaN. An out-of-range
    /// elapsed makes the system's extrapolation run away, which is what shows a Now Playing card counting
    /// past the end of the film.
    static func publishableElapsed(_ elapsed: Double, duration: Double?) -> Double {
        guard elapsed.isFinite else { return 0 }
        let floored = max(0, elapsed)
        guard let duration else { return floored }
        return min(floored, duration)
    }

    /// Whether the system should be offered absolute scrubbing (the Control Center / Lock Screen progress
    /// bar drag). Live content and durationless streams cannot honour it, so the command stays disabled there
    /// rather than accepting a drag that the engine then ignores.
    static func allowsScrubbing(duration: Double, isLive: Bool) -> Bool {
        publishableDuration(duration, isLive: isLive) != nil
    }
}
