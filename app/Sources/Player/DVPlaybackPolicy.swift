import Foundation

/// Pure decision logic for the two Dolby Vision playback fixes, deliberately kept in a file that imports nothing
/// but Foundation.
///
/// Why it is separate: the code that USES these decisions lives in files that pull in AVFoundation, UIKit and the
/// remux stream, so a standalone harness cannot compile them without app-wide stubs. That forced the first version
/// of these gates to assert on SOURCE TEXT, and a substring assertion proves a line exists, not that it runs. A
/// mutant that kept every asserted string and appended `false` to the condition passed that suite while the guard
/// could never fire. Moving the decision here makes both properties executable, so a test calls the real function
/// and a semantic break fails it.
enum DVPlaybackPolicy {

    enum NativePreAttachOutcome: Equatable, Sendable {
        case stale
        case attachedWithLoadedCriteria
        case attachedFailSoft
    }

    /// Executes the native-DV completion ordering with injected side effects so the production attach sequence
    /// is mutation-testable without AVFoundation. A stale token/generation performs no work; a successful load
    /// applies the exact Apple-owned object before attach; a load failure attaches fail-soft without a guess.
    static func completeNativePreAttach<Criteria>(
        loadedCriteria: Criteria?,
        isCurrent: () -> Bool,
        apply: (Criteria) -> Void,
        attach: () -> Void
    ) -> NativePreAttachOutcome {
        guard isCurrent() else { return .stale }
        if let loadedCriteria {
            apply(loadedCriteria)
            guard isCurrent() else { return .stale }
            attach()
            return .attachedWithLoadedCriteria
        }
        attach()
        return .attachedFailSoft
    }

    // MARK: - HLS start position

    struct StartupMediaSnapshot: Equatable, Sendable {
        let window: VortXHLSWindow
        let ended: Bool
    }

    /// Freezes the first media response to the earliest absolute segment cohort. Master/display/audio waits may
    /// let the producer run far ahead, but they cannot widen this first body toward the live edge. A capped view
    /// cannot carry ENDLIST while later produced segments are intentionally hidden.
    static func pinnedStartupSnapshot(window: VortXHLSWindow,
                                      ended: Bool,
                                      minimumSegmentCount: Int) -> StartupMediaSnapshot? {
        guard minimumSegmentCount > 0,
              !window.segments.isEmpty,
              window.mediaSequence == 0,
              window.segments.count >= minimumSegmentCount || ended else { return nil }
        let pinnedSegments = Array(window.segments.prefix(minimumSegmentCount))
        return StartupMediaSnapshot(
            window: VortXHLSWindow(segments: pinnedSegments),
            ended: ended && pinnedSegments.count == window.segments.count)
    }

    /// Render exactly one immutable resident window. A sliding playlist cannot declare EVENT because an EVENT
    /// playlist may not remove earlier entries. The precise zero-start preference is valid only while segment zero
    /// is still the start of the session; after eviction MEDIA-SEQUENCE advances to the first retained absolute id.
    static func mediaPlaylistLines(window: VortXHLSWindow, ended: Bool,
                                   targetDuration: Int, mapURI: String) -> [String] {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(window.mediaSequence)",
        ]
        if window.mediaSequence == 0 {
            lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
        }
        lines.append("#EXT-X-MAP:URI=\"\(mapURI)\"")
        for segment in window.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("seg\(segment.id).m4s")
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        lines.append("")
        return lines
    }

    /// Plain values needed to render the local HLS master. Keeping this renderer dependency-free lets the
    /// flag-off body be compared byte-for-byte with the pre-rendition artifact while the Network server calls
    /// the same production function.
    struct MasterPlaylistInput: Equatable, Sendable {
        let videoCodec: String
        let supplementalCodec: String?
        let videoRange: String?
        let audioCodec: String?
        let width: Int
        let height: Int
        let bandwidth: Int
        let fps: Double
        let dolbyVision: Bool
    }

    /// Render the exact master artifact. With no optional tags or attributes this preserves the established
    /// plain and Dolby Vision bytes; feature-on media rows precede the variants and every variant receives the
    /// same group attributes.
    static func masterPlaylistData(input: MasterPlaylistInput,
                                   mediaTags: [String],
                                   streamInfAttributes: String) -> Data {
        let head = (["#EXTM3U", "#EXT-X-VERSION:7"] + mediaTags).joined(separator: "\n")
        var codecs = input.videoCodec
        if let audio = input.audioCodec { codecs += ",\(audio)" }

        func commonInf(bandwidth: Int) -> String {
            var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)"
            if input.width > 0, input.height > 0 {
                inf += ",RESOLUTION=\(input.width)x\(input.height)"
            }
            inf += ",CODECS=\"\(codecs)\""
            if input.fps > 0 { inf += String(format: ",FRAME-RATE=%.3f", input.fps) }
            return inf
        }

        if !input.dolbyVision {
            let inf = commonInf(bandwidth: input.bandwidth) + streamInfAttributes
            return Data("\(head)\n\(inf)\nmedia.m3u8\n".utf8)
        }

        var dvInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(input.bandwidth)"
        if input.width > 0, input.height > 0 {
            dvInf += ",RESOLUTION=\(input.width)x\(input.height)"
        }
        dvInf += ",CODECS=\"\(codecs)\""
        if let supplemental = input.supplementalCodec {
            dvInf += ",SUPPLEMENTAL-CODECS=\"\(supplemental)\""
        }
        if let range = input.videoRange { dvInf += ",VIDEO-RANGE=\(range)" }
        if input.fps > 0 { dvInf += String(format: ",FRAME-RATE=%.3f", input.fps) }
        dvInf += streamInfAttributes

        let fallbackBandwidth = max(input.bandwidth - 100_000, 1)
        let fallbackInf = commonInf(bandwidth: fallbackBandwidth) + streamInfAttributes
        return Data("\(head)\n\(dvInf)\nmedia.m3u8\n\(fallbackInf)\nmedia-hdr.m3u8\n".utf8)
    }

    // MARK: - Display switch de-duplication

    /// One request for a display mode. `range` is carried as its raw string so this file needs no player types.
    struct DisplayRequest: Equatable {
        let range: String
        let rate: Float
        let width: Int
        let height: Int

        init(range: String, rate: Float, width: Int, height: Int) {
            self.range = range
            self.rate = rate
            self.width = width
            self.height = height
        }
    }

    /// Resolve one session's display rate without inventing a value. The remux classifier is authoritative; an
    /// AVAssetTrack rate is only a fallback for sessions with no classified value.
    static func frameRate(classified: Double, assetTrack: Double) -> Double? {
        if classified.isFinite, classified > 0 { return classified }
        if assetTrack.isFinite, assetTrack > 0 { return assetTrack }
        return nil
    }

    /// Manager-owned request memory. Pending requests coalesce while an assignment is in flight, failed
    /// assignments are retryable, and replacing the AVDisplayManager invalidates the previous manager's state.
    struct DisplayRequestLedger {
        private var managerID: ObjectIdentifier?
        private var pending: DisplayRequest?
        private var applied: DisplayRequest?

        mutating func begin(_ request: DisplayRequest, manager: AnyObject) -> Bool {
            let nextManagerID = ObjectIdentifier(manager)
            if managerID != nextManagerID {
                managerID = nextManagerID
                pending = nil
                applied = nil
            }
            guard pending != request, applied != request else { return false }
            pending = request
            return true
        }

        mutating func complete(_ request: DisplayRequest, manager: AnyObject, applied wasApplied: Bool) {
            guard managerID == ObjectIdentifier(manager), pending == request else { return }
            pending = nil
            if wasApplied { applied = request }
        }

        mutating func reset() {
            managerID = nil
            pending = nil
            applied = nil
        }
    }

    /// Selected-option identity cached by AVPlayerEngine. Both explicit calls and AVPlayer's system notification
    /// pass through this state so cached MPVTrack flags update once per real transition, including Off.
    struct SelectionRefreshState {
        private struct Snapshot: Equatable {
            let audio: Int?
            let subtitle: Int?
        }

        private var snapshot: Snapshot?

        mutating func update(audio: Int?, subtitle: Int?) -> Bool {
            let next = Snapshot(audio: audio, subtitle: subtitle)
            guard snapshot != next else { return false }
            snapshot = next
            return true
        }

        mutating func reset() { snapshot = nil }
    }

    static func selectedFlags(optionCount: Int, selectedIndex: Int?) -> [Bool] {
        (0..<max(0, optionCount)).map { $0 == selectedIndex }
    }
}
