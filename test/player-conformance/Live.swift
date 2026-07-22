import Foundation

// =============================================================================
// Live channel: talk to the running server over loopback and read segment bytes
// + the filesystem, for the parts a trace cannot decide.
//
// The tvOS simulator shares the host's loopback, so a server the app bound to
// 127.0.0.1:PORT inside the sim is reachable from this process at the same
// address. The port is discovered from the app's request log; the harness then
// fetches the master + media playlists and individual segments, and measures the
// Caches spool directory. Requires a plain-remux playback to be LIVE.
// =============================================================================

enum Live {

    struct Response { let status: Int; let body: Data }

    static func get(host: String = "127.0.0.1", port: Int, path: String, timeout: TimeInterval = 8) -> Response? {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { return nil }
        var out: Response?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse { out = Response(status: http.statusCode, body: data ?? Data()) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return out
    }

    static func directoryBytes(_ path: String) -> Int? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let en = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var total = 0
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += v?.fileSize ?? 0 }
        }
        return total
    }

    /// Full live battery. `trace` supplies mount/ready timing (6) and the
    /// success-path event count (7); the loopback fetches decide 1 (exact ms), 2,
    /// 3 and 4; `spoolPath` measures 5.
    static func findings(port: Int, trace: TraceSession, spoolPath: String?, spoolBoundMiB: Int, segmentSampleCap: Int) -> [Finding] {
        var out: [Finding] = []

        let master = get(port: port, path: "/master.m3u8")
        let masterText = master.flatMap { String(data: $0.body, encoding: .utf8) } ?? ""
        let media = get(port: port, path: "/media.m3u8")
        let parsed = media.flatMap { String(data: $0.body, encoding: .utf8) }.map(Playlist.parseMedia)

        // (1) Exact startup cohort. Best measured from the FIRST response the server
        // ever gave (the trace). The live playlist additionally proves the exact ms
        // arithmetic on real EXTINF text and that TARGETDURATION covers every EXTINF.
        do {
            var ev: [String] = []
            var verdict = Verdict.indeterminate
            if let firstSegs = trace.firstMediaSegs {
                ev.append("first /media.m3u8 (trace) served segs=\(firstSegs) ended=\(trace.firstMediaEnded ?? false)")
                if trace.firstMediaEnded == true && firstSegs < Contract.minStartupSegments {
                    verdict = .exempt; ev.append("ended short clip -> exempt")
                } else {
                    verdict = firstSegs >= Contract.minStartupSegments ? .green : .red
                }
            }
            if let p = parsed {
                let firstN = Array(p.segments.prefix(max(Contract.minStartupSegments, 1)))
                let exactMs = firstN.reduce(0) { $0 + max(0, $1.ms) }
                ev.append("live playlist: \(p.count) segs, first \(firstN.count) sum to \(exactMs) ms (EXACT integer ms from EXTINF text)")
                ev.append("TARGETDURATION=\(p.targetDuration) s; max EXTINF=\(p.segments.map(\.ms).max() ?? 0) ms")
            }
            out.append(Finding(point: .startupCohort, verdict: verdict, evidence: ev))
        }

        // (2) IDR-start on every published segment (sampled).
        do {
            var ev: [String] = []
            var offenders: [Int] = []
            var checked = 0, indeterminate = 0
            // Resolve the VIDEO track_ID from the init segment so the IDR check inspects the
            // video traf, not the first (audio-first fragments would otherwise false-pass).
            let videoTID: UInt32? = get(port: port, path: "/init.mp4").flatMap {
                $0.status == 200 ? FMP4.videoTrackID(inInit: $0.body) : nil
            }
            if let videoTID { ev.append("resolved video track_ID \(videoTID) from init.mp4") }
            else { ev.append("could not resolve video track_ID from init.mp4; IDR check fails safe to indeterminate") }
            if let p = parsed {
                for seg in p.segments.prefix(segmentSampleCap) {
                    guard let r = get(port: port, path: "/seg\(seg.id).m4s"), r.status == 200 else { continue }
                    checked += 1
                    switch FMP4.firstSampleIsSync(r.body, videoTrackID: videoTID) {
                    case .some(true): break
                    case .some(false): offenders.append(seg.id)
                    case .none: indeterminate += 1
                    }
                }
                ev.append("checked \(checked) segments (sample cap \(segmentSampleCap)); non-IDR starts: \(offenders); indeterminate: \(indeterminate)")
                out.append(Finding(point: .idrStart, verdict: offenders.isEmpty ? (checked > 0 ? .green : .indeterminate) : .red, evidence: ev))
            } else {
                out.append(Finding(point: .idrStart, verdict: .indeterminate, evidence: ["no live media playlist to enumerate segments"]))
            }
        }

        // (3) First video + first alternate-audio segment id == 0.
        do {
            var ev: [String] = []
            var verdict = Verdict.red
            if let p = parsed, let firstVideo = p.segments.map(\.id).min() {
                ev.append("live video playlist lowest advertised id: \(firstVideo)")
                verdict = firstVideo == 0 ? .green : .red
            }
            // Alternate audio rendition from the master's EXT-X-MEDIA URI.
            if let audioURI = audioRenditionURI(masterText) {
                ev.append("master advertises alternate audio rendition: \(audioURI)")
                if let a = get(port: port, path: "/\(audioURI)"), let atext = String(data: a.body, encoding: .utf8) {
                    let ap = Playlist.parseMedia(atext)
                    let firstAudio = ap.segments.map(\.id).min() ?? -1
                    ev.append("audio rendition lowest advertised id: \(firstAudio)")
                    if firstAudio != 0 { verdict = .red }
                } else { ev.append("audio playlist fetch failed"); verdict = .red }
            } else {
                ev.append("master advertises NO alternate audio rendition (audio muxed inline) -> audio half UNMET")
                verdict = .red
            }
            out.append(Finding(point: .firstSegmentZero, verdict: verdict, evidence: ev))
        }

        // (4) Availability window: directly GET the lowest advertised segment. On an
        // EVENT playlist (MEDIA-SEQUENCE 0) that is seg0, which the resident window
        // may have evicted while still advertising it.
        do {
            var ev: [String] = []
            var verdict = Verdict.indeterminate
            if let p = parsed, let lowest = p.segments.map(\.id).min() {
                let r = get(port: port, path: "/seg\(lowest).m4s")
                let st = r?.status ?? -1
                ev.append("GET /seg\(lowest).m4s (lowest advertised) -> HTTP \(st)")
                verdict = st == 200 ? .green : .red
                if st != 200 { ev.append("advertised segment is not fetchable -> availability-window violation (RFC 8216 s6.2.2)") }
            }
            out.append(Finding(point: .noAdvertised404, verdict: verdict, evidence: ev))
        }

        // (5) Spool bounded (during-session sample). Post-session zero is a second
        // measurement the runner takes after teardown (see run-conformance.sh).
        do {
            if let path = spoolPath, let bytes = directoryBytes(path) {
                let mib = bytes / (1024 * 1024)
                let ok = mib <= spoolBoundMiB
                out.append(Finding(point: .spoolBounded, verdict: ok ? .green : .red,
                                   evidence: ["spool \(path) = \(bytes) B (\(mib) MiB); mid-session bound \(spoolBoundMiB) MiB",
                                              "post-session-zero must be confirmed by re-measuring after teardown (runner does this)"]))
            } else {
                out.append(Finding(point: .spoolBounded, verdict: .indeterminate,
                                   evidence: ["no spool directory to measure (pass --spool <dir> once the rework names it)"]))
            }
        }

        // (6) + (7) from the trace facts already parsed from the live container log.
        out.append(contentsOf: Trace.findings(trace).filter { $0.point == .startupLatency || $0.point == .failSoftCounted })
        return out
    }

    /// The URI attribute of the master's audio `#EXT-X-MEDIA:TYPE=AUDIO,...` line.
    static func audioRenditionURI(_ master: String) -> String? {
        for line in master.split(separator: "\n") where line.contains("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            if let uriRange = line.range(of: "URI=\"") {
                let rest = line[uriRange.upperBound...]
                if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
            }
        }
        return nil
    }
}
