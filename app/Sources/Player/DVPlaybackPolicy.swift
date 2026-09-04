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

    /// Prefix carried unchanged from remux classification to the player source-failover edge. Keeping one
    /// typed prefix prevents a mislabeled preview asset from being reduced to a generic AVPlayer URL error.
    static let sourceCapabilityMismatchPrefix = "source capability mismatch:"

    /// A source ranked and routed as Dolby Vision can still resolve to a short 720p preview or trailer. The
    /// diagnostic signature is deliberately strict: low-resolution video, no audio track, and no Dolby Vision
    /// configuration after both container and bounded in-band inspection. Any partial match keeps the ordinary
    /// codec/profile path because a valid unusual source must never be skipped by inference.
    static func sourceCapabilityMismatch(
        requiresDolbyVision: Bool,
        width: Int,
        height: Int,
        dolbyVisionProfile: Int,
        audioTrackCount: Int
    ) -> String? {
        guard requiresDolbyVision,
              width > 0, height > 0,
              max(width, height) <= 1280,
              min(width, height) <= 720,
              dolbyVisionProfile < 0,
              audioTrackCount == 0 else { return nil }
        return "\(sourceCapabilityMismatchPrefix) routed Dolby Vision but resolved "
            + "\(width)x\(height), no audio, and no Dolby Vision configuration"
    }

    static func isSourceCapabilityMismatch(_ message: String) -> Bool {
        message.hasPrefix(sourceCapabilityMismatchPrefix)
    }

    /// A tvOS Dolby Vision display switch may overlap the remaining remux setup only after source metadata
    /// proves the route is viable without packet inspection. Final HLS signaling and master publication remain
    /// gated on the completed output header, so this only moves the expensive display preparation earlier.
    static func canPublishEarlyDisplayIntent(
        requiresDolbyVision: Bool,
        dolbyVisionProfile: Int,
        width: Int,
        height: Int,
        frameRate: Double,
        hasBaseVideo: Bool,
        hvc1ExtradataReady: Bool,
        hasStreamCopyAudio: Bool
    ) -> Bool {
        requiresDolbyVision
            && (dolbyVisionProfile == 5
                || dolbyVisionProfile == 7
                || dolbyVisionProfile == 8)
            && width > 0
            && height > 0
            && frameRate.isFinite
            && frameRate > 0
            && hasBaseVideo
            && hvc1ExtradataReady
            && hasStreamCopyAudio
    }

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
    ///
    /// `isEvent` is the exception, and it defaults false so every existing caller renders byte-for-byte what it
    /// always has. An engine host that RETAINS its whole timeline never removes an entry, which is exactly the
    /// promise RFC 8216 4.3.3.5 defines EVENT as, and making that promise explicit is what entitles a client to
    /// treat the whole timeline as seekable instead of assuming the start may move out from under it. Declaring
    /// EVENT on a sliding playlist would be a lie that clients are allowed to act on, hence the default.
    static func mediaPlaylistLines(window: VortXHLSWindow, ended: Bool,
                                   targetDuration: Int, mapURI: String,
                                   isEvent: Bool = false) -> [String] {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(window.mediaSequence)",
        ]
        if isEvent { lines.append("#EXT-X-PLAYLIST-TYPE:EVENT") }
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

    enum MasterVideoVariant: Equatable, Sendable {
        case primary
        case hdrFallback
    }

    enum HDRFallbackDisplayRange: Equatable, Sendable {
        case hdr10
        case hlg
    }

    /// Render the exact master artifact. With no optional tags or attributes this preserves the established
    /// plain and Dolby Vision bytes; feature-on media rows precede the variants and every variant receives the
    /// same group attributes.
    static func masterPlaylistData(input: MasterPlaylistInput,
                                   mediaTags: [String],
                                   streamInfAttributes: String,
                                   videoVariant: MasterVideoVariant = .primary) -> Data {
        let head = (["#EXTM3U", "#EXT-X-VERSION:7"] + mediaTags).joined(separator: "\n")
        var codecs = input.videoCodec
        if let audio = input.audioCodec { codecs += ",\(audio)" }

        func commonInf(bandwidth: Int, videoRange: String? = nil) -> String {
            var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)"
            if input.width > 0, input.height > 0 {
                inf += ",RESOLUTION=\(input.width)x\(input.height)"
            }
            inf += ",CODECS=\"\(codecs)\""
            if let videoRange { inf += ",VIDEO-RANGE=\(videoRange)" }
            if input.fps > 0 { inf += String(format: ",FRAME-RATE=%.3f", input.fps) }
            return inf
        }

        if !input.dolbyVision {
            let inf = commonInf(bandwidth: input.bandwidth) + streamInfAttributes
            return Data("\(head)\n\(inf)\nmedia.m3u8\n".utf8)
        }

        if videoVariant == .hdrFallback {
            let fallbackRange = hdrFallbackDisplayRange(videoRange: input.videoRange) == .hlg
                ? "HLG" : "PQ"
            let inf = commonInf(
                bandwidth: input.bandwidth,
                videoRange: fallbackRange) + streamInfAttributes
            return Data("\(head)\n\(inf)\nmedia-hdr.m3u8\n".utf8)
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

        return Data("\(head)\n\(dvInf)\nmedia.m3u8\n".utf8)
    }

    /// The error-log fields needed to prove that AVFoundation rejected the PRIMARY Dolby Vision initialization
    /// resource. This intentionally contains no AVFoundation types so the admission rule stays executable in
    /// the contract suite.
    struct HDRFallbackErrorLogEvent: Equatable, Sendable {
        let errorDomain: String?
        let errorStatusCode: Int
        let uri: String?
    }

    /// Evidence available at the instant a DV item fails. A mid-play failure must never replace an item with
    /// an HDR variant because that replacement loses the user's active decoder, media selections and picture.
    struct HDRFallbackAdmissionEvidence: Equatable, Sendable {
        let videoFrameEverProduced: Bool
        let errorLogEvents: [HDRFallbackErrorLogEvent]
    }

    /// True only for the one known compatibility edge: CoreMedia rejected this remux's primary `init.mp4`
    /// before it ever rendered a video frame. Error-log URI provenance prevents ordinary playlist, segment,
    /// audio and subtitle transport failures from being misrepresented as Dolby Vision incompatibility.
    static func hasPrimaryDVInitFailure(_ evidence: HDRFallbackAdmissionEvidence) -> Bool {
        guard !evidence.videoFrameEverProduced else { return false }
        return evidence.errorLogEvents.contains { event in
            guard event.errorDomain == "CoreMediaErrorDomain",
                  event.errorStatusCode == -12927,
                  let uri = event.uri,
                  let components = URLComponents(string: uri),
                  components.scheme != nil,
                  components.host != nil,
                  let url = components.url else { return false }
            return url.lastPathComponent == "init.mp4"
        }
    }

    /// A CoreMedia rejection of a healthy DV item gets one explicit HDR-only item, never an in-item variant
    /// switch. A source with no compatible base layer, such as Profile 5, cannot truthfully enter this path.
    static func shouldAttemptHDRFallback(dolbyVision: Bool,
                                         remuxMounted: Bool,
                                         mountHealthy: Bool,
                                         fallbackAvailable: Bool,
                                         alreadyAttempted: Bool,
                                         errorDomain: String?,
                                         errorCode: Int,
                                         evidence: HDRFallbackAdmissionEvidence) -> Bool {
        dolbyVision
            && remuxMounted
            && mountHealthy
            && fallbackAvailable
            && !alreadyAttempted
            && errorDomain == "CoreMediaErrorDomain"
            && errorCode == -12927
            && hasPrimaryDVInitFailure(evidence)
    }

    /// A recovery capability exists only after byte surgery settled successfully. Profile 5 remains excluded
    /// even if malformed state somehow supplied bytes, because its IPT-only base is not independently playable.
    static func supportsHDRFallback(
        dolbyVision: Bool,
        videoCodec: String,
        surgerySettled: Bool,
        recoveryInitAvailable: Bool
    ) -> Bool {
        dolbyVision
            && !videoCodec.lowercased().hasPrefix("dvh1.05")
            && surgerySettled
            && recoveryInitAvailable
    }

    /// A recovery item may share a mount whose one ready transition already happened. It may also be the item
    /// that crosses that transition after a pre-ready primary failure. Every other false transition is terminal.
    static func acceptsRemuxReady(transitionAccepted: Bool,
                                  mountAlreadyReady: Bool,
                                  recoveryItem: Bool) -> Bool {
        transitionAccepted || (recoveryItem && mountAlreadyReady)
    }

    /// One-shot replacement seek state that keeps player-clock restoration separate from user source-clock
    /// intent. A user action arriving during replacement supersedes the automatic value, and `consume` clears
    /// both domains atomically so no later callback can replay either seek.
    struct HDRRecoverySeekState: Equatable, Sendable {
        private(set) var automaticPlayerSeconds: Double?
        private(set) var userSourceSeconds: Double?

        /// Begin one replacement atomically. A resume or seek queued before the failed item became ready is
        /// already user source-time intent, so it must be installed in the same write that stages the fallback
        /// player clock. This prevents replacement setup from clearing the queued intent between two calls.
        mutating func stageReplacement(
            playerSeconds: Double,
            queuedUserSourceSeconds: Double?
        ) {
            automaticPlayerSeconds = playerSeconds
            userSourceSeconds = queuedUserSourceSeconds
        }

        mutating func supersedeWithUser(sourceSeconds: Double) {
            userSourceSeconds = sourceSeconds
        }

        mutating func consume(sourceToPlayer: (Double) -> Double) -> Double? {
            let target = userSourceSeconds.map(sourceToPlayer) ?? automaticPlayerSeconds
            automaticPlayerSeconds = nil
            userSourceSeconds = nil
            return target
        }

        mutating func reset() {
            automaticPlayerSeconds = nil
            userSourceSeconds = nil
        }

        /// Choose the source-time resume point if a hosted engine disappears during replacement. A staged user
        /// source seek is already in the required domain. Otherwise map the old item's staged player clock
        /// through the live mount origin; the replacement item's current clock may still be zero. A seek queued
        /// before replacement staging, such as one received during the hosted capability refresh, is newer than
        /// both staged values and therefore wins first.
        func failoverSourceSeconds(
            pendingUserSourceSeconds: Double? = nil,
            currentSourceSeconds: Double,
            playerToSource: (Double) -> Double
        ) -> Double {
            if let pendingUserSourceSeconds { return pendingUserSourceSeconds }
            if let userSourceSeconds { return userSourceSeconds }
            if let automaticPlayerSeconds { return playerToSource(automaticPlayerSeconds) }
            return currentSourceSeconds
        }
    }

    /// Media-selection snapshot for an HDR replacement item. User actions received while AVFoundation is still
    /// loading the new groups mutate this snapshot, so the newest intent wins when the groups become available.
    struct HDRRecoverySelectionState: Equatable, Sendable {
        var audioSelectionKnown: Bool
        var audioIndex: Int?
        var subtitleSelectionKnown: Bool
        var subtitleIndex: Int?
        var externalSubtitleActive: Bool

        mutating func selectAudio(_ id: Int) {
            audioSelectionKnown = true
            audioIndex = id >= 0 ? id : nil
        }

        mutating func selectSubtitle(_ id: Int, externalTrackID: Int) {
            subtitleSelectionKnown = true
            if id == externalTrackID {
                subtitleIndex = nil
                externalSubtitleActive = true
            } else {
                subtitleIndex = id >= 0 ? id : nil
                externalSubtitleActive = false
            }
        }
    }

    /// Choose the newest selection intent for a fresh remount. A replacement-time snapshot is newer than the
    /// failed item's groups and therefore wins. External overlay cues are deliberately not preserved because
    /// `loadFile` discards their parsed payload; retaining only the active flag would advertise a row that can
    /// no longer render. Embedded selections remain stable and an invalid external selection becomes Off.
    static func selectionForFreshRemount(
        pendingReplacement: HDRRecoverySelectionState?,
        current: HDRRecoverySelectionState
    ) -> HDRRecoverySelectionState {
        var selected = pendingReplacement ?? current
        if selected.externalSubtitleActive {
            selected.subtitleSelectionKnown = true
            selected.subtitleIndex = nil
            selected.externalSubtitleActive = false
        }
        return selected
    }

    /// The post-first-frame bitrate pin is valid only for an authoritatively signaled primary DV remux item.
    /// Route intent alone is insufficient because a plain remux can share the same controller and bandwidth
    /// field, and the HDR recovery item deliberately no longer carries Dolby Vision.
    static func shouldPinPreferredPeakBitRate(
        isRemuxMounted: Bool,
        usingHDRFallbackItem: Bool,
        contentIsDolbyVision: Bool,
        signalingDolbyVision: Bool
    ) -> Bool {
        isRemuxMounted
            && !usingHDRFallbackItem
            && contentIsDolbyVision
            && signalingDolbyVision
    }

    /// Preserve the origin, capability prefix and query while replacing only the primary master resource.
    /// A different terminal resource is not a remux master and fails closed.
    static func hdrFallbackMasterURL(from primaryURL: URL) -> URL? {
        guard var components = URLComponents(url: primaryURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let suffix = "/master.m3u8"
        guard components.path.hasSuffix(suffix) else { return nil }
        components.path = String(components.path.dropLast(suffix.count)) + "/master-hdr.m3u8"
        return components.url
    }

    /// Profile 8.4 carries an HLG-compatible base layer. Other compatible recovery assets use HDR10/PQ.
    static func hdrFallbackDisplayRange(videoRange: String?) -> HDRFallbackDisplayRange {
        videoRange?.uppercased() == "HLG" ? .hlg : .hdr10
    }

    // MARK: - libmpv pre-probe colour fallback (unsafe-until-proven-safe)

    /// Evidence available about a Dolby Vision title BEFORE mpv has decoded any real video parameters
    /// (empty gamma, sig-peak still 0.0/unset). A text-parsed "this stream is Dolby Vision" Boolean is not
    /// proof of which colour space the eventual decoded frames use: Profile 8.1 carries an HDR10-compatible
    /// base layer and may safely pre-seed HDR10 while mpv is still probing, but Profile 5 has no
    /// independently playable base layer, and relabelling it HDR10 on a guess can present a genuine
    /// green/purple matrix error as if it were correct output. `nil` on either field means "not proven",
    /// never "assume compatible".
    struct DolbyVisionFallbackInfo: Equatable, Sendable {
        let profile: Int?
        let baseLayerHDR10Compatible: Bool?

        static let unknown = DolbyVisionFallbackInfo(profile: nil, baseLayerHDR10Compatible: nil)
    }

    /// What the libmpv pre-probe colour policy may do before mpv has reported ANY decoded transfer
    /// function or signal peak. The caller's own decoded-parameter branches (real gamma/sigPeak evidence)
    /// are consulted first and always win; this decision exists only for the gap before that evidence
    /// exists, where a bare "is DV" flag used to be trusted as if it were proof.
    enum DolbyVisionFallbackOutput: Equatable, Sendable {
        /// No decoded evidence and no proven-compatible base layer: apply NOTHING. Do not set
        /// target-trc/target-prim, tag the layer colourspace, or request a tvOS display mode. The next
        /// decoded-parameter callback re-derives the real answer once mpv has actually probed the stream.
        case waitForDecodedParameters
        case hdr10
        case mappedDolbyVision
        /// A proven-incompatible base layer (Profile 5, or an explicit non-HDR10-compatible id) with no
        /// mapped Dolby Vision output path available on this lane. The caller must not relabel this as
        /// HDR10; it needs a source hop, not a colour tag.
        case rejectAndHopSource
    }

    /// Decision order: (1) a proven HDR10-compatible base layer (container/DOVI
    /// `dv_bl_signal_compatibility_id`) is safe to pre-seed as HDR10; (2) an explicitly proven-incompatible
    /// base layer (Profile 5, or `baseLayerHDR10Compatible == false`) uses a mapped Dolby Vision path if one
    /// exists on this lane, otherwise the source must be rejected/hopped rather than relabelled; (3)
    /// everything else - including the common case where no profile/compatibility evidence has reached this
    /// lane at all - waits instead of guessing. Callers consult this ONLY while real decoded transfer/peak
    /// evidence is still absent; once mpv reports gamma=="pq" or sigPeak>1.0 that IS proof and the caller's
    /// own decoded-parameter branch already resolves HDR10 without going through this function at all.
    static func dolbyVisionFallbackOutput(
        contentIsDolbyVision: Bool,
        info: DolbyVisionFallbackInfo,
        mappedDolbyVisionAvailable: Bool
    ) -> DolbyVisionFallbackOutput {
        guard contentIsDolbyVision else { return .waitForDecodedParameters }
        if info.baseLayerHDR10Compatible == true { return .hdr10 }
        if info.profile == 5 || info.baseLayerHDR10Compatible == false {
            return mappedDolbyVisionAvailable ? .mappedDolbyVision : .rejectAndHopSource
        }
        return .waitForDecodedParameters
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

        /// True when `other` can only negotiate the SAME HDMI mode as this request. tvOS display-mode
        /// matching selects a mode by dynamic range and refresh rate; the output resolution is the
        /// user's Settings choice and never follows content dimensions, so a width/height difference
        /// cannot change the negotiated mode. Re-assigning criteria that differ only in dimensions
        /// still renegotiates the link (a visible blank): the remux lane asks once with classifier
        /// dimensions (serveMaster) and once with the item's presentationSize (readyToPlay), and on a
        /// binge run those two ping-pong every episode, so the ledger must treat them as one mode.
        func selectsSameMode(as other: DisplayRequest) -> Bool {
            range == other.range && rate == other.rate
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
            // Redundancy is judged on the fields that can actually change the negotiated HDMI mode
            // (range + rate, see selectsSameMode). A dims-only repeat of an applied or in-flight mode
            // is a no-op skip instead of a fresh criteria assignment, because tvOS renegotiates (and
            // blanks) on assignment even when the resolved mode is identical. A range or rate change
            // is never skipped, so a needed switch cannot be lost.
            if let pending, request.selectsSameMode(as: pending) { return false }
            if let applied, request.selectsSameMode(as: applied) { return false }
            pending = request
            return true
        }

        mutating func complete(_ request: DisplayRequest, manager: AnyObject, applied wasApplied: Bool) {
            guard managerID == ObjectIdentifier(manager), pending == request else { return }
            pending = nil
            if wasApplied { applied = request }
        }

        func isApplied(_ request: DisplayRequest, manager: AnyObject) -> Bool {
            managerID == ObjectIdentifier(manager)
                && applied?.selectsSameMode(as: request) == true
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

/// Exact access-unit classifier for the two video codecs the remux lane can publish. A segment may open only
/// at a picture from which decode can begin independently. For HEVC that is any IRAP with a defined
/// random-access contract: IDR (19/20), CRA (21) and BLA (16-18). CRA/BLA are MP4 sync samples and legal HLS
/// segment starts (their RASL leading pictures are discarded by a decoder that tunes in at the IRAP); the
/// field regression that motivated this widening was IDR-only classification killing every open-GOP HEVC
/// source: such encodes carry CRA keyframes for long stretches (and a resume seek lands on one), so the
/// boundary policy could never cut (fresh play died at the frozen-target cap) or never open (resume died on
/// its first packet) and the whole DV mount 404'd into the libmpv HDR10 demote. Build 187 cut on FFmpeg's
/// KEY flag, which covers exactly these IRAP types, and shipped that behavior for months. H.264 stays
/// IDR-only: its open-GOP recovery points are SEI-signaled and not provable from one NAL header.
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
            // IRAP with a random-access contract: BLA_W_LP(16) ... CRA_NUT(21). See the type doc above.
            return (16...21).contains(type) ? .idrVCL : .otherVCL
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

/// Fail-closed ISO-BMFF proof used immediately before a muxed HLS byte range is published. A range is
/// publishable only when every top-level box is complete, every `moof` is paired with the following `mdat`,
/// and the requested track can be resolved from `tfhd.track_ID`. Video additionally proves that sample zero
/// in the first fragment is sync. Packet-level IDR evidence remains a separate required gate because an MP4
/// sync flag alone does not prove the encoded NAL is an IDR picture.
enum VortXFMP4FragmentParser {
    struct VideoSampleFormat: Equatable, Sendable {
        let codec: VortXVideoIDRClassifier.Codec
        let packetFormat: VortXVideoIDRClassifier.PacketFormat
    }

    struct MediaRangeProof: Equatable, Sendable {
        let mediaEnd: Int
        let fragmentCount: Int
        let sampleCount: Int
        let firstSampleIsSync: Bool?
        let firstSampleBytes: Data
    }

    /// Presentation-clock proof for one track across the delayed init and its first media fragment.
    ///
    /// `tfdt == 0` alone does not prove a fresh item begins at zero. movenc can also write a positive leading
    /// empty edit into `elst`, which makes AVFoundation expose the original source offset while the fragment's
    /// decode clock still starts at zero. Keeping both witnesses in one proof prevents that false green.
    struct TrackTimelineProof: Equatable, Sendable {
        let movieTimescale: UInt32
        let mediaTimescale: UInt32
        let leadingEmptyEditDuration: UInt64
        let firstBaseDecodeTime: UInt64

        var leadingEmptyEditSeconds: Double {
            Double(leadingEmptyEditDuration) / Double(movieTimescale)
        }

        var firstBaseDecodeSeconds: Double {
            Double(firstBaseDecodeTime) / Double(mediaTimescale)
        }

        var effectiveStartSeconds: Double {
            leadingEmptyEditSeconds + firstBaseDecodeSeconds
        }
    }

    static func videoTrackID(inInit data: Data) -> UInt32? {
        mediaTrackID(inInit: data, handlerType: "vide")
    }

    static func audioTrackID(inInit data: Data) -> UInt32? {
        mediaTrackID(inInit: data, handlerType: "soun")
    }

    static func trackTimelineProof(inInit initData: Data,
                                   firstMedia: Data,
                                   trackID: UInt32) -> TrackTimelineProof? {
        guard trackID != 0,
              let top = boxes(in: initData, range: initData.startIndex..<initData.endIndex),
              top.filter({ $0.type == "moov" }).count == 1,
              let moov = top.first(where: { $0.type == "moov" }),
              let moovChildren = boxes(in: initData, range: moov.payload),
              let mvhd = moovChildren.first(where: { $0.type == "mvhd" }),
              let movieTimescale = timescale(inFullHeader: mvhd, data: initData) else { return nil }

        var selectedTrack: Box?
        for trak in moovChildren where trak.type == "trak" {
            guard let trakChildren = boxes(in: initData, range: trak.payload),
                  let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
                  let candidateID = Self.trackID(inTKHD: tkhd, data: initData) else { return nil }
            guard candidateID == trackID else { continue }
            guard selectedTrack == nil else { return nil }
            selectedTrack = trak
        }
        guard let selectedTrack,
              let trakChildren = boxes(in: initData, range: selectedTrack.payload),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = boxes(in: initData, range: mdia.payload),
              let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let mediaTimescale = timescale(inFullHeader: mdhd, data: initData) else { return nil }

        let emptyEditDuration: UInt64
        if let edts = trakChildren.first(where: { $0.type == "edts" }) {
            guard let parsed = leadingEmptyEditDuration(in: edts, data: initData) else { return nil }
            emptyEditDuration = parsed
        } else {
            emptyEditDuration = 0
        }
        guard let firstBaseDecodeTime = firstBaseDecodeTime(
            in: firstMedia,
            trackID: trackID
        ) else { return nil }
        return TrackTimelineProof(
            movieTimescale: movieTimescale,
            mediaTimescale: mediaTimescale,
            leadingEmptyEditDuration: emptyEditDuration,
            firstBaseDecodeTime: firstBaseDecodeTime)
    }

    static func videoSampleFormat(inInit data: Data, trackID: UInt32) -> VideoSampleFormat? {
        guard trackID != 0,
              let top = boxes(in: data, range: data.startIndex..<data.endIndex),
              let moov = top.first(where: { $0.type == "moov" }),
              let moovChildren = boxes(in: data, range: moov.payload) else { return nil }
        for trak in moovChildren where trak.type == "trak" {
            guard let trakChildren = boxes(in: data, range: trak.payload),
                  let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
                  let candidateID = Self.trackID(inTKHD: tkhd, data: data) else { return nil }
            guard candidateID == trackID else { continue }
            guard let mdia = trakChildren.first(where: { $0.type == "mdia" }),
                  let mdiaChildren = boxes(in: data, range: mdia.payload),
                  let minf = mdiaChildren.first(where: { $0.type == "minf" }),
                  let minfChildren = boxes(in: data, range: minf.payload),
                  let stbl = minfChildren.first(where: { $0.type == "stbl" }),
                  let stblChildren = boxes(in: data, range: stbl.payload),
                  let stsd = stblChildren.first(where: { $0.type == "stsd" }),
                  stsd.payload.count >= 8 else { return nil }
            let entriesStart = stsd.payload.lowerBound + 8
            guard let entries = boxes(in: data, range: entriesStart..<stsd.payload.upperBound),
                  entries.count == 1, let entry = entries.first,
                  entry.payload.count >= 78 else { return nil }
            let codec: VortXVideoIDRClassifier.Codec
            let configType: String
            switch entry.type {
            case "hvc1", "hev1", "dvh1", "dvhe":
                codec = .hevc
                configType = "hvcC"
            case "avc1", "avc3":
                codec = .h264
                configType = "avcC"
            default:
                return nil
            }
            let childrenStart = entry.payload.lowerBound + 78
            guard let entryChildren = boxes(in: data, range: childrenStart..<entry.payload.upperBound),
                  let config = entryChildren.first(where: { $0.type == configType }) else { return nil }
            let lengthSize: Int
            switch codec {
            case .hevc:
                guard config.payload.count >= 22 else { return nil }
                lengthSize = Int(data[config.payload.lowerBound + 21] & 0x03) + 1
            case .h264:
                guard config.payload.count >= 5 else { return nil }
                lengthSize = Int(data[config.payload.lowerBound + 4] & 0x03) + 1
            }
            guard lengthSize == 1 || lengthSize == 2 || lengthSize == 4 else { return nil }
            return VideoSampleFormat(codec: codec, packetFormat: .lengthPrefixed(lengthSize))
        }
        return nil
    }

    static func trackIDsInFirstFragment(_ data: Data) -> [UInt32]? {
        guard let top = boxes(in: data, range: data.startIndex..<data.endIndex),
              let moof = top.first(where: { $0.type == "moof" }),
              let children = boxes(in: data, range: moof.payload) else { return nil }
        var trackIDs: [UInt32] = []
        for traf in children where traf.type == "traf" {
            guard let trafChildren = boxes(in: data, range: traf.payload),
                  let tfhdBox = trafChildren.first(where: { $0.type == "tfhd" }),
                  let tfhd = trackFragmentHeader(in: tfhdBox, data: data) else { return nil }
            trackIDs.append(tfhd.trackID)
        }
        return trackIDs.isEmpty ? nil : trackIDs
    }

    /// `mediaEnd` is relative to `data.startIndex`. It normally equals `data.count`; at EOF it may stop before
    /// a fully parsed trailing `mfra`, which is index metadata and must not enter the final media byte range.
    static func proveMediaRange(_ data: Data,
                                trackID: UInt32,
                                requireFirstSampleSync: Bool) -> MediaRangeProof? {
        guard trackID != 0, !data.isEmpty,
              let boxes = boxes(in: data, range: data.startIndex..<data.endIndex) else { return nil }
        var pending: FragmentSummary?
        var fragmentCount = 0
        var sampleCount = 0
        var firstSampleIsSync: Bool?
        var firstSampleBytes: Data?
        var mediaEnd: Int?
        var sawTrailer = false

        for box in boxes {
            switch box.type {
            case "styp", "sidx", "emsg", "prft", "free", "skip":
                guard pending == nil, !sawTrailer else { return nil }
            case "moof":
                guard pending == nil, !sawTrailer,
                      let summary = fragmentSummary(
                          in: data, moof: box, trackID: trackID) else { return nil }
                pending = summary
            case "mdat":
                guard let summary = pending else { return nil }
                pending = nil
                guard summary.firstSampleRange.lowerBound >= box.payload.lowerBound,
                      summary.firstSampleRange.upperBound <= box.payload.upperBound else { return nil }
                let (newSamples, overflow) = sampleCount.addingReportingOverflow(summary.sampleCount)
                guard !overflow else { return nil }
                sampleCount = newSamples
                if fragmentCount == 0 {
                    firstSampleIsSync = summary.firstSampleIsSync
                    firstSampleBytes = Data(data[summary.firstSampleRange])
                }
                fragmentCount += 1
                mediaEnd = box.end - data.startIndex
            case "mfra":
                guard pending == nil, mediaEnd != nil, !sawTrailer else { return nil }
                sawTrailer = true
            default:
                return nil
            }
        }

        guard pending == nil, fragmentCount > 0, sampleCount > 0,
              let mediaEnd, let firstSampleBytes, !firstSampleBytes.isEmpty else { return nil }
        if requireFirstSampleSync, firstSampleIsSync != true { return nil }
        return MediaRangeProof(
            mediaEnd: mediaEnd,
            fragmentCount: fragmentCount,
            sampleCount: sampleCount,
            firstSampleIsSync: firstSampleIsSync,
            firstSampleBytes: firstSampleBytes)
    }

    /// Proves exactly the first complete `moof` + following `mdat` at the front of a media range. Bytes for a
    /// complete or partial successor fragment are deliberately ignored. The HLS publication FIFO uses this
    /// narrower proof so one producer advance can never collapse two queued boundaries into one byte range.
    /// Callers that need an aggregate EOF/media proof continue to use `proveMediaRange` above.
    static func proveFirstMediaFragment(_ data: Data,
                                        trackID: UInt32,
                                        requireFirstSampleSync: Bool) -> MediaRangeProof? {
        guard trackID != 0, !data.isEmpty else { return nil }
        var cursor = data.startIndex
        var pending: FragmentSummary?
        while cursor < data.endIndex {
            guard let box = box(in: data, start: cursor, limit: data.endIndex) else { return nil }
            cursor = box.end
            switch box.type {
            case "styp", "sidx", "emsg", "prft", "free", "skip":
                guard pending == nil else { return nil }
            case "moof":
                guard pending == nil,
                      let summary = fragmentSummary(
                          in: data, moof: box, trackID: trackID) else { return nil }
                pending = summary
            case "mdat":
                guard let summary = pending,
                      summary.firstSampleRange.lowerBound >= box.payload.lowerBound,
                      summary.firstSampleRange.upperBound <= box.payload.upperBound else { return nil }
                let firstSampleBytes = Data(data[summary.firstSampleRange])
                guard !firstSampleBytes.isEmpty,
                      !requireFirstSampleSync || summary.firstSampleIsSync == true else { return nil }
                return MediaRangeProof(
                    mediaEnd: box.end - data.startIndex,
                    fragmentCount: 1,
                    sampleCount: summary.sampleCount,
                    firstSampleIsSync: summary.firstSampleIsSync,
                    firstSampleBytes: firstSampleBytes)
            default:
                return nil
            }
        }
        return nil
    }

    private struct Box {
        let type: String
        let start: Data.Index
        let payload: Range<Data.Index>
        let end: Data.Index
    }

    private struct FragmentSummary {
        let sampleCount: Int
        let firstSampleIsSync: Bool?
        let firstSampleRange: Range<Data.Index>
    }

    private struct TrackFragmentHeader {
        let trackID: UInt32
        let defaultSampleSize: Int?
        let defaultSampleFlags: UInt32?
        let defaultBaseIsMoof: Bool
    }

    private struct TrackRunSummary {
        let sampleCount: Int
        let firstSampleFlags: UInt32?
        let firstSampleSize: Int?
        let dataOffset: Int32?
    }

    private static func mediaTrackID(inInit data: Data, handlerType: String) -> UInt32? {
        guard let top = boxes(in: data, range: data.startIndex..<data.endIndex),
              top.filter({ $0.type == "moov" }).count == 1,
              let moov = top.first(where: { $0.type == "moov" }),
              let moovChildren = boxes(in: data, range: moov.payload) else { return nil }
        var resolved: UInt32?
        for trak in moovChildren where trak.type == "trak" {
            guard let trakChildren = boxes(in: data, range: trak.payload),
                  let mdia = trakChildren.first(where: { $0.type == "mdia" }),
                  let mdiaChildren = boxes(in: data, range: mdia.payload),
                  let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) else { return nil }
            let handlerStart = hdlr.payload.lowerBound + 8
            guard handlerStart + 4 <= hdlr.payload.upperBound else { return nil }
            let handler = String(bytes: data[handlerStart..<(handlerStart + 4)], encoding: .ascii)
            guard handler == handlerType else { continue }
            guard let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
                  let trackID = trackID(inTKHD: tkhd, data: data),
                  resolved == nil else { return nil }
            resolved = trackID
        }
        return resolved
    }

    private static func trackID(inTKHD tkhd: Box, data: Data) -> UInt32? {
        guard tkhd.payload.count >= 1 else { return nil }
        let version = data[tkhd.payload.lowerBound]
        let offset: Int
        switch version {
        case 0: offset = 12
        case 1: offset = 20
        default: return nil
        }
        let start = tkhd.payload.lowerBound + offset
        guard start + 4 <= tkhd.payload.upperBound else { return nil }
        let value = be32(data, start)
        return value == 0 ? nil : value
    }

    private static func timescale(inFullHeader box: Box, data: Data) -> UInt32? {
        guard box.payload.count >= 1 else { return nil }
        let offset: Int
        switch data[box.payload.lowerBound] {
        case 0: offset = 12
        case 1: offset = 20
        default: return nil
        }
        let start = box.payload.lowerBound + offset
        guard start + 4 <= box.payload.upperBound else { return nil }
        let value = be32(data, start)
        return value == 0 ? nil : value
    }

    private static func leadingEmptyEditDuration(in edts: Box, data: Data) -> UInt64? {
        guard let children = boxes(in: data, range: edts.payload),
              children.count == 1,
              let elst = children.first,
              elst.type == "elst",
              elst.payload.count >= 8 else { return nil }
        let version = data[elst.payload.lowerBound]
        let entryCount = be32(data, elst.payload.lowerBound + 4)
        guard entryCount > 0 else { return nil }
        let first = elst.payload.lowerBound + 8
        switch version {
        case 0:
            guard first + 12 <= elst.payload.upperBound else { return nil }
            return be32(data, first + 4) == UInt32.max ? UInt64(be32(data, first)) : 0
        case 1:
            guard first + 20 <= elst.payload.upperBound else { return nil }
            return be64(data, first + 8) == UInt64.max ? be64(data, first) : 0
        default:
            return nil
        }
    }

    private static func firstBaseDecodeTime(in data: Data, trackID: UInt32) -> UInt64? {
        guard let top = boxes(in: data, range: data.startIndex..<data.endIndex),
              let moof = top.first(where: { $0.type == "moof" }),
              let children = boxes(in: data, range: moof.payload) else { return nil }
        var resolved: UInt64?
        for traf in children where traf.type == "traf" {
            guard let trafChildren = boxes(in: data, range: traf.payload),
                  let tfhdBox = trafChildren.first(where: { $0.type == "tfhd" }),
                  let tfhd = trackFragmentHeader(in: tfhdBox, data: data) else { return nil }
            guard tfhd.trackID == trackID else { continue }
            guard resolved == nil,
                  let tfdt = trafChildren.first(where: { $0.type == "tfdt" }),
                  tfdt.payload.count >= 1 else { return nil }
            let start = tfdt.payload.lowerBound + 4
            switch data[tfdt.payload.lowerBound] {
            case 0:
                guard tfdt.payload.count == 8 else { return nil }
                resolved = UInt64(be32(data, start))
            case 1:
                guard tfdt.payload.count == 12 else { return nil }
                resolved = be64(data, start)
            default:
                return nil
            }
        }
        return resolved
    }

    private static func fragmentSummary(in data: Data,
                                        moof: Box,
                                        trackID: UInt32) -> FragmentSummary? {
        guard let children = boxes(in: data, range: moof.payload) else { return nil }
        var matched: FragmentSummary?
        for traf in children where traf.type == "traf" {
            guard let trafChildren = boxes(in: data, range: traf.payload),
                  let tfhdBox = trafChildren.first(where: { $0.type == "tfhd" }),
                  let tfhd = trackFragmentHeader(in: tfhdBox, data: data) else { return nil }
            guard tfhd.trackID == trackID else { continue }
            guard matched == nil else { return nil }
            var totalSamples = 0
            var firstFlags: UInt32?
            var firstSize: Int?
            var firstDataOffset: Int32?
            for trun in trafChildren where trun.type == "trun" {
                guard let run = trackRunSummary(
                    in: trun,
                    data: data,
                    defaultSampleSize: tfhd.defaultSampleSize,
                    defaultSampleFlags: tfhd.defaultSampleFlags) else { return nil }
                if totalSamples == 0, run.sampleCount > 0 {
                    firstFlags = run.firstSampleFlags
                    firstSize = run.firstSampleSize
                    firstDataOffset = run.dataOffset
                }
                let (next, overflow) = totalSamples.addingReportingOverflow(run.sampleCount)
                guard !overflow else { return nil }
                totalSamples = next
            }
            guard totalSamples > 0,
                  tfhd.defaultBaseIsMoof,
                  let firstSize, firstSize > 0,
                  let firstDataOffset else { return nil }
            let (sampleStart, startOverflow) = moof.start.addingReportingOverflow(Int(firstDataOffset))
            guard !startOverflow, sampleStart >= data.startIndex else { return nil }
            let (sampleEnd, endOverflow) = sampleStart.addingReportingOverflow(firstSize)
            guard !endOverflow, sampleEnd <= data.endIndex else { return nil }
            matched = FragmentSummary(
                sampleCount: totalSamples,
                firstSampleIsSync: firstFlags.map { ($0 & 0x0001_0000) == 0 },
                firstSampleRange: sampleStart..<sampleEnd)
        }
        return matched
    }

    private static func trackFragmentHeader(in box: Box, data: Data) -> TrackFragmentHeader? {
        guard box.payload.count >= 8 else { return nil }
        let flags = be32(data, box.payload.lowerBound) & 0x00ff_ffff
        let trackID = be32(data, box.payload.lowerBound + 4)
        guard trackID != 0 else { return nil }
        var cursor = box.payload.lowerBound + 8
        if flags & 0x000001 != 0 { cursor += 8 }
        if flags & 0x000002 != 0 { cursor += 4 }
        if flags & 0x000008 != 0 { cursor += 4 }
        var defaultSize: Int?
        if flags & 0x000010 != 0 {
            guard cursor + 4 <= box.payload.upperBound else { return nil }
            let raw = be32(data, cursor)
            guard raw > 0, UInt64(raw) <= UInt64(Int.max) else { return nil }
            defaultSize = Int(raw)
            cursor += 4
        }
        var defaultFlags: UInt32?
        if flags & 0x000020 != 0 {
            guard cursor + 4 <= box.payload.upperBound else { return nil }
            defaultFlags = be32(data, cursor)
            cursor += 4
        }
        guard cursor == box.payload.upperBound else { return nil }
        return TrackFragmentHeader(
            trackID: trackID,
            defaultSampleSize: defaultSize,
            defaultSampleFlags: defaultFlags,
            defaultBaseIsMoof: flags & 0x020000 != 0)
    }

    private static func trackRunSummary(in box: Box,
                                        data: Data,
                                        defaultSampleSize: Int?,
                                        defaultSampleFlags: UInt32?) -> TrackRunSummary? {
        guard box.payload.count >= 8 else { return nil }
        let flags = be32(data, box.payload.lowerBound) & 0x00ff_ffff
        let rawCount = be32(data, box.payload.lowerBound + 4)
        guard UInt64(rawCount) <= UInt64(Int.max) else { return nil }
        let sampleCount = Int(rawCount)
        let hasFirstFlags = flags & 0x000004 != 0
        let hasPerSampleFlags = flags & 0x000400 != 0
        guard !(hasFirstFlags && hasPerSampleFlags) else { return nil }
        var cursor = box.payload.lowerBound + 8
        var dataOffset: Int32?
        if flags & 0x000001 != 0 {
            guard cursor + 4 <= box.payload.upperBound else { return nil }
            dataOffset = Int32(bitPattern: be32(data, cursor))
            cursor += 4
        }
        var explicitFirstFlags: UInt32?
        if hasFirstFlags {
            guard cursor + 4 <= box.payload.upperBound else { return nil }
            explicitFirstFlags = be32(data, cursor)
            cursor += 4
        }

        let fieldsPerSample = (flags & 0x000100 != 0 ? 1 : 0)
            + (flags & 0x000200 != 0 ? 1 : 0)
            + (hasPerSampleFlags ? 1 : 0)
            + (flags & 0x000800 != 0 ? 1 : 0)
        let (fieldBytes, multiplyOverflow) = sampleCount.multipliedReportingOverflow(by: fieldsPerSample * 4)
        guard !multiplyOverflow, cursor <= box.payload.upperBound,
              fieldBytes <= box.payload.upperBound - cursor else { return nil }

        var perSampleFirstFlags: UInt32?
        var perSampleFirstSize: Int?
        if sampleCount > 0, hasPerSampleFlags {
            var firstFlagsOffset = cursor
            if flags & 0x000100 != 0 { firstFlagsOffset += 4 }
            if flags & 0x000200 != 0 { firstFlagsOffset += 4 }
            guard firstFlagsOffset + 4 <= box.payload.upperBound else { return nil }
            perSampleFirstFlags = be32(data, firstFlagsOffset)
        }
        if sampleCount > 0, flags & 0x000200 != 0 {
            var firstSizeOffset = cursor
            if flags & 0x000100 != 0 { firstSizeOffset += 4 }
            guard firstSizeOffset + 4 <= box.payload.upperBound else { return nil }
            let raw = be32(data, firstSizeOffset)
            guard raw > 0, UInt64(raw) <= UInt64(Int.max) else { return nil }
            perSampleFirstSize = Int(raw)
        }
        cursor += fieldBytes
        guard cursor == box.payload.upperBound else { return nil }
        return TrackRunSummary(
            sampleCount: sampleCount,
            firstSampleFlags: explicitFirstFlags ?? perSampleFirstFlags ?? defaultSampleFlags,
            firstSampleSize: perSampleFirstSize ?? defaultSampleSize,
            dataOffset: dataOffset)
    }

    private static func boxes(in data: Data, range: Range<Data.Index>) -> [Box]? {
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard let box = box(in: data, start: cursor, limit: range.upperBound) else { return nil }
            result.append(box)
            cursor = box.end
        }
        return cursor == range.upperBound ? result : nil
    }

    private static func box(in data: Data, start: Data.Index, limit: Data.Index) -> Box? {
        guard start >= data.startIndex, limit <= data.endIndex, start <= limit,
              start + 8 <= limit else { return nil }
        let size32 = be32(data, start)
        var headerSize = 8
        let size64: UInt64
        switch size32 {
        case 0:
            return nil
        case 1:
            guard start + 16 <= limit else { return nil }
            size64 = be64(data, start + 8)
            headerSize = 16
        default:
            size64 = UInt64(size32)
        }
        guard size64 >= UInt64(headerSize), size64 <= UInt64(Int.max) else { return nil }
        let size = Int(size64)
        guard size <= limit - start else { return nil }
        let type = String(bytes: data[(start + 4)..<(start + 8)], encoding: .ascii) ?? ""
        guard type.utf8.count == 4 else { return nil }
        let end = start + size
        return Box(type: type, start: start, payload: (start + headerSize)..<end, end: end)
    }

    private static func be32(_ data: Data, _ offset: Data.Index) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func be64(_ data: Data, _ offset: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }
}

/// One source of truth for the primary A/V muxer's fragmented-MP4 options and the integration harness that
/// executes the shipped movenc binary. `frag_keyframe` is the automatic fragment trigger; `min_frag_duration`
/// is only its one-second floor. No caller sends a nil packet through `av_write_frame`, so the public write API
/// remains `av_interleaved_write_frame` end to end.
enum VortXHLSMovencPolicy {
    static let movflags = "empty_moov+default_base_moof+delay_moov+frag_keyframe"
    static let minimumFragmentDurationMicroseconds = "1000000"
}

/// The audio-only muxer has no video keyframes to trigger deterministic boundaries. Fragmenting before every
/// incoming audio sample means the first packet of the next logical segment completes the prior segment through
/// the same interleaved write API. The final sample is completed by the trailer at EOF.
enum VortXAlternateAudioMovencPolicy {
    static let movflags = "empty_moov+default_base_moof+delay_moov+frag_every_frame"
}

struct VortXHLSKeyframeIndexEvidence: Equatable, Sendable {
    enum Completeness: Equatable, Sendable {
        case incomplete
        case validatedComplete
    }

    let completeness: Completeness
    let adjacentIntervalsSeconds: [Double]
}

struct VortXHLSFrozenTarget: Equatable, Sendable {
    enum Authority: Equatable, Sendable {
        case conservativeFallback
        case validatedCompleteIndex
    }

    let seconds: Int
    let authority: Authority
}

/// Phase-aware AVPlayer buffering for remux mounts. Local production starts at the HLS publication readiness
/// window (`startupSeconds`, raised to eight seconds for high-bitrate DV readiness) so a startup cohort is never
/// declined for want of media. Remote production leaves the initial duration at zero so AVPlayer adapts to the
/// network. Both restore the field-proven 30-second device cap after the first decoded picture.
enum VortXRemuxForwardBufferPolicy {
    enum Mount: Equatable, Sendable {
        case direct
        case localRemux
        case remoteRemux
    }

    static let startupSeconds: TimeInterval = 8
    static let steadyStateSeconds: TimeInterval = 30

    static func preferredDuration(
        mount: Mount,
        hasProducedFirstFrame: Bool
    ) -> TimeInterval {
        if hasProducedFirstFrame { return steadyStateSeconds }
        switch mount {
        case .direct:
            return steadyStateSeconds
        case .localRemux:
            return startupSeconds
        case .remoteRemux:
            return 0
        }
    }

    static func automaticallyWaitsToMinimizeStalling(mount: Mount) -> Bool {
        mount != .direct
    }

    /// A memory warning may replace AVPlayer's system-selected zero value or lower an oversized explicit
    /// duration, but it must never increase an already-smaller positive buffer. Normal remote startup remains
    /// adaptive at zero; under memory pressure only, use the finite local startup floor until first frame.
    static func memoryWarningReplacementDuration(
        currentDuration: TimeInterval,
        mount: Mount,
        hasProducedFirstFrame: Bool
    ) -> TimeInterval? {
        let phaseCap = preferredDuration(
            mount: mount,
            hasProducedFirstFrame: hasProducedFirstFrame)
        let cap = mount == .remoteRemux && !hasProducedFirstFrame
            ? startupSeconds : phaseCap
        if currentDuration.isFinite, currentDuration == cap { return nil }
        guard !currentDuration.isFinite || currentDuration <= 0 || currentDuration > cap else {
            return nil
        }
        return cap
    }
}

struct VortXHLSStartupReadiness: Equatable, Sendable {
    let frozenTarget: VortXHLSFrozenTarget
    let minimumSegmentCount: Int
    let minimumRenderedDurationMilliseconds: Int

    /// Startup floor: ONE independently decodable segment and TWELVE seconds of rendered media. This is a flat
    /// wall-clock budget, not a multiple of the frozen target. A short segment still requires enough following
    /// segments to reach the floor; a single complete segment that already covers it can be served immediately.
    ///
    /// WHY THE FLOOR MUST EXCEED THE WINDOW (Beta 13 seek-latency diagnosis, resized by Beta 26). In Beta 13 the
    /// floor sat EXACTLY on AVPlayer's readiness window, so the startup cohort advertised ~4.01s of media against
    /// a ~4.0s window, i.e. ten milliseconds of margin, and CoreMedia declined readiness; the retry then waited a
    /// playlist reload interval derived from our own conservative EXT-X-TARGETDURATION of 12, spending 6.2 seconds
    /// of a 12.9-second remount re-asking a question a fraction of a second more media would have answered first
    /// time. Sizing the floor off the readiness window rather than a bare literal keeps the two from drifting
    /// apart again: the floor is the window + 50% (`startupSeconds * 1.5`), capped at twelve seconds so it can
    /// never creep back toward the build 189 regression below. Beta 26 raised the local-remux startup window from
    /// four to eight seconds (`startupSeconds`) so a high-bitrate DV mount does not stall right after it starts;
    /// following the same +50% rule raises this floor to twelve seconds, adding ~4s of media before the master
    /// publishes (the "startup buffer 4s->8s" trade: a slightly later first frame in exchange for a robust
    /// startup), a published window the spool ceiling still bounds exactly as before.
    ///
    /// The build 189 field regression: the floor was
    /// 6 segments AND 3x the conservative 12s target (36 SECONDS of media), so a UHD DV mount held its master
    /// until ~380 MB had been produced - 12-15s on a fast debrid link - while the chrome's start watchdog
    /// demotes at 10s. Every DV title "hung ~10s then fell to HDR10". The same floor sized the live window
    /// (36 segments), whose RFC 8216 retention arithmetic (segment + longest-playlist duration) then pushed
    /// resident spool bytes past the 512 MiB admission ceiling ~25s in and killed the healthy remux mid-play.
    /// Build 187 shipped a TWO-segment startup window for months (field-proven on the same device/player);
    /// EXT-X-START:TIME-OFFSET=0,PRECISE=YES pins the start point, so the 3-target live-edge heuristic of
    /// RFC 8216 6.3.3 does not apply to this server's fixed-offset startup.
    static let startupFloorMilliseconds = min(
        12_000,
        Int(VortXRemuxForwardBufferPolicy.startupSeconds * 1_500))   // readiness window + 50%, capped at 12s

    /// Before AVPlayer has fetched any media, advertise a base cap of two segments. The actual cap below also
    /// carries one already-produced successor beyond the master-frozen cohort. That successor is bounded growth
    /// evidence for CoreMedia's readiness negotiation, while the rest of a producer-ahead tail remains hidden.
    /// The first segment fetch becomes the consumption receipt that lets normal rolling publication grow.
    var maximumUnconsumedSegmentCount: Int { max(2, minimumSegmentCount) }

    func unconsumedStartupWindow(
        _ window: VortXHLSWindow,
        startupCohortCount: Int
    ) -> VortXHLSWindow {
        let cohortWithSuccessor = startupCohortCount == Int.max
            ? Int.max : startupCohortCount + 1
        let maximumCount = max(maximumUnconsumedSegmentCount, cohortWithSuccessor)
        guard window.segments.count > maximumCount else { return window }
        return VortXHLSWindow(
            segments: Array(window.segments.prefix(maximumCount)))
    }

    init?(frozenTarget: VortXHLSFrozenTarget, minimumSegmentCount: Int = 1) {
        guard frozenTarget.seconds >= VortXHLSTargetPolicy.minimumSeconds,
              frozenTarget.seconds <= VortXHLSTargetPolicy.conservativeSeconds,
              minimumSegmentCount > 0 else { return nil }
        self.frozenTarget = frozenTarget
        self.minimumSegmentCount = minimumSegmentCount
        self.minimumRenderedDurationMilliseconds = Self.startupFloorMilliseconds
    }
}

/// Session target authority. FFmpeg indexes and container cues are not completeness proof, so current
/// production passes no evidence and freezes the conservative value once for the entire mount.
///
/// WHY THE WRITTEN EXT-X-TARGETDURATION STAYS AT THE CONSERVATIVE 12 (Beta 13 evaluation). A lower target
/// would shorten the client's playlist reload interval, which is what made a declined startup readiness cost
/// 6.2 seconds, and RFC 8216 does permit any value at or above every segment's duration. It is still not safe
/// to write "the true ceiling" here, for two independent reasons:
///   1. The value MUST NOT change once a playlist is published (RFC 8216 6.2.1), so it has to bound EVERY
///      FUTURE segment, not the ones produced so far. Segments are cut at the first keyframe past one second
///      (`VortXMKVRemuxStream.hlsTargetSegmentSecs`), so their real ceiling is the SOURCE's keyframe interval,
///      which is not known at freeze time and is routinely several seconds on a sparse-GOP encode.
///   2. In this server the frozen target is also the per-segment ACCEPTANCE ceiling
///      (`VortXRemuxHLSServer.windowConformsToFrozenTarget` -> `accepts`). Lowering it would make any later
///      longer segment fail publication and demote a healthy mid-play session to libmpv HDR10, which is
///      exactly the fail-closed class of regression build 189 shipped.
/// The safe lever is `freeze(indexEvidence:)` below, which already lowers the target to the measured maximum
/// keyframe interval when a VALIDATED-COMPLETE index proves that ceiling; production supplies no such evidence
/// today. So the startup cost is removed on the other side of the trade, by publishing a cohort with real
/// margin (see `VortXHLSStartupReadiness.startupFloorMilliseconds`) instead of relying on a fast retry.
enum VortXHLSTargetPolicy {
    static let minimumSeconds = 5
    static let conservativeSeconds = 12
    static let conservativeTarget = VortXHLSFrozenTarget(
        seconds: conservativeSeconds,
        authority: .conservativeFallback)

    static func freeze(indexEvidence: VortXHLSKeyframeIndexEvidence?) -> VortXHLSFrozenTarget? {
        guard let indexEvidence,
              indexEvidence.completeness == .validatedComplete,
              !indexEvidence.adjacentIntervalsSeconds.isEmpty else {
            return conservativeTarget
        }
        var maximum = 0.0
        for interval in indexEvidence.adjacentIntervalsSeconds {
            guard interval.isFinite, interval > 0, interval <= Double(conservativeSeconds) else {
                return nil
            }
            maximum = max(maximum, interval)
        }
        let rounded = Int(ceil(maximum))
        guard rounded <= conservativeSeconds else { return nil }
        return VortXHLSFrozenTarget(
            seconds: max(minimumSeconds, rounded),
            authority: .validatedCompleteIndex)
    }

    static func accepts(intervalSeconds: Double, frozenTargetSeconds: Int) -> Bool {
        intervalSeconds.isFinite
            && intervalSeconds > 0
            && frozenTargetSeconds >= minimumSeconds
            && frozenTargetSeconds <= conservativeSeconds
            && intervalSeconds <= Double(frozenTargetSeconds)
    }
}

/// Pure monotonic state machine for the one mount-to-ready deadline. Production supplies system uptime; tests
/// supply exact timestamps so sequential waits, the exact expiry edge, and ready/timeout races are executable.
struct VortXHLSMountDeadlineState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case running(deadline: TimeInterval)
        case ready
        case timedOut
        case cancelled
    }

    static let productionDuration: TimeInterval = 30
    private(set) var phase: Phase = .idle

    mutating func start(now: TimeInterval,
                        duration: TimeInterval = productionDuration) -> TimeInterval? {
        guard case .idle = phase,
              now.isFinite, duration.isFinite, duration > 0 else { return nil }
        let deadline = now + duration
        guard deadline.isFinite else { return nil }
        phase = .running(deadline: deadline)
        return deadline
    }

    /// Remaining shared wall budget. Returning zero transitions the state exactly once at `now >= deadline`.
    mutating func remaining(now: TimeInterval) -> (seconds: TimeInterval, didExpire: Bool) {
        guard now.isFinite else {
            let didExpire = phase != .timedOut
            phase = .timedOut
            return (0, didExpire)
        }
        switch phase {
        case .running(let deadline):
            guard now < deadline else {
                phase = .timedOut
                return (0, true)
            }
            return (deadline - now, false)
        case .idle, .timedOut, .cancelled:
            return (0, false)
        case .ready:
            return (.infinity, false)
        }
    }

    /// Ready wins only strictly before the deadline. `didExpire` tells the owner to run the one terminal edge.
    mutating func markReady(now: TimeInterval) -> (accepted: Bool, didExpire: Bool) {
        let budget = remaining(now: now)
        guard budget.seconds > 0, case .running = phase else {
            return (false, budget.didExpire)
        }
        phase = .ready
        return (true, false)
    }

    /// Rechecks a successful probe at its completion edge. A probe that began in budget cannot escape after
    /// the deadline, while a server already in `.ready` keeps accepting later master reloads.
    mutating func gateSuccessfulProbe<Value>(
        _ value: Value,
        completedAt now: TimeInterval,
        invalidated: Bool
    ) -> (value: Value?, didExpire: Bool) {
        guard !invalidated else { return (nil, false) }
        let budget = remaining(now: now)
        guard budget.seconds > 0 else { return (nil, budget.didExpire) }
        return (value, false)
    }

    mutating func cancel() {
        switch phase {
        case .idle, .running:
            phase = .cancelled
        case .ready, .timedOut, .cancelled:
            break
        }
    }
}

/// Legal video segmentation decision shared by the FFmpeg owner and the standalone mutation harness. Every
/// segment opens on the incoming packet, so segment zero and every cut packet must be IDR. A segment remains
/// legal through the exact frozen target and fails soft only after the newest logical interval exceeds it.
enum VortXHLSBoundaryPolicy {
    enum Decision: Equatable, Sendable {
        case open
        case continueOpen
        case cut
        case failSoft
    }

    static func decision(hasOpenSegment: Bool,
                         incomingIsIDR: Bool,
                         incomingHasKeyFlag: Bool,
                         elapsed: Double,
                         targetSeconds: Double = 1,
                         frozenTargetSeconds: Double = 12) -> Decision {
        guard elapsed.isFinite, elapsed >= 0,
              targetSeconds.isFinite, targetSeconds > 0,
              frozenTargetSeconds.isFinite,
              frozenTargetSeconds >= targetSeconds,
              frozenTargetSeconds <= Double(VortXHLSTargetPolicy.conservativeSeconds) else {
            return .failSoft
        }
        let hasConfirmedStart = incomingIsIDR && incomingHasKeyFlag
        guard hasOpenSegment else { return hasConfirmedStart ? .open : .failSoft }
        guard elapsed <= frozenTargetSeconds else { return .failSoft }
        if hasConfirmedStart, elapsed >= targetSeconds { return .cut }
        return .continueOpen
    }

    static func timestampSeconds(dts: Int64?,
                                 pts: Int64?,
                                 timeBaseNumerator: Int32,
                                 timeBaseDenominator: Int32) -> Double? {
        guard let timestamp = dts ?? pts,
              timeBaseNumerator > 0,
              timeBaseDenominator > 0 else { return nil }
        let seconds = Double(timestamp) * Double(timeBaseNumerator) / Double(timeBaseDenominator)
        return seconds.isFinite ? seconds : nil
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

/// FIFO ownership for video boundaries that movenc has accepted but the HLS publisher cannot consume yet.
/// Delayed init and interleaver latency are independent, so a confirmed boundary remains queued until both the
/// init and a parser-complete media fragment exist. The queue tail is the logical start of the newest open
/// segment, which lets later confirmed keys retain their own boundary without replacing an older one.
final class VortXHLSPendingPublicationMachine<Payload> {
    struct Entry {
        let segmentID: Int
        let startSeconds: Double
        let endSeconds: Double
        var payload: Payload
    }

    enum Failure: Equatable, Sendable {
        case drainFailed
        case publishFailed
        case incompleteAfterDrain
        case incompleteAtEnd
    }

    enum AdvanceResult: Equatable, Sendable {
        case settled
        case waitingForInit
        case waitingForFragment
        case failed(Failure)
    }

    private var storage: [Entry] = []

    var count: Int { storage.count }
    var hasPendingBoundary: Bool { !storage.isEmpty }
    var first: Entry? { storage.first }
    var logicalSegmentStartSeconds: Double? { storage.last?.endSeconds }

    func append(segmentID: Int,
                startSeconds: Double,
                endSeconds: Double,
                payload: Payload) -> Bool {
        guard segmentID >= 0,
              startSeconds.isFinite,
              endSeconds.isFinite,
              endSeconds > startSeconds else { return false }
        if let last = storage.last {
            guard segmentID == last.segmentID + 1,
                  startSeconds == last.endSeconds else { return false }
        }
        storage.append(Entry(
            segmentID: segmentID,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            payload: payload))
        return true
    }

    func attachPayload(_ payload: Payload, toSegmentID segmentID: Int) -> Bool {
        guard let index = storage.firstIndex(where: { $0.segmentID == segmentID }) else { return false }
        storage[index].payload = payload
        return true
    }

    /// Runs the complete pending-publication transition against caller-owned side effects. The machine asks for
    /// at most one post-init interleave drain, never asks before init, and removes an entry only after a concrete
    /// parser proof has been accepted by the publication closure.
    func advance<FragmentProof>(
        initMayPublishMedia: () -> Bool,
        allowPostInitDrain: Bool = true,
        incompleteIsTerminal: Bool = false,
        proveNextFragment: () -> FragmentProof?,
        performPostInitDrain: () -> Bool,
        publish: (Entry, FragmentProof) -> Bool) -> AdvanceResult {
        var performedPostInitDrain = false
        var publishedInThisAdvance = false
        while let pending = storage.first {
            guard initMayPublishMedia() else { return .waitingForInit }
            if let proof = proveNextFragment() {
                guard publish(pending, proof) else { return .failed(.publishFailed) }
                storage.removeFirst()
                publishedInThisAdvance = true
                continue
            }
            guard allowPostInitDrain else {
                return incompleteIsTerminal ? .failed(.incompleteAtEnd) : .waitingForFragment
            }
            guard !performedPostInitDrain else {
                // A complete head can publish either before or after the one drain while a later, already-bounded
                // fragment still needs another ordinary packet or EOF trailer. Retain that next FIFO head after
                // concrete progress in this advance; only an advance that proves nothing is terminal malformed
                // output.
                return publishedInThisAdvance ? .waitingForFragment : .failed(.incompleteAfterDrain)
            }
            guard performPostInitDrain() else { return .failed(.drainFailed) }
            performedPostInitDrain = true
        }
        return .settled
    }
}
