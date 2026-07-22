#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import Network

/// Serves the DV-for-MKV streaming remux (`VortXMKVRemuxStream`) to AVPlayer as LOCAL HLS from 127.0.0.1
/// (b166). AVFoundation does not support a growing fragmented MP4 as a plain progressive asset: on the old
/// `vortxremux://` delivery every DV play on device either failed "Cannot Open" or scanned hundreds of MB
/// without ever producing a frame. HLS is the one delivery AVFoundation documents for a live fMP4 stream,
/// and the one Apple's authoring spec defines for Dolby Vision 8.1 (CODECS + SUPPLEMENTAL-CODECS +
/// VIDEO-RANGE), so this server presents the remux as:
///   - `/master.m3u8`: two EXT-X-STREAM-INF variants - the DV variant (CODECS + SUPPLEMENTAL-CODECS +
///     VIDEO-RANGE -> media.m3u8) plus a range-unlabeled "lifeboat" variant (-> media-hdr.m3u8), so
///     AVFoundation's variant filter (which drops an explicit PQ/HLG variant when the pipeline is not
///     provably HDR at parse time) always leaves one playable variant instead of zero -> -1002 (the b170
///     fix). Since #143 the two variants have DISTINCT playlists/inits so each variant's media agrees with
///     its declarations (the on-device -12927 rejections matched a declaration/content cross-check failing
///     right after /init.mp4): the DV variant's init carries the declared db1p/db4h compatibility brand,
///     the lifeboat's init has the dvvC stripped (it declares no Dolby Vision, so it serves none).
///   - `/media.m3u8`: a sliding playlist of closed segments whose bytes are currently resident, with an
///     absolute MEDIA-SEQUENCE and EXT-X-ENDLIST once the trailer is written. The first answer is held until
///     a small startup window exists, and those startup bytes remain pinned until AVPlayer is ready.
///   - `/media-hdr.m3u8`: the lifeboat's view of that same immutable resident window.
///   - `/init.mp4`:    the ftyp+moov init segment (retained in memory for the whole session).
///   - `/init-hdr.mp4`: the lifeboat's init: same moov with the DV config box stripped (#143).
///   - `/seg{N}.m4s`:  one closed segment (shared by both variants), read out of the sliding-window buffer.
///
/// Follows the proven `VXTrailerProxy` NWListener pattern: bound to 127.0.0.1 on an OS-assigned ephemeral
/// port (never reachable off-device), per-connection fail-soft (a bad request / evicted range / gone client
/// closes that one connection). One instance backs one playback session.
///
/// FAIL-SOFT GUARANTEE: a listener that will not start makes the factory return nil (the engine then emits
/// endFileError and the chrome demotes to libmpv HDR10); a remux failure 404s the next playlist reload so
/// AVPlayer errors into the same demotion; an evicted-segment request 404s the same way; and the chrome's
/// start watchdog covers a mount that never frames. Nothing here can hang playback.
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
    /// master advertises any rendition, then advances both video variants and every advertised audio/subtitle
    /// route through one shared absolute-ID frontier. Disk work and playlist receipts happen while this lock is
    /// held, so no concurrent request can expose half of a generation.
    private let publicationLock = NSLock()
    private var startupMediaList: (window: VortXHLSWindow, ended: Bool)?
    private var publishedVideoWindow: VortXHLSWindow?
    private var advertisedAudioPlan: MultiAudioPolicy.RenditionPlan?
    private var advertisedSubtitles: [SubtitleRenditionPolicy.Rendition] = []
    private var advertisedDolbyVision = false
    private var engineReady = false
    private var startupTimeoutLogged = false

    private struct Publication {
        let videoWindow: VortXHLSWindow
        let audioWindow: VortXHLSWindow?
        let subtitleWindow: VortXHLSWindow?
        let audioPlan: MultiAudioPolicy.RenditionPlan?
        let subtitles: [SubtitleRenditionPolicy.Rendition]
        let ended: Bool
    }

    private struct MasterPublication {
        let audioPlan: MultiAudioPolicy.RenditionPlan?
        let subtitles: [SubtitleRenditionPolicy.Rendition]
    }

    /// Build the remux stream + local server for an MKV URL. Returns nil when the listener cannot bind
    /// (the caller fails soft to libmpv). The caller must `start()` the returned server to begin remuxing.
    /// `mode` (#147): `.dolbyVision` (the default, the original lane) or `.plain` for a non-DV MKV kept on
    /// AVPlayer for Picture in Picture; the mode flows into classify + signaling (see VortXMKVRemuxStream.Mode).
    /// `startAtSeconds` is a sanitized source-timeline origin consumed by AVPlayer before this mount exists.
    /// The stream seeks once before muxing, then publishes the base-video timestamp it actually reached.
    static func make(input: URL, headers: [String: String]?,
                     mode: VortXMKVRemuxStream.Mode = .dolbyVision,
                     startAtSeconds: Double = 0) -> (server: VortXRemuxHLSServer, playlistURL: URL)? {
        let stream = VortXMKVRemuxStream(
            input: input.absoluteString,
            headers: headers,
            indexForHLS: true,
            mode: mode,
            startAtSeconds: startAtSeconds)
        let server = VortXRemuxHLSServer(stream: stream)
        guard server.listen() else { server.invalidate(); return nil }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(server.port)
        comps.path = "/master.m3u8"
        guard let url = comps.url else { server.invalidate(); return nil }
        return (server, url)
    }

    private init(stream: VortXMKVRemuxStream) {
        self.stream = stream
    }

    /// Begin remuxing. Call once, after the asset is (about to be) mounted.
    func start() { stream.start() }

    /// F3: forward the engine's first-frame readiness to the buffer so its producer lead widens from the
    /// reduced pre-ready value to the full lead. Called from AVPlayerEngine's readyToPlay handler.
    func markEngineReady() {
        publicationLock.lock(); engineReady = true; publicationLock.unlock()
        stream.markEngineReady()
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

    /// Whether the mount is still HEALTHY: the init segment has published AND the remux buffer has not failed.
    /// The engine's one-shot healthy-mount retry (#76) reads this to tell "a CoreMedia startup hiccup on a live
    /// mount" (retry a fresh item) from "the remux itself died" (demote). Same two signals serveMedia gates on.
    var isMountHealthy: Bool {
        stream.hlsSnapshot().initData != nil && stream.buffer.status().failure == nil
    }

    /// Monotonic mount-progress counters for the chrome's progress-aware start watchdog. Thread-safe passthrough.
    var mountProgress: VortXMKVRemuxStream.MountProgress { stream.mountProgress() }

    /// Stop everything: the remux thread, the listener, and every open connection. Idempotent.
    func invalidate() {
        stateLock.lock()
        let already = invalidated
        invalidated = true
        let open = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        guard !already else { return }
        stream.cancel()
        listener?.cancel()
        open.forEach { $0.cancel() }
        if listener == nil { retireListenerOnce() }
    }

    private var isInvalidated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return invalidated
    }

    /// Start the loopback listener synchronously (the VXTrailerProxy pattern) and record its port.
    private func listen() -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
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
            DiagnosticsLog.log("dv", "hls server listening on 127.0.0.1:\(bound)")
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

    /// Parse "GET /path HTTP/1.1" and dispatch to the four resources.
    private func route(_ connection: NWConnection, header: Data) {
        guard !isInvalidated,
              let text = String(data: header, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            close(connection, status: "400 Bad Request")
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            close(connection, status: "400 Bad Request")
            return
        }
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]
        DiagnosticsLog.log("dv", "hls req \(path)")
        switch path {
        case "/master.m3u8":    serveMaster(connection)
        case "/media.m3u8":     serveMedia(connection, hdr: false)
        case "/media-hdr.m3u8": serveMedia(connection, hdr: true)
        case "/init.mp4":       serveInit(connection, hdr: false)
        case "/init-hdr.mp4":   serveInit(connection, hdr: true)
        default:
            if let audioRequest = MultiAudioPolicy.parseRequest(path: path) {
                switch audioRequest {
                case .playlist(let renditionID):
                    serveAudioPlaylist(connection, renditionID: renditionID)
                case .initialization(let renditionID):
                    serveAudioInit(connection, renditionID: renditionID)
                case .segment(let renditionID, let segmentID):
                    serveAudioSegment(connection, renditionID: renditionID, segmentID: segmentID)
                }
            } else if let subtitleRequest = SubtitleRenditionPolicy.parseRequest(path: path) {
                switch subtitleRequest {
                case .playlist(let renditionID):
                    serveSubtitlePlaylist(connection, renditionID: renditionID)
                case .segment(let renditionID, let segmentID):
                    serveSubtitleSegment(connection, renditionID: renditionID, segmentID: segmentID)
                }
            } else if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
               let index = Int(path.dropFirst(4).dropLast(4)) {
                serveSegment(connection, index: index)
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
    private func waitFor<T>(seconds: TimeInterval, _ probe: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isInvalidated { return nil }
            if let value = probe() { return value }
            if stream.buffer.status().failure != nil { return nil }   // remux failed: stop waiting
            Thread.sleep(forTimeInterval: 0.1)
        }
        return probe()
    }

    // MARK: - Resources

    /// Master playlist: TWO variants (DV -> media.m3u8, lifeboat -> media-hdr.m3u8, #143). Held until the
    /// remux has classified the source
    /// and written its header (the signaling exists from then on).
    private func serveMaster(_ connection: NWConnection) {
        guard let sig = waitFor(seconds: Self.resourceWaitSeconds, { stream.hlsSnapshot().signaling }) else {
            DiagnosticsLog.log("dv", "hls 404 /master.m3u8")
            close(connection, status: "404 Not Found")
            return
        }
        #if os(tvOS)
        // #147: the panel switch below is DV-lane only. A PLAIN (non-DV) remux mount must never touch the
        // panel: its master carries no DV declaration and its content is whatever the source was (usually
        // SDR). `sig.dolbyVision` is mode-derived (every `.dolbyVision` master keeps today's behavior exactly,
        // including a P8 with an unknown compat id).
        if sig.dolbyVision {
        // #76: FIRE the Dolby Vision panel switch HERE, now that classify has published signaling, and BEFORE
        // the media playlist / any segment (the real video mount). This replaces the old pre-attach switch in
        // loadFile, which fired on mount for every remux candidate and cycled the panel twice per hop whenever
        // classify then rejected a non-DV / undecodable source (that path fails the buffer BEFORE any signaling
        // exists, 404s the guard above, and never reaches this line). Signaling PRESENCE is the gate: every
        // served master is a classify-ACCEPTED DV source by construction (non-5/7/8 profiles are rejected
        // pre-signaling), including a P8 with an unknown compat id whose CODECS string ships as plain HEVC.
        // The native (non-remux) DV lane still switches pre-attach because AVPlayer cannot report the profile
        // before it demuxes. `request` is @MainActor and a no-op on iOS/macOS. Fired synchronously (bounded
        // semaphore) so setSwitchSettled(false) lands before the settle-wait below, which is what closes the
        // master-parse race that wait exists for.
        let switched = DispatchSemaphore(value: 0)
        let dvFps = sig.fps, dvWidth = sig.width, dvHeight = sig.height
        DispatchQueue.main.async { [weak self] in
            defer { switched.signal() }   // signal on EVERY exit so the serve task never eats the full timeout
            // Teardown race (#76 rework): if the user exited in this instant, invalidate() + stop()'s
            // HDRDisplayMode.reset may already have run; an unguarded queued request would then flip the TV
            // into DV mode on the home screen with nothing left to correct it. A torn-down server never
            // switches the panel.
            guard let self, !self.isInvalidated else { return }
            MainActor.assumeIsolated {   // request() is @MainActor; this closure runs on the main queue
                HDRDisplayMode.request(.dolbyVision, fps: dvFps, width: dvWidth, height: dvHeight, in: nil)
            }
            DiagnosticsLog.log("dv", "remux classify confirmed DV -> requested Dolby Vision display mode before mount (fps=\(String(format: "%.3f", dvFps)) \(dvWidth)x\(dvHeight))")
        }
        if switched.wait(timeout: .now() + 2) == .timedOut {   // bounded: a wedged main must not hang the serve task
            DiagnosticsLog.log("dv", "DV display switch request not confirmed within 2s (main queue busy); the switch may land after the master is served")
        }
        }   // end sig.dolbyVision (#147)
        #endif
        // Hold the master until any in-flight HDR display-mode switch settles. AVFoundation's multivariant
        // selector drops the explicit-PQ DV variant whenever it parses the master before the output pipeline
        // is provably HDR, and that choice is session-persistent, so a master fetched mid-switch can pin the
        // lifeboat (HDR10 output) for the whole title. Bounded and fail-OPEN: on timeout the lifeboat still
        // guarantees a playable variant. HDRDisplayMode.isSwitchSettled is always true on iOS/macOS and
        // whenever Match Dynamic Range never started a switch, so this is a no-op except on the tvOS DV path.
        _ = waitFor(seconds: 6) { HDRDisplayMode.isSwitchSettled ? true : nil }

        // Alternate qualification is hard-bounded and fail-open. Once this step finishes, the common startup
        // gate below treats the resulting topology as immutable: every advertised rendition must contribute
        // the same absolute startup IDs before the master can expose it.
        var featureSnapshot = stream.hlsWindowSnapshot()
        if featureSnapshot.audioState == .pending {
            if let resolved = waitFor(seconds: MultiAudioPolicy.alternateStartupWaitSeconds, {
                let snapshot = stream.hlsWindowSnapshot()
                return snapshot.audioState == .pending ? nil : snapshot
            }) {
                featureSnapshot = resolved
            } else {
                stream.omitPendingAlternateAudioOnTimeout()
                featureSnapshot = stream.hlsWindowSnapshot()
            }
        }
        guard let publication = waitFor(seconds: Self.resourceWaitSeconds, {
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
        let audioTags = MultiAudioPolicy.mediaTags(audioPlan)
        let audioAttribute = MultiAudioPolicy.streamInfAttribute(plan: audioPlan)
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
            streamInfAttributes: audioAttribute + subtitleAttribute)
        DiagnosticsLog.log("dv", "hls resp /master.m3u8 variants=\(sig.dolbyVision ? 2 : 1) audio=\(audioPlan == nil ? 0 : 1) subs=\(subtitleRenditions.count) \(body.count)B")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    private static let minimumStartupSegments = 6
    private static let minimumStartupDurationMilliseconds = 15_000

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
        guard let cohort = DVPlaybackPolicy.pinnedStartupCohort(
            windows: requiredWindows,
            ended: snapshot.ended,
            minimumSegmentCount: Self.minimumStartupSegments,
            minimumRenderedDurationMilliseconds: Self.minimumStartupDurationMilliseconds) else { return nil }
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
        advertisedSubtitles = subtitles
        advertisedDolbyVision = snapshot.signaling?.dolbyVision == true
        return MasterPublication(audioPlan: audioPlan, subtitles: subtitles)
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
            "hls_startup_cohort_timeout waitedMs=60000 requiredCount=6 requiredDurationMs=15000 actualCount=\(progress.count) actualDuration=\(progress.durationMilliseconds)")
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

        let selectedVideo: VortXHLSWindow
        let ended: Bool
        if !engineReady {
            selectedVideo = startup.window
            ended = startup.ended
        } else {
            var requiredWindows = [snapshot.window]
            if advertisedAudioPlan != nil {
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
            if commonReachedEOF,
               (common.segments.count < Self.minimumStartupSegments
                || (DVPlaybackPolicy.renderedDurationMilliseconds(of: common) ?? 0)
                    < Self.minimumStartupDurationMilliseconds) {
                selectedVideo = common
            } else {
                guard let suffix = DVPlaybackPolicy.minimumConformingSuffix(
                    window: common,
                    minimumSegmentCount: Self.minimumStartupSegments,
                    minimumRenderedDurationMilliseconds: Self.minimumStartupDurationMilliseconds) else {
                    return nil
                }
                selectedVideo = suffix
            }
            publishedVideoWindow = selectedVideo
            ended = commonReachedEOF
        }

        let ids = selectedVideo.segments.map(\.id)
        let selectedAudio = advertisedAudioPlan == nil
            ? nil : snapshot.audioWindow.flatMap { exactWindow($0, ids: ids) }
        guard advertisedAudioPlan == nil || selectedAudio != nil else { return nil }
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
            ended: ended)
    }

    private func topologyMatches(_ snapshot: VortXMKVRemuxStream.HLSWindowSnapshot) -> Bool {
        guard snapshot.signaling?.dolbyVision == advertisedDolbyVision else { return false }
        if let advertisedAudioPlan {
            guard snapshot.audioPlan == advertisedAudioPlan,
                  snapshot.audioInitData != nil else { return false }
        }
        guard snapshot.subtitleFailureReason == nil || advertisedSubtitles.isEmpty,
              advertisedSubtitles.allSatisfy({ snapshot.subtitleRenditions.contains($0) }) else {
            return false
        }
        return true
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
    private func serveMedia(_ connection: NWConnection, hdr: Bool) {
        let path = hdr ? "/media-hdr.m3u8" : "/media.m3u8"
        publicationLock.lock()
        let hdrAdvertised = advertisedDolbyVision
        publicationLock.unlock()
        guard !hdr || hdrAdvertised,
              let publication = waitFor(seconds: Self.resourceWaitSeconds, {
                  self.currentPublication()
              }) else {
            DiagnosticsLog.log("dv", "hls 404 \(path)")
            close(connection, status: "404 Not Found")
            return
        }
        if stream.buffer.status().failure != nil, !publication.ended {
            DiagnosticsLog.log("dv", "hls 404 \(path) (remux failed)")
            close(connection, status: "404 Not Found")
            return
        }
        let body = Self.buildMediaBody(
            window: publication.videoWindow,
            ended: publication.ended,
            mapURI: hdr ? "init-hdr.mp4" : "init.mp4")
        DiagnosticsLog.log("dv", "hls resp \(path) seq=\(publication.videoWindow.mediaSequence) segs=\(publication.videoWindow.segments.count) ended=\(publication.ended) \(body.count)B")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    /// Pure rendering of the exact immutable storage window used for request lookup.
    private static func buildMediaBody(window: VortXHLSWindow, ended: Bool, mapURI: String) -> Data {
        let lines = DVPlaybackPolicy.mediaPlaylistLines(window: window, ended: ended,
            targetDuration: VortXMKVRemuxStream.hlsTargetDuration, mapURI: mapURI)
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The ftyp+moov init segment, retained in memory for the whole session (immune to window eviction).
    /// `hdr` serves the lifeboat's dvvC-stripped copy (#143); both publish in the same lock write, so
    /// whichever exists implies both do (the nil-coalesce is a belt-and-braces fallback, not a lane).
    private func serveInit(_ connection: NWConnection, hdr: Bool) {
        let path = hdr ? "/init-hdr.mp4" : "/init.mp4"
        let initData = waitFor(seconds: Self.resourceWaitSeconds) { () -> Data? in
            let snap = stream.hlsSnapshot()
            return hdr ? (snap.initDataHDR ?? snap.initData) : snap.initData
        }
        guard let initData else {
            DiagnosticsLog.log("dv", "hls 404 \(path)")
            close(connection, status: "404 Not Found")
            return
        }
        DiagnosticsLog.log("dv", "hls resp \(path) \(initData.count)B")
        respond(connection, body: initData, contentType: "video/mp4")
    }

    /// Resource lookup is independent of the current playlist window. A URI removed from a later generation
    /// stays openable through its receipt-derived deadline, and the lease is acquired before any 200 bytes.
    private func serveSegment(_ connection: NWConnection, index: Int) {
        serveSpoolResource(
            connection,
            key: .video(segmentID: index),
            path: "/seg\(index).m4s",
            contentType: "video/mp4")
    }

    private static let segmentChunk = 512 * 1024

    // MARK: - Optional aligned audio rendition

    private func serveAudioPlaylist(_ connection: NWConnection, renditionID: Int) {
        guard let publication = waitFor(seconds: Self.resourceWaitSeconds, {
            self.currentPublication()
        }), publication.audioPlan?.alternate.id == renditionID,
              let window = publication.audioWindow else {
            close(connection, status: "404 Not Found")
            return
        }
        let lines = MultiAudioPolicy.mediaPlaylist(
            renditionID: renditionID,
            window: window,
            ended: publication.ended,
            targetDuration: VortXMKVRemuxStream.hlsTargetDuration)
        let body = Data(lines.joined(separator: "\n").utf8)
        DiagnosticsLog.log("dv", "hls resp /audio\(renditionID).m3u8 seq=\(window.mediaSequence) segs=\(window.segments.count)")
        respond(connection, body: body, contentType: "application/vnd.apple.mpegurl")
    }

    private func serveAudioInit(_ connection: NWConnection, renditionID: Int) {
        publicationLock.lock()
        let advertised = advertisedAudioPlan?.alternate.id == renditionID
        publicationLock.unlock()
        let snapshot = stream.hlsWindowSnapshot()
        guard advertised, snapshot.audioPlan?.alternate.id == renditionID,
              let data = snapshot.audioInitData else {
            close(connection, status: "404 Not Found")
            return
        }
        respond(connection, body: data, contentType: "audio/mp4")
    }

    private func serveAudioSegment(_ connection: NWConnection,
                                   renditionID: Int,
                                   segmentID: Int) {
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
            contentType: "audio/mp4")
    }

    // MARK: - Optional settled subtitle renditions

    private func serveSubtitlePlaylist(_ connection: NWConnection, renditionID: Int) {
        guard let publication = waitFor(seconds: Self.resourceWaitSeconds, {
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
            targetDuration: VortXMKVRemuxStream.hlsTargetDuration)
        respond(connection,
                body: Data(lines.joined(separator: "\n").utf8),
                contentType: "application/vnd.apple.mpegurl")
    }

    private func serveSubtitleSegment(_ connection: NWConnection,
                                      renditionID: Int,
                                      segmentID: Int) {
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
            contentType: "text/vtt")
    }

    private func serveSpoolResource(_ connection: NWConnection,
                                    key: VortXHLSSessionSpool.ResourceKey,
                                    path: String,
                                    contentType: String) {
        guard let lease = stream.openHLSResource(key),
              let response = VortXSpoolResponsePump(
                  lease: lease,
                  chunkSize: Self.segmentChunk) else {
            DiagnosticsLog.log("dv", "hls 404 \(path)")
            close(connection, status: "404 Not Found")
            return
        }
        DiagnosticsLog.log("dv", "hls resp \(path) \(lease.length)B")
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(lease.length)\r\nConnection: close\r\n\r\n"
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

    private func respond(_ connection: NWConnection, body: Data, contentType: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
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
