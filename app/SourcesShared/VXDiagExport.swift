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
/// the request, write an HTTP response, close), but binds to `0.0.0.0` (all interfaces) so a phone on the
/// LAN can reach it.
///
/// WHAT IT SERVES AND TO WHOM. Exactly one `GET` of one unguessable 128-bit path, once per start. It used to
/// be described as one-shot and was neither one-shot nor addressed: it advertised a bare root URL, served
/// ANY connection whose bytes happened to contain a CRLF pair without ever checking the method or the path,
/// and kept the listener alive so any LAN peer could pull the log repeatedly for as long as the screen was
/// up. `VXDiagExportPolicy` now mints the capability and makes the accept/reject decision; the scope of what
/// that does and does not buy is written at `VXDiagExportPolicy.makeCapabilityPath`.
///
/// FAIL-SOFT: every path is wrapped so a bad request or a gone client just closes that one connection.
/// `start()` returns nil (caller shows a "connect to Wi-Fi" message) when there is no LAN IPv4 to advertise
/// or the listener will not come up. `stop()` tears the listener down so the log is not left served.
final class VXDiagExport: @unchecked Sendable {

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

    /// How long `startAsync()` keeps re-attempting the cold listener bring-up while Wi-Fi is present.
    /// The FIRST export of a session pays for Network.framework init plus the local-network determination
    /// on the `0.0.0.0` bind, which can outlast one `ensureListening()` `.ready` wait; the retry budget
    /// covers that so the very first open produces the QR instead of only a later re-entry once warm.
    private static let coldStartBudget: TimeInterval = 6
    private static let coldStartRetryGap: TimeInterval = 0.3

    /// Separates an in-flight one-shot claim from local send completion. A failed or interrupted client
    /// releases its claim for retry, while nominal completion consumes the capability. Neither clears the
    /// rolling log because Network.framework completion is not receiver acknowledgement.
    /// Guarded by `stateLock`.
    private var transferGate = VXDiagExportPolicy.TransferGate()

    /// The unguessable path minted for the CURRENT export session, guarded by `stateLock`. Re-minted on
    /// every `start()`, so a path scraped from an earlier session's QR code is dead.
    private var capabilityPath = ""

    private struct ExportPayload {
        let body: Data
        let logSnapshot: VXProbeLogSnapshot
    }

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
        // Fresh capability per start, and the one-shot gate re-armed with it: the URL on screen is the only
        // thing that can fetch this session's log, and it can do it once.
        stateLock.lock()
        capabilityPath = VXDiagExportPolicy.makeCapabilityPath()
        transferGate.reset()
        let path = capabilityPath
        stateLock.unlock()
        let urlString = "http://\(ip):\(boundPort)\(path)"
        guard let cg = Self.qrImage(urlString) else {
            NSLog("[diag] export: QR generation failed")
            return nil
        }
        // The capability is IN the URL, so the URL is a secret for the length of the export window and is
        // never written to a log line.
        NSLog("[diag] export: serving diagnostic log on port %d", boundPort)
        return (urlString, Image(decorative: cg, scale: 1))
    }

    /// `start()` off the main thread, retried through the cold bring-up. Apple TV opened the export screen
    /// blank on the FIRST attempt and only filled it in on a later re-entry, because a single synchronous
    /// `start()` on the main actor gave the cold LAN listener no time to reach `.ready` (Network.framework
    /// init + local-network determination) inside one `ensureListening()` wait, so it returned nil and the
    /// sheet showed its no-QR fallback. Here the work runs off the main thread (the caller shows a spinner)
    /// and `start()` is re-attempted while Wi-Fi is present and we are inside `coldStartBudget`, so the QR
    /// is produced as soon as the listener is actually ready.
    ///
    /// On the warm/happy path the first `start()` succeeds and the loop body never runs, so this is
    /// byte-identical to a lone `start()`: same fresh capability, same one-shot `didServe` re-arm. When a
    /// retry is needed, each `start()` re-mints the capability exactly as a fresh export should, and the
    /// last successful attempt is the live one; the serve-once contract is untouched.
    func startAsync() async -> (url: String, qr: Image)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(Self.coldStartBudget)
                var result = self.start()
                while result == nil, Self.lanIPv4() != nil, Date() < deadline {
                    Thread.sleep(forTimeInterval: Self.coldStartRetryGap)
                    result = self.start()
                }
                continuation.resume(returning: result)
            }
        }
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
            transferGate.reset()
            capabilityPath = ""   // retire the capability with the listener
            stateLock.unlock()
            open.forEach { $0.cancel() }
            // LAN sends never clear the rolling log without app-layer receiver acknowledgement. Stopping also
            // retires the capability and cancels any incomplete connection.
            NSLog("[diag] export: stopped")
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
        let connectionID = ObjectIdentifier(connection)
        stateLock.lock()
        connections[connectionID] = connection
        stateLock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                self.stateLock.lock()
                self.connections.removeValue(forKey: connectionID)
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

    /// Read until the REQUEST LINE is complete (the first LF), then let `VXDiagExportPolicy` decide.
    ///
    /// The request line is enough: the decision is method plus path, and waiting for CRLFCRLF only gave a
    /// peer more room to send bytes we do not read. Anything the policy rejects is closed WITHOUT a reply,
    /// so a scanner probing the port learns nothing from us, not even a 404. The read is bounded and the
    /// deadline force-cancels a client that never completes a line.
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

            if accumulated.contains(0x0A) {
                deadline.cancel()
                // Claim the one-shot under the lock so two simultaneous connections cannot both win it.
                self.stateLock.lock()
                let path = self.capabilityPath
                let decision = VXDiagExportPolicy.decide(request: accumulated,
                                                         capabilityPath: path,
                                                         alreadyServed: self.transferGate.blocksNewClaim || path.isEmpty)
                let claim = decision == .serve ? self.transferGate.claim() : nil
                self.stateLock.unlock()
                if let claim {
                    self.serve(connection, claim: claim)
                } else {
                    NSLog("[diag] export: rejected a request")
                    connection.cancel()
                }
                return
            }
            if isComplete || accumulated.count > VXDiagExportPolicy.maxRequestLineBytes {
                deadline.cancel()
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: accumulated, deadline: deadline)
        }
    }

    /// Write the current diagnostic log as a text/plain attachment, then close. Any read failure yields an
    /// empty body rather than an error so the phone still gets a (harmless) file.
    private func serve(
        _ connection: NWConnection,
        claim: VXDiagExportPolicy.TransferClaim
    ) {
        let payload = Self.exportPayload()
        let body = payload.body
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Disposition: attachment; filename="vortx-diag.log"\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        NSLog("[diag] export: sending log (%d bytes)", body.count)
        let ranges = VXDiagExportPolicy.chunkRanges(bodyBytes: body.count)
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.finishTransfer(
                    connection, claim: claim, success: false
                )
                return
            }
            self.sendBodyChunks(
                body,
                ranges: ranges,
                index: 0,
                connection: connection,
                claim: claim
            )
        })
    }

    private func sendBodyChunks(
        _ body: Data,
        ranges: [Range<Int>],
        index: Int,
        connection: NWConnection,
        claim: VXDiagExportPolicy.TransferClaim
    ) {
        guard ranges.indices.contains(index) else {
            finishTransfer(
                connection, claim: claim, success: true
            )
            return
        }
        let chunk = body.subdata(in: ranges[index])
        let isFinalChunk = index == ranges.index(before: ranges.endIndex)
        connection.send(
            content: chunk,
            contentContext: isFinalChunk
                ? NWConnection.ContentContext.finalMessage
                : NWConnection.ContentContext.defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.finishTransfer(
                        connection, claim: claim, success: false
                    )
                    return
                }
                self.sendBodyChunks(
                    body,
                    ranges: ranges,
                    index: index + 1,
                    connection: connection,
                    claim: claim
                )
            }
        )
    }

    private func finishTransfer(
        _ connection: NWConnection,
        claim: VXDiagExportPolicy.TransferClaim,
        success: Bool
    ) {
        stateLock.lock()
        let completion = transferGate.complete(claim, success: success)
        stateLock.unlock()
        switch completion {
        case .deliveredPreservingLog:
            NSLog("[diag] export: LAN send completed; preserved rolling log because receiver did not ACK")
        case .retryableFailure:
            NSLog("[diag] export: transfer failed; preserved log for retry")
        case .stale:
            break
        }
        switch completion.connectionCleanup {
        case .waitForPeerClose:
            waitForPeerClose(connection)
        case .cancelImmediately:
            connection.cancel()
        }
    }

    /// `contentProcessed` only means Network.framework accepted the final send locally. `finalMessage`
    /// performs the TCP write-close, so cancelling at that callback can truncate buffered body bytes or FIN.
    /// Keep the connection alive until the peer closes its side, with a fixed upper bound for cleanup.
    private static let peerCloseTimeout: TimeInterval = 30

    private func waitForPeerClose(_ connection: NWConnection) {
        let timeout = DispatchWorkItem {
            NSLog("[diag] export: peer-close timeout; preserved rolling log")
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + Self.peerCloseTimeout, execute: timeout)
        receiveUntilPeerClose(connection, timeout: timeout)
    }

    private func receiveUntilPeerClose(
        _ connection: NWConnection,
        timeout: DispatchWorkItem
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
            [weak self] _, _, isComplete, error in
            guard !timeout.isCancelled else { return }
            if isComplete || error != nil {
                timeout.cancel()
                connection.cancel()
                return
            }
            guard let self else {
                timeout.cancel()
                connection.cancel()
                return
            }
            self.receiveUntilPeerClose(connection, timeout: timeout)
        }
    }

    // MARK: - Helpers

    /// The COMPLETE bytes of one export, built AT EXPORT TIME from whatever is on disk right now: the
    /// rolling probe log plus the embedded streaming server's status and a bounded tail (~400 lines) of its
    /// OWN log (`stremio-server.log`). Every line of both is re-run through the current redaction rules by
    /// `VXDiagExportPolicy.exportBody`.
    ///
    /// The tail is 400 rather than 100 because 100 could not span an event. The server writes a heartbeat
    /// plus its ordinary request chatter, so 100 lines was a couple of minutes of wall clock: an export
    /// taken after a suspension carried only the post-wake side, and the before/after comparison was gone
    /// before anyone could ask for it (FAIL-260804-10). Every line still passes through the same redaction,
    /// so a longer tail widens the window, not the disclosure.
    ///
    /// Why re-run rules over bytes that were supposedly scrubbed on the way in: because they were not, or
    /// not by these rules. `Caches/vortx-diag.log` and `Caches/stremio-server.log` both survive app updates,
    /// so a build that scrubs on write still exports whatever an older build wrote. The server log is worse
    /// than legacy: it is written by bundled JavaScript we do not own, which logs RAW TORRENT HASHES on
    /// engine created/destroyed/idle/inactive/error/invalid-piece, and no write-path fix of ours reaches it.
    ///
    /// Target-safe via ServerDiagnostics: on a build with no server (the Lite tvOS app) the provider is nil
    /// and the server section is omitted. Never throws.
    private static func exportPayload() -> ExportPayload {
        let snapshot = VXProbe.logSnapshot()
        let status = ServerDiagnostics.status()
        let tail = status == nil ? [] : ServerDiagnostics.logTail(400)
        let body = VXDiagExportPolicy.exportBody(
            logContents: snapshot.contents,
            serverStatus: status,
            serverTailLines: tail
        )
        return ExportPayload(body: body, logSnapshot: snapshot)
    }

    /// Materialize a sanitized point-in-time body for the native share-sheet and Finder export paths. The
    /// caller decides whether a receiver acknowledgement exists and therefore whether consumption is safe.
    static func exportBody() -> Data {
        exportPayload().body
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
        let fm = FileManager.default
        // Prefer Downloads (user-visible); fall back to the temp dir if it is not resolvable.
        let destDir = (try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.temporaryDirectory
        let dest = destDir.appendingPathComponent("vortx-diag.log")
        // Write the SANITISED export body (overwriting any stale copy) rather than copying the live file:
        // the live file holds whatever every previous build wrote, and this is an export path like any
        // other. If the source is missing/empty the body is a placeholder, so the reveal is not a dead file.
        let payload = Self.exportPayload()
        let data = payload.body
        do {
            try data.write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            // Consume only the point-in-time prefix copied above. Lines appended while the atomic write or
            // Finder reveal was in flight remain in the live log for the next export.
            VXProbe.consumeLogSnapshot(payload.logSnapshot)
            NSLog("[diag] export: revealed %@ in Finder + consumed exported snapshot", dest.path)
            return dest.path
        } catch {
            // Downloads not writable (unexpected on an unsandboxed Mac): fall back to the temp dir, still
            // with the sanitised body. Revealing the LIVE file in place was the old fallback and it is an
            // export path that skips the sanitiser, which is exactly the hole this change closes.
            let temp = fm.temporaryDirectory.appendingPathComponent("vortx-diag.log")
            guard (try? data.write(to: temp, options: .atomic)) != nil else {
                NSLog("[diag] export: could not materialise the log anywhere (%@)", String(describing: error))
                return nil
            }
            NSWorkspace.shared.activateFileViewerSelecting([temp])
            VXProbe.consumeLogSnapshot(payload.logSnapshot)
            NSLog("[diag] export: Downloads not writable (%@), revealed the temp copy + consumed exported snapshot", String(describing: error))
            return temp.path
        }
    }
}
#endif
