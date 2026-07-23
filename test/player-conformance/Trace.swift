import Foundation

struct TraceSession {
    struct MediaResponse: Equatable {
        let sequence: Int
        let segmentCount: Int
        let ended: Bool

        var advertisedRange: Range<Int>? {
            guard sequence >= 0, segmentCount >= 0 else { return nil }
            let (end, overflow) = sequence.addingReportingOverflow(segmentCount)
            return overflow ? nil : sequence..<end
        }
    }

    struct AudioResponse: Equatable {
        let renditionID: Int
        let sequence: Int
        let segmentCount: Int

        var advertisedRange: Range<Int>? {
            guard renditionID >= 0, sequence >= 0, segmentCount >= 0 else { return nil }
            let (end, overflow) = sequence.addingReportingOverflow(segmentCount)
            return overflow ? nil : sequence..<end
        }
    }

    struct TimeoutEvent: Equatable {
        let ordinal: Int
        let waitedMs: Int
        let requiredCount: Int
        let requiredDurationMs: Int
        let actualCount: Int
        let actualDurationMs: Int
    }

    struct AudioRequest: Equatable {
        let renditionID: Int
        let segmentID: Int
    }

    struct HTTPReceipt: Equatable {
        let ordinal: Int
        let path: String
        let status: Int
        let bytes: Int
        let curlRC: Int
    }

    var lines: [(t: Date?, raw: String)] = []
    var port: Int?
    var mountAt: Date?
    var readyAt: Date?
    var publishedDurationsMs: [Int: Int] = [:]
    var firstVideoSegReq: Int?
    var audioSegReqs: [AudioRequest] = []
    var mediaResponses: [MediaResponse] = []
    var audioResponses: [AudioResponse] = []
    var advertisedFailures: [String] = []
    var masterRequestOrdinals: [Int] = []
    var master404Ordinals: [Int] = []
    var timeoutEventOrdinals: [Int] = []
    var timeoutEvents: [TimeoutEvent] = []
    var completeHTTPReceipts: [HTTPReceipt] = []
    var parseErrors: [String] = []
    var sawEventPlaylist = false

    var firstMediaResponse: MediaResponse? { mediaResponses.first }
    var masterRequestCount: Int { masterRequestOrdinals.count }
}

enum Trace {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func timestamp(_ line: String) -> Date? {
        guard line.count >= 23 else { return nil }
        return stamp.date(from: String(line.prefix(23)))
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let matchRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    static func session(inFileAt path: String, index: Int = 0) -> TraceSession? {
        guard index >= 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let starts = all.indices.filter { all[$0].contains("hls server listening on 127.0.0.1:") }
        guard index < starts.count else { return nil }
        let lower = starts[index]
        let upper = index + 1 < starts.count ? starts[index + 1] : all.count
        return build(Array(all[lower..<upper]))
    }

    static func sessionCount(inFileAt path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("hls server listening on 127.0.0.1:") }.count
    }

    private static func build(_ raw: [String]) -> TraceSession {
        var session = TraceSession()
        var videoRanges: [Range<Int>] = []
        var audioRanges: [Int: [Range<Int>]] = [:]

        for (ordinal, line) in raw.enumerated() {
            session.lines.append((timestamp(line), line))
            if session.port == nil,
               let match = firstMatch(#"hls server listening on 127\.0\.0\.1:(\d+)"#, line) {
                session.port = Int(match[1])
            }
            if session.mountAt == nil, line.contains("plain-remux mount") {
                session.mountAt = timestamp(line)
            }
            if session.readyAt == nil, line.contains("readyToPlay -> play") {
                session.readyAt = timestamp(line)
            }
            if line.contains("#EXT-X-PLAYLIST-TYPE:EVENT") { session.sawEventPlaylist = true }

            if let match = firstMatch(
                #"hls media segment (\d+) published .*\([0-9]+B, ([0-9]+\.[0-9]+)s media\)$"#,
                line),
               let id = Int(match[1]),
               let milliseconds = Playlist.msFromSecondsText(match[2]) {
                session.publishedDurationsMs[id] = milliseconds
            } else if line.contains("hls media segment ") && line.contains(" published ") {
                session.parseErrors.append("malformed segment publication at ordinal \(ordinal)")
            }

            if let match = firstMatch(
                #"hls resp /media\.m3u8 seq=(\d+) segs=(\d+) ended=(true|false) ([0-9]+)B$"#,
                line),
               let sequence = Int(match[1]), let count = Int(match[2]) {
                let response = TraceSession.MediaResponse(
                    sequence: sequence, segmentCount: count, ended: match[3] == "true")
                session.mediaResponses.append(response)
                if let range = response.advertisedRange { videoRanges.append(range) }
            } else if line.contains("hls resp /media.m3u8") {
                session.parseErrors.append("malformed media response at ordinal \(ordinal)")
            }
            if let match = firstMatch(
                #"hls resp /audio(\d+)\.m3u8 seq=(\d+) segs=(\d+)$"#,
                line),
               let rendition = Int(match[1]),
               let sequence = Int(match[2]),
               let count = Int(match[3]) {
                let response = TraceSession.AudioResponse(
                    renditionID: rendition, sequence: sequence, segmentCount: count)
                session.audioResponses.append(response)
                if let range = response.advertisedRange {
                    audioRanges[rendition, default: []].append(range)
                }
            } else if line.contains("hls resp /audio") && line.contains(".m3u8") {
                session.parseErrors.append("malformed audio response at ordinal \(ordinal)")
            }

            if let match = firstMatch(#"hls req /seg(\d+)\.m4s$"#, line),
               let id = Int(match[1]) {
                if session.firstVideoSegReq == nil { session.firstVideoSegReq = id }
            } else if line.contains("hls req /seg") {
                session.parseErrors.append("malformed video segment request at ordinal \(ordinal)")
            }
            if let match = firstMatch(#"hls req /audio(\d+)-seg(\d+)\.m4s$"#, line),
               let rendition = Int(match[1]), let id = Int(match[2]) {
                session.audioSegReqs.append(.init(renditionID: rendition, segmentID: id))
            } else if line.contains("hls req /audio") && line.contains("-seg") {
                session.parseErrors.append("malformed audio segment request at ordinal \(ordinal)")
            }

            if line.hasSuffix("hls req /master.m3u8") { session.masterRequestOrdinals.append(ordinal) }
            else if line.contains("hls req /master.m3u8") {
                session.parseErrors.append("malformed master request at ordinal \(ordinal)")
            }
            if line.hasSuffix("hls 404 /master.m3u8") { session.master404Ordinals.append(ordinal) }
            else if line.contains("hls 404 /master.m3u8") {
                session.parseErrors.append("malformed master 404 at ordinal \(ordinal)")
            }
            if line.contains(Contract.cohortTimeoutEvent) {
                session.timeoutEventOrdinals.append(ordinal)
            }

            if let match = firstMatch(#"hls 404 /seg(\d+)\.m4s$"#, line),
               let id = Int(match[1]), videoRanges.contains(where: { $0.contains(id) }) {
                session.advertisedFailures.append("/seg\(id).m4s")
            } else if line.contains("hls 404 /seg") {
                session.parseErrors.append("malformed video segment 404 at ordinal \(ordinal)")
            }
            if let match = firstMatch(#"hls 404 /audio(\d+)-seg(\d+)\.m4s$"#, line),
               let rendition = Int(match[1]), let id = Int(match[2]),
               audioRanges[rendition]?.contains(where: { $0.contains(id) }) == true {
                session.advertisedFailures.append("/audio\(rendition)-seg\(id).m4s")
            } else if line.contains("hls 404 /audio") && line.contains("-seg") {
                session.parseErrors.append("malformed audio segment 404 at ordinal \(ordinal)")
            }

            if let match = firstMatch(
                #"^\[harness\] complete-http path=(/[^ ]+) status=(\d{3}) bytes=(\d+) curl_rc=(\d+)$"#,
                line),
               let status = Int(match[2]), let bytes = Int(match[3]), let curlRC = Int(match[4]) {
                session.completeHTTPReceipts.append(.init(
                    ordinal: ordinal, path: match[1], status: status, bytes: bytes, curlRC: curlRC))
            } else if line.contains("[harness] complete-http") {
                session.parseErrors.append("malformed complete HTTP receipt at ordinal \(ordinal)")
            }

            if let match = firstMatch(
                #"hls_startup_cohort_timeout waitedMs=(\d+) requiredCount=(\d+) requiredDurationMs=(\d+) actualCount=(\d+) actualDuration=(\d+)"#,
                line),
               let waited = Int(match[1]),
               let requiredCount = Int(match[2]),
               let requiredDuration = Int(match[3]),
               let actualCount = Int(match[4]),
               let actualDuration = Int(match[5]) {
                session.timeoutEvents.append(.init(
                    ordinal: ordinal,
                    waitedMs: waited,
                    requiredCount: requiredCount,
                    requiredDurationMs: requiredDuration,
                    actualCount: actualCount,
                    actualDurationMs: actualDuration))
            }
        }
        return session
    }

    static func startupRenderedMilliseconds(
        _ session: TraceSession,
        response: TraceSession.MediaResponse
    ) -> Int? {
        guard let range = response.advertisedRange else { return nil }
        var total = 0
        for id in range {
            guard let duration = session.publishedDurationsMs[id] else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(duration)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    static func failSoftTimeoutFinding(_ session: TraceSession) -> Finding {
        let events = session.timeoutEvents
        var evidence = [
            "timeout events=\(events.count), master requests=\(session.masterRequestCount), /master 404s=\(session.master404Ordinals.count), complete receipts=\(session.completeHTTPReceipts.count), ready=\(session.readyAt != nil)"
        ]
        guard events.count == 1,
              session.timeoutEventOrdinals.count == 1,
              session.timeoutEventOrdinals[0] == events[0].ordinal else {
            evidence.append("expected exactly one fully parseable \(Contract.cohortTimeoutEvent); raw markers=\(session.timeoutEventOrdinals.count)")
            return Finding(point: .failSoftCounted, verdict: .red, evidence: evidence)
        }
        let event = events[0]
        let fieldsMatch = event.waitedMs == Contract.sloMountToReadyMs
            && event.requiredCount == Contract.minStartupSegments
            && event.requiredDurationMs == Contract.minStartupMs
            && !Playlist.cohortReady(count: event.actualCount, totalMs: event.actualDurationMs)
        evidence.append(
            "event waitedMs=\(event.waitedMs) requiredCount=\(event.requiredCount) requiredDurationMs=\(event.requiredDurationMs) actualCount=\(event.actualCount) actualDuration=\(event.actualDurationMs)")
        let masterRequestBeforeEvent = session.masterRequestOrdinals.contains { $0 < event.ordinal }
        let master404AfterEvent = session.master404Ordinals.contains { $0 > event.ordinal }
        let complete404s = session.completeHTTPReceipts.filter {
            $0.path == "/master.m3u8" && $0.status == 404 && $0.bytes == 0
                && $0.curlRC == 0 && $0.ordinal > event.ordinal
        }
        if !masterRequestBeforeEvent { evidence.append("no startup /master.m3u8 request before the timeout event") }
        if !master404AfterEvent { evidence.append("no /master.m3u8 404 after the timeout event") }
        if complete404s.count != 1 {
            evidence.append("expected one complete bounded /master.m3u8 HTTP 404 receipt after the event")
        }
        if !session.parseErrors.isEmpty { evidence.append("parse errors=\(session.parseErrors)") }
        if session.readyAt != nil { evidence.append("readyToPlay appeared on the timeout path") }
        return Finding(
            point: .failSoftCounted,
            verdict: fieldsMatch && masterRequestBeforeEvent && master404AfterEvent
                && complete404s.count == 1 && session.parseErrors.isEmpty
                && session.readyAt == nil ? .green : .red,
            evidence: evidence)
    }

    static func findings(_ session: TraceSession) -> [Finding] {
        var output: [Finding] = []

        if let first = session.firstMediaResponse {
            var evidence = [
                "first /media.m3u8 response: seq=\(first.sequence) segs=\(first.segmentCount) ended=\(first.ended)",
                "advertised range: \(first.advertisedRange.map { "[\($0.lowerBound),\($0.upperBound))" } ?? "invalid")",
            ]
            if first.ended {
                if first.sequence != 0 || first.advertisedRange == nil {
                    evidence.append("ended startup response is not a valid absolute-zero range")
                    output.append(Finding(point: .startupCohort, verdict: .red, evidence: evidence))
                } else if let milliseconds = startupRenderedMilliseconds(session, response: first),
                   Playlist.cohortReady(count: first.segmentCount, totalMs: milliseconds) {
                    evidence.append("rendered startup duration=\(milliseconds) ms")
                    output.append(Finding(point: .startupCohort, verdict: .green, evidence: evidence))
                } else {
                    evidence.append("completed source is exempt from the live startup floors")
                    output.append(Finding(point: .startupCohort, verdict: .exempt, evidence: evidence))
                }
            } else if let milliseconds = startupRenderedMilliseconds(session, response: first) {
                evidence.append("rendered startup duration=\(milliseconds) ms")
                let ready = first.sequence == 0
                    && Playlist.cohortReady(count: first.segmentCount, totalMs: milliseconds)
                output.append(Finding(point: .startupCohort, verdict: ready ? .green : .red, evidence: evidence))
            } else {
                evidence.append("trace lacks every segment duration; exact duration needs the live playlist")
                output.append(Finding(point: .startupCohort, verdict: .indeterminate, evidence: evidence))
            }
        } else {
            output.append(Finding(point: .startupCohort, verdict: .indeterminate,
                                  evidence: ["no /media.m3u8 response in session"]))
        }

        output.append(Finding(point: .idrStart, verdict: .indeterminate,
                              evidence: ["segment bytes require the live channel"]))

        var firstEvidence: [String] = []
        let videoZero = session.firstVideoSegReq == 0
        firstEvidence.append("first video request id=\(session.firstVideoSegReq.map(String.init) ?? "missing")")
        let audioZero = session.audioSegReqs.first?.segmentID == 0
        if let audio = session.audioSegReqs.first {
            firstEvidence.append("first alternate request=/audio\(audio.renditionID)-seg\(audio.segmentID).m4s")
        } else {
            firstEvidence.append("no exact /audio<ID>-seg<ID>.m4s request")
        }
        output.append(Finding(point: .firstSegmentZero,
                              verdict: videoZero && audioZero ? .green : .red,
                              evidence: firstEvidence))

        output.append(Finding(
            point: .noAdvertised404,
            verdict: session.advertisedFailures.isEmpty ? .indeterminate : .red,
            evidence: session.advertisedFailures.isEmpty
                ? ["no advertised URI failure observed; complete coverage requires the live channel"]
                : ["advertised URIs returned 404: \(session.advertisedFailures)"]))

        output.append(Finding(point: .spoolBounded, verdict: .indeterminate,
                              evidence: ["whole-root byte accounting requires the live filesystem channel"]))

        if let mount = session.mountAt, let ready = session.readyAt {
            let interval = ready.timeIntervalSince(mount)
            let milliseconds = Int((interval * 1_000).rounded())
            output.append(Finding(
                point: .startupLatency,
                verdict: interval >= 0
                    && interval < Double(Contract.sloMountToReadyMs) / 1_000 ? .green : .red,
                evidence: ["mount -> readyToPlay = \(milliseconds) ms; readiness must win strictly before \(Contract.sloMountToReadyMs) ms"]))
        } else {
            output.append(Finding(point: .startupLatency, verdict: .indeterminate,
                                  evidence: ["missing mount or readyToPlay timestamp"]))
        }

        if session.readyAt != nil {
            let success = session.timeoutEventOrdinals.isEmpty
                && session.timeoutEvents.isEmpty && session.master404Ordinals.isEmpty
            output.append(Finding(
                point: .failSoftCounted,
                verdict: success ? .green : .red,
                evidence: ["success path: timeout events=\(session.timeoutEvents.count), /master 404s=\(session.master404Ordinals.count)"]))
        } else if !session.timeoutEventOrdinals.isEmpty
                    || !session.timeoutEvents.isEmpty || !session.master404Ordinals.isEmpty {
            output.append(failSoftTimeoutFinding(session))
        } else {
            output.append(Finding(point: .failSoftCounted, verdict: .indeterminate,
                                  evidence: ["neither success nor timeout terminal tuple is present"]))
        }
        guard session.parseErrors.isEmpty else {
            return output.map {
                Finding(
                    point: $0.point,
                    verdict: .red,
                    evidence: $0.evidence + ["trace parse errors=\(session.parseErrors)"])
            }
        }
        return output
    }
}
