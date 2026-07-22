import Foundation

/// Surface-side ownership contract for a TERMINAL load failure (REQ-260721-78, option A).
///
/// The failure this pins down: on a terminal native-HLS Dolby Vision failure the surface used to set
/// its terminal flag and leave the AVFoundation controller live, so a delayed
/// `preferredDisplayCriteria` completion could still switch the display mode, attach the item, and
/// begin playback BEHIND an overlay that had already declared the load dead. Option A closes that
/// window on the surface side: the engine is retired synchronously FIRST, and only then does the
/// terminal overlay publish. Retirement (AVPlayerEngineController.stop()) invalidates the load token
/// and advances the item generation, so every completion minted before the publication fails the
/// engine's ownership gate and is inert. Same shape as the debrid-crash straddle root cause, fixed
/// by stop-before-dismiss: the engine goes down before the surface state changes, never after.
///
/// Why a separate Foundation-only file: the surfaces that route through this decision (PlayerScreen,
/// TVPlayerView) pull in SwiftUI and AVFoundation and cannot compile in a standalone harness, and a
/// source-text assertion proves a line exists, not that it runs (see DVPlaybackPolicy's header for
/// the mutant that beat exactly that). Keeping the ordering here makes the property executable: the
/// contract test calls the real function against a token-gated engine model and must go RED when the
/// retire step is dropped or reordered.
enum TerminalLoadFailurePolicy {

    /// Whether the terminal presentation must retire the mounted engine before publishing.
    ///
    /// True only for the native (AVFoundation) engine: it is the engine that parks deferred
    /// display-criteria / pre-attach work able to fire after the overlay, and its stop() is
    /// recoverable (loadFile rebuilds asset, item, token and observers, so the overlay's Retry still
    /// works). libmpv must NOT be retired here: its stop() destroys the core outright
    /// (mpv_terminate_destroy; every later property access is a guarded no-op), which would turn the
    /// overlay's Retry into a silent dead end, and it parks no deferred pre-attach display work, so
    /// a terminal overlay over an idle mpv core has no late completion to fear.
    static func shouldRetireBeforePublish(engineIsNative: Bool) -> Bool {
        engineIsNative
    }

    /// The one legal ordering for going terminal: retire the engine synchronously, and only THEN
    /// publish the terminal overlay. Both closures always run, exactly once each, in that order. The
    /// caller passes a retire closure that is a no-op when `shouldRetireBeforePublish` says the
    /// mounted engine must be left alone.
    static func presentTerminal(retire: () -> Void, publish: () -> Void) {
        retire()
        publish()
    }
}
