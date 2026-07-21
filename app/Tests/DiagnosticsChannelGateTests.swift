// Standalone executable for the THREE durable diagnostic channels: what leaves the device, and who is
// allowed to ask for it.
//
//   xcrun swiftc -o /tmp/diagnostics-channel-gate \
//     app/SourcesShared/VXProbeRedaction.swift \
//     app/SourcesShared/VXDiagExportPolicy.swift \
//     app/Tests/DiagnosticsChannelGateTests.swift && /tmp/diagnostics-channel-gate
//
// Run from the repo root, or pass the repo root as the single argument.
//
// WHY THIS EXISTS. Enumerating by ARTIFACT rather than by call site gives three channels, and they do not
// share a posture:
//   - `vortx-diag.log`      OPT-IN. Exported by the LAN QR path, the macOS Finder copy, and the iOS ShareLink.
//   - `diagnostics.log`     ALWAYS ON for every user, ~512 KiB durable, 152 call sites across 25 files.
//   - `stremio-server.log`  Written by bundled JavaScript we do not own, retained ACROSS BOOTS, and appended
//                           to two of the three exports, so it DOES leave the device. It logs raw torrent
//                           hashes on engine created/destroyed/idle/inactive/error/invalid-piece.
//
// PART 1 proves the pure policy: who may fetch an export, and what bytes an export contains.
// PART 2 is a SOURCE GATE over the production files, in the same shape as IdentityCallerGateTests, because
// the wiring is what keeps regressing: the formatter can be perfect while a writer bypasses it, and a
// behavioural suite cannot see that. Every rule proves it can go RED against a synthetic pre-fix fixture.
//
// WHAT IS NOT CLAIMED. Part 2 is a source-text gate, not a compiler: it proves the forbidden shapes are
// absent and the required shapes are present in the named files. And no part of this file claims the
// redaction rules are complete; they are best-effort by construction, which VXProbeRedactionTests states
// case by case.

import Foundation

// MARK: - Harness

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func expect(_ condition: Bool, _ what: String) {
    if condition {
        passed += 1
        print("PASS  \(what)")
    } else {
        failed += 1
        print("FAIL  \(what)")
    }
}

/// A stall must FAIL, not hang.
let watchdogSeconds = 60.0

// MARK: - Source model (Part 2)

struct SourceFile {
    let path: String
    let lines: [String]

    /// Line numbers (1-based) containing `needle`, skipping pure `//` comment lines so a rule's own
    /// explanatory prose cannot trip it.
    func lines(containing needle: String) -> [Int] {
        var hits: [Int] = []
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if line.contains(needle) { hits.append(index + 1) }
        }
        return hits
    }
}

func load(_ root: String, _ relative: String) -> SourceFile? {
    guard let text = try? String(contentsOfFile: root + "/" + relative, encoding: .utf8), !text.isEmpty else { return nil }
    return SourceFile(path: relative, lines: text.components(separatedBy: "\n"))
}

func synthetic(_ path: String, _ text: String) -> SourceFile {
    SourceFile(path: path, lines: text.components(separatedBy: "\n"))
}

func forbidding(_ file: SourceFile, _ needle: String, why: String) -> [String] {
    file.lines(containing: needle).map { "\(file.path):\($0) \(why) (`\(needle)`)" }
}

func requiring(_ file: SourceFile, _ needle: String, why: String) -> [String] {
    file.lines(containing: needle).isEmpty ? ["\(file.path) \(why) (missing `\(needle)`)"] : []
}

struct Rule {
    let name: String
    let files: [String]
    let check: ([String: SourceFile]) -> [String]
    /// The exact PRE-FIX shape, per governed file. Phase 2 asserts the rule reports a violation against it.
    let revertedFixture: [String: String]
}

let rules: [Rule] = [

    // G1. The ALWAYS-ON channel writes through the shared formatter. This is the one with no toggle in front
    // of it, and it was appending a hand-built "stamp [category] message" line: raw category, raw message,
    // no control-character neutralisation, and a cap that did not exist.
    Rule(
        name: "G1 DiagnosticsLog forms every durable line with the shared formatter",
        files: ["app/SourcesShared/DiagnosticsLog.swift"],
        check: { files in
            guard let file = files["app/SourcesShared/DiagnosticsLog.swift"] else { return ["missing"] }
            return requiring(file, "VXProbeRedaction.durableLine(",
                             why: "must form its durable line through the shared bounded formatter")
                + forbidding(file, "\\(stamp.string(from: Date())) [\\(category)] \\(message)",
                             why: "hand-builds a durable line, bypassing the formatter")
        },
        revertedFixture: ["app/SourcesShared/DiagnosticsLog.swift": """
        enum DiagnosticsLog {
            static func log(_ category: String, _ message: String) {
                let line = "\\(stamp.string(from: Date())) [\\(category)] \\(message)\\n"
                queue.async { append(line) }
            }
        }
        """]
    ),

    // G2. Same for the opt-in probe channel, which additionally mirrors to NSLog. The previous revision
    // scrubbed only `message` and then interpolated a RAW category into both sinks.
    Rule(
        name: "G2 VXProbeFileLog forms its line (and its NSLog mirror) with the shared formatter",
        files: ["app/SourcesShared/VXProbe.swift"],
        check: { files in
            guard let file = files["app/SourcesShared/VXProbe.swift"] else { return ["missing"] }
            return requiring(file, "VXProbeRedaction.durableLine(",
                             why: "must form its durable line through the shared bounded formatter")
                + forbidding(file, "NSLog(\"[%@] %@\", category",
                             why: "mirrors a RAW category to the device console")
                + forbidding(file, "[\\(category)] \\(safe)",
                             why: "hand-builds a durable line with an unscrubbed category")
        },
        revertedFixture: ["app/SourcesShared/VXProbe.swift": """
        final class VXProbeFileLog {
            func record(category: String, message: String) {
                let safe = VXProbeRedaction.scrub(message)
                queue.async {
                    NSLog("[%@] %@", category, safe)
                    let line = "\\(self.formatter.string(from: now)) [\\(category)] \\(safe)\\n"
                    self.write(Data(line.utf8))
                }
            }
        }
        """]
    ),

    // G3. Every export path emits the sanitised body. A write-path scrubber does nothing for the megabytes
    // already in Caches from earlier builds, and Caches survives app updates, so the sanitiser has to sit at
    // export time on ALL THREE surfaces or the weakest one defines the exposure.
    Rule(
        name: "G3 all three export paths emit the sanitised export body, never the live file",
        files: ["app/SourcesShared/VXDiagExport.swift", "app/SourcesiOS/iOSSettingsView.swift"],
        check: { files in
            var found: [String] = []
            if let export = files["app/SourcesShared/VXDiagExport.swift"] {
                found += requiring(export, "VXDiagExportPolicy.exportBody(",
                                   why: "must build its bytes through the export-time sanitiser")
                found += forbidding(export, "(try? Data(contentsOf: VXProbe.logFileURL))",
                                    why: "serves the LIVE log bytes, skipping the export-time sanitiser")
                found += forbidding(export, "activateFileViewerSelecting([src])",
                                    why: "reveals the LIVE log file, skipping the export-time sanitiser")
            }
            if let settings = files["app/SourcesiOS/iOSSettingsView.swift"] {
                found += requiring(settings, "VXDiagExport.exportBody()",
                                   why: "ShareLink must hand over a sanitised copy")
                found += forbidding(settings, "let url = VXProbe.logFileURL",
                                    why: "ShareLink hands over the LIVE log URL, skipping the export-time sanitiser")
            }
            return found
        },
        revertedFixture: [
            "app/SourcesShared/VXDiagExport.swift": """
            final class VXDiagExport {
                private func serve(_ connection: NWConnection) {
                    var body = (try? Data(contentsOf: VXProbe.logFileURL)) ?? Data()
                    body.append(Self.serverSection())
                }
            }
            """,
            "app/SourcesiOS/iOSSettingsView.swift": """
            struct iOSSettingsView: View {
                private var diagLogExportURL: URL? {
                    let url = VXProbe.logFileURL
                    return url
                }
            }
            """
        ]
    ),

    // G4. The LAN listener is capability-gated and one-shot. It used to advertise a bare root URL and serve
    // ANY connection whose bytes contained a CRLF pair, without checking method, path or peer, and it stayed
    // up so a LAN peer could pull repeatedly for the life of the screen.
    Rule(
        name: "G4 the LAN export requires one GET of an unguessable path, exactly once",
        files: ["app/SourcesShared/VXDiagExport.swift"],
        check: { files in
            guard let file = files["app/SourcesShared/VXDiagExport.swift"] else { return ["missing"] }
            return requiring(file, "VXDiagExportPolicy.makeCapabilityPath()",
                             why: "must mint capability material per start")
                + requiring(file, "VXDiagExportPolicy.decide(",
                            why: "must route every request through the accept/reject decision")
                + forbidding(file, "let terminator = Data(\"\\r\\n\\r\\n\".utf8)",
                             why: "serves on a bare CRLFCRLF sighting, with no method or path check")
                + forbidding(file, "let urlString = \"http://\\(ip):\\(boundPort)/\"",
                             why: "advertises a bare root URL, which is guessable by definition")
        },
        revertedFixture: ["app/SourcesShared/VXDiagExport.swift": """
        final class VXDiagExport {
            func start() -> (url: String, qr: Image)? {
                let urlString = "http://\\(ip):\\(boundPort)/"
            }
            private func readRequest(_ connection: NWConnection, buffer: Data) {
                let terminator = Data("\\r\\n\\r\\n".utf8)
                if accumulated.range(of: terminator) != nil { self.serve(connection) }
            }
        }
        """]
    ),

    // G5. The named raw producers. Every one of these was verified emitting an identifier in the clear while
    // its counterpart on the other platform already redacted the same value, which is the standing evidence
    // that "the sink will catch it" is not a plan.
    Rule(
        name: "G5 no named producer builds an identifier-bearing diagnostic line in the clear",
        files: [
            "app/SourcesTV/TVPlayerView.swift",
            "app/SourcesShared/CommunityTrickplay.swift",
            "app/SourcesShared/CoreBridge.swift",
            "app/SourcesShared/LastStreamStore.swift"
        ],
        check: { files in
            var found: [String] = []
            if let tv = files["app/SourcesTV/TVPlayerView.swift"] {
                found += forbidding(tv, "playing=\\(m.libraryId)", why: "logs a raw library id")
                found += forbidding(tv, "metaDetails=\\(core.metaDetails?.meta?.id", why: "logs a raw meta id")
                found += forbidding(tv, "unresolvable id \\(m.libraryId)", why: "logs a raw library id")
                found += forbidding(tv, "route file=\\(url.lastPathComponent)",
                                    why: "logs a raw file name to the ALWAYS-ON breadcrumb as well as the probe log")
                // These three are on the ALWAYS-ON channel, found by re-counting rather than from the
                // review list, which is the reason the count is reported with its method attached.
                found += forbidding(tv, "-> \\(pending.meta.videoId)", why: "logs a raw video id")
                found += forbidding(tv, "advance load for \\(pending.meta.videoId)", why: "logs a raw video id")
                found += forbidding(tv, "pending url \\(u.lastPathComponent)", why: "logs a raw file name")
            }
            if let store = files["app/SourcesShared/LastStreamStore.swift"] {
                found += forbidding(store, "id=\\(libraryId)", why: "logs a raw library id on the always-on channel")
            }
            if let trickplay = files["app/SourcesShared/CommunityTrickplay.swift"] {
                found += forbidding(trickplay, "resolved \\(rawId) -> \\(tt)", why: "logs two raw catalog ids")
                found += forbidding(trickplay, "POST \\(url.absoluteString)",
                                    why: "logs a signed URL including its query string")
            }
            if let bridge = files["app/SourcesShared/CoreBridge.swift"] {
                found += forbidding(bridge, "meta=\\(details?.meta?.id", why: "logs a raw meta id")
            }
            return found
        },
        revertedFixture: [
            "app/SourcesTV/TVPlayerView.swift": """
            VXProbe.log("tp", "provisional key MISS (tvOS): playing=\\(m.libraryId) done")
            """,
            "app/SourcesShared/CommunityTrickplay.swift": """
            VXProbe.log("tp", "POST \\(url.absoluteString) httpStatus=\\(code)")
            """,
            "app/SourcesShared/CoreBridge.swift": """
            VXProbe.log("engine", "metaDetails changed meta=\\(details?.meta?.id ?? "nil")")
            """,
            "app/SourcesShared/LastStreamStore.swift": """
            DiagnosticsLog.log("cw-resume", "\\(outcome) id=\\(libraryId) profile=\\(pid)")
            """
        ]
    )
]

// MARK: - Run

@main
struct DiagnosticsChannelGate {
    static func main() {
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: watchdogSeconds)
            FileHandle.standardError.write(
                Data("FAIL  gate exceeded its \(Int(watchdogSeconds))s bound (a hang is a failure, not a pass)\n".utf8))
            exit(2)
        }
        watchdog.stackSize = 512 * 1024
        watchdog.start()

        capabilityContract()
        requestContract()
        exportBodyContract()
        sourceGate()

        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed) of \(passed + failed) checks")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: Part 1a - the capability

    static func capabilityContract() {
        let path = VXDiagExportPolicy.makeCapabilityPath()
        expect(path.hasPrefix("/") && path.count == 1 + VXDiagExportPolicy.capabilityBytes * 2,
               "G-CAP1: the capability is a path of \(VXDiagExportPolicy.capabilityBytes * 2) hex characters, i.e. \(VXDiagExportPolicy.capabilityBytes * 8) bits")
        expect(VXDiagExportPolicy.capabilityBytes * 8 >= 128,
               "G-CAP2: at least 128 bits of capability material per start")
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        expect(path.dropFirst().unicodeScalars.allSatisfy { hex.contains($0) },
               "G-CAP3: the path is hex only, so it survives a QR round trip and a URL unchanged")
        var seen = Set<String>()
        for _ in 0..<512 { seen.insert(VXDiagExportPolicy.makeCapabilityPath()) }
        expect(seen.count == 512,
               "G-CAP4: every start mints a fresh capability, so a path scraped from an earlier session is dead")
    }

    // MARK: Part 1b - who gets served

    static func requestContract() {
        let path = VXDiagExportPolicy.makeCapabilityPath()
        func request(_ text: String) -> Data { Data(text.utf8) }

        expect(VXDiagExportPolicy.decide(request: request("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n"),
                                         capabilityPath: path, alreadyServed: false) == .serve,
               "G-REQ1: the owner's own QR URL is served")
        expect(VXDiagExportPolicy.decide(request: request("GET \(path)?x=1 HTTP/1.1\r\n"),
                                         capabilityPath: path, alreadyServed: false) == .serve,
               "G-REQ2: a query string is ignored rather than breaking the capability match")

        // The exact pre-fix behaviour: bytes containing a CRLF pair, no method, no path.
        expect(VXDiagExportPolicy.decide(request: request("\r\n\r\n"),
                                         capabilityPath: path, alreadyServed: false) == .reject,
               "G-REQ3: a bare CRLFCRLF is rejected, which is precisely what used to be served")
        expect(VXDiagExportPolicy.decide(request: request("GET / HTTP/1.1\r\n\r\n"),
                                         capabilityPath: path, alreadyServed: false) == .reject,
               "G-REQ4: the bare root URL is rejected, so a port scanner that finds the listener gets nothing")
        expect(VXDiagExportPolicy.decide(request: request("GET \(path)x HTTP/1.1\r\n"),
                                         capabilityPath: path, alreadyServed: false) == .reject,
               "G-REQ5: a near-miss path is rejected (exact match, not prefix)")
        expect(VXDiagExportPolicy.decide(request: request("POST \(path) HTTP/1.1\r\n"),
                                         capabilityPath: path, alreadyServed: false) == .reject,
               "G-REQ6: only GET is served")
        expect(VXDiagExportPolicy.decide(request: request("GET \(path) HTTP/1.1"),
                                         capabilityPath: path, alreadyServed: false) == .reject,
               "G-REQ7: an incomplete request line is not judged, so a peer cannot be served on a partial path")
        expect(VXDiagExportPolicy.decide(request: request("GET \(path) HTTP/1.1\r\n"),
                                         capabilityPath: path, alreadyServed: true) == .reject,
               "G-REQ8: ONE-SHOT: the second correct request is rejected, so a LAN peer cannot pull repeatedly")
        expect(VXDiagExportPolicy.decide(request: request("GET / HTTP/1.1\r\n"),
                                         capabilityPath: "", alreadyServed: false) == .reject,
               "G-REQ9: with no capability minted, nothing is served")
        let long = "GET /" + String(repeating: "a", count: VXDiagExportPolicy.maxRequestLineBytes) + " HTTP/1.1\r\n"
        expect(VXDiagExportPolicy.decide(request: request(long), capabilityPath: path, alreadyServed: false) == .reject,
               "G-REQ10: an oversized request line is rejected rather than parsed")
    }

    // MARK: Part 1c - what the export contains

    static func exportBodyContract() {
        let hash = "bbe3eb70b55e5ffc0e4eb30fbf33c2ca92fad49e"

        // LEGACY BYTES. These lines are what an OLDER build wrote: raw, already on disk, and untouched by any
        // write-path fix. Caches survives app updates, so this is the normal case, not a corner one.
        let legacy = """
        2026-01-01 00:00:00.000 [engine] metaDetails changed meta=tt0903747 streams=4
        2026-01-01 00:00:01.000 [tp] POST https://poster.example/up?auth_token=RD-abc123 body=ok
        """
        let body = VXDiagExportPolicy.exportBody(logContents: legacy, serverStatus: nil, serverTailLines: [])
        let text = String(decoding: body, as: UTF8.self)
        expect(!text.contains("tt0903747"),
               "G-EXP1: a raw id written by an EARLIER build is redacted at export time, not left on the way out")
        expect(!text.contains("RD-abc123"),
               "G-EXP2: a credential written by an earlier build is redacted at export time too")
        expect(text.contains("streams=4"),
               "G-EXP3: everything that is not an identifier still reaches the person reading the export")

        // THE SERVER CHANNEL. Written by bundled JavaScript we do not own, retained across boots, appended to
        // the export. A bare infohash outside a URL is exactly what URL-only scrubbing cannot see.
        let serverLines = [
            "12:00:00 [log] engine created \(hash)",
            "12:00:01 [log] fetch http://127.0.0.1:11470/\(hash)/0?passkey=SEEKRIT99",
            "12:00:02 [err] invalid piece 7 for \(hash)"
        ]
        let withServer = VXDiagExportPolicy.exportBody(logContents: "x\n",
                                                       serverStatus: "running pid=1 hash=\(hash)",
                                                       serverTailLines: serverLines)
        let serverText = String(decoding: withServer, as: UTF8.self)
        expect(!serverText.contains(hash),
               "G-EXP4: a BARE torrent hash in the server log is redacted, which URL-only scrubbing cannot do")
        expect(!serverText.contains("SEEKRIT99"),
               "G-EXP5: the server log's query strings are dropped before the tail is appended")
        expect(serverText.contains("invalid piece 7"),
               "G-EXP6: the server line still says what went wrong, which is the reason to ship the tail at all")
        expect(serverText.contains("===== streaming server ====="),
               "G-EXP7: the server section is present when a server is registered")

        expect(!String(decoding: VXDiagExportPolicy.exportBody(logContents: "x\n", serverStatus: nil,
                                                               serverTailLines: serverLines), as: UTF8.self)
                .contains("streaming server"),
               "G-EXP8: with no server registered (the Lite build) the section is omitted entirely")

        // A forged line in retained bytes cannot be laundered into the export as a genuine entry.
        let forged = VXDiagExportPolicy.exportBody(logContents: "2026-01-01 00:00:00.000 [a] x",
                                                   serverStatus: nil, serverTailLines: [])
        expect(String(decoding: forged, as: UTF8.self).contains("[a] x"),
               "G-EXP9: an ordinary retained line survives the export rewrite readable")

        expect(String(decoding: VXDiagExportPolicy.exportBody(logContents: "", serverStatus: nil,
                                                              serverTailLines: []), as: UTF8.self)
                .contains("(diagnostic log is empty)"),
               "G-EXP10: an empty log exports a placeholder rather than a zero-byte file")
    }

    // MARK: Part 2 - the production wiring

    static func sourceGate() {
        let arguments = CommandLine.arguments
        let repoRoot = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath

        // Phase 0: every governed file must be present and readable. A rule whose files vanished covers
        // nothing, and a gate that quietly covers nothing is the failure mode this file exists to end.
        var loaded: [String: SourceFile] = [:]
        var missing: [String] = []
        for path in Set(rules.flatMap(\.files)).sorted() {
            if let file = load(repoRoot, path) { loaded[path] = file } else { missing.append(path) }
        }
        expect(missing.isEmpty,
               "GATE: every governed production source is present and readable"
               + (missing.isEmpty ? "" : " (missing: \(missing.joined(separator: ", ")))"))

        // Phase 1: the real tree must be clean.
        for rule in rules {
            let governed = loaded.filter { rule.files.contains($0.key) }
            let found = governed.isEmpty ? ["\(rule.name): no governed file loaded"] : rule.check(governed)
            for violation in found.sorted() { print("      \(violation)") }
            expect(found.isEmpty, rule.name)
        }

        // Phase 2: every rule must REJECT the pre-fix shape it was written for. A rule that stays green
        // against its own reverted fixture cannot fail, which is worth less than no rule at all.
        for rule in rules {
            var fixtures = loaded.filter { rule.files.contains($0.key) }
            for (path, text) in rule.revertedFixture { fixtures[path] = synthetic(path, text) }
            expect(!rule.check(fixtures).isEmpty, "MUTANT: \(rule.name) goes RED against the reverted shape")
        }
    }
}
