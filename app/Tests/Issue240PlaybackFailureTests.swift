import Foundation

// Compile the production router and terminal policy, not copies of their decisions.
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

@main
enum Issue240PlaybackFailureTests {
    static func main() throws {
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        func section(_ source: String, from start: String, to end: String) -> String {
            guard let lower = source.range(of: start),
                  let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
                return ""
            }
            return String(source[lower.lowerBound..<upper.lowerBound])
        }
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
        }

        let key = PlayerEngineRouter.dvRemuxKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let mkv = URL(string: "https://stream.example.invalid/movie.DV.mkv")!
        for storedOff: Any in [false, 0, "0"] {
            UserDefaults.standard.set(storedOff, forKey: key)
            for remote in [nil, false, true] as [Bool?] {
                RemoteConfig.snapshot.features = remote.map { ["dvRemux": $0] } ?? [:]
                let resolution = PlayerEngineRouter.dvRemuxResolution(dvDisplayCapable: true)
                check("explicit Off (\(storedOff)) wins over remote \(String(describing: remote)) and DV display",
                      !resolution.enabled && resolution.source == .user)
                for preference in PlayerEngineRouter.Override.allCases {
                    check("Off survives engine preference \(preference.rawValue)",
                          PlayerEngineRouter.engine(for: mkv, isTorrent: false, isDolbyVision: true,
                                                    override: preference, dvDisplayCapable: true) == .mpv)
                    check("Off diagnostic retains user provenance",
                          PlayerEngineRouter.dvRemuxRouteDescription(dvDisplayCapable: true,
                                                                    override: preference) == "dvRemux=off(user)")
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        RemoteConfig.snapshot.features = [:]
        check("absent preference retains display default, not an invented Off",
              PlayerEngineRouter.dvRemuxResolution(dvDisplayCapable: true).source == .displayDefault
                && PlayerEngineRouter.dvRemuxEnabled(dvDisplayCapable: true))

        let player = try source("Sources/PlayerScreen.swift")
        let terminal = section(player, from: "private func presentTerminalLoadFailure()", to: "/// Fail (or hop)")
        for task in ["autoRetryTask", "loadTimeout", "recoveryDeadline"] {
            check("terminal presentation cancels \(task) before publication",
                  section(terminal, from: "private func presentTerminalLoadFailure()", to: "publish:")
                    .contains("\(task)?.cancel()"))
        }
        let property = section(player, from: "private func handleProperty(", to: "if let loadToken, loadToken == recoveryPauseOwner")
        check("terminal overlay fences late playback callbacks", property.contains("guard !loadFailed else { return }"))
        let nilEpisode = section(player, from: "guard let es = resolved, resolutionBudget.canAdmit(", to: "guard EpisodePlaybackIdentity.canIssueEpisodeSwitch(")
        check("failed next-episode resolution cannot silently dismiss playback",
              !nilEpisode.isEmpty && !nilEpisode.contains("onClose()") && nilEpisode.contains("presentTerminalLoadFailure()"))
        check("failed episode retains its retry target", nilEpisode.contains("failedEpisodeResolutionID = videoId"))
        let episodeAdmission = section(player, from: "private func goToEpisode(", to: "let retainedPreparedEpisode = takePreparedEpisode(for: videoId)")
        check("resolver target survives a failed Retry until the player command is accepted",
              episodeAdmission.contains("failedEpisodeResolutionID = videoId")
                && !episodeAdmission.contains("failedEpisodeResolutionID = nil"))
        let duplicateEpisode = section(player, from: "guard EpisodePlaybackIdentity.canIssueEpisodeSwitch(",
                                       to: "episodeResolveGeneration = nil\n            // PUBLISH-AT-FIRST-FRAME")
        check("duplicate outgoing URL remains a terminal resolution error with the retained target",
              duplicateEpisode.contains("if es.meta.videoId != curMeta?.videoId {")
                && section(duplicateEpisode, from: "if es.meta.videoId != curMeta?.videoId {", to: "} else {")
                    .contains("presentTerminalLoadFailure()"))
        let rejectedCommand = section(player, from: "guard let issuedToken else {", to: "pendingAdvance?.loadToken = issuedToken")
        check("rejected command does not drop the retained resolver target",
              rejectedCommand.contains("presentTerminalLoadFailure()")
                && !rejectedCommand.contains("failedEpisodeResolutionID = nil"))
        let retry = section(player, from: "private func retryPlaybackByUser()", to: "private func viewerToggle()")
        check("manual retry resolves the failed episode before reloading any old URL",
              retry.contains("if let target = failedEpisodeResolutionID") && retry.contains("goToEpisode(target)"))
        let deadline = section(player, from: "private func armEpisodeResolutionDeadline(", to: "private func admitEpisodeResolutionIfCurrent(")
        check("resolver timeout preserves its exact target", deadline.contains("failedEpisodeResolutionID = owner.videoID"))
        let replacement = section(player, from: "private func resetRuntimeForIssuedSourceSwitch(",
                                  to: "private func resetRuntimeForIssuedEpisode()")
        check("accepted replacement reopens callbacks and clears resolver failure",
              replacement.contains("loadFailed = false") && replacement.contains("failedEpisodeResolutionID = nil"))
        let overlay = section(player, from: "private var loadErrorOverlay:", to: "private var loadErrorHint:")
        check("resolver failures cannot offer the outgoing episode's source list",
              overlay.contains("if failedEpisodeResolutionID == nil, hasAlternateSources"))

        let mpv = try source("Sources/Player/MPVMetalViewController.swift")
        let errorEvent = section(mpv, from: "let msg = String(cString: mpv_error_string(ef.error))",
                                 to: "} else if ef.reason == MPV_END_FILE_REASON_EOF")
        check("MPV error stays separate from successful EOF", errorEvent.contains("self.emit(MPVProperty.endFileError")
              && !errorEvent.contains("endFileEof") && !errorEvent.contains("handleEndFileEOF"))
        check("MPV error receipt includes the numeric code", errorEvent.contains("code=\\(ef.error)"))
        let hint = section(player, from: "private var loadErrorHint:", to: "// MARK: - Controls")
        check("error UI does not diagnose an outage or uncached download without evidence",
              !hint.contains("uncached") && !hint.contains("offline"))

        if failures != 0 { print("\(failures) FAILURE(S)"); exit(1) }
        print("ALL PASS")
    }
}
