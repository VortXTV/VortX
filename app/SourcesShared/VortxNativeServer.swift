#if os(iOS) || os(tvOS)
import Foundation
#if canImport(VortxEngine)
import VortxEngine
#endif

/// Phase 8 (engine/apple-cutover), server slice: run the vortx-core streaming server IN-PROCESS on
/// iOS/tvOS via the vortx-ffi C server ABI (vortx_server_start / vortx_server_port /
/// vortx_server_base_url / vortx_server_stop), the platforms where a subprocess spawn is impossible
/// so the server MUST live inside the app binary. This is the iOS/tvOS sibling of
/// `MacNodeServer.swift` (macOS runs the server as a child process): same lifecycle shape
/// (start on launch/foreground, stop on background, publish the bound port for the player), same
/// SourcesShared home.
///
/// ADDITIVE + FLAG-GATED. The `vortxNativeServer` UserDefaults flag defaults OFF: a default build
/// takes exactly one boolean read here and the nodejs-mobile `NodeServer` path serves the player
/// byte-identically to today. Flag ON starts THIS server (ephemeral port, loopback) alongside the
/// node one and `StremioServer.embeddedPort` prefers its published port, so the player streams
/// through the engine server while every nodejs code path stays untouched and revertable with one
/// toggle. The flag flip is CEO/device-gated; nothing in the app turns it on by itself.
///
/// Compile gating, two layers:
///   - `canImport(VortxEngine)`: the target links VortxEngine.xcframework at all (today only
///     VortXiOSNative; a target without the framework compiles the inert stubs below).
///   - `VORTX_ENGINE_SERVER` (a per-target SWIFT_ACTIVE_COMPILATION_CONDITIONS entry in
///     project.yml): the linked slice actually CARRIES the 4 server symbols. `canImport` cannot
///     see symbols, only the module, so a kernel-only slice (the `--no-server` fallback build of
///     scripts/build-ffi-xcframework.sh, or a tvOS slice if the tier-3 cross-compile walls) would
///     pass `canImport` and then fail at link. The project.yml condition is set exactly where the
///     xcframework slice is server-inclusive, keeping "compiles" and "links" in agreement.
enum VortxNativeServerFlag {
    /// Settings-parity rule: the SAME key on every app (VortXiOSNative, VortXTV; macOS task #61
    /// uses this name for its native-server flag too, so one key governs the native-server
    /// cutover on every platform when the branches meet).
    static let key = "vortxNativeServer"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Whether THIS build can run the in-process engine server (framework linked AND the slice is
    /// server-inclusive). Settings uses it to show the toggle only where flipping it can work.
    static var isSupported: Bool {
        #if canImport(VortxEngine) && VORTX_ENGINE_SERVER
        return true
        #else
        return false
        #endif
    }
}

/// The in-process engine streaming-server manager. All entry points exist on every iOS/tvOS
/// target (inert stubs when the engine server is not linked), so call sites need no conditionals.
enum VortxNativeServer {
    #if canImport(VortxEngine) && VORTX_ENGINE_SERVER

    /// Serializes the whole lifecycle. The FFI contract is one call at a time per handle, and both
    /// start (bind + rqbit session) and stop (graceful shutdown, up to ~4 s with open streams)
    /// BLOCK, so they run here, never on the main thread. Matches the serial-queue pattern of
    /// MacNodeServer / DiagnosticsLog.
    private static let queue = DispatchQueue(label: "com.stremiox.vortx-native-server", qos: .userInitiated)
    /// The opaque ServerHandle from `vortx_server_start`. Touched only on `queue`. Nulled BEFORE
    /// `vortx_server_stop` consumes it (the pointer is freed by that call; a second stop with the
    /// same pointer would be a double free).
    private static var handle: UnsafeMutableRawPointer?

    /// Publishes the running server's address to readers on other threads
    /// (`StremioServer.embeddedPort` is read from the player and Settings). Lock-guarded because
    /// the writer is `queue` and the readers are arbitrary threads.
    private static let publishLock = NSLock()
    private static var _port: Int?
    private static var _baseURL: String?

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

    /// One-line state for Settings diagnostics, mirroring NodeServer.statusDescription's role.
    static var statusDescription: String {
        guard VortxNativeServerFlag.isOn else { return "Off" }
        if let base = publishedBaseURL { return "In-process engine server running at \(base)" }
        return "Enabled, waiting to start"
    }

    /// Piece-cache self-bound. The node server defaults to a 2 GB torrent cache, which the app has
    /// to cap after boot via POST /settings; the engine server takes the cap up front in its start
    /// config. 128 MiB sits inside the 96-192 MiB range the FFI documents for the iOS/tvOS
    /// sandbox (Apple TV HD is the 2 GB floor device).
    private static let cacheSizeBytes = 134_217_728
    /// Peer-connection self-bound for the same sandbox (fd budget shared with mpv + URLSession;
    /// the value the FFI docs give for iOS/tvOS).
    private static let btMaxConnections = 35

    /// Start the engine server if the flag is on and it is not already running. Async on the
    /// serial queue, so calling from app init / scenePhase never blocks the main thread.
    /// Idempotent; a start failure is logged and leaves the nodejs path serving as before.
    static func startIfNeeded() {
        guard VortxNativeServerFlag.isOn else { return }
        queue.async {
            guard handle == nil else { return }
            // The same writable root the node server uses (tvOS may only write Caches + tmp, so
            // Application Support, the Mac's choice, is not portable here). Its own subdir keeps
            // the engine server's settings.json / piece cache / port file apart from node's.
            let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
                ?? NSTemporaryDirectory()
            let home = (caches as NSString).appendingPathComponent("vortx-server")
            try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

            // Port 0 = ephemeral bind, read back below. Deliberately NOT 11470: with the flag ON
            // the node server still boots (this path is additive; nothing gates node yet), so
            // claiming its port would push node into the silent 11471+ EADDRINUSE fallback.
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
                DiagnosticsLog.log("server", "vortx_server_start returned NULL; engine in-process server unavailable (node path still serving)")
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
            DiagnosticsLog.log("server", "engine in-process server started at \(base) (flag vortxNativeServer)")
        }
    }

    /// Graceful stop + free. Synchronous on the serial queue: if a start is mid-flight it finishes
    /// first, then this stop consumes the handle, so the two can never overlap on the pointer.
    /// The publish is cleared BEFORE the (briefly blocking) stop so no reader routes a new request
    /// at a server that is shutting down.
    static func stop() {
        queue.sync {
            guard let h = handle else { return }
            handle = nil
            publish(port: nil, baseURL: nil)
            vortx_server_stop(h)
            DiagnosticsLog.log("server", "engine in-process server stopped")
        }
    }

    /// Background-transition stop, detached so the (up to ~4 s) graceful shutdown never runs on
    /// the main thread during the OS's backgrounding window. Known trade-off, documented rather
    /// than hidden: with the flag ON, backgrounding tears the engine server down, so a torrent
    /// stream continued in PiP/background dies with it; foreground restarts on a fresh ephemeral
    /// port and `StremioServer.embeddedPort` follows. The node path (flag OFF) is unaffected.
    static func stopOnBackground() {
        guard VortxNativeServerFlag.isOn else { return }
        Task.detached(priority: .utility) { stop() }
    }

    #else

    // Engine server not linked in this target (no VortxEngine.xcframework, a kernel-only slice,
    // or the Lite build): every entry point is an inert no-op so call sites compile unchanged.
    static var publishedPort: Int? { nil }
    static var publishedBaseURL: String? { nil }
    static var statusDescription: String { "Not available in this build" }
    static func startIfNeeded() {}
    static func stop() {}
    static func stopOnBackground() {}

    #endif
}
#endif
