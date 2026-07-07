import Foundation
import Network

/// A tiny local HTTP/1.1 range-proxy that sits between libmpv and googlevideo so YouTube trailers play.
///
/// WHY THIS EXISTS: googlevideo now 403s every Range shape libmpv/FFmpeg can send on its own. FFmpeg opens a
/// media URL with either an open-ended `Range: bytes=0-` or no Range header at all, and googlevideo answers 403
/// to both. What it DOES answer 200 to is a bounded window expressed as a query parameter on the URL itself:
/// `&range=start-stop` (the same mechanism the browser player uses). So we cannot fix this by handing mpv a
/// header, we have to fetch the bytes ourselves in bounded windows and re-serve them to mpv as a clean 206.
///
/// WHAT IT DOES: `proxied(_:mime:)` returns a `http://127.0.0.1:<port>/yt?u=<base64url>&mime=<mime>` URL that
/// mpv opens instead of the raw googlevideo URL. For each mpv connection the proxy:
///   1. reads the request line + headers, parses the client `Range: bytes=start-[end]` (default 0..clen-1),
///   2. replies `206 Partial Content` with `Content-Range`/`Content-Length`/`Accept-Ranges: bytes`,
///   3. streams the body by fetching googlevideo in <=1 MiB `&range=pos-stop` windows (each a plain HTTP 200),
///      sending the InnerTube IOS-client User-Agent upstream and writing each window to mpv with backpressure.
/// A full-file `&range=0-(clen-1)` is itself REJECTED (403) by googlevideo, which is exactly why the body is
/// chunked into <=1 MiB windows. `clen` (total content length) is always present as a query param on every
/// googlevideo URL, so the total size is read straight from the URL rather than probed.
///
/// SSRF GATE: `u` is only ever proxied when its decoded host contains "googlevideo"; anything else is refused.
/// This proxy binds to 127.0.0.1 on an OS-assigned ephemeral port, so it is reachable only from this device.
///
/// FAIL-SOFT: every path is wrapped so a bad request, an upstream error, or a slow/gone client just closes that
/// one connection. `proxied` returns nil (caller falls back to the raw URL) for a non-googlevideo host or a
/// listener that will not start. Uses Network framework, which is available on iOS, tvOS, and macOS alike.
final class VXTrailerProxy {

    static let shared = VXTrailerProxy()

    /// Upstream fetch window. googlevideo 403s a full-file `&range=0-(clen-1)`, so the body is pulled in
    /// windows no larger than this. 1 MiB is the size proven end to end against ffmpeg in the prototype.
    private static let windowSize = 1_048_576

    /// Per-window upstream retry budget. A single googlevideo window failure (transient network error, a
    /// non-2xx status, or an empty body) must NOT truncate the track: the fixed-length 206 already promised the
    /// full byte count, and a trailer streams video + audio as TWO independent proxied connections, so one
    /// unretried hiccup ends just that track mid-clip (the "audio or video dies halfway, never finishes" bug).
    /// Each window is re-requested (idempotent `&range=`) up to this many times with backoff before giving up.
    private static let maxWindowAttempts = 4
    /// Base backoff between window retries, scaled by attempt number.
    private static let windowRetryBaseDelay: TimeInterval = 0.3
    /// Per-window upstream timeout so a stalled window fails fast (and retries) instead of hanging the track.
    private static let windowTimeout: TimeInterval = 20

    private let queue = DispatchQueue(label: "com.stremiox.vxtrailerproxy")

    /// A SEPARATE queue for the listener's state/connection callbacks. It must not be `queue`: `ensureListening`
    /// blocks `queue` on a semaphore waiting for the `.ready` state, so the state handler has to run elsewhere or
    /// it would deadlock against that wait.
    private let listenerQueue = DispatchQueue(label: "com.stremiox.vxtrailerproxy.listener")

    /// A shared ephemeral session for the upstream window GETs (no persistent cache/cookies; each window is a
    /// one-shot range request). Guarded by `queue`.
    private let upstream = URLSession(configuration: .ephemeral)

    private var listener: NWListener?

    /// The bound ephemeral port. Written by the listener state handler (on `listenerQueue`) and read by
    /// `ensureListening` (on `queue`), so every access goes through `portLock` to keep the two queues from
    /// racing on it. Use `currentPort` / `setPort`, never the backing store directly.
    private var _port: UInt16 = 0
    private let portLock = NSLock()

    private var currentPort: UInt16 {
        portLock.lock(); defer { portLock.unlock() }
        return _port
    }

    private func setPort(_ value: UInt16) {
        portLock.lock(); defer { portLock.unlock() }
        _port = value
    }

    private init() {}

    // MARK: - Public contract

    /// Return a `http://127.0.0.1/yt?...` proxy URL for a googlevideo `upstream`, lazily starting the listener.
    /// Returns nil (so the caller falls back to the raw URL) when the host is not googlevideo (SSRF gate) or the
    /// listener cannot start.
    func proxied(_ upstream: URL, mime: String = "video/mp4") -> URL? {
        guard upstream.host?.contains("googlevideo") ?? false else { return nil }
        guard let port = ensureListening() else { return nil }

        let encoded = Self.base64url(upstream.absoluteString)
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        comps.path = "/yt"
        comps.queryItems = [
            URLQueryItem(name: "u", value: encoded),
            URLQueryItem(name: "mime", value: mime),
        ]
        return comps.url
    }

    // MARK: - Listener lifecycle

    /// Start the listener once (idempotent) and return its bound port, or nil on failure. Serialized on `queue`
    /// so a double-resolve (hero + trailer button within seconds) cannot race two listeners into existence.
    private func ensureListening() -> UInt16? {
        queue.sync {
            if listener != nil, currentPort != 0 { return currentPort }

            do {
                // Bind explicitly to loopback so the socket is never reachable off-device: an OS-assigned
                // ephemeral port (port 0) on 127.0.0.1 only.
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                let newListener = try NWListener(using: params)
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                // Resolve the OS-assigned ephemeral port once the listener is ready.
                let ready = DispatchSemaphore(value: 0)
                newListener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        // The state handler runs on `listenerQueue`; `ensureListening` reads `port` on `queue`
                        // on the semaphore-timeout path. Guard the write with `portLock` so the two queues do
                        // not race on `port`. (We cannot hop onto `queue` here: `ensureListening` is blocked
                        // inside `queue.sync` waiting on `ready`, so a `queue.async` would deadlock.)
                        self?.setPort(newListener.port?.rawValue ?? 0)
                        ready.signal()
                    case .failed, .cancelled:
                        ready.signal()
                    default:
                        break
                    }
                }
                newListener.start(queue: listenerQueue)
                // Wait briefly for the ready state so the caller gets a usable port synchronously.
                _ = ready.wait(timeout: .now() + 2)
                let boundPort = currentPort
                guard newListener.port?.rawValue != nil, boundPort != 0 else {
                    newListener.cancel()
                    return nil
                }
                self.listener = newListener
                NSLog("[yt-proxy] listener started on port %d", boundPort)
                return boundPort
            } catch {
                NSLog("[yt-proxy] listener start failed: %@", String(describing: error))
                return nil
            }
        }
    }

    // MARK: - Per-connection handling

    /// How long a client has to send a complete request header before the connection is force-cancelled. A
    /// client that connects and then stalls (or dribbles bytes without ever sending CRLFCRLF) would otherwise
    /// keep the NWConnection and its receive-closure chain alive forever; this bounds that to a hard deadline.
    private static let headerDeadline: TimeInterval = 15

    /// Accept one mpv connection: read its request, then stream the requested byte range from googlevideo.
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Arm a header-read deadline so a client that connects but never finishes its header does not leak the
        // connection. Disarmed (`.cancel()`) once the header is parsed and `serve` takes over.
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.headerDeadline, execute: deadline)
        readRequest(connection, buffer: Data(), deadline: deadline)
    }

    /// Read from the connection until the header terminator (CRLFCRLF), then serve. Bounds the header read so a
    /// malformed client cannot make us buffer without limit. `deadline` force-cancels a client that never
    /// completes its header; it is cancelled the moment the header is fully parsed.
    private func readRequest(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                deadline.cancel()
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let chunk, !chunk.isEmpty {
                accumulated.append(chunk)
            }

            let terminator = Data("\r\n\r\n".utf8)
            if let range = accumulated.range(of: terminator) {
                deadline.cancel()   // header complete: disarm the idle-header deadline before serving
                let headerData = accumulated.subdata(in: accumulated.startIndex..<range.lowerBound)
                self.serve(connection, header: headerData)
                return
            }

            // Guard against an unbounded / never-terminated header.
            if isComplete || accumulated.count > 64_000 {
                deadline.cancel()
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: accumulated, deadline: deadline)
        }
    }

    /// Parse the request header (path query `u`/`mime` + `Range:`), apply the SSRF gate, then stream windows.
    private func serve(_ connection: NWConnection, header: Data) {
        guard let headerText = String(data: header, encoding: .utf8) else {
            close(connection, status: "400 Bad Request")
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            close(connection, status: "400 Bad Request")
            return
        }

        // Request line: "GET /yt?u=...&mime=... HTTP/1.1"
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            close(connection, status: "400 Bad Request")
            return
        }
        let items = comps.queryItems ?? []
        let encodedU = items.first(where: { $0.name == "u" })?.value ?? ""
        // Whitelist the mime before it goes into the `Content-Type:` response header. The value is client
        // supplied, so an un-checked value (containing CR/LF) would let a local client inject extra response
        // headers into mpv. Anything not in the known set falls back to video/mp4.
        let mime = Self.sanitizedMime(items.first(where: { $0.name == "mime" })?.value)

        guard let upstreamString = Self.base64urlDecode(encodedU),
              let upstreamURL = URL(string: upstreamString),
              upstreamURL.host?.contains("googlevideo") ?? false else {
            // SSRF gate: refuse anything that is not a googlevideo URL.
            close(connection, status: "400 Bad Request")
            return
        }

        // `clen` (total content length) is always present on a googlevideo URL.
        let clen = Int(URLComponents(url: upstreamURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "clen" })?.value ?? "") ?? 0
        guard clen > 0 else {
            close(connection, status: "404 Not Found")
            return
        }

        // Parse the client Range: "Range: bytes=start-[end]" (default the whole file).
        var start = 0
        var end = clen - 1
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let spec = rangeLine.drop(while: { $0 != "=" }).dropFirst()   // "start-end"
            let bounds = spec.components(separatedBy: "-")
            if (bounds.first ?? "").isEmpty, bounds.count > 1, let n = Int(bounds[1]), n > 0 {
                start = max(0, clen - n); end = clen - 1   // suffix range "bytes=-N": the last N bytes (RFC 7233)
            } else {
                if let s = Int(bounds.first ?? ""), s >= 0 { start = s }
                if bounds.count > 1, let e = Int(bounds[1]), e >= start { end = e }
            }
        }
        end = min(end, clen - 1)
        guard start <= end else {
            close(connection, status: "416 Range Not Satisfiable")
            return
        }

        let length = end - start + 1
        let head = """
        HTTP/1.1 206 Partial Content\r
        Content-Type: \(mime)\r
        Accept-Ranges: bytes\r
        Content-Range: bytes \(start)-\(end)/\(clen)\r
        Content-Length: \(length)\r
        Connection: close\r
        \r

        """
        NSLog("[yt-proxy] serving host=%@ bytes=%d-%d clen=%d", upstreamURL.host ?? "?", start, end, clen)

        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.streamWindows(connection, upstream: upstreamURL, pos: start, end: end)
        })
    }

    // MARK: - Windowed streaming

    /// Fetch `[pos, end]` from googlevideo one <=1 MiB `&range=` window at a time, writing each to the client
    /// before requesting the next (backpressure keeps memory bounded to a single window). Each window is fetched
    /// with a bounded retry (see `fetchWindow`) so a transient upstream hiccup does not truncate the track.
    private func streamWindows(_ connection: NWConnection, upstream: URL, pos: Int, end: Int) {
        guard pos <= end else {
            connection.cancel()   // done: the 206 body is complete
            return
        }
        let stop = min(pos + Self.windowSize - 1, end)
        fetchWindow(connection, upstream: upstream, start: pos, stop: stop, end: end, attempt: 1)
    }

    /// Fetch ONE `[start, stop]` window and, on success, write it to the client and advance to the next window.
    /// On a transient upstream failure (network error, non-2xx status, or empty body) it re-requests the SAME
    /// idempotent `&range=` window up to `maxWindowAttempts` with a small backoff BEFORE giving up. This is the
    /// fix for trailers dying halfway: previously any single window failure did `connection.cancel()`, closing
    /// the socket after fewer bytes than the fixed Content-Length promised and truncating that one track.
    private func fetchWindow(_ connection: NWConnection, upstream: URL, start: Int, stop: Int, end: Int, attempt: Int) {
        guard let windowURL = Self.appendRange(upstream, start: start, stop: stop) else {
            connection.cancel()
            return
        }

        var request = URLRequest(url: windowURL)
        request.timeoutInterval = Self.windowTimeout
        // NO Range header upstream: googlevideo answers the bounded `&range=` query with a plain 200.
        request.setValue(YouTubeDirectResolver.googlevideoUserAgent, forHTTPHeaderField: "User-Agent")

        let task = upstream_session_dataTask(request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200...299).contains(status) && (data?.isEmpty == false)
            guard ok, let data else {
                // Transient upstream failure: retry the SAME window (idempotent) after a short backoff rather
                // than cancelling and truncating this track. Only close once the retry budget is exhausted.
                if attempt < Self.maxWindowAttempts {
                    self.queue.asyncAfter(deadline: .now() + Self.windowRetryBaseDelay * Double(attempt)) { [weak self] in
                        self?.fetchWindow(connection, upstream: upstream, start: start, stop: stop, end: end, attempt: attempt + 1)
                    }
                } else {
                    NSLog("[yt-proxy] window %d-%d gave up after %d attempts (status=%d err=%@)",
                          start, stop, attempt, status, String(describing: error))
                    connection.cancel()
                }
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, sendError == nil else {
                    connection.cancel()   // client went away or a slow write failed
                    return
                }
                self.streamWindows(connection, upstream: upstream, pos: stop + 1, end: end)
            })
        }
        task.resume()
    }

    /// Thin wrapper so the upstream session read stays on `queue` semantics without capturing it in the name.
    private func upstream_session_dataTask(_ request: URLRequest,
                                           completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        upstream.dataTask(with: request, completionHandler: completion)
    }

    // MARK: - Helpers

    /// The only mime types this proxy ever serves. Anything else (including a CR/LF-bearing injection attempt)
    /// falls back to `video/mp4` so the `Content-Type:` response header can never carry attacker-controlled text.
    private static let allowedMimes: Set<String> = ["video/mp4", "audio/mp4"]

    /// Clamp a client-supplied mime to the known-good set, defaulting to `video/mp4`. This is the response-header
    /// injection guard: the returned value is always a literal from `allowedMimes`, never client text.
    private static func sanitizedMime(_ raw: String?) -> String {
        guard let raw, allowedMimes.contains(raw) else { return "video/mp4" }
        return raw
    }

    /// Append (or replace) the bounded `&range=start-stop` window on a googlevideo URL.
    private static func appendRange(_ url: URL, start: Int, stop: Int) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = comps.queryItems ?? []
        items.removeAll(where: { $0.name == "range" })
        items.append(URLQueryItem(name: "range", value: "\(start)-\(stop)"))
        comps.queryItems = items
        return comps.url
    }

    /// Write a bare status line and close (used for the refusal / error paths).
    private func close(_ connection: NWConnection, status: String) {
        let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// URL-safe base64 with padding stripped (round-trips through `base64urlDecode`).
    private static func base64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ string: String) -> String? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
