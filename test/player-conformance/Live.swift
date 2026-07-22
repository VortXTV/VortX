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

    /// A probe result that can EXPLAIN itself. `status == -1` means the request never
    /// got an HTTP response at all, and `transportError` says why. Collapsing that case
    /// to a bare `nil` is exactly what let "the live server was unreachable" masquerade
    /// as a contract verdict; every failure here has to stay attributable.
    struct Response {
        let status: Int
        let body: Data
        let transportError: String?
        var ok: Bool { status == 200 }
        /// Short description for evidence and INFRA lines.
        var describe: String { transportError.map { "transport error: \($0)" } ?? "HTTP \(status)" }
    }

    static func get(host: String = "127.0.0.1", port: Int, path: String, timeout: TimeInterval = 8) -> Response {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            return Response(status: -1, body: Data(), transportError: "malformed URL for \(path)")
        }
        var out = Response(status: -1, body: Data(), transportError: "no response within \(Int(timeout))s")
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let http = resp as? HTTPURLResponse {
                out = Response(status: http.statusCode, body: data ?? Data(), transportError: nil)
            } else if let err {
                out = Response(status: -1, body: Data(), transportError: err.localizedDescription)
            }
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

    /// The result of a live battery. `infra` non-nil means the channel could NOT
    /// OBSERVE the session and no verdict in `findings` may be trusted or reported as
    /// a product signal: the caller must exit 3, not 1.
    ///
    /// The distinction this type exists to encode, which the harness previously got
    /// wrong: "there is nothing to measure" (point 5 with no spool directory, a
    /// legitimate INDETERMINATE) versus "I could not reach the thing I meant to
    /// measure" (the live server was gone at probe time, an INFRA failure). The second
    /// case degrading to INDETERMINATE, and the run then exiting 1 with "gate ran and
    /// decided", is worse than crashing because it looks authoritative.
    struct Outcome {
        let findings: [Finding]
        let infra: String?
    }

    /// Full live battery. `trace` supplies mount/ready timing (6) and the
    /// success-path event count (7); the loopback fetches decide 1 (exact ms), 2,
    /// 3 and 4; `spoolPath` measures 5.
    static func evaluate(port: Int, trace: TraceSession, spoolPath: String?, spoolBoundMiB: Int, segmentSampleCap: Int) -> Outcome {
        var out: [Finding] = []
        // Set by any check that could not REACH what it meant to measure. Distinct from
        // a legitimate INDETERMINATE ("there is nothing to measure", e.g. no spool dir).
        var probeInfra: String?
        var audioFetchInfra: String?

        let master = get(port: port, path: "/master.m3u8")
        let masterText = String(data: master.body, encoding: .utf8) ?? ""
        let media = get(port: port, path: "/media.m3u8")

        // HARD GATE. The media playlist is the spine of this channel: points 2, 3 and
        // point 4's active strand all enumerate advertised segments from it. If it is
        // unreachable there is nothing to probe, and the ONLY honest report is INFRA.
        // Never degrade to INDETERMINATE here and never let point 4 stand on its
        // latent (predicted) strand alone, which we specifically decided must not be
        // a verdict by itself.
        guard media.ok, let mediaText = String(data: media.body, encoding: .utf8) else {
            let why = """
            could not fetch the live media playlist from the session's own HLS server.
              GET http://127.0.0.1:\(port)/media.m3u8 -> \(media.describe)
              GET http://127.0.0.1:\(port)/master.m3u8 -> \(master.describe)
            The port above was read from the session's `hls server listening` line. The
            server is gone, was never reachable, or the session was torn down before the
            probe ran. Points 2, 3 and point 4's ACTIVE strand cannot be observed at all,
            so no product verdict is reported for them. This is an observation failure,
            NOT a player regression.
            """
            return Outcome(findings: out, infra: why)
        }
        let parsed: Playlist.Parsed? = Playlist.parseMedia(mediaText)

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
                var unreachable = 0
                var lastUnreachableWhy = ""
                for seg in p.segments {
                    if checked >= segmentSampleCap { break }
                    let r = get(port: port, path: "/seg\(seg.id).m4s")
                    if r.transportError != nil {
                        unreachable += 1; lastUnreachableWhy = r.describe; continue
                    }
                    guard r.ok else { evictedSkipped += 1; continue }
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
                if unreachable > 0 {
                    ev.append("\(unreachable) segment fetches could not reach the server (\(lastUnreachableWhy))")
                }
                if checked == 0 {
                    // Could not read a single segment's bytes. Whether the server died or
                    // every advertised segment was evicted, this channel did not OBSERVE
                    // point 2 and must not imply it did.
                    probeInfra = probeInfra ?? ("point 2 could not read the bytes of a single advertised segment "
                        + "(\(p.segments.count) advertised, \(evictedSkipped) unfetchable, \(unreachable) unreachable"
                        + (lastUnreachableWhy.isEmpty ? "" : ": \(lastUnreachableWhy)") + ").")
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
                let a = get(port: port, path: "/\(audioURI)")
                if a.ok, let atext = String(data: a.body, encoding: .utf8) {
                    let ap = Playlist.parseMedia(atext)
                    let firstAudio = ap.segments.map(\.id).min() ?? -1
                    ev.append("audio rendition lowest advertised id: \(firstAudio)")
                    if firstAudio != 0 { verdict = .red }
                } else {
                    // The master ADVERTISES this rendition, so failing to fetch it is a
                    // reachability failure, not evidence about the contract.
                    audioFetchInfra = "the master advertises an alternate audio rendition at /\(audioURI) "
                                    + "but it could not be fetched: \(a.describe)"
                    ev.append("audio playlist fetch FAILED: \(a.describe)")
                }
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
            var unreachable: [(id: Int, why: String)] = []
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
                    // A TRANSPORT failure is not a 404: it means we could not ask the
                    // question. Track it separately so it can never be scored as a
                    // contract violation.
                    if r.transportError != nil { unreachable.append((id, r.describe)) }
                    probed.append((id, r.status))
                }
                probed.sort { $0.id < $1.id }
                let missing = probed.filter { $0.status != 200 && $0.status != -1 }
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

            // --- verdict.
            // A -1 status is a TRANSPORT failure, never a 404, so it can never count as
            // the active strand firing.
            let activeFired = probed.contains { $0.status != 200 && $0.status != -1 }
            let activeRan = !probed.isEmpty && unreachable.count < probed.count
            let latentFired = w.evictedUpTo != nil || !w.observed404s.isEmpty

            if !unreachable.isEmpty {
                ev.append("ACTIVE: \(unreachable.count) of \(probed.count) probes could not reach the server at all "
                          + "(e.g. seg\(unreachable[0].id): \(unreachable[0].why))")
            }

            if !activeRan {
                // The active strand could not run. The latent strand is a PREDICTION
                // from the resident-window arithmetic, and we decided deliberately that
                // a prediction must not stand as a verdict on its own: a correct
                // implementation whose real retention exceeds the estimate's floor would
                // be scored RED for no observed failure. So this is INFRA, not a verdict.
                probeInfra = "point 4's ACTIVE strand could not run: "
                           + (probed.isEmpty
                              ? "no advertised segments could be enumerated to probe."
                              : "every one of the \(probed.count) segment probes failed to reach the server "
                                + "(e.g. seg\(unreachable.first?.id ?? -1): \(unreachable.first?.why ?? "unknown")).")
                           + " Refusing to report point 4 RED from the latent arithmetic alone."
                verdict = .indeterminate
                ev.append("point 4 NOT DECIDED: the active strand could not run, and the latent strand is a prediction that may not stand alone.")
            } else if activeFired || latentFired {
                verdict = .red
            } else {
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
        return Outcome(findings: out, infra: probeInfra ?? audioFetchInfra)
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
