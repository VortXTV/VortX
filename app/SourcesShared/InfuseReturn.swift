import Foundation

/// One Infuse handoff waiting for Infuse to come back.
///
/// Infuse's documented x-callback API (support.firecore.com, "API for Third-Party Apps & Services"):
/// `play` takes `position` in whole seconds, and calls `x-success` once when its player closes,
/// appending `lastPlayedUrl` and `position` (seconds). It reports no duration, so the handoff keeps the
/// runtime VortX already knew when it launched Infuse. Persisted, because the system may end VortX
/// while Infuse plays and the callback then cold-launches it.
struct InfuseHandoff: Codable, Equatable {
    let token: String
    let stream: String
    let libraryId: String
    let videoId: String
    let type: String
    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?
    /// The profile that started playback; only that profile may receive the position.
    let profileID: String
    let durationSeconds: Double?
    let createdAt: Date
    /// Set once Infuse reported back and the position is waiting to be saved.
    var returnedPositionSeconds: Double?

    var meta: PlaybackMeta {
        PlaybackMeta(libraryId: libraryId, videoId: videoId, type: type, name: name,
                     poster: poster, season: season, episode: episode)
    }
}

enum InfuseReturnPolicy {
    static let successHost = "infuse-return"
    static let errorHost = "infuse-error"
    /// A handoff Infuse never answered is forgotten after this long.
    static let lifetime: TimeInterval = 24 * 3600
    static let maxPending = 8
    /// Closing Infuse within this many seconds of the start saves nothing, so a mistaken open can never
    /// wipe an existing resume point.
    static let minimumPositionSeconds = 5.0

    struct Callback: Equatable {
        let token: String
        let succeeded: Bool
        let lastPlayedURL: String?
        let positionSeconds: Double?
    }

    static func makeHandoff(token: String, stream: URL, meta: PlaybackMeta, profileID: String,
                            durationSeconds: Double?, now: Date) -> InfuseHandoff {
        InfuseHandoff(token: token, stream: stream.absoluteString, libraryId: meta.libraryId, videoId: meta.videoId,
                      type: meta.type, name: meta.name, poster: meta.poster, season: meta.season, episode: meta.episode,
                      profileID: profileID.lowercased(),
                      durationSeconds: durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                      createdAt: now, returnedPositionSeconds: nil)
    }

    /// `<scheme>://infuse-return/<token>`. The token rides in the path so Infuse can append its own query
    /// without any question of how it merges with ours.
    static func callbackURL(scheme: String, token: String, succeeded: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = succeeded ? successHost : errorHost
        components.path = "/" + token
        return components.url
    }

    /// The whole-second start Infuse accepts, or nil when playback should start at the beginning.
    static func startPosition(_ seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds >= 1, seconds < 86_400 * 2 else { return nil }
        return Int(seconds)
    }

    /// Parses an inbound URL as an Infuse callback. Any app can open our scheme, so everything is
    /// validated: an unknown host, a malformed token or a garbage position yields nil or no position.
    static func parse(_ url: URL, scheme: String) -> Callback? {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              let host = url.host?.lowercased(), host == successHost || host == errorHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let token = String(components.path.drop(while: { $0 == "/" }))
        guard isToken(token) else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        let position = query["position"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 && $0 < 86_400 * 2 ? $0 : nil }
        return Callback(token: token, succeeded: host == successHost,
                        lastPlayedURL: query["lastPlayedUrl"].flatMap { $0.isEmpty ? nil : $0 },
                        positionSeconds: position)
    }

    static func isToken(_ value: String) -> Bool {
        value.count == 32 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    /// The position to save and the duration to save it against, or nil when this return must not
    /// touch the user's progress.
    static func progress(for handoff: InfuseHandoff, callback: Callback) -> (position: Double, duration: Double)? {
        guard callback.succeeded, let position = callback.positionSeconds, position >= minimumPositionSeconds,
              let duration = handoff.durationSeconds, duration > 0 else { return nil }
        if let played = callback.lastPlayedURL, normalized(played) != normalized(handoff.stream) { return nil }
        // A runtime from metadata can be shorter than the actual cut; past the end means finished.
        return (min(position, duration), duration)
    }

    /// Drops expired entries and keeps the newest few.
    static func pruned(_ handoffs: [InfuseHandoff], now: Date) -> [InfuseHandoff] {
        let live = handoffs.filter { now.timeIntervalSince($0.createdAt) < lifetime && $0.createdAt <= now.addingTimeInterval(60) }
        return Array(live.sorted { $0.createdAt > $1.createdAt }.prefix(maxPending))
    }

    private static func normalized(_ url: String) -> String {
        (url.removingPercentEncoding ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
