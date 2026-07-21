// Standalone authorization and zero-transport harness for the production SubtitlePoolClient.swift.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/subtitle-pool-consent-test \
//     app/SourcesShared/VXProbeRedaction.swift \
//     app/SourcesShared/SubtitlePoolClient.swift \
//     app/Tests/SubtitlePoolConsentContractTests.swift && /tmp/subtitle-pool-consent-test
//
// VXProbeRedaction is a REQUIRED input: the producer-cleanup wave routed this file's three probe lines
// through identityToken, so the harness no longer compiles without it. A header command that does not
// run is not a receipt, which is how this regression reached review unnoticed.

import Foundation

enum MoatConsent {
    nonisolated(unsafe) static var contributeAndConsume = true
}

actor MoatToken {
    static let shared = MoatToken()
    static let header = "X-VX-Moat"
    func current(isSignedIn: Bool) -> String? { isSignedIn ? "live-moat" : nil }
}

struct SourceIndexLifecycleSnapshot: Sendable {
    let sourceGeneration: UInt64
    let sessionGeneration: UInt64
    let consentGeneration: UInt64
}

enum SourceIndexLifecycleClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sourceGeneration: UInt64 = 0
    nonisolated(unsafe) private static var sessionGeneration: UInt64 = 0
    nonisolated(unsafe) private static var consentGeneration: UInt64 = 0

    static func snapshot() -> SourceIndexLifecycleSnapshot {
        lock.withLock {
            SourceIndexLifecycleSnapshot(
                sourceGeneration: sourceGeneration,
                sessionGeneration: sessionGeneration,
                consentGeneration: consentGeneration
            )
        }
    }

    static func rotateSession() {
        lock.withLock {
            sourceGeneration &+= 1
            sessionGeneration &+= 1
        }
    }

    static func rotateConsent() {
        lock.withLock {
            sourceGeneration &+= 1
            consentGeneration &+= 1
        }
    }
}

struct RemoteConfigSnapshot {
    let subtitleDownloadTimeout: TimeInterval = 1
    // Deliberately above the Worker's fixed ceiling so the client-side hard clamp is exercised.
    let subtitleUploadMaxBytes = 2_097_152

    func isFeatureOn(_ key: String, default value: Bool) -> Bool { true }
    func endpoint(_ key: String) -> URL? {
        key == "subtitles" ? URL(string: "https://public-base.invalid") : nil
    }
}

enum RemoteConfig {
    static let snapshot = RemoteConfigSnapshot()
}

enum RemoteConfigDefaults {
    static let featureCommunitySubtitles = true
    static let featureSubtitleSync = true
    static let endpointSubtitles = "https://subtitles.vortx.tv"
}

enum VortXEdgeAuth {
    static func sign(_ request: inout URLRequest) {}
}

enum VXProbe {
    static func log(_ channel: String, _ message: String) {}
}

actor SubtitleTransportProbe {
    private var requests: [URLRequest] = []
    private let response: SubtitlePoolClient.TransportResponse?

    init(response: SubtitlePoolClient.TransportResponse? = nil) {
        self.response = response
    }

    func perform(_ request: URLRequest) -> SubtitlePoolClient.TransportResponse? {
        requests.append(request)
        return response
    }

    func count() -> Int { requests.count }
    func captured() -> [URLRequest] { requests }
}

actor InvocationCounter {
    private var value = 0

    func increment() { value += 1 }
    func count() -> Int { value }
}

private final class RedirectServerHarness {
    struct State: Decodable {
        let sourcePort: Int
        let targetPort: Int
        let redirectRequests: Int
        let sameTargetRequests: Int
        let crossTargetRequests: Int
        let okRequests: Int
        let bodyRequests: Int
        let postRequests: Int
        let okMoat: String?
        let sameTargetMoat: String?
        let crossTargetMoat: String?
    }

    enum HarnessError: Error {
        case didNotStart(String)
    }

    private let process: Process
    private let stateURL: URL
    private let directory: URL
    let sourcePort: Int
    let targetPort: Int

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-subtitle-redirect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.serverScript, stateURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()

        var ready: State?
        for _ in 0..<250 {
            if let state = try? Self.readState(at: stateURL),
               state.sourcePort > 0, state.targetPort > 0 {
                ready = state
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let ready else {
            process.terminate()
            process.waitUntilExit()
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            try? FileManager.default.removeItem(at: directory)
            throw HarnessError.didNotStart(error)
        }

        self.process = process
        self.stateURL = stateURL
        self.directory = directory
        self.sourcePort = ready.sourcePort
        self.targetPort = ready.targetPort
    }

    func state() throws -> State {
        try Self.readState(at: stateURL)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func readState(at url: URL) throws -> State {
        try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    private static let serverScript = #"""
import http.server
import gzip
import json
import os
import sys
import threading
import time

state_path = sys.argv[1]
lock = threading.Lock()
state = {
    "sourcePort": 0,
    "targetPort": 0,
    "redirectRequests": 0,
    "sameTargetRequests": 0,
    "crossTargetRequests": 0,
    "okRequests": 0,
    "bodyRequests": 0,
    "postRequests": 0,
    "okMoat": None,
    "sameTargetMoat": None,
    "crossTargetMoat": None,
}

def publish():
    with lock:
        body = json.dumps(state)
    temporary = state_path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.replace(temporary, state_path)

def record(key, moat_key=None, moat=None):
    with lock:
        state[key] += 1
        if moat_key is not None:
            state[moat_key] = moat
    publish()

def send(handler, status, body=b"", location=None):
    handler.send_response(status)
    if location is not None:
        handler.send_header("location", location)
    handler.send_header("content-length", str(len(body)))
    handler.end_headers()
    if body:
        handler.wfile.write(body)

def send_without_length(handler, body, delay=0):
    handler.send_response(200)
    handler.end_headers()
    try:
        for start in range(0, len(body), 4096):
            handler.wfile.write(body[start:start + 4096])
            handler.wfile.flush()
            if delay:
                time.sleep(delay)
    except (BrokenPipeError, ConnectionResetError):
        pass

class SourceHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/redirect/"):
            parts = self.path.split("/")
            status = int(parts[2])
            destination = parts[3]
            record("redirectRequests")
            if destination == "same":
                location = "/same-target"
            else:
                location = f"http://127.0.0.1:{target.server_port}/cross-target"
            send(self, status, location=location)
            return
        if self.path == "/same-target":
            record("sameTargetRequests", "sameTargetMoat", self.headers.get("X-VX-Moat"))
            send(self, 200, b"same")
            return
        if self.path == "/ok":
            record("okRequests", "okMoat", self.headers.get("X-VX-Moat"))
            send(self, 200, b"ok")
            return
        if self.path.startswith("/bytes/"):
            parts = self.path.split("/")
            mode = parts[2]
            size = int(parts[3])
            record("bodyRequests")
            body = b"x" * size
            if mode == "declared":
                send(self, 200, body)
            elif mode == "absent":
                send_without_length(self, body)
            elif mode == "malformed":
                self.send_response(200)
                self.send_header("content-length", "not-a-number")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            elif mode == "gzip":
                compressed = gzip.compress(body)
                self.send_response(200)
                self.send_header("content-encoding", "gzip")
                self.send_header("content-length", str(len(compressed)))
                self.end_headers()
                try:
                    self.wfile.write(compressed)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            elif mode == "slow":
                send_without_length(self, body, delay=0.02)
            else:
                send(self, 404)
            return
        send(self, 404)

    def do_POST(self):
        if self.path == "/post-large":
            length = int(self.headers.get("content-length") or "0")
            if length:
                self.rfile.read(length)
            record("postRequests")
            send_without_length(self, b"p" * (2 * 1024 * 1024), delay=0.001)
            return
        send(self, 404)

    def log_message(self, format, *args):
        pass

class TargetHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/cross-target":
            record("crossTargetRequests", "crossTargetMoat", self.headers.get("X-VX-Moat"))
            send(self, 200, b"cross")
            return
        send(self, 404)

    def log_message(self, format, *args):
        pass

target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
source = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SourceHandler)
with lock:
    state["sourcePort"] = source.server_port
    state["targetPort"] = target.server_port
publish()
threading.Thread(target=target.serve_forever, daemon=True).start()
threading.Thread(target=source.serve_forever, daemon=True).start()
while True:
    time.sleep(1)
"""#
}

@main
struct SubtitlePoolConsentContractTests {
    private static let contentKey = "imdb:tt1234567"
    private static let canonicalHash = String(repeating: "a", count: 64)

    @MainActor
    private static var failures = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    @MainActor
    private static func pooled(hash: String = canonicalHash, format: String = "srt") -> SubtitlePoolClient.PooledSubtitle {
        SubtitlePoolClient.PooledSubtitle(
            id: 1,
            contentKey: contentKey,
            lang: "en",
            format: format,
            origin: "embedded",
            score: 1,
            url: URL(
                string: "https://subtitles.vortx.tv/r2/subs/\(contentKey)/\(hash).\(format)"
            )!
        )
    }

    private static func responseBody(url: URL, offsetMs: Int? = nil) -> Data {
        var root: [String: Any] = [
            "subs": [[
                "id": 1,
                "lang": "en",
                "format": url.pathExtension,
                "origin": "embedded",
                "score": 1,
                "url": url.absoluteString,
            ]],
            "offset": NSNull(),
        ]
        if let offsetMs {
            root["offset"] = ["offsetMs": offsetMs, "votes": 1]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private static func stableHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private static func expectedTemporaryFile(
        for pooled: SubtitlePoolClient.PooledSubtitle,
        lifecycle: SourceIndexLifecycleSnapshot
    ) -> URL {
        let name = "vortx-poolsub-\(stableHash(pooled.url.absoluteString))-s\(lifecycle.sessionGeneration)-c\(lifecycle.consentGeneration).\(pooled.format)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    @MainActor
    private static func testURLGrammar() {
        let hash = canonicalHash
        let key = contentKey
        let canonical = "https://subtitles.vortx.tv/r2/subs/\(key)/\(hash).srt"
        let cases: [(name: String, raw: String, expectedKey: String, format: String, valid: Bool)] = [
            ("canonical srt", canonical, key, "srt", true),
            ("canonical vtt", "https://subtitles.vortx.tv/r2/subs/\(key)/\(hash).vtt", key, "vtt", true),
            ("canonical ass", "https://subtitles.vortx.tv/r2/subs/\(key)/\(hash).ass", key, "ass", true),
            ("case-insensitive HTTPS origin", "HTTPS://SUBTITLES.VORTX.TV/r2/subs/\(key)/\(hash).srt", key, "srt", true),
            ("http scheme", "http://subtitles.vortx.tv/r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("foreign host", "https://example.invalid/r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("host suffix", "https://subtitles.vortx.tv.example.invalid/r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("host trailing dot", "https://subtitles.vortx.tv./r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("userinfo", "https://user@subtitles.vortx.tv/r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("userinfo password", "https://user:pass@subtitles.vortx.tv/r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("explicit default port", "https://subtitles.vortx.tv:443/r2/subs/\(key)/\(hash).srt", key, "srt", false),
            ("query", "\(canonical)?download=1", key, "srt", false),
            ("empty query", "\(canonical)?", key, "srt", false),
            ("fragment", "\(canonical)#cue", key, "srt", false),
            ("empty fragment", "\(canonical)#", key, "srt", false),
            ("missing r2", "https://subtitles.vortx.tv/subs/\(key)/\(hash).srt", key, "srt", false),
            ("wrong prefix", "https://subtitles.vortx.tv/r2/files/\(key)/\(hash).srt", key, "srt", false),
            ("extra path segment", "https://subtitles.vortx.tv/r2/subs/extra/\(key)/\(hash).srt", key, "srt", false),
            ("trailing path segment", "\(canonical)/extra", key, "srt", false),
            ("encoded content key", "https://subtitles.vortx.tv/r2/subs/imdb%3Att1234567/\(hash).srt", key, "srt", false),
            ("wrong content key", canonical, "imdb:tt7654321", "srt", false),
            ("empty expected key", canonical, "", "srt", false),
            ("invalid expected key", canonical, "imdb/tt1234567", "srt", false),
            ("overlong expected key", canonical, String(repeating: "a", count: 201), "srt", false),
            ("short hash", "https://subtitles.vortx.tv/r2/subs/\(key)/\(String(repeating: "a", count: 63)).srt", key, "srt", false),
            ("long hash", "https://subtitles.vortx.tv/r2/subs/\(key)/\(String(repeating: "a", count: 65)).srt", key, "srt", false),
            ("uppercase hash", "https://subtitles.vortx.tv/r2/subs/\(key)/\(String(repeating: "A", count: 64)).srt", key, "srt", false),
            ("nonhex hash", "https://subtitles.vortx.tv/r2/subs/\(key)/\(String(repeating: "g", count: 64)).srt", key, "srt", false),
            ("uppercase extension", "https://subtitles.vortx.tv/r2/subs/\(key)/\(hash).SRT", key, "srt", false),
            ("format mismatch", canonical, key, "vtt", false),
            ("unsupported format", "https://subtitles.vortx.tv/r2/subs/\(key)/\(hash).txt", key, "txt", false),
            ("double slash", "https://subtitles.vortx.tv/r2/subs/\(key)//\(hash).srt", key, "srt", false),
        ]

        for entry in cases {
            let actual = URL(string: entry.raw).map {
                SubtitlePoolClient.isValidDownloadURL(
                    $0, contentKey: entry.expectedKey, format: entry.format
                )
            } ?? false
            expect(actual == entry.valid, "URL grammar: \(entry.name)")
        }
    }

    @MainActor
    private static func testAuthorizationAndDecode() async {
        let pooled = pooled()

        MoatConsent.contributeAndConsume = false
        let optedOut = SubtitleTransportProbe()
        let optedOutTransport: SubtitlePoolClient.Transport = { request in
            await optedOut.perform(request)
        }
        let optedOutFetch = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: optedOutTransport
        )
        let optedOutDownload = await SubtitlePoolClient.downloadUsing(
            pooled,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: optedOutTransport
        )
        await SubtitlePoolClient.uploadUsing(
            contentKey: contentKey,
            lang: "en",
            fingerprint: nil,
            origin: "embedded",
            format: "srt",
            text: "1\n00:00:00,000 --> 00:00:01,000\nHello",
            transport: optedOutTransport
        )
        await SubtitlePoolClient.postOffsetUsing(
            contentKey: contentKey,
            lang: "en",
            fingerprint: nil,
            offsetMs: 250,
            transport: optedOutTransport
        )
        let optedOutCount = await optedOut.count()
        expect(optedOutFetch.subs.isEmpty && optedOutFetch.offsetMs == nil
               && optedOutDownload == nil && optedOutCount == 0,
               "master consent off makes every subtitle pool operation zero-transport")

        MoatConsent.contributeAndConsume = true
        let signedOutProvider = InvocationCounter()
        let signedOutTransport = SubtitleTransportProbe()
        let signedOutFetch = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: false,
            moatProvider: { _ in
                await signedOutProvider.increment()
                return "must-not-run"
            },
            transport: { request in await signedOutTransport.perform(request) }
        )
        let signedOutDownload = await SubtitlePoolClient.downloadUsing(
            pooled,
            isSignedIn: false,
            moatProvider: { _ in
                await signedOutProvider.increment()
                return "must-not-run"
            },
            transport: { request in await signedOutTransport.perform(request) }
        )
        let signedOutProviderCount = await signedOutProvider.count()
        let signedOutTransportCount = await signedOutTransport.count()
        expect(signedOutFetch.subs.isEmpty && signedOutFetch.offsetMs == nil
               && signedOutDownload == nil && signedOutProviderCount == 0
               && signedOutTransportCount == 0,
               "signed-out reads are zero-provider and zero-transport")

        let missingMoat = SubtitleTransportProbe()
        let missingMoatTransport: SubtitlePoolClient.Transport = { request in
            await missingMoat.perform(request)
        }
        _ = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in nil },
            transport: missingMoatTransport
        )
        _ = await SubtitlePoolClient.downloadUsing(
            pooled,
            isSignedIn: true,
            moatProvider: { _ in "" },
            transport: missingMoatTransport
        )
        let missingMoatCount = await missingMoat.count()
        expect(missingMoatCount == 0,
               "missing or empty moat evidence makes subtitle reads and downloads zero-transport")

        let closedAfterMoat = SubtitleTransportProbe()
        _ = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in
                SourceIndexLifecycleClock.rotateSession()
                return "moat"
            },
            transport: { request in await closedAfterMoat.perform(request) }
        )
        let closedAfterMoatCount = await closedAfterMoat.count()
        expect(closedAfterMoatCount == 0,
               "session generation closing during moat acquisition prevents subtitle transport")

        let optedOutAfterMoat = SubtitleTransportProbe()
        _ = await SubtitlePoolClient.downloadUsing(
            pooled,
            isSignedIn: true,
            moatProvider: { _ in
                SourceIndexLifecycleClock.rotateConsent()
                MoatConsent.contributeAndConsume = false
                return "moat"
            },
            transport: { request in await optedOutAfterMoat.perform(request) }
        )
        let optedOutAfterMoatCount = await optedOutAfterMoat.count()
        expect(optedOutAfterMoatCount == 0,
               "consent generation closing during moat acquisition prevents subtitle download transport")

        MoatConsent.contributeAndConsume = true
        let validBody = responseBody(url: pooled.url, offsetMs: 250)
        let authorized = SubtitleTransportProbe(
            response: .init(data: validBody, statusCode: 200)
        )
        let authorizedResult = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await authorized.perform(request) }
        )
        let authorizedRequests = await authorized.captured()
        expect(authorizedResult.subs == [pooled] && authorizedResult.offsetMs == 250
               && authorizedRequests.count == 1
               && authorizedRequests.first?.url?.host == "subtitles.vortx.tv"
               && authorizedRequests.first?.url?.path == "/subs"
               && authorizedRequests.first?.value(forHTTPHeaderField: MoatToken.header) == "moat",
               "authorized subtitle read ignores custom base, publishes canonical row, and stamps moat")

        let poisonedURL = URL(
            string: "https://cdn.example.invalid/r2/subs/\(contentKey)/\(canonicalHash).srt"
        )!
        let poisoned = SubtitleTransportProbe(
            response: .init(data: responseBody(url: poisonedURL), statusCode: 200)
        )
        let poisonedResult = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await poisoned.perform(request) }
        )
        let poisonedRequests = await poisoned.count()
        expect(poisonedResult.subs.isEmpty && poisonedRequests == 1,
               "poisoned worker JSON cannot create a downloadable model")

        let crafted = SubtitlePoolClient.PooledSubtitle(
            id: 2,
            contentKey: contentKey,
            lang: "en",
            format: "srt",
            origin: "embedded",
            score: 0,
            url: poisonedURL
        )
        let craftedProvider = InvocationCounter()
        let craftedTransport = SubtitleTransportProbe()
        let craftedResult = await SubtitlePoolClient.downloadUsing(
            crafted,
            isSignedIn: true,
            moatProvider: { _ in
                await craftedProvider.increment()
                return "moat"
            },
            transport: { request in await craftedTransport.perform(request) }
        )
        let craftedProviderCount = await craftedProvider.count()
        let craftedTransportCount = await craftedTransport.count()
        expect(craftedResult == nil && craftedProviderCount == 0 && craftedTransportCount == 0,
               "directly crafted off-origin subtitle is zero-provider and zero-transport")

        let oversizedUpload = SubtitleTransportProbe()
        await SubtitlePoolClient.uploadUsing(
            contentKey: contentKey,
            lang: "en",
            fingerprint: nil,
            origin: "embedded",
            format: "srt",
            text: String(repeating: "x", count: SubtitlePoolClient.subtitleBodyMaxBytes + 1),
            transport: { request in await oversizedUpload.perform(request) }
        )
        let oversizedUploadCount = await oversizedUpload.count()
        expect(oversizedUploadCount == 0,
               "raised remote upload cap cannot authorize a Worker-oversized subtitle")

        let redirectStatus = SubtitleTransportProbe(
            response: .init(data: Data(), statusCode: 302)
        )
        let redirectResult = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await redirectStatus.perform(request) }
        )
        expect(redirectResult.subs.isEmpty && redirectResult.offsetMs == nil,
               "3xx subtitle index response fails soft")
    }

    @MainActor
    private static func testTransportLifecycleFences() async {
        MoatConsent.contributeAndConsume = true
        let fetchPooled = pooled(hash: String(repeating: "b", count: 64))
        let validBody = responseBody(url: fetchPooled.url, offsetMs: 500)

        let sessionFetchProbe = SubtitleTransportProbe(
            response: .init(data: validBody, statusCode: 200)
        )
        let sessionFetch = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in
                let response = await sessionFetchProbe.perform(request)
                SourceIndexLifecycleClock.rotateSession()
                return response
            }
        )
        let sessionFetchCount = await sessionFetchProbe.count()
        expect(sessionFetchCount == 1 && sessionFetch.subs.isEmpty && sessionFetch.offsetMs == nil,
               "session rotation during fetch transport blocks decoded row and offset publication")

        let consentFetchProbe = SubtitleTransportProbe(
            response: .init(data: validBody, statusCode: 200)
        )
        let consentFetch = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in
                let response = await consentFetchProbe.perform(request)
                SourceIndexLifecycleClock.rotateConsent()
                MoatConsent.contributeAndConsume = false
                return response
            }
        )
        let consentFetchCount = await consentFetchProbe.count()
        expect(consentFetchCount == 1 && consentFetch.subs.isEmpty && consentFetch.offsetMs == nil,
               "consent rotation during fetch transport blocks decoded row and offset publication")

        MoatConsent.contributeAndConsume = true
        let sessionDownload = pooled(hash: String(repeating: "c", count: 64))
        let sessionLifecycle = SourceIndexLifecycleClock.snapshot()
        let sessionFile = expectedTemporaryFile(for: sessionDownload, lifecycle: sessionLifecycle)
        try? FileManager.default.removeItem(at: sessionFile)
        let sessionDownloadProbe = SubtitleTransportProbe(
            response: .init(data: Data("session subtitle".utf8), statusCode: 200)
        )
        let sessionDownloadResult = await SubtitlePoolClient.downloadUsing(
            sessionDownload,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in
                let response = await sessionDownloadProbe.perform(request)
                SourceIndexLifecycleClock.rotateSession()
                return response
            }
        )
        let sessionDownloadCount = await sessionDownloadProbe.count()
        expect(sessionDownloadCount == 1 && sessionDownloadResult == nil
               && !FileManager.default.fileExists(atPath: sessionFile.path),
               "session rotation during download transport blocks temp-file and cache publication")

        let consentDownload = pooled(hash: String(repeating: "d", count: 64))
        let consentLifecycle = SourceIndexLifecycleClock.snapshot()
        let consentFile = expectedTemporaryFile(for: consentDownload, lifecycle: consentLifecycle)
        try? FileManager.default.removeItem(at: consentFile)
        let consentDownloadProbe = SubtitleTransportProbe(
            response: .init(data: Data("consent subtitle".utf8), statusCode: 200)
        )
        let consentDownloadResult = await SubtitlePoolClient.downloadUsing(
            consentDownload,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in
                let response = await consentDownloadProbe.perform(request)
                SourceIndexLifecycleClock.rotateConsent()
                MoatConsent.contributeAndConsume = false
                return response
            }
        )
        let consentDownloadCount = await consentDownloadProbe.count()
        expect(consentDownloadCount == 1 && consentDownloadResult == nil
               && !FileManager.default.fileExists(atPath: consentFile.path),
               "consent rotation during download transport blocks temp-file and cache publication")

        MoatConsent.contributeAndConsume = true
        let freshProbe = SubtitleTransportProbe(
            response: .init(data: Data("fresh subtitle".utf8), statusCode: 200)
        )
        let freshResult = await SubtitlePoolClient.downloadUsing(
            consentDownload,
            isSignedIn: true,
            moatProvider: { _ in "fresh-moat" },
            transport: { request in await freshProbe.perform(request) }
        )
        let freshRequests = await freshProbe.captured()
        expect(freshResult != nil && freshRequests.count == 1
               && freshRequests.first?.value(forHTTPHeaderField: MoatToken.header) == "fresh-moat",
               "fresh authorized download performs transport and publishes a scoped local file")
        if let freshResult { try? FileManager.default.removeItem(at: freshResult) }
    }

    @MainActor
    private static func testDiskCacheLifecycle() async {
        MoatConsent.contributeAndConsume = true
        let repeated = pooled(hash: String(repeating: "e", count: 64))
        let firstLifecycle = SourceIndexLifecycleClock.snapshot()
        let firstExpected = expectedTemporaryFile(for: repeated, lifecycle: firstLifecycle)
        try? FileManager.default.removeItem(at: firstExpected)
        let firstProbe = SubtitleTransportProbe(
            response: .init(data: Data("generation one".utf8), statusCode: 200)
        )
        let firstFile = await SubtitlePoolClient.downloadUsing(
            repeated,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await firstProbe.perform(request) }
        )

        SourceIndexLifecycleClock.rotateSession()
        let secondLifecycle = SourceIndexLifecycleClock.snapshot()
        let secondExpected = expectedTemporaryFile(for: repeated, lifecycle: secondLifecycle)
        try? FileManager.default.removeItem(at: secondExpected)
        let secondProbe = SubtitleTransportProbe(
            response: .init(data: Data("generation two".utf8), statusCode: 200)
        )
        let secondFile = await SubtitlePoolClient.downloadUsing(
            repeated,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await secondProbe.perform(request) }
        )
        let replacementBody = secondFile.flatMap { try? Data(contentsOf: $0) }
        expect(firstFile == firstExpected && secondFile == secondExpected
               && !FileManager.default.fileExists(atPath: firstExpected.path)
               && replacementBody == Data("generation two".utf8),
               "generation replacement removes the old local file and publishes only the new file")

        let cacheHitProbe = SubtitleTransportProbe()
        let cacheHit = await SubtitlePoolClient.downloadUsing(
            repeated,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await cacheHitProbe.perform(request) }
        )
        let cacheHitTransportCount = await cacheHitProbe.count()
        expect(cacheHit == secondFile && cacheHitTransportCount == 0,
               "surviving generation replacement cache-hits without transport")

        let evictionProbe = SubtitleTransportProbe(
            response: .init(data: Data("cache entry".utf8), statusCode: 200)
        )
        var entries: [(pooled: SubtitlePoolClient.PooledSubtitle, local: URL)] = []
        for index in 0...256 {
            let hash = String(format: "%064llx", UInt64(index + 0x1000))
            let entry = pooled(hash: hash)
            if let local = await SubtitlePoolClient.downloadUsing(
                entry,
                isSignedIn: true,
                moatProvider: { _ in "moat" },
                transport: { request in await evictionProbe.perform(request) }
            ) {
                entries.append((entry, local))
            }
        }
        let evictionTransportCount = await evictionProbe.count()
        let firstEvicted = entries.first.map {
            !FileManager.default.fileExists(atPath: $0.local.path)
        } ?? false
        let lastSurvives = entries.last.map {
            FileManager.default.fileExists(atPath: $0.local.path)
        } ?? false
        expect(entries.count == 257 && evictionTransportCount == 257 && firstEvicted && lastSurvives,
               "257th cache insertion evicts metadata and deletes the oldest local file")

        let survivingProbe = SubtitleTransportProbe()
        let survivingHit: URL?
        if let last = entries.last {
            survivingHit = await SubtitlePoolClient.downloadUsing(
                last.pooled,
                isSignedIn: true,
                moatProvider: { _ in "moat" },
                transport: { request in await survivingProbe.perform(request) }
            )
        } else {
            survivingHit = nil
        }
        let survivingTransportCount = await survivingProbe.count()
        expect(survivingHit == entries.last?.local && survivingTransportCount == 0,
               "post-eviction surviving entry cache-hits without transport")

        if let secondFile { try? FileManager.default.removeItem(at: secondFile) }
        for entry in entries { try? FileManager.default.removeItem(at: entry.local) }
    }

    private enum CallerInvalidation: String, CaseIterable {
        case session
        case consent
        case content
    }

    @MainActor
    private static func apply(
        _ invalidation: CallerInvalidation,
        currentContentKey: inout String,
        isSignedIn: inout Bool
    ) {
        switch invalidation {
        case .session:
            SourceIndexLifecycleClock.rotateSession()
        case .consent:
            SourceIndexLifecycleClock.rotateConsent()
            MoatConsent.contributeAndConsume = false
        case .content:
            currentContentKey = "imdb:tt7654321"
        }
    }

    /// Exercises the exact shared RequestOwnership value used by both production player callers. Each delayed
    /// stage is checked against both the account/content fence and its opaque owner before publication or cleanup.
    @MainActor
    private static func testCallerRequestOwnership() {
        let delayedResult = (subs: [pooled()], offsetMs: 750)
        let delayedLocalFile = URL(fileURLWithPath: "/tmp/delayed-community-subtitle.srt")

        for invalidation in CallerInvalidation.allCases {
            MoatConsent.contributeAndConsume = true
            var currentKey = contentKey
            var signedIn = true
            var fetchOwnership = SubtitlePoolClient.RequestOwnership()
            let fetchKey = "\(contentKey)#fingerprint"
            let fetchID = fetchOwnership.beginFetch(dedupeKey: fetchKey)!
            let fetchFence = SubtitlePoolClient.PublicationFence(contentKey: contentKey)
            apply(invalidation, currentContentKey: &currentKey, isSignedIn: &signedIn)
            var publishedSubs: [SubtitlePoolClient.PooledSubtitle] = []
            var publishedOffset: Int?
            if fetchFence.permits(currentContentKey: currentKey, isSignedIn: signedIn),
               fetchOwnership.finishFetch(fetchID, published: true) {
                publishedSubs = delayedResult.subs
                publishedOffset = delayedResult.offsetMs
            } else {
                fetchOwnership.finishFetch(fetchID, published: false)
            }
            MoatConsent.contributeAndConsume = true
            let retryFetchKey = "\(currentKey)#fingerprint"
            let retryFetchID = fetchOwnership.beginFetch(dedupeKey: retryFetchKey)
            let retryFetchSucceeded = retryFetchID.map {
                fetchOwnership.finishFetch($0, published: true)
            } ?? false
            expect(publishedSubs.isEmpty && publishedOffset == nil
                   && !fetchOwnership.ownsFetch(fetchID) && retryFetchSucceeded,
                   "\(invalidation.rawValue) rotation rejects delayed fetch, releases owner, and permits retry")

            MoatConsent.contributeAndConsume = true
            currentKey = contentKey
            signedIn = true
            var downloadOwnership = SubtitlePoolClient.RequestOwnership()
            let downloadID = downloadOwnership.beginDownload()
            let downloadFence = SubtitlePoolClient.PublicationFence(contentKey: contentKey)
            apply(invalidation, currentContentKey: &currentKey, isSignedIn: &signedIn)
            var handedOffFile: URL?
            if downloadFence.permits(currentContentKey: currentKey, isSignedIn: signedIn),
               downloadOwnership.ownsDownload(downloadID) {
                handedOffFile = delayedLocalFile
            } else {
                downloadOwnership.finishDownload(downloadID)
            }
            MoatConsent.contributeAndConsume = true
            let retryDownloadID = downloadOwnership.beginDownload()
            let retryExternalID = downloadOwnership.beginExternal(after: retryDownloadID)
            let retryDownloadSucceeded = retryExternalID.map {
                downloadOwnership.finishExternal($0)
            } ?? false
            expect(handedOffFile == nil && !downloadOwnership.ownsDownload(downloadID)
                   && retryDownloadSucceeded,
                   "\(invalidation.rawValue) rotation rejects delayed download handoff and permits retry")

            MoatConsent.contributeAndConsume = true
            currentKey = contentKey
            signedIn = true
            var externalOwnership = SubtitlePoolClient.RequestOwnership()
            let initialDownloadID = externalOwnership.beginDownload()
            let externalID = externalOwnership.beginExternal(after: initialDownloadID)!
            let externalFence = SubtitlePoolClient.PublicationFence(contentKey: contentKey)
            apply(invalidation, currentContentKey: &currentKey, isSignedIn: &signedIn)
            var publishedSelection = false
            if externalFence.permits(currentContentKey: currentKey, isSignedIn: signedIn),
               externalOwnership.finishExternal(externalID) {
                publishedSelection = true
            } else {
                externalOwnership.finishExternal(externalID)
            }
            MoatConsent.contributeAndConsume = true
            let freshDownloadID = externalOwnership.beginDownload()
            let freshExternalID = externalOwnership.beginExternal(after: freshDownloadID)
            let freshExternalSucceeded = freshExternalID.map {
                externalOwnership.finishExternal($0)
            } ?? false
            expect(!publishedSelection && !externalOwnership.ownsExternal(externalID)
                   && freshExternalSucceeded,
                   "\(invalidation.rawValue) rotation rejects delayed player-add completion and permits retry")
        }

        MoatConsent.contributeAndConsume = true
        var overlappingFetches = SubtitlePoolClient.RequestOwnership()
        let oldFetchID = overlappingFetches.beginFetch(dedupeKey: "\(contentKey)#rip-a")!
        let oldFetchFence = SubtitlePoolClient.PublicationFence(contentKey: contentKey)
        let newFetchID = overlappingFetches.beginFetch(dedupeKey: "\(contentKey)#rip-b")!
        var staleRowsPublished = false
        if oldFetchFence.permits(currentContentKey: contentKey, isSignedIn: true),
           overlappingFetches.finishFetch(oldFetchID, published: true) {
            staleRowsPublished = true
        }
        let newFetchPublished = overlappingFetches.finishFetch(newFetchID, published: true)
        expect(!staleRowsPublished && newFetchPublished,
               "same-content fingerprint B owns publication and stale fetch A cannot overwrite it")

        var sameURLDownloads = SubtitlePoolClient.RequestOwnership()
        let oldDownloadID = sameURLDownloads.beginDownload()
        let newDownloadID = sameURLDownloads.beginDownload()
        let staleDownloadReleased = sameURLDownloads.finishDownload(oldDownloadID)
        expect(!staleDownloadReleased && sameURLDownloads.ownsDownload(newDownloadID),
               "same-URL stale download A cannot clear active download B")

        let oldExternalID = sameURLDownloads.beginExternal(after: newDownloadID)!
        let replacementDownloadID = sameURLDownloads.beginDownload()
        let replacementExternalID = sameURLDownloads.beginExternal(after: replacementDownloadID)!
        let staleExternalReleased = sameURLDownloads.finishExternal(oldExternalID)
        expect(!staleExternalReleased && sameURLDownloads.ownsExternal(replacementExternalID),
               "same-URL stale player-add A cannot clear active player-add B")

        var resetOwnership = SubtitlePoolClient.RequestOwnership()
        let resetFetchID = resetOwnership.beginFetch(dedupeKey: "\(contentKey)#rip")!
        let resetDownloadID = resetOwnership.beginDownload()
        resetOwnership.invalidate()
        let resetRetryID = resetOwnership.beginFetch(dedupeKey: "\(contentKey)#rip")
        expect(!resetOwnership.ownsFetch(resetFetchID) && !resetOwnership.ownsDownload(resetDownloadID)
               && resetRetryID != nil,
               "content/source/episode reset invalidates every owner and clears fetch de-duplication")
    }

    @MainActor
    private static func testBoundedStreamingTransport() async {
        var absentLength = SubtitlePoolClient.BoundedBodyAccumulator(maxBytes: 8)
        let absentAccepted = absentLength.acceptsDeclaredContentLength(nil)
            && absentLength.append(Data(repeating: 1, count: 8))
            && !absentLength.append(Data([1]))
        expect(absentAccepted && absentLength.data.isEmpty
               && absentLength.receivedByteCount == 9,
               "absent Content-Length is incrementally capped and partial bytes are discarded")

        var malformedLength = SubtitlePoolClient.BoundedBodyAccumulator(maxBytes: 8)
        let malformedAccepted = malformedLength.acceptsDeclaredContentLength("not-a-number")
            && malformedLength.append(Data(repeating: 1, count: 8))
            && !malformedLength.append(Data([1]))
        expect(malformedAccepted && malformedLength.data.isEmpty,
               "malformed Content-Length falls back to incremental cap enforcement")

        var dishonestLength = SubtitlePoolClient.BoundedBodyAccumulator(maxBytes: 8)
        let dishonestRejected = dishonestLength.acceptsDeclaredContentLength("1")
            && dishonestLength.append(Data(repeating: 1, count: 8))
            && !dishonestLength.append(Data([1]))
        expect(dishonestRejected && dishonestLength.data.isEmpty,
               "dishonest undersized Content-Length cannot bypass the actual-byte cap")

        let declaredOversize = SubtitlePoolClient.BoundedBodyAccumulator(maxBytes: 8)
        expect(!declaredOversize.acceptsDeclaredContentLength("9")
               && declaredOversize.receivedByteCount == 0,
               "declared oversize is rejected before any body byte is buffered")

        do {
            let server = try RedirectServerHarness()
            defer { server.stop() }
            func request(_ mode: String, _ size: Int) -> URLRequest {
                URLRequest(url: URL(
                    string: "http://127.0.0.1:\(server.sourcePort)/bytes/\(mode)/\(size)"
                )!)
            }

            let exactIndex = await SubtitlePoolClient.liveTransportOutcome(
                request("declared", SubtitlePoolClient.indexResponseMaxBytes),
                maxBytes: SubtitlePoolClient.indexResponseMaxBytes
            )
            expect(exactIndex.response?.data.count == SubtitlePoolClient.indexResponseMaxBytes
                   && !exactIndex.didCancelTask,
                   "streamed index response accepts exactly 64 KiB")

            let exactSubtitle = await SubtitlePoolClient.liveTransportOutcome(
                request("declared", SubtitlePoolClient.subtitleBodyMaxBytes),
                maxBytes: SubtitlePoolClient.subtitleBodyMaxBytes
            )
            expect(exactSubtitle.response?.data.count == SubtitlePoolClient.subtitleBodyMaxBytes
                   && !exactSubtitle.didCancelTask,
                   "streamed subtitle response accepts exactly 1 MiB")

            let declaredOver = await SubtitlePoolClient.liveTransportOutcome(
                request("declared", SubtitlePoolClient.indexResponseMaxBytes + 1),
                maxBytes: SubtitlePoolClient.indexResponseMaxBytes
            )
            expect(declaredOver.response == nil && declaredOver.didCancelTask
                   && declaredOver.bufferedByteCount == 0 && declaredOver.receivedByteCount == 0,
                   "declared 64 KiB plus one response is cancelled before body buffering")

            let absentOver = await SubtitlePoolClient.liveTransportOutcome(
                request("absent", SubtitlePoolClient.indexResponseMaxBytes + 1),
                maxBytes: SubtitlePoolClient.indexResponseMaxBytes
            )
            expect(absentOver.response == nil && absentOver.didCancelTask
                   && absentOver.bufferedByteCount == 0
                   && absentOver.receivedByteCount > SubtitlePoolClient.indexResponseMaxBytes,
                   "absent-length 64 KiB plus one response is cancelled on the actual byte stream")

            let gzipOver = await SubtitlePoolClient.liveTransportOutcome(
                request("gzip", SubtitlePoolClient.indexResponseMaxBytes + 1),
                maxBytes: SubtitlePoolClient.indexResponseMaxBytes
            )
            expect(gzipOver.response == nil && gzipOver.didCancelTask
                   && gzipOver.bufferedByteCount == 0,
                   "understated compressed length cannot publish a decoded body over the cap")

            let slowTask = Task {
                await SubtitlePoolClient.liveTransportOutcome(
                    request("slow", 4 * 1024 * 1024),
                    maxBytes: SubtitlePoolClient.subtitleBodyMaxBytes
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            slowTask.cancel()
            let cancelled = await slowTask.value
            expect(cancelled.response == nil && cancelled.didCancelTask
                   && cancelled.bufferedByteCount == 0,
                   "caller cancellation explicitly cancels the live task and discards partial bytes")

            var postRequest = URLRequest(
                url: URL(string: "http://127.0.0.1:\(server.sourcePort)/post-large")!
            )
            postRequest.httpMethod = "POST"
            postRequest.httpBody = Data("{}".utf8)
            let discardedPost = await SubtitlePoolClient.liveDiscardTransportOutcome(postRequest)
            let serverState = try server.state()
            expect(discardedPost.response == nil && discardedPost.didCancelTask
                   && discardedPost.bufferedByteCount == 0
                   && discardedPost.receivedByteCount == 0 && serverState.postRequests == 1,
                   "POST response is cancelled at headers without response-body buffering")
        } catch {
            expect(false, "bounded streaming server starts and completes: \(error)")
        }

        MoatConsent.contributeAndConsume = true
        let responseURL = pooled(hash: String(repeating: "7", count: 64)).url
        let validIndexBody = responseBody(url: responseURL, offsetMs: 250)
        var exactIndexBody = validIndexBody
        exactIndexBody.append(Data(
            repeating: 0x20,
            count: SubtitlePoolClient.indexResponseMaxBytes - validIndexBody.count
        ))
        let exactIndexProbe = SubtitleTransportProbe(
            response: .init(data: exactIndexBody, statusCode: 200)
        )
        let exactIndexResult = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await exactIndexProbe.perform(request) }
        )
        expect(exactIndexResult.subs.count == 1 && exactIndexResult.offsetMs == 250,
               "injected GET /subs body at exactly 64 KiB is accepted")

        var oversizedIndexBody = exactIndexBody
        oversizedIndexBody.append(0x20)
        let oversizedIndexProbe = SubtitleTransportProbe(
            response: .init(data: oversizedIndexBody, statusCode: 200)
        )
        let oversizedIndexResult = await SubtitlePoolClient.fetchPooledUsing(
            contentKey: contentKey,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await oversizedIndexProbe.perform(request) }
        )
        expect(oversizedIndexResult.subs.isEmpty && oversizedIndexResult.offsetMs == nil,
               "injected GET /subs body at 64 KiB plus one cannot publish rows or offset")

        let oversizedDownload = pooled(hash: String(repeating: "8", count: 64))
        let lifecycle = SourceIndexLifecycleClock.snapshot()
        let expectedFile = expectedTemporaryFile(for: oversizedDownload, lifecycle: lifecycle)
        try? FileManager.default.removeItem(at: expectedFile)
        let oversizedDownloadProbe = SubtitleTransportProbe(
            response: .init(
                data: Data(repeating: 1, count: SubtitlePoolClient.subtitleBodyMaxBytes + 1),
                statusCode: 200
            )
        )
        let oversizedDownloadResult = await SubtitlePoolClient.downloadUsing(
            oversizedDownload,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await oversizedDownloadProbe.perform(request) }
        )
        let oversizedPublishedNoFile = !FileManager.default.fileExists(atPath: expectedFile.path)
        let exactDownloadProbe = SubtitleTransportProbe(
            response: .init(
                data: Data(repeating: 2, count: SubtitlePoolClient.subtitleBodyMaxBytes),
                statusCode: 200
            )
        )
        let exactDownloadResult = await SubtitlePoolClient.downloadUsing(
            oversizedDownload,
            isSignedIn: true,
            moatProvider: { _ in "moat" },
            transport: { request in await exactDownloadProbe.perform(request) }
        )
        let exactDownloadTransportCount = await exactDownloadProbe.count()
        expect(oversizedDownloadResult == nil
               && oversizedPublishedNoFile
               && exactDownloadResult == expectedFile && exactDownloadTransportCount == 1,
               "1 MiB plus one download publishes no temp/cache entry and exact-cap retry succeeds")
        if let exactDownloadResult { try? FileManager.default.removeItem(at: exactDownloadResult) }
    }

    @MainActor
    private static func testRealRedirectTransport() async {
        do {
            let server = try RedirectServerHarness()
            defer { server.stop() }
            let statuses = [301, 302, 303, 307, 308]
            var preservedStatuses = true
            for status in statuses {
                for destination in ["same", "cross"] {
                    let url = URL(
                        string: "http://127.0.0.1:\(server.sourcePort)/redirect/\(status)/\(destination)"
                    )!
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("redirect-moat", forHTTPHeaderField: MoatToken.header)
                    let response = await SubtitlePoolClient.liveTransport(request)
                    preservedStatuses = preservedStatuses && response?.statusCode == status
                }
            }
            let redirected = try server.state()
            expect(preservedStatuses && redirected.redirectRequests == 10,
                   "real 301/302/303/307/308 responses remain 3xx soft failures")
            expect(redirected.sameTargetRequests == 0 && redirected.crossTargetRequests == 0
                   && redirected.sameTargetMoat == nil && redirected.crossTargetMoat == nil,
                   "same-origin and cross-origin redirect targets receive zero requests and zero moat headers")

            let okURL = URL(string: "http://127.0.0.1:\(server.sourcePort)/ok")!
            var okRequest = URLRequest(url: okURL)
            okRequest.httpMethod = "GET"
            okRequest.setValue("same-origin-moat", forHTTPHeaderField: MoatToken.header)
            let okResponse = await SubtitlePoolClient.liveTransport(okRequest)
            let okState = try server.state()
            expect(okResponse?.statusCode == 200 && okResponse?.data == Data("ok".utf8)
                   && okState.okRequests == 1 && okState.okMoat == "same-origin-moat",
                   "exact same-origin 200 receives moat and succeeds")
        } catch {
            expect(false, "real two-listener redirect harness starts and completes: \(error)")
        }
    }

    @MainActor
    static func main() async {
        testURLGrammar()
        await testAuthorizationAndDecode()
        await testTransportLifecycleFences()
        await testDiskCacheLifecycle()
        testCallerRequestOwnership()
        await testBoundedStreamingTransport()
        await testRealRedirectTransport()

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
