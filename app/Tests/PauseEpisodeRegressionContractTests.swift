import Foundation

@main
@MainActor
private enum PauseEpisodeRegressionContractTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }

    static func main() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controller = try String(contentsOf: app.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"), encoding: .utf8)
        let player = try String(contentsOf: app.appendingPathComponent("SourcesTV/TVPlayerView.swift"), encoding: .utf8)
        let root = try String(contentsOf: app.appendingPathComponent("SourcesTV/RootTabView.swift"), encoding: .utf8)

        check("cache clearing and exact reanchor share one player command",
              controller.contains("let commandResult = mpv_command_string(")
                && controller.contains("no-osd drop-buffers; no-osd seek \\(flight.targetArgument) absolute+exact"))
        check("real EOF reaches the UI instead of being hidden as cache recovery",
              !controller.contains("consumeSyntheticEOF")
                && !controller.contains("synthetic EOF suppressed")
                && controller.contains("self.emitEndFileEOF(loadToken: loadToken)"))

        check("exact pending episode reentry preserves the active resolution",
              player.contains("pending.meta.videoId == v.id")
                && player.contains("!pending.terminal")
                && player.contains("pending resolution retained"))

        guard let receiptWrite = root.range(of: "playbackCloseReceipt = receiptState.close(requestID: requestID)"),
              let nilWrite = root.range(of: "request = nil", range: receiptWrite.upperBound..<root.endIndex) else {
            check("close publishes receipt before request nil", false)
            finish()
            return
        }
        check("close publishes receipt before request nil", receiptWrite.lowerBound < nilWrite.lowerBound)
        check("player exit uses deterministic presenter close",
              root.contains("presenter.close(requestID: req.id)"))

        finish()
    }

    private static func finish() {
        guard failures == 0 else {
            print("PauseEpisodeRegressionContractTests: \(failures) FAILED")
            exit(1)
        }
        print("PauseEpisodeRegressionContractTests: ALL PASS")
    }
}
