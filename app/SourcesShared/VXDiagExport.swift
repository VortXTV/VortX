import Foundation
import Network
import CoreImage
import SwiftUI
import Darwin   // getifaddrs / ifaddrs / getnameinfo for LAN IPv4 discovery

/// One-shot LAN export for the rolling diagnostic log (`VXProbe.logFileURL`). Apple TV has no share
/// sheet, so the owner cannot AirDrop or email the log off the box directly. Instead this stands up a
/// tiny HTTP server bound to the LAN on an ephemeral port that serves the current `vortx-diag.log` as a
/// downloadable text/plain attachment, and hands back a QR code encoding `http://LANIP:PORT/`. The owner
/// scans it with their phone on the same Wi-Fi, the log downloads to the phone, and they send it on.
///
/// This mirrors `VXTrailerProxy`'s NWListener pattern (bind, resolve the ephemeral port on `.ready`, read
/// the request header to CRLFCRLF, write an HTTP response, close), but binds to `0.0.0.0` (all interfaces)
/// so a phone on the LAN can reach it, and answers a single GET `/` with the file rather than proxying.
///
/// FAIL-SOFT: every path is wrapped so a bad request or a gone client just closes that one connection.
/// `start()` returns nil (caller shows a "connect to Wi-Fi" message) when there is no LAN IPv4 to advertise
/// or the listener will not come up. `stop()` tears the listener down so the log is not left served.
final class VXDiagExport {

    static let shared = VXDiagExport()

    private let queue = DispatchQueue(label: "com.stremiox.vxdiagexport")

    /// A SEPARATE queue for the listener's state/connection callbacks: `start()` blocks `queue` on a
    /// semaphore waiting for `.ready`, so the state handler must run elsewhere or it would deadlock.
    private let listenerQueue = DispatchQueue(label: "com.stremiox.vxdiagexport.listener")

    private var listener: NWListener?
    private var port: UInt16 = 0

    /// Open accepted connections, so `stop()` can cancel any that are mid-request instead of leaking them.
    /// Guarded by `stateLock` (touched from `queue` on accept/teardown and from `stop()`'s `queue.sync`).
    private let stateLock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Header-read deadline so a phone that connects and then stalls never leaks its connection.
    private static let headerDeadline: TimeInterval = 15

    /// Set once the LAN server has actually served the log to a phone at least once this session, so `stop()`
    /// (export screen dismissed) can CLEAR the rolling log then and only then, giving the next export a fresh
    /// buffer without wiping data that was never downloaded. Owner request: "once exported, clear it."
    private var didServe = false

    private init() {}

    // MARK: - Public contract

    /// Start (idempotent) the LAN log server and return `(url, qr)` for display, or nil when there is no
    /// Wi-Fi IPv4 to advertise or the listener cannot start. `url` is `http://LANIP:PORT/`; `qr` encodes it.
    func start() -> (url: String, qr: Image)? {
        guard let ip = Self.lanIPv4() else {
            NSLog("[diag] export: no LAN IPv4 (not on Wi-Fi?)")
            return nil
        }
        guard let boundPort = ensureListening() else {
            NSLog("[diag] export: listener failed to start")
            return nil
        }
        let urlString = "http://\(ip):\(boundPort)/"
        guard let cg = Self.qrImage(urlString) else {
            NSLog("[diag] export: QR generation failed for %@", urlString)
            return nil
        }
        NSLog("[diag] export: serving diagnostic log at %@", urlString)
        return (urlString, Image(decorative: cg, scale: 1))
    }

    /// Tear the listener down so the log is no longer served. Safe to call when not started.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            port = 0
            // Cancel any connection still mid-request so a stalled phone is not left holding an open socket.
            stateLock.lock()
            let open = Array(connections.values)
            connections.removeAll()
            stateLock.unlock()
            open.forEach { $0.cancel() }
            // Clear the rolling log ONLY if it was actually downloaded this session, so the next export starts
            // fresh (owner request) without discarding a log the phone never fetched.
            if didServe {
                VXProbe.clearLog()
                didServe = false
                NSLog("[diag] export: stopped + cleared log (was served)")
            } else {
                NSLog("[diag] export: stopped")
            }
        }
    }

    // MARK: - Listener lifecycle

    /// Start the listener once (idempotent) and return its bound port, or nil on failure. Serialized on
    /// `queue`. Binds to `0.0.0.0` (all interfaces) so a phone on the same Wi-Fi can reach it.
    private func ensureListening() -> UInt16? {
        queue.sync {
            if listener != nil, port != 0 { return port }

            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                // Bind to all interfaces (not loopback): the phone downloading the log is a different device.
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: .any)
                let newListener = try NWListener(using: params)
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
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
                _ = ready.wait(timeout: .now() + 2)
                guard newListener.port?.rawValue != nil, self.port != 0 else {
                    newListener.cancel()
                    return nil
                }
                self.listener = newListener
                NSLog("[diag] export: listener started on port %d", self.port)
                return self.port
            } catch {
                NSLog("[diag] export: listener start failed: %@", String(describing: error))
                return nil
            }
        }
    }

    // MARK: - Per-connection handling

    /// Accept one phone connection: read its request header, then serve the log file. The connection is
    /// tracked so `stop()` can cancel it, and a deadline force-cancels a client that never sends a header.
    private func handle(_ connection: NWConnection) {
        stateLock.lock()
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

    /// Read until the header terminator (CRLFCRLF), then serve. Bounds the read so a malformed client
    /// cannot make us buffer without limit; the deadline force-cancels a header that never completes.
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
            if accumulated.range(of: terminator) != nil {
                deadline.cancel()
                self.serve(connection)
                return
            }
            if isComplete || accumulated.count > 64_000 {
                deadline.cancel()
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: accumulated, deadline: deadline)
        }
    }

    /// Write the current diagnostic log as a text/plain attachment, then close. Any read failure yields an
    /// empty body rather than an error so the phone still gets a (harmless) file.
    private func serve(_ connection: NWConnection) {
        var body = (try? Data(contentsOf: VXProbe.logFileURL)) ?? Data("(diagnostic log is empty)\n".utf8)
        body.append(Self.serverSection())
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Disposition: attachment; filename="vortx-diag.log"\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        NSLog("[diag] export: sending log (%d bytes)", body.count)
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            // The log has now been handed to the phone: mark it served so `stop()` clears the buffer for a
            // fresh next export. Serialized on `queue` (same queue the connection + stop() run on).
            self?.queue.async { self?.didServe = true }
            connection.cancel()
        })
    }

    // MARK: - Helpers

    /// The embedded streaming-server section appended to every diagnostics export (F4): the server's current
    /// one-line status plus a bounded tail (~100 lines) of its OWN log (`stremio-server.log`). The rolling
    /// probe log alone never carried the node's log, so a server death/stall was invisible in the file the
    /// owner actually sends. Target-safe via ServerDiagnostics: on a build with no server (the Lite tvOS app)
    /// the provider is nil and this returns an empty section. Never throws.
    private static func serverSection() -> Data {
        guard let status = ServerDiagnostics.status() else { return Data() }
        let tail = ServerDiagnostics.logTail(100)
        var section = "\n\n===== streaming server =====\nstatus: \(status)\n"
        if tail.isEmpty {
            section += "(server log empty or unavailable)\n"
        } else {
            section += "--- stremio-server.log (last \(tail.count) lines) ---\n"
            section += tail.map(scrubURLs).joined(separator: "\n")
            section += "\n"
        }
        return Data(section.utf8)
    }

    /// Reduces every http(s) URL embedded in a server log line to `scheme://host/path`, dropping the query
    /// string and fragment entirely, mirroring the redaction `MPVMetalViewController.loadFile` applies to
    /// its own `mpvLog` line (`"\(playURL.scheme ?? "?")://\(playURL.host ?? "?")\(playURL.path)"`): debrid
    /// and direct-CDN URLs carry API tokens / signed queries that must not leave the device in the exported
    /// log tail. Adapted here (rather than reused directly) because that call site redacts one known URL
    /// value, while this one has to find and replace URLs embedded anywhere inside a free-text log line.
    /// Fails soft: a line with no URL, or a matched substring that fails to parse as a URL, passes through
    /// unchanged.
    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]]+"#)

    private static func scrubURLs(_ line: String) -> String {
        guard let urlPattern else { return line }
        let nsLine = line as NSString
        let matches = urlPattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else { return line }

        var result = line
        // Replace back-to-front so each earlier match's NSRange (computed against the original line) still
        // lines up with `result`: only text AFTER the current match has been touched by prior iterations.
        for match in matches.reversed() {
            let raw = nsLine.substring(with: match.range)
            guard let url = URL(string: raw), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)")
        }
        return result
    }

    /// The device's LAN IPv4 for the Wi-Fi interface (`en0`), or nil when not on Wi-Fi. Uses getifaddrs so
    /// no extra entitlement is needed; falls back to the first non-loopback IPv4 if `en0` is not present.
    private static func lanIPv4() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }

        var preferred: String?   // en0 (Wi-Fi)
        var fallback: String?    // any other non-loopback IPv4
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  flags & IFF_LOOPBACK == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, !ip.hasPrefix("169.254") else { continue }   // skip link-local

            if name == "en0" {
                preferred = ip
            } else if fallback == nil {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }

    /// Generate a scaled QR CGImage for `string` with CoreImage (no external dependency). Returns nil if
    /// the generator is unavailable. Rendered as a CGImage so `Image(decorative:scale:)` works on every
    /// platform without a UIImage/NSImage split.
    private static func qrImage(_ string: String) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

#if os(macOS)
import AppKit

extension VXDiagExport {

    /// macOS export path: a Mac has a filesystem and Finder, so the LAN-server + scan-a-QR-with-your-phone
    /// dance (built for Apple TV, which has neither a share sheet nor a reachable file browser) is the wrong
    /// mechanism and also trips over the App Sandbox network-server gate on a `0.0.0.0` bind. Instead just
    /// copy the current rolling `vortx-diag.log` into the user's Downloads folder and reveal it in Finder so
    /// the owner grabs and sends the file directly. Returns the destination path to show the user, or nil if
    /// the log could not be materialised anywhere.
    @MainActor func revealInFinder() -> String? {
        let src = VXProbe.logFileURL
        let fm = FileManager.default
        // Prefer Downloads (user-visible); fall back to the temp dir if it is not resolvable.
        let destDir = (try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.temporaryDirectory
        let dest = destDir.appendingPathComponent("vortx-diag.log")
        // Copy the current log (overwriting any stale copy). If the source is missing/empty, still write a
        // placeholder so the reveal is not a dead file.
        var data = (try? Data(contentsOf: src)) ?? Data("(diagnostic log is empty)\n".utf8)
        data.append(Self.serverSection())   // F4: fold in the streaming server's status + log tail
        do {
            try data.write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            // The Downloads copy is an independent file, so it is safe to clear the live rolling log now: the
            // next export starts fresh (owner request "once exported, clear it").
            VXProbe.clearLog()
            NSLog("[diag] export: revealed %@ in Finder + cleared live log", dest.path)
            return dest.path
        } catch {
            // Downloads not writable (unexpected on an unsandboxed Mac): reveal the log in place instead.
            NSWorkspace.shared.activateFileViewerSelecting([src])
            NSLog("[diag] export: copy to Downloads failed (%@), revealed source in place", String(describing: error))
            return src.path
        }
    }
}
#endif
