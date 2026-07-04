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

    private let queue = DispatchQueue(label: "com.stremiox.vxtrailerproxy")

    /// A SEPARATE queue for the listener's state/connection callbacks. It must not be `queue`: `ensureListening`
    /// blocks `queue` on a semaphore waiting for the `.ready` state, so the state handler has to run elsewhere or
    /// it would deadlock against that wait.
    private let listenerQueue = DispatchQueue(label: "com.stremiox.vxtrailerproxy.listener")

    /// A shared ephemeral session for the upstream window GETs (no persistent cache/cookies; each window is a
    /// one-shot range request). Guarded by `queue`.
    private let upstream = URLSession(configuration: .ephemeral)

    private var listener: NWListener?
    private var port: UInt16 = 0

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
            if listener != nil, port != 0 { return port }

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
                        self?.port = newListener.port?.rawValue ?? 0
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
                guard newListener.port?.rawValue != nil, self.port != 0 else {
                    newListener.cancel()
                    return nil
                }
                self.listener = newListener
                NSLog("[yt-proxy] listener started on port %d", self.port)
                return self.port
            } catch {
                NSLog("[yt-proxy] listener start failed: %@", String(describing: error))
                return nil
            }
        }
    }

    // MARK: - Per-connection handling

    /// Accept one mpv connection: read its request, then stream the requested byte range from googlevideo.
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    /// Read from the connection until the header terminator (CRLFCRLF), then serve. Bounds the header read so a
    /// malformed client cannot make us buffer without limit.
    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let chunk, !chunk.isEmpty {
                accumulated.append(chunk)
            }

            let terminator = Data("\r\n\r\n".utf8)
            if let range = accumulated.range(of: terminator) {
                let headerData = accumulated.subdata(in: accumulated.startIndex..<range.lowerBound)
                self.serve(connection, header: headerData)
                return
            }

            // Guard against an unbounded / never-terminated header.
            if isComplete || accumulated.count > 64_000 {
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: accumulated)
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
        let mime = items.first(where: { $0.name == "mime" })?.value ?? "video/mp4"

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
            if let s = Int(bounds.first ?? ""), s >= 0 { start = s }
            if bounds.count > 1, let e = Int(bounds[1]), e >= start { end = e }
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
    /// before requesting the next (backpressure keeps memory bounded to a single window). Stops on client
    /// disconnect or any upstream error.
    private func streamWindows(_ connection: NWConnection, upstream: URL, pos: Int, end: Int) {
        guard pos <= end else {
            connection.cancel()   // done: the 206 body is complete
            return
        }
        let stop = min(pos + Self.windowSize - 1, end)
        guard let windowURL = Self.appendRange(upstream, start: pos, stop: stop) else {
            connection.cancel()
            return
        }

        var request = URLRequest(url: windowURL)
        // NO Range header upstream: googlevideo answers the bounded `&range=` query with a plain 200.
        request.setValue(YouTubeDirectResolver.googlevideoUserAgent, forHTTPHeaderField: "User-Agent")

        let task = upstream_session_dataTask(request) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
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
