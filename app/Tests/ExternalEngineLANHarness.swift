// EXTERNAL ENGINE MODE: the end-to-end gate.
//
// WHAT THIS PROVES, and why the other tests are not enough. `VortXEngineHostPolicyTests` proves the decisions
// in isolation; a green build proves the code compiles. Neither proves the thing the whole feature rests on:
// that a REAL AVFoundation player, in one process, will consume the exact resource shape our remux server
// emits, from a DIFFERENT process, over a NON-LOOPBACK address, through a capability-gated path prefix,
// continuously, resolving every relative child URI against that mount.
//
// This runs both halves for real:
//   - a server process binding 0.0.0.0 that routes EVERY request through the production
//     `VortXEngineHostPolicy.route`, so the capability gate under test is the shipping one and not a mock
//   - a player process that loads `http://<LAN IP>:<port>/r/<capability>/master.m3u8` in AVPlayer, plays, and
//     reports whether the clock actually advanced
//
// It also proves the NEGATIVE, which matters more than the positive: an unpaired peer that guesses the port
// but not the capability gets nothing at all, not even an error body.
//
// HONEST LIMIT, stated because the alternative is implying something untrue. This is macOS AVFoundation on one
// machine, reaching itself over its own LAN address (192.168.x.x, not 127.0.0.1, so it is real socket traffic
// through the network stack rather than the loopback shortcut). It exercises the transport, the relative-URI
// mechanics, the capability gate, the ATS posture and continuous playback. It does NOT exercise tvOS Dolby
// Vision negotiation against a LAN HLS origin, which needs an actual Apple TV and an actual DV source. That
// remains the one thing only a device soak can settle.
//
// BUILD AND RUN. Swift only permits top-level code in a file literally named `main.swift`, so the harness is
// copied to that name in a scratch directory rather than being restructured around an @main type, which would
// have added a layer of indirection for no benefit to a script:
//   cd /Users/daksh/vortx-extengine/app
//   mkdir -p /tmp/vortx-lan && cp Tests/ExternalEngineLANHarness.swift /tmp/vortx-lan/main.swift
//   xcrun swiftc -O -o /tmp/vortx-lan/harness \
//     SourcesShared/VortXEngineHostPolicy.swift /tmp/vortx-lan/main.swift
//   /tmp/vortx-lan/harness
//
// Requires ffmpeg on PATH to synthesize the test asset (any recent build; it only needs libx264 and the
// fragmented-MP4 HLS muxer).

import Foundation
import AVFoundation
import Network

// MARK: - Harness plumbing

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vortx-lan-harness", isDirectory: true)

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

func shell(_ command: String) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-lc", command]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

/// The machine's own non-loopback address. The whole point is to NOT use 127.0.0.1: loopback takes a shortcut
/// through the stack and would prove nothing about a LAN.
func lanAddress() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var best: String?
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let interface = current.pointee
        let name = String(cString: interface.ifa_name)
        if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
           (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !text.hasPrefix("169.254"), text != "127.0.0.1" {
                    if name.hasPrefix("en") { return text }
                    if best == nil { best = text }
                }
            }
        }
        pointer = interface.ifa_next
    }
    return best
}

// MARK: - Test asset

/// Generate the exact resource shape `VortXRemuxHLSServer` emits: a master pointing at `media.m3u8`, an
/// `#EXT-X-MAP:URI="init.mp4"`, and `seg{N}.m4s` segments. Every URI relative, which is the property the whole
/// capability-prefix design depends on.
func makeAsset() {
    try? FileManager.default.removeItem(at: scratch)
    try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let status = shell("""
        cd '\(scratch.path)' && ffmpeg -y -hide_banner -loglevel error \
          -f lavfi -i testsrc2=size=1280x720:rate=24 \
          -f lavfi -i sine=frequency=440:sample_rate=48000 \
          -t 20 -c:v libx264 -preset ultrafast -g 48 -pix_fmt yuv420p -c:a aac -b:a 96k \
          -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
          -hls_fmp4_init_filename init.mp4 -hls_segment_filename 'seg%d.m4s' media.m3u8
        """)
    guard status == 0 else { fail("ffmpeg could not build the test asset (is ffmpeg on PATH?)") }
    // Master with one variant, mirroring DVPlaybackPolicy.masterPlaylistData's relative form.
    let master = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720
    media.m3u8

    """
    try! master.write(to: scratch.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
    guard FileManager.default.fileExists(atPath: scratch.appendingPathComponent("init.mp4").path) else {
        fail("asset has no init.mp4; the fMP4 HLS muxer did not run")
    }
}

// MARK: - The server half

/// Access log: what AVFoundation actually fetched, in order. This is the evidence, not a proxy for it.
final class AccessLog: @unchecked Sendable {
    private var entries: [(String, String)] = []
    private let lock = NSLock()
    func record(_ verdict: String, _ path: String) {
        lock.lock(); entries.append((verdict, path)); lock.unlock()
    }
    var served: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.0 == "200" }.map { $0.1 }
    }
    var all: [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// A server that routes every request through the PRODUCTION policy. It is deliberately not a mock: the point
/// is to exercise `VortXEngineHostPolicy.route` exactly as `VortXRemuxHLSServer.route` calls it, including the
/// capability check, the prefix strip and the silent close on a bad credential.
final class HarnessServer: @unchecked Sendable {
    private let capability: String
    private let log: AccessLog
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "vortx.lanharness")
    private(set) var port: UInt16 = 0

    init(capability: String, log: AccessLog) {
        self.capability = capability
        self.log = log
    }

    func start() -> Bool {
        let bind = VortXEngineHostPolicy.bindHost(capability: capability)
        guard bind == .allInterfaces else { fail("policy refused to bind the LAN for a valid capability") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bind.hostString), port: .any)
        guard let created = try? NWListener(using: params) else { return false }
        created.newConnectionHandler = { [weak self] in self?.accept($0) }
        let ready = DispatchSemaphore(value: 0)
        created.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        created.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let bound = created.port?.rawValue, bound != 0 else { return false }
        listener = created
        port = bound
        return true
    }

    func stop() { listener?.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }
            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }
            guard let split = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if done || accumulated.count > 64_000 { connection.cancel() } else {
                    self.read(connection, buffer: accumulated)
                }
                return
            }
            let header = String(
                data: accumulated.subdata(in: accumulated.startIndex..<split.lowerBound), encoding: .utf8) ?? ""
            self.route(connection, header: header)
        }
    }

    private func route(_ connection: NWConnection, header: String) {
        switch VortXEngineHostPolicy.route(header: header, capability: capability) {
        case .legacy(let path):
            // Unreachable for a hosted session, and reaching it would mean the capability gate did not engage.
            log.record("LEGACY", path)
            connection.cancel()
        case .guarded(let method, let path, let range):
            serve(connection, path: path, method: method, range: range)
        case .reject(let status):
            log.record(status ?? "SILENT", "-")
            if let status {
                let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                connection.cancel()
            }
        }
    }

    private func serve(_ connection: NWConnection, path: String,
                       method: VortXEngineHostPolicy.Method,
                       range: VortXEngineHostPolicy.RangeSpec?) {
        let file = scratch.appendingPathComponent(String(path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            log.record("404", path)
            let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let type = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
        var body = method == .get ? data : Data()
        var status = "200 OK"
        var extra = "Accept-Ranges: bytes\r\n"
        if let range, let resolved = VortXEngineHostPolicy.resolve(range, length: data.count) {
            status = "206 Partial Content"
            extra += "Content-Range: bytes \(resolved.lowerBound)-\(resolved.upperBound)/\(data.count)\r\n"
            if method == .get { body = data.subdata(in: resolved.lowerBound..<(resolved.upperBound + 1)) }
        }
        log.record(status.hasPrefix("200") || status.hasPrefix("206") ? "200" : status, path)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Run

print("=== VortX external engine: LAN playback gate ===\n")

guard let lan = lanAddress() else { fail("no non-loopback IPv4 address on this machine") }
print("machine LAN address: \(lan)   (deliberately NOT 127.0.0.1)")

print("building the test asset with ffmpeg ...")
makeAsset()
let segments = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?
    .filter { $0.hasSuffix(".m4s") }.count ?? 0
print("asset ready: master.m3u8 -> media.m3u8, init.mp4, \(segments) x seg{N}.m4s\n")

let capability = VortXEngineHostPolicy.makeCapability()
let log = AccessLog()
let server = HarnessServer(capability: capability, log: log)
guard server.start() else { fail("harness server could not bind 0.0.0.0") }
print("server bound 0.0.0.0:\(server.port), capability \(capability.prefix(8))...\n")

// ---------------------------------------------------------------- negative test, run FIRST
print("--- NEGATIVE: an unpaired peer that knows the port but not the capability ---")
var negativeResults: [String] = []
let wrongCapability = VortXEngineHostPolicy.makeCapability()
for probe in ["/master.m3u8",
              "/r/\(wrongCapability)/master.m3u8",
              "/r/\(capability)/../../etc/passwd",
              "/"] {
    let url = URL(string: "http://\(lan):\(server.port)\(probe)")!
    let done = DispatchSemaphore(value: 0)
    var outcome = "no response (connection closed with no bytes)"
    var request = URLRequest(url: url)
    request.timeoutInterval = 4
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse {
            outcome = "HTTP \(http.statusCode), \(data?.count ?? 0) bytes"
        }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 6)
    let shown = probe.count > 46 ? String(probe.prefix(22)) + "..." + String(probe.suffix(18)) : probe
    print("  GET \(shown)\n      -> \(outcome)")
    negativeResults.append(outcome)
}
let anyLeak = negativeResults.contains { $0.contains("HTTP 200") }
print(anyLeak ? "\n  RESULT: LEAK. An unauthorised peer was served media.\n"
              : "\n  RESULT: nothing served to an unauthorised peer.\n")

// ---------------------------------------------------------------- positive test
print("--- POSITIVE: a real AVPlayer over the LAN address, through the capability path ---")
let mount = URL(string: "http://\(lan):\(server.port)"
                + VortXEngineHostPolicy.mountPath(capability: capability, resource: "master.m3u8"))!
print("mounting \(mount.absoluteString.replacingOccurrences(of: capability, with: String(capability.prefix(8)) + "..."))")

let item = AVPlayerItem(url: mount)
let player = AVPlayer(playerItem: item)
player.automaticallyWaitsToMinimizeStalling = false

let readyDeadline = Date().addingTimeInterval(25)
while item.status == .unknown, Date() < readyDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard item.status == .readyToPlay else {
    server.stop()
    fail("AVPlayer never reached readyToPlay (status=\(item.status.rawValue) error=\(String(describing: item.error)))")
}
let duration = item.duration.seconds
print("readyToPlay: duration=\(String(format: "%.2f", duration))s tracks=\(item.tracks.count)")

// Continuous playback, not a single frame. Sample the clock so a mount that reaches ready and then stalls is
// caught, which is the exact failure mode the on-device lane has hit in the field.
player.play()
var samples: [Double] = []
for _ in 0..<12 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    samples.append(player.currentTime().seconds)
}
let advanced = (samples.last ?? 0) - (samples.first ?? 0)
print("played \(String(format: "%.2f", advanced))s of wall-clock media "
      + "(t=\(samples.map { String(format: "%.1f", $0) }.joined(separator: " ")))")

server.stop()

// ---------------------------------------------------------------- evidence
print("\n--- ACCESS LOG: what AVFoundation actually fetched over the LAN ---")
var counts: [String: Int] = [:]
for path in log.served { counts[path, default: 0] += 1 }
for path in counts.keys.sorted() {
    print(String(format: "  %3d  GET %@", counts[path] ?? 0, path))
}
let rejected = log.all.filter { $0.0 != "200" }
print("  rejected before any body: \(rejected.count) (\(Set(rejected.map { $0.0 }).sorted().joined(separator: ", ")))")

// ---------------------------------------------------------------- verdict
print("\n--- VERDICT ---")
var failures: [String] = []
if anyLeak { failures.append("an unauthorised peer was served media") }
if item.status != .readyToPlay { failures.append("no readyToPlay") }
if advanced < 2.0 { failures.append("playback did not advance continuously (\(advanced)s)") }
if !log.served.contains("/master.m3u8") { failures.append("master was never served through the capability path") }
if !log.served.contains("/media.m3u8") { failures.append("relative child media.m3u8 was never resolved") }
if !log.served.contains("/init.mp4") { failures.append("relative child init.mp4 was never resolved") }
if !log.served.contains(where: { $0.hasPrefix("/seg") }) { failures.append("no media segment was fetched") }
if log.all.contains(where: { $0.0 == "LEGACY" }) { failures.append("a hosted request took the legacy path") }

if failures.isEmpty {
    print("PASS")
    print("  - a real AVPlayer played continuously from a non-loopback address")
    print("  - every relative child URI resolved against the capability-prefixed mount")
    print("  - the production policy gate served nothing to an unauthorised peer")
    print("\nNOT covered here: tvOS Dolby Vision negotiation against a LAN origin. That needs a device.")
    exit(0)
} else {
    for failure in failures { print("  FAIL: \(failure)") }
    exit(1)
}
