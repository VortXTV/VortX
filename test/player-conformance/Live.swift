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

    /// Ceiling on point 4's active probes, so a long EVENT playlist with a large
    /// predicted-evicted range cannot turn one gate run into hundreds of fetches.
    /// The targets are chosen most-at-risk first (see the point 4 block), so the cap
    /// trims the least informative probes.
    static let availabilityProbeCap = 16

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
            var checked = 0, indeterminate = 0, evictedSkipped = 0
            if let p = parsed {
                // Walk the advertised list and check the first `segmentSampleCap`
                // segments that are actually RETRIEVABLE, rather than the first
                // `segmentSampleCap` advertised ids. Once the run is sized so the
                // window genuinely evicts (which point 4 requires), the lowest
                // advertised ids are exactly the evicted ones, and a fixed
                // `prefix(cap)` spends its whole budget on 404s and reports
                // "checked 0 segments" - point 2 stops being decided at all.
                // Same predicate, same verdict mapping: only the aim changes.
                for seg in p.segments {
                    if checked >= segmentSampleCap { break }
                    guard let r = get(port: port, path: "/seg\(seg.id).m4s") else { continue }
                    guard r.status == 200 else { evictedSkipped += 1; continue }
                    checked += 1
                    switch FMP4.firstSampleIsSync(r.body) {
                    case .some(true): break
                    case .some(false): offenders.append(seg.id)
                    case .none: indeterminate += 1
                    }
                }
                ev.append("checked \(checked) retrievable segments (sample cap \(segmentSampleCap)); non-IDR starts: \(offenders); indeterminate: \(indeterminate)")
                if evictedSkipped > 0 {
                    ev.append("skipped \(evictedSkipped) advertised-but-unfetchable segments while sampling (that is point 4's finding, not point 2's)")
                }
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

        // (4) Availability window. TWO independent strands, ORed into one verdict:
        //
        //   ACTIVE  - GET advertised segments and see whether any 404. Aimed at the
        //             ids the resident-window arithmetic predicts are already gone,
        //             plus the lowest advertised id, the highest, and a spread across
        //             the advertised range. Probing ONLY the lowest id (what this
        //             check used to do) aims at whichever segment is most likely to
        //             still be resident, so it could report GREEN on a session the
        //             trace channel proved RED from the identical log.
        //   LATENT  - the resident-window arithmetic itself, taken from
        //             `Trace.availabilityWindow` so both channels share one
        //             implementation, plus any advertised-id 404 the request log
        //             actually recorded during playback.
        //
        // RED if EITHER strand fires. Both are always printed, so a reader can tell
        // PROOF (a real 404) from PREDICTION (arithmetic) - including when they
        // disagree, which is itself a fact about the retention behaviour.
        //
        // This widens what is OBSERVED. The bar is unchanged: contract point 4 has
        // always been "no advertised-segment 404 through the RFC 8216 s6.2.2
        // availability window" (Contract.swift), and neither its text nor its
        // threshold is touched here.
        do {
            var ev: [String] = []
            var verdict = Verdict.indeterminate
            let w = Trace.availabilityWindow(trace)

            // --- ACTIVE strand
            var probed: [(id: Int, status: Int)] = []
            var atRisk = Set<Int>()
            if let p = parsed, !p.segments.isEmpty {
                let ids = p.segments.map(\.id).sorted()
                // Ordered MOST-AT-RISK FIRST so `availabilityProbeCap` trims the least
                // informative probes rather than the ones aimed at the defect.
                var targets: [Int] = []
                func add(_ id: Int) { if !targets.contains(id) { targets.append(id) } }
                atRisk = Set(w.predictedEvictedIds).intersection(ids)
                for id in atRisk.sorted() { add(id) }        // predicted evicted
                if let lowest = ids.first { add(lowest) }    // the classic seg0 case
                let step = max(1, ids.count / 6)             // spread across the range
                for i in stride(from: 0, to: ids.count, by: step) { add(ids[i]) }
                if let highest = ids.last { add(highest) }   // the newest published

                for id in targets.prefix(Live.availabilityProbeCap) {
                    let r = get(port: port, path: "/seg\(id).m4s")
                    probed.append((id, r?.status ?? -1))
                }
                probed.sort { $0.id < $1.id }
                let missing = probed.filter { $0.status != 200 }
                ev.append("ACTIVE: probed \(probed.count) advertised ids \(probed.map(\.id)) "
                          + "(lowest + highest + \(atRisk.count) predicted-evicted + a spread); "
                          + "non-200: \(missing.isEmpty ? "none" : missing.map { "seg\($0.id)->HTTP\($0.status)" }.joined(separator: ", "))")
                if !missing.isEmpty {
                    ev.append("PROOF: an ADVERTISED segment is not fetchable -> availability-window violation (RFC 8216 s6.2.2)")
                }
            } else {
                ev.append("ACTIVE: no live media playlist to enumerate advertised segments")
            }

            // --- LATENT strand (identical arithmetic to the trace channel)
            if !w.observed404s.isEmpty {
                ev.append("LATENT: advertised segments that 404'd during playback: \(w.observed404s)")
            }
            if w.avgSegmentBytes > 0 {
                ev.append("LATENT: resident window ~= \(Contract.windowFloorMiB) MiB / \(w.avgSegmentBytes) B ≈ \(w.residentSegments) segments; playlist advertised up to \(w.advertisedMax) (MEDIA-SEQUENCE stays 0)")
                if let evictedUpTo = w.evictedUpTo {
                    ev.append("LATENT: segment 0..\(evictedUpTo) advertised but evicted -> a client that re-requests one (RFC 8216 s6.2.2 window) gets a 404")
                }
            } else {
                ev.append("LATENT: no served-segment byte sizes in the log yet; window arithmetic unavailable")
            }

            // --- verdict: either strand is sufficient
            let activeFired = probed.contains { $0.status != 200 }
            let latentFired = w.evictedUpTo != nil || !w.observed404s.isEmpty
            if activeFired || latentFired {
                verdict = .red
            } else if !probed.isEmpty {
                verdict = .green
            }

            // --- a disagreement between the strands is information, not something to
            //     quietly resolve in favour of whichever strand is more convenient.
            if latentFired && !activeFired && !probed.isEmpty {
                let stillResident = Set(probed.filter { $0.status == 200 }.map(\.id))
                    .intersection(atRisk).sorted()
                ev.append("NOTE: the strands DISAGREE. The arithmetic predicts 0..\(w.evictedUpTo.map(String.init) ?? "?") are evicted, "
                          + "but \(stillResident.isEmpty ? "no probed at-risk id" : "ids \(stillResident)") still returned 200. "
                          + "Either the window retains more than the \(Contract.windowFloorMiB) MiB floor the estimate uses, or eviction "
                          + "had not run yet. RED stands on the latent strand: the playlist advertises a range the window is not sized to guarantee.")
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
