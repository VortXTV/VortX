import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Drives the system Now Playing surface and routes its remote controls back into the player, on EVERY Apple
/// surface: the Apple TV Control Center "Now Playing" card and Siri Remote transport (tvOS), the Lock Screen
/// and Control Center (iOS), and the menu-bar / media-key surface (macOS).
///
/// #157: tvOS was registering nothing at all. The audio session was already correct on both engines
/// (`MPVMetalViewController.configureAudioSession` for libmpv, `AVPlayerAudioSession.activateForMovie` for
/// AVPlayer), but this type - the ONLY caller of `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` in the
/// app - was wired solely from `Sources/PlayerScreen.swift`, which the tvOS targets do not compile. So tvOS
/// held an active `.playback` session while telling the system nothing was playing: no Now Playing card, no
/// system-level transport, no media state for the routing overlays.
///
/// This is deliberately ENGINE-AGNOSTIC. Both players emit the same `MPVProperty.timePos` / `.pause`
/// property stream (libmpv natively, `AVPlayerEngineController` by synthesising it), so one wiring in each
/// player chrome covers libmpv AND AVPlayer, including the Dolby Vision remux lane, with no engine branch.
///
/// Threading: main-thread-only by construction. Every caller is a SwiftUI player chrome running on the main
/// actor, and `MPRemoteCommand` targets are delivered on the main thread, so the static state below is never
/// touched concurrently. Kept un-isolated (rather than `@MainActor`) so the command handlers can act
/// synchronously, exactly as the shipping iOS wiring already did.
enum NowPlayingCenter {

    // MARK: - State (main thread only)

    /// The item currently published, so an ordinary position tick can be told apart from a real item change
    /// (a binge advance, an in-player source hop) that must re-push title + artwork immediately.
    private static var publishedIdentity: String?
    /// Wall clock of the last real push, for the refresh throttle.
    private static var lastPushAt: Double = 0
    /// The last (rate, duration) pushed, so a play/pause or a newly-known duration is never throttled away.
    private static var lastRate: Double = -1
    private static var lastDuration: Double = -1
    /// The last position pushed. With `lastPushAt` and `lastRate` this reconstructs the play head the system
    /// is currently extrapolating, which is how every seek path re-publishes without announcing itself.
    private static var lastElapsed: Double = 0

    /// The resolved artwork and the URL it was resolved from, so the poster is fetched ONCE per item and
    /// re-attached to every subsequent push for free.
    private static var artwork: MPMediaItemArtwork?
    private static var artworkURL: String?
    private static var artworkTask: Task<Void, Never>?

    // MARK: - Publishing

    /// Publish (or refresh) what is playing. Safe to call on every player tick: an unchanged item is throttled
    /// to `NowPlayingPolicy.refreshInterval`, and anything the system cannot extrapolate (a pause, a speed
    /// change, a newly-known duration, a different episode) pushes immediately.
    ///
    /// - Parameter force: push regardless of the throttle. Pass `true` right after a committed seek, where
    ///   the system's extrapolated position is now wrong by the whole seek distance.
    static func update(item: NowPlayingItem,
                       elapsed: Double,
                       duration: Double,
                       paused: Bool,
                       speed: Double = 1.0,
                       force: Bool = false) {
        let rate = NowPlayingPolicy.rate(paused: paused, speed: speed)
        let publishedDuration = NowPlayingPolicy.publishableDuration(duration, isLive: item.isLive)
        let publishedElapsed = NowPlayingPolicy.publishableElapsed(elapsed, duration: publishedDuration)
        let identity = item.identity
        let itemChanged = identity != publishedIdentity
        let now = Date().timeIntervalSinceReferenceDate
        // A seek of any kind (skip buttons, scrub commit, skip-intro pill, chapter jump, restart) shows up
        // here as the published play head diverging from what the system is extrapolating, so NO seek call
        // site has to announce itself: they are all covered by this one check.
        let drifted = NowPlayingPolicy.positionDrifted(elapsed: publishedElapsed,
                                                       lastElapsed: lastElapsed,
                                                       lastPush: lastPushAt,
                                                       now: now,
                                                       rate: lastRate)
        let stateChanged = rate != lastRate || (publishedDuration ?? 0) != lastDuration || drifted

        if itemChanged { beginArtwork(for: item) }

        guard NowPlayingPolicy.shouldPush(now: now,
                                          lastPush: lastPushAt,
                                          itemChanged: itemChanged,
                                          stateChanged: stateChanged,
                                          force: force) else { return }

        publishedIdentity = identity
        lastPushAt = now
        lastRate = rate
        lastDuration = publishedDuration ?? 0
        lastElapsed = publishedElapsed
        push(item: item, elapsed: publishedElapsed, duration: publishedDuration, rate: rate)
    }

    /// Build the dictionary and hand it to the system. Split out so `artworkArrived` can re-push the SAME
    /// item once the poster decodes without re-deriving any of the decisions above.
    private static func push(item: NowPlayingItem, elapsed: Double, duration: Double?, rate: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: NowPlayingPolicy.primaryTitle(for: item),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // Without this the system treats the session as AUDIO and renders the card with music chrome
            // instead of presenting it as a video Now Playing session.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive,
        ]
        if let secondary = NowPlayingPolicy.secondaryLine(for: item) {
            info[MPMediaItemPropertyArtist] = secondary
        }
        if let season = NowPlayingPolicy.seasonLine(for: item) {
            info[MPMediaItemPropertyAlbumTitle] = season
        }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        #if os(macOS)
        // macOS ONLY, and required there: MPNowPlayingInfoCenter's own header states that playback state
        // "cannot be determined by the application's audio session" on macOS and that this property must be
        // set every time the app begins or halts playback, or remote control may not work as expected. iOS
        // and tvOS derive the same state from the active AVAudioSession, so setting it there is redundant.
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
        #endif
    }

    // MARK: - Artwork

    /// Kick off (or skip) the poster fetch for a newly published item. The fetch happens off the main thread
    /// in `PosterImageLoader` (dedicated cache + bounded concurrency), so a missing or slow poster NEVER
    /// delays the Now Playing card: the card publishes immediately and the art is attached when it lands.
    private static func beginArtwork(for item: NowPlayingItem) {
        let url = item.artworkURL
        guard url != artworkURL else { return }   // same art as the outgoing item: keep it, no refetch
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = url
        guard let url, !url.isEmpty else { return }
        let identity = item.identity
        artworkTask = Task { @MainActor in
            guard let image = await PosterImageLoader.load(url, maxPixel: 600) else { return }
            guard !Task.isCancelled, identity == publishedIdentity else { return }   // item moved on: drop it
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artworkArrived()
        }
    }

    /// Re-push the CURRENT dictionary with the artwork attached. Mutating the published dictionary (rather
    /// than rebuilding it) means a late poster cannot disturb the published position or rate.
    private static func artworkArrived() {
        guard let artwork, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote commands

    /// Wire the system transport (Control Center, the Siri Remote's play/pause, Lock Screen buttons, media
    /// keys) to the player. Call once per playback, at first frame.
    ///
    /// `play` and `pause` are DISTINCT from `togglePause` on purpose. They used to all run the same toggle,
    /// which meant an explicit "play" from Control Center while already playing PAUSED the film (and the
    /// reverse), because the system sends the command it wants, never a toggle.
    ///
    /// - Parameters:
    ///   - seekBy: signed delta in seconds, for the skip buttons.
    ///   - seekTo: absolute position, for a drag on the system progress bar.
    ///   - canScrub: whether position control is meaningful (false for live / durationless streams, where the
    ///     commands stay disabled instead of silently swallowing the input).
    static func wireCommands(play: @escaping () -> Void,
                             pause: @escaping () -> Void,
                             togglePause: @escaping () -> Void,
                             seekBy: @escaping (Double) -> Void,
                             seekTo: @escaping (Double) -> Void,
                             stepSeconds: Double,
                             canScrub: Bool) {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.removeTarget(nil)
        c.playCommand.isEnabled = true
        c.playCommand.addTarget { _ in play(); return .success }

        c.pauseCommand.removeTarget(nil)
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { _ in pause(); return .success }

        c.togglePlayPauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { _ in togglePause(); return .success }

        let step = [NSNumber(value: stepSeconds)]
        c.skipForwardCommand.preferredIntervals = step
        c.skipForwardCommand.removeTarget(nil)
        c.skipForwardCommand.isEnabled = canScrub
        c.skipForwardCommand.addTarget { _ in seekBy(stepSeconds); return .success }

        c.skipBackwardCommand.preferredIntervals = step
        c.skipBackwardCommand.removeTarget(nil)
        c.skipBackwardCommand.isEnabled = canScrub
        c.skipBackwardCommand.addTarget { _ in seekBy(-stepSeconds); return .success }

        // The system progress bar's own drag. Without this the Now Playing card draws a scrub bar that does
        // nothing when moved.
        c.changePlaybackPositionCommand.removeTarget(nil)
        c.changePlaybackPositionCommand.isEnabled = canScrub
        c.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seekTo(event.positionTime)
            return .success
        }

        // Explicitly off: left enabled with no target these still advertise themselves to the system, which
        // draws dead next/previous buttons on the card. Episode navigation lives in the player's own chrome.
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
    }

    /// Update ONLY the position-command enablement, for the case where a stream's duration arrives after
    /// first frame (durationless debrid MKVs) and position control becomes meaningful mid-playback.
    static func setScrubbingEnabled(_ enabled: Bool) {
        let c = MPRemoteCommandCenter.shared()
        guard c.changePlaybackPositionCommand.isEnabled != enabled else { return }
        c.changePlaybackPositionCommand.isEnabled = enabled
        c.skipForwardCommand.isEnabled = enabled
        c.skipBackwardCommand.isEnabled = enabled
    }

    // MARK: - Teardown

    /// Tear the Now Playing session down when the player closes. Clearing the info dictionary is what removes
    /// the card from Control Center; dropping the targets is what stops a stale closure holding the last
    /// player alive and swallowing transport presses meant for whatever plays next.
    static func clear() {
        artworkTask?.cancel(); artworkTask = nil
        artwork = nil; artworkURL = nil
        publishedIdentity = nil
        lastPushAt = 0; lastRate = -1; lastDuration = -1; lastElapsed = 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
         c.skipForwardCommand, c.skipBackwardCommand,
         c.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
    }
}
