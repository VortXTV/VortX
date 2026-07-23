#if DEBUG
import Foundation

/// Debug-only entry point used by the player conformance harness.
///
/// The hook validates that a requested source can take the plain-remux path,
/// pins the three routing controls before the player mounts, and emits a
/// receipt that can be joined to the production route line without logging the
/// raw URL. The complete type is excluded when DEBUG is not defined.
@MainActor
enum DebugPlaybackHook {
    private static let engineOverrideKey = "stremiox.playerEngine"
    private static let deliveryKey = "stremiox.dvRemuxHLS"
    private static let plainRemuxKey = "stremiox.plainRemux"
    private static let environmentURLKey = "VORTX_DEBUG_PLAY_URL"
    private static let environmentTitleKey = "VORTX_DEBUG_PLAY_TITLE"
    private static let environmentRunKey = "VORTX_DEBUG_PLAY_RUN"
    private static let deepLinkHost = "debug-play"
    private static let maximumURLCharacters = 2_048
    private static let maximumDeepLinkCharacters = 4_096
    private static let maximumTitleCharacters = 120
    private static let settleSeconds: TimeInterval = 1.5
    private static var environmentRequestIssued = false

    static func fireFromEnvironmentIfRequested(presenter: PlayerPresenter) {
        let environment = ProcessInfo.processInfo.environment
        guard !environmentRequestIssued, let rawURL = environment[environmentURLKey] else { return }
        environmentRequestIssued = true
        let run = normalizedRunReceipt(environment[environmentRunKey])
        requestPlayback(
            urlString: rawURL,
            title: environment[environmentTitleKey],
            trigger: "env",
            run: run,
            presenter: presenter)
    }

    static func handleDeepLink(_ url: URL, presenter: PlayerPresenter) -> Bool {
        guard url.scheme?.lowercased() == TopShelfSnapshot.urlScheme.lowercased(),
              url.host?.lowercased() == deepLinkHost else { return false }
        let run = UUID().uuidString.lowercased()
        guard url.absoluteString.count <= maximumDeepLinkCharacters else {
            reject(trigger: "deeplink", run: run, reason: "deeplink-too-long", token: "-")
            return true
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.filter({ $0.name == "url" }).count == 1,
              let stream = items.first(where: { $0.name == "url" })?.value,
              !stream.isEmpty else {
            reject(trigger: "deeplink", run: run, reason: "invalid-url-param", token: "-")
            return true
        }
        requestPlayback(
            urlString: stream,
            title: nil,
            trigger: "deeplink",
            run: run,
            presenter: presenter)
        return true
    }

    private static func requestPlayback(
        urlString: String,
        title: String?,
        trigger: String,
        run: String,
        presenter: PlayerPresenter
    ) {
        guard urlString.count <= maximumURLCharacters else {
            reject(trigger: trigger, run: run, reason: "url-too-long", token: "-")
            return
        }
        guard let url = URL(string: urlString), url.host != nil else {
            reject(trigger: trigger, run: run, reason: "unparseable-url", token: "-")
            return
        }
        let token = VXProbeRedaction.identityToken(url.lastPathComponent)
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            reject(trigger: trigger, run: run, reason: "scheme-not-http", token: token)
            return
        }
        let host = (url.host ?? "")
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, host != "localhost", host != "::1", !host.hasPrefix("127.") else {
            reject(trigger: trigger, run: run, reason: "loopback-host", token: token)
            return
        }
        guard carriesMatroskaEvidence(url) else {
            reject(trigger: trigger, run: run, reason: "no-mkv-evidence", token: token)
            return
        }

        pin(engineOverrideKey, "avfoundation")
        pin(deliveryKey, true)
        pin(plainRemuxKey, true)
        DiagnosticsLog.log(
            "debughook",
            "debug-play accept trigger=\(trigger) run=\(run) token=\(token) "
                + "engineOverride=avfoundation dvRemuxHLS=true plainRemux=true startFromZero=true")

        let displayTitle = String((title ?? "Conformance Playback").prefix(maximumTitleCharacters))
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            presenter.request = PlaybackRequest(url: url, title: displayTitle, startFromZero: true)
        }
    }

    private static func normalizedRunReceipt(_ candidate: String?) -> String {
        guard let candidate,
              candidate.count == 36,
              let parsed = UUID(uuidString: candidate),
              parsed.uuidString.caseInsensitiveCompare(candidate) == .orderedSame else {
            return UUID().uuidString.lowercased()
        }
        return candidate.lowercased()
    }

    private static func carriesMatroskaEvidence(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "mkv" { return true }
        let hint = (url.lastPathComponent + " " + (url.query ?? "")).lowercased()
        return hint.range(of: #"\.mkv(?![a-z0-9])"#, options: .regularExpression) != nil
            || hint.contains("matroska")
    }

    private static func reject(trigger: String, run: String, reason: String, token: String) {
        DiagnosticsLog.log(
            "debughook",
            "debug-play reject trigger=\(trigger) run=\(run) reason=\(reason) token=\(token)")
    }

    private static func pin(_ key: String, _ value: Any) {
        let prior = UserDefaults.standard.object(forKey: key).map(String.init(describing:)) ?? "<unset>"
        UserDefaults.standard.set(value, forKey: key)
        DiagnosticsLog.log("debughook", "debug-play pin key=\(key) prior=\(prior) new=\(value)")
    }
}
#endif
