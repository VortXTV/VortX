import Combine
import Foundation

/// Process-wide "a fullscreen player is presented" signal, used to switch the ambient hero trailers OFF
/// while real playback runs.
///
/// WHY: on every platform the fullscreen player is presented OVER the browse UI, which stays mounted
/// underneath (opacity-hidden on tvOS, under a fullScreenCover on iOS / a hoisted host on macOS) - so a
/// mounted in-hero trailer (`InHeroTrailerView` / `TVInHeroTrailerView`) kept its own libmpv instance
/// decoding and re-fetching a looping 1080p trailer for the WHOLE movie: micro stutter, audio crackle,
/// and doubled bandwidth on every stream started while a hero clip was up (the 0.3.9 full-trailer hero
/// regression). The player screens drive this gate from onAppear/onDisappear; the hero views unmount
/// their clip while `playerActive` and remount when playback closes.
///
/// Main-thread only (SwiftUI appear/disappear callbacks and view bodies), so no locking is needed. The
/// two mutators are `@MainActor` so that isolation is compiler-enforced, matching `CoreBridge.setPlayerActive`.
final class FullscreenPlaybackGate: ObservableObject {
    static let shared = FullscreenPlaybackGate()
    private init() {}

    /// Number of mounted fullscreen player screens. A COUNT rather than a Bool because two players can
    /// briefly coexist during a SwiftUI `.id`-rebuild transition (the new one can appear before the old
    /// one disappears); the gate must stay closed across that overlap.
    @Published private(set) var activePlayers = 0

    /// True while at least one fullscreen player screen is mounted.
    var playerActive: Bool { activePlayers > 0 }

    @MainActor func playerDidAppear() { activePlayers += 1 }
    @MainActor func playerDidDisappear() { activePlayers = max(0, activePlayers - 1) }
}
