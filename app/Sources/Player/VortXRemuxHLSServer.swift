#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import Network

/// Serves the DV-for-MKV streaming remux (`VortXMKVRemuxStream`) to AVPlayer as LOCAL HLS from 127.0.0.1
/// (b166). AVFoundation does not support a growing fragmented MP4 as a plain progressive asset: on the old
/// `vortxremux://` delivery every DV play on device either failed "Cannot Open" or scanned hundreds of MB
/// without ever producing a frame. HLS is the one delivery AVFoundation documents for a live fMP4 stream,
/// and the one Apple's authoring spec defines for Dolby Vision 8.1 (CODECS + SUPPLEMENTAL-CODECS +
/// VIDEO-RANGE), so this server presents the remux as:
///   - `/master.m3u8`: exactly one DV EXT-X-STREAM-INF (CODECS + SUPPLEMENTAL-CODECS + VIDEO-RANGE ->
///     media.m3u8). A DV and stripped-HDR representation must never share one adaptive set: AVPlayer switched
///     between them and rejected `/init-hdr.mp4` with CoreMedia -12927 on an otherwise healthy mount.
///   - `/master-hdr.m3u8`: a separate, one-variant recovery master for a base-layer-compatible DV source. A
///     fresh AVPlayerItem mounts it only after the DV item fails. Profile 5 has no HDR base layer and this route
///     fails closed for it.
///   - `/media.m3u8`: a sliding playlist of closed, durably staged segments, with an
///     absolute MEDIA-SEQUENCE and EXT-X-ENDLIST once the trailer is written. The first answer is held until
///     a small startup window exists, and those startup bytes remain pinned until AVPlayer is ready.
///   - `/media-hdr.m3u8`: the lifeboat's view of that same immutable durable window.
///   - `/init.mp4`:    the ftyp+moov init segment (retained in memory for the whole session).
///   - `/init-hdr.mp4`: the lifeboat's init: same moov with the DV config box stripped (#143).
///   - `/seg{N}.m4s`:  one closed segment (shared by both variants), read from the private session spool.
///
/// Follows the proven `VXTrailerProxy` NWListener pattern: bound to 127.0.0.1 on an OS-assigned ephemeral
/// port (never reachable off-device), per-connection fail-soft (a bad request / evicted range / gone client
/// closes that one connection). One instance backs one playback session.
///
/// FAIL-SOFT GUARANTEE: a listener that will not start makes the factory return nil (the engine then emits
/// endFileError and the chrome demotes to libmpv HDR10); a remux failure 404s the next playlist reload so
/// AVPlayer errors into the same demotion while the engine retains the exact producer reason; an
/// evicted-segment request 404s the same way; and the chrome's start watchdog covers a mount that never frames.
/// Nothing here can hang playback.
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

    /// Fleet escape hatch for the WINDOW-ADVANCEMENT policy (standing requirement after build 190). ON, the
    /// default: the published media window slides only behind the client's demonstrated consumption frontier
    /// (the Beta 6 field-proven contract, ported onto the Beta 7 structure), with the pre-ready tail growing
    /// so CoreMedia's readiness negotiation is never starved. OFF: the build 190 behavior (frozen pre-ready
    /// startup window + production-driven minimum-suffix slide), kept remotely flippable so any unforeseen
    /// field regression in the new windowing can be reverted without shipping a build. An explicit
    /// UserDefaults value wins for local testing; else the RemoteConfig feature decides. Captured once per
    /// server so a mid-play fleet flip cannot mix the two policies inside one session.
    static let consumptionAnchorKey = "stremiox.dvWindowConsumptionAnchor"
    static var consumptionAnchorEnabled: Bool {
        if UserDefaults.standard.object(forKey: consumptionAnchorKey) != nil {
            return UserDefaults.standard.bool(forKey: consumptionAnchorKey)
        }
        return RemoteConfig.snapshot.isFeatureOn("dvWindowConsumptionAnchor", default: true)
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
    private var listenerRetired = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// One cross-rendition publication coordinator. It freezes the exact common startup cohort before the
    /// master advertises any rendition, then advances the DV and recovery video resources plus every advertised
    /// audio/subtitle route through one shared absolute-ID frontier. Disk work and playlist receipts happen while this lock is
    /// held, so no concurrent request can expose half of a generation.
    private let publicationLock = NSLock()
    private var startupMediaList: (window: VortXHLSWindow, ended: Bool)?
    private var publishedVideoWindow: VortXHLSWindow?
    private var advertisedAudioPlan: MultiAudioPolicy.RenditionPlan?
    private var advertisedPrimaryAudioTag: String?
    /// Last aligned alternate-audio window + init actually published, retained so an ADVERTISED alternate
    /// that later fails can freeze at this terminal window (ENDLIST) instead of killing the whole session.
    private var lastPublishedAudioWindow: VortXHLSWindow?
    private var advertisedAudioInitData: Data?
    /// The client's demonstrated CONSUMPTION frontier: the highest video segment id it has requested.
    /// -1 until the first fetch, which keeps the startup window pinned at its first sequence. Guarded by
    /// `publicationLock`.
    private var highestServedVideoSegmentID = -1
    /// Session-captured window-advancement policy (see `consumptionAnchorEnabled`).
    private let consumptionAnchored = VortXRemuxHLSServer.consumptionAnchorEnabled
    private var advertisedSubtitles: [SubtitleRenditionPolicy.Rendition] = []
    private var advertisedDolbyVision = false
    private var engineReady = false
    private var startupTimeoutLogged = false
    private let displayRequestLock = NSLock()
    private var primaryDisplayDispatched = false
    private var recoveryDisplayDispatched = false
    private let startupReadiness: VortXHLSStartupReadiness
    private let onStartupTimeout: @Sendable (VortXRemuxHLSServer) -> Void
    private let deadlineLock = NSLock()
    private var mountDeadline = VortXHLSMountDeadlineState()
    private var mountDeadlineWorkItem: DispatchWorkItem?

    /// The remux producer's first terminal reason. The AVPlayer error surface reads this instead of reducing a
    /// typed source or storage failure to CoreMedia's generic "URL not found" string.
    var terminalFailureReason: String? {
        stream.buffer.status().failure
    }

    /// True only after the remux producer has closed the source and published its terminal index state.
    /// AVPlayer can emit an item-end notification at the current tail of a still-growing playlist, so callers
    /// must use this receipt before translating that notification into content EOF.
    var hasReachedEndOfStream: Bool {
        stream.hlsSnapshot().ended
    }

    private struct Publication {
        let videoWindow: VortXHLSWindow
        let audioWindow: VortXHLSWindow?
        let subtitleWindow: VortXHLSWindow?
        let audioPlan: MultiAudioPolicy.RenditionPlan?
        let subtitles: [SubtitleRenditionPolicy.Rendition]
        let ended: Bool
        /// The advertised alternate failed after publication; its route serves the frozen terminal window.
        let audioTerminated: Bool
    }

    private struct MasterPublication {
        let audioPlan: MultiAudioPolicy.RenditionPlan?
        /// URI-less in-band primary label, used ONLY when `audioPlan` is nil (see HLSWindowSnapshot).
        let primaryAudioTag: String?
        let subtitles: [SubtitleRenditionPolicy.Rendition]
    }

    private enum PrimaryMasterPrelude {
        case displayIntent(VortXMKVRemuxStream.HLSDisplayIntent)
        case signaling(VortXMKVRemuxStream.HLSSignaling)
    }

    // MARK: - Hosting (external engine mode)

    /// Turns this session from a private loopback mount into one HOSTED for another device on the network.
    ///
    /// Presence of this config is the ONE switch that changes the server's posture, deliberately: the bind
    /// host, the strict HTTP layer and the session path prefix are all derived from it rather than from
    /// independent flags, so "listening on 0.0.0.0 with no credential" is unrepresentable rather than merely
    /// discouraged. `nil` (the default, and what every on-device caller passes) leaves the server byte-identical
    /// to what shipped: loopback bind, method-blind parse, no path prefix, no Range handling.
    struct HostingConfig: Equatable {
        /// 128 bits of CSPRNG material, minted per session by `VortXEngineHostPolicy.makeCapability()`. Every
        /// resource of this session hangs under `/r/<capability>/`, which authenticates every child fetch for
        /// free because every playlist URI the server emits is relative.
        let capability: String

        /// Ask the session to retain its ENTIRE produced timeline rather than sliding a window, which is what
        /// lets the client seek backwards anywhere into what has been produced. Only a host has the disk for
        /// this. The request may be DOWNGRADED at construction when the machine cannot support it, so read
        /// `VortXRemuxHLSServer.retainsFullTimeline` for what was actually granted.
        let retainFullTimeline: Bool

        init?(capability: String, retainFullTimeline: Bool = false) {
            guard VortXEngineHostPolicy.isWellFormedCapability(capability) else { return nil }
            self.capability = capability
            self.retainFullTimeline = retainFullTimeline
        }
    }

    /// Whether this session ACTUALLY retains its whole timeline. False for every on-device mount, and false for
    /// a hosted mount on a machine that turned out not to have the disk.
    var retainsFullTimeline: Bool { stream.retainsFullTimeline }

    private let hosting: HostingConfig?

    /// True when this session is serving another device rather than this process's own AVPlayer.
    var isHosted: Bool { hosting != nil }

    /// The absolute path the master playlist answers on. `/master.m3u8` for a loopback session (unchanged);
    /// `/r/<capability>/master.m3u8` for a hosted one. The engine host hands this plus `port` to the client,
    /// which builds the URL against the address it already dialled, so the server never has to guess which of
    /// its own interfaces the client can reach (this is what makes Tailscale and mDNS work for free).
    var mountResourcePath: String {
        guard let hosting else { return "/master.m3u8" }
        return VortXEngineHostPolicy.mountPath(capability: hosting.capability, resource: "master.m3u8")
    }

    /// Build the remux stream + local server for an MKV URL. Returns nil when the listener cannot bind
    /// (the caller fails soft to libmpv). The caller must `start()` the returned server to begin remuxing.
    /// `mode` (#147): `.dolbyVision` (the default, the original lane) or `.plain` for a non-DV MKV kept on
    /// AVPlayer for Picture in Picture; the mode flows into classify + signaling (see VortXMKVRemuxStream.Mode).
    /// `startAtSeconds` is a sanitized source-timeline origin consumed by AVPlayer before this mount exists.
    /// The stream seeks once before muxing, then publishes the base-video timestamp it actually reached.
    /// `hosting` is nil for every on-device mount and non-nil only for a session an engine host is serving to
    /// another device; see `HostingConfig`.
    static func make(input: URL, headers: [String: String]?,
                     mode: VortXMKVRemuxStream.Mode = .dolbyVision,
                     startAtSeconds: Double = 0,
                     selectedAudioStreamIndex: Int? = nil,
                     hosting: HostingConfig? = nil,
                     onStartupTimeout: @escaping @Sendable (VortXRemuxHLSServer) -> Void = { _ in })
        -> (server: VortXRemuxHLSServer, playlistURL: URL)? {
        let stream = VortXMKVRemuxStream(
            input: input.absoluteString,
            headers: headers,
            indexForHLS: true,
            mode: mode,
            startAtSeconds: startAtSeconds,
            retainFullTimeline: hosting?.retainFullTimeline ?? false,
            selectedAudioStreamIndex: selectedAudioStreamIndex)
        guard let server = VortXRemuxHLSServer(
            stream: stream,
            hosting: hosting,
            onStartupTimeout: onStartupTimeout) else {
            stream.cancel()
            stream.listenerDidRetire()
            return nil
        }
        guard server.listen() else { server.invalidate(); return nil }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(server.port)
        comps.path = server.mountResourcePath
        guard let url = comps.url else { server.invalidate(); return nil }
        return (server, url)
    }

    private init?(stream: VortXMKVRemuxStream,
                  hosting: HostingConfig?,
                  onStartupTimeout: @escaping @Sendable (VortXRemuxHLSServer) -> Void) {
        guard let startupReadiness = VortXHLSStartupReadiness(
            frozenTarget: stream.frozenHLSTarget) else { return nil }
        self.stream = stream
        self.hosting = hosting
        self.startupReadiness = startupReadiness
        self.onStartupTimeout = onStartupTimeout
    }

    /// Begin remuxing. Call once, after the asset is (about to be) mounted.
    func start() {
        let now = ProcessInfo.processInfo.systemUptime
        deadlineLock.lock()
        guard let deadline = mountDeadline.start(now: now) else {
            deadlineLock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.expireMountIfNeeded() }
        mountDeadlineWorkItem = work
        deadlineLock.unlock()
        queue.asyncAfter(deadline: .now() + max(0, deadline - now), execute: work)
        stream.start()
    }

    /// F3: forward the engine's first-frame readiness to the buffer so its producer lead widens from the
    /// reduced pre-ready value to the full lead. Called from AVPlayerEngine's readyToPlay handler.
    @discardableResult
    func markEngineReady() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        deadlineLock.lock()
        let transition = mountDeadline.markReady(now: now)
        let work = transition.accepted ? mountDeadlineWorkItem : nil
        if transition.accepted { mountDeadlineWorkItem = nil }
        deadlineLock.unlock()
        if transition.didExpire { handleMountTimeout() }
        guard transition.accepted else { return false }
        work?.cancel()
        publicationLock.lock(); engineReady = true; publicationLock.unlock()
        stream.markEngineReady()
        DiagnosticsLog.log(
            "dv",
            "startup phase=ready-to-play elapsedMs=\(stream.startupElapsedMilliseconds)")
        return true
    }

    /// True only after this mount accepted its one ready transition. Recovery items use this to distinguish an
    /// already-ready mount from a mount whose deadline expired before either item became playable.
    var hasMarkedEngineReady: Bool {
        publicationLock.lock(); defer { publicationLock.unlock() }
        return engineReady
    }

    /// The source MKV runtime in seconds (0 until parsed / when unknown). The engine reads it at readyToPlay
    /// to synthesize a finite VOD duration, since the live HLS delivery keeps AVPlayerItem.duration INDEFINITE.
    var sourceDurationSeconds: Double { stream.sourceDurationSeconds }

    /// The achieved source-timeline second represented by player clock zero. It is established only by a
    /// mapped base-video packet after a successful input seek, never by earlier audio/subtitle packets.
    var timelineOriginSeconds: Double { stream.timelineOriginSeconds }

    /// The classifier's session-authoritative frame rate. AVPlayer's asset track can be absent for local HLS;
    /// callers must prefer this value and must not replace it with an invented 60Hz fallback.
    var authoritativeFrameRate: Double { stream.hlsSnapshot().signaling?.fps ?? 0 }

    /// The source MKV chapter markers (start seconds + title). The engine reads these for the Chapters panel /
    /// scrubber ticks on the DV remux lane, since the local HLS delivery carries no chapter metadata (Gap 3).
    var chapters: [(start: Double, title: String)] { stream.chapters }

    /// Stable source-container identities available to the remount-based audio picker.
    var sourceAudioTracks: [VortXEngineProtocol.AudioTrack] { stream.sourceAudioTracks }

    /// The source identity actually mapped into the primary output after validation and fallback.
    var selectedSourceAudioIndex: Int? { stream.selectedSourceAudioIndex }

    /// Stable source subtitle identities, including honest unavailable bitmap rows.
    var sourceSubtitleTracks: [VortXEngineProtocol.SubtitleTrack] { stream.sourceSubtitleTracks }

    /// Whether the mount is still HEALTHY: the init segment has published AND the remux buffer has not failed.
    /// The engine's one-shot healthy-mount retry (#76) reads this to tell "a CoreMedia startup hiccup on a live
    /// mount" (retry a fresh item) from "the remux itself died" (demote). Same two signals serveMedia gates on.
    var isMountHealthy: Bool {
        stream.hlsSnapshot().initData != nil && stream.buffer.status().failure == nil
    }

    /// Profile 5 carries IPT-only Dolby Vision and has no honest HDR base layer. Profile 8 and converted
    /// Profile 7 are eligible only after the stream has explicitly produced a validated stripped-DV init.
    var supportsHDRFallback: Bool {
        let snapshot = stream.hlsSnapshot()
        guard let signaling = snapshot.signaling else { return false }
        return DVPlaybackPolicy.supportsHDRFallback(
            dolbyVision: signaling.dolbyVision,
            videoCodec: signaling.videoCodec,
            surgerySettled: snapshot.hdrRecoveryInitSettled,
            recoveryInitAvailable: snapshot.initDataHDR != nil)
    }

    /// The classifier's published signalling, or nil before classify finishes.
    ///
    /// Exposed for one reason: a HOSTED session's client has to fire its own Dolby Vision panel switch. The
    /// switch inside `serveMaster` is `#if os(tvOS)` and a host is a Mac, so it is compiled out there and a
    /// hosted session would otherwise present true DV to a panel nobody switched.
    var signaling: VortXMKVRemuxStream.HLSSignaling? { stream.hlsSnapshot().signaling }

    /// Monotonic mount-progress counters for the chrome's progress-aware start watchdog. Thread-safe passthrough.
    var mountProgress: VortXMKVRemuxStream.MountProgress { stream.mountProgress() }

    /// Monotonic mount-to-now duration used for ready and first-frame timing receipts.
    var startupElapsedMilliseconds: Int { stream.startupElapsedMilliseconds }

    /// The furthest SOURCE second a closed segment has been published for.
    ///
    /// On-device this is inferable from AVPlayer's own seekable ranges, so nothing reads it. A remote client
    /// cannot infer it (its AVPlayer only knows what the playlist currently advertises, and on a retaining
    /// session that is the whole timeline regardless of production), so a host reports it explicitly and the
    /// client clamps forward seeks against it exactly as the on-device lane does.
    var producedEdgeSeconds: Double {
        guard let last = stream.hlsWindowSnapshot().window.segments.last else { return 0 }
        return timelineOriginSeconds + last.end
    }

    /// Stop everything: the remux thread, the listener, and every open connection. Idempotent.
    func invalidate() {
        stateLock.lock()
        let already = invalidated
        invalidated = true
        let open = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        guard !already else { return }
        deadlineLock.lock()
        mountDeadline.cancel()
        let deadlineWork = mountDeadlineWorkItem
        mountDeadlineWorkItem = nil
        deadlineLock.unlock()
        deadlineWork?.cancel()
        stream.cancel()
        listener?.cancel()
        open.forEach { $0.cancel() }
        if listener == nil { retireListenerOnce() }
    }

    private var isInvalidated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return invalidated
    }

    /// Start the listener synchronously (the VXTrailerProxy pattern) and record its port.
    ///
    /// The bind host is DERIVED from the hosting credential, never configured separately: no capability means
    /// loopback, which is the shipped invariant ("never reachable off-device"). `VXDiagExport.swift:154-163` is
    /// the working precedent for the `0.0.0.0` bind with these same `NWParameters`.
    private func listen() -> Bool {
        do {
            let bind = VortXEngineHostPolicy.bindHost(capability: hosting?.capability)
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(bind.hostString), port: .any)
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
                    self.retireListenerOnce()
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
            DiagnosticsLog.log("dv", "hls server listening on \(bind.hostString):\(bound)\(hosting == nil ? "" : " [hosted]")")
            return true
        } catch {
            DiagnosticsLog.log("dv", "hls server listener start failed: \(error)")
            return false
        }
    }

    private func retireListenerOnce() {
        stateLock.lock()
        let shouldRetire = !listenerRetired
        listenerRetired = true
        stateLock.unlock()
        if shouldRetire { stream.listenerDidRetire() }
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
                // Serve off the concurrent queue: playlist answers may poll-wait for the remux.
                self.serveQueue.async { self.route(connection, header: header) }
                return
            }
            if isComplete || accumulated.count > 64_000 {
                deadline.cancel(); connection.cancel(); return
            }
            self.readRequest(connection, buffer: accumulated, deadline: deadline)
        }
    }

    /// How one request's response is shaped. `.legacy` is the shipped behaviour and the only value a loopback
    /// session ever produces: treat everything as a body-bearing GET, ignore `Range`. A hosted session may
    /// additionally see HEAD (a probe) and Range (a recovery-path partial fetch), which loopback CoreMedia has
    /// never sent and which we therefore do not start answering differently on the on-device lane.
    struct Delivery: Equatable {
        let method: VortXEngineHostPolicy.Method
        let range: VortXEngineHostPolicy.RangeSpec?
        static let legacy = Delivery(method: .get, range: nil)
        var wantsBody: Bool { method == .get }
    }

    /// Parse the request and dispatch to the resources.
    ///
    /// The parse itself lives in `VortXEngineHostPolicy.route`, which is pure and therefore provable. For a
    /// loopback session it returns `.legacy` and reproduces the shipped parse exactly (method-blind,
    /// Range-blind); for a hosted session it enforces the capability, the method and the path prefix BEFORE a
    /// byte is written. A failed capability check closes with no reply at all, so a scanner on the LAN learns
    /// nothing it could not already learn from the open port.
    private func route(_ connection: NWConnection, header: Data) {
        guard !isInvalidated, let text = String(data: header, encoding: .utf8) else {
            close(connection, status: "400 Bad Request")
            return
        }
        switch VortXEngineHostPolicy.route(header: text, capability: hosting?.capability) {
        case .legacy(let path):
            DiagnosticsLog.log("dv", "hls req \(path)")
            dispatch(connection, path: path, delivery: .legacy)
        case .guarded(let method, let path, let range):
            DiagnosticsLog.log("dv", "hls req \(path) [hosted \(method.rawValue)\(range == nil ? "" : " ranged")]")
            dispatch(connection, path: path, delivery: Delivery(method: method, range: range))
        case .reject(let status):
            if let status {
                close(connection, status: status)
            } else {
                // No reply at all. See `VortXEngineHostPolicy.Route.reject`.
                connection.cancel()
            }
        }
    }

    private func dispatch(_ connection: NWConnection, path: String, delivery: Delivery) {
        switch path {
        case "/master.m3u8":    serveMaster(connection, videoVariant: .primary, delivery: delivery)
        case "/master-hdr.m3u8": serveMaster(connection, videoVariant: .hdrFallback, delivery: delivery)
        case "/media.m3u8":     serveMedia(connection, hdr: false, delivery: delivery)
        case "/media-hdr.m3u8": serveMedia(connection, hdr: true, delivery: delivery)
        case "/init.mp4":       serveInit(connection, hdr: false, delivery: delivery)
        case "/init-hdr.mp4":   serveInit(connection, hdr: true, delivery: delivery)
        default:
            if let audioRequest = MultiAudioPolicy.parseRequest(path: path) {
                switch audioRequest {
                case .playlist(let renditionID):
                    serveAudioPlaylist(connection, renditionID: renditionID, delivery: delivery)
                case .initialization(let renditionID):
                    serveAudioInit(connection, renditionID: renditionID, delivery: delivery)
                case .segment(let renditionID, let segmentID):
                    serveAudioSegment(connection, renditionID: renditionID, segmentID: segmentID,
                                      delivery: delivery)
                }
            } else if let subtitleRequest = SubtitleRenditionPolicy.parseRequest(path: path) {
                switch subtitleRequest {
                case .playlist(let renditionID):
                    serveSubtitlePlaylist(connection, renditionID: renditionID, delivery: delivery)
                case .segment(let renditionID, let segmentID):
                    serveSubtitleSegment(connection, renditionID: renditionID, segmentID: segmentID,
                                         delivery: delivery)
                }
            } else if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
               let index = Int(path.dropFirst(4).dropLast(4)) {
                serveSegment(connection, index: index, delivery: delivery)
            } else {
                DiagnosticsLog.log("dv", "hls 404 \(path)")
                close(connection, status: "404 Not Found")
            }
        }
    }

    // MARK: - Waiting on the remux (bounded polls; every tick re-checks teardown + remux failure)

    /// How long a playlist / init request may poll-wait for the remux to produce what it needs. Generous on
    /// purpose: the chrome's start watchdog demotes a dead mount long before this bound is the limiter, so
    /// it only stops an orphaned request from polling forever after a teardown race.
    private static let resourceWaitSeconds: TimeInterval = 60

    /// Poll `probe` until it yields a value, the deadline passes, the server is invalidated, or the remux
    /// FAILS (its classify fail-fast / mid-stream error). Returns nil on every non-success path; the caller
    /// answers 404 and AVPlayer's error path drives the libmpv demotion.
    private func waitForResource<T>(seconds: TimeInterval, _ probe: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isInvalidated { return nil }
            if let value = probe() { return value }
            if stream.buffer.status().failure != nil { return nil }   // remux failed: stop waiting
            Thread.sleep(forTimeInterval: 0.1)
        }
        return probe()
    }

    /// Poll within the one server-owned monotonic mount-to-ready budget. A stage may have a smaller local cap,
    /// but no stage can reset or extend the absolute 30-second deadline. The hard edge never performs a final
    /// probe after expiry, so playlist publication cannot race a timeout that already won.
    private func waitForMount<T>(maximumStageSeconds: TimeInterval? = nil,
                                 _ probe: () -> T?) -> T? {
        let started = ProcessInfo.processInfo.systemUptime
        let stageDeadline = maximumStageSeconds.flatMap { maximum -> TimeInterval? in
            guard maximum.isFinite, maximum > 0 else { return nil }
            return started + maximum
        }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let remaining = remainingMountBudget(now: now)
            guard remaining > 0, !isInvalidated else { return nil }
            if let value = probe() { return gateMountProbe(value) }
            if stream.buffer.status().failure != nil { return nil }
            if let stageDeadline, now >= stageDeadline {
                guard let value = probe() else { return nil }
                return gateMountProbe(value)
            }
            let stageRemaining = stageDeadline.map { max(0, $0 - now) } ?? .infinity
            Thread.sleep(forTimeInterval: min(0.1, remaining, stageRemaining))
        }
    }

    private func gateMountProbe<T>(_ value: T) -> T? {
        let completedAt = ProcessInfo.processInfo.systemUptime
        let invalidatedBeforeGate = isInvalidated
        deadlineLock.lock()
        let result = mountDeadline.gateSuccessfulProbe(
            value,
            completedAt: completedAt,
            invalidated: invalidatedBeforeGate)
        deadlineLock.unlock()
        if result.didExpire { handleMountTimeout() }
        guard let accepted = result.value, !isInvalidated else { return nil }
        return accepted
    }

    private func remainingMountBudget(now: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> TimeInterval {
        deadlineLock.lock()
        let result = mountDeadline.remaining(now: now)
        deadlineLock.unlock()
        if result.didExpire { handleMountTimeout() }
        return result.seconds
    }

    #if os(tvOS)
    /// Claim and dispatch one display request for each item variant. The claim is server-owned, so duplicate
    /// master requests cannot queue repeated panel switches. Final master publication still waits for settlement.
    private func requestDisplaySwitch(
        _ requestedRange: ContentDynamicRange,
        fps: Double,
        width: Int,
        height: Int,
        recovery: Bool,
        source: String
    ) {
        let switched = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            defer { switched.signal() }
            guard let self, !self.isInvalidated else { return }
            let applied = MainActor.assumeIsolated {
                HDRDisplayMode.request(
                    requestedRange, fps: fps, width: width, height: height, in: nil)
            }
            self.displayRequestLock.lock()
            if recovery {
                self.recoveryDisplayDispatched = true
            } else {
                self.primaryDisplayDispatched = true
            }
            self.displayRequestLock.unlock()
            DiagnosticsLog.log(
                "dv",
                "startup phase=display-request source=\(source) range=\(requestedRange.rawValue) applied=\(applied) "
                    + "elapsedMs=\(self.stream.startupElapsedMilliseconds)")
        }
        let switchBudget = min(2, remainingMountBudget())
        if switchBudget <= 0 || switched.wait(timeout: .now() + switchBudget) == .timedOut {
            DiagnosticsLog.log(
                "dv",
                "DV display switch request not confirmed within 2s (main queue busy); "
                    + "the switch may land after the master is served")
        }
    }

    private func displayRequestWasDispatched(recovery: Bool) -> Bool {
        displayRequestLock.lock(); defer { displayRequestLock.unlock() }
        return recovery ? recoveryDisplayDispatched : primaryDisplayDispatched
    }
    #endif

    private func expireMountIfNeeded() {
        _ = remainingMountBudget()
    }

    private func handleMountTimeout() {
        DiagnosticsLog.log(
            "dv", "hls_mount_to_ready_timeout count=1 waitedMs=30000 -> fail-soft")
        stream.failHLS("HLS mount did not reach AVPlayer readyToPlay within 30 seconds")
        invalidate()
        onStartupTimeout(self)
    }

    // MARK: - Resources

    /// Master playlist: exactly one video variant per AVPlayerItem. The primary item receives DV; a later
    /// explicit recovery item may receive the stripped-HDR base layer. Held until the remux has classified the
    /// source and written its header.
    private func serveMaster(_ connection: NWConnection,
                             videoVariant: DVPlaybackPolicy.MasterVideoVariant = .primary,
                             delivery: Delivery = .legacy) {
        DiagnosticsLog.log(
            "dv",
            "startup phase=master-request variant=\(videoVariant == .primary ? "primary" : "recovery") "
                + "elapsedMs=\(stream.startupElapsedMilliseconds)")
        var preludeSignaling: VortXMKVRemuxStream.HLSSignaling?
        #if os(tvOS)
        if videoVariant == .primary {
            let prelude = waitForMount { () -> PrimaryMasterPrelude? in
                let snapshot = self.stream.hlsSnapshot()
                if let signaling = snapshot.signaling { return .signaling(signaling) }
                if let intent = snapshot.displayIntent { return .displayIntent(intent) }
                return nil
            }
            guard let prelude else {
                DiagnosticsLog.log("dv", "hls 404 /master.m3u8")
                close(connection, status: "404 Not Found")
                return
            }
            switch prelude {
            case .displayIntent(let intent):
                requestDisplaySwitch(
                    .dolbyVision,
                    fps: intent.fps,
                    width: intent.width,
                    height: intent.height,
                    recovery: false,
                    source: "verified-preflight")
            case .signaling(let signaling):
                preludeSignaling = signaling
            }
        }
        #endif
        guard let sig = preludeSignaling ?? waitForMount({ stream.hlsSnapshot().signaling }) else {
            DiagnosticsLog.log("dv", "hls 404 /master.m3u8")
            close(connection, status: "404 Not Found")
            return
        }
        if videoVariant == .hdrFallback {
            let recoveryAvailable = waitForMount { () -> Bool? in
                let snapshot = self.stream.hlsSnapshot()
                guard snapshot.hdrRecoveryInitSettled else { return nil }
                guard let signaling = snapshot.signaling else { return false }
                return DVPlaybackPolicy.supportsHDRFallback(
                    dolbyVision: signaling.dolbyVision,
                    videoCodec: signaling.videoCodec,
                    surgerySettled: snapshot.hdrRecoveryInitSettled,
                    recoveryInitAvailable: snapshot.initDataHDR != nil)
            }
            guard recoveryAvailable == true else {
                DiagnosticsLog.log(
                    "dv",
                    "hls 404 /master-hdr.m3u8: validated HDR recovery init unavailable")
                close(connection, status: "404 Not Found")
                return
            }
        }
        #if os(tvOS)
        // The verified preflight path may already have started this request while resume and mux setup ran.
        // Sources that needed packet repair or audio transcode still use the final signaling path here.
        if sig.dolbyVision {
            let recoveryRange = DVPlaybackPolicy.hdrFallbackDisplayRange(videoRange: sig.videoRange)
            let requestedRange: ContentDynamicRange = videoVariant == .primary
                ? .dolbyVision
                : (recoveryRange == .hlg ? .hlg : .hdr10)
            requestDisplaySwitch(
                requestedRange,
                fps: sig.fps,
                width: sig.width,
                height: sig.height,
                recovery: videoVariant == .hdrFallback,
                source: "final-signaling")
        }
        #endif
        // Hold the master until any in-flight HDR display-mode switch settles. AVFoundation's multivariant
        // selector can reject an explicit-range item whenever it parses the master before the output pipeline
        // is provably HDR, and that choice is session-persistent. HDRDisplayMode.isSwitchSettled is always true on iOS/macOS and
        // whenever Match Dynamic Range never started a switch, so this is a no-op except on the tvOS DV path.
        let displaySettled: Bool? = waitForMount(maximumStageSeconds: 6) {
            #if os(tvOS)
            if sig.dolbyVision,
               !self.displayRequestWasDispatched(recovery: videoVariant == .hdrFallback) {
                return nil
            }
            #endif
            return HDRDisplayMode.isSwitchSettled ? true : nil
        }
        DiagnosticsLog.log(
            "dv",
            "startup phase=display-settle settled=\(displaySettled == true) "
                + "elapsedMs=\(stream.startupElapsedMilliseconds)")

        // Alternate qualification is hard-bounded and fail-open. Once this step finishes, the common startup
        // gate below treats the resulting topology as immutable: every advertised rendition must contribute
        // the same absolute startup IDs before the master can expose it.
        var featureSnapshot = stream.hlsWindowSnapshot()
        if featureSnapshot.audioState == .pending {
            if let resolved = waitForMount(
                maximumStageSeconds: MultiAudioPolicy.alternateStartupWaitSeconds, {
                let snapshot = stream.hlsWindowSnapshot()
                return snapshot.audioState == .pending ? nil : snapshot
            }) {
                featureSnapshot = resolved
            } else {
                guard remainingMountBudget() > 0 else {
                    DiagnosticsLog.log("dv", "hls 404 /master.m3u8")
                    close(connection, status: "404 Not Found")
                    return
                }
                stream.omitPendingAlternateAudioOnTimeout()
                featureSnapshot = stream.hlsWindowSnapshot()
            }
        }
        guard let publication = waitForMount({
            self.prepareMasterPublication()
        }) else {
            if !isInvalidated, stream.buffer.status().failure == nil {
                logStartupCohortTimeout()
            }
            DiagnosticsLog.log("dv", "hls 404 /master.m3u8")
            close(connection, status: "404 Not Found")
            return
        }

        let audioPlan = publication.audioPlan
        // With a qualified alternate the two-rendition tags render exactly as before. Without one, the muxed
        // primary still gets a NAMED URI-less row so AVPlayer's audio menu shows the real language instead of
        // "Unknown" (build 189 field regression on every multi-language mixed-codec file).
        let audioTags: [String]
        if audioPlan != nil {
            audioTags = MultiAudioPolicy.mediaTags(audioPlan)
        } else if let primaryTag = publication.primaryAudioTag {
            audioTags = [primaryTag]
        } else {
            audioTags = []
        }
        let audioAttribute = audioTags.isEmpty ? "" : ",AUDIO=\"audio\""
        let subtitleRenditions = publication.subtitles
        let subtitleTags = subtitleRenditions.map(SubtitleRenditionPolicy.mediaTag)
        let subtitleAttribute = SubtitleRenditionPolicy.streamInfAttribute(
            renditionCount: subtitleRenditions.count)
        let input = DVPlaybackPolicy.MasterPlaylistInput(
            videoCodec: sig.videoCodec,
            supplementalCodec: sig.supplementalCodec,
            videoRange: sig.videoRange,
            audioCodec: sig.audioCodec,
            width: sig.width,
            height: sig.height,
            bandwidth: sig.bandwidth,
            fps: sig.fps,
            dolbyVision: sig.dolbyVision)
        let body = DVPlaybackPolicy.masterPlaylistData(
            input: input,
            mediaTags: audioTags + subtitleTags,
            streamInfAttributes: audioAttribute + subtitleAttribute,
            videoVariant: videoVariant)
        let masterPath = videoVariant == .primary ? "/master.m3u8" : "/master-hdr.m3u8"
        DiagnosticsLog.log(
            "dv",
            "hls resp \(masterPath) variants=1 mode=\(videoVariant == .primary ? "primary" : "hdr-recovery") audio=\(audioPlan == nil ? 0 : 1) audioTags=\(audioTags.count) subs=\(subtitleRenditions.count) \(body.count)B elapsedMs=\(stream.startupElapsedMilliseconds)")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl", delivery: delivery)
    }

    /// Freeze the shortest absolute-zero cohort that satisfies every rendition's rendered-duration floor.
    /// The master is the topology publication edge, so subtitle WebVTT resources are materialized and every
    /// required durable key is rechecked before the topology becomes visible.
    private func prepareMasterPublication() -> MasterPublication? {
        publicationLock.lock(); defer { publicationLock.unlock() }

        if startupMediaList != nil {
            let snapshot = stream.hlsWindowSnapshot()
            guard topologyMatches(snapshot) else { return nil }
            return MasterPublication(
                audioPlan: advertisedAudioPlan,
                primaryAudioTag: advertisedPrimaryAudioTag,
                subtitles: advertisedSubtitles)
        }

        var snapshot = stream.hlsWindowSnapshot()
        guard snapshot.initData != nil,
              snapshot.audioState != .pending,
              !snapshot.window.segments.isEmpty else { return nil }
        let audioPlan = snapshot.audioPlan
        let subtitles = snapshot.subtitleRenditions
        var requiredWindows = [snapshot.window]
        if audioPlan != nil {
            guard snapshot.audioInitData != nil, let audioWindow = snapshot.audioWindow else { return nil }
            requiredWindows.append(audioWindow)
        }
        if !subtitles.isEmpty {
            guard snapshot.subtitleFailureReason == nil,
                  let subtitleWindow = snapshot.subtitleWindow else { return nil }
            requiredWindows.append(subtitleWindow)
        }
        guard requiredWindows.allSatisfy(windowConformsToFrozenTarget) else {
            stream.failHLS("HLS rendition interval exceeded the frozen target before master publication")
            return nil
        }
        guard let cohort = DVPlaybackPolicy.pinnedStartupCohort(
            windows: requiredWindows,
            ended: snapshot.ended,
            minimumSegmentCount: startupReadiness.minimumSegmentCount,
            minimumRenderedDurationMilliseconds:
                startupReadiness.minimumRenderedDurationMilliseconds) else { return nil }
        let ids = cohort.window.segments.map(\.id)
        guard exactWindow(snapshot.window, ids: ids) != nil else { return nil }
        let audioWindow = audioPlan == nil ? nil : snapshot.audioWindow.flatMap { exactWindow($0, ids: ids) }
        guard audioPlan == nil || audioWindow != nil else { return nil }

        if !subtitles.isEmpty {
            guard let subtitleWindow = snapshot.subtitleWindow.flatMap({ exactWindow($0, ids: ids) }) else {
                return nil
            }
            for rendition in subtitles {
                guard rendition.id >= 0, rendition.id < snapshot.subtitleCues.count,
                      stream.ensureSubtitleBacking(
                          renditionID: rendition.id,
                          window: subtitleWindow,
                          cues: snapshot.subtitleCues[rendition.id]) else { return nil }
            }
        }

        // Optional state can change while WebVTT files are written. Re-read it before committing the master;
        // stale files are harmless session-local artifacts, while a stale advertised topology would not be.
        snapshot = stream.hlsWindowSnapshot()
        guard snapshot.audioPlan == audioPlan,
              snapshot.subtitleRenditions == subtitles,
              snapshot.subtitleFailureReason == nil || subtitles.isEmpty,
              let finalVideoWindow = exactWindow(snapshot.window, ids: ids),
              ids.allSatisfy({ stream.hasHLSResource(.video(segmentID: $0)) }) else { return nil }
        var finalAudioWindow: VortXHLSWindow?
        if let audioPlan {
            guard snapshot.audioInitData != nil,
                  let window = snapshot.audioWindow.flatMap({ exactWindow($0, ids: ids) }),
                  ids.allSatisfy({ stream.hasHLSResource(.audio(
                      renditionID: audioPlan.alternate.id, segmentID: $0)) }) else { return nil }
            finalAudioWindow = window
        }
        if !subtitles.isEmpty {
            guard snapshot.subtitleWindow.flatMap({ exactWindow($0, ids: ids) }) != nil else { return nil }
            for rendition in subtitles where !ids.allSatisfy({
                stream.hasHLSResource(.subtitle(renditionID: rendition.id, segmentID: $0))
            }) { return nil }
        }

        let ended = cohort.ended
            && finalVideoWindow.segments.last?.id == snapshot.window.segments.last?.id
            && (finalAudioWindow == nil
                || finalAudioWindow?.segments.last?.id == snapshot.audioWindow?.segments.last?.id)
        startupMediaList = (finalVideoWindow, ended)
        publishedVideoWindow = finalVideoWindow
        advertisedAudioPlan = audioPlan
        advertisedPrimaryAudioTag = audioPlan == nil ? snapshot.primaryAudioTag : nil
        advertisedAudioInitData = audioPlan == nil ? nil : snapshot.audioInitData
        lastPublishedAudioWindow = finalAudioWindow
        advertisedSubtitles = subtitles
        advertisedDolbyVision = snapshot.signaling?.dolbyVision == true
        return MasterPublication(
            audioPlan: audioPlan,
            primaryAudioTag: advertisedPrimaryAudioTag,
            subtitles: subtitles)
    }

    private func logStartupCohortTimeout() {
        let progress = startupCommonProgress()
        publicationLock.lock()
        let shouldLog = !startupTimeoutLogged
        startupTimeoutLogged = true
        publicationLock.unlock()
        guard shouldLog else { return }
        DiagnosticsLog.log(
            "dv",
            "hls_startup_cohort_timeout waitedMs=30000 requiredCount=\(startupReadiness.minimumSegmentCount) requiredDurationMs=\(startupReadiness.minimumRenderedDurationMilliseconds) actualCount=\(progress.count) actualDuration=\(progress.durationMilliseconds)")
    }

    private func startupCommonProgress() -> (count: Int, durationMilliseconds: Int) {
        let snapshot = stream.hlsWindowSnapshot()
        guard snapshot.audioState != .pending else { return (0, 0) }
        var windows = [snapshot.window]
        if snapshot.audioPlan != nil {
            guard let audio = snapshot.audioWindow else { return (0, 0) }
            windows.append(audio)
        }
        if !snapshot.subtitleRenditions.isEmpty {
            guard let subtitles = snapshot.subtitleWindow else { return (0, 0) }
            windows.append(subtitles)
        }
        guard let window = greatestCommonContiguousWindow(windows: windows, startingAt: 0) else {
            return (0, 0)
        }
        return (
            window.segments.count,
            DVPlaybackPolicy.renderedDurationMilliseconds(of: window) ?? 0)
    }

    /// Both video variants and every optional media route render one coordinator-owned generation. Before any
    /// body is sent, all logical playlist receipts are recorded so unselected optional tracks cannot leak their
    /// old backing forever and a URI remains openable through its distributed-playlist deadline.
    private func currentPublication() -> Publication? {
        publicationLock.lock(); defer { publicationLock.unlock() }
        guard let startup = startupMediaList,
              let current = publishedVideoWindow else { return nil }
        let snapshot = stream.hlsWindowSnapshot()
        guard topologyMatches(snapshot) else {
            stream.failHLS("advertised HLS rendition topology became unavailable")
            return nil
        }

        let audioTerminated = audioDegraded(snapshot)
        var selectedVideo: VortXHLSWindow
        let ended: Bool
        // Pre-ready and post-ready share ONE window rule now (the 187 EVENT-playlist shape): the START is
        // pinned until the client's own consumption advances it, and the TAIL always grows with production.
        // The old pre-ready branch froze the whole startup window until markEngineReady; CoreMedia can hold
        // readyToPlay until the live playlist offers more than the minimum cohort, so a frozen pre-ready
        // window deadlocks startup (the engine's readyToPlay is exactly what would have unfrozen it). The
        // consumption floor already pins the start at the startup sequence while nothing has been fetched.
        if !engineReady, startup.ended || !consumptionAnchored {
            // `!consumptionAnchored` is the fleet escape hatch: the exact build 190 frozen pre-ready window.
            selectedVideo = startup.window
            ended = startup.ended
        } else {
            var requiredWindows = [snapshot.window]
            if advertisedAudioPlan != nil, !audioTerminated {
                guard let audioWindow = snapshot.audioWindow else { return nil }
                requiredWindows.append(audioWindow)
            }
            if !advertisedSubtitles.isEmpty {
                guard let subtitleWindow = snapshot.subtitleWindow else { return nil }
                for rendition in advertisedSubtitles {
                    guard rendition.id >= 0, rendition.id < snapshot.subtitleCues.count,
                          stream.ensureSubtitleBacking(
                              renditionID: rendition.id,
                              window: subtitleWindow,
                              cues: snapshot.subtitleCues[rendition.id]) else {
                        stream.failHLS("subtitle HLS backing could not be committed")
                        return nil
                    }
                }
                requiredWindows.append(subtitleWindow)
            }
            guard requiredWindows.allSatisfy(windowConformsToFrozenTarget) else {
                stream.failHLS("HLS rendition interval exceeded the frozen target before playlist publication")
                return nil
            }
            guard let common = greatestCommonContiguousWindow(
                windows: requiredWindows,
                startingAt: current.mediaSequence),
                  Array(common.segments.prefix(current.segments.count).map(\.id))
                    == current.segments.map(\.id) else {
                stream.failHLS("HLS publication frontier lost a previously advertised segment")
                return nil
            }
            let commonReachedEOF = snapshot.ended
                && common.segments.last?.id == snapshot.window.segments.last?.id
                && (snapshot.audioWindow == nil
                    || common.segments.last?.id == snapshot.audioWindow?.segments.last?.id)
                && (snapshot.subtitleWindow == nil
                    || common.segments.last?.id == snapshot.subtitleWindow?.segments.last?.id)
            if retainsFullTimeline {
                // FULL-TIMELINE RETENTION (hosted sessions only). The window START never advances: the playlist
                // always begins at the first segment and only grows at the tail, which is exactly the EVENT
                // promise the renderers make below and is what entitles AVPlayer to treat the whole produced
                // timeline as seekable. Backward seek stops being a demote and becomes an ordinary seek.
                //
                // Nothing has to be taught not to evict. Spool retention is playlist-receipt driven: a deadline
                // is armed only for a key that was in the PREVIOUS generation and is absent from this one, so a
                // playlist that never drops an entry never arms a deadline and nothing is ever collected. The
                // only real obstacle was the ordinary admission ceiling, raised for a retaining spool.
                //
                // Skipping `minimumConformingSuffix` here is not an optimisation, it is a requirement. That
                // function walks every suffix of the window and re-renders each one's duration through
                // `String(format:)`, which is O(n squared) formatted-string round trips per reload; at the 3600
                // to 7200 segments of a two-hour title that is seconds of CPU on every playlist fetch. With a
                // pinned start there is nothing to slide, so its entire purpose is void anyway.
                selectedVideo = common
            } else if commonReachedEOF,
               (common.segments.count < startupReadiness.minimumSegmentCount
                || (DVPlaybackPolicy.renderedDurationMilliseconds(of: common) ?? 0)
                    < startupReadiness.minimumRenderedDurationMilliseconds) {
                selectedVideo = common
            } else {
                // CONSUMPTION-ANCHORED SLIDE (the field-proven Beta 6 / build 187 contract, restored).
                // The pre-rework server never advanced MEDIA-SEQUENCE past the client at all (EVENT playlist,
                // entries only appended) and bounded memory BEHIND THE READER via the byte window. The rework
                // slid the published window to `minimumConformingSuffix` of everything PRODUCED on every
                // reload; with the small startup floor, production outran playback ~20 sequences per reload
                // (build 190 field log: seq=0 -> 29 -> 49 -> 59 at ~6s intervals, segs=4), AVPlayer's next
                // fetch fell off the window's tail-end, and every DV play skipped/stalled into the HDR10
                // demote. The playlist start may now advance ONLY behind the client's demonstrated
                // consumption frontier (the highest video segment it has actually fetched, minus a small
                // keep-behind), and never past the furthest slide the minimum floors would allow. Before the
                // client fetches anything, the startup window stays PINNED at its first sequence. Memory
                // stays bounded exactly as before: segments the window drops enter their RFC retention
                // deadlines, and the producer parks on the spool ceiling (backpressure) instead of running
                // unbounded ahead.
                guard let suffix = DVPlaybackPolicy.minimumConformingSuffix(
                    window: common,
                    minimumSegmentCount: startupReadiness.minimumSegmentCount,
                    minimumRenderedDurationMilliseconds:
                        startupReadiness.minimumRenderedDurationMilliseconds) else {
                    return nil
                }
                let suffixStartID = suffix.segments.first?.id ?? current.mediaSequence
                if consumptionAnchored {
                    let consumptionFloorID = highestServedVideoSegmentID < 0
                        ? current.mediaSequence
                        : VortXHLSConsumptionWindowPolicy.floor(
                            frontier: highestServedVideoSegmentID,
                            window: common)
                    let newStartID = max(current.mediaSequence, min(suffixStartID, consumptionFloorID))
                    let slid = common.segments.drop { $0.id < newStartID }
                    selectedVideo = slid.isEmpty ? common : VortXHLSWindow(segments: Array(slid))
                } else {
                    // Escape hatch OFF-path: the build 190 production-driven minimum suffix, verbatim.
                    selectedVideo = suffix
                }
            }
            publishedVideoWindow = selectedVideo
            ended = commonReachedEOF
        }

        // Until AVPlayer requests its first media segment, keep the initial playlist near the independently
        // decodable start. A delayed master can otherwise expose a long producer tail and AVPlayer may begin near
        // that live edge despite EXT-X-START. The first segment fetch is the receipt that releases this cap.
        if !engineReady,
           consumptionAnchored,
           highestServedVideoSegmentID < 0,
           !ended,
           selectedVideo.segments.count > max(
            startupReadiness.maximumUnconsumedSegmentCount,
            startup.window.segments.count
           ) {
            selectedVideo = startupReadiness.unconsumedStartupWindow(
                selectedVideo,
                startupCohortCount: startup.window.segments.count
            )
            publishedVideoWindow = selectedVideo
        }

        let ids = selectedVideo.segments.map(\.id)
        let selectedAudio: VortXHLSWindow?
        if advertisedAudioPlan == nil {
            selectedAudio = nil
        } else if audioTerminated {
            // Degraded: the alternate's route freezes at the last window it actually published.
            selectedAudio = lastPublishedAudioWindow
        } else {
            selectedAudio = snapshot.audioWindow.flatMap { exactWindow($0, ids: ids) }
            guard selectedAudio != nil else { return nil }
            lastPublishedAudioWindow = selectedAudio
        }
        let selectedSubtitles = advertisedSubtitles.isEmpty
            ? nil : snapshot.subtitleWindow.flatMap { exactWindow($0, ids: ids) }
        guard advertisedSubtitles.isEmpty || selectedSubtitles != nil else { return nil }
        guard recordPublication(
            videoWindow: selectedVideo,
            audioWindow: selectedAudio,
            subtitleWindow: selectedSubtitles) else {
            stream.failHLS("HLS playlist receipt could not be recorded")
            return nil
        }
        return Publication(
            videoWindow: selectedVideo,
            audioWindow: selectedAudio,
            subtitleWindow: selectedSubtitles,
            audioPlan: advertisedAudioPlan,
            subtitles: advertisedSubtitles,
            ended: ended,
            audioTerminated: audioTerminated)
    }

    private func topologyMatches(_ snapshot: VortXMKVRemuxStream.HLSWindowSnapshot) -> Bool {
        guard snapshot.frozenTarget == startupReadiness.frozenTarget else { return false }
        guard snapshot.signaling?.dolbyVision == advertisedDolbyVision else { return false }
        if let advertisedAudioPlan {
            // An advertised alternate that FAILED after publication is a DEGRADED topology, not a dead one:
            // the alternate route freezes at its last published window (ENDLIST) while video/subtitles play
            // on. Build 189 fail-closed here ("advertised HLS rendition topology became unavailable"), which
            // 404'd every playlist and demoted a healthy mid-play session to libmpv HDR10 the moment the
            // OPTIONAL rendition hit any snag.
            guard audioDegraded(snapshot)
                || (snapshot.audioPlan == advertisedAudioPlan && snapshot.audioInitData != nil) else {
                return false
            }
        }
        guard snapshot.subtitleFailureReason == nil || advertisedSubtitles.isEmpty,
              advertisedSubtitles.allSatisfy({ snapshot.subtitleRenditions.contains($0) }) else {
            return false
        }
        return true
    }

    /// True when an advertised alternate has failed after publication (the degraded, freeze-and-continue state).
    private func audioDegraded(_ snapshot: VortXMKVRemuxStream.HLSWindowSnapshot) -> Bool {
        advertisedAudioPlan != nil && snapshot.audioState == .failed
    }

    private func windowConformsToFrozenTarget(_ window: VortXHLSWindow) -> Bool {
        window.segments.allSatisfy {
            VortXHLSTargetPolicy.accepts(
                intervalSeconds: $0.duration,
                frozenTargetSeconds: startupReadiness.frozenTarget.seconds)
        }
    }

    private func recordPublication(videoWindow: VortXHLSWindow,
                                   audioWindow: VortXHLSWindow?,
                                   subtitleWindow: VortXHLSWindow?) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let videoKeys = videoWindow.segments.map {
            VortXHLSSessionSpool.ResourceKey.video(segmentID: $0.id)
        }
        guard stream.recordHLSPlaylist("/media.m3u8", resourceKeys: videoKeys, now: now) else {
            return false
        }
        if advertisedDolbyVision,
           !stream.recordHLSPlaylist("/media-hdr.m3u8", resourceKeys: videoKeys, now: now) {
            return false
        }
        if let plan = advertisedAudioPlan, let audioWindow {
            let keys = audioWindow.segments.map {
                VortXHLSSessionSpool.ResourceKey.audio(
                    renditionID: plan.alternate.id, segmentID: $0.id)
            }
            guard stream.recordHLSPlaylist(
                "/audio\(plan.alternate.id).m3u8", resourceKeys: keys, now: now) else { return false }
        }
        if let subtitleWindow {
            for rendition in advertisedSubtitles {
                let keys = subtitleWindow.segments.map {
                    VortXHLSSessionSpool.ResourceKey.subtitle(
                        renditionID: rendition.id, segmentID: $0.id)
                }
                guard stream.recordHLSPlaylist(
                    "/sub\(rendition.id).m3u8", resourceKeys: keys, now: now) else { return false }
            }
        }
        return true
    }

    private func exactWindow(_ window: VortXHLSWindow, ids: [Int]) -> VortXHLSWindow? {
        guard !ids.isEmpty, Set(ids).count == ids.count else { return nil }
        let grouped = Dictionary(grouping: window.segments, by: \.id)
        var selected: [VortXHLSSegment] = []
        selected.reserveCapacity(ids.count)
        for id in ids {
            guard let matches = grouped[id], matches.count == 1 else { return nil }
            selected.append(matches[0])
        }
        return VortXHLSWindow(segments: selected)
    }

    private func greatestCommonContiguousWindow(windows: [VortXHLSWindow],
                                                 startingAt firstID: Int) -> VortXHLSWindow? {
        guard firstID >= 0, let base = windows.first, !windows.isEmpty else { return nil }
        let grouped = windows.map { Dictionary(grouping: $0.segments, by: \.id) }
        guard grouped.allSatisfy({ $0.values.allSatisfy({ $0.count == 1 }) }),
              let startIndex = base.segments.firstIndex(where: { $0.id == firstID }) else { return nil }
        var expected = firstID
        var selected: [VortXHLSSegment] = []
        for segment in base.segments[startIndex...] {
            guard segment.id == expected,
                  grouped.allSatisfy({ $0[expected]?.count == 1 }) else { break }
            selected.append(segment)
            if expected == Int.max { break }
            expected += 1
        }
        return selected.isEmpty ? nil : VortXHLSWindow(segments: selected)
    }

    /// Both video variants render the exact same coordinator-owned absolute-ID frontier.
    private func serveMedia(_ connection: NWConnection, hdr: Bool, delivery: Delivery = .legacy) {
        let path = hdr ? "/media-hdr.m3u8" : "/media.m3u8"
        publicationLock.lock()
        let hdrAdvertised = advertisedDolbyVision
        publicationLock.unlock()
        guard !hdr || hdrAdvertised,
              let publication = waitForResource(seconds: Self.resourceWaitSeconds, {
                  self.currentPublication()
              }) else {
            DiagnosticsLog.log("dv", "hls 404 \(path)")
            close(connection, status: "404 Not Found")
            return
        }
        if let failure = stream.buffer.status().failure, !publication.ended {
            DiagnosticsLog.log("dv", "hls 404 \(path) (remux failed: \(failure))")
            close(connection, status: "404 Not Found")
            return
        }
        let body = buildMediaBody(
            window: publication.videoWindow,
            ended: publication.ended,
            mapURI: hdr ? "init-hdr.mp4" : "init.mp4")
        DiagnosticsLog.log(
            "dv",
            "hls resp \(path) seq=\(publication.videoWindow.mediaSequence) "
                + "segs=\(publication.videoWindow.segments.count) ended=\(publication.ended) "
                + "\(body.count)B elapsedMs=\(stream.startupElapsedMilliseconds)")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl", delivery: delivery)
    }

    /// Pure rendering of the exact immutable storage window used for request lookup.
    private func buildMediaBody(window: VortXHLSWindow, ended: Bool, mapURI: String) -> Data {
        let lines = DVPlaybackPolicy.mediaPlaylistLines(window: window, ended: ended,
            targetDuration: startupReadiness.frozenTarget.seconds, mapURI: mapURI,
            isEvent: retainsFullTimeline)
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The ftyp+moov init segment, retained in memory for the whole session (immune to window eviction).
    /// `hdr` serves only the validated dvvC/dvcC plus dby1-stripped copy. A missing recovery init is a 404,
    /// never a request to substitute the primary bytes that still declare Dolby Vision.
    private func serveInit(_ connection: NWConnection, hdr: Bool, delivery: Delivery = .legacy) {
        let path = hdr ? "/init-hdr.mp4" : "/init.mp4"
        let initData = waitForResource(seconds: Self.resourceWaitSeconds) { () -> Data? in
            let snap = stream.hlsSnapshot()
            return hdr ? snap.initDataHDR : snap.initData
        }
        guard let initData else {
            DiagnosticsLog.log("dv", "hls 404 \(path)")
            close(connection, status: "404 Not Found")
            return
        }
        DiagnosticsLog.log("dv", "hls resp \(path) \(initData.count)B")
        respond(connection, body: initData, contentType: "video/mp4", delivery: delivery)
    }

    /// Resource lookup is independent of the current playlist window. A URI removed from a later generation
    /// stays openable through its receipt-derived deadline, and the lease is acquired before any 200 bytes.
    private func serveSegment(_ connection: NWConnection, index: Int, delivery: Delivery = .legacy) {
        // A video segment REQUEST is the client's consumption receipt: requesting seg N proves its playlist
        // coverage reaches N, so the published window may slide up to N minus the keep-behind (and no
        // further). This is the anchor the consumption-bounded slide in `currentPublication` keys on.
        publicationLock.lock()
        if index > highestServedVideoSegmentID { highestServedVideoSegmentID = index }
        publicationLock.unlock()
        serveSpoolResource(
            connection,
            key: .video(segmentID: index),
            path: "/seg\(index).m4s",
            contentType: "video/mp4",
            delivery: delivery)
    }

    private static let segmentChunk = 512 * 1024

    // MARK: - Optional aligned audio rendition

    private func serveAudioPlaylist(_ connection: NWConnection, renditionID: Int,
                                    delivery: Delivery = .legacy) {
        guard let publication = waitForResource(seconds: Self.resourceWaitSeconds, {
            self.currentPublication()
        }), publication.audioPlan?.alternate.id == renditionID,
              let window = publication.audioWindow else {
            close(connection, status: "404 Not Found")
            return
        }
        let lines = MultiAudioPolicy.mediaPlaylist(
            renditionID: renditionID,
            window: window,
            ended: publication.ended || publication.audioTerminated,
            targetDuration: startupReadiness.frozenTarget.seconds,
            isEvent: retainsFullTimeline)
        let body = Data(lines.joined(separator: "\n").utf8)
        DiagnosticsLog.log("dv", "hls resp /audio\(renditionID).m3u8 seq=\(window.mediaSequence) segs=\(window.segments.count)\(publication.audioTerminated ? " [terminated]" : "")")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl", delivery: delivery)
    }

    private func serveAudioInit(_ connection: NWConnection, renditionID: Int,
                                delivery: Delivery = .legacy) {
        publicationLock.lock()
        let advertised = advertisedAudioPlan?.alternate.id == renditionID
        let retainedInit = advertisedAudioInitData
        publicationLock.unlock()
        let snapshot = stream.hlsWindowSnapshot()
        // The retained copy keeps the init servable in the degraded (terminated) state, where the failed
        // alternate's stream-side snapshot no longer carries it.
        guard advertised, let data = snapshot.audioInitData ?? retainedInit else {
            close(connection, status: "404 Not Found")
            return
        }
        respond(connection, body: data, contentType: "audio/mp4", delivery: delivery)
    }

    private func serveAudioSegment(_ connection: NWConnection,
                                   renditionID: Int,
                                   segmentID: Int,
                                   delivery: Delivery = .legacy) {
        publicationLock.lock()
        let advertised = advertisedAudioPlan?.alternate.id == renditionID
        publicationLock.unlock()
        guard advertised else {
            close(connection, status: "404 Not Found")
            return
        }
        serveSpoolResource(
            connection,
            key: .audio(renditionID: renditionID, segmentID: segmentID),
            path: "/audio\(renditionID)-seg\(segmentID).m4s",
            contentType: "audio/mp4",
            delivery: delivery)
    }

    // MARK: - Optional settled subtitle renditions

    private func serveSubtitlePlaylist(_ connection: NWConnection, renditionID: Int,
                                       delivery: Delivery = .legacy) {
        guard let publication = waitForResource(seconds: Self.resourceWaitSeconds, {
            self.currentPublication()
        }), publication.subtitles.contains(where: { $0.id == renditionID }),
              let window = publication.subtitleWindow else {
            close(connection, status: "404 Not Found")
            return
        }
        let lines = SubtitleRenditionPolicy.mediaPlaylist(
            renditionID: renditionID,
            window: window,
            ended: publication.ended,
            targetDuration: startupReadiness.frozenTarget.seconds,
            isEvent: retainsFullTimeline)
        respond(connection,
                body: Data(lines.joined(separator: "\n").utf8),
                contentType: "application/vnd.apple.mpegurl",
                delivery: delivery)
    }

    private func serveSubtitleSegment(_ connection: NWConnection,
                                      renditionID: Int,
                                      segmentID: Int,
                                      delivery: Delivery = .legacy) {
        publicationLock.lock()
        let advertised = advertisedSubtitles.contains(where: { $0.id == renditionID })
        publicationLock.unlock()
        guard advertised else {
            close(connection, status: "404 Not Found")
            return
        }
        serveSpoolResource(
            connection,
            key: .subtitle(renditionID: renditionID, segmentID: segmentID),
            path: SubtitleRenditionPolicy.segmentURI(
                renditionID: renditionID, segmentID: segmentID),
            contentType: "text/vtt",
            delivery: delivery)
    }

    private func serveSpoolResource(_ connection: NWConnection,
                                    key: VortXHLSSessionSpool.ResourceKey,
                                    path: String,
                                    contentType: String,
                                    delivery: Delivery = .legacy) {
        // HOSTED-ONLY BRANCHES FIRST, and they are only reachable for a hosted session because `Delivery` is
        // always `.legacy` on the loopback lane (see `route`). Everything after this block is the shipped code
        // path, unchanged, which is what keeps external-mode-off byte-identical.
        if delivery != .legacy {
            if !delivery.wantsBody {
                // HEAD: answer the headers a GET would have produced, without opening a response pump. Used by
                // a client probing whether a resource exists before committing to a fetch.
                guard let lease = stream.openHLSResource(key) else {
                    close(connection, status: "404 Not Found")
                    return
                }
                let length = lease.length
                lease.close()
                DiagnosticsLog.log("dv", "hls head \(path) \(length)B")
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if let spec = delivery.range {
                guard let lease = stream.openHLSResource(key) else {
                    DiagnosticsLog.log("dv", "hls 404 \(path)")
                    close(connection, status: "404 Not Found")
                    return
                }
                let total = lease.length
                guard let resolved = VortXEngineHostPolicy.resolve(spec, length: total) else {
                    lease.close()
                    DiagnosticsLog.log("dv", "hls 416 \(path) len=\(total)")
                    close(connection, status: "416 Range Not Satisfiable")
                    return
                }
                guard let response = VortXRangedSpoolPump(
                    lease: lease, chunkSize: Self.segmentChunk, range: resolved) else {
                    DiagnosticsLog.log("dv", "hls 404 \(path) (range pump)")
                    close(connection, status: "404 Not Found")
                    return
                }
                DiagnosticsLog.log(
                    "dv", "hls resp \(path) 206 \(resolved.lowerBound)-\(resolved.upperBound)/\(total)")
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: \(contentType)\r\nContent-Length: \(resolved.count)\r\nContent-Range: bytes \(resolved.lowerBound)-\(resolved.upperBound)/\(total)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                response.start(
                    header: Data(head.utf8),
                    cancelled: { [weak self] in self?.isInvalidated ?? true },
                    send: { content, completion in
                        connection.send(content: content, completion: .contentProcessed { error in
                            completion(error == nil)
                        })
                    },
                    terminal: { _ in connection.cancel() })
                return
            }
        }
        guard let lease = stream.openHLSResource(key),
              let response = VortXSpoolResponsePump(
                  lease: lease,
                  chunkSize: Self.segmentChunk) else {
            DiagnosticsLog.log("dv", "hls 404 \(path)")
            close(connection, status: "404 Not Found")
            return
        }
        DiagnosticsLog.log("dv", "hls resp \(path) \(lease.length)B")
        // `Accept-Ranges` is advertised only on a hosted session. Adding a header to the loopback response
        // would be a behaviour change on the lane that must not move, and CoreMedia over loopback has never
        // asked for one.
        let acceptRanges = hosting == nil ? "" : "Accept-Ranges: bytes\r\n"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(lease.length)\r\n\(acceptRanges)Connection: close\r\n\r\n"
        response.start(
            header: Data(head.utf8),
            cancelled: { [weak self] in self?.isInvalidated ?? true },
            send: { content, completion in
                connection.send(content: content, completion: .contentProcessed { error in
                    completion(error == nil)
                })
            },
            terminal: { _ in connection.cancel() })
    }

    // MARK: - Response helpers

    /// Answer a small in-memory resource (a playlist, an init segment).
    ///
    /// A `Range` on one of these is deliberately ignored and answered whole with a 200: a playlist is a few KB,
    /// an init segment a few hundred bytes, and no HLS client partial-fetches either. HEAD is honoured because
    /// it costs one branch and a hosted client may legitimately probe.
    private func respond(_ connection: NWConnection, body: Data, contentType: String,
                         delivery: Delivery = .legacy) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if delivery.wantsBody { payload.append(body) }
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
