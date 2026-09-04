// Source-level regression contract for AVPlayer external subtitle settlement.
//
// Run with:
//   swiftc -parse-as-library -o /tmp/subtitle-selection-settlement \
//     app/Tests/SubtitleSelectionSettlementContractTests.swift && /tmp/subtitle-selection-settlement

import Foundation

private func slice(_ source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

@main
enum SubtitleSelectionSettlementContractTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name)")
            }
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let source = try? String(
            contentsOf: root.appendingPathComponent("Sources/Player/AVPlayerEngine.swift"),
            encoding: .utf8) else {
            fputs("FAIL  AVPlayerEngine source unavailable\n", stderr)
            exit(1)
        }

        let userSelection = slice(source, from: "    func setSubtitleTrack(", to: "    private func selectNativeSubtitle")
        let externalLoad = slice(source, from: "    func addExternalSubtitle(", to: "    /// Stop rendering")
        let restore = slice(source, from: "                switch restore.subtitle", to: "                // The snapshot owns playhead")
        let notification = slice(source, from: "    @objc private func mediaSelectionDidChange", to: "    private func teardownObservers")
        let groupLoad = slice(source, from: "            if externalSubActive || pendingExternalSubtitleActivation {", to: "            let sourceBackedAudio")
        let settlement = slice(source, from: "    private func selectNativeSubtitle", to: "    private func setExternalSubtitleActive")
        let disableExternal = slice(source, from: "    private func disableExternalSubtitle", to: "    /// AVFoundation cannot time-shift")

        check("user external selection does not directly select AVFoundation media", userSelection?.contains("item.select(") == false)
        check("external load does not activate before centralized settlement", externalLoad?.contains("item.select(") == false
            && externalLoad?.contains("selectNativeSubtitle(nil, activatingExternalAfterSettlement: true)") == true)
        check("restore sends every subtitle intent through centralized settlement", restore?.contains("item.select(") == false
            && restore?.contains("selectNativeSubtitle(nil, activatingExternalAfterSettlement: true)") == true
            && restore?.contains("selectNativeSubtitle(nil, activatingExternalAfterSettlement: false)") == true
            && restore?.contains("selectNativeSubtitle(option, activatingExternalAfterSettlement: false)") == true)
        check("media-selection notification corrects a native selection under the overlay", notification?.contains("selectNativeSubtitle(nil, activatingExternalAfterSettlement: true)") == true)
        check("late legible-group load uses the same external settlement path", groupLoad?.contains("item.select(") == false
            && groupLoad?.contains("selectNativeSubtitle(nil, activatingExternalAfterSettlement: true)") == true)
        check("central settlement is item-generation and mount fenced", settlement?.contains("selectionContextIsCurrent(") == true
            && settlement?.contains("subtitleSelectionRevision") == true
            && settlement?.contains("item.select(requested, in: group)") == true)
        check("missing cached legible group defers external activation until topology resolves", settlement?.contains("pendingExternalSubtitleActivation = activatingExternalAfterSettlement") == true
            && settlement?.contains("selectionTopologyGeneration == itemGeneration") == true
            && source.contains("if pendingExternalSubtitleActivation {")
            && source.contains("selectNativeSubtitle(nil, activatingExternalAfterSettlement: true)"))
        check("external teardown clears pending activation and cancels old settlement", disableExternal?.contains("pendingExternalSubtitleActivation = false") == true
            && disableExternal?.contains("subtitleSelectionRevision &+= 1") == true)

        if failures > 0 { exit(1) }
    }
}
