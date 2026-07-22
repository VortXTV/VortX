#if DEBUG
import Foundation

/// DEBUG-ONLY headless playback entry point for the AVFoundation plain-remux/HLS lane.
///
/// Exists so the player-conformance harness (`test/player-conformance`) can stand up a live
/// plain-remux session on the Apple TV simulator with no human: today the only ways onto that
/// lane are a Settings toggle plus a remote-driven play, which `xcrun simctl` cannot drive.
/// Two triggers, one shared seam:
///
///   1. Launch environment (cold start, deterministic; simctl passes env via
///      SIMCTL_CHILD_-prefixed vars in the calling environment):
///        SIMCTL_CHILD_VORTX_DEBUG_PLAY_URL=<url> xcrun simctl launch <udid> com.stremiox.tv
///      Optional `VORTX_DEBUG_PLAY_TITLE` names the session (display only).
///   2. Deep link (MANUAL CONVENIENCE ONLY, never automation):
///        xcrun simctl openurl <udid> "vortx://debug-play?url=<percent-encoded url>"
///      NOT HEADLESS. Verified on tvOS 26.5 / Apple TV 4K (3rd gen): tvOS gates EVERY
///      `simctl openurl` behind a system `Open in "VortX"?` / Open / Cancel confirmation,
///      whether the app is backgrounded or already foregrounded, and the URL is not
///      delivered to `onOpenURL` until a human presses Open on the remote. Do not script
///      it: an unattended run hangs to timeout with no marker ever written. The harness
///      uses trigger 1 for BOTH cold start and re-trigger (relaunching is fully headless
///      and mints a fresh session, which is better for conformance determinism anyway).
///      See test/player-conformance/DEBUG-PLAYBACK-HOOK.md.
///
/// Both funnel into `requestPlayback`, which:
///   - VALIDATES the URL and REJECTS LOUDLY (a diagnostics line, no playback) any input that
///     would silently land in the libmpv lane instead: non-http(s) schemes, loopback hosts
///     (router rule 1 and the remux candidacy gate both veto loopback), and URLs carrying no
///     Matroska evidence (the plain-remux candidacy needs an explicit `.mkv` extension or an
///     mkv/matroska token in the filename/query). A silent demote to libmpv is exactly the
///     failure this hook exists to eliminate, so a rejected URL must be unmistakable.
///   - PINS the three UserDefaults the lane depends on, BEFORE the request is assigned (the
///     player latches its engine route once per playback in onAppear): the shipping engine
///     override to `avfoundation` (router rule 2 — the only way a non-DV MKV routes to
///     AVFoundation), and the two lane flags to true so a fetched RemoteConfig snapshot can
///     never disable the lane out from under a conformance run. Prior values are logged.
///   - issues `presenter.request = PlaybackRequest(url:title:startFromZero: true)` after the
///     same 1.5 s shell-settle delay the existing `-tv-playertest` diagnostic uses
///     (VortXTVApp). `meta` stays nil so no resume lookup runs; `sourceHint` stays nil so the
///     stream can never read as Dolby Vision; a fresh request id makes RootView rebuild the
///     player cleanly even when a previous session is still mounted (warm re-trigger).
///
/// MACHINE-READABLE MARKERS (the harness waits on these; keep the strings stable):
///   accepted:  `debug-play accept trigger=<env|deeplink> token=<id:xxxxxx>`
///              ` engineOverride=avfoundation dvRemuxHLS=true plainRemux=true startFromZero=true`
///   rejected:  `debug-play reject trigger=<env|deeplink> reason=<reason> token=<id:xxxxxx|->`
/// written via `DiagnosticsLog` under category `debughook`, i.e. lines in Caches/diagnostics.log
/// of the form `<timestamp> [debughook] debug-play accept …`. The token is
/// `VXProbeRedaction.identityToken(<final path component>)` — the SAME producer-side token the
/// player's `route file=<token> …` line uses, so one grep correlates accept -> route -> mount
/// within a run without the raw URL ever being written (diagnostics.log is always on; raw
/// URLs / release names do not belong in it).
///
/// DELIBERATELY DECOUPLED from the player sources: the UserDefaults keys and the candidacy
/// predicate are mirrored as literals here (each annotated with its source of truth) instead of
/// referencing `PlayerEngineRouter` / `VortXRemuxHLSServer` symbols, so the player lane can be
/// reworked without this debug file participating in the build graph of that change. If a
/// mirrored value drifts, the conformance gate turns RED (the route line stops saying
/// `engine=avfoundation`), which is the failure mode we accept in exchange for zero coupling.
///
/// The ENTIRE file body compiles only under `#if DEBUG` (the generated Debug configuration
/// carries `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`; Release carries no such condition),
/// and both call sites in `VortXTVApp` are `#if DEBUG`-gated too: a Release build contains no
/// trace of the hook, and `vortx://debug-play` falls through to the normal deep-link router
/// there, which ignores it as "not ours".
@MainActor
enum DebugPlaybackHook {

    // MARK: - Mirrored constants (annotated with their source of truth; see header for why mirrored)

    /// UserDefaults key of the shipping engine override — mirrors
    /// `PlayerEngineRouter.overrideKey` (app/Sources/Player/PlayerEngineRouter.swift). Pinned to
    /// `"avfoundation"`: router rule 2 is the only route that sends a plain non-DV MKV to the
    /// AVFoundation engine (Auto keeps them on libmpv by rule 5).
    private static let engineOverrideKey = "stremiox.playerEngine"
    private static let engineOverrideValue = "avfoundation"
    /// UserDefaults key of the local-HLS delivery flag — mirrors `VortXRemuxHLSServer.deliveryKey`
    /// (app/Sources/Player/VortXRemuxHLSServer.swift). Baked ON, but a fetched RemoteConfig
    /// `dvRemuxHLS=false` kill-switch would win; pinning an explicit local value makes a
    /// conformance run deterministic (an explicit UserDefaults value always beats RemoteConfig).
    private static let deliveryKey = "stremiox.dvRemuxHLS"
    /// UserDefaults key of the plain (non-DV) remux lane flag — mirrors
    /// `PlayerEngineRouter.plainRemuxKey`. Same determinism rationale as `deliveryKey`.
    private static let plainRemuxKey = "stremiox.plainRemux"

    /// Diagnostics category for every line this hook writes.
    private static let logCategory = "debughook"

    /// Hostile-input bounds, same posture as `TopShelfSnapshot.parse` (a URL scheme is an open
    /// door: any process on the device can send one). The stream URL bound is generous because
    /// debrid links legitimately carry long signed queries; the deep-link bound caps the whole
    /// envelope before any parsing work happens.
    private static let maxStreamURLChars = 2048
    private static let maxDeepLinkChars = 4096
    private static let maxTitleChars = 120

    /// Environment variable names (launch triggers). Env rather than a `-flag` argument on
    /// purpose: it matches the existing `VORTX_PROBE` convention, and unlike the `-stremiox-*`
    /// arguments it is read only inside this `#if DEBUG` file, so Release builds ignore it.
    private static let envURLKey = "VORTX_DEBUG_PLAY_URL"
    private static let envTitleKey = "VORTX_DEBUG_PLAY_TITLE"

    /// Deep-link host under the app's own scheme: `vortx://debug-play?url=<percent-encoded>`.
    private static let deepLinkHost = "debug-play"

    /// Shell-settle delay before assigning the request, copied from the `-tv-playertest`
    /// diagnostic (VortXTVApp): the root replacement should not race the shell's first mount.
    private static let settleSeconds: TimeInterval = 1.5

    // MARK: - Triggers

    /// One-shot latch so a re-fired `.onAppear` cannot double-issue the env-requested playback.
    private static var envFired = false

    /// Trigger 1: the launch environment. Call from the root scene's `.onAppear`; a no-op when
    /// `VORTX_DEBUG_PLAY_URL` is absent, and one-shot per process when it is present.
    static func fireFromEnvironmentIfRequested(presenter: PlayerPresenter) {
        guard !envFired, let raw = ProcessInfo.processInfo.environment[envURLKey] else { return }
        envFired = true
        let title = ProcessInfo.processInfo.environment[envTitleKey]
        requestPlayback(urlString: raw, title: title, trigger: "env", presenter: presenter)
    }

    /// Trigger 2: the deep link. Call from `onOpenURL` BEFORE the normal router; returns true
    /// when the URL was ours (`<scheme>://debug-play…`), whether it was accepted or rejected, so
    /// a malformed debug link is consumed loudly here instead of dribbling into the router.
    /// Returns false for every other URL (the caller passes those to `DeepLinkRouter` unchanged).
    static func handleDeepLink(_ url: URL, presenter: PlayerPresenter) -> Bool {
        guard url.scheme?.lowercased() == TopShelfSnapshot.urlScheme.lowercased(),
              url.host?.lowercased() == deepLinkHost else { return false }
        // Bound the whole envelope before any further parsing (hostile-input posture).
        guard url.absoluteString.count <= maxDeepLinkChars else {
            reject(trigger: "deeplink", reason: "deeplink-too-long", token: "-")
            return true
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let streamString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !streamString.isEmpty else {
            reject(trigger: "deeplink", reason: "missing-url-param", token: "-")
            return true
        }
        requestPlayback(urlString: streamString, title: nil, trigger: "deeplink", presenter: presenter)
        return true
    }

    // MARK: - The one shared seam

    /// Validate -> pin -> mark -> issue. Everything both triggers do happens here, so the two
    /// can never drift apart.
    private static func requestPlayback(urlString: String, title: String?, trigger: String,
                                        presenter: PlayerPresenter) {
        guard urlString.count <= maxStreamURLChars else {
            reject(trigger: trigger, reason: "url-too-long", token: "-")
            return
        }
        guard let url = URL(string: urlString), url.host != nil else {
            reject(trigger: trigger, reason: "unparseable-url", token: "-")
            return
        }
        // The player's route line tokens the LAST PATH COMPONENT; token the same input so the
        // accept/reject marker and the subsequent `route file=…` line correlate in one grep.
        let token = VXProbeRedaction.identityToken(url.lastPathComponent)
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            reject(trigger: trigger, reason: "scheme-not-http", token: token)
            return
        }
        // Loopback would be vetoed at three layers (router rule 1, the engine-picker gate, the
        // remux candidacy), all of which land the stream on libmpv — the silent-demote outcome
        // this hook must never produce. Rejected slightly WIDER than the player's exact-match
        // checks (any 127.* and IPv6 ::1), deliberately: the simulator shares the host loopback,
        // so every loopback fixture is a mistake regardless of spelling.
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            reject(trigger: trigger, reason: "loopback-host", token: token)
            return
        }
        // Mirror of the plain-remux candidacy's Matroska evidence (PlayerEngineRouter
        // .isPlainRemuxCandidate): an explicit `.mkv` path extension, or a boundary-matched mkv
        // token / a "matroska" token in the filename+query. Anything else would mount RAW on
        // AVPlayer and demote (or play natively) — either way not the plain-remux lane.
        guard carriesMatroskaEvidence(url) else {
            reject(trigger: trigger, reason: "no-mkv-evidence", token: token)
            return
        }

        // PIN before the request is assigned: TVPlayerView latches its engine route once, in
        // onAppear, so these must be on disk first. Prior values are logged for the operator;
        // pinning is not reverted on session end (a conformance box is disposable by design).
        pin(engineOverrideKey, engineOverrideValue)
        pin(deliveryKey, true)
        pin(plainRemuxKey, true)

        // THE machine-readable readiness marker (see header; the harness greps this exact shape).
        DiagnosticsLog.log(logCategory,
                           "debug-play accept trigger=\(trigger) token=\(token) "
                           + "engineOverride=\(engineOverrideValue) dvRemuxHLS=true plainRemux=true "
                           + "startFromZero=true")

        let displayTitle = String((title ?? "Debug Playback").prefix(maxTitleChars))
        // Same settle pattern as `-tv-playertest` (VortXTVApp): give the shell its first mount
        // before the root swaps to the player. A fresh request id also cleanly replaces any
        // still-mounted previous session via RootView's `.id(req.id)` rebuild.
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            presenter.request = PlaybackRequest(url: url, title: displayTitle, startFromZero: true)
        }
    }

    // MARK: - Helpers

    /// The reject marker (see header). `reason` is always one of a fixed vocabulary — never any
    /// part of the input — so a hostile string cannot ride into the always-on diagnostics log.
    private static func reject(trigger: String, reason: String, token: String) {
        DiagnosticsLog.log(logCategory, "debug-play reject trigger=\(trigger) reason=\(reason) token=\(token)")
    }

    /// Mirrors `PlayerEngineRouter.isPlainRemuxCandidate`'s Matroska-evidence half (the http(s)
    /// and loopback halves are enforced above): a real `.mkv` path extension, or a
    /// boundary-matched `.mkv` token (its trailing character must not extend the extension) or a
    /// `matroska` token anywhere in the lowercased filename+query.
    private static func carriesMatroskaEvidence(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "mkv" { return true }
        let hint = (url.lastPathComponent + " " + (url.query ?? "")).lowercased()
        if hint.range(of: #"\.(mkv)(?![a-z0-9])"#, options: .regularExpression) != nil { return true }
        return hint.contains("matroska")
    }

    /// Pin one UserDefaults value, logging what was there before (D1: "log exactly what you
    /// pinned and its prior value"). The prior is rendered from `object(forKey:)` so "never set"
    /// is distinguishable from an explicit false/empty.
    private static func pin(_ key: String, _ value: Any) {
        let prior = UserDefaults.standard.object(forKey: key).map { String(describing: $0) } ?? "<unset>"
        UserDefaults.standard.set(value, forKey: key)
        DiagnosticsLog.log(logCategory, "debug-play pin key=\(key) prior=\(prior) new=\(value)")
    }
}
#endif
