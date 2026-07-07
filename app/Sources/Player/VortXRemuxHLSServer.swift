#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import Network

/// Serves the DV-for-MKV streaming remux (`VortXMKVRemuxStream`) to AVPlayer as LOCAL HLS from 127.0.0.1
/// (b166). AVFoundation does not support a growing fragmented MP4 as a plain progressive asset: on the old
/// `vortxremux://` delivery every DV play on device either failed "Cannot Open" or scanned hundreds of MB
/// without ever producing a frame. HLS is the one delivery AVFoundation documents for a live fMP4 stream,
/// and the one Apple's authoring spec defines for Dolby Vision 8.1 (CODECS + SUPPLEMENTAL-CODECS +
/// VIDEO-RANGE), so this server presents the remux as:
///   - `/master.m3u8`: one EXT-X-STREAM-INF advertising the DV codec strings the remux classified.
///   - `/media.m3u8`:  an EVENT playlist (starts at the beginning, append-only) of the closed segments the
///     remux has produced so far, EXT-X-ENDLIST once the trailer is written. The first answer is held until
///     three segments exist so AVPlayer's startup never sees an empty window.
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
/// 10s start watchdog covers a mount that never frames. Nothing here can hang playback.
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

    /// Bytes the remux has produced so far (the chrome's watchdog progress probe).
    var producedBytes: Int { stream.buffer.status().produced }

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
        switch path {
        case "/master.m3u8": serveMaster(connection)
        case "/media.m3u8":  serveMedia(connection)
        case "/init.mp4":    serveInit(connection)
        default:
            if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
               let index = Int(path.dropFirst(4).dropLast(4)) {
                serveSegment(connection, index: index)
            } else {
                close(connection, status: "404 Not Found")
            }
        }
    }

    // MARK: - Waiting on the remux (bounded polls; every tick re-checks teardown + remux failure)

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

    /// Master playlist: one variant carrying the DV signaling. Held until the remux has classified the
    /// source and written its header (the signaling exists from then on).
    private func serveMaster(_ connection: NWConnection) {
        guard let sig = waitFor(seconds: 60, { stream.hlsSnapshot().signaling }) else {
            close(connection, status: "404 Not Found")
            return
        }
        var codecs = sig.videoCodec
        if let audio = sig.audioCodec { codecs += ",\(audio)" }
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(sig.bandwidth)"
        if sig.width > 0, sig.height > 0 { streamInf += ",RESOLUTION=\(sig.width)x\(sig.height)" }
        streamInf += ",CODECS=\"\(codecs)\""
        if let supplemental = sig.supplementalCodec { streamInf += ",SUPPLEMENTAL-CODECS=\"\(supplemental)\"" }
        if let range = sig.videoRange { streamInf += ",VIDEO-RANGE=\(range)" }
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        \(streamInf)
        media.m3u8

        """
        respond(connection, body: Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl")
    }

    /// Media playlist: EVENT type (playback starts at the beginning; entries are only ever appended) over
    /// the closed segments. The FIRST answer waits for three segments so AVPlayer's startup buffer math has
    /// something to chew on; later reloads answer immediately with whatever exists.
    private func serveMedia(_ connection: NWConnection) {
        struct Ready { let segments: [VortXMKVRemuxStream.HLSSegment]; let ended: Bool }
        let ready = waitFor(seconds: 60) { () -> Ready? in
            let snap = stream.hlsSnapshot()
            guard snap.initData != nil, !snap.segments.isEmpty,
                  snap.segments.count >= 3 || snap.ended else { return nil }
            return Ready(segments: snap.segments, ended: snap.ended)
        }
        guard let ready else {
            close(connection, status: "404 Not Found")
            return
        }
        // A FAILED remux must stop feeding AVPlayer (never ENDLIST: that would end playback "successfully"
        // mid-movie and auto-advance). 404 the reload so AVPlayer errors into the libmpv demotion.
        if stream.buffer.status().failure != nil, !ready.ended {
            close(connection, status: "404 Not Found")
            return
        }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(VortXMKVRemuxStream.hlsTargetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for seg in ready.segments {
            lines.append(String(format: "#EXTINF:%.3f,", seg.duration))
            lines.append("seg\(seg.index).m4s")
        }
        if ready.ended { lines.append("#EXT-X-ENDLIST") }
        lines.append("")
        respond(connection, body: Data(lines.joined(separator: "\n").utf8),
                contentType: "application/vnd.apple.mpegurl")
    }

    /// The ftyp+moov init segment, retained in memory for the whole session (immune to window eviction).
    private func serveInit(_ connection: NWConnection) {
        guard let initData = waitFor(seconds: 60, { stream.hlsSnapshot().initData }) else {
            close(connection, status: "404 Not Found")
            return
        }
        respond(connection, body: initData, contentType: "video/mp4")
    }

    /// One closed media segment, streamed out of the remux buffer in bounded chunks with send backpressure.
    /// A segment that fell out of the sliding window 404s (fail-soft into the demotion path) BEFORE any
    /// headers are sent; a read failure mid-body closes the connection (AVPlayer retries, then errors).
    private func serveSegment(_ connection: NWConnection, index: Int) {
        let snap = stream.hlsSnapshot()
        guard index >= 0, index < snap.segments.count else {
            close(connection, status: "404 Not Found")
            return
        }
        let seg = snap.segments[index]
        // Probe the first chunk BEFORE committing headers so an evicted range is a clean 404.
        let first = stream.buffer.read(offset: seg.byteOffset,
                                       length: min(Self.segmentChunk, seg.byteLength),
                                       cancelled: { [weak self] in self?.isInvalidated ?? true })
        guard first.failure == nil, !first.data.isEmpty else {
            close(connection, status: "404 Not Found")
            return
        }
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
