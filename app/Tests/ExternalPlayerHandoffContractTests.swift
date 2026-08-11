// Focused source contract for the Apple external-player handoff.
//
// Run without an Xcode build:
//   swiftc -parse-as-library -warnings-as-errors \
//     app/Sources/ExternalPlayer.swift app/Tests/ExternalPlayerHandoffContractTests.swift \
//     -o /tmp/external-player-handoff-contract-tests && \
//   /tmp/external-player-handoff-contract-tests

import Foundation

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

private func source(at path: String, root: URL) -> String {
    let url = root.appendingPathComponent(path)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func section(in source: String, from start: String, to end: String) -> String {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return ""
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func ordered(_ needles: [String], in source: String) -> Bool {
    var lower = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: lower..<source.endIndex) else {
            return false
        }
        lower = range.upperBound
    }
    return true
}

private func tvDefaultRouteKeepsTrailersNative(_ source: String) -> Bool {
    let route = section(
        in: source,
        from: "private func maybeRouteToDefaultExternalPlayer()",
        to: "/// A concise one-line label for a source"
    )
    return ordered([
        "guard let player = ExternalPlayers.defaultPlayer(),",
        "!isTrailer,",
        "!isTorrentPlayback",
        "ExternalPlayers.open(u, in: player)"
    ], in: route)
}

@MainActor
private final class DelayedExternalLaunch {
    private var completion: ((Bool) -> Void)?

    func open(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func finish(_ launched: Bool) {
        completion?(launched)
    }
}

@MainActor
private final class PlaybackState {
    var url: URL
    var sessionID: String
    var episodeGeneration: Int
    var loadToken: UUID?

    init(url: URL, sessionID: String, episodeGeneration: Int, loadToken: UUID?) {
        self.url = url
        self.sessionID = sessionID
        self.episodeGeneration = episodeGeneration
        self.loadToken = loadToken
    }
}

@main
private enum ExternalPlayerHandoffContractTests {
    @MainActor
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let externalPlayer = source(at: "app/Sources/ExternalPlayer.swift", root: root)
        let playerScreen = source(at: "app/Sources/PlayerScreen.swift", root: root)
        let tvPlayerView = source(at: "app/SourcesTV/TVPlayerView.swift", root: root)
        check("production sources are readable",
              !externalPlayer.isEmpty && !playerScreen.isEmpty && !tvPlayerView.isEmpty)

        check("iOS open uses the platform completion handler",
              externalPlayer.contains("UIApplication.shared.open(link, options: [:])")
                  && externalPlayer.contains("finish(launched)"))
        check("macOS open uses the platform completion handler",
              externalPlayer.contains("NSWorkspace.shared.open(link, configuration: NSWorkspace.OpenConfiguration())")
                  && externalPlayer.contains("finish(error == nil)"))
        check("launch rejection is reported as failure",
              externalPlayer.contains("finish(false)"))
        check("macOS completion reports NSError failure",
              externalPlayer.contains("finish(error == nil)"))
        check("legacy synchronous iOS open is absent",
              !externalPlayer.contains("UIApplication.shared.open(link)"))
        check("legacy synchronous macOS open is absent",
              !externalPlayer.contains("NSWorkspace.shared.open(link)"))

        let defaultRoute = section(
            in: playerScreen,
            from: "// Auto-route to the user's chosen default external player",
            to: "curURL = url; curHeaders = headers; curIsTorrent = recordIsTorrent"
        )
        check("default route receives an async completion",
              defaultRoute.contains("ExternalPlayer.routeToDefaultIfSet")
                  && defaultRoute.contains("launched in"))
        check("default route fences the exact handoff target",
              defaultRoute.contains("ExternalPlayer.HandoffIdentity")
                  && defaultRoute.contains("loadToken: externalHandoffLoadToken")
                  && defaultRoute.contains("episodeGeneration: episodeSwitchGeneration"))
        check("default route checks the fence before acting",
              defaultRoute.contains("externalHandoff.matches(")
                  && defaultRoute.contains("url: curURL ?? url")
                  && defaultRoute.contains("loadToken: coordinator.player?.activeLoadToken"))
        check("default route closes only after confirmed launch",
              ordered(["if launched", "onClose()"], in: defaultRoute))
        check("default route keeps local playback on failed launch",
              defaultRoute.contains("externalLinkDead = true"))

        check("tvOS default route keeps trailers in the built-in player",
              tvDefaultRouteKeepsTrailersNative(tvPlayerView))
        let trailerFenceRemoved = tvPlayerView.replacingOccurrences(of: "!isTrailer,", with: "")
        check("tvOS default route rejects a missing trailer fence",
              !tvDefaultRouteKeepsTrailersNative(trailerFenceRemoved))

        let explicitChooser = section(
            in: playerScreen,
            from: ".confirmationDialog(\"Play in another app\"",
            to: ".alert(\"Stream unavailable\""
        )
        check("explicit chooser still probes before handoff",
              ordered(["probeAlive", "ExternalPlayer.open"], in: explicitChooser))
        check("explicit chooser still pauses only after a confirmed handoff",
              explicitChooser.contains("if launched, !isPaused")
                  && explicitChooser.contains("coordinator.player?.togglePause()"))
        check("explicit chooser captures a non-nil production handoff identity",
              explicitChooser.contains("ExternalPlayer.HandoffIdentity")
                  && explicitChooser.contains("guard let externalHandoffLoadToken"))
        check("explicit chooser revalidates before and after probing",
              explicitChooser.components(separatedBy: ".matches(").count >= 3)
        check("explicit completion revalidates before pausing or alerting",
              ordered(["ExternalPlayer.open", "externalHandoff.matches", "if launched"], in: explicitChooser))

        hostileDelayedCompletionChecks()

        if failures > 0 {
            print("\n\(failures) contract check(s) failed")
            exit(1)
        }
        print("\nAll external-player handoff contract checks passed")
    }

    @MainActor
    private static func hostileDelayedCompletionChecks() {
        let oldURL = URL(string: "https://cdn.example.test/old.mkv")!
        let replacementURL = URL(string: "https://cdn.example.test/replacement.mkv")!
        let oldToken = UUID()
        let replacementToken = UUID()
        let state = PlaybackState(
            url: oldURL, sessionID: "session-old", episodeGeneration: 3, loadToken: oldToken
        )
        let identity = ExternalPlayer.HandoffIdentity(
            url: oldURL, sessionID: "session-old", episodeGeneration: 3, loadToken: oldToken
        )
        let delayed = DelayedExternalLaunch()
        var pauseCount = 0
        var errorCount = 0
        delayed.open { launched in
            guard identity.matches(
                url: state.url,
                sessionID: state.sessionID,
                episodeGeneration: state.episodeGeneration,
                loadToken: state.loadToken
            ) else { return }
            if launched { pauseCount += 1 } else { errorCount += 1 }
        }

        state.url = replacementURL
        state.sessionID = "session-replacement"
        state.episodeGeneration = 4
        state.loadToken = replacementToken
        delayed.finish(true)
        check("hostile delayed success cannot pause replacement playback",
              pauseCount == 0 && errorCount == 0)
        delayed.finish(false)
        check("hostile delayed failure cannot alert replacement playback",
              pauseCount == 0 && errorCount == 0)

        state.url = oldURL
        state.sessionID = "session-old"
        state.episodeGeneration = 3
        state.loadToken = oldToken
        delayed.finish(true)
        check("matching delayed success preserves chooser pause semantics", pauseCount == 1)
        delayed.finish(false)
        check("matching delayed failure preserves chooser fallback semantics", errorCount == 1)
    }
}
