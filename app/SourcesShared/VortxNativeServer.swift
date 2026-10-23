#if os(iOS) || os(tvOS)
import Foundation
import VortxEngine

/// The VortX engine's streaming server, run IN-PROCESS on iOS/tvOS via the vortx-ffi C server ABI
/// (vortx_server_start / vortx_server_port / vortx_server_base_url / vortx_server_stop). These
/// platforms cannot spawn a subprocess, so the server lives inside the app binary; macOS runs the
/// same server as a child process (`MacNodeServer.swift`). Start on launch/foreground, stop on
/// background, publish the bound port for the player. A start failure stays explicit until the
/// next foreground or relaunch.
///
/// `VORTX_ENGINE_SERVER` (a per-target SWIFT_ACTIVE_COMPILATION_CONDITIONS entry in project.yml)
/// marks targets whose linked VortxEngine slice carries the server symbols. The Lite build links
/// no server, so it compiles the inert stubs below.
enum VortxNativeServerFlag {
    /// Whether THIS build can run the in-process engine server (the linked slice is
    /// server-inclusive). The Lite build has no streaming server.
    static var isSupported: Bool {
        #if VORTX_ENGINE_SERVER
        return true
        #else
        return false
        #endif
    }
}

/// The in-process engine streaming-server manager. All entry points exist on every iOS/tvOS
/// target (inert stubs when the engine server is not linked), so call sites need no conditionals.
enum VortxNativeServer {
    #if VORTX_ENGINE_SERVER

    /// Serializes the whole lifecycle. The FFI contract is one call at a time per handle, and both
    /// start (bind + rqbit session) and stop (graceful shutdown, up to ~4 s with open streams)
    /// BLOCK, so they run here, never on the main thread. Matches the serial-queue pattern of
    /// MacNodeServer / DiagnosticsLog.
    private static let queue = DispatchQueue(label: "com.stremiox.vortx-native-server", qos: .userInitiated)
    /// The opaque ServerHandle from `vortx_server_start`. Touched only on `queue`. Nulled BEFORE
    /// `vortx_server_stop` consumes it (the pointer is freed by that call; a second stop with the
    /// same pointer would be a double free).
    nonisolated(unsafe) private static var handle: UnsafeMutableRawPointer?

    /// Publishes the running server's address to readers on other threads
    /// (`StremioServer.embeddedPort` is read from the player and Settings). Lock-guarded because
    /// the writer is `queue` and the readers are arbitrary threads.
    private static let publishLock = NSLock()
    nonisolated(unsafe) private static var _port: Int?
    nonisolated(unsafe) private static var _baseURL: String?
    nonisolated(unsafe) private static var _failure: String?

    /// The ACTUAL bound port while the engine server runs, else nil. Ephemeral (port 0 bind), so
    /// it changes across background/foreground cycles; `StremioServer.embeddedPort` re-reads it
    /// per use, so followers never go stale.
    static var publishedPort: Int? {
        publishLock.lock(); defer { publishLock.unlock() }
        return _port
    }
    /// The advertised base URL (`http://127.0.0.1:PORT`) while running, else nil.
    static var publishedBaseURL: String? {
        publishLock.lock(); defer { publishLock.unlock() }
        return _baseURL
    }
    private static func publish(port: Int?, baseURL: String?) {
        publishLock.lock()
        _port = port
        _baseURL = baseURL
        publishLock.unlock()
    }

    /// One-line state for Settings diagnostics.
    static var statusDescription: String {
        if let base = publishedBaseURL { return "In-process engine server running at \(base)" }
        publishLock.lock(); defer { publishLock.unlock() }
        if let failure = _failure { return failure }
        return "Enabled, waiting to start"
    }

    /// Piece-cache self-bound, taken up front in the start config. 128 MiB sits inside the 96-192 MiB range the FFI documents for the iOS/tvOS
    /// sandbox (Apple TV HD is the 2 GB floor device).
    private static let cacheSizeBytes = 134_217_728
    /// Peer-connection self-bound for the same sandbox (fd budget shared with mpv + URLSession;
    /// the value the FFI docs give for iOS/tvOS).
    private static let btMaxConnections = 35

    /// Start the engine server if it is not already running. Async on the serial queue, so
    /// calling from app init / scenePhase never blocks the main thread. Idempotent; a start
    /// failure remains explicit.
    static func startIfNeeded() {
        queue.async {
            guard handle == nil else { return }
            publishLock.lock(); _failure = nil; publishLock.unlock()
            // tvOS may only write Caches + tmp, so Application Support (the Mac's choice) is not
            // portable here. The subdir holds the server's settings.json / piece cache / port file.
            let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
                ?? NSTemporaryDirectory()
            let home = (caches as NSString).appendingPathComponent("vortx-server")
            try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

            // Port 0 = ephemeral bind, read back below. Never guess a conventional local port
            // before startup publishes the actual native listener.
            let config: [String: Any] = [
                "serverHome": home,
                "port": 0,
                "bind": "127.0.0.1",
                "cacheSize": cacheSizeBytes,
                "btMaxConnections": btMaxConnections,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: config),
                  let json = String(data: data, encoding: .utf8) else { return }

            // Blocks until bound and serving (or failed). NULL covers every failure; there is no
            // last-error channel on this ABI surface yet, so the log line is the diagnosis.
            guard let h = json.withCString({ vortx_server_start($0) }) else {
                publishLock.lock(); _failure = "Native streaming server failed to start."; publishLock.unlock()
                DiagnosticsLog.log("server", "vortx_server_start returned NULL; native streaming unavailable")
                return
            }
            handle = h
            let port = Int(vortx_server_port(h))
            var base = "http://127.0.0.1:\(port)"
            if let c = vortx_server_base_url(h) {
                base = String(cString: c)
                vortx_string_free(c)
            }
            publish(port: port, baseURL: base)
            DiagnosticsLog.log("server", "engine in-process server started at \(base)")
        }
    }

    /// Graceful stop + free. Synchronous on the serial queue: if a start is mid-flight it finishes
    /// first, then this stop consumes the handle, so the two can never overlap on the pointer.
    /// The publish is cleared BEFORE the (briefly blocking) stop so no reader routes a new request
    /// at a server that is shutting down.
    static func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Queue-only teardown, shared by synchronous shutdown and FIFO background transitions.
    private static func stopOnQueue() {
        guard let h = handle else { return }
        handle = nil
        publish(port: nil, baseURL: nil)
        vortx_server_stop(h)
        DiagnosticsLog.log("server", "engine in-process server stopped")
    }

    /// Enqueue the background stop immediately. A subsequent foreground start enters the SAME
    /// FIFO queue after this stop, even if shutdown takes time. A detached Task could enqueue its
    /// stop after that foreground start and leave the newly active app without its native server.
    /// Shutdown never runs on the main thread. Known trade-off, documented rather
    /// than hidden: backgrounding tears the engine server down, so a torrent stream continued in
    /// PiP/background dies with it; foreground restarts on a fresh ephemeral port and
    /// `StremioServer.embeddedPort` follows.
    static func stopOnBackground() {
        queue.async { stopOnQueue() }
    }

    #else

    // Engine server not linked in this target (the Lite build): every entry point is an inert no-op so call sites compile unchanged.
    static var publishedPort: Int? { nil }
    static var publishedBaseURL: String? { nil }
    static var statusDescription: String { "Native streaming is not available in this build." }
    static func startIfNeeded() {}
    static func stop() {}
    static func stopOnBackground() {}

    #endif
}
#endif
