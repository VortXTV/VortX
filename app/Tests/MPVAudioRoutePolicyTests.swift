// MPVAudioRoutePolicyTests: standalone contract for the tvOS audio-route policy.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Sources/Player/AudioOutputMode.swift \
//     app/Tests/MPVAudioRoutePolicyTests.swift \
//     -o /tmp/mpv-audio-route-policy-tests \
//     && /tmp/mpv-audio-route-policy-tests

import Foundation

// AudioOutputMode.swift consults RemoteConfig only for the unrelated tvOS spdif experiment.
// This minimal standalone substitute keeps the production policy itself in the executable.
enum RemoteConfig {
    struct Snapshot: Sendable {
        func isFeatureOn(_ key: String, default fallback: Bool) -> Bool { fallback }
    }

    static let snapshot = Snapshot()
}

@main
@MainActor
private enum MPVAudioRoutePolicyTests {
    static var failures = 0

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func section(_ source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func ordered(_ needles: [String], in source: String) -> Bool {
        var cursor = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
                return false
            }
            cursor = range.upperBound
        }
        return true
    }

    static func hasActualOutputTruth(_ source: String) -> Bool {
        guard let refresh = section(
            source,
            from: "private func refreshAudioSessionPolicy()",
            to: "/// mpv `audio-samplerate`"
        ) else {
            return false
        }
        return ordered(
            [
                "let maximumOutputChannels = session.maximumOutputNumberOfChannels",
                "let requestedOutputChannels = AudioRoutePolicy.preferredOutputChannels(",
                "try? session.setPreferredOutputNumberOfChannels(requestedOutputChannels)",
                "let actualOutputChannels = AudioRoutePolicy.resolvedOutputChannels(session.outputNumberOfChannels)",
                "outputChannels = actualOutputChannels",
            ],
            in: refresh
        ) && !refresh.contains("outputChannels = max(session.maximumOutputNumberOfChannels, 2)")
    }

    static func hasExplicitStereoSessionPredicate(_ source: String) -> Bool {
        source.contains("mode != .stereo")
            && source.contains("return 2")
    }

    static func hasRuntimeRefreshWiring(_ source: String) -> Bool {
        guard let reapply = section(
            source,
            from: "private func applyChannelPolicy(force: Bool = false)",
            to: "@objc private func audioRouteChanged"
        ), let modeSwitch = section(
            source,
            from: "func setAudioOutputMode(_ mode: AudioOutputMode)",
            to: "/// Live numbers for the player's"
        ), let routeChange = section(
            source,
            from: "@objc private func audioRouteChanged(_ note: Notification)",
            to: "#endif   // canImport(UIKit): audio-session + lifecycle observers are iOS/tvOS only"
        ) else {
            return false
        }
        return ordered(
            [
                "refreshAudioSessionPolicy()",
                "setString(\"audio-channels\", next.0)",
            ],
            in: reapply
        ) && modeSwitch.contains("applyChannelPolicy(force: true)")
            && routeChange.contains("applyChannelPolicy()")
    }

    static func clearsStaleSampleRate(_ source: String) -> Bool {
        guard let reapply = section(
            source,
            from: "private func applyChannelPolicy(force: Bool = false)",
            to: "@objc private func audioRouteChanged"
        ) else {
            return false
        }
        return ordered(
            [
                "let next = (channelPolicy, sampleRatePolicy ?? 0)",
                "setString(\"audio-channels\", next.0)",
                "setString(\"audio-samplerate\", String(next.1))",
            ],
            in: reapply
        ) && !reapply.contains("if next.1 > 0")
    }

    static func hasDiagnosticsReceipt(_ source: String) -> Bool {
        guard let refresh = section(
            source,
            from: "private func refreshAudioSessionPolicy()",
            to: "/// mpv `audio-samplerate`"
        ) else {
            return false
        }
        return refresh.contains("DiagnosticsLog.log(")
            && refresh.contains("\"player\",")
            && refresh.contains("audio route policy mode=")
            && refresh.contains(" port=")
            && refresh.contains(" max=")
            && refresh.contains(" actual=")
            && refresh.contains(" requested=")
            && refresh.contains(" resolved=")
            && !refresh.localizedCaseInsensitiveContains("url")
    }

    static func main() throws {
        // The policy's request uses maximum capability, while the playback choice uses the
        // realized route. A capable HDMI route can legitimately advertise 8 but currently open 2.
        let autoSupportsMultichannel = AudioRoutePolicy.supportsMultichannelContent(
            mode: .auto,
            maximumOutputChannels: 8,
            routeIsStereoOnly: false,
            routeIsAirPods: false
        )
        check("max 8 / actual 2 Auto still resolves to a stereo downmix",
              autoSupportsMultichannel
                && AudioRoutePolicy.preferredOutputChannels(
                    mode: .auto,
                    maximumOutputChannels: 8,
                    routeIsStereoOnly: false,
                    routeIsAirPods: false
                ) == 8
                && AudioRoutePolicy.channelPolicy(
                    mode: .auto,
                    actualOutputChannels: 2,
                    routeIsStereoOnly: false,
                    routeIsAirPods: false
                ) == "stereo")

        check("max 8 / actual 6 Auto preserves safe multichannel",
              AudioRoutePolicy.channelPolicy(
                mode: .auto,
                actualOutputChannels: 6,
                routeIsStereoOnly: false,
                routeIsAirPods: false
              ) == "auto-safe")

        check("Stereo always disables multichannel content and requests 2 channels",
              !AudioRoutePolicy.supportsMultichannelContent(
                mode: .stereo,
                maximumOutputChannels: 8,
                routeIsStereoOnly: false,
                routeIsAirPods: true
              ) && AudioRoutePolicy.preferredOutputChannels(
                mode: .stereo,
                maximumOutputChannels: 8,
                routeIsStereoOnly: false,
                routeIsAirPods: true
              ) == 2
                && AudioRoutePolicy.channelPolicy(
                    mode: .stereo,
                    actualOutputChannels: 8,
                    routeIsStereoOnly: false,
                    routeIsAirPods: true
                ) == "stereo")

        check("stereo-only route stays at 2 channels",
              !AudioRoutePolicy.supportsMultichannelContent(
                mode: .auto,
                maximumOutputChannels: 8,
                routeIsStereoOnly: true,
                routeIsAirPods: false
              ) && AudioRoutePolicy.preferredOutputChannels(
                mode: .auto,
                maximumOutputChannels: 8,
                routeIsStereoOnly: true,
                routeIsAirPods: false
              ) == 2
                && AudioRoutePolicy.resolvedOutputChannels(0) == 2
                && AudioRoutePolicy.channelPolicy(
                    mode: .auto,
                    actualOutputChannels: 8,
                    routeIsStereoOnly: true,
                    routeIsAirPods: false
                ) == "stereo")

        check("capable requests are bounded to 8 channels",
              AudioRoutePolicy.preferredOutputChannels(
                mode: .auto,
                maximumOutputChannels: 12,
                routeIsStereoOnly: false,
                routeIsAirPods: false
              ) == 8)

        let testFile = URL(fileURLWithPath: #filePath)
        let app = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let controllerURL = app.appendingPathComponent("Sources/Player/MPVMetalViewController.swift")
        let modeURL = app.appendingPathComponent("Sources/Player/AudioOutputMode.swift")
        let controller = try String(contentsOf: controllerURL, encoding: .utf8)
        let modeSource = try String(contentsOf: modeURL, encoding: .utf8)

        check("initial setup refreshes the session before pre-init audio policy",
              ordered(
                [
                    "try session.setActive(true)",
                    "refreshAudioSessionPolicy()",
                    "mpv = mpv_create()",
                ],
                in: controller
              ))
        check("production policy uses the realized output channel count", hasActualOutputTruth(controller))
        check("Stereo has an explicit AVAudioSession predicate", hasExplicitStereoSessionPredicate(modeSource))
        check("route change and live mode refresh before mpv audio properties", hasRuntimeRefreshWiring(controller))
        check("nonzero to zero sample-rate transition clears the stale mpv property",
              clearsStaleSampleRate(controller))
        check("DiagnosticsLog receipt is bounded to route-policy facts", hasDiagnosticsReceipt(controller))

        let maximumAsActualMutant = controller.replacingOccurrences(
            of: "outputChannels = actualOutputChannels",
            with: "outputChannels = max(session.maximumOutputNumberOfChannels, 2)"
        )
        check("hostile: maximum-as-actual mutation fails", !hasActualOutputTruth(maximumAsActualMutant))

        let missingStereoMutant = modeSource.replacingOccurrences(of: "mode != .stereo", with: "true")
        check("hostile: missing Stereo predicate fails", !hasExplicitStereoSessionPredicate(missingStereoMutant))

        let missingLiveRefreshMutant = controller.replacingOccurrences(
            of: "applyChannelPolicy(force: true)",
            with: "setString(\"audio-channels\", channelPolicy)"
        )
        check("hostile: mode switch without refresh fails", !hasRuntimeRefreshWiring(missingLiveRefreshMutant))

        let staleSampleRateMutant = controller.replacingOccurrences(
            of: "setString(\"audio-samplerate\", String(next.1))",
            with: "if next.1 > 0 { setString(\"audio-samplerate\", String(next.1)) }"
        )
        check("hostile: conditional sample-rate write fails the clear contract",
              !clearsStaleSampleRate(staleSampleRateMutant))

        guard failures == 0 else {
            print("MPVAudioRoutePolicyTests: \(failures) FAILED")
            exit(1)
        }
        print("MPVAudioRoutePolicyTests: ALL PASS")
    }
}
