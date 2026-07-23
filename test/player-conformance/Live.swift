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

    static func isCanonicalUUIDDirectory(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix.count == 36,
              suffix != "00000000-0000-0000-0000-000000000000",
              let value = UUID(uuidString: suffix) else { return false }
        return value.uuidString == suffix
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
                } else if values.isDirectory == true
                            && isCanonicalUUIDDirectory(child.lastPathComponent, prefix: "launch-") {
                    launches.append(child.path)
                    let launchChildren = try manager.contentsOfDirectory(
                        at: child, includingPropertiesForKeys: Array(keys), options: [])
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for launchChild in launchChildren {
                        let childValues = try launchChild.resourceValues(forKeys: keys)
                        if childValues.isSymbolicLink == true {
                            errors.append("symlink in launch directory: \(launchChild.lastPathComponent)")
                        } else if childValues.isDirectory == true
                                    && isCanonicalUUIDDirectory(
                                        launchChild.lastPathComponent, prefix: "session-") {
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
        private let deadline: DispatchTime
        private var sealed = false
        private var response: Response?

        init(deadline: DispatchTime) {
            self.deadline = deadline
        }

        func publish(_ value: Response) {
            let completedAt = DispatchTime.now()
            lock.lock()
            guard !sealed, completedAt < deadline else { lock.unlock(); return }
            sealed = true
            response = value
            lock.unlock()
            signal.signal()
        }

        func wait(or timeout: Response) -> Response {
            let completed = signal.wait(timeout: deadline) == .success
            lock.lock(); defer { lock.unlock() }
            if completed, let response { return response }
            sealed = true
            response = timeout
            return timeout
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
        let deadline = DispatchTime.now() + timeout
        let latch = ResponseLatch(deadline: deadline)
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
        let response = latch.wait(or: timeoutResponse)
        if response.transportError == timeoutResponse.transportError { task.cancel() }
        return response
    }

    struct Outcome {
        let findings: [Finding]
        let infra: String?
    }

    struct CaptureOutcome {
        let passed: Bool
        let evidence: [String]
    }

    private struct AudioTopology {
        let groupID: String
        let primaryLanguage: String
        let alternateLanguage: String
        let alternateURI: String
        let alternateID: Int
    }

    private struct Variant {
        let uri: String
        let codecs: [String]
        let audioGroup: String
    }

    private struct MasterTopology {
        let variants: [Variant]
        let audio: AudioTopology?
        let errors: [String]

        var isValid: Bool {
            errors.isEmpty && !variants.isEmpty && variants.count <= 2 && audio != nil
        }
    }

    private struct PlaylistFetch {
        let uri: String
        let response: Response
        let parsed: Playlist.Parsed
    }

    private struct Publication {
        let masterResponse: Response
        let topology: MasterTopology
        let variants: [PlaylistFetch]
        let audio: PlaylistFetch?

        var isCoherent: Bool {
            guard masterResponse.ok, topology.isValid,
                  variants.count == topology.variants.count,
                  variants.allSatisfy({ $0.response.ok && $0.parsed.isValidAdvertisedWindow }),
                  let audio, audio.response.ok, audio.parsed.isValidAdvertisedWindow,
                  let firstRange = variants.first?.parsed.advertisedRange else { return false }
            return variants.allSatisfy {
                $0.parsed.advertisedRange == firstRange
                    && $0.parsed.targetDuration == Contract.hlsTargetDuration
                    && !$0.parsed.hasPlaylistTypeEvent
            } && audio.parsed.advertisedRange == firstRange
                && audio.parsed.targetDuration == Contract.hlsTargetDuration
                && !audio.parsed.hasPlaylistTypeEvent
                && audio.parsed.segments.allSatisfy {
                    $0.renditionID == topology.audio?.alternateID
                }
        }
    }

    private struct ResourceProbe {
        let responses: [String: Response]
        let invalidURIs: [String]

        var allComplete200: Bool {
            invalidURIs.isEmpty && !responses.isEmpty
                && responses.values.allSatisfy(\.ok)
        }
    }

    static func captureStartup(
        port: Int,
        directoryPath: String,
        session: URLSession = .shared
    ) -> CaptureOutcome {
        let master = get(port: port, path: "/master.m3u8", timeout: 40, session: session)
        let publication = fetchPublication(
            port: port, masterResponse: master, attempts: 6, session: session)
        var evidence = publicationEvidence(publication, label: "startup")
        guard startupMeetsMinimalContract(publication) else {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try publication.masterResponse.body.write(
                    to: directory.appendingPathComponent("master.failed.m3u8"), options: .atomic)
                evidence.append("saved rejected master bytes for diagnosis")
            } catch {
                evidence.append("could not preserve rejected master: \(error.localizedDescription)")
            }
            evidence.append("startup capture did not prove one immutable, minimal sequence-zero cohort meeting both floors")
            return CaptureOutcome(passed: false, evidence: evidence)
        }
        do {
            try write(publication: publication, to: directoryPath)
            evidence.append("saved immutable startup publication at \(directoryPath)")
            return CaptureOutcome(passed: true, evidence: evidence)
        } catch {
            evidence.append("capture write failed: \(error.localizedDescription)")
            return CaptureOutcome(passed: false, evidence: evidence)
        }
    }

    static func verifyCapturedResources(
        port: Int,
        directoryPath: String,
        receiptPath: String,
        session: URLSession = .shared
    ) -> CaptureOutcome {
        guard let publication = loadPublication(from: directoryPath) else {
            return CaptureOutcome(passed: false, evidence: ["captured publication is missing or malformed"])
        }
        let probe = fetchResources(port: port, publication: publication, session: session)
        let manifestResponses = publication.topology.variants.map {
            get(port: port, path: requestPath($0.uri) ?? "", session: session)
        } + [get(
            port: port,
            path: requestPath(publication.topology.audio?.alternateURI ?? "") ?? "",
            session: session,
        )]
        let passed = publication.isCoherent && probe.allComplete200
            && manifestResponses.allSatisfy(\.ok)
        var evidence = [
            "retained manifest responses=\(manifestResponses.map(\.describe))",
            "retained resource count=\(probe.responses.count), invalid=\(probe.invalidURIs)",
        ]
        if passed {
            let receipt = "retained-advertised-resources port=\(port) status=PASS\n"
            do {
                try Data(receipt.utf8).write(
                    to: URL(fileURLWithPath: receiptPath), options: .atomic)
                evidence.append("wrote retained-window receipt \(receiptPath)")
            } catch {
                evidence.append("receipt write failed: \(error.localizedDescription)")
                return CaptureOutcome(passed: false, evidence: evidence)
            }
        }
        return CaptureOutcome(passed: passed, evidence: evidence)
    }

    static func evaluate(
        port: Int,
        trace: TraceSession,
        containerPath: String,
        startupDirectoryPath: String?,
        retainedReceiptPath: String?,
        session: URLSession = .shared
    ) -> Outcome {
        let current = fetchPublication(port: port, attempts: 6, session: session)
        let currentResources = fetchResources(port: port, publication: current, session: session)
        let startup = startupDirectoryPath.flatMap(loadPublication)
        let retainedReceipt = retainedReceiptPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        let retainedProven = retainedReceipt
            == "retained-advertised-resources port=\(port) status=PASS\n"

        var findings: [Finding] = []

        var startupEvidence = startup.map { publicationEvidence($0, label: "captured first") }
            ?? ["missing immutable startup capture"]
        var startupVerdict = Verdict.red
        if let startup, let captured = startup.variants.first?.parsed,
           let first = trace.firstMediaResponse {
            startupEvidence.append(
                "trace first response seq=\(first.sequence) segs=\(first.segmentCount) ended=\(first.ended)")
            let sameResponse = first.sequence == captured.mediaSequence
                && first.segmentCount == captured.count
                && first.ended == captured.endlist
            if captured.endlist && first.ended && captured.mediaSequence == 0 && sameResponse {
                startupVerdict = Playlist.cohortReady(count: captured.count, totalMs: captured.totalMs)
                    ? .green : .exempt
            } else if startupMeetsMinimalContract(startup) && sameResponse {
                let rendered = Trace.startupRenderedMilliseconds(trace, response: first)
                startupEvidence.append(
                    "trace rendered startup=\(rendered.map(String.init) ?? "missing") ms; captured=\(captured.totalMs) ms")
                if rendered == captured.totalMs { startupVerdict = .green }
            }
        }
        findings.append(Finding(
            point: .startupCohort, verdict: startupVerdict, evidence: startupEvidence))

        var nonIDR: [String] = []
        var undecidable: [String] = []
        for variant in current.variants {
            guard let mapURI = variant.parsed.mapURI,
                  let mapPath = requestPath(mapURI),
                  let initResponse = currentResources.responses[mapPath], initResponse.ok,
                  let track = FMP4.videoTrack(inInit: initResponse.body) else {
                undecidable.append("\(variant.uri):init")
                continue
            }
            for segment in variant.parsed.segments {
                guard let path = requestPath(segment.uri),
                      let response = currentResources.responses[path], response.ok else {
                    undecidable.append("\(variant.uri):\(segment.uri)")
                    continue
                }
                switch FMP4.firstVideoSampleIsIDR(
                    response.body, videoTrackID: track.id, codec: track.codec) {
                case .some(true): break
                case .some(false): nonIDR.append("\(variant.uri):\(segment.uri)")
                case .none: undecidable.append("\(variant.uri):\(segment.uri)")
                }
            }
        }
        findings.append(Finding(
            point: .idrStart,
            verdict: current.isCoherent && nonIDR.isEmpty && undecidable.isEmpty ? .green : .red,
            evidence: [
                "checked variants=\(current.variants.count), non-IDR=\(nonIDR), undecidable=\(undecidable)",
            ]))

        let topology = current.topology.audio
        let firstAudio = trace.audioSegReqs.first
        let primaryAAC = current.variants.allSatisfy { fetch in
            guard let map = fetch.parsed.mapURI, let path = requestPath(map),
                  let response = currentResources.responses[path], response.ok else { return false }
            return exactlyOneMP4AAudioTrack(in: response.body)
        }
        let alternateAAC: Bool = {
            guard let audio = current.audio, let map = audio.parsed.mapURI,
                  let path = requestPath(map), let response = currentResources.responses[path],
                  response.ok else { return false }
            return exactlyOneMP4AAudioTrack(in: response.body)
        }()
        findings.append(Finding(
            point: .firstSegmentZero,
            verdict: trace.firstVideoSegReq == 0 && firstAudio?.segmentID == 0
                && firstAudio?.renditionID == topology?.alternateID
                && topology != nil && primaryAAC && alternateAAC ? .green : .red,
            evidence: [
                "first video=\(trace.firstVideoSegReq.map(String.init) ?? "missing"), first audio=\(String(describing: firstAudio))",
                "languages=\(topology?.primaryLanguage ?? "missing")/\(topology?.alternateLanguage ?? "missing"), primaryAAC=\(primaryAAC), alternateAAC=\(alternateAAC)",
            ]))

        let currentEvidence = publicationEvidence(current, label: "current") + [
            "advertised resources=\(currentResources.responses.count), invalid URIs=\(currentResources.invalidURIs)",
            "retained startup window receipt=\(retainedProven)",
            "trace advertised failures=\(trace.advertisedFailures)",
        ]
        findings.append(Finding(
            point: .noAdvertised404,
            verdict: current.isCoherent && currentResources.allComplete200
                && retainedProven && trace.advertisedFailures.isEmpty ? .green : .red,
            evidence: currentEvidence))

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

        let infra = spool.inspectionFailed
            ? "could not inspect the authoritative VortXHLS root: \(spool.errors.joined(separator: "; "))"
            : nil
        return Outcome(findings: findings, infra: infra)
    }

    static func audioRenditionURI(_ master: String) -> String? {
        let topology = parseMaster(master)
        return topology.isValid ? topology.audio?.alternateURI : nil
    }

    private static func fetchPublication(
        port: Int,
        masterResponse suppliedMaster: Response? = nil,
        attempts: Int,
        session: URLSession
    ) -> Publication {
        let masterResponse = suppliedMaster ?? get(port: port, path: "/master.m3u8", session: session)
        let masterText = String(data: masterResponse.body, encoding: .utf8) ?? ""
        let topology = parseMaster(masterText)
        var last = Publication(
            masterResponse: masterResponse, topology: topology, variants: [], audio: nil)
        guard masterResponse.ok, topology.isValid else { return last }

        for attempt in 0..<max(1, attempts) {
            let variants = topology.variants.map {
                fetchPlaylist(uri: $0.uri, port: port, session: session)
            }
            let audio = topology.audio.map {
                fetchPlaylist(uri: $0.alternateURI, port: port, session: session)
            }
            last = Publication(
                masterResponse: masterResponse, topology: topology, variants: variants, audio: audio)
            if last.isCoherent { return last }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.05) }
        }
        return last
    }

    private static func fetchPlaylist(
        uri: String,
        port: Int,
        session: URLSession
    ) -> PlaylistFetch {
        guard let path = requestPath(uri) else {
            let response = Response(status: -1, body: Data(), transportError: "invalid advertised URI")
            return PlaylistFetch(uri: uri, response: response, parsed: Playlist.parseMedia(""))
        }
        let response = get(port: port, path: path, session: session)
        let text = String(data: response.body, encoding: .utf8) ?? ""
        return PlaylistFetch(uri: uri, response: response, parsed: Playlist.parseMedia(text))
    }

    private static func fetchResources(
        port: Int,
        publication: Publication,
        session: URLSession
    ) -> ResourceProbe {
        var paths = Set<String>()
        var invalid: [String] = []
        for playlist in publication.variants + (publication.audio.map { [$0] } ?? []) {
            let uris = [playlist.parsed.mapURI].compactMap { $0 } + playlist.parsed.segments.map(\.uri)
            for uri in uris {
                if let path = requestPath(uri) { paths.insert(path) }
                else { invalid.append(uri) }
            }
        }
        var responses: [String: Response] = [:]
        for path in paths.sorted() {
            responses[path] = get(port: port, path: path, timeout: 12, session: session)
        }
        return ResourceProbe(responses: responses, invalidURIs: invalid.sorted())
    }

    private static func startupMeetsMinimalContract(_ publication: Publication) -> Bool {
        guard publication.isCoherent, let first = publication.variants.first?.parsed else { return false }
        if first.endlist {
            return first.mediaSequence == 0
                && publication.variants.allSatisfy { $0.parsed.endlist }
                && publication.audio?.parsed.endlist == true
        }
        let renditions = publication.variants.map(\.parsed)
            + (publication.audio.map { [$0.parsed] } ?? [])
        guard first.mediaSequence == 0,
              renditions.allSatisfy({
                  $0.mediaSequence == 0 && !$0.endlist
                      && Playlist.cohortReady(count: $0.count, totalMs: $0.totalMs)
              }) else { return false }
        return renditions.contains { Playlist.isMinimalStartupCohort($0) }
    }

    private static func publicationEvidence(_ publication: Publication, label: String) -> [String] {
        var evidence = [
            "\(label) master=\(publication.masterResponse.describe), masterErrors=\(publication.topology.errors)",
        ]
        for playlist in publication.variants {
            evidence.append(
                "\(label) \(playlist.uri)=\(playlist.response.describe) range=\(describe(playlist.parsed.advertisedRange)) count=\(playlist.parsed.count) ms=\(playlist.parsed.totalMs) errors=\(playlist.parsed.errors)")
        }
        if let audio = publication.audio {
            evidence.append(
                "\(label) \(audio.uri)=\(audio.response.describe) range=\(describe(audio.parsed.advertisedRange)) count=\(audio.parsed.count) ms=\(audio.parsed.totalMs) errors=\(audio.parsed.errors)")
        }
        return evidence
    }

    private static func write(publication: Publication, to directoryPath: String) throws {
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        if manager.fileExists(atPath: directory.path) {
            let existing = try manager.contentsOfDirectory(atPath: directory.path)
            guard existing.isEmpty else {
                throw NSError(domain: "PlayerConformance", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "capture directory is not empty"])
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try publication.masterResponse.body.write(
            to: directory.appendingPathComponent("master.m3u8"), options: .atomic)
        for (index, playlist) in publication.variants.enumerated() {
            try playlist.response.body.write(
                to: directory.appendingPathComponent("variant-\(index).m3u8"), options: .atomic)
        }
        if let audio = publication.audio {
            try audio.response.body.write(
                to: directory.appendingPathComponent("audio.m3u8"), options: .atomic)
        }
    }

    private static func loadPublication(from directoryPath: String) -> Publication? {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let masterData = try? Data(contentsOf: directory.appendingPathComponent("master.m3u8")),
              let masterText = String(data: masterData, encoding: .utf8) else { return nil }
        let topology = parseMaster(masterText)
        guard topology.isValid else { return nil }
        var variants: [PlaylistFetch] = []
        for (index, variant) in topology.variants.enumerated() {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("variant-\(index).m3u8")),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            variants.append(PlaylistFetch(
                uri: variant.uri,
                response: Response(status: 200, body: data, transportError: nil),
                parsed: Playlist.parseMedia(text)))
        }
        guard let audioData = try? Data(contentsOf: directory.appendingPathComponent("audio.m3u8")),
              let audioText = String(data: audioData, encoding: .utf8),
              let audioURI = topology.audio?.alternateURI else { return nil }
        return Publication(
            masterResponse: Response(status: 200, body: masterData, transportError: nil),
            topology: topology,
            variants: variants,
            audio: PlaylistFetch(
                uri: audioURI,
                response: Response(status: 200, body: audioData, transportError: nil),
                parsed: Playlist.parseMedia(audioText)))
    }

    private static func parseMaster(_ body: String) -> MasterTopology {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var errors: [String] = []
        var variants: [Variant] = []
        var audioRows: [[String: String]] = []
        var versionSeen = false
        var index = 0
        guard lines.first == "#EXTM3U" else {
            return MasterTopology(variants: [], audio: nil, errors: ["missing leading EXTM3U"])
        }
        index = 1
        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                if index != lines.indices.last { errors.append("empty line before master end") }
                index += 1
                continue
            }
            if line.hasPrefix("#EXT-X-VERSION:") {
                if versionSeen { errors.append("duplicate VERSION") }
                versionSeen = true
                if line != "#EXT-X-VERSION:7" { errors.append("VERSION must be 7") }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let parsed = parseAttributes(line)
                if let error = parsed.error { errors.append(error) }
                else if parsed.values["TYPE"] == "AUDIO",
                        audioAttributeSetIsExact(parsed.values) {
                    audioRows.append(parsed.values)
                }
                else if parsed.values["TYPE"] == "AUDIO" {
                    errors.append("unknown, missing, or misplaced AUDIO attribute")
                }
                else { errors.append("unsupported EXT-X-MEDIA type") }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let parsed = parseAttributes(line)
                if let error = parsed.error { errors.append(error) }
                guard index + 1 < lines.count else {
                    errors.append("STREAM-INF missing URI")
                    break
                }
                index += 1
                let uri = lines[index]
                guard requestPath(uri) != nil else {
                    errors.append("invalid variant URI")
                    index += 1
                    continue
                }
                let codecs = parsed.values["CODECS"]?.split(
                    separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
                let audioGroup = parsed.values["AUDIO"] ?? ""
                guard parsed.error == nil,
                      streamAttributeSetIsExact(parsed.values),
                      parsed.values["BANDWIDTH"].flatMap(Int.init).map({ $0 > 0 }) == true,
                      validOptionalVariantAttributes(parsed.values),
                      codecs.count == 2,
                      codecs.filter({ $0 == "mp4a.40.2" }).count == 1,
                      codecs.filter(isRecognizedVideoCodec).count == 1,
                      !audioGroup.isEmpty else {
                    errors.append("invalid STREAM-INF attributes")
                    index += 1
                    continue
                }
                variants.append(Variant(uri: uri, codecs: codecs, audioGroup: audioGroup))
            } else {
                errors.append("unknown or malformed master line: \(line)")
            }
            index += 1
        }
        if !versionSeen { errors.append("missing VERSION") }
        if Set(variants.map(\.uri)).count != variants.count { errors.append("duplicate variant URI") }
        let audio = parseAudioTopology(audioRows)
        if audio == nil { errors.append("invalid two-AAC audio topology") }
        if let audio, variants.contains(where: { $0.audioGroup != audio.groupID }) {
            errors.append("variant AUDIO group does not match rendition group")
        }
        return MasterTopology(variants: variants, audio: audio, errors: errors)
    }

    private static func parseAttributes(
        _ line: String
    ) -> (values: [String: String], error: String?) {
        guard let colon = line.firstIndex(of: ":") else { return ([:], "missing attribute colon") }
        let source = line[line.index(after: colon)...]
        var fields: [String] = []
        var current = ""
        var quoted = false
        for character in source {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == "," && !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !quoted else { return ([:], "unbalanced attribute quotes") }
        fields.append(current)
        var output: [String: String] = [:]
        for field in fields {
            guard !field.isEmpty, let equals = field.firstIndex(of: "=") else {
                return ([:], "malformed attribute field")
            }
            let key = String(field[..<equals])
            let raw = String(field[field.index(after: equals)...])
            guard !key.isEmpty, key.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" }),
                  output[key] == nil, !raw.isEmpty else {
                return ([:], "invalid or duplicate attribute")
            }
            let value: String
            if raw.hasPrefix("\"") || raw.hasSuffix("\"") {
                guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
                    return ([:], "unbalanced quoted attribute")
                }
                value = String(raw.dropFirst().dropLast())
                guard !value.contains("\"") else { return ([:], "embedded attribute quote") }
            } else {
                guard !raw.contains("\"") else { return ([:], "unexpected attribute quote") }
                value = raw
            }
            output[key] = value
        }
        return (output, nil)
    }

    private static func parseAudioTopology(_ rows: [[String: String]]) -> AudioTopology? {
        guard rows.count == 2,
              let primary = rows.first(where: { $0["DEFAULT"] == "YES" && $0["URI"] == nil }),
              let alternate = rows.first(where: { $0["DEFAULT"] == "NO" && $0["URI"] != nil }),
              primary["AUTOSELECT"] == "YES", alternate["AUTOSELECT"] == "YES",
              let group = primary["GROUP-ID"], !group.isEmpty,
              alternate["GROUP-ID"] == group,
              let primaryLanguage = primary["LANGUAGE"],
              let alternateLanguage = alternate["LANGUAGE"],
              let primaryChannels = primary["CHANNELS"], !primaryChannels.isEmpty,
              let alternateChannels = alternate["CHANNELS"], !alternateChannels.isEmpty,
              let uri = alternate["URI"], requestPath(uri) != nil,
              let alternateID = audioPlaylistRenditionID(uri),
              !isUnknownLanguage(primaryLanguage), !isUnknownLanguage(alternateLanguage),
              primaryLanguage.lowercased() != alternateLanguage.lowercased() else { return nil }
        return AudioTopology(
            groupID: group,
            primaryLanguage: primaryLanguage,
            alternateLanguage: alternateLanguage,
            alternateURI: uri,
            alternateID: alternateID)
    }

    private static func audioAttributeSetIsExact(_ values: [String: String]) -> Bool {
        let primary = Set(["TYPE", "GROUP-ID", "NAME", "LANGUAGE", "DEFAULT", "AUTOSELECT", "CHANNELS"])
        let alternate = primary.union(["URI"])
        let keys = Set(values.keys)
        return keys == primary || keys == alternate
    }

    private static func streamAttributeSetIsExact(_ values: [String: String]) -> Bool {
        let required = Set(["BANDWIDTH", "CODECS", "AUDIO"])
        let allowed = required.union([
            "RESOLUTION", "FRAME-RATE", "SUPPLEMENTAL-CODECS", "VIDEO-RANGE",
        ])
        let keys = Set(values.keys)
        return required.isSubset(of: keys) && keys.isSubset(of: allowed)
    }

    private static func validOptionalVariantAttributes(_ values: [String: String]) -> Bool {
        if let resolution = values["RESOLUTION"] {
            let fields = resolution.split(separator: "x", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  fields.allSatisfy({ Int($0).map { $0 > 0 } == true }) else { return false }
        }
        if let rate = values["FRAME-RATE"] {
            guard Playlist.msFromSecondsText(rate) != nil,
                  (Double(rate).map { $0.isFinite && $0 > 0 } == true) else { return false }
        }
        if let range = values["VIDEO-RANGE"], !["SDR", "PQ", "HLG"].contains(range) {
            return false
        }
        if let supplemental = values["SUPPLEMENTAL-CODECS"], supplemental.isEmpty {
            return false
        }
        return true
    }

    private static func isRecognizedVideoCodec(_ codec: String) -> Bool {
        ["avc1.", "hvc1.", "hev1.", "dvh1.", "dvhe."].contains {
            codec.hasPrefix($0) && codec.count > $0.count
        }
    }

    private struct MP4Box {
        let type: String
        let payload: Range<Int>
    }

    private static func exactlyOneMP4AAudioTrack(in data: Data) -> Bool {
        guard let top = mp4Boxes(data, range: 0..<data.count),
              let moov = onlyBox("moov", in: top),
              let moovChildren = mp4Boxes(data, range: moov.payload) else { return false }
        var audioEntries: [String] = []
        for trak in moovChildren where trak.type == "trak" {
            guard let trakChildren = mp4Boxes(data, range: trak.payload),
                  let mdia = onlyBox("mdia", in: trakChildren),
                  let mdiaChildren = mp4Boxes(data, range: mdia.payload),
                  let hdlr = onlyBox("hdlr", in: mdiaChildren),
                  hdlr.payload.count >= 12 else { return false }
            let handlerStart = hdlr.payload.lowerBound + 8
            guard let handler = String(data: data[handlerStart..<(handlerStart + 4)], encoding: .ascii) else {
                return false
            }
            guard handler == "soun" else { continue }
            guard let minf = onlyBox("minf", in: mdiaChildren),
                  let minfChildren = mp4Boxes(data, range: minf.payload),
                  let stbl = onlyBox("stbl", in: minfChildren),
                  let stblChildren = mp4Boxes(data, range: stbl.payload),
                  let stsd = onlyBox("stsd", in: stblChildren), stsd.payload.count >= 8,
                  be32(data, at: stsd.payload.lowerBound + 4) == 1,
                  let entries = mp4Boxes(
                    data, range: (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound),
                  entries.count == 1 else { return false }
            audioEntries.append(entries[0].type)
        }
        return audioEntries == ["mp4a"]
    }

    private static func mp4Boxes(_ data: Data, range: Range<Int>) -> [MP4Box]? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        var boxes: [MP4Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor <= range.upperBound - 8, let compact = be32(data, at: cursor) else { return nil }
            var header = 8
            let length: UInt64
            if compact == 1 {
                guard cursor <= range.upperBound - 16, let wide = be64(data, at: cursor + 8) else { return nil }
                header = 16
                length = wide
            } else if compact == 0 {
                length = UInt64(range.upperBound - cursor)
            } else {
                length = UInt64(compact)
            }
            guard length >= UInt64(header), length <= UInt64(range.upperBound - cursor),
                  let type = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii) else {
                return nil
            }
            let end = cursor + Int(length)
            boxes.append(MP4Box(type: type, payload: (cursor + header)..<end))
            cursor = end
        }
        return cursor == range.upperBound ? boxes : nil
    }

    private static func onlyBox(_ type: String, in boxes: [MP4Box]) -> MP4Box? {
        let matches = boxes.filter { $0.type == type }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func be32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func be64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        return data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func isUnknownLanguage(_ language: String) -> Bool {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty || ["und", "unk", "mis", "zxx"].contains(key)
    }

    private static func audioPlaylistRenditionID(_ uri: String) -> Int? {
        guard uri.hasPrefix("audio"), uri.hasSuffix(".m3u8"), !uri.contains("/") else { return nil }
        let digits = String(uri.dropFirst(5).dropLast(5))
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let id = Int(digits) else { return nil }
        return id
    }

    private static func requestPath(_ uri: String) -> String? {
        guard !uri.isEmpty, uri.utf8.count <= 255,
              !uri.contains("/"), !uri.contains("?"), !uri.contains("#"),
              !uri.contains("%"), !uri.contains(":") else { return nil }
        return "/\(uri)"
    }

    private static func describe(_ range: Range<Int>?) -> String {
        range.map { "[\($0.lowerBound),\($0.upperBound))" } ?? "invalid"
    }
}
