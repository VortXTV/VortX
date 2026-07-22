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
                                      minimumSegmentCount: Int,
                                      minimumRenderedDurationMilliseconds: Int = 0) -> StartupMediaSnapshot? {
        guard minimumSegmentCount > 0, minimumRenderedDurationMilliseconds >= 0,
              !window.segments.isEmpty, window.mediaSequence == 0 else { return nil }
        for (expectedID, segment) in window.segments.enumerated() where segment.id != expectedID {
            return nil
        }

        var renderedMilliseconds = 0
        var prefixCount: Int?
        for (index, segment) in window.segments.enumerated() {
            guard let milliseconds = renderedDurationMilliseconds(segment.duration) else { return nil }
            let (sum, overflow) = renderedMilliseconds.addingReportingOverflow(milliseconds)
            guard !overflow else { return nil }
            renderedMilliseconds = sum
            if index + 1 >= minimumSegmentCount,
               renderedMilliseconds >= minimumRenderedDurationMilliseconds {
                prefixCount = index + 1
                break
            }
        }
        // A completed short source cannot grow into the live startup threshold. Publish its complete, legal
        // segment-zero prefix with ENDLIST. A completed source that already satisfies the threshold keeps the
        // same capped first body as a live producer, so an ahead-of-client mux cannot widen startup to its tail.
        guard let selectedCount = prefixCount else {
            guard ended else { return nil }
            return StartupMediaSnapshot(window: window, ended: true)
        }
        let pinnedSegments = Array(window.segments.prefix(selectedCount))
        return StartupMediaSnapshot(
            window: VortXHLSWindow(segments: pinnedSegments),
            ended: ended && pinnedSegments.count == window.segments.count)
    }

    /// Select one startup cohort shared by video, every advertised alternate-audio rendition, and subtitles.
    /// Each rendition must independently satisfy the rendered-duration floor, and every absolute ID must match
    /// the video base. The returned segment timing is the first window's timing; sibling routes use the same IDs
    /// with their own EXTINF values.
    static func pinnedStartupCohort(windows: [VortXHLSWindow],
                                    ended: Bool,
                                    minimumSegmentCount: Int,
                                    minimumRenderedDurationMilliseconds: Int) -> StartupMediaSnapshot? {
        guard let base = windows.first, !windows.isEmpty else { return nil }
        var requiredCount = 0
        for window in windows {
            guard let snapshot = pinnedStartupSnapshot(
                window: window,
                ended: ended,
                minimumSegmentCount: minimumSegmentCount,
                minimumRenderedDurationMilliseconds: minimumRenderedDurationMilliseconds) else { return nil }
            requiredCount = max(requiredCount, snapshot.window.segments.count)
        }
        guard requiredCount > 0, base.segments.count >= requiredCount else { return nil }
        let ids = Array(base.segments.prefix(requiredCount).map(\.id))
        for window in windows {
            let prefix = VortXHLSWindow(segments: Array(window.segments.prefix(requiredCount)))
            guard prefix.segments.map(\.id) == ids,
                  prefix.segments.count >= minimumSegmentCount || ended,
                  let duration = renderedDurationMilliseconds(of: prefix),
                  duration >= minimumRenderedDurationMilliseconds || ended else { return nil }
        }
        let selected = VortXHLSWindow(segments: Array(base.segments.prefix(requiredCount)))
        return StartupMediaSnapshot(
            window: selected,
            ended: ended && windows.allSatisfy { $0.segments.count == requiredCount })
    }

    /// Trim an already-contiguous rolling generation as far forward as possible while retaining both live
    /// floors. The caller appends only contiguous, previously unadvertised IDs before invoking this helper.
    static func minimumConformingSuffix(window: VortXHLSWindow,
                                         minimumSegmentCount: Int,
                                         minimumRenderedDurationMilliseconds: Int) -> VortXHLSWindow? {
        guard minimumSegmentCount > 0, minimumRenderedDurationMilliseconds >= 0,
              window.segments.count >= minimumSegmentCount else { return nil }
        guard let firstID = window.segments.first?.id, firstID >= 0 else { return nil }
        for (offset, segment) in window.segments.enumerated() {
            let (expectedID, overflow) = firstID.addingReportingOverflow(offset)
            guard !overflow, segment.id == expectedID else { return nil }
        }
        for index in window.segments.indices.dropFirst() {
            let candidate = VortXHLSWindow(segments: Array(window.segments[index...]))
            guard candidate.segments.count >= minimumSegmentCount else { break }
            guard let duration = renderedDurationMilliseconds(of: candidate) else { return nil }
            if duration >= minimumRenderedDurationMilliseconds { continue }
            let previous = VortXHLSWindow(segments: Array(window.segments[(index - 1)...]))
            return previous
        }
        guard let duration = renderedDurationMilliseconds(of: window),
              duration >= minimumRenderedDurationMilliseconds else { return nil }
        if window.segments.count == minimumSegmentCount {
            return window
        }
        let last = VortXHLSWindow(segments: Array(window.segments.suffix(minimumSegmentCount)))
        if let lastDuration = renderedDurationMilliseconds(of: last),
           lastDuration >= minimumRenderedDurationMilliseconds {
            return last
        }
        return window
    }

    /// The media renderer emits EXTINF to exactly three decimal places. Startup admission must total those
    /// emitted values, not the source Doubles: a client sees the rendered milliseconds and RFC duration math is
    /// defined over the distributed playlist. Parsing the shared formatter also avoids a second rounding rule.
    static func renderedDurationMilliseconds(of window: VortXHLSWindow) -> Int? {
        var total = 0
        for segment in window.segments {
            guard let milliseconds = renderedDurationMilliseconds(segment.duration) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(milliseconds)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private static func renderedDurationMilliseconds(_ duration: Double) -> Int? {
        guard duration.isFinite, duration >= 0 else { return nil }
        let rendered = renderedDuration(duration)
        let fields = rendered.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let seconds = Int(fields[0]),
              let fraction = Int(fields[1]),
              fields[1].count == 3 else { return nil }
        let (scaled, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
        let (milliseconds, addOverflow) = scaled.addingReportingOverflow(fraction)
        guard !multiplyOverflow, !addOverflow, milliseconds > 0 else { return nil }
        return milliseconds
    }

    private static func renderedDuration(_ duration: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), duration)
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
            lines.append("#EXTINF:\(renderedDuration(segment.duration)),")
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

/// Exact access-unit classifier for the two video codecs the remux lane can publish. FFmpeg's KEY flag also
/// covers HEVC CRA/BLA pictures; Apple segment independence requires IDR, so production passes the packet bytes
/// through this parser before asking the boundary policy to open or cut a segment.
enum VortXVideoIDRClassifier {
    enum Codec: Equatable, Sendable { case hevc, h264 }
    enum PacketFormat: Equatable, Sendable {
        case lengthPrefixed(Int)
        case annexB
    }

    static func isIDR(bytes: [UInt8], codec: Codec, format: PacketFormat) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return isIDR(bytes: base, count: buffer.count, codec: codec, format: format)
        }
    }

    static func isIDR(bytes: UnsafePointer<UInt8>, count: Int,
                      codec: Codec, format: PacketFormat) -> Bool {
        guard count > 0 else { return false }
        switch format {
        case .lengthPrefixed(let prefixBytes):
            return lengthPrefixedContainsIDR(
                bytes: bytes, count: count, prefixBytes: prefixBytes, codec: codec)
        case .annexB:
            return annexBContainsIDR(bytes: bytes, count: count, codec: codec)
        }
    }

    private static func lengthPrefixedContainsIDR(bytes: UnsafePointer<UInt8>, count: Int,
                                                  prefixBytes: Int, codec: Codec) -> Bool {
        guard prefixBytes == 1 || prefixBytes == 2 || prefixBytes == 4 else { return false }
        var cursor = 0
        var foundIDR = false
        while cursor < count {
            guard prefixBytes <= count - cursor else { return false }
            var nalLength = 0
            for index in 0..<prefixBytes {
                let (shifted, overflow) = nalLength.multipliedReportingOverflow(by: 256)
                guard !overflow else { return false }
                let (next, addOverflow) = shifted.addingReportingOverflow(Int(bytes[cursor + index]))
                guard !addOverflow else { return false }
                nalLength = next
            }
            cursor += prefixBytes
            let headerBytes = codec == .hevc ? 2 : 1
            guard nalLength >= headerBytes, nalLength <= count - cursor else { return false }
            switch classifyNAL(bytes: bytes + cursor, length: nalLength, codec: codec) {
            case .malformed, .otherVCL: return false
            case .idrVCL: foundIDR = true
            case .nonVCL: break
            }
            cursor += nalLength
        }
        return cursor == count && foundIDR
    }

    private static func annexBContainsIDR(bytes: UnsafePointer<UInt8>, count: Int,
                                          codec: Codec) -> Bool {
        guard let first = annexBStart(bytes: bytes, count: count, from: 0) else { return false }
        for index in 0..<first.offset where bytes[index] != 0 { return false }
        var start = first
        var foundIDR = false
        while true {
            let payloadStart = start.offset + start.length
            let next = annexBStart(bytes: bytes, count: count, from: payloadStart)
            let payloadEnd = next?.offset ?? count
            let headerBytes = codec == .hevc ? 2 : 1
            guard payloadEnd - payloadStart >= headerBytes else { return false }
            switch classifyNAL(bytes: bytes + payloadStart, length: payloadEnd - payloadStart, codec: codec) {
            case .malformed, .otherVCL: return false
            case .idrVCL: foundIDR = true
            case .nonVCL: break
            }
            guard let next else { return foundIDR }
            start = next
        }
    }

    private static func annexBStart(bytes: UnsafePointer<UInt8>, count: Int,
                                    from: Int) -> (offset: Int, length: Int)? {
        guard from >= 0, from < count else { return nil }
        var index = from
        while index + 3 <= count {
            if index + 4 <= count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                return (index, 4)
            }
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                return (index, 3)
            }
            index += 1
        }
        return nil
    }

    private enum NALClassification { case nonVCL, idrVCL, otherVCL, malformed }

    private static func classifyNAL(bytes: UnsafePointer<UInt8>, length: Int,
                                    codec: Codec) -> NALClassification {
        switch codec {
        case .hevc:
            guard length >= 2,
                  bytes[0] & 0x80 == 0,
                  bytes[1] & 0x07 != 0 else { return .malformed }
            let type = (bytes[0] >> 1) & 0x3f
            guard type <= 31 else { return .nonVCL }
            return type == 19 || type == 20 ? .idrVCL : .otherVCL
        case .h264:
            guard length >= 1, bytes[0] & 0x80 == 0 else { return .malformed }
            let type = bytes[0] & 0x1f
            let isVCL = (1...5).contains(type) || (19...21).contains(type)
            guard isVCL else { return .nonVCL }
            guard type == 5 else { return .otherVCL }
            return bytes[0] & 0x60 == 0 ? .malformed : .idrVCL
        }
    }
}

/// Legal video segmentation decision shared by the FFmpeg owner and the standalone mutation harness. Every
/// segment opens on the incoming packet, so segment zero and every cut packet must be IDR. The time/byte guards
/// are safety limits, not permission to publish a non-decodable boundary.
enum VortXHLSBoundaryPolicy {
    enum Decision: Equatable, Sendable {
        case open
        case continueOpen
        case cut
        case failSoft
    }

    static func decision(hasOpenSegment: Bool,
                         incomingIsIDR: Bool,
                         elapsed: Double,
                         openBytes: Int,
                         targetSeconds: Double = 1,
                         maximumSeconds: Double = 4,
                         maximumBytes: Int = 32 * 1024 * 1024) -> Decision {
        guard elapsed.isFinite, elapsed >= 0, openBytes >= 0,
              targetSeconds.isFinite, targetSeconds > 0,
              maximumSeconds.isFinite, maximumSeconds >= targetSeconds,
              maximumBytes > 0 else { return .failSoft }
        guard hasOpenSegment else { return incomingIsIDR ? .open : .failSoft }
        let hardLimitReached = elapsed >= maximumSeconds || openBytes >= maximumBytes
        if hardLimitReached { return incomingIsIDR ? .cut : .failSoft }
        if incomingIsIDR, elapsed >= targetSeconds { return .cut }
        return .continueOpen
    }
}

/// The init scanner reaching a terminal state and the init becoming publishable are independent properties.
/// An aborted scan must never masquerade as successful publication and reopen media cuts.
struct VortXHLSInitPublicationState: Equatable, Sendable {
    private(set) var scanTerminated = false
    private(set) var initPublished = false
    private(set) var failureReason: String?

    var mayPublishMedia: Bool { initPublished && failureReason == nil }

    mutating func publish() {
        guard failureReason == nil else { return }
        scanTerminated = true
        initPublished = true
    }

    mutating func abort(reason: String) {
        guard !initPublished else { return }
        scanTerminated = true
        failureReason = failureReason ?? reason
    }
}
