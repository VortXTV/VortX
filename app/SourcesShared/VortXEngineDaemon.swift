#if os(macOS)
import Foundation
import AppKit

/// STANDALONE SERVER MODE: run the engine host with no user interface at all.
///
/// The destination is the shape Stremio ships: a desktop app AND a server you can just run, that clients point
/// at. This is that server. Launched with `--engine-daemon`, the same VortX binary starts the engine host,
/// takes no dock icon, opens no window, and serves until it is told to stop. `launchd` keeps it alive across
/// logins and restarts.
///
/// WHY IT IS THE APP BINARY AND NOT A SEPARATE EXECUTABLE, stated plainly because it is the one place this
/// falls short of the ideal. A separate `vortx-engined` tool would be tidier, but the remux is
/// `VortXMKVRemuxStream`, which links Libavformat, Libavcodec, Libavutil and Libdovi through MPVKit-GPL. A
/// second target linking that whole vendor tree doubles the build and gains nothing a user can perceive: the
/// process that results is the same code doing the same work. Reusing the app binary in a headless mode is how
/// a great many macOS background services actually ship, and it means the daemon and the app can never drift
/// apart in version or behaviour. What a separate executable would additionally need is listed in the design
/// note; nothing here forecloses it, because `VortXEngineHost` imports only Foundation and Network and has no
/// idea a UI exists.
///
/// This file is the ONLY place the headless service touches AppKit, and it touches it for exactly one reason:
/// to tell the window server we do not want a dock icon.
enum VortXEngineDaemon {

    /// Argument that selects headless mode.
    static let flag = "--engine-daemon"

    /// Environment equivalent, because `launchd` plists carry environment more comfortably than they carry
    /// argument vectors, and because it makes `VORTX_ENGINE_DAEMON=1 open -a VortX` work for a quick test.
    static let environmentKey = "VORTX_ENGINE_DAEMON"

    static var isRequested: Bool {
        if CommandLine.arguments.contains(flag) { return true }
        return ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// Optional config file, so the daemon can be administered without opening the app at all.
    ///
    /// It is READ ONLY at boot and every key is optional, falling back to whatever the app's own settings hold.
    /// That ordering matters: a user who configured the host in the UI and then adds a launchd agent should get
    /// the settings they already chose, not a silent reset to defaults.
    static var configURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VortX", isDirectory: true)
            .appendingPathComponent("engine.json")
    }

    struct Config: Decodable {
        let name: String?
        let port: Int?
        let retainFullTimeline: Bool?
    }

    /// Boot the headless service.
    ///
    /// Returns false when headless mode was not requested. When it IS requested this NEVER RETURNS: it hands the
    /// thread to `dispatchMain()` and the process serves until it is signalled. That is deliberate. SwiftUI's
    /// `SceneBuilder` has no conditional support, so "build no scene" is not expressible in a `body`; blocking
    /// here means AppKit's run loop is never started at all, which is what a service with no interface actually
    /// wants. `dispatchMain` services the main queue, which is all the listener's dispatch sources and the
    /// signal handlers below require.
    ///
    /// Everything here is fail-soft. A missing or malformed config file is ignored. A control port that will not
    /// bind logs and exits non-zero so `launchd` reports a real failure rather than flapping silently.
    @discardableResult
    static func bootIfRequested() -> Bool {
        guard isRequested else { return false }

        applyConfig()

        // No dock icon, no menu bar, no windows. `.accessory` rather than `.prohibited` because a prohibited
        // process cannot become active at all, and that turns out to matter for the Keychain and for anything
        // that ever needs to put a system prompt on screen; accessory is invisible in every way a user notices
        // while leaving those paths working.
        NSApplication.shared.setActivationPolicy(.accessory)

        // The engine host, unconditionally: running the daemon IS the instruction to host, so it does not
        // consult the app's on/off toggle. That toggle governs the app; the argument governs this process.
        let host = VortXEngineHost.shared
        guard host.start() else {
            log("engine host could not bind port \(host.controlPort); exiting")
            exit(70)   // EX_SOFTWARE, so launchd surfaces a real failure instead of restarting into the same one
        }
        log("VortX engine daemon serving on port \(host.boundPort) as \"\(host.displayName)\"")
        log("capabilities: \(host.capabilities.map(\.rawValue).joined(separator: ", "))")
        if host.pairingRegistry.isEmpty {
            log("no devices are paired yet. Open VortX on this Mac, turn on pairing, and enter the code on the client.")
        } else {
            log("paired devices: \(host.pairingRegistry.pairedDevices.map(\.clientName).joined(separator: ", "))")
        }

        installSignalHandlers()
        // Hand the main thread to GCD and serve. Never returns; the signal handlers above are the only exit.
        dispatchMain()
    }

    private static func applyConfig() {
        guard let configURL,
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return }
        let host = VortXEngineHost.shared
        if let name = config.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            host.displayName = name
        }
        if let port = config.port, port > 0, port <= 65535 { host.controlPort = port }
        if let retain = config.retainFullTimeline { host.retainsFullTimeline = retain }
        log("applied config from \(configURL.path)")
    }

    /// Stop cleanly on SIGTERM and SIGINT so `launchd stop` and Ctrl-C both tear sessions down instead of
    /// orphaning a producer thread and a spool directory.
    ///
    /// `DispatchSource` rather than `signal()`: a dispatch source handler runs on a real queue where it is safe
    /// to do the work, whereas a C signal handler may call almost nothing. `SIG_IGN` first is required, because
    /// the dispatch source observes the signal rather than replacing the default action.
    private static func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                log("received signal \(sig); stopping")
                VortXEngineHost.shared.stop()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Retained for the process lifetime. A dispatch source that is not held is cancelled immediately, which
    /// would silently drop the clean-shutdown behaviour above.
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// Log to stderr as well as to the app's diagnostic log. `launchd` captures stderr into whatever
    /// `StandardErrorPath` names, which is the only log a user administering a background service will look at.
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[vortx-engine] \(message)\n".utf8))
        DiagnosticsLog.log("enginehost", message)
    }
}
#endif
