// Focused executable contract for Apple source-row player choices, the iOS/macOS source drill-in,
// and the long-episode Scroll to Top affordance.
//
// Run:
//   swiftc -parse-as-library -warnings-as-errors \
//     app/SourcesShared/SourcePlayerChoicePolicy.swift \
//     app/Sources/Player/PlayerEngineRouter.swift \
//     app/Tests/AppleSourcePlayerChoiceContractTests.swift \
//     -o /tmp/apple-source-player-choice-contract-tests && \
//   /tmp/apple-source-player-choice-contract-tests

import Foundation

final class ResolvedConfig {
    var features: [String: Bool] = [:]
    func isFeatureOn(_ key: String, default fallback: Bool) -> Bool { features[key] ?? fallback }
}

enum RemoteConfig {
    nonisolated(unsafe) static var snapshot = ResolvedConfig()
}

enum DVDisplaySupport {
    @MainActor static var isCapable = true
}

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func source(_ relativePath: String, root: URL) -> String {
    (try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
}

private func section(_ source: String, from start: String, to end: String) -> String {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else { return "" }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func ordered(_ needles: [String], in source: String) -> Bool {
    var lower = source.startIndex
    for needle in needles {
        guard let match = source.range(of: needle, range: lower..<source.endIndex) else { return false }
        lower = match.upperBound
    }
    return true
}

/// Small executable mirror of the tvOS watchdog ownership boundary. The production assertion below proves the
/// first-frame callback calls the real helper; this model makes the normal source/episode replacement sequence
/// fail if a future edit leaves the watchdog holding the retired item's generation.
private struct TVAVStallWatchdogGenerationModel {
    var activeToken: Int
    var currentItemGeneration: UInt64
    var observedItemGeneration: UInt64?

    mutating func firstFrame(loadToken: Int) {
        guard loadToken == activeToken else { return }
        observedItemGeneration = currentItemGeneration
    }

    var canRecoverProvenSurfaceStall: Bool {
        observedItemGeneration == currentItemGeneration
    }
}

@main
private enum AppleSourcePlayerChoiceContractTests {
    @MainActor
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tvDetail = source("app/SourcesTV/DetailView.swift", root: root)
        let iosDetail = source("app/SourcesiOS/iOSDetailView.swift", root: root)
        let player = source("app/Sources/PlayerScreen.swift", root: root)
        let tvPlayer = source("app/SourcesTV/TVPlayerView.swift", root: root)
        check("production sources are readable", !tvDetail.isEmpty && !iosDetail.isEmpty && !player.isEmpty && !tvPlayer.isEmpty)

        resetFlags()
        let mp4 = URL(string: "https://cdn.example.test/movie.mp4")!
        let mkv = URL(string: "https://cdn.example.test/movie.mkv")!
        let avi = URL(string: "https://cdn.example.test/movie.avi")!
        let loopback = URL(string: "http://127.0.0.1:11470/torrent/0")!
        check("AVPlayer choice accepts a native remote container",
              PlayerEngineRouter.canHonorAVPlayerChoice(
                for: mp4, isTorrent: false, isDolbyVision: false,
                dvDisplayCapable: true, plainRemuxDelivery: true))
        check("AVPlayer choice accepts Matroska only through the enabled remux lane",
              PlayerEngineRouter.canHonorAVPlayerChoice(
                for: mkv, isTorrent: false, isDolbyVision: false,
                dvDisplayCapable: true, plainRemuxDelivery: true))
        check("AVPlayer choice rejects a torrent/loopback route",
              !PlayerEngineRouter.canHonorAVPlayerChoice(
                for: loopback, isTorrent: true, isDolbyVision: false,
                dvDisplayCapable: true, plainRemuxDelivery: true))
        check("AVPlayer choice rejects an unsupported container",
              !PlayerEngineRouter.canHonorAVPlayerChoice(
                for: avi, isTorrent: false, isDolbyVision: false,
                dvDisplayCapable: true, plainRemuxDelivery: true))

        check("external handoff accepts a self-contained direct URL",
              SourcePlayerChoicePolicy.canHandOffExternally(
                url: mp4, isTorrent: false, isUsenet: false, requestHeaders: nil))
        check("external handoff rejects request-header sources",
              !SourcePlayerChoicePolicy.canHandOffExternally(
                url: mp4, isTorrent: false, isUsenet: false, requestHeaders: ["Referer": "redacted"]))
        check("external handoff rejects torrent and usenet descriptors",
              !SourcePlayerChoicePolicy.canHandOffExternally(
                url: mp4, isTorrent: true, isUsenet: false, requestHeaders: nil)
                && !SourcePlayerChoicePolicy.canHandOffExternally(
                    url: mp4, isTorrent: false, isUsenet: true, requestHeaders: nil))
        check("external handoff rejects loopback",
              !SourcePlayerChoicePolicy.canHandOffExternally(
                url: loopback, isTorrent: false, isUsenet: false, requestHeaders: nil))

        let tvMenu = section(tvDetail, from: "private func sourcePlayerMenu", to: "private func pinMenu")
        check("tvOS source menu offers one-launch VortX and eligible AVPlayer routes",
              tvMenu.contains("enginePreference: .mpv")
                && tvMenu.contains("enginePreference: .avfoundation")
                && tvMenu.contains("canHonorAVPlayerChoice"))
        check("tvOS external choices use the shared handoff safety gate",
              tvMenu.contains("SourcePlayerChoicePolicy.canHandOffExternally")
                && tvMenu.contains("ExternalPlayers.detected()"))
        check("tvOS source menu never persists a default",
              !tvMenu.contains("UserDefaults") && !tvMenu.contains("overrideKey"))

        let iosMenu = section(iosDetail, from: "private func sourcePlayerMenu", to: "private func pinMenu")
        check("iOS/macOS source menu offers one-launch VortX and eligible AVPlayer routes",
              iosMenu.contains("playWithEngine(stream, url, .mpv)")
                && iosMenu.contains("playWithEngine(stream, url, .avfoundation)")
                && iosMenu.contains("canHonorAVPlayerChoice"))
        check("iOS/macOS external choices reuse installed and eligibility APIs",
              iosMenu.contains("ExternalPlayer.canRouteExternally")
                && iosMenu.contains("externalPlayerTargets"))
        check("iOS/macOS source menu never persists a default",
              !iosMenu.contains("UserDefaults") && !iosMenu.contains("defaultPlayerID"))

        check("iOS/macOS detail exposes a visible session-only player picker",
              iosDetail.contains("private var launchPlayerMenu")
                && iosDetail.contains("launchEnginePreference = .mpv")
                && iosDetail.contains("launchEnginePreference = .avfoundation")
                && iosDetail.contains("launchPlayerMenu"))
        check("one-launch engine input reaches both PlayerScreen presenters",
              iosDetail.components(separatedBy: "initialEnginePreference: launch.enginePreference").count >= 3
                && player.contains("var initialEnginePreference: PlayerEngineRouter.Override? = nil")
                && player.contains("override: initialEnginePreference ?? PlayerEngineRouter.currentOverride"))

        let playerSources = section(player, from: "private func sourceRows()", to: "private func sourceLabel")
        check("iOS/macOS in-player Sources orders Quality then Audio then matching sources",
              ordered([
                "Row(label: \"Quality\", detail: \"›\"",
                "Row(label: \"Audio\", detail: \"›\"",
                "Row(label: \"Sources\", isHeader: true)",
                "TrackPreferences.$audioLanguagesOverride.withValue(sessionAudioLanguages)",
                "switchStream(to: stream"
              ], in: playerSources))
        check("iOS/macOS source Audio drill-in is wired",
              player.contains("sourceAudio, episodes")
                && player.contains("case .sourceAudio:")
                && player.contains("return audioLanguageFilterRows()"))
        check("quality and source switches retain the current-position switch path",
              player.contains("switchStream(to: opt.stream")
                && playerSources.contains("switchStream(to: stream")
                && player.contains("accessibilityHint: \"Switches at the current playback position\""))

        let tvSourceRows = section(tvPlayer, from: "private func sourceRows()", to: "private func sourceLabel")
        let tvAudioRows = section(tvPlayer, from: "private func audioLanguageFilterRows()", to: "private func playerSettingsRows()")
        let tvRemoteHandling = section(tvPlayer, from: "private func handlePress(_ type: UIPress.PressType)", to: "private var canEditSkip")
        check("tvOS source Audio returns to visibly re-ranked Sources without auto-switching",
              tvSourceRows.contains("TrackPreferences.$audioLanguagesOverride.withValue(sessionAudioLanguages)")
                && tvAudioRows.components(separatedBy:
                    "openPanel(.sources, preferredAccessibilityID: \"sources.audio\")").count == 3
                && !tvAudioRows.contains("resolveAndSwitchStream"))
        check("tvOS source Audio Back restores the stable Audio parent",
              tvRemoteHandling.contains(
                "case .sourceAudio:      openPanel(.sources, preferredAccessibilityID: \"sources.audio\")")
                && !tvRemoteHandling.contains("case .sourceAudio:      closePanel()"))
        check("tvOS episode advance preserves the outgoing surface until a replacement is issued",
              tvPlayer.contains("if pendingAdvance?.issued == true {")
                && !tvPlayer.contains("if pendingAdvance != nil {\n                Color.black.ignoresSafeArea()"))
        check("tvOS transport warm caller gates before claiming warmed identity",
              ordered([
                "private func warmNextIfReady()",
                "NextEpisodePreloadPolicy.isTransportWarmEligible(",
                "guard let pre = preloaded, warmedID != pre.episodeID else { return }",
                "warmedID = pre.episodeID"
              ], in: tvPlayer))
        let tvStall = section(tvPlayer, from: "private func recoverFromStall", to: "private func reloadAtPlayhead")
        check("tvOS AVPlayer stall caller is generation-fenced and never falls through to legacy reload",
              tvPlayer.contains("@State private var avStallWatchdogItemGeneration: UInt64?")
                && tvStall.contains("recoverFreshItemForProvenSurfaceStall(")
                && tvStall.contains("expectedItemGeneration: expectedItemGeneration")
                && tvStall.contains("case .retain(let reason):")
                && tvStall.contains("case .replaceFreshItem:")
                && ordered([
                    "case .terminal(let proof):",
                    "return",
                    "}\n        }\n        guard stallRecoveries < 3"
                ], in: tvStall))
        let tvFirstFrame = section(tvPlayer, from: "case MPVProperty.timePos:", to: "// Seek-in-flight guard")
        check("tvOS normal AV source or episode first frame rearms the watchdog under the active load-token fence",
              tvPlayer.contains("private func rearmAVStallWatchdogItemGenerationIfOwned(by loadToken: PlayerLoadToken)")
                && tvFirstFrame.contains("hasStartedPlaying = true\n                    rearmAVStallWatchdogItemGenerationIfOwned(by: event.loadToken)")
                && tvPlayer.contains("activeToken: avPlayer.activeLoadToken"))
        var generationModel = TVAVStallWatchdogGenerationModel(
            activeToken: 10,
            currentItemGeneration: 41,
            observedItemGeneration: 41)
        // Normal accepted source/episode replacement keeps the outer view alive but advances both ownership
        // values. The first frame for the NEW active token must make the subsequent proven freeze recoverable.
        generationModel.activeToken = 11
        generationModel.currentItemGeneration = 42
        generationModel.firstFrame(loadToken: 11)
        check("tvOS normal AV source or episode change re-arms a later proven surface-stall recovery",
              generationModel.canRecoverProvenSurfaceStall)
        generationModel.activeToken = 12
        generationModel.currentItemGeneration = 43
        generationModel.firstFrame(loadToken: 11)
        check("tvOS stale retired-item first frame cannot rearm the newer AV watchdog generation",
              !generationModel.canRecoverProvenSurfaceStall)
        let tvTrickplay = section(tvPlayer, from: "private func currentLocalTrickplayCaptureDecision", to: "/// The one place a trickplay frame")
        check("tvOS trickplay declares AVPlayer video-output versus libmpv inline backend",
              tvTrickplay.contains("player is AVPlayerEngineController")
                && tvTrickplay.contains(".avPlayerVideoOutput")
                && tvTrickplay.contains(".libmpvInlineDrawable"))

        check("long episode lists publish a stable top anchor",
              iosDetail.contains("private static let episodesTopAnchor")
                && iosDetail.contains(".id(Self.episodesTopAnchor)")
                && iosDetail.contains("EpisodeTopOffsetPreferenceKey"))
        check("floating Scroll to Top is conditional and accessible",
              iosDetail.contains("hasLongEpisodeList && showEpisodeScrollToTop")
                && iosDetail.contains("proxy.scrollTo(Self.episodesTopAnchor, anchor: .top)")
                && iosDetail.contains(".accessibilityLabel(\"Scroll to top\")")
                && iosDetail.contains("episodeScrollThreshold"))

        if failures > 0 {
            print("\n\(failures) contract check(s) failed")
            exit(1)
        }
        print("\nAll Apple source/player/scroll contract checks passed")
    }

    private static func resetFlags() {
        UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.plainRemuxKey)
        UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.dvRemuxKey)
        UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.overrideKey)
        UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.avPlayerDefaultKey)
        RemoteConfig.snapshot = ResolvedConfig()
    }
}
