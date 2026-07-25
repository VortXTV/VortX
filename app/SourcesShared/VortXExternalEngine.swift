import Foundation

/// THE CLIENT SIDE of external engine mode: what an Apple TV, iPhone, iPad or Mac uses to talk to an engine
/// host and to decide, per playback, whether to use one at all.
///
/// DEFAULT OFF, AND THAT IS THE MOST IMPORTANT PROPERTY IN THIS FILE. The overwhelming majority of users have
/// no Mac on their network, and the Dolby Vision lane they DO use took two field regressions to stabilise. So
/// `mountPlan` returns `.onDevice` unless the user explicitly turned this on, the fleet kill switch is still
/// on, and a host is actually configured. With any of those missing, nothing in this file runs and the player
/// behaves exactly as it shipped. There is deliberately no auto-adoption: a discovered host is OFFERED, never
/// silently used, because rerouting someone's playback to another machine without asking is not acceptable
/// behaviour no matter how good the reason.
///
/// PLATFORM-AGNOSTIC. This is the reference implementation of the client half of `VortXEngineProtocol`, and it
/// is written to be portable: plain URLSession, plain JSON, no AVFoundation. The Android and desktop clients
/// implement the same six calls against the same shapes.
final class VortXExternalEngine: @unchecked Sendable {

    static let shared = VortXExternalEngine()

    // MARK: - Persisted settings

    enum Defaults {
        /// The user's explicit opt-in. Absent means OFF; there is no remote default that can turn this on for
        /// somebody, which is deliberate. A fleet flag may only ever take the feature AWAY.
        static let enabledKey = "vortx.externalEngine.enabled"
        /// The engine host, as the user typed it or as adoption of a discovered host wrote it.
        static let hostKey = "vortx.externalEngine.host"
        /// Stable per-install id, so re-pairing replaces this device's token instead of accumulating one per
        /// attempt on the host's list.
        static let clientIDKey = "vortx.externalEngine.clientID"
        /// Cached host display name, purely so settings can show which Mac is paired while it is asleep.
        static let hostNameKey = "vortx.externalEngine.hostName"
        /// Cached capability list from the last successful `/info`.
        static let capabilitiesKey = "vortx.externalEngine.capabilities"
        /// What this device calls itself on the host's list.
        static let clientNameKey = "vortx.externalEngine.clientName"
    }

    /// Keychain account for the bearer token. Never UserDefaults, never a settings backup: it is a credential
    /// that authorises another machine to fetch URLs on this user's behalf.
    private static let tokenAccount = "vortx.externalEngine.token"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Defaults.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.enabledKey) }
    }

    var host: String? {
        get { UserDefaults.standard.string(forKey: Defaults.hostKey) }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.hostKey) }
    }

    private(set) var hostName: String? {
        get { UserDefaults.standard.string(forKey: Defaults.hostNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.hostNameKey) }
    }

    private(set) var capabilities: [VortXEngineProtocol.Capability] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Defaults.capabilitiesKey) ?? []
            return raw.compactMap(VortXEngineProtocol.Capability.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Defaults.capabilitiesKey)
        }
    }

    var token: String? { Keychain.string(Self.tokenAccount) }
    var isPaired: Bool { !(token ?? "").isEmpty }

    /// Stable identity for this install. Minted once and kept, so the host's paired-device list has one row per
    /// device rather than one per pairing attempt.
    var clientID: String {
        if let stored = UserDefaults.standard.string(forKey: Defaults.clientIDKey), !stored.isEmpty {
            return stored
        }
        let minted = UUID().uuidString.lowercased()
        UserDefaults.standard.set(minted, forKey: Defaults.clientIDKey)
        return minted
    }

    /// What this device calls itself on the host's paired-device list, so the owner can revoke the right one.
    ///
    /// Deliberately NOT `UIDevice.current.name`: that accessor is main-actor isolated on current SDKs and this
    /// property is read from whatever queue is opening a session, so reaching for it would trade a correct name
    /// for an isolation crash. A platform word is enough to tell an Apple TV from an iPhone, and the owner can
    /// set something better.
    var clientName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Defaults.clientNameKey)
            if let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty { return stored }
            #if os(tvOS)
            return "Apple TV"
            #elseif os(macOS)
            return Host.current().localizedName ?? "Mac"
            #elseif os(iOS)
            return "iPhone or iPad"
            #else
            return "VortX client"
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.clientNameKey) }
    }

    // MARK: - The gate

    /// The fleet kill switch. Baked ON so that removing the backend changes nothing; the USER default is off, so
    /// "on" here only means "not disabled", never "enabled for everyone".
    ///
    /// This is a standing requirement rather than a nicety: the whole feature must be revocable fleet-wide
    /// without shipping a build, because it is new code on the periphery of a lane that has already regressed
    /// in the field twice.
    static var killSwitchOn: Bool {
        RemoteConfig.snapshot.isFeatureOn("externalEngine", default: true)
    }

    /// THE decision, for one playback. Everything else in this file is unreachable when this says `.onDevice`.
    var mountPlan: VortXEngineHostPolicy.MountPlan {
        guard isPaired else { return .onDevice }
        return VortXEngineHostPolicy.mountPlan(
            userEnabled: isEnabled, killSwitchOn: Self.killSwitchOn, host: host)
    }

    /// Whether a hosted session should be asked to retain its whole timeline, which is what unlocks seeking
    /// backwards anywhere. Asked for whenever the host said it can; the host answers with what it granted.
    var wantsFullTimeline: Bool { capabilities.contains(.seekAnywhere) }

    // MARK: - Transport

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        // No cookies, no cache, no credential storage: this is a LAN control channel, not a browser.
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Build a control URL against an explicit host. Takes the host as an argument rather than reading the
    /// stored one, so pairing (which happens BEFORE a host is committed to settings) uses the same code path.
    private func controlURL(host: String, port: Int, path: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        comps.path = path
        return comps.url
    }

    private func request(_ url: URL, method: String, body: Data?, authorized: Bool) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token {
            req.setValue(VortXEngineProtocol.bearer(token),
                         forHTTPHeaderField: VortXEngineProtocol.authorizationHeader)
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async -> T? {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Calls

    /// Ask a host what it is. The one unauthenticated call, so it works before pairing.
    func info(host rawHost: String) async -> VortXEngineProtocol.Info? {
        guard let resolved = VortXEngineHostPolicy.normalizeHost(rawHost),
              let url = controlURL(host: resolved.host, port: resolved.port,
                                   path: VortXEngineProtocol.Path.info) else { return nil }
        let info = await send(request(url, method: "GET", body: nil, authorized: false),
                              as: VortXEngineProtocol.Info.self)
        // Refuse a host whose protocol we do not know rather than guessing at a shape. Forward compatibility is
        // the host's job (it may add fields); a MAJOR version we have never seen is not something to improvise
        // against.
        guard let info, info.protocolVersion == VortXEngineProtocol.version else { return nil }
        return info
    }

    /// Exchange a code the owner read off the host's screen for a bearer token, and commit the host on success.
    ///
    /// Commits ONLY on success, so a failed attempt never leaves settings pointing at a host this device cannot
    /// actually use.
    @discardableResult
    func pair(host rawHost: String, code: String) async -> VortXEngineProtocol.PairResponse? {
        guard let resolved = VortXEngineHostPolicy.normalizeHost(rawHost),
              let url = controlURL(host: resolved.host, port: resolved.port,
                                   path: VortXEngineProtocol.Path.pair) else { return nil }
        let body = try? JSONEncoder().encode(VortXEngineProtocol.PairRequest(
            code: code, clientName: clientName, clientID: clientID))
        guard let body,
              let paired = await send(request(url, method: "POST", body: body, authorized: false),
                                      as: VortXEngineProtocol.PairResponse.self) else { return nil }
        Keychain.set(paired.token, for: Self.tokenAccount)
        host = VortXEngineHostPolicy.normalizeHost(rawHost).map { "\($0.host):\($0.port)" } ?? rawHost
        hostName = paired.hostName
        capabilities = paired.capabilities
        DiagnosticsLog.log("engine", "paired with host \(paired.hostName) caps=\(paired.capabilities.map(\.rawValue).joined(separator: ","))")
        return paired
    }

    /// Forget the host. Local only: it does not tell the host, because a device that is being unpaired may well
    /// be unable to reach it. The owner revokes on the host side to invalidate the token there.
    func unpair() {
        Keychain.set(nil, for: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Defaults.hostKey)
        UserDefaults.standard.removeObject(forKey: Defaults.hostNameKey)
        UserDefaults.standard.removeObject(forKey: Defaults.capabilitiesKey)
        isEnabled = false
        DiagnosticsLog.log("engine", "unpaired from host")
    }

    /// Refresh the cached capability list. Cheap, and worth doing when settings opens so the UI is honest about
    /// what the host can currently do (transcoding, for instance, depends on the host finding ffmpeg).
    func refreshCapabilities() async {
        guard let host, let info = await info(host: host) else { return }
        capabilities = info.capabilities
        hostName = info.name
    }

    // MARK: - Sessions

    struct OpenedSession: Sendable {
        let sessionID: String
        /// The full media URL, composed against the host address this client dialled. The host never returns a
        /// URL because it does not know which of its addresses we can reach.
        let playlistURL: URL
        let retainsFullTimeline: Bool
        let host: String
        let port: Int
    }

    /// Ask the host to build a remux and return where to fetch it. Returns nil for every failure, which the
    /// caller turns into an on-device mount rather than an error the user sees.
    func openSession(input: URL,
                     headers: [String: String]?,
                     mode: VortXEngineProtocol.RemuxMode,
                     startAtSeconds: Double) async -> OpenedSession? {
        guard case .external(let hostString, let port) = mountPlan,
              let url = controlURL(host: hostString, port: port,
                                   path: VortXEngineProtocol.Path.session) else { return nil }
        let payload = VortXEngineProtocol.SessionRequest(
            input: input.absoluteString,
            headers: headers,
            mode: mode,
            startAtSeconds: startAtSeconds,
            requestFullTimeline: wantsFullTimeline)
        guard let body = try? JSONEncoder().encode(payload),
              let opened = await send(request(url, method: "POST", body: body, authorized: true),
                                      as: VortXEngineProtocol.SessionResponse.self) else {
            DiagnosticsLog.log("engine", "host session request failed; falling back to on-device")
            return nil
        }
        var media = URLComponents()
        media.scheme = "http"
        media.host = hostString
        media.port = opened.mediaPort
        media.path = opened.mediaPath
        guard let playlistURL = media.url else { return nil }
        DiagnosticsLog.log(
            "engine",
            "host session \(opened.sessionID) media=\(hostString):\(opened.mediaPort) retain=\(opened.retainsFullTimeline)")
        return OpenedSession(sessionID: opened.sessionID,
                             playlistURL: playlistURL,
                             retainsFullTimeline: opened.retainsFullTimeline,
                             host: hostString,
                             port: port)
    }

    func status(_ session: OpenedSession) async -> VortXEngineProtocol.SessionStatus? {
        guard let url = controlURL(host: session.host, port: session.port,
                                   path: VortXEngineProtocol.Path.status(session.sessionID)) else { return nil }
        return await send(request(url, method: "GET", body: nil, authorized: true),
                          as: VortXEngineProtocol.SessionStatus.self)
    }

    /// Tell the host our player reached first frame, which widens the producer's lead exactly as the on-device
    /// lane's `markEngineReady` does.
    @discardableResult
    func markReady(_ session: OpenedSession) async -> VortXEngineProtocol.SessionStatus? {
        guard let url = controlURL(host: session.host, port: session.port,
                                   path: VortXEngineProtocol.Path.ready(session.sessionID)) else { return nil }
        return await send(request(url, method: "POST", body: Data("{}".utf8), authorized: true),
                          as: VortXEngineProtocol.SessionStatus.self)
    }

    /// Best-effort teardown. Fire and forget: the host reaps an abandoned session on its own timer, so a client
    /// that dies or loses the network costs it a minute of producer time, not a leak.
    func close(_ session: OpenedSession) {
        guard let url = controlURL(host: session.host, port: session.port,
                                   path: VortXEngineProtocol.Path.teardown(session.sessionID)) else { return }
        let req = request(url, method: "DELETE", body: nil, authorized: true)
        session_teardown(req)
    }

    private func session_teardown(_ req: URLRequest) {
        session.dataTask(with: req).resume()
    }
}
