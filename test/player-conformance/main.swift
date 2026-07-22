import Foundation

// =============================================================================
// player-conformance - acceptance harness for the player rework.
//
// Subcommands:
//   selftest                         Validate the oracle (cohort boundary cases,
//                                     EXTINF integer-ms parsing, fMP4 sync parser,
//                                     server-faithful build/parse round trip).
//   trace <log> [--index N] [--only-point7]
//                                     Evaluate a captured production trace.
//   fixture-assert <normal> <timeout> Assert only fixture-observable facts.
//   live  --container <dir>          Full battery over loopback + filesystem while
//         [--port N] [--log <file>]  a plain-remux playback is LIVE.
//   spool --container <dir> [--expect-active|--expect-empty]
//
// Exit code for trace/live is the GATE: 0 only when every point is GREEN/EXEMPT.
// Against current beta it is non-zero (points are RED); it turns 0 when the rework
// is correct. selftest exits 0 only when the oracle's own checks all pass.
// =============================================================================

let useColor = isatty(fileno(stdout)) != 0
func paint(_ s: String, _ code: String) -> String { useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func colorFor(_ v: Verdict) -> String {
    switch v {
    case .green: return "32"; case .red: return "31"
    case .exempt: return "36"; case .indeterminate: return "33"; case .pending: return "35"
    }
}

func report(_ title: String, _ findings: [Finding]) -> Bool {
    print("")
    print(paint("== \(title) ==", "1"))
    var accept = !findings.isEmpty
    for p in Point.allCases {
        guard let f = findings.first(where: { $0.point == p }) else { continue }
        if !f.verdict.acceptable { accept = false }
        let tag = paint(f.verdict.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0), colorFor(f.verdict))
        print("[\(tag)] (\(p.rawValue)) \(p.title)")
        for e in f.evidence { print("               - \(e)") }
    }
    print("")
    print(accept ? paint("GATE: PASS (all points GREEN/EXEMPT)", "1;32")
                 : paint("GATE: FAIL (not every point is GREEN/EXEMPT)", "1;31"))
    return accept
}

private final class URLProtocolScript: @unchecked Sendable {
    typealias Handler = @Sendable (HarnessURLProtocol) -> Void
    private let lock = NSLock()
    private var handler: Handler?

    func install(_ value: @escaping Handler) {
        lock.lock()
        handler = value
        lock.unlock()
    }

    func run(_ request: HarnessURLProtocol) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(request)
    }
}

private final class HarnessURLProtocol: URLProtocol, @unchecked Sendable {
    static let script = URLProtocolScript()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.script.run(self) }
    override func stopLoading() {}
}

private func protocolResponse(_ request: URLRequest, status: Int, length: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(length)]
    )!
}

// MARK: - selftest

enum HarnessMutation: String {
    case startupReadinessOr = "startup-readiness-or"
}

func runSelfTest(
    mutation: FMP4.Mutation? = nil,
    harnessMutation: HarnessMutation? = nil
) -> Bool {
    var checks: [(String, Bool)] = []
    func expect(_ name: String, _ cond: Bool) { checks.append((name, cond)) }

    // Cohort boundary cases, built through the REAL server format and measured as
    // integer ms from the resulting EXTINF text.
    func cohort(_ durs: [Double], ended: Bool = false) -> (Int, Int, Bool) {
        let body = Playlist.buildMediaBodyLikeServer(durations: durs, ended: ended)
        let p = Playlist.parseMedia(body)
        let ready = harnessMutation == .startupReadinessOr
            ? (p.count >= Contract.minStartupSegments || p.totalMs >= Contract.minStartupMs)
            : Playlist.cohortReady(count: p.count, totalMs: p.totalMs)
        return (p.count, p.totalMs, ready)
    }
    let productionReadiness = VortXHLSStartupReadiness(
        frozenTarget: VortXHLSTargetPolicy.conservativeTarget)
    expect("contract target mirrors production conservative target 12",
           Contract.hlsTargetDuration == 12
               && VortXHLSTargetPolicy.conservativeSeconds == Contract.hlsTargetDuration)
    expect("contract startup floors mirror production 6 segments and 36000 ms",
           productionReadiness?.minimumSegmentCount == Contract.minStartupSegments
               && productionReadiness?.minimumRenderedDurationMilliseconds == Contract.minStartupMs)

    func productionStartup(_ durations: [Double], ended: Bool = false) -> DVPlaybackPolicy.StartupMediaSnapshot? {
        let segments = durations.enumerated().map {
            VortXHLSSegment(id: $0.offset, byteOffset: 0, byteLength: 1, duration: $0.element)
        }
        return DVPlaybackPolicy.pinnedStartupSnapshot(
            window: VortXHLSWindow(segments: segments),
            ended: ended,
            minimumSegmentCount: Contract.minStartupSegments,
            minimumRenderedDurationMilliseconds: Contract.minStartupMs)
    }

    let a = cohort(Array(repeating: 8.000, count: 5))
    expect("5 segments stay CLOSED even above 36000 ms", a == (5, 40000, false))
    let b = cohort([6.000, 6.000, 6.000, 6.000, 6.000, 5.999])
    expect("6 segments at 35999 ms stay CLOSED by 1 ms", b == (6, 35999, false))
    let c = cohort(Array(repeating: 6.000, count: 6))
    expect("6 segments at exactly 36000 ms OPEN", c == (6, 36000, true))
    expect("production gate rejects 5 segments even above 36000 ms",
           productionStartup(Array(repeating: 8.000, count: 5)) == nil)
    expect("production gate rejects the 35999 ms boundary",
           productionStartup([6.000, 6.000, 6.000, 6.000, 6.000, 5.999]) == nil)
    expect("production gate accepts exactly 6 segments and 36000 rendered ms",
           productionStartup(Array(repeating: 6.000, count: 6))?.window.segments.count == 6)
    expect("ended short source is explicitly exempt",
           Playlist.startupDisposition(count: 1, totalMs: 1_000, ended: true) == .endedExempt
               && productionStartup([1.000], ended: true)?.ended == true)
    expect("same short non-ended source remains closed",
           Playlist.startupDisposition(count: 1, totalMs: 1_000, ended: false) == .notReady
               && productionStartup([1.000], ended: false) == nil)

    expect("production wall deadline mirrors the separate 30000 ms contract",
           Int(VortXHLSMountDeadlineState.productionDuration * 1_000) == Contract.sloMountToReadyMs)
    var beforeEdge = VortXHLSMountDeadlineState()
    expect("monotonic wall deadline starts once and cannot be reset",
           beforeEdge.start(now: 100) == 130 && beforeEdge.start(now: 101) == nil)
    expect("ready strictly before the wall edge wins",
           beforeEdge.markReady(now: 129.999).accepted)
    var atEdge = VortXHLSMountDeadlineState()
    _ = atEdge.start(now: 100)
    let exactEdge = atEdge.markReady(now: 130)
    expect("ready exactly at the wall edge loses and expires once",
           !exactEdge.accepted && exactEdge.didExpire && atEdge.phase == .timedOut)

    // EXTINF text -> integer ms, no float.
    expect("EXTINF 4.000 -> 4000 ms", Playlist.msFromExtinf("#EXTINF:4.000,") == 4000)
    expect("EXTINF 35.999 -> 35999 ms", Playlist.msFromExtinf("#EXTINF:35.999,") == 35999)
    expect("EXTINF 36.000 -> 36000 ms", Playlist.msFromExtinf("#EXTINF:36.000,") == 36000)
    expect("EXTINF 36 -> 36000 ms", Playlist.msFromExtinf("#EXTINF:36,") == 36000)
    expect("EXTINF 1.5 -> 1500 ms", Playlist.msFromExtinf("#EXTINF:1.5,") == 1500)

    // The real DVPlaybackPolicy header is compiled in and used by the builder.
    let body = Playlist.buildMediaBodyLikeServer(
        durations: Array(repeating: 6.0, count: 6), ended: false, startID: 8)
    expect("builder emits frozen TARGETDURATION 12", body.contains("#EXT-X-TARGETDURATION:12"))
    expect("sliding builder omits zero-only EXT-X-START", !body.contains("#EXT-X-START:"))
    expect("builder emits EXT-X-MAP init.mp4", body.contains("#EXT-X-MAP:URI=\"init.mp4\""))
    let rp = Playlist.parseMedia(body)
    expect("sliding round-trip uses seq as first absolute id and segs as cardinality",
           rp.mediaSequence == 8 && rp.count == 6 && rp.advertisedRange == 8..<14
               && rp.segments.map(\.id) == Array(8..<14) && rp.isValidAdvertisedWindow)
    expect("sliding playlist never declares EVENT", !rp.hasPlaylistTypeEvent)
    let mismatchedIDs = Playlist.parseMedia(body.replacingOccurrences(of: "seg8.m4s", with: "seg7.m4s"))
    expect("URI id must equal seq plus its cardinal offset", !mismatchedIDs.isValidAdvertisedWindow)
    let overflowingRange = Playlist.parseMedia("""
    #EXTM3U
    #EXT-X-TARGETDURATION:12
    #EXT-X-MEDIA-SEQUENCE:\(Int.max)
    #EXTINF:6.000,
    seg\(Int.max).m4s
    """)
    expect("advertised [seq, seq+segs) overflow fails closed",
           overflowingRange.advertisedRange == nil && !overflowingRange.isValidAdvertisedWindow)

    let audioBody = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:12
    #EXT-X-MEDIA-SEQUENCE:8
    #EXT-X-MAP:URI="audio0-init.mp4"
    #EXTINF:6.000,
    audio0-seg8.m4s
    #EXTINF:6.000,
    audio0-seg9.m4s
    """
    let audioParsed = Playlist.parseMedia(audioBody)
    expect("exact audio<ID>-seg<ID>.m4s grammar parses absolute ids",
           audioParsed.isValidAdvertisedWindow
               && audioParsed.segments.map(\.uri) == ["audio0-seg8.m4s", "audio0-seg9.m4s"])
    expect("retired aseg alias is rejected",
           Playlist.segmentIdentity(fromURI: "aseg0.m4s") == nil)
    expect("segment URI queries and paths are rejected",
           Playlist.segmentIdentity(fromURI: "seg0.m4s?token=1") == nil
               && Playlist.segmentIdentity(fromURI: "nested/seg0.m4s") == nil)
    let duplicateMap = Playlist.parseMedia(body.replacingOccurrences(
        of: "#EXT-X-MAP:URI=\"init.mp4\"",
        with: "#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-MAP:URI=\"init.mp4\""))
    expect("duplicate EXT-X-MAP fails closed", !duplicateMap.isValidAdvertisedWindow)
    let validMaster = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="eng",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Spanish",LANGUAGE="spa",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio0.m3u8"
    """
    expect("master requires one in-band primary and one exact alternate playlist URI",
           Live.audioRenditionURI(validMaster) == "audio0.m3u8")
    expect("master rejects an alternate with the primary language",
           Live.audioRenditionURI(validMaster.replacingOccurrences(of: "LANGUAGE=\"spa\"", with: "LANGUAGE=\"eng\"")) == nil)
    expect("master rejects unknown-language topology",
           Live.audioRenditionURI(validMaster.replacingOccurrences(of: "LANGUAGE=\"spa\"", with: "LANGUAGE=\"und\"")) == nil)

    var timeout = TraceSession()
    timeout.masterRequestOrdinals = [0]
    timeout.master404Ordinals = [2]
    timeout.timeoutEventOrdinals = [1]
    timeout.timeoutEvents = [.init(
        ordinal: 1, waitedMs: 30_000, requiredCount: 6, requiredDurationMs: 36_000,
        actualCount: 1, actualDurationMs: 6_000)]
    expect("point7 accepts exactly one current event then /master 404 and no ready",
           Trace.failSoftTimeoutFinding(timeout).verdict == .green)
    var wrongPath = timeout
    wrongPath.master404Ordinals = []
    wrongPath.advertisedFailures = ["/seg0.m4s"]
    expect("point7 rejects a media-segment 404 in place of /master 404",
           Trace.failSoftTimeoutFinding(wrongPath).verdict == .red)
    var duplicate = timeout
    duplicate.timeoutEvents.append(.init(
        ordinal: 2, waitedMs: 30_000, requiredCount: 6, requiredDurationMs: 36_000,
        actualCount: 1, actualDurationMs: 6_000))
    expect("point7 rejects duplicate timeout events",
           Trace.failSoftTimeoutFinding(duplicate).verdict == .red)
    var malformedDuplicate = timeout
    malformedDuplicate.timeoutEventOrdinals.append(3)
    expect("point7 rejects an extra malformed timeout marker",
           Trace.failSoftTimeoutFinding(malformedDuplicate).verdict == .red)
    var lateMasterRequest = timeout
    lateMasterRequest.masterRequestOrdinals = [2]
    expect("point7 requires the startup master request before the event",
           Trace.failSoftTimeoutFinding(lateMasterRequest).verdict == .red)
    var staleFields = timeout
    staleFields.timeoutEvents = [.init(
        ordinal: 1, waitedMs: 30_000, requiredCount: 6, requiredDurationMs: 15_000,
        actualCount: 1, actualDurationMs: 6_000)]
    expect("point7 rejects stale event fields",
           Trace.failSoftTimeoutFinding(staleFields).verdict == .red)
    var reachedReady = timeout
    reachedReady.readyAt = Date()
    expect("point7 rejects readyToPlay on the timeout path",
           Trace.failSoftTimeoutFinding(reachedReady).verdict == .red)

    expect("512 MiB exact admission boundary is accepted",
           SpoolLayout.withinAdmissionCeiling(512 * 1024 * 1024))
    expect("512 MiB plus one byte is rejected",
           !SpoolLayout.withinAdmissionCeiling(512 * 1024 * 1024 + 1))

    let layoutRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-conformance-layout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: layoutRoot) }
    let sessionDirectory = layoutRoot.appendingPathComponent(
        "Library/Caches/VortXHLS/launch-A/session-A", isDirectory: true)
    try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    try? Data([0x01]).write(to: sessionDirectory.appendingPathComponent("video-0.m4s"))
    let oneSession = SpoolLayout.inspect(containerPath: layoutRoot.path)
    expect("whole-root discovery accepts exactly one launch and session",
           oneSession.hasOneActiveLaunchAndSession && oneSession.bytes == 1)
    let secondSession = layoutRoot.appendingPathComponent(
        "Library/Caches/VortXHLS/launch-B/session-B", isDirectory: true)
    try? FileManager.default.createDirectory(at: secondSession, withIntermediateDirectories: true)
    expect("whole-root discovery rejects multiple active launches",
           !SpoolLayout.inspect(containerPath: layoutRoot.path).hasOneActiveLaunchAndSession)
    try? FileManager.default.removeItem(at: secondSession.deletingLastPathComponent())
    let siblingSession = sessionDirectory.deletingLastPathComponent()
        .appendingPathComponent("session-B", isDirectory: true)
    try? FileManager.default.createDirectory(at: siblingSession, withIntermediateDirectories: true)
    expect("whole-root discovery rejects multiple active sessions in one launch",
           !SpoolLayout.inspect(containerPath: layoutRoot.path).hasOneActiveLaunchAndSession)

    var edge = TraceSession()
    edge.mountAt = Date(timeIntervalSince1970: 0)
    edge.readyAt = Date(timeIntervalSince1970: 30)
    let edgeFinding = Trace.findings(edge).first { $0.point == .startupLatency }
    expect("ready exactly at 30000 ms loses the strict monotonic edge",
           edgeFinding?.verdict == .red)
    var reversed = TraceSession()
    reversed.mountAt = Date(timeIntervalSince1970: 30)
    reversed.readyAt = Date(timeIntervalSince1970: 0)
    let reversedFinding = Trace.findings(reversed).first { $0.point == .startupLatency }
    expect("ready timestamp before mount fails closed",
           reversedFinding?.verdict == .red)

    // fMP4 first-video-sample parser. These are complete ffmpeg-produced fragmented
    // MP4 fixtures, stored as base64 so the repository does not carry opaque binary
    // blobs. The AVC file is video-first; the HEVC file is audio-first. Both init
    // segments carry real tkhd/hdlr/stsd codec configuration, and both first media
    // fragments carry two traf boxes plus real encoded IDR access units.
    let avc = FMP4Fixtures.load("avc-video-first")
    let hevc = FMP4Fixtures.load("hevc-audio-first")
    expect("real AVC video-first init fixture loads", avc != nil)
    expect("real HEVC audio-first init fixture loads", hevc != nil)

    if let avc, let hevc {
        let avcTrack = FMP4.videoTrack(inInit: avc.initSegment, mutation: mutation)
        let hevcTrack = FMP4.videoTrack(inInit: hevc.initSegment, mutation: mutation)
        expect("AVC init resolves vide track_ID 1 and 4-byte NAL lengths",
               avcTrack == FMP4.VideoTrack(id: 1, codec: .avc(nalLengthBytes: 4)))
        expect("HEVC init resolves vide track_ID 2 and 4-byte NAL lengths",
               hevcTrack == FMP4.VideoTrack(id: 2, codec: .hevc(nalLengthBytes: 4)))

        expect("video-first fragment really orders video traf before audio traf",
               FMP4.trafTrackIDs(in: avc.firstFragment) == [1, 2])
        expect("audio-first fragment really orders audio traf before video traf",
               FMP4.trafTrackIDs(in: hevc.firstFragment) == [1, 2])

        let avcEvidence = FMP4.firstVideoSampleEvidence(
            avc.firstFragment,
            videoTrackID: avcTrack?.id,
            codec: avcTrack?.codec,
            mutation: mutation
        )
        let hevcEvidence = FMP4.firstVideoSampleEvidence(
            hevc.firstFragment,
            videoTrackID: hevcTrack?.id,
            codec: hevcTrack?.codec,
            mutation: mutation
        )
        expect("video-first AVC first VIDEO sample has MP4 sync metadata AND an IDR NAL",
               avcEvidence == FMP4.FirstVideoSampleEvidence(mp4Sync: true, nalIDR: true))
        expect("audio-first HEVC first VIDEO sample has MP4 sync metadata AND an IDR NAL",
               hevcEvidence == FMP4.FirstVideoSampleEvidence(mp4Sync: true, nalIDR: true))

        expect("nil video track yields indeterminate, never a first-traf guess",
               FMP4.firstVideoSampleIsIDR(
                   avc.firstFragment,
                   videoTrackID: nil,
                   codec: .avc(nalLengthBytes: 4),
                   mutation: mutation
               ) == nil)
        expect("unmatched video track yields indeterminate, never a first-traf guess",
               FMP4.firstVideoSampleIsIDR(
                   avc.firstFragment,
                   videoTrackID: 99,
                   codec: .avc(nalLengthBytes: 4),
                   mutation: mutation
               ) == nil)

        let unknownTkhd = FMP4.settingVideoTkhdVersion(in: avc.initSegment, to: 2)
        expect("unknown tkhd version fails closed",
               unknownTkhd != nil && FMP4.videoTrack(inInit: unknownTkhd!, mutation: mutation) == nil)
        for byteCount in 1 ... 3 {
            let shortTkhd = FMP4.truncatingVideoTkhdPayload(
                in: avc.initSegment,
                to: byteCount
            )
            expect("\(byteCount)-byte tkhd payload fails closed before FullBox read",
                   shortTkhd != nil
                       && FMP4.videoTrack(inInit: shortTkhd!, mutation: mutation) == nil)
        }

        let syncFlagOnly = avcTrack.flatMap {
            FMP4.removingFirstVideoSampleIDR(from: avc.firstFragment, videoTrackID: $0.id, codec: $0.codec)
        }
        expect("fixture mutant can remove the AVC IDR while retaining MP4 sync metadata", syncFlagOnly != nil)
        if let syncFlagOnly, let avcTrack {
            expect("MP4 sync metadata without an IDR NAL is rejected",
                   FMP4.firstVideoSampleEvidence(
                       syncFlagOnly,
                       videoTrackID: avcTrack.id,
                       codec: avcTrack.codec,
                       mutation: mutation
                   ) == FMP4.FirstVideoSampleEvidence(mp4Sync: true, nalIDR: false))
        }

        let nalOnly = hevcTrack.flatMap {
            FMP4.settingFirstVideoSampleSyncMetadata(in: hevc.firstFragment, videoTrackID: $0.id, sync: false)
        }
        expect("fixture mutant can clear HEVC MP4 sync metadata while retaining its IDR NAL", nalOnly != nil)
        if let nalOnly, let hevcTrack {
            expect("an IDR NAL without MP4 sync metadata is rejected",
                   FMP4.firstVideoSampleEvidence(
                       nalOnly,
                       videoTrackID: hevcTrack.id,
                       codec: hevcTrack.codec,
                       mutation: mutation
                   ) == FMP4.FirstVideoSampleEvidence(mp4Sync: false, nalIDR: true))
        }

        let validAVCIDR = Data([0, 0, 0, 2, 0x65, 0x80])
        let malformedAVCTail = validAVCIDR + Data([0, 0, 0, 2, 0x41])
        expect("complete AVC IDR access unit validates",
               FMP4.sampleContainsIDR(validAVCIDR, codec: .avc(nalLengthBytes: 4)) == true)
        expect("AVC IDR prefix with malformed trailing NAL fails closed",
               FMP4.sampleContainsIDR(malformedAVCTail, codec: .avc(nalLengthBytes: 4)) == nil)
        expect("one-byte AVC IDR NAL has no payload and fails closed",
               FMP4.sampleContainsIDR(Data([0, 0, 0, 1, 0x65]), codec: .avc(nalLengthBytes: 4)) == nil)
        expect("AVC forbidden_zero_bit fails closed",
               FMP4.sampleContainsIDR(Data([0, 0, 0, 2, 0xE5, 0x80]), codec: .avc(nalLengthBytes: 4)) == nil)

        let validHEVCIDR = Data([0, 0, 0, 3, 0x26, 0x01, 0x80])
        expect("complete HEVC IDR access unit validates",
               FMP4.sampleContainsIDR(validHEVCIDR, codec: .hevc(nalLengthBytes: 4)) == true)
        expect("one-byte HEVC IDR prefix fails closed",
               FMP4.sampleContainsIDR(Data([0, 0, 0, 1, 0x26]), codec: .hevc(nalLengthBytes: 4)) == nil)
        expect("HEVC temporal_id_plus1 zero fails closed",
               FMP4.sampleContainsIDR(Data([0, 0, 0, 3, 0x26, 0x00, 0x80]), codec: .hevc(nalLengthBytes: 4)) == nil)
        expect("HEVC forbidden_zero_bit fails closed",
               FMP4.sampleContainsIDR(Data([0, 0, 0, 3, 0xA6, 0x01, 0x80]), codec: .hevc(nalLengthBytes: 4)) == nil)
        expect("Dolby Vision UNSPEC62 remains valid but does not count as an IDR",
               FMP4.sampleContainsIDR(Data([0, 0, 0, 3, 0x7C, 0x01, 0x80]), codec: .hevc(nalLengthBytes: 4)) == false)
        expect("multilayer HEVC IDR-type NAL is valid but not a base-layer IDR",
               FMP4.sampleContainsIDR(
                   Data([0, 0, 0, 3, 0x27, 0x09, 0x80]),
                   codec: .hevc(nalLengthBytes: 4),
                   mutation: mutation
               ) == false)

        if let avcTrack {
            let inflated = FMP4.inflatingFirstVideoTRUNSampleCountWithOneRecord(
                in: avc.firstFragment,
                videoTrackID: avcTrack.id
            )
            expect("fixture mutant inflates trun sample_count", inflated != nil)
            expect("inflated trun sample_count with one record fails closed",
                   inflated != nil && FMP4.firstVideoSampleIsIDR(
                       inflated!, videoTrackID: avcTrack.id, codec: avcTrack.codec
                   ) == nil)

            let badTFHD = FMP4.settingFirstVideoTFHDVersion(
                in: avc.firstFragment,
                videoTrackID: avcTrack.id,
                to: 0xFF
            )
            expect("unsupported tfhd FullBox version fails closed",
                   badTFHD != nil && FMP4.firstVideoSampleIsIDR(
                       badTFHD!, videoTrackID: avcTrack.id, codec: avcTrack.codec
                   ) == nil)
            let badTFHDFlags = FMP4.settingFirstVideoTFHDFlags(
                in: avc.firstFragment,
                videoTrackID: avcTrack.id,
                to: 0x800000
            )
            expect("unknown tfhd FullBox flags fail closed",
                   badTFHDFlags != nil && FMP4.firstVideoSampleIsIDR(
                       badTFHDFlags!, videoTrackID: avcTrack.id, codec: avcTrack.codec
                   ) == nil)

            let badTRUN = FMP4.settingFirstVideoTRUNVersion(
                in: avc.firstFragment,
                videoTrackID: avcTrack.id,
                to: 0xFF
            )
            expect("unsupported trun FullBox version fails closed",
                   badTRUN != nil && FMP4.firstVideoSampleIsIDR(
                       badTRUN!, videoTrackID: avcTrack.id, codec: avcTrack.codec
                   ) == nil)
            let badTRUNFlags = FMP4.settingFirstVideoTRUNFlags(
                in: avc.firstFragment,
                videoTrackID: avcTrack.id,
                to: 0x800000
            )
            expect("unknown trun FullBox flags fail closed",
                   badTRUNFlags != nil && FMP4.firstVideoSampleIsIDR(
                       badTRUNFlags!, videoTrackID: avcTrack.id, codec: avcTrack.codec
                   ) == nil)

            let duplicateTraf = FMP4.duplicatingMatchingTraf(
                in: avc.firstFragment,
                videoTrackID: avcTrack.id
            )
            expect("duplicate matching video traf fails closed",
                   duplicateTraf != nil && FMP4.firstVideoSampleIsIDR(
                       duplicateTraf!, videoTrackID: avcTrack.id, codec: avcTrack.codec
                   ) == nil)
        }

        let duplicateVideoTrack = FMP4.duplicatingVideoTrack(in: avc.initSegment)
        expect("duplicate vide tracks are ambiguous and fail closed",
               duplicateVideoTrack != nil && FMP4.videoTrack(inInit: duplicateVideoTrack!) == nil)
        let duplicateDescription = FMP4.duplicatingVideoSampleDescription(in: avc.initSegment)
        expect("multiple unresolved video sample descriptions fail closed",
               duplicateDescription != nil && FMP4.videoTrack(inInit: duplicateDescription!) == nil)
    }

    if mutation == nil {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessURLProtocol.self]
        let session = URLSession(configuration: configuration)

        HarnessURLProtocol.script.install { request in
            let response = protocolResponse(request.request, status: 200, length: 3)
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: Data("abc".utf8))
            request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost))
        }
        let responsePlusError = Live.get(
            host: "transport.test", port: 80, path: "/response-plus-error", timeout: 1, session: session
        )
        expect("URL response plus error is transport failure and discards body",
               !responsePlusError.ok && responsePlusError.transportError != nil && responsePlusError.body.isEmpty)

        HarnessURLProtocol.script.install { request in
            let response = protocolResponse(request.request, status: 200, length: 12)
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: Data("partial".utf8))
            request.client?.urlProtocolDidFinishLoading(request)
        }
        let partialSegment = Live.get(
            host: "transport.test", port: 80, path: "/seg7.m4s", timeout: 1, session: session
        )
        expect("partial advertised segment is not a complete HTTP 200",
               partialSegment.status == 200 && !partialSegment.ok
                   && partialSegment.transportError?.contains("incomplete body") == true
                   && partialSegment.body.isEmpty)

        let lateCompletion = DispatchSemaphore(value: 0)
        HarnessURLProtocol.script.install { request in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                let response = protocolResponse(request.request, status: 200, length: 4)
                request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
                request.client?.urlProtocol(request, didLoad: Data("late".utf8))
                request.client?.urlProtocolDidFinishLoading(request)
                lateCompletion.signal()
            }
        }
        let timedOut = Live.get(
            host: "transport.test", port: 80, path: "/late", timeout: 0.05, session: session
        )
        let lateAttemptRan = lateCompletion.wait(timeout: .now() + 1) == .success
        expect("timeout seals the result, cancels the task, and ignores post-timeout completion",
               timedOut.status == -1 && !timedOut.ok && timedOut.body.isEmpty
                   && timedOut.transportError != nil && lateAttemptRan)
        session.invalidateAndCancel()
    }

    let mutationName = mutation?.rawValue ?? harnessMutation?.rawValue
    let title = mutationName.map { "== oracle self-test (MUTANT: \($0)) ==" } ?? "== oracle self-test =="
    print(paint(title, "1"))
    var ok = true
    for (name, pass) in checks {
        ok = ok && pass
        print("[\(paint(pass ? "PASS" : "FAIL", pass ? "32" : "31"))] \(name)")
    }
    print("")
    print(ok ? paint("SELF-TEST OK (oracle validated)", "1;32") : paint("SELF-TEST FAILED", "1;31"))
    return ok
}

func runFixtureAssert(normalPath: String, timeoutPath: String) -> Bool {
    var checks: [(String, Bool)] = []
    func expect(_ name: String, _ condition: Bool) { checks.append((name, condition)) }

    let normal = Trace.session(inFileAt: normalPath)
    let timeout = Trace.session(inFileAt: timeoutPath)
    expect("normal fixture has exactly one session", Trace.sessionCount(inFileAt: normalPath) == 1)
    expect("timeout fixture has exactly one session", Trace.sessionCount(inFileAt: timeoutPath) == 1)

    if let normal, let first = normal.firstMediaResponse {
        expect("normal first response is absolute zero with six-segment cardinality",
               first.sequence == 0 && first.segmentCount == 6 && first.advertisedRange == 0..<6)
        expect("normal fixture keeps duration proof scoped to live playlist bytes",
               Trace.startupRenderedMilliseconds(normal, response: first) == nil)
        expect("normal fixture proves a valid nonzero sliding response",
               normal.mediaResponses.dropFirst().contains {
                   $0.sequence > 0 && $0.advertisedRange != nil
               })
        expect("normal alternate playlist starts at the same absolute-zero cohort",
               normal.audioResponses.first?.sequence == 0
                   && normal.audioResponses.first?.segmentCount == 6)
        expect("normal first requests use real video and audio URI grammar at segment zero",
               normal.firstVideoSegReq == 0 && normal.audioSegReqs.first?.segmentID == 0)
        expect("normal trace has no EVENT marker or advertised 404",
               !normal.sawEventPlaylist && normal.advertisedFailures.isEmpty)
        let points = Trace.findings(normal)
        expect("normal success path is under the separate wall deadline",
               points.first { $0.point == .startupLatency }?.verdict == .green)
        expect("normal success path emits no timeout tuple",
               points.first { $0.point == .failSoftCounted }?.verdict == .green)
    } else {
        expect("normal fixture parses", false)
    }

    if let timeout {
        expect("timeout fixture proves only the complete point7 tuple",
               Trace.failSoftTimeoutFinding(timeout).verdict == .green)
    } else {
        expect("timeout fixture parses", false)
    }

    print(paint("== dedicated fixture assertions ==", "1"))
    var passed = true
    for (name, condition) in checks {
        passed = passed && condition
        print("[\(paint(condition ? "PASS" : "FAIL", condition ? "32" : "31"))] \(name)")
    }
    print("")
    print(passed ? paint("FIXTURES OK", "1;32") : paint("FIXTURES FAILED", "1;31"))
    return passed
}

// MARK: - arg helpers

func value(_ flag: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "selftest"

switch cmd {
case "selftest":
    let mutation: FMP4.Mutation?
    let harnessMutation: HarnessMutation?
    if let name = value("--mutant", args) {
        if let parsed = FMP4.Mutation(rawValue: name) {
            mutation = parsed
            harnessMutation = nil
        } else if let parsed = HarnessMutation(rawValue: name) {
            mutation = nil
            harnessMutation = parsed
        } else {
            let names = (FMP4.Mutation.allCases.map(\.rawValue) + [HarnessMutation.startupReadinessOr.rawValue])
                .joined(separator: " | ")
            FileHandle.standardError.write(Data("unknown mutant \(name); use \(names)\n".utf8)); exit(2)
        }
    } else {
        mutation = nil
        harnessMutation = nil
    }
    exit(runSelfTest(mutation: mutation, harnessMutation: harnessMutation) ? 0 : 1)

case "trace":
    guard let path = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        FileHandle.standardError.write(Data("usage: trace <log> [--index N] [--only-point7]\n".utf8)); exit(2)
    }
    let idx = Int(value("--index", args) ?? "0") ?? 0
    guard let s = Trace.session(inFileAt: path, index: idx) else {
        FileHandle.standardError.write(Data("no plain-remux HLS session #\(idx) in \(path)\n".utf8)); exit(2)
    }
    let findings = args.contains("--only-point7")
        ? [Trace.failSoftTimeoutFinding(s)] : Trace.findings(s)
    let accept = report(
        "trace channel: \(path) (session #\(idx), port \(s.port.map(String.init) ?? "?"))",
        findings)
    exit(accept ? 0 : 1)

case "fixture-assert":
    let paths = Array(args.dropFirst())
    guard paths.count == 2 else {
        FileHandle.standardError.write(Data("usage: fixture-assert <normal.trace> <timeout.trace>\n".utf8)); exit(2)
    }
    exit(runFixtureAssert(normalPath: paths[0], timeoutPath: paths[1]) ? 0 : 1)

case "live":
    guard let container = value("--container", args) else {
        FileHandle.standardError.write(Data("usage: live --container <appDataDir> [--port N] [--log <file>]\n".utf8)); exit(2)
    }
    var logPath = value("--log", args)
    if logPath == nil { logPath = container + "/Library/Caches/diagnostics.log" }
    guard let logPath else {
        FileHandle.standardError.write(Data("usage: live --container <appDataDir> [--port N] [--log <file>]\n".utf8)); exit(2)
    }
    guard let s = Trace.session(inFileAt: logPath) else {
        FileHandle.standardError.write(Data("no live plain-remux session in \(logPath) (is a plain MKV playing?)\n".utf8)); exit(2)
    }
    guard let port = Int(value("--port", args) ?? "") ?? s.port else {
        FileHandle.standardError.write(Data("could not determine loopback port (pass --port N)\n".utf8)); exit(2)
    }
    // Provenance of the port, printed on every run: probing a STALE port is one of the
    // ways this channel can silently measure the wrong thing, and it must be visible.
    let sessions = Trace.sessionCount(inFileAt: logPath)
    print("[live] probing 127.0.0.1:\(port) (port read from this session's `hls server listening` line; "
          + "\(sessions) plain-remux session(s) in \(logPath))")
    if sessions > 1 {
        FileHandle.standardError.write(Data("""

        [INFRA] the captured log contains \(sessions) plain-remux sessions, not 1.
        [INFRA] The session that was waited on is NOT necessarily the one still
        [INFRA] listening, so any probe result would be ambiguous and the port may be dead.
        [INFRA] This means the app was relaunched or re-mounted mid-run.
        [INFRA] exit 3 - could not stand up a probeable playback session.

        """.utf8))
        exit(3)
    }

    let outcome = Live.evaluate(port: port, trace: s, containerPath: container)
    if let infra = outcome.infra {
        // Print whatever WAS observed, explicitly marked as not a verdict, then exit 3.
        if !outcome.findings.isEmpty {
            _ = report("live channel (INCOMPLETE - NOT A VERDICT): 127.0.0.1:\(port)", outcome.findings)
        }
        FileHandle.standardError.write(Data("""

        [INFRA] \(infra)
        [INFRA] exit 3 - the live channel could not OBSERVE the session, so nothing above is
        [INFRA] a product signal. This is NOT a player regression.

        """.utf8))
        exit(3)
    }
    let accept = report("live channel: 127.0.0.1:\(port) (log \(logPath))", outcome.findings)
    exit(accept ? 0 : 1)

case "spool":
    guard let container = value("--container", args) else {
        FileHandle.standardError.write(Data("usage: spool --container <appDataDir> [--expect-active|--expect-empty]\n".utf8)); exit(2)
    }
    let snapshot = SpoolLayout.inspect(containerPath: container)
    print("root=\(snapshot.rootPath) bytes=\(snapshot.bytes) launches=\(snapshot.launchDirectories.count) sessions=\(snapshot.sessionDirectories.count) errors=\(snapshot.errors)")
    if snapshot.inspectionFailed { exit(2) }
    if args.contains("--expect-active") {
        exit(snapshot.hasOneActiveLaunchAndSession
            && SpoolLayout.withinAdmissionCeiling(snapshot.bytes) ? 0 : 1)
    }
    if args.contains("--expect-empty") { exit(snapshot.isReclaimed ? 0 : 1) }
    exit(0)

default:
    FileHandle.standardError.write(Data("unknown command \(cmd); use selftest | fixture-assert | trace | live | spool\n".utf8))
    exit(2)
}
