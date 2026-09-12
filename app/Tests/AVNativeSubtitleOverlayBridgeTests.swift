import AVFoundation
import Foundation

@main
enum AVNativeSubtitleOverlayBridgeTests {
    @MainActor
    static func main() throws {
        for active in [false, true] {
            for transitioning in [false, true] {
                for external in [false, true] {
                    precondition(AVNativeSubtitleOverlayBridge.canRenderInline(
                        pipActive: active, pipTransitioning: transitioning, externalPlayback: external)
                        == (!active && !transitioning && !external), "PiP/AirPlay must keep native captions")
                }
            }
        }
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/test.m3u8")!)
        var rendered: [String?] = []
        let bridge = AVNativeSubtitleOverlayBridge(item: item, option: nil) { rendered.append($0) }
        precondition(!bridge.output.suppressesPlayerRendering, "No text evidence: retain native fallback")
        let unrelated = AVPlayerItemLegibleOutput()
        bridge.legibleOutput(unrelated, didOutputAttributedStrings: [NSAttributedString(string: "stale")],
                             nativeSampleBuffers: [], forItemTime: .zero)
        precondition(rendered.isEmpty, "Wrong output may not publish")
        bridge.legibleOutput(bridge.output, didOutputAttributedStrings: [NSAttributedString(string: "Line one"), NSAttributedString(string: "Line two")],
                             nativeSampleBuffers: [], forItemTime: .zero)
        precondition(bridge.output.suppressesPlayerRendering, "Native renderer must be suppressed before overlay")
        precondition(rendered.last! == "Line one\nLine two", "Publish one current cue snapshot, not an accumulating list")
        bridge.outputSequenceWasFlushed(bridge.output)
        precondition(rendered.last! == nil, "Seek flush clears old cue")
        bridge.legibleOutput(bridge.output, didOutputAttributedStrings: [], nativeSampleBuffers: [], forItemTime: .zero)
        precondition(rendered.last! == nil, "Empty update clears expired cue")
        bridge.invalidate()
        precondition(!bridge.output.suppressesPlayerRendering && !item.outputs.contains(bridge.output))
        let count = rendered.count
        bridge.legibleOutput(bridge.output, didOutputAttributedStrings: [NSAttributedString(string: "late")],
                             nativeSampleBuffers: [], forItemTime: .zero)
        bridge.outputSequenceWasFlushed(bridge.output)
        bridge.invalidate()
        precondition(rendered.count == count, "Retired callbacks and repeated teardown are inert")
        let bitmap = AVNativeSubtitleOverlayBridge(item: item, option: nil) { rendered.append($0) }
        bitmap.legibleOutput(bitmap.output, didOutputAttributedStrings: [], nativeSampleBuffers: [1], forItemTime: .zero)
        precondition(!bitmap.output.suppressesPlayerRendering && !item.outputs.contains(bitmap.output), "Unsupported payload returns to native")
        let engine = try String(contentsOfFile: "app/Sources/Player/AVPlayerEngine.swift", encoding: .utf8)
        precondition(engine.contains("self.itemGeneration == generation, !self.externalSubActive"))
        precondition(engine.contains("if active { invalidateNativeSubtitleOverlay() }"))
        precondition(engine.contains("private func teardownObservers() {\n        invalidateNativeSubtitleOverlay()"))
        precondition(engine.contains("if hadNativeOverlay, !externalSubActive { subtitleOverlay?.setText(nil) }"))
        precondition(engine.contains("$0.delivery == .webVTT"))
        precondition(engine.contains("externalPlayback: player.isExternalPlaybackActive"))
        precondition(engine.contains("player.observe(\\.isExternalPlaybackActive"))
        let pipStart = engine.range(of: "private func publishPictureInPictureState()")!.lowerBound
        let pipEnd = engine.range(of: "private func pictureInPictureGeneration(")!.lowerBound
        precondition(engine[pipStart..<pipEnd].contains("refreshNativeSubtitleOverlay(for: item)"))
        print("PASS native subtitle bridge: renderer exclusion, cue replacement/expiry, flush, stale callback fences, unsupported fallback, engine wiring")
    }
}
