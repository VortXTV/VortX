import AVFoundation
import Foundation

/// Uses AVFoundation's selected WebVTT rendition and cue clock, but renders through the app's existing
/// styled overlay. Never selects a track, downloads subtitles, or changes global accessibility settings.
@MainActor
final class AVNativeSubtitleOverlayBridge: NSObject, @preconcurrency AVPlayerItemLegibleOutputPushDelegate {
    static func canRenderInline(pipActive: Bool, pipTransitioning: Bool, externalPlayback: Bool) -> Bool {
        !pipActive && !pipTransitioning && !externalPlayback
    }
    private weak var item: AVPlayerItem?
    private let option: AVMediaSelectionOption?
    let output = AVPlayerItemLegibleOutput()
    private var active = true
    private let render: (String?) -> Void

    init(item: AVPlayerItem, option: AVMediaSelectionOption?, render: @escaping (String?) -> Void) {
        self.item = item
        self.option = option
        self.render = render
        super.init()
        output.advanceIntervalForDelegateInvocation = 0
        // Fail open until AVFoundation actually vends text; an unsupported/no-output rendition remains native.
        output.suppressesPlayerRendering = false
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    func owns(item: AVPlayerItem, option: AVMediaSelectionOption) -> Bool {
        active && self.item === item && self.option == option
    }

    func invalidate() {
        guard active else { return }
        active = false // Fences callbacks already queued on the main delegate queue.
        render(nil)
        output.suppressesPlayerRendering = false
        output.setDelegate(nil, queue: nil)
        item?.remove(output)
        item = nil
    }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                       didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        guard active, output === self.output, item != nil else { return }
        guard nativeSamples.isEmpty else { invalidate(); return } // Never hide an unsupported bitmap stream.
        let text = strings.map(\.string).joined(separator: "\n")
        if !text.isEmpty {
            // Suppress BEFORE drawing: exactly one renderer owns this selected rendition.
            output.suppressesPlayerRendering = true
        }
        render(text.isEmpty ? nil : text)
    }

    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        guard active, output === self.output else { return }
        render(nil) // Seeks/direction changes must not retain the previous cue.
    }
}
