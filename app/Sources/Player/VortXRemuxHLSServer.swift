#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import Network

/// Serves the DV-for-MKV streaming remux (`VortXMKVRemuxStream`) to AVPlayer as LOCAL HLS from 127.0.0.1
/// (b166). AVFoundation does not support a growing fragmented MP4 as a plain progressive asset: on the old
/// `vortxremux://` delivery every DV play on device either failed "Cannot Open" or scanned hundreds of MB
/// without ever producing a frame. HLS is the one delivery AVFoundation documents for a live fMP4 stream,
/// and the one Apple's authoring spec defines for Dolby Vision 8.1 (CODECS + SUPPLEMENTAL-CODECS +
/// VIDEO-RANGE), so this server presents the remux as:
///   - `/master.m3u8`: two EXT-X-STREAM-INF variants on the SAME media.m3u8 - the DV variant (CODECS +
///     SUPPLEMENTAL-CODECS + VIDEO-RANGE) plus a range-unlabeled "lifeboat" variant, so AVFoundation's
///     variant filter (which drops an explicit PQ/HLG variant when the pipeline is not provably HDR at
///     parse time) always leaves one playable variant instead of zero -> -1002 (the b170 fix).
///   - `/media.m3u8`:  an EVENT playlist (starts at the beginning, append-only) of the closed segments the
///     remux has produced so far, EXT-X-ENDLIST once the trailer is written. The first answer is held until
///     a small startup window of segments exists so AVPlayer's startup never sees an empty playlist.
///   - `/init.mp4`:    the ftyp+moov init segment (retained in memory for the whole session).
///   - `/seg{N}.m4s`:  one closed segment, read out of the remux's sliding-window buffer.
///
/// Follows the proven `VXTrailerProxy` NWListener pattern: bound to 127.0.0.1 on an OS-assigned ephemeral
/// port (never reachable off-device), per-connection fail-soft (a bad request / evicted range / gone client
/// closes that one connection). One instance backs one playback session.
///
/// FAIL-SOFT GUARANTEE: a listener that will not start makes the factory return nil (the engine then emits
/// endFileError and the chrome demotes to libmpv HDR10); a remux failure 404s the next playlist reload so
/// AVPlayer errors into the same demotion; an evicted-segment request 404s the same way; and the chrome's
/// start watchdog covers a mount that never frames. Nothing here can hang playback.
final class VortXRemuxHLSServer: @unchecked Sendable {

    // MARK: - Delivery flag (rollback switch)

    /// Rollback switch for the HLS delivery lane. Baked ON (this lane IS the b166 first-frame fix); an
    /// explicit UserDefaults value wins (instant local rollback to the legacy `vortxremux://` loader path,
    /// which stays compiled), else the RemoteConfig `dvRemuxHLS` feature acts as a fleet kill-switch.
    static let deliveryKey = "stremiox.dvRemuxHLS"
    static var deliveryEnabled: Bool {
        if UserDefaults.standard.object(forKey: deliveryKey) != nil {
            return UserDefaults.standard.bool(forKey: deliveryKey)
        }
        return RemoteConfig.snapshot.isFeatureOn("dvRemuxHLS", default: true)
    }

    // MARK: - Lifecycle

    private let stream: VortXMKVRemuxStream
    /// Listener + connection event queue (never blocked).
    private let queue = DispatchQueue(label: "vortx.dvremux.hls")
    /// Request servicing queue: concurrent, because playlist answers legitimately WAIT (poll) for the remux
    /// to produce segments and must not starve a parallel segment read.
    private let serveQueue = DispatchQueue(label: "vortx.dvremux.hls.serve", attributes: .concurrent)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let stateLock = NSLock()
    private var invalidated = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Single-flight for the two concurrent startup /media.m3u8 fetches (#76). The master advertises two
    /// variants on the SAME media.m3u8 URI, so CoreMedia opens both at startup; if the two HELD requests poll
    /// the remux 100ms apart they can capture a DIFFERENT segment count for the same URI, which CoreMedia
    /// rejects with -12927. The first held request builds ONE body when the startup gate opens and stores it
    /// here; every other held request answers those identical bytes. Reloads after startup build fresh so the
    /// EVENT playlist still grows.
    private let mediaGateLock = NSLock()
    private var startupMediaBody: Data?

    /// Build the remux stream + local server for a DV MKV URL. Returns nil when the listener cannot bind
    /// (the caller fails soft to libmpv). The caller must `start()` the returned server to begin remuxing.
    static func make(input: URL, headers: [String: String]?) -> (server: VortXRemuxHLSServer, playlistURL: URL)? {
        let stream = VortXMKVRemuxStream(input: input.absoluteString, headers: headers, indexForHLS: true)
        let server = VortXRemuxHLSServer(stream: stream)
        guard server.listen() else { return nil }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(server.port)
        comps.path = "/master.m3u8"
        guard let url = comps.url else { server.invalidate(); return nil }
        return (server, url)
    }

    private init(stream: VortXMKVRemuxStream) {
        self.stream = stream
    }

    /// Begin remuxing. Call once, after the asset is (about to be) mounted.
    func start() { stream.start() }

    /// F3: forward the engine's first-frame readiness to the buffer so its producer lead widens from the
    /// reduced pre-ready value to the full lead. Called from AVPlayerEngine's readyToPlay handler.
    func markEngineReady() { stream.buffer.markEngineReady() }

    /// Whether the mount is still HEALTHY: the init segment has published AND the remux buffer has not failed.
    /// The engine's one-shot healthy-mount retry (#76) reads this to tell "a CoreMedia startup hiccup on a live
    /// mount" (retry a fresh item) from "the remux itself died" (demote). Same two signals serveMedia gates on.
    var isMountHealthy: Bool {
        stream.hlsSnapshot().initData != nil && stream.buffer.status().failure == nil
    }

    /// Stop everything: the remux thread, the listener, and every open connection. Idempotent.
    func invalidate() {
        stateLock.lock()
        let already = invalidated
        invalidated = true
        let open = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        guard !already else { return }
        stream.cancel()
        listener?.cancel()
        open.forEach { $0.cancel() }
    }

    private var isInvalidated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return invalidated
    }

    /// Start the loopback listener synchronously (the VXTrailerProxy pattern) and record its port.
    private func listen() -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let newListener = try NWListener(using: params)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            let ready = DispatchSemaphore(value: 0)
            let portLock = NSLock()
            var boundPort: UInt16 = 0
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    portLock.lock(); boundPort = newListener.port?.rawValue ?? 0; portLock.unlock()
                    ready.signal()
                case .failed, .cancelled:
                    ready.signal()
                default:
                    break
                }
            }
            newListener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
            portLock.lock(); let bound = boundPort; portLock.unlock()
            guard bound != 0 else {
                newListener.cancel()
                DiagnosticsLog.log("dv", "hls server failed to bind (no port)")
                return false
            }
            listener = newListener
            port = bound
            DiagnosticsLog.log("dv", "hls server listening on 127.0.0.1:\(bound)")
            return true
        } catch {
            DiagnosticsLog.log("dv", "hls server listener start failed: \(error)")
            return false
        }
    }

    // MARK: - Per-connection handling

    /// Header-read deadline so a client that connects and stalls never leaks its connection.
    private static let headerDeadline: TimeInterval = 15

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        if invalidated {
            stateLock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .cancelled, .failed:
                guard let self, let connection else { return }
                self.stateLock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                self.stateLock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.headerDeadline, execute: deadline)
        readRequest(connection, buffer: Data(), deadline: deadline)
    }

    /// Read until the CRLFCRLF header terminator, then route. Bounded (a malformed client cannot make us
    /// buffer without limit); the deadline force-cancels a never-completing header.
    private func readRequest(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                deadline.cancel(); connection.cancel(); return
            }
            var accumulated = buffer
            if let chunk, !chunk.isEmpty { accumulated.append(chunk) }
            if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                deadline.cancel()
                let header = accumulated.subdata(in: accumulated.startIndex..<range.lowerBound)
                // Serve off the event queue: playlist answers may poll-wait for the remux.
                self.serveQueue.async { self.route(connection, header: header) }
                return
            }
            if isComplete || accumulated.count > 64_000 {
                deadline.cancel(); connection.cancel(); return
            }
            self.readRequest(connection, buffer: accumulated, deadline: deadline)
        }
    }

    /// Parse "GET /path HTTP/1.1" and dispatch to the four resources.
    private func route(_ connection: NWConnection, header: Data) {
        guard !isInvalidated,
              let text = String(data: header, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            close(connection, status: "400 Bad Request")
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            close(connection, status: "400 Bad Request")
            return
        }
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]
        DiagnosticsLog.log("dv", "hls req \(path)")
        switch path {
        case "/master.m3u8": serveMaster(connection)
        case "/media.m3u8":  serveMedia(connection)
        case "/init.mp4":    serveInit(connection)
        default:
            if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
               let index = Int(path.dropFirst(4).dropLast(4)) {
                serveSegment(connection, index: index)
            } else {
                DiagnosticsLog.log("dv", "hls 404 \(path)")
                close(connection, status: "404 Not Found")
            }
        }
    }

    // MARK: - Waiting on the remux (bounded polls; every tick re-checks teardown + remux failure)

    /// How long a playlist / init request may poll-wait for the remux to produce what it needs. Generous on
    /// purpose: the chrome's start watchdog demotes a dead mount long before this bound is the limiter, so
    /// it only stops an orphaned request from polling forever after a teardown race.
    private static let resourceWaitSeconds: TimeInterval = 60

    /// Poll `probe` until it yields a value, the deadline passes, the server is invalidated, or the remux
    /// FAILS (its classify fail-fast / mid-stream error). Returns nil on every non-success path; the caller
    /// answers 404 and AVPlayer's error path drives the libmpv demotion.
    private func waitFor<T>(seconds: TimeInterval, _ probe: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isInvalidated { return nil }
            if let value = probe() { return value }
            if stream.buffer.status().failure != nil { return nil }   // remux failed: stop waiting
            Thread.sleep(forTimeInterval: 0.1)
        }
        return probe()
    }

    // MARK: - Resources

    /// Master playlist: TWO variants on the SAME media.m3u8. Held until the remux has classified the source
    /// and written its header (the signaling exists from then on).
    private func serveMaster(_ connection: NWConnection) {
        guard let sig = waitFor(seconds: Self.resourceWaitSeconds, { stream.hlsSnapshot().signaling }) else {
            DiagnosticsLog.log("dv", "hls 404 /master.m3u8")
            close(connection, status: "404 Not Found")
            return
        }
        #if os(tvOS)
        // #76: FIRE the Dolby Vision panel switch HERE, now that classify has published signaling, and BEFORE
        // the media playlist / any segment (the real video mount). This replaces the old pre-attach switch in
        // loadFile, which fired on mount for every remux candidate and cycled the panel twice per hop whenever
        // classify then rejected a non-DV / undecodable source (that path fails the buffer BEFORE any signaling
        // exists, 404s the guard above, and never reaches this line). Signaling PRESENCE is the gate: every
        // served master is a classify-ACCEPTED DV source by construction (non-5/7/8 profiles are rejected
        // pre-signaling), including a P8 with an unknown compat id whose CODECS string ships as plain HEVC.
        // The native (non-remux) DV lane still switches pre-attach because AVPlayer cannot report the profile
        // before it demuxes. `request` is @MainActor and a no-op on iOS/macOS. Fired synchronously (bounded
        // semaphore) so setSwitchSettled(false) lands before the settle-wait below, which is what closes the
        // master-parse race that wait exists for.
        let switched = DispatchSemaphore(value: 0)
        let dvFps = sig.fps, dvWidth = sig.width, dvHeight = sig.height
        DispatchQueue.main.async { [weak self] in
            defer { switched.signal() }   // signal on EVERY exit so the serve task never eats the full timeout
            // Teardown race (#76 rework): if the user exited in this instant, invalidate() + stop()'s
            // HDRDisplayMode.reset may already have run; an unguarded queued request would then flip the TV
            // into DV mode on the home screen with nothing left to correct it. A torn-down server never
            // switches the panel.
            guard let self, !self.isInvalidated else { return }
            MainActor.assumeIsolated {   // request() is @MainActor; this closure runs on the main queue
                HDRDisplayMode.request(.dolbyVision, fps: dvFps, width: dvWidth, height: dvHeight, in: nil)
            }
            DiagnosticsLog.log("dv", "remux classify confirmed DV -> requested Dolby Vision display mode before mount (fps=\(String(format: "%.3f", dvFps)) \(dvWidth)x\(dvHeight))")
        }
        if switched.wait(timeout: .now() + 2) == .timedOut {   // bounded: a wedged main must not hang the serve task
            DiagnosticsLog.log("dv", "DV display switch request not confirmed within 2s (main queue busy); the switch may land after the master is served")
        }
        #endif
        // Hold the master until any in-flight HDR display-mode switch settles. AVFoundation's multivariant
        // selector drops the explicit-PQ DV variant whenever it parses the master before the output pipeline
        // is provably HDR, and that choice is session-persistent, so a master fetched mid-switch can pin the
        // lifeboat (HDR10 output) for the whole title. Bounded and fail-OPEN: on timeout the lifeboat still
        // guarantees a playable variant. HDRDisplayMode.isSwitchSettled is always true on iOS/macOS and
        // whenever Match Dynamic Range never started a switch, so this is a no-op except on the tvOS DV path.
        _ = waitFor(seconds: 6) { HDRDisplayMode.isSwitchSettled ? true : nil }
        var codecs = sig.videoCodec
        if let audio = sig.audioCodec { codecs += ",\(audio)" }
        // DV variant FIRST (Apple authoring-spec truth: SUPPLEMENTAL-CODECS + VIDEO-RANGE) so it is the
        // initial pick whenever the pipeline admits HDR at parse time.
        var dvInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(sig.bandwidth)"
        if sig.width > 0, sig.height > 0 { dvInf += ",RESOLUTION=\(sig.width)x\(sig.height)" }
        dvInf += ",CODECS=\"\(codecs)\""
        if let supplemental = sig.supplementalCodec { dvInf += ",SUPPLEMENTAL-CODECS=\"\(supplemental)\"" }
        if let range = sig.videoRange { dvInf += ",VIDEO-RANGE=\(range)" }
        if sig.fps > 0 { dvInf += String(format: ",FRAME-RATE=%.3f", sig.fps) }   // authoring rule 9.15 (MUST)
        // Lifeboat (the b170 -1002 fix): same URI, same CODECS, NO VIDEO-RANGE / NO SUPPLEMENTAL-CODECS.
        // AVFoundation's multivariant selector drops any variant carrying an explicit non-SDR VIDEO-RANGE
        // (PQ/HLG) whenever the output pipeline is not provably HDR at the instant the master is parsed
        // (SDR-base Match-Content state, display switch not settled, layerless probe). With exactly ONE
        // variant that single drop leaves ZERO playable variants, which CoreMedia surfaces as
        // NSURLErrorDomain -1002 / CoreMediaErrorDomain -1002 (empirically bisected off-device, byte-exact:
        // the VIDEO-RANGE tag alone is the poison; an untagged copy of the same stream is accepted). A
        // range-unlabeled variant is never range-filtered, so a variant always survives. Same segments
        // either way: the fMP4 sample entry (hvc1+dvvC) and the in-band RPUs drive the actual DV decode, and
        // VortX forces the Apple TV panel itself via HDRDisplayMode. BANDWIDTH-1 keeps the DV variant
        // preferred when both survive; identical URIs make any ABR switch a no-op.
        // BANDWIDTH is dropped by 100 kbps (not 1) so the readyToPlay access-log's indicatedBitrate reveals
        // which variant AVFoundation latched: ~the DV BANDWIDTH means the DV variant, ~100 kbps lower means the
        // lifeboat. Same ordering (DV preferred), identical URI, so playback is unchanged.
        var fbInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(max(sig.bandwidth - 100_000, 1))"
        if sig.width > 0, sig.height > 0 { fbInf += ",RESOLUTION=\(sig.width)x\(sig.height)" }
        fbInf += ",CODECS=\"\(codecs)\""
        if sig.fps > 0 { fbInf += String(format: ",FRAME-RATE=%.3f", sig.fps) }   // authoring rule 9.15 (MUST)
        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n\(dvInf)\nmedia.m3u8\n\(fbInf)\nmedia.m3u8\n"
        let body = Data(playlist.utf8)
        DiagnosticsLog.log("dv", "hls resp /master.m3u8 variants=2 \(body.count)B")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    /// Segments the FIRST media-playlist answer waits for, so AVPlayer's startup buffer math never sees a
    /// near-empty window (a finished-early remux is exempt: `ended` publishes whatever exists).
    private static let minStartupSegments = 2

    /// Media playlist: EVENT type (playback starts at the beginning; entries are only ever appended) over
    /// the closed segments. The FIRST answer waits for `minStartupSegments` so AVPlayer's startup buffer
    /// math has something to chew on; later reloads answer immediately with whatever exists.
    private func serveMedia(_ connection: NWConnection) {
        struct Ready { let segments: [VortXMKVRemuxStream.HLSSegment]; let ended: Bool }
        // Was the startup gate already open on the FIRST probe? If not, this is a HELD startup request (one of
        // the two concurrent per-variant fetches of the same URI) and must share ONE body with its sibling so
        // the two never disagree on segment count (-12927). A request that finds the gate already open is a
        // post-startup reload and builds fresh below so the EVENT playlist keeps growing.
        let gateOpenOnEntry: Bool = {
            let snap = stream.hlsSnapshot()
            return snap.initData != nil && !snap.segments.isEmpty
                && (snap.segments.count >= Self.minStartupSegments || snap.ended)
        }()
        let ready = waitFor(seconds: Self.resourceWaitSeconds) { () -> Ready? in
            let snap = stream.hlsSnapshot()
            guard snap.initData != nil, !snap.segments.isEmpty,
                  snap.segments.count >= Self.minStartupSegments || snap.ended else { return nil }
            return Ready(segments: snap.segments, ended: snap.ended)
        }
        guard let ready else {
            DiagnosticsLog.log("dv", "hls 404 /media.m3u8")
            close(connection, status: "404 Not Found")
            return
        }
        // A FAILED remux must stop feeding AVPlayer (never ENDLIST: that would end playback "successfully"
        // mid-movie and auto-advance). 404 the reload so AVPlayer errors into the libmpv demotion.
        if stream.buffer.status().failure != nil, !ready.ended {
            DiagnosticsLog.log("dv", "hls 404 /media.m3u8 (remux failed)")
            close(connection, status: "404 Not Found")
            return
        }
        // Single-flight the held startup answers (#76): the first held request builds ONE body when the gate
        // opens and stores it; the concurrent sibling answers those identical bytes. Reloads build fresh.
        let singleFlight = !gateOpenOnEntry
        let body: Data
        if singleFlight {
            mediaGateLock.lock()
            if let cached = startupMediaBody {
                body = cached
            } else {
                body = Self.buildMediaBody(segments: ready.segments, ended: ready.ended)
                startupMediaBody = body
            }
            mediaGateLock.unlock()
        } else {
            body = Self.buildMediaBody(segments: ready.segments, ended: ready.ended)
        }
        DiagnosticsLog.log("dv", "hls resp /media.m3u8 segs=\(ready.segments.count) ended=\(ready.ended) \(body.count)B\(singleFlight ? " [startup single-flight]" : "")")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    /// Build the EVENT media playlist bytes for a given closed-segment set. Pure and deterministic: the same
    /// (segments, ended) always yields byte-identical output, so two requests that share one snapshot cannot
    /// disagree. Playback starts at the beginning; entries are only ever appended (MEDIA-SEQUENCE stays 0).
    private static func buildMediaBody(segments: [VortXMKVRemuxStream.HLSSegment], ended: Bool) -> Data {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(VortXMKVRemuxStream.hlsTargetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for seg in segments {
            lines.append(String(format: "#EXTINF:%.3f,", seg.duration))
            lines.append("seg\(seg.index).m4s")
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The ftyp+moov init segment, retained in memory for the whole session (immune to window eviction).
    private func serveInit(_ connection: NWConnection) {
        guard let initData = waitFor(seconds: Self.resourceWaitSeconds, { stream.hlsSnapshot().initData }) else {
            DiagnosticsLog.log("dv", "hls 404 /init.mp4")
            close(connection, status: "404 Not Found")
            return
        }
        DiagnosticsLog.log("dv", "hls resp /init.mp4 \(initData.count)B")
        respond(connection, body: initData, contentType: "video/mp4")
    }

    /// One closed media segment, streamed out of the remux buffer in bounded chunks with send backpressure.
    /// A segment that fell out of the sliding window 404s (fail-soft into the demotion path) BEFORE any
    /// headers are sent; a read failure mid-body closes the connection (AVPlayer retries, then errors).
    private func serveSegment(_ connection: NWConnection, index: Int) {
        let snap = stream.hlsSnapshot()
        guard index >= 0, index < snap.segments.count else {
            DiagnosticsLog.log("dv", "hls 404 /seg\(index).m4s")
            close(connection, status: "404 Not Found")
            return
        }
        let seg = snap.segments[index]
        // Probe the first chunk BEFORE committing headers so an evicted range is a clean 404.
        let first = stream.buffer.read(offset: seg.byteOffset,
                                       length: min(Self.segmentChunk, seg.byteLength),
                                       cancelled: { [weak self] in self?.isInvalidated ?? true })
        guard first.failure == nil, !first.data.isEmpty else {
            DiagnosticsLog.log("dv", "hls 404 /seg\(index).m4s (evicted)")
            close(connection, status: "404 Not Found")
            return
        }
        DiagnosticsLog.log("dv", "hls resp /seg\(index).m4s \(seg.byteLength)B")
        let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(seg.byteLength)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            connection.send(content: first.data, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.sendSegmentTail(connection,
                                     offset: seg.byteOffset + first.data.count,
                                     remaining: seg.byteLength - first.data.count)
            })
        })
    }

    private static let segmentChunk = 512 * 1024

    /// Send the rest of a segment chunk-by-chunk, each write waiting on the previous (backpressure keeps
    /// memory bounded to one chunk). All bytes of a CLOSED segment are already produced, so reads return
    /// immediately unless the range was evicted or the remux failed, both of which close the connection.
    private func sendSegmentTail(_ connection: NWConnection, offset: Int, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }   // done (Connection: close)
        serveQueue.async { [weak self] in
            guard let self, !self.isInvalidated else { connection.cancel(); return }
            let chunk = self.stream.buffer.read(offset: offset,
                                                length: min(Self.segmentChunk, remaining),
                                                cancelled: { [weak self] in self?.isInvalidated ?? true })
            guard chunk.failure == nil, !chunk.data.isEmpty else { connection.cancel(); return }
            connection.send(content: chunk.data, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.sendSegmentTail(connection, offset: offset + chunk.data.count,
                                     remaining: remaining - chunk.data.count)
            })
        }
    }

    // MARK: - Response helpers

    private func respond(_ connection: NWConnection, body: Data, contentType: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func close(_ connection: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
