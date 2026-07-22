import Foundation

enum SpoolLayout {
    struct Snapshot {
        let rootPath: String
        let rootExists: Bool
        let launchDirectories: [String]
        let sessionDirectories: [String]
        let bytes: Int
        let errors: [String]

        var hasOneActiveLaunchAndSession: Bool {
            rootExists && launchDirectories.count == 1 && sessionDirectories.count == 1 && errors.isEmpty
        }

        var isReclaimed: Bool {
            bytes == 0 && sessionDirectories.isEmpty && errors.isEmpty
        }

        var inspectionFailed: Bool {
            errors.contains {
                $0.hasPrefix("app container")
                    || $0.hasPrefix("VortXHLS root is not")
                    || $0.hasPrefix("directory discovery failed")
                    || $0.hasPrefix("enumeration failed")
                    || $0.hasPrefix("stat failed")
                    || $0.hasPrefix("could not enumerate")
                    || $0.hasPrefix("whole-root byte total overflow")
            }
        }
    }

    static func withinAdmissionCeiling(_ bytes: Int) -> Bool {
        bytes >= 0 && bytes <= Contract.spoolAdmissionBytes
    }

    /// Resolve the production root from the one authoritative app container and
    /// account every regular file beneath it. Directory ordering is sorted so
    /// evidence is deterministic across filesystems.
    static func inspect(containerPath: String) -> Snapshot {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: containerPath, isDirectory: true)
            .appendingPathComponent("Library/Caches/VortXHLS", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: containerPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Snapshot(rootPath: root.path, rootExists: false, launchDirectories: [],
                            sessionDirectories: [], bytes: 0,
                            errors: ["app container does not exist or is not a directory"])
        }
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return Snapshot(rootPath: root.path, rootExists: false, launchDirectories: [],
                            sessionDirectories: [], bytes: 0, errors: [])
        }
        guard isDirectory.boolValue else {
            return Snapshot(rootPath: root.path, rootExists: true, launchDirectories: [],
                            sessionDirectories: [], bytes: 0,
                            errors: ["VortXHLS root is not a directory"])
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var errors: [String] = []
        var launches: [String] = []
        var sessions: [String] = []
        do {
            let rootChildren = try manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(keys), options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in rootChildren {
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    errors.append("symlink at VortXHLS root: \(child.lastPathComponent)")
                } else if values.isDirectory == true && child.lastPathComponent.hasPrefix("launch-") {
                    launches.append(child.path)
                    let launchChildren = try manager.contentsOfDirectory(
                        at: child, includingPropertiesForKeys: Array(keys), options: [])
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for launchChild in launchChildren {
                        let childValues = try launchChild.resourceValues(forKeys: keys)
                        if childValues.isSymbolicLink == true {
                            errors.append("symlink in launch directory: \(launchChild.lastPathComponent)")
                        } else if childValues.isDirectory == true
                                    && launchChild.lastPathComponent.hasPrefix("session-") {
                            sessions.append(launchChild.path)
                        } else {
                            errors.append("unexpected launch entry: \(launchChild.lastPathComponent)")
                        }
                    }
                } else {
                    errors.append("unexpected VortXHLS root entry: \(child.lastPathComponent)")
                }
            }
        } catch {
            errors.append("directory discovery failed: \(error.localizedDescription)")
        }

        var bytes = 0
        if let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { url, error in
                errors.append("enumeration failed at \(url.path): \(error.localizedDescription)")
                return true
            }) {
            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true {
                        if !errors.contains(where: { $0.contains(url.lastPathComponent) }) {
                            errors.append("symlink below VortXHLS root: \(url.lastPathComponent)")
                        }
                    } else if values.isRegularFile == true {
                        guard let size = values.fileSize, size >= 0 else {
                            errors.append("stat failed at \(url.path): missing or negative file size")
                            continue
                        }
                        let (sum, overflow) = bytes.addingReportingOverflow(size)
                        if overflow {
                            errors.append("whole-root byte total overflow")
                            bytes = Int.max
                            break
                        }
                        bytes = sum
                    }
                } catch {
                    errors.append("stat failed at \(url.path): \(error.localizedDescription)")
                }
            }
        } else {
            errors.append("could not enumerate VortXHLS root")
        }

        return Snapshot(rootPath: root.path, rootExists: true,
                        launchDirectories: launches.sorted(), sessionDirectories: sessions.sorted(),
                        bytes: bytes, errors: errors)
    }
}

enum Live {
    struct Response {
        let status: Int
        let body: Data
        let transportError: String?

        var ok: Bool { status == 200 && transportError == nil }
        var describe: String {
            if let transportError {
                return "HTTP \(status >= 0 ? String(status) : "none"); transport error: \(transportError)"
            }
            return "HTTP \(status)"
        }
    }

    private final class ResponseLatch: @unchecked Sendable {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private var sealed = false
        private var response: Response?

        func publish(_ value: Response) {
            lock.lock()
            guard !sealed else { lock.unlock(); return }
            sealed = true
            response = value
            lock.unlock()
            signal.signal()
        }

        func wait(seconds: TimeInterval) -> Response? {
            guard signal.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return response
        }

        func sealTimeout(_ value: Response) -> Response {
            lock.lock(); defer { lock.unlock() }
            if !sealed { sealed = true; response = value }
            return response ?? value
        }
    }

    static func get(
        host: String = "127.0.0.1",
        port: Int,
        path: String,
        timeout: TimeInterval = 8,
        session: URLSession = .shared
    ) -> Response {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            return Response(status: -1, body: Data(), transportError: "malformed URL for \(path)")
        }
        let timeoutResponse = Response(
            status: -1, body: Data(), transportError: "no complete response within \(timeout)s")
        let latch = ResponseLatch()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            if let error {
                latch.publish(Response(status: status, body: Data(), transportError: error.localizedDescription))
                return
            }
            guard let http else {
                latch.publish(Response(status: -1, body: Data(), transportError: "missing HTTP response"))
                return
            }
            let body = data ?? Data()
            let expected = http.expectedContentLength
            if expected >= 0 && UInt64(body.count) != UInt64(expected) {
                latch.publish(Response(
                    status: status, body: Data(),
                    transportError: "incomplete body: received \(body.count) of \(expected) advertised bytes"))
                return
            }
            latch.publish(Response(status: status, body: body, transportError: nil))
        }
        task.resume()
        if let response = latch.wait(seconds: timeout) { return response }
        let sealed = latch.sealTimeout(timeoutResponse)
        task.cancel()
        return sealed
    }

    struct Outcome {
        let findings: [Finding]
        let infra: String?
    }

    private struct AudioTopology {
        let primaryLanguage: String
        let alternateLanguage: String
        let alternateURI: String
        let alternateID: Int
    }

    private struct SegmentFetch {
        let segment: Playlist.Segment
        let response: Response
    }

    static func evaluate(
        port: Int,
        trace: TraceSession,
        containerPath: String,
        session: URLSession = .shared
    ) -> Outcome {
        let masterResponse = get(port: port, path: "/master.m3u8", session: session)
        let mediaResponse = get(port: port, path: "/media.m3u8", session: session)
        if let error = masterResponse.transportError ?? mediaResponse.transportError {
            return Outcome(findings: [], infra: "manifest transport was incomplete: \(error)")
        }

        let masterText = String(data: masterResponse.body, encoding: .utf8) ?? ""
        let mediaText = String(data: mediaResponse.body, encoding: .utf8) ?? ""
        let media = Playlist.parseMedia(mediaText)
        let topology = audioTopology(masterText)

        var audioResponse: Response?
        var audio: Playlist.Parsed?
        if let topology, let path = requestPath(topology.alternateURI) {
            let response = get(port: port, path: path, session: session)
            if let error = response.transportError {
                return Outcome(findings: [], infra: "alternate playlist transport was incomplete: \(error)")
            }
            audioResponse = response
            if let text = String(data: response.body, encoding: .utf8) {
                audio = Playlist.parseMedia(text)
            }
        }

        var transportFailures: [String] = []
        func fetch(_ parsed: Playlist.Parsed?) -> [SegmentFetch] {
            guard let parsed else { return [] }
            return parsed.segments.compactMap { segment in
                guard let path = requestPath(segment.uri) else { return nil }
                let response = get(port: port, path: path, session: session)
                if let error = response.transportError {
                    transportFailures.append("\(path): \(error)")
                }
                return SegmentFetch(segment: segment, response: response)
            }
        }
        let videoFetches = fetch(mediaResponse.status == 200 ? media : nil)
        let audioFetches = fetch(audioResponse?.status == 200 ? audio : nil)

        var initResponse: Response?
        if let map = media.mapURI, let path = requestPath(map), mediaResponse.status == 200 {
            let response = get(port: port, path: path, session: session)
            if let error = response.transportError { transportFailures.append("\(path): \(error)") }
            initResponse = response
        }

        var findings: [Finding] = []

        // (1) The first response trace supplies the startup edge. The currently
        // advertised body supplies exact rendered duration and renderer invariants.
        var startupEvidence = [
            "GET /master.m3u8 -> \(masterResponse.describe)",
            "GET /media.m3u8 -> \(mediaResponse.describe)",
        ]
        var startupVerdict = Verdict.red
        if let first = trace.firstMediaResponse {
            startupEvidence.append("first response seq=\(first.sequence) segs=\(first.segmentCount) ended=\(first.ended)")
            startupEvidence.append("live rendered window=\(media.totalMs) ms across \(media.count) segments")
            startupEvidence.append("target=\(media.targetDuration.map(String.init) ?? "missing"), EVENT=\(media.hasPlaylistTypeEvent)")
            let livePlaylistValid = masterResponse.status == 200 && mediaResponse.status == 200
                && media.targetDuration == Contract.hlsTargetDuration
                && !media.hasPlaylistTypeEvent && media.isValidAdvertisedWindow
            if first.ended {
                let stableFinalWindow = livePlaylistValid && media.endlist
                    && first.sequence == 0 && media.mediaSequence == 0
                    && first.segmentCount == media.count
                if stableFinalWindow {
                    startupVerdict = Playlist.cohortReady(count: media.count, totalMs: media.totalMs)
                        ? .green : .exempt
                }
            } else {
                let ready = livePlaylistValid && first.sequence == 0
                    && first.segmentCount >= Contract.minStartupSegments
                    && Playlist.cohortReady(count: media.count, totalMs: media.totalMs)
                startupVerdict = ready ? .green : .red
            }
        } else {
            startupEvidence.append("missing first media response trace")
        }
        findings.append(Finding(point: .startupCohort, verdict: startupVerdict, evidence: startupEvidence))

        // (2) Every video URI in the current advertised range is checked.
        var idrEvidence: [String] = []
        var idrVerdict = Verdict.indeterminate
        if initResponse?.status == 200,
           let initData = initResponse?.body,
           let track = FMP4.videoTrack(inInit: initData),
           videoFetches.count == media.count,
           videoFetches.allSatisfy({ $0.response.status == 200 && $0.response.transportError == nil }) {
            var offenders: [Int] = []
            var undecidable: [Int] = []
            for fetch in videoFetches {
                switch FMP4.firstVideoSampleIsIDR(
                    fetch.response.body, videoTrackID: track.id, codec: track.codec) {
                case .some(true): break
                case .some(false): offenders.append(fetch.segment.id)
                case .none: undecidable.append(fetch.segment.id)
                }
            }
            idrEvidence.append("checked all \(videoFetches.count) advertised video URIs; non-IDR=\(offenders), undecidable=\(undecidable)")
            idrVerdict = offenders.isEmpty && undecidable.isEmpty ? .green : .red
        } else {
            idrEvidence.append("could not parse init or receive complete 200 for every advertised video segment")
        }
        findings.append(Finding(point: .idrStart, verdict: idrVerdict, evidence: idrEvidence))

        // (3) Use first requests from the trace, not the lowest id in a later
        // sliding playlist. The master must expose one in-band primary and one
        // different-known-language alternate.
        let firstVideo = trace.firstVideoSegReq
        let firstAudio = trace.audioSegReqs.first
        var firstEvidence = ["first video request id=\(firstVideo.map(String.init) ?? "missing")"]
        if let firstAudio {
            firstEvidence.append("first alternate request=/audio\(firstAudio.renditionID)-seg\(firstAudio.segmentID).m4s")
        } else {
            firstEvidence.append("no exact alternate segment request")
        }
        if let topology {
            firstEvidence.append("primary language=\(topology.primaryLanguage), alternate language=\(topology.alternateLanguage), URI=\(topology.alternateURI)")
        } else {
            firstEvidence.append("master does not contain exactly one in-band primary and one known-language alternate")
        }
        findings.append(Finding(
            point: .firstSegmentZero,
            verdict: firstVideo == 0 && firstAudio?.segmentID == 0
                && firstAudio?.renditionID == topology?.alternateID && topology != nil ? .green : .red,
            evidence: firstEvidence))

        // (4) Parse seq as the first absolute id and segs as cardinality, then
        // fetch every actual URI in both current advertised ranges.
        let allFetches = videoFetches + audioFetches
        let failed = allFetches.filter { $0.response.transportError == nil && $0.response.status != 200 }
        let windowsValid = mediaResponse.status == 200 && media.isValidAdvertisedWindow
            && !media.hasPlaylistTypeEvent
            && media.targetDuration == Contract.hlsTargetDuration
            && topology != nil && audioResponse?.status == 200
            && audio?.isValidAdvertisedWindow == true
            && audio?.hasPlaylistTypeEvent == false
            && audio?.targetDuration == Contract.hlsTargetDuration
            && audio?.advertisedRange == media.advertisedRange
            && audio?.segments.allSatisfy({ $0.renditionID == topology?.alternateID }) == true
        var availabilityEvidence = [
            "video range=\(describe(media.advertisedRange)), URIs=\(media.count), fetched=\(videoFetches.count)",
            "audio range=\(describe(audio?.advertisedRange)), URIs=\(audio?.count ?? 0), fetched=\(audioFetches.count)",
            "complete non-200 advertised responses=\(failed.map { "\($0.segment.uri)->\($0.response.status)" })",
        ]
        if !trace.advertisedFailures.isEmpty {
            availabilityEvidence.append("product trace advertised 404s=\(trace.advertisedFailures)")
        }
        findings.append(Finding(
            point: .noAdvertised404,
            verdict: windowsValid && failed.isEmpty && trace.advertisedFailures.isEmpty
                && allFetches.count == media.count + (audio?.count ?? 0) ? .green : .red,
            evidence: availabilityEvidence))

        // (5) Account the whole root derived from the authoritative container.
        let spool = SpoolLayout.inspect(containerPath: containerPath)
        let spoolOK = spool.hasOneActiveLaunchAndSession
            && SpoolLayout.withinAdmissionCeiling(spool.bytes)
        findings.append(Finding(
            point: .spoolBounded,
            verdict: spoolOK ? .green : .red,
            evidence: [
                "root=\(spool.rootPath), bytes=\(spool.bytes), ceiling=\(Contract.spoolAdmissionBytes)",
                "launches=\(spool.launchDirectories.count), sessions=\(spool.sessionDirectories.count), errors=\(spool.errors)",
            ]))

        findings.append(contentsOf: Trace.findings(trace).filter {
            $0.point == .startupLatency || $0.point == .failSoftCounted
        })

        let infra: String?
        if !transportFailures.isEmpty {
            infra = "incomplete advertised-resource transport: \(transportFailures.joined(separator: "; "))"
        } else if spool.inspectionFailed {
            infra = "could not safely inspect the whole VortXHLS root: \(spool.errors.joined(separator: "; "))"
        } else {
            infra = nil
        }
        return Outcome(findings: findings, infra: infra)
    }

    static func audioRenditionURI(_ master: String) -> String? {
        audioTopology(master)?.alternateURI
    }

    private static func audioTopology(_ master: String) -> AudioTopology? {
        let rows = master.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("#EXT-X-MEDIA:") && attributes($0)["TYPE"] == "AUDIO" }
        guard rows.count == 2 else { return nil }
        let parsed = rows.map(attributes)
        guard let primary = parsed.first(where: { $0["DEFAULT"] == "YES" && $0["URI"] == nil }),
              let alternate = parsed.first(where: { $0["DEFAULT"] != "YES" && $0["URI"] != nil }),
              let primaryLanguage = primary["LANGUAGE"],
              let alternateLanguage = alternate["LANGUAGE"],
              let uri = alternate["URI"],
              let alternateID = audioPlaylistRenditionID(uri),
              primary["GROUP-ID"] == alternate["GROUP-ID"],
              !isUnknownLanguage(primaryLanguage),
              !isUnknownLanguage(alternateLanguage),
              primaryLanguage.lowercased() != alternateLanguage.lowercased() else { return nil }
        return AudioTopology(
            primaryLanguage: primaryLanguage,
            alternateLanguage: alternateLanguage,
            alternateURI: uri,
            alternateID: alternateID)
    }

    private static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let source = line[line.index(after: colon)...]
        var fields: [String] = []
        var current = ""
        var quoted = false
        for character in source {
            if character == "\"" { quoted.toggle(); current.append(character) }
            else if character == "," && !quoted { fields.append(current); current = "" }
            else { current.append(character) }
        }
        fields.append(current)
        var output: [String: String] = [:]
        for field in fields {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let key = String(field[..<equals])
            var value = String(field[field.index(after: equals)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            output[key] = value
        }
        return output
    }

    private static func isUnknownLanguage(_ language: String) -> Bool {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty || ["und", "unk", "mis", "zxx"].contains(key)
    }

    private static func audioPlaylistRenditionID(_ uri: String) -> Int? {
        let name = uri.split(separator: "/").last.map(String.init) ?? uri
        guard name.hasPrefix("audio"), name.hasSuffix(".m3u8") else { return nil }
        let digits = String(name.dropFirst(5).dropLast(5))
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let id = Int(digits), id >= 0 else { return nil }
        return id
    }

    private static func requestPath(_ uri: String) -> String? {
        guard !uri.isEmpty, !uri.contains("://") else { return nil }
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        guard !path.split(separator: "/").contains("..") else { return nil }
        return path.hasPrefix("/") ? path : "/\(path)"
    }

    private static func describe(_ range: Range<Int>?) -> String {
        range.map { "[\($0.lowerBound),\($0.upperBound))" } ?? "invalid"
    }
}
