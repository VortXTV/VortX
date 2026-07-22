import Foundation

// =============================================================================
// player-conformance - acceptance harness for the player rework.
//
// Subcommands:
//   selftest                         Validate the oracle (cohort boundary cases,
//                                     EXTINF integer-ms parsing, fMP4 sync parser,
//                                     server-faithful build/parse round trip).
//   trace <log> [--index N]          Evaluate contract points 1,3,4,6,7 from a
//                                     captured request-trace (real server lines).
//   live  --container <dir>          Full battery over loopback + filesystem while
//         [--port N] [--log <file>]  a plain-remux playback is LIVE. Decides all
//         [--spool <dir>]            seven points; the acceptance gate.
//         [--spool-bound-mib N]
//         [--sample N]
//   spool <dir>                      Print total bytes under <dir> (runner uses it
//                                     for the post-teardown zero check).
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
    var accept = true
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

func traceFindingsWithObservedAvailability(_ session: TraceSession) -> [Finding] {
    Trace.findings(session).map { finding in
        guard finding.point == .noAdvertised404, session.advertised404s.isEmpty else { return finding }
        return Finding(
            point: .noAdvertised404,
            verdict: .indeterminate,
            evidence: finding.evidence + [
                "resident-window arithmetic is diagnostic only; this trace contains no complete advertised-id 404/410 proof"
            ]
        )
    }
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

func runSelfTest(mutation: FMP4.Mutation? = nil) -> Bool {
    var checks: [(String, Bool)] = []
    func expect(_ name: String, _ cond: Bool) { checks.append((name, cond)) }

    // Cohort boundary cases, built through the REAL server format and measured as
    // integer ms from the resulting EXTINF text.
    func cohort(_ durs: [Double], ended: Bool = false) -> (Int, Int, Bool) {
        let body = Playlist.buildMediaBodyLikeServer(durations: durs, ended: ended)
        let p = Playlist.parseMedia(body)
        return (p.count, p.totalMs, Playlist.cohortReady(count: p.count, totalMs: p.totalMs))
    }
    let a = cohort(Array(repeating: 4.000, count: 5))
    expect("5x4.000s stays CLOSED (count 5<6)", a == (5, 20000, false))
    let b = cohort(Array(repeating: 3.000, count: 6))
    expect("6x3.000s OPENS (6 segs, 18000 ms)", b == (6, 18000, true))
    let c = cohort(Array(repeating: 1.000, count: 15))
    expect("15x1.000s OPENS (15 segs, 15000 ms)", c == (15, 15000, true))
    let d = cohort([2.500, 2.500, 2.500, 2.500, 2.500, 2.499])
    expect("14.999s (6 segs) stays CLOSED (14999<15000, 1 ms)", d == (6, 14999, false))
    let e = cohort([2.500, 2.500, 2.500, 2.500, 2.500, 2.500])
    expect("15.000s (6 segs) OPENS (integer >= 15000)", e == (6, 15000, true))

    // EXTINF text -> integer ms, no float.
    expect("EXTINF 4.000 -> 4000 ms", Playlist.msFromExtinf("#EXTINF:4.000,") == 4000)
    expect("EXTINF 14.999 -> 14999 ms", Playlist.msFromExtinf("#EXTINF:14.999,") == 14999)
    expect("EXTINF 15.000 -> 15000 ms", Playlist.msFromExtinf("#EXTINF:15.000,") == 15000)
    expect("EXTINF 15 -> 15000 ms", Playlist.msFromExtinf("#EXTINF:15,") == 15000)
    expect("EXTINF 1.5 -> 1500 ms", Playlist.msFromExtinf("#EXTINF:1.5,") == 1500)

    // The real DVPlaybackPolicy header is compiled in and used by the builder.
    let body = Playlist.buildMediaBodyLikeServer(durations: [4.0, 4.0, 4.0], ended: true)
    expect("builder emits TARGETDURATION 5", body.contains("#EXT-X-TARGETDURATION:5"))
    expect("builder emits the load-bearing EXT-X-START", body.contains("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"))
    expect("builder emits EXT-X-MAP init.mp4", body.contains("#EXT-X-MAP:URI=\"init.mp4\""))
    let rp = Playlist.parseMedia(body)
    expect("round-trip recovers 3 segments ids 0..2", rp.segments.map(\.id) == [0, 1, 2])
    expect("round-trip sees ENDLIST", rp.endlist)

    var predictedOnlyTrace = TraceSession()
    predictedOnlyTrace.advertisedMax = 100
    predictedOnlyTrace.segResponseBytes = [0: 2 * 1024 * 1024]
    let predictedOnlyPoint = traceFindingsWithObservedAvailability(predictedOnlyTrace)
        .first { $0.point == .noAdvertised404 }
    expect("resident-window prediction alone is diagnostic, not RED",
           predictedOnlyPoint?.verdict == .indeterminate)
    predictedOnlyTrace.advertised404s = [0]
    let observed404Point = traceFindingsWithObservedAvailability(predictedOnlyTrace)
        .first { $0.point == .noAdvertised404 }
    expect("observed advertised-id 404 remains RED", observed404Point?.verdict == .red)

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

        if let avc {
            let masterBody = Data("#EXTM3U\n".utf8)
            let mediaBody = Data(Playlist.buildMediaBodyLikeServer(durations: [4.0], ended: false).utf8)
            let initBody = avc.initSegment
            HarnessURLProtocol.script.install { request in
                let path = request.request.url?.path ?? ""
                let body: Data
                let advertisedLength: Int
                switch path {
                case "/master.m3u8":
                    body = masterBody; advertisedLength = body.count
                case "/media.m3u8":
                    body = mediaBody; advertisedLength = body.count
                case "/init.mp4":
                    body = initBody; advertisedLength = body.count
                default:
                    body = Data("short".utf8); advertisedLength = body.count + 50
                }
                let response = protocolResponse(request.request, status: 200, length: advertisedLength)
                request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
                request.client?.urlProtocol(request, didLoad: body)
                request.client?.urlProtocolDidFinishLoading(request)
            }
            let partialAvailability = Live.evaluate(
                port: 80,
                trace: TraceSession(),
                spoolPath: nil,
                spoolBoundMiB: Contract.windowFloorMiB * 2,
                segmentSampleCap: 1,
                session: session
            )
            let availabilityPoint = partialAvailability.findings.first { $0.point == .noAdvertised404 }
            expect("partial advertised segment makes availability INFRA, never GREEN or RED",
                   partialAvailability.infra != nil && availabilityPoint?.verdict == .indeterminate)
        }

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

    let title = mutation.map { "== oracle self-test (MUTANT: \($0.rawValue)) ==" } ?? "== oracle self-test =="
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
    if let name = value("--mutant", args) {
        guard let parsed = FMP4.Mutation(rawValue: name) else {
            let names = FMP4.Mutation.allCases.map(\.rawValue).joined(separator: " | ")
            FileHandle.standardError.write(Data("unknown mutant \(name); use \(names)\n".utf8)); exit(2)
        }
        mutation = parsed
    } else {
        mutation = nil
    }
    exit(runSelfTest(mutation: mutation) ? 0 : 1)

case "trace":
    guard let path = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
        FileHandle.standardError.write(Data("usage: trace <log> [--index N]\n".utf8)); exit(2)
    }
    let idx = Int(value("--index", args) ?? "0") ?? 0
    guard let s = Trace.session(inFileAt: path, index: idx) else {
        FileHandle.standardError.write(Data("no plain-remux HLS session #\(idx) in \(path)\n".utf8)); exit(2)
    }
    let accept = report(
        "trace channel: \(path) (session #\(idx), port \(s.port.map(String.init) ?? "?"))",
        traceFindingsWithObservedAvailability(s)
    )
    exit(accept ? 0 : 1)

case "live":
    let container = value("--container", args)
    var logPath = value("--log", args)
    if logPath == nil, let c = container { logPath = c + "/Library/Caches/diagnostics.log" }
    guard let logPath else {
        FileHandle.standardError.write(Data("usage: live --container <appDataDir> [--port N] [--log <file>] [--spool <dir>]\n".utf8)); exit(2)
    }
    guard let s = Trace.session(inFileAt: logPath) else {
        FileHandle.standardError.write(Data("no live plain-remux session in \(logPath) (is a plain MKV playing?)\n".utf8)); exit(2)
    }
    guard let port = Int(value("--port", args) ?? "") ?? s.port else {
        FileHandle.standardError.write(Data("could not determine loopback port (pass --port N)\n".utf8)); exit(2)
    }
    let spool = value("--spool", args)
    let bound = Int(value("--spool-bound-mib", args) ?? "") ?? (Contract.windowFloorMiB * 2)
    let sample = Int(value("--sample", args) ?? "") ?? 12

    // Provenance of the port, printed on every run: probing a STALE port is one of the
    // ways this channel can silently measure the wrong thing, and it must be visible.
    let sessions = Trace.sessionCount(inFileAt: logPath)
    print("[live] probing 127.0.0.1:\(port) (port read from this session's `hls server listening` line; "
          + "\(sessions) plain-remux session(s) in \(logPath))")
    if sessions > 1 {
        FileHandle.standardError.write(Data("""

        [INFRA] the captured log contains \(sessions) plain-remux sessions, not 1.
        [INFRA] The session that was waited on and soaked is NOT necessarily the one still
        [INFRA] listening, so any probe result would be ambiguous and the port may be dead.
        [INFRA] This means the app was relaunched or re-mounted mid-run.
        [INFRA] exit 3 - could not stand up a probeable playback session.

        """.utf8))
        exit(3)
    }

    let outcome = Live.evaluate(port: port, trace: s, spoolPath: spool, spoolBoundMiB: bound, segmentSampleCap: sample)
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
    guard let dir = args.dropFirst().first else {
        FileHandle.standardError.write(Data("usage: spool <dir>\n".utf8)); exit(2)
    }
    if let b = Live.directoryBytes(dir) { print("\(b)"); exit(0) }
    FileHandle.standardError.write(Data("no directory at \(dir)\n".utf8)); exit(2)

default:
    FileHandle.standardError.write(Data("unknown command \(cmd); use selftest | trace | live | spool\n".utf8))
    exit(2)
}
