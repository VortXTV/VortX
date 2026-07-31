// Executable harness for the system Now Playing decisions (#157): what the Apple TV Control Center card /
// iOS Lock Screen / Mac menu bar is told, and WHEN it is told.
//
//   xcrun swiftc -o /tmp/nowplaying-policy-test \
//     app/SourcesShared/NowPlayingPolicy.swift \
//     app/Tests/NowPlayingPolicyTests.swift && /tmp/nowplaying-policy-test
//
// This suite CALLS the production decisions. Every one of them lives in `NowPlayingPolicy` precisely so it
// can be exercised here rather than only inside PlayerScreen / TVPlayerView (which pull in SwiftUI +
// MediaPlayer + AVFoundation and could only be asserted on as source text).
//
// The properties that matter:
//   1. The card is ENGINE-AGNOSTIC and STATE-DRIVEN: nothing here knows about libmpv or AVPlayer.
//   2. Ordinary playback is THROTTLED (the system extrapolates the play head itself), but anything the
//      system cannot extrapolate - a pause, a speed change, a newly-known duration, a different episode,
//      and above all a SEEK - pushes immediately. The seek case is covered by drift detection rather than
//      by every seek call site announcing itself, so no future seek path can forget to.
//   3. Live and durationless streams publish NO duration and offer NO scrubbing, so the system never draws
//      a progress bar that lies or a scrub that the engine ignores.

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
enum NowPlayingPolicyTests {
    @MainActor static func main() { run() }

    static let movie = NowPlayingItem(title: "Dune: Part Two", artworkURL: "https://art/dune.jpg")
    static let episode = NowPlayingItem(title: "The Kingsroad",
                                        showName: "Game of Thrones",
                                        season: 1, episode: 2,
                                        artworkURL: "https://art/got.jpg")
    static let live = NowPlayingItem(title: "Sky News", isLive: true)

    @MainActor static func run() {
        identity()
        titles()
        rates()
        durationsAndElapsed()
        scrubbing()
        throttle()
        drift()
        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        if failures > 0 { exit(1) }
    }

    // MARK: identity

    @MainActor static func identity() {
        check("same item has a stable identity", movie.identity == movie.identity)
        var nextEpisode = episode
        nextEpisode.episode = 3
        nextEpisode.title = "Lord Snow"
        check("a binge advance changes identity", nextEpisode.identity != episode.identity)

        // A title containing the separator must not be able to forge another item's identity.
        let a = NowPlayingItem(title: "A", showName: "B")
        let b = NowPlayingItem(title: "B", showName: "A")
        check("identity is not order-collapsible", a.identity != b.identity)

        // Two different shows with the same episode title stay distinct.
        var otherShow = episode
        otherShow.showName = "Andor"
        check("same episode title on a different show is a different item",
              otherShow.identity != episode.identity)
    }

    // MARK: title lines

    @MainActor static func titles() {
        check("movie title is published as-is", NowPlayingPolicy.primaryTitle(for: movie) == "Dune: Part Two")
        check("movie has no secondary line", NowPlayingPolicy.secondaryLine(for: movie) == nil)
        check("movie has no season line", NowPlayingPolicy.seasonLine(for: movie) == nil)

        check("episode secondary line carries show + code",
              NowPlayingPolicy.secondaryLine(for: episode) == "Game of Thrones · S01E02")
        check("episode season line", NowPlayingPolicy.seasonLine(for: episode) == "Season 1")

        // The chrome title often ALREADY carries the show name; do not print it twice.
        var redundant = episode
        redundant.title = "Game of Thrones - The Kingsroad"
        check("show name is dropped when the title already carries it",
              NowPlayingPolicy.secondaryLine(for: redundant) == "S01E02")

        // Add-on metadata routinely carries 0 for "unknown"; a movie must never render S00E00.
        let zeroed = NowPlayingItem(title: "Movie", showName: nil, season: 0, episode: 0)
        check("zero season/episode is treated as absent", NowPlayingPolicy.episodeCode(season: 0, episode: 0) == nil)
        check("zeroed item has no secondary line", NowPlayingPolicy.secondaryLine(for: zeroed) == nil)
        check("seasonless episode still gets a code", NowPlayingPolicy.episodeCode(season: nil, episode: 7) == "E07")
        check("a season without an episode is not a season line",
              NowPlayingPolicy.seasonLine(for: NowPlayingItem(title: "x", season: 2, episode: nil)) == nil)

        // An empty title reads as a broken card, never as "no metadata".
        check("empty title falls back to the show name",
              NowPlayingPolicy.primaryTitle(for: NowPlayingItem(title: "   ", showName: "Severance")) == "Severance")
        check("empty title and no show falls back to the product name",
              NowPlayingPolicy.primaryTitle(for: NowPlayingItem(title: "")) == "VortX")
    }

    // MARK: rate

    @MainActor static func rates() {
        check("playing at 1x publishes rate 1", NowPlayingPolicy.rate(paused: false, speed: 1) == 1)
        check("paused publishes rate 0", NowPlayingPolicy.rate(paused: true, speed: 1) == 0)
        check("paused at 1.5x still publishes rate 0", NowPlayingPolicy.rate(paused: true, speed: 1.5) == 0)
        check("the player's speed is carried through", NowPlayingPolicy.rate(paused: false, speed: 1.5) == 1.5)
        check("a nonsense speed degrades to 1", NowPlayingPolicy.rate(paused: false, speed: 0) == 1)
        check("a NaN speed degrades to 1", NowPlayingPolicy.rate(paused: false, speed: .nan) == 1)
    }

    // MARK: duration + elapsed

    @MainActor static func durationsAndElapsed() {
        check("a VOD duration is published", NowPlayingPolicy.publishableDuration(7200, isLive: false) == 7200)
        check("live publishes no duration", NowPlayingPolicy.publishableDuration(7200, isLive: true) == nil)
        check("a durationless stream publishes no duration",
              NowPlayingPolicy.publishableDuration(0, isLive: false) == nil)
        check("an infinite duration publishes no duration",
              NowPlayingPolicy.publishableDuration(.infinity, isLive: false) == nil)

        check("elapsed is never negative", NowPlayingPolicy.publishableElapsed(-5, duration: 100) == 0)
        check("elapsed is clamped to the duration", NowPlayingPolicy.publishableElapsed(120, duration: 100) == 100)
        check("elapsed passes through in range", NowPlayingPolicy.publishableElapsed(42, duration: 100) == 42)
        check("elapsed is unclamped when there is no duration",
              NowPlayingPolicy.publishableElapsed(9999, duration: nil) == 9999)
        check("a NaN elapsed degrades to 0", NowPlayingPolicy.publishableElapsed(.nan, duration: 100) == 0)
    }

    // MARK: scrubbing

    @MainActor static func scrubbing() {
        check("a VOD with a duration allows scrubbing",
              NowPlayingPolicy.allowsScrubbing(duration: 5400, isLive: false))
        check("live never allows scrubbing", !NowPlayingPolicy.allowsScrubbing(duration: 5400, isLive: true))
        check("a durationless stream does not allow scrubbing",
              !NowPlayingPolicy.allowsScrubbing(duration: 0, isLive: false))
    }

    // MARK: push throttle

    @MainActor static func throttle() {
        check("the first push always goes out",
              NowPlayingPolicy.shouldPush(now: 100, lastPush: 0, itemChanged: false, stateChanged: false))
        check("an unchanged item inside the window is throttled",
              !NowPlayingPolicy.shouldPush(now: 101, lastPush: 100, itemChanged: false, stateChanged: false))
        check("an unchanged item past the window refreshes",
              NowPlayingPolicy.shouldPush(now: 100 + NowPlayingPolicy.refreshInterval,
                                          lastPush: 100, itemChanged: false, stateChanged: false))
        check("a new episode is never throttled",
              NowPlayingPolicy.shouldPush(now: 100.1, lastPush: 100, itemChanged: true, stateChanged: false))
        check("a play/pause is never throttled",
              NowPlayingPolicy.shouldPush(now: 100.1, lastPush: 100, itemChanged: false, stateChanged: true))
        check("force overrides the window",
              NowPlayingPolicy.shouldPush(now: 100.1, lastPush: 100, itemChanged: false, stateChanged: false, force: true))
        check("a backwards clock never stalls the surface",
              NowPlayingPolicy.shouldPush(now: 50, lastPush: 100, itemChanged: false, stateChanged: false))
    }

    // MARK: seek detection (drift)

    @MainActor static func drift() {
        // Ordinary playback: the system's extrapolation is right, so nothing is forced.
        check("steady playback does not read as drift",
              !NowPlayingPolicy.positionDrifted(elapsed: 61, lastElapsed: 60, lastPush: 100, now: 101, rate: 1))
        check("steady playback at 1.5x does not read as drift",
              !NowPlayingPolicy.positionDrifted(elapsed: 63, lastElapsed: 60, lastPush: 100, now: 102, rate: 1.5))
        check("a paused player does not read as drift",
              !NowPlayingPolicy.positionDrifted(elapsed: 60, lastElapsed: 60, lastPush: 100, now: 130, rate: 0))

        // Every seek surface lands far outside the tolerance, which is what makes them all self-correcting.
        check("a +10s skip reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 71, lastElapsed: 60, lastPush: 100, now: 100.25, rate: 1))
        check("a -10s skip reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 50, lastElapsed: 60, lastPush: 100, now: 100.25, rate: 1))
        check("a scrub commit across the film reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 3600, lastElapsed: 60, lastPush: 100, now: 100.25, rate: 1))
        check("a restart to zero reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 0, lastElapsed: 1800, lastPush: 100, now: 100.25, rate: 1))
        check("resuming from a long pause at a new position reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 900, lastElapsed: 60, lastPush: 100, now: 160, rate: 0))

        // Degenerate inputs must fail SAFE (push), never latch the card on a stale position.
        check("nothing pushed yet reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 10, lastElapsed: 0, lastPush: 0, now: 100, rate: 1))
        check("a backwards clock reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: 10, lastElapsed: 10, lastPush: 100, now: 50, rate: 1))
        check("a NaN position reads as drift",
              NowPlayingPolicy.positionDrifted(elapsed: .nan, lastElapsed: 10, lastPush: 100, now: 101, rate: 1))
    }
}
