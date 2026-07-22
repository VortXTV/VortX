import Foundation

// =============================================================================
// Request-trace analysis.
//
// The server writes one durable line per request/response to the app's
// Caches request log (the same channel the overnight run used). Every line is
// "yyyy-MM-dd HH:mm:ss.SSS [category] message". We slice out ONE plain-remux HLS
// session and read the contract-observable facts straight from the real lines the
// running server emitted - this is runtime behaviour, not source text.
//
// Facts a trace can decide on its own: (1) cohort segment count + approximate
// startup ms, (3) first video segment id, (4) any advertised-segment 404 plus the
// latent EVENT-window eviction, (6) mount -> readyToPlay latency, (7) count of
// fail-soft cohort-timeout events on this (successful) session. Points (2) and (5)
// need segment bytes / the filesystem and are left to the live channel.
// =============================================================================

struct TraceSession {
    var lines: [(t: Date?, raw: String)] = []
    var port: Int?
    var mountAt: Date?
    var readyAt: Date?
    var firstMediaSegs: Int?
    var firstMediaEnded: Bool?
    var publishedDurations: [Int: Double] = [:]     // segIndex -> media seconds (from "published" lines)
    var firstVideoSegReq: Int?
    var audioSegReqs: [Int] = []
    var advertisedMax: Int = 0
    var segResponseBytes: [Int: Int] = [:]          // segIndex -> byte length served
    var advertised404s: [Int] = []
    var sawAny404 = false
    var cohortTimeoutEvents = 0
    var mediaResponses: [(segs: Int, ended: Bool)] = []
}

enum Trace {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static func timestamp(_ line: String) -> Date? {
        guard line.count >= 23 else { return nil }
        return stamp.date(from: String(line.prefix(23)))
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: r) else { return nil }
        return (0..<m.numberOfRanges).compactMap { idx in
            guard let rg = Range(m.range(at: idx), in: text) else { return nil }
            return String(text[rg])
        }
    }

    /// Slice the Nth (default first) plain-remux HLS session out of a trace file.
    /// A session begins at "hls server listening on 127.0.0.1:PORT" and runs until
    /// the next such line (or EOF).
    static func session(inFileAt path: String, index: Int = 0) -> TraceSession? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var starts: [Int] = []
        for (i, l) in all.enumerated() where l.contains("hls server listening on 127.0.0.1:") { starts.append(i) }
        guard index < starts.count else { return nil }
        let lo = starts[index]
        let hi = index + 1 < starts.count ? starts[index + 1] : all.count
        return build(Array(all[lo..<hi]))
    }

    private static func build(_ raw: [String]) -> TraceSession {
        var s = TraceSession()
        for line in raw {
            s.lines.append((timestamp(line), line))

            if s.port == nil, let m = firstMatch(#"hls server listening on 127\.0\.0\.1:(\d+)"#, line) {
                s.port = Int(m[1])
            }
            if s.mountAt == nil, line.contains("plain-remux mount") { s.mountAt = timestamp(line) }
            if s.readyAt == nil, line.contains("readyToPlay -> play") { s.readyAt = timestamp(line) }

            if let m = firstMatch(#"hls media segment (\d+) published .*\((\d+)B, ([0-9]+\.[0-9]+)s media\)"#, line) {
                if let idx = Int(m[1]), let d = Double(m[3]) { s.publishedDurations[idx] = d }
            }
            if let m = firstMatch(#"hls resp /media\.m3u8 segs=(\d+) ended=(true|false)"#, line) {
                let segs = Int(m[1]) ?? 0
                let ended = m[2] == "true"
                s.mediaResponses.append((segs, ended))
                s.advertisedMax = max(s.advertisedMax, segs)
                if s.firstMediaSegs == nil { s.firstMediaSegs = segs; s.firstMediaEnded = ended }
            }
            if let m = firstMatch(#"hls req /seg(\d+)\.m4s"#, line), let idx = Int(m[1]) {
                if s.firstVideoSegReq == nil { s.firstVideoSegReq = idx }
            }
            // Alternate-audio rendition segment request (rework-introduced). Match a
            // few plausible shapes so the check works whatever the rework names it.
            if let m = firstMatch(#"hls req /(?:aseg|audio-?seg|aud)(\d+)\.(?:m4s|aac|mp4)"#, line), let idx = Int(m[1]) {
                s.audioSegReqs.append(idx)
            }
            if let m = firstMatch(#"hls resp /seg(\d+)\.m4s (\d+)B"#, line), let idx = Int(m[1]), let b = Int(m[2]) {
                s.segResponseBytes[idx] = b
            }
            if line.contains("hls 404") { s.sawAny404 = true }
            if let m = firstMatch(#"hls 404 /seg(\d+)\.m4s"#, line), let idx = Int(m[1]) {
                // Advertised at the time iff below the max the playlist ever grew to.
                if idx < s.advertisedMax { s.advertised404s.append(idx) }
            }
            if line.contains(Contract.cohortTimeoutEvent) { s.cohortTimeoutEvents += 1 }
        }
        return s
    }

    // MARK: - Availability window (point 4), shared by both channels

    /// The resident-window arithmetic behind contract point 4, factored out so the
    /// trace channel and the live channel evaluate the SAME numbers. When these
    /// lived only inside `Trace.findings`, the live channel probed just the lowest
    /// advertised segment and could report GREEN on a session this arithmetic
    /// proved RED from the identical log. That was a harness UNDER-OBSERVATION bug,
    /// not a contract difference: point 4 has always been "no advertised-segment
    /// 404 through the RFC 8216 s6.2.2 availability window", and the live channel
    /// simply was not looking at the segments most likely to violate it.
    struct AvailabilityWindow {
        /// Mean served segment size, from the real `hls resp /segN.m4s <bytes>B` lines.
        let avgSegmentBytes: Int
        /// How many segments of that size the resident window can hold.
        let residentSegments: Int
        /// Highest segment count the playlist ever advertised.
        let advertisedMax: Int
        /// Highest advertised id the window can no longer hold, or nil when the whole
        /// advertised range still fits. Ids `0...evictedUpTo` are advertised-but-gone.
        let evictedUpTo: Int?
        /// Advertised ids that actually 404'd during playback (proof, not prediction).
        let observed404s: [Int]

        /// Ids the arithmetic predicts are advertised but no longer resident.
        var predictedEvictedIds: [Int] { evictedUpTo.map { Array(0...$0) } ?? [] }
    }

    static func availabilityWindow(_ s: TraceSession) -> AvailabilityWindow {
        let avg = s.segResponseBytes.isEmpty ? 0
                : s.segResponseBytes.values.reduce(0, +) / s.segResponseBytes.count
        let resident = avg > 0 ? (Contract.windowFloorMiB * 1024 * 1024) / avg : 0
        var evictedUpTo: Int?
        if avg > 0, s.advertisedMax > resident { evictedUpTo = s.advertisedMax - resident - 1 }
        return AvailabilityWindow(avgSegmentBytes: avg, residentSegments: resident,
                                  advertisedMax: s.advertisedMax, evictedUpTo: evictedUpTo,
                                  observed404s: s.advertised404s.sorted())
    }

    // MARK: - Contract evaluation from a trace

    static func findings(_ s: TraceSession) -> [Finding] {
        var out: [Finding] = []

        // (1) Startup cohort - count is authoritative from the trace; startup ms is
        // the sum of the cohort segments' published durations (2-dp log precision,
        // which is ample to decide the 15 000 ms floor). `ended` short clips exempt.
        do {
            let segs = s.firstMediaSegs ?? -1
            let ended = s.firstMediaEnded ?? false
            var approxMs = 0
            if segs > 0 { for i in 0..<segs { approxMs += Int(((s.publishedDurations[i] ?? 0) * 1000).rounded()) } }
            let ev = [
                "first /media.m3u8 response: segs=\(segs) ended=\(ended)",
                "cohort startup duration ~= \(approxMs) ms (sum of \(max(segs,0)) published segment durations, 2-dp log)",
                "floors: segments >= \(Contract.minStartupSegments) AND duration >= \(Contract.minStartupMs) ms",
            ]
            if segs < 0 {
                out.append(Finding(point: .startupCohort, verdict: .indeterminate, evidence: ["no /media.m3u8 response in session"]))
            } else if ended && segs < Contract.minStartupSegments {
                out.append(Finding(point: .startupCohort, verdict: .exempt,
                                   evidence: ev + ["source ENDED before the cohort could fill; short-clip exemption"]))
            } else {
                let ok = segs >= Contract.minStartupSegments && approxMs >= Contract.minStartupMs
                out.append(Finding(point: .startupCohort, verdict: ok ? .green : .red, evidence: ev))
            }
        }

        // (2) IDR-start - not decidable from a trace. Heuristic note only.
        do {
            let hardCut = s.publishedDurations.filter { abs($0.value - Contract.hardCutSecs) < 0.005 }.keys.sorted()
            var ev = ["segment bytes are not in the trace; the IDR check needs the live channel (fMP4 parse)"]
            if !hardCut.isEmpty {
                ev.append("heuristic: segments \(hardCut) are exactly \(Contract.hardCutSecs)s (the hard cut) -> the FOLLOWING segment likely starts mid-GOP (non-IDR)")
            }
            out.append(Finding(point: .idrStart, verdict: .indeterminate, evidence: ev))
        }

        // (3) First segment ids.
        do {
            var ev: [String] = []
            var verdict = Verdict.red
            if let v = s.firstVideoSegReq {
                ev.append("first video segment requested: /seg\(v).m4s -> id \(v) (want 0)")
                verdict = v == 0 ? .green : .red
            } else {
                ev.append("no video segment request seen"); verdict = .indeterminate
            }
            if let a = s.audioSegReqs.first {
                ev.append("first alternate-audio segment requested: id \(a) (want 0)")
                if a != 0 { verdict = .red }
            } else {
                ev.append("no alternate-audio rendition requests in trace (beta muxes audio inline) -> audio half UNMET until the rework serves a separate audio rendition starting at seg 0")
                verdict = .red
            }
            out.append(Finding(point: .firstSegmentZero, verdict: verdict, evidence: ev))
        }

        // (4) Advertised-segment availability. Same numbers the live channel uses
        // (see `availabilityWindow`); the two channels must never disagree on them.
        do {
            var ev: [String] = []
            var verdict = Verdict.green
            let w = availabilityWindow(s)
            if !w.observed404s.isEmpty {
                ev.append("advertised segments 404'd: \(w.observed404s)")
                verdict = .red
            } else {
                ev.append("no advertised-segment 404 fired during this forward-only playback")
            }
            // Latent EVENT-window eviction: MEDIA-SEQUENCE stays 0, so the playlist keeps
            // advertising low segments after the resident window has slid past them.
            if w.avgSegmentBytes > 0 {
                ev.append("resident window ~= \(Contract.windowFloorMiB) MiB / \(w.avgSegmentBytes) B ≈ \(w.residentSegments) segments; playlist advertised up to \(w.advertisedMax) (MEDIA-SEQUENCE stays 0)")
                if let evictedUpTo = w.evictedUpTo {
                    ev.append("LATENT: segment 0..\(evictedUpTo) advertised but evicted -> a client that re-requests one (RFC 8216 s6.2.2 window) gets a 404")
                    verdict = .red
                }
            }
            out.append(Finding(point: .noAdvertised404, verdict: verdict, evidence: ev))
        }

        // (5) Spool - filesystem only.
        out.append(Finding(point: .spoolBounded, verdict: .indeterminate,
                           evidence: ["spool byte accounting is not in the trace; needs the live/filesystem channel"]))

        // (6) Startup latency.
        do {
            if let m = s.mountAt, let r = s.readyAt {
                let ms = Int(r.timeIntervalSince(m) * 1000)
                out.append(Finding(point: .startupLatency, verdict: ms <= Contract.sloMountToReadyMs ? .green : .red,
                                   evidence: ["mount -> readyToPlay = \(ms) ms (SLO <= \(Contract.sloMountToReadyMs) ms)"]))
            } else {
                out.append(Finding(point: .startupLatency, verdict: .indeterminate,
                                   evidence: ["missing mount or readyToPlay line in session"]))
            }
        }

        // (7) Fail-soft counted. Two observable sub-invariants:
        //   (a) success path - 0 timeout events on a start that reaches readyToPlay;
        //   (b) timeout path - EXACTLY ONE event + a 404 (into the demotion) + no ready.
        // A forced-timeout fixture session proves (b); a normal session proves (a) but
        // cannot prove the mechanism exists, so it stays PENDING (run the fixture too).
        do {
            let reachedReady = s.readyAt != nil
            let n = s.cohortTimeoutEvents
            var ev = ["\(Contract.cohortTimeoutEvent) events in session: \(n); saw a 404: \(s.sawAny404); reached readyToPlay: \(reachedReady)"]
            var verdict: Verdict
            if n > 1 {
                ev.append("duplicate fail-soft accounting (>1 event)"); verdict = .red
            } else if n == 1 && reachedReady {
                ev.append("a timeout event fired on a start that still succeeded"); verdict = .red
            } else if n == 1 && !reachedReady {
                if s.sawAny404 { ev.append("timeout path verified: one event then a 404 into the demotion"); verdict = .green }
                else { ev.append("one timeout event but no 404 into the demotion"); verdict = .red }
            } else if n == 0 && reachedReady {
                ev.append("success-path invariant holds (0 events); the counted-timeout path is unproven here - run the forced-timeout fixture")
                verdict = .pending
            } else {
                verdict = .indeterminate
            }
            out.append(Finding(point: .failSoftCounted, verdict: verdict, evidence: ev))
        }

        return out
    }
}
