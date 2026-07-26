#if os(macOS)
import Foundation
import Network

/// THE ENGINE HOST: the Mac side of external engine mode.
///
/// This is the service the CEO asked for when he said "let the Mac be the brain". It listens on the LAN, and
/// on request it builds a Dolby Vision remux for a client that cannot afford to build one itself, then serves
/// that remux as HLS. The client decodes. The host never does.
///
/// WHAT IT ACTUALLY RELIEVES, and what it cannot. It removes the MKV demux, the Profile 7 to 8.1 RPU rewrite,
/// the fragmented-MP4 mux, the segment cutting, the produce buffer and the on-disk spool from a process that
/// gets killed by jetsam at roughly 900 MB. It does NOT remove the HEVC decode or the Dolby Vision panel
/// switch, and nothing ever will: those happen on the device physically in the HDMI chain. Every byte of video
/// that leaves this host is a STREAM COPY of the source's own samples. There is no re-encode in the Dolby
/// Vision path and there must never be one, because the RPU cannot be regenerated without a Dolby encoder
/// licence and a re-encode would forfeit true DV to buy nothing.
///
/// HEADLESS BY CONSTRUCTION. This type imports Foundation and Network and nothing else. No SwiftUI, no AppKit,
/// no view model, no main-actor isolation. That is deliberate and load-bearing: the destination is a standalone
/// server in the shape Stremio ships one, and a service that reaches into the UI layer cannot become that. It
/// runs identically whether it was started by the app's settings toggle or by `launchd` against the same
/// binary in daemon mode (see `VortXEngineDaemon`).
///
/// FAIL-SOFT EVERYWHERE. A listener that will not bind logs and reports false. A session that cannot be built
/// returns an error the client turns into an on-device fallback. A client that disappears leaves a session the
/// reaper collects. Nothing here can hang, and nothing here can take the Mac app down with it.
final class VortXEngineHost: @unchecked Sendable {

    static let shared = VortXEngineHost()

    // MARK: - Persisted settings

    enum Defaults {
        static let enabledKey = "vortx.engineHost.enabled"
        static let portKey = "vortx.engineHost.port"
        static let nameKey = "vortx.engineHost.name"
        static let devicesKey = "vortx.engineHost.pairedDevices"
        static let fullTimelineKey = "vortx.engineHost.retainFullTimeline"
    }

    /// Whether the host should be running. Setting it starts or stops the listener.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Defaults.enabledKey) }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: Defaults.enabledKey)
            if newValue { _ = start() } else { stop() }
        }
    }

    /// Control port. Defaults to 11471, deliberately NOT the streaming server's 11470, so one Mac can run both
    /// and a user cannot paste one address into the other's field by accident.
    var controlPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Defaults.portKey)
            return (stored > 0 && stored <= 65535) ? stored : VortXEngineHostPolicy.defaultControlPort
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.portKey) }
    }

    /// Name shown to a client that is choosing a host.
    var displayName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Defaults.nameKey)
            if let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty { return stored }
            return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.nameKey) }
    }

    /// Whether hosted sessions retain their entire produced timeline (which is what makes seek-anywhere
    /// possible) rather than sliding a window. Defaults ON: a Mac has disk, and this is the capability the
    /// on-device lane fundamentally cannot have. Exposed so a Mac genuinely short of disk can turn it off.
    var retainsFullTimeline: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Defaults.fullTimelineKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Defaults.fullTimelineKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.fullTimelineKey) }
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "vortx.enginehost.control")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0
    private var sessions: [String: HostedSession] = [:]
    private var pairing = VortXEnginePairingState()
    private var activityToken: NSObjectProtocol?
    private var reaper: DispatchSourceTimer?

    /// Concurrent hosted sessions. Each one is a full remux: a producer thread, a spool and a listener. Two is
    /// a household watching in two rooms; beyond that the honest answer to a client is "not right now" rather
    /// than degrading everyone.
    static let maximumSessions = 4

    /// A session with no client contact for this long is abandoned and torn down. The client polls status every
    /// two seconds while playing, so a minute of silence is a dead client, not a slow one.
    static let sessionIdleTimeout: TimeInterval = 60

    let pairingRegistry: VortXEnginePairingRegistry

    private init() {
        let stored = UserDefaults.standard.data(forKey: Defaults.devicesKey)
        let devices = stored.flatMap { try? JSONDecoder().decode([VortXPairedDevice].self, from: $0) } ?? []
        pairingRegistry = VortXEnginePairingRegistry(
            devices: devices,
            tokens: VortXEngineKeychainTokenStore(),
            persist: { snapshot in
                let encoded = try? JSONEncoder().encode(snapshot)
                UserDefaults.standard.set(encoded, forKey: Defaults.devicesKey)
            })
    }

    // MARK: - Hosted session

    private final class HostedSession {
        let id: String
        let capability: String
        let server: VortXRemuxHLSServer
        let retainsFullTimeline: Bool
        var lastContact: TimeInterval
        var readyMarked = false

        init(id: String, capability: String, server: VortXRemuxHLSServer,
             retainsFullTimeline: Bool, now: TimeInterval) {
            self.id = id
            self.capability = capability
            self.server = server
            self.retainsFullTimeline = retainsFullTimeline
            self.lastContact = now
        }
    }

    // MARK: - Lifecycle

    /// Start the control listener. Idempotent, synchronous, and fail-soft: returns false rather than throwing
    /// when the port is taken or the listener will not come up.
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        if listener != nil { stateLock.unlock(); return true }
        stateLock.unlock()

        let port = controlPort
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 0.0.0.0 unconditionally: a control surface only a loopback client could reach would be pointless,
            // and it is safe to bind because EVERY route below except /info and /pair requires a bearer token
            // that only a human-approved pairing can produce.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: .any)
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
            let newListener = try NWListener(using: params, on: nwPort)
            newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            // Advertise on THIS listener rather than from a separate object. Network.framework has no
            // advertise-only API, so an independent advertiser would have to bind its own throwaway socket and
            // publish an SRV record pointing at that decoy port. Attaching the service here makes the SRV record
            // true for every mDNS client on the network, not just ours, and ties the advertisement's lifetime to
            // the listener it describes so there is no second lifecycle to keep in sync.
            newListener.service = VortXEngineAdvertisement.service(
                hostName: displayName,
                controlPort: port,
                capabilities: capabilities)
            let ready = DispatchSemaphore(value: 0)
            let portLock = NSLock()
            var bound: UInt16 = 0
            var failed = false
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    portLock.lock(); bound = newListener.port?.rawValue ?? 0; portLock.unlock()
                    ready.signal()
                case .failed, .cancelled:
                    portLock.lock(); failed = true; portLock.unlock()
                    ready.signal()
                default: break
                }
            }
            newListener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3)
            portLock.lock(); let boundPortValue = bound; let didFail = failed; portLock.unlock()
            guard !didFail, boundPortValue != 0 else {
                newListener.cancel()
                DiagnosticsLog.log("enginehost", "control listener failed to bind on :\(port)")
                return false
            }
            stateLock.lock()
            listener = newListener
            boundPort = boundPortValue
            stateLock.unlock()
            startReaper()
            DiagnosticsLog.log("enginehost", "control listening on 0.0.0.0:\(boundPortValue) name=\(displayName)")
            return true
        } catch {
            DiagnosticsLog.log("enginehost", "control listener start failed: \(error)")
            return false
        }
    }

    /// Stop the listener and tear down every hosted session. Idempotent.
    func stop() {
        stateLock.lock()
        let current = listener
        listener = nil
        boundPort = 0
        let open = Array(sessions.values)
        sessions.removeAll()
        stateLock.unlock()
        reaper?.cancel(); reaper = nil
        current?.cancel()
        open.forEach { $0.server.invalidate() }
        releaseActivityIfIdle()
        DiagnosticsLog.log("enginehost", "control stopped, \(open.count) session(s) torn down")
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener != nil
    }

    var activeSessionCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return sessions.count
    }

    /// What this host advertises it can do.
    ///
    /// `transcode` is conditional on the streaming server actually having found ffmpeg, because advertising a
    /// capability the host cannot deliver is worse than not advertising it: the client would route to us and
    /// then fail, instead of playing on-device.
    var capabilities: [VortXEngineProtocol.Capability] {
        var caps: [VortXEngineProtocol.Capability] = [.remux, .trickplay]
        if retainsFullTimeline { caps.append(.seekAnywhere) }
        if NodeServer.sharedOnLAN { caps.append(.torrentServer) }
        if NodeServer.canTranscode { caps.append(.transcode) }
        return caps
    }

    // MARK: - Pairing (owner side)

    /// Open a pairing window and return the code to show the owner.
    @discardableResult
    func openPairing() -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        let code = pairing.open(now: ProcessInfo.processInfo.systemUptime)
        DiagnosticsLog.log("enginehost", "pairing window opened")
        return code
    }

    func closePairing() {
        stateLock.lock(); defer { stateLock.unlock() }
        pairing.close()
    }

    /// The live code and its remaining seconds, or nil when pairing is closed. For the owner's screen.
    var pairingWindow: (code: String, remaining: TimeInterval)? {
        stateLock.lock(); defer { stateLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard pairing.isOpen(now: now), let code = pairing.code else { return nil }
        return (code, pairing.remainingSeconds(now: now))
    }

    // MARK: - Power

    /// Hold a power assertion for as long as any session is hosted.
    ///
    /// HONEST LIMIT, because this is the kind of thing that gets over-promised: `idleSystemSleepDisabled` stops
    /// the Mac idling to sleep while it is serving. It does NOT stop a laptop sleeping when the lid closes, and
    /// nothing in user space does. A MacBook that gets its lid shut mid-film will drop the session, which is
    /// exactly why the client-side failover exists and why it is not optional.
    private func acquireActivityIfNeeded() {
        stateLock.lock()
        let needed = !sessions.isEmpty && activityToken == nil
        stateLock.unlock()
        guard needed else { return }
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "VortX is producing a remux for another device on this network")
        stateLock.lock(); activityToken = token; stateLock.unlock()
        DiagnosticsLog.log("enginehost", "power assertion acquired")
    }

    private func releaseActivityIfIdle() {
        stateLock.lock()
        let token = sessions.isEmpty ? activityToken : nil
        if token != nil { activityToken = nil }
        stateLock.unlock()
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        DiagnosticsLog.log("enginehost", "power assertion released")
    }

    // MARK: - Reaper

    private func startReaper() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.reapIdleSessions() }
        timer.resume()
        reaper = timer
    }

    private func reapIdleSessions() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let doomed = sessions.values.filter { now - $0.lastContact > Self.sessionIdleTimeout }
        for session in doomed { sessions.removeValue(forKey: session.id) }
        stateLock.unlock()
        for session in doomed {
            DiagnosticsLog.log("enginehost", "session \(session.id) idle-reaped")
            session.server.invalidate()
        }
        releaseActivityIfIdle()
    }

    // MARK: - Connection handling

    /// A control request body is JSON describing one session. Anything larger than this is not that.
    private static let maximumBodyBytes = 64 * 1024
    private static let headerDeadline: TimeInterval = 10

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.headerDeadline, execute: deadline)
        read(connection, buffer: Data(), deadline: deadline)
    }

    private func read(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { deadline.cancel(); connection.cancel(); return }
            var accumulated = buffer
            if let chunk, !chunk.isEmpty { accumulated.append(chunk) }
            guard let split = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || accumulated.count > Self.maximumBodyBytes {
                    deadline.cancel(); connection.cancel()
                    return
                }
                self.read(connection, buffer: accumulated, deadline: deadline)
                return
            }
            let headerData = accumulated.subdata(in: accumulated.startIndex..<split.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8),
                  let request = VortXEngineHTTPRequest(header: headerText) else {
                deadline.cancel()
                self.reply(connection, status: "400 Bad Request",
                           body: VortXEngineProtocol.ErrorBody(error: "malformed", detail: nil))
                return
            }
            let bodySoFar = accumulated.subdata(in: split.upperBound..<accumulated.endIndex)
            guard request.contentLength <= Self.maximumBodyBytes else {
                deadline.cancel()
                self.reply(connection, status: "413 Payload Too Large",
                           body: VortXEngineProtocol.ErrorBody(error: "too_large", detail: nil))
                return
            }
            self.readBody(connection, request: request, body: bodySoFar, deadline: deadline)
        }
    }

    private func readBody(_ connection: NWConnection, request: VortXEngineHTTPRequest,
                          body: Data, deadline: DispatchWorkItem) {
        guard body.count < request.contentLength else {
            deadline.cancel()
            queue.async { self.handle(connection, request: request, body: body) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { deadline.cancel(); connection.cancel(); return }
            var accumulated = body
            if let chunk, !chunk.isEmpty { accumulated.append(chunk) }
            if isComplete, accumulated.count < request.contentLength {
                deadline.cancel(); connection.cancel(); return
            }
            self.readBody(connection, request: request, body: accumulated, deadline: deadline)
        }
    }

    // MARK: - Routing

    private func handle(_ connection: NWConnection, request: VortXEngineHTTPRequest, body: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        let wall = Date().timeIntervalSince1970

        // Unauthenticated routes. Exactly two, and both are here rather than behind the token because a client
        // that has never paired must be able to learn what this host is and then complete a pairing.
        if request.path == VortXEngineProtocol.Path.info, request.method == "GET" {
            stateLock.lock()
            let open = pairing.isOpen(now: now)
            let count = sessions.count
            stateLock.unlock()
            reply(connection, status: "200 OK", body: VortXEngineProtocol.Info(
                name: displayName,
                protocolVersion: VortXEngineProtocol.version,
                engineVersion: Self.engineVersionString,
                platform: "macOS",
                capabilities: capabilities,
                requiresPairing: true,
                pairingOpen: open,
                activeSessions: count,
                maximumSessions: Self.maximumSessions))
            return
        }

        if request.path == VortXEngineProtocol.Path.pair, request.method == "POST" {
            handlePair(connection, body: body, now: now, wall: wall)
            return
        }

        // Everything below requires a token.
        guard let header = request.headers[VortXEngineProtocol.authorizationHeader.lowercased()],
              let token = VortXEngineProtocol.token(fromAuthorization: header),
              pairingRegistry.authorize(token: token, now: wall) != nil else {
            reply(connection, status: "401 Unauthorized",
                  body: VortXEngineProtocol.ErrorBody(error: "unauthorized", detail: "pair this device first"))
            return
        }

        if request.path == VortXEngineProtocol.Path.session, request.method == "POST" {
            handleCreateSession(connection, body: body, now: now)
            return
        }

        // Per-session routes: /engine/v1/session/<id>/<verb>
        let prefix = VortXEngineProtocol.basePath + "/session/"
        if request.path.hasPrefix(prefix) {
            let rest = String(request.path.dropFirst(prefix.count))
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let id = parts.first else {
                reply(connection, status: "404 Not Found",
                      body: VortXEngineProtocol.ErrorBody(error: "not_found", detail: nil))
                return
            }
            let verb = parts.count > 1 ? parts[1] : ""
            switch (request.method, verb) {
            case ("GET", "status"):  handleStatus(connection, id: id, now: now, markReady: false)
            case ("POST", "ready"):  handleStatus(connection, id: id, now: now, markReady: true)
            case ("DELETE", ""):     handleTeardown(connection, id: id)
            default:
                reply(connection, status: "405 Method Not Allowed",
                      body: VortXEngineProtocol.ErrorBody(error: "method", detail: nil))
            }
            return
        }

        reply(connection, status: "404 Not Found",
              body: VortXEngineProtocol.ErrorBody(error: "not_found", detail: nil))
    }

    private func handlePair(_ connection: NWConnection, body: Data, now: TimeInterval, wall: Double) {
        guard let request = try? JSONDecoder().decode(VortXEngineProtocol.PairRequest.self, from: body) else {
            reply(connection, status: "400 Bad Request",
                  body: VortXEngineProtocol.ErrorBody(error: "malformed", detail: nil))
            return
        }
        stateLock.lock()
        let outcome = pairing.submit(code: request.code, now: now)
        stateLock.unlock()
        switch outcome {
        case .paired:
            guard let token = pairingRegistry.register(
                clientID: request.clientID, clientName: request.clientName, now: wall) else {
                reply(connection, status: "507 Insufficient Storage",
                      body: VortXEngineProtocol.ErrorBody(error: "device_limit", detail: nil))
                return
            }
            DiagnosticsLog.log("enginehost", "paired device \(request.clientName)")
            reply(connection, status: "200 OK", body: VortXEngineProtocol.PairResponse(
                token: token, hostName: displayName, capabilities: capabilities))
        case .wrongCode, .closed:
            // ONE answer for both. Distinguishing "wrong code" from "no window open" would tell a prober
            // whether the owner currently has the pairing screen up, which is exactly the signal it should not
            // get. The owner's own screen shows the attempt count; the wire does not.
            DiagnosticsLog.log("enginehost", "pairing attempt rejected")
            reply(connection, status: "403 Forbidden",
                  body: VortXEngineProtocol.ErrorBody(error: "pairing_rejected", detail: nil))
        }
    }

    private func handleCreateSession(_ connection: NWConnection, body: Data, now: TimeInterval) {
        guard let request = try? JSONDecoder().decode(VortXEngineProtocol.SessionRequest.self, from: body),
              let input = URL(string: request.input) else {
            reply(connection, status: "400 Bad Request",
                  body: VortXEngineProtocol.ErrorBody(error: "malformed", detail: nil))
            return
        }
        stateLock.lock()
        let atCapacity = sessions.count >= Self.maximumSessions
        stateLock.unlock()
        guard !atCapacity else {
            reply(connection, status: "503 Service Unavailable",
                  body: VortXEngineProtocol.ErrorBody(
                    error: "at_capacity",
                    detail: "this Mac is already hosting \(Self.maximumSessions) sessions"))
            return
        }

        let capability = VortXEngineHostPolicy.makeCapability()
        let wantsRetention = request.requestFullTimeline && retainsFullTimeline
        guard let hosting = VortXRemuxHLSServer.HostingConfig(
            capability: capability, retainFullTimeline: wantsRetention) else {
            reply(connection, status: "500 Internal Server Error",
                  body: VortXEngineProtocol.ErrorBody(error: "capability", detail: nil))
            return
        }
        guard let mounted = VortXRemuxHLSServer.make(
            input: input,
            headers: request.headers,
            mode: request.mode == .plain ? .plain : .dolbyVision,
            startAtSeconds: max(0, request.startAtSeconds),
            hosting: hosting) else {
            reply(connection, status: "500 Internal Server Error",
                  body: VortXEngineProtocol.ErrorBody(error: "mount_failed",
                                                      detail: "could not build the remux"))
            return
        }
        // What was actually GRANTED, not what was asked for. A host short of disk still serves; it just serves
        // a sliding window, and the client must keep clamping backward seeks in that case.
        let granted = mounted.server.retainsFullTimeline
        let id = UUID().uuidString.lowercased()
        let session = HostedSession(id: id, capability: capability, server: mounted.server,
                                    retainsFullTimeline: granted, now: now)
        stateLock.lock(); sessions[id] = session; stateLock.unlock()
        acquireActivityIfNeeded()
        mounted.server.start()
        DiagnosticsLog.log(
            "enginehost",
            "session \(id) hosting \(request.mode.rawValue) on media port \(mounted.server.port) retain=\(granted)\(wantsRetention && !granted ? " (requested but disk declined)" : "")")
        reply(connection, status: "200 OK", body: VortXEngineProtocol.SessionResponse(
            sessionID: id,
            mediaPort: Int(mounted.server.port),
            mediaPath: mounted.server.mountResourcePath,
            retainsFullTimeline: granted))
    }

    private func handleStatus(_ connection: NWConnection, id: String, now: TimeInterval, markReady: Bool) {
        stateLock.lock()
        let session = sessions[id]
        session?.lastContact = now
        if markReady, let session, !session.readyMarked { session.readyMarked = true }
        stateLock.unlock()
        guard let session else {
            reply(connection, status: "404 Not Found",
                  body: VortXEngineProtocol.ErrorBody(error: "no_session", detail: nil))
            return
        }
        if markReady { _ = session.server.markEngineReady() }
        let progress = session.server.mountProgress
        let signalling = session.server.signaling
        reply(connection, status: "200 OK", body: VortXEngineProtocol.SessionStatus(
            healthy: session.server.isMountHealthy,
            durationSeconds: session.server.sourceDurationSeconds,
            timelineOriginSeconds: session.server.timelineOriginSeconds,
            frameRate: session.server.authoritativeFrameRate,
            chapters: session.server.chapters.map {
                VortXEngineProtocol.Chapter(start: $0.start, title: $0.title)
            },
            producedSegments: progress.segmentCount,
            producedBytes: progress.producedBytes,
            ended: progress.ended,
            signalingPublished: progress.signalingPublished,
            dolbyVision: signalling?.dolbyVision ?? false,
            width: signalling?.width ?? 0,
            height: signalling?.height ?? 0,
            bandwidth: signalling?.bandwidth,
            videoRange: signalling?.videoRange,
            supportsHDRFallback: session.server.supportsHDRFallback,
            producedEdgeSeconds: session.server.producedEdgeSeconds))
    }

    private func handleTeardown(_ connection: NWConnection, id: String) {
        stateLock.lock()
        let session = sessions.removeValue(forKey: id)
        stateLock.unlock()
        session?.server.invalidate()
        if session != nil { DiagnosticsLog.log("enginehost", "session \(id) torn down by client") }
        releaseActivityIfIdle()
        reply(connection, status: "200 OK", body: VortXEngineProtocol.ErrorBody(error: "ok", detail: nil))
    }

    // MARK: - Replies

    private func reply<Body: Encodable>(_ connection: NWConnection, status: String, body: Body) {
        let encoded = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(encoded.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(encoded)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static var engineVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// Minimal HTTP request head. Deliberately not a general-purpose HTTP implementation: it parses exactly the
/// shapes this protocol defines and rejects everything else, which is a smaller attack surface than a
/// permissive parser and a smaller maintenance surface than a dependency.
struct VortXEngineHTTPRequest {
    let method: String
    let path: String
    /// Header names are lowercased so lookup is case-insensitive, as HTTP requires.
    let headers: [String: String]
    let contentLength: Int

    init?(header text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        method = parts[0].uppercased()
        path = parts[1].components(separatedBy: "?").first ?? parts[1]
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            parsed[name] = value
        }
        headers = parsed
        contentLength = Int(parsed["content-length"] ?? "0") ?? 0
    }
}

/// Keychain-backed token store. On macOS `Keychain` is a file-backed store at
/// `~/Library/Application Support/StremioX/credentials.plist` with owner-only permissions, chosen because
/// ad-hoc signing makes every `SecItem` access pop a password prompt. Host tokens live there alongside the
/// account token, which also means `SettingsBackup` already excludes them.
final class VortXEngineKeychainTokenStore: VortXEngineTokenStore {
    private static let prefix = "vortx.engineHost.token."

    func token(forClientID clientID: String) -> String? {
        Keychain.string(Self.prefix + clientID)
    }

    func setToken(_ token: String?, forClientID clientID: String) {
        Keychain.set(token, for: Self.prefix + clientID)
    }
}
#endif
