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
    /// Highest EXT-X-MEDIA-SEQUENCE the server reported on a media response. The window
    /// is consumption-anchored and SLIDES, so a nonzero value here is normal, expected
    /// behaviour and not evidence of anything going wrong.
    var maxMediaSequence: Int = 0
    /// Raw `hls resp /media.m3u8` lines seen, whether or not this parser understood them.
    /// The gap between this and `mediaResponses.count` is PARSER DRIFT, not product
    /// behaviour, and is reported as INFRA rather than folded into a verdict.
    var mediaResponseLines: Int = 0
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

    /// How many plain-remux sessions the file contains. More than one in a slice that
    /// is meant to cover a single run means the app was relaunched or re-mounted
    /// mid-run, so the port the live channel would probe may belong to a DEAD session.
    static func sessionCount(inFileAt path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
                   .filter { $0.contains("hls server listening on 127.0.0.1:") }.count
    }

    private static func build(_ raw: [String]) -> TraceSession {
        var s = TraceSession()
        for line in raw {
            s.lines.append((timestamp(line), line))

            if s.port == nil, let m = firstMatch(#"hls server listening on 127\.0\.0\.1:(\d+)"#, line) {
                s.port = Int(m[1])
            }
            // The mount marker the shipped engine writes is `dv-remux mount host=...`
            // (AVPlayerEngine.swift:339, category `avplayer`). `plain-remux mount` is kept
            // only so older captured traces still parse; it is NOT a shipped shape.
            if s.mountAt == nil,
               line.contains("dv-remux mount") || line.contains("plain-remux mount") {
                s.mountAt = timestamp(line)
            }
            if s.readyAt == nil, line.contains("readyToPlay -> play") { s.readyAt = timestamp(line) }

            if let m = firstMatch(#"hls media segment (\d+) published .*\((\d+)B, ([0-9]+\.[0-9]+)s media\)"#, line) {
                if let idx = Int(m[1]), let d = Double(m[3]) { s.publishedDurations[idx] = d }
            }
            // DRIFT FIXED: this pattern had no `seq=(\d+) ` between the path and `segs=`,
            // but the server has emitted the media sequence in that exact position since
            // the window became consumption-anchored (VortXRemuxHLSServer.swift:1012). The
            // regex therefore matched NOTHING on a real trace: `firstMediaSegs` stayed nil,
            // point 1 was permanently INDETERMINATE and point 4's `advertisedMax` stayed 0.
            // A blind check that reports "cannot observe" looks identical to a check that
            // is merely unlucky, which is how this survived.
            if let m = firstMatch(#"hls resp /media\.m3u8 seq=(\d+) segs=(\d+) ended=(true|false)"#, line) {
                let seq = Int(m[1]) ?? 0
                let segs = Int(m[2]) ?? 0
                let ended = m[3] == "true"
                s.mediaResponses.append((segs, ended))
                s.maxMediaSequence = max(s.maxMediaSequence, seq)
                s.advertisedMax = max(s.advertisedMax, seq + segs)
                if s.firstMediaSegs == nil { s.firstMediaSegs = segs; s.firstMediaEnded = ended }
            }
            if line.contains("hls resp /media.m3u8") { s.mediaResponseLines += 1 }
            if let m = firstMatch(#"hls req /seg(\d+)\.m4s"#, line), let idx = Int(m[1]) {
                if s.firstVideoSegReq == nil { s.firstVideoSegReq = idx }
            }
            // Alternate-audio rendition segment request. The shipped URI is
            // `/audio<renditionID>-seg<segmentID>.m4s` (VortXRemuxHLSServer.swift:1107);
            // the legacy `aseg<N>.m4s` shape is kept only for older captured traces.
            //
            // DRIFT FIXED: the old pattern (`aseg|audio-?seg|aud` followed immediately by
            // digits) cannot match `/audio0-seg3.m4s`, because the rendition id sits
            // between `audio` and `-seg`. Every alternate-audio request in a real trace was
            // invisible, so the trace channel's point 3 always concluded "beta muxes audio
            // inline" and scored RED no matter what the server served.
            if let m = firstMatch(#"hls req /audio\d+-seg(\d+)\.m4s"#, line), let idx = Int(m[1]) {
                s.audioSegReqs.append(idx)
            } else if let m = firstMatch(#"hls req /aseg(\d+)\.m4s"#, line), let idx = Int(m[1]) {
                s.audioSegReqs.append(idx)
            }
            if let m = firstMatch(#"hls resp /seg(\d+)\.m4s (\d+)B"#, line), let idx = Int(m[1]), let b = Int(m[2]) {
                s.segResponseBytes[idx] = b
            }
            if line.contains("hls 404") { s.sawAny404 = true }
            if let m = firstMatch(#"hls 404 /seg(\d+)\.m4s"#, line), let idx = Int(m[1]) {
                // Advertised at the time iff inside the window the playlist actually
                // published: at or above the highest MEDIA-SEQUENCE reached, and below the
                // highest absolute id advertised.
                //
                // DRIFT FIXED: this was `idx < s.advertisedMax` alone, which treats every
                // low id as permanently advertised. That was true of the old EVENT-shaped
                // playlist whose MEDIA-SEQUENCE never moved; the shipped playlist SLIDES
                // (DVPlaybackPolicy.swift:184-196 renders `window.mediaSequence`, and the
                // window is anchored behind the client's demonstrated fetch frontier). A
                // 404 for an id the playlist has already dropped is the server behaving
                // correctly, and scoring it RED would have manufactured a product
                // regression out of the current windowing.
                if idx >= s.maxMediaSequence, idx < s.advertisedMax { s.advertised404s.append(idx) }
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
        // which is ample to decide the 4 000 ms floor). `ended` short clips exempt.
        //
        // The product logs the "published +Xs after mount" breadcrumb ONLY for segments
        // 0 and 1 (VortXMKVRemuxStream.swift:2882, `if idx <= 1`). Summing missing ids as
        // zero would fabricate a duration shortfall, so the ms strand is reported only
        // when EVERY id in the cohort actually has a logged duration.
        do {
            let segs = s.firstMediaSegs ?? -1
            let ended = s.firstMediaEnded ?? false
            var approxMs: Int?
            if segs > 0 {
                let ids = Array(0..<segs)
                if ids.allSatisfy({ s.publishedDurations[$0] != nil }) {
                    approxMs = ids.reduce(0) { $0 + Int(((s.publishedDurations[$1] ?? 0) * 1000).rounded()) }
                }
            }
            var ev = ["first /media.m3u8 response: segs=\(segs) ended=\(ended)"]
            if let approxMs {
                ev.append("cohort startup duration ~= \(approxMs) ms (sum of \(segs) published segment durations, 2-dp log)")
            } else if segs > 0 {
                ev.append("cohort duration NOT measurable from this trace: the product logs the published"
                    + " breadcrumb only for segments 0 and 1, and this cohort is \(segs) segments."
                    + " The count strand decides; the live channel measures exact ms from EXTINF text.")
            }
            ev.append("floors: segments >= \(Contract.minStartupSegments) AND duration >= \(Contract.minStartupMs) ms")
            if segs < 0 {
                out.append(Finding(point: .startupCohort, verdict: .indeterminate,
                                   evidence: ["no /media.m3u8 response in session"]))
            } else if ended && segs < Contract.minStartupSegments {
                out.append(Finding(point: .startupCohort, verdict: .exempt,
                                   evidence: ev + ["source ENDED before the cohort could fill; short-clip exemption"]))
            } else {
                let countOK = segs >= Contract.minStartupSegments
                let durationOK = approxMs.map { $0 >= Contract.minStartupMs } ?? true
                out.append(Finding(point: .startupCohort,
                                   verdict: (countOK && durationOK) ? .green : .red, evidence: ev))
            }
        }

        // (2) IDR-start - not decidable from a trace, and no longer even guessable.
        //
        // DRIFT FIXED: this used to flag segments whose duration equalled the 4 s
        // non-keyframe HARD CUT and predict that the following segment started mid-GOP.
        // That cut no longer exists: `VortXHLSBoundaryPolicy.decision` only ever returns
        // `.open` or `.cut` when `incomingIsIDR && incomingHasKeyFlag`, and fails soft
        // past the frozen target instead of cutting on an arbitrary frame
        // (DVPlaybackPolicy.swift:1136-1140). Keeping the heuristic would have printed a
        // confident mid-GOP accusation about a mechanism the product retired.
        do {
            var ev = ["segment bytes are not in the trace; the IDR check needs the live channel (fMP4 parse)"]
            let longRun = s.publishedDurations
                .filter { $0.value >= Double(Contract.segmentFailSoftSecs) }.keys.sorted()
            if !longRun.isEmpty {
                ev.append("note: segments \(longRun) reached the \(Contract.segmentFailSoftSecs)s fail-soft ceiling;"
                    + " the product fails the remux soft there rather than cutting mid-GOP")
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
            // Resident-window arithmetic, DIAGNOSTIC ONLY.
            //
            // DRIFT FIXED: this block used to turn a purely arithmetic prediction into a
            // RED verdict, on the premise that "MEDIA-SEQUENCE stays 0, so the playlist
            // keeps advertising low segments after the resident window has slid past
            // them". The shipped playlist slides its MEDIA-SEQUENCE and drops the entries
            // it can no longer serve, and the window is anchored behind the client's
            // demonstrated fetch frontier, so the premise is simply no longer true. Only a
            // real 404 for a still-advertised id decides this point.
            if w.avgSegmentBytes > 0 {
                ev.append("DIAGNOSTIC: resident window ~= \(Contract.windowFloorMiB) MiB / \(w.avgSegmentBytes) B ≈ \(w.residentSegments) segments;"
                    + " playlist advertised up to absolute id \(w.advertisedMax) with MEDIA-SEQUENCE reaching \(s.maxMediaSequence)")
                if let evictedUpTo = w.evictedUpTo {
                    ev.append("DIAGNOSTIC prediction only: ids 0..\(evictedUpTo) may no longer be resident."
                        + " With a sliding MEDIA-SEQUENCE this is the EXPECTED steady state, not a violation.")
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
