#if os(iOS) || os(tvOS) || os(macOS)
import Foundation

/// A remux mount that lives on ANOTHER MACHINE.
///
/// `VortXRemuxHLSServer` is not merely a URL to the engine: the engine asks it seven questions
/// (`markEngineReady`, `sourceDurationSeconds`, `timelineOriginSeconds`, `authoritativeFrameRate`, `chapters`,
/// `isMountHealthy`, `mountProgress`) and a remote mount has to answer all seven. This is that answer. It polls
/// the host's status endpoint and caches the result, so every property stays a cheap synchronous read exactly
/// like the local one, and the engine's call sites do not have to learn about latency.
///
/// WHY THE PANEL SWITCH IS HERE AND NOT ON THE HOST. On device, the Dolby Vision panel switch is fired from
/// inside `VortXRemuxHLSServer.serveMaster`, under `#if os(tvOS)`, at the moment classify confirms a decodable
/// DV profile. A host is a Mac, so that code is compiled out and a hosted session would serve a true DV stream
/// to an Apple TV whose panel was never switched into DV mode. The client therefore fires it itself, from the
/// signalling the host reports. It can also fire it EARLIER than the on-device lane manages, before the item is
/// attached at all, which is the ordering Apple Tech Talk 503 actually asks for.
///
/// FAILOVER IS THE POINT OF THE POLL, not a side effect. A Mac can close its lid, sleep, drop off Wi-Fi or be
/// quit mid-film. When that happens the client must degrade to an on-device mount at the current position, not
/// stall. `onLost` is how this object says so, and `VortXEngineHostPolicy.failover` decides when: a host that
/// REPORTS itself unhealthy is believed at once, while silence is ambiguous and has to run out a threshold.
final class VortXRemoteRemuxMount: @unchecked Sendable {

    /// Bounded time after session creation for the host to publish classify and init signalling.
    static let signallingTimeoutSeconds: Double = 12

    struct ReadinessReceipt: Sendable {
        let identity: VortXEngineHostPolicy.RemoteMountIdentity
        let status: VortXEngineProtocol.SessionStatus
    }

    enum ReadinessFailure: String, Error {
        case explicitFailure = "explicit-failure"
        case unhealthy = "unhealthy"
        case timeout = "readiness-timeout"
        case retired = "retired-mount"
        case cancelled = "cancelled"
    }

    /// Where the client's AVPlayer mounts. Composed against the address this client dialled, never against an
    /// address the host guessed about itself.
    let playlistURL: URL

    /// Exact host-session identity carried by every readiness receipt and loss callback.
    let identity: VortXEngineHostPolicy.RemoteMountIdentity

    /// Whether the host granted full-timeline retention. When true the whole produced timeline is seekable and
    /// the client must NOT clamp backward seeks; when false a hosted session behaves exactly like a local one.
    let retainsFullTimeline: Bool

    private let session: VortXExternalEngine.OpenedSession
    private let engine: VortXExternalEngine
    private let onLost: @Sendable (VortXRemoteRemuxMount) -> Void

    private let lock = NSLock()
    private var latest: VortXEngineProtocol.SessionStatus?
    private var consecutiveFailures = 0
    private var invalidated = false
    private var poller: Task<Void, Never>?
    private var readyMarked = false
    /// One exact remote close is shared by ordinary invalidation and an AV→MPV physical-quiescence handoff.
    /// Repeating DELETEs may receive the same idempotent host receipt, but we never create competing local
    /// waiters that could race their deadlines.
    private var teardownReceipt: VortXRemuxQuiescenceReceipt?

    private init(session: VortXExternalEngine.OpenedSession,
                 engine: VortXExternalEngine,
                 onLost: @escaping @Sendable (VortXRemoteRemuxMount) -> Void) {
        self.session = session
        self.engine = engine
        self.playlistURL = session.playlistURL
        self.identity = VortXEngineHostPolicy.RemoteMountIdentity(
            sessionID: session.sessionID,
            mountGeneration: session.mountGeneration,
            playlistURL: session.playlistURL.absoluteString)
        self.retainsFullTimeline = session.retainsFullTimeline
        self.onLost = onLost
    }

    /// Open a session on the configured host. Returns nil for EVERY failure, which the caller turns into an
    /// ordinary on-device mount rather than an error the user has to see. There is no state in which a failed
    /// host makes playback worse than not having one.
    static func open(input: URL,
                     headers: [String: String]?,
                     mode: VortXEngineProtocol.RemuxMode,
                     startAtSeconds: Double,
                     selectedAudioStreamIndex: Int? = nil,
                     preferredAudioLanguages: [String]? = nil,
                     audioRejectTerms: [String]? = nil,
                     engine: VortXExternalEngine = .shared,
                     onLost: @escaping @Sendable (VortXRemoteRemuxMount) -> Void) async
        -> VortXRemoteRemuxMount? {
        guard let opened = await engine.openSession(
            input: input, headers: headers, mode: mode,
            startAtSeconds: max(0, startAtSeconds),
            selectedAudioStreamIndex: selectedAudioStreamIndex,
            preferredAudioLanguages: preferredAudioLanguages,
            audioRejectTerms: audioRejectTerms) else { return nil }
        return VortXRemoteRemuxMount(session: opened, engine: engine, onLost: onLost)
    }

    /// Begin steady-state polling after the bounded readiness wait succeeds. Startup owns its own status loop,
    /// so a young session cannot spend the steady-state silence budget before it has published its first init.
    func start() {
        lock.lock()
        guard !invalidated, poller == nil else { lock.unlock(); return }
        lock.unlock()
        let task = Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, !self.isInvalidated {
                await self.pollOnce()
                try? await Task.sleep(
                    nanoseconds: UInt64(VortXEngineHostPolicy.healthPollSeconds * 1_000_000_000))
            }
        }
        lock.lock(); poller = task; lock.unlock()
    }

    private var isInvalidated: Bool {
        lock.lock(); defer { lock.unlock() }
        return invalidated
    }

    private func cacheSuccessfulStatus(_ status: VortXEngineProtocol.SessionStatus) {
        lock.lock()
        latest = status
        consecutiveFailures = 0
        lock.unlock()
    }

    private func pollOnce() async {
        let status = await engine.status(session)
        lock.lock()
        if let status {
            latest = status
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
        let failures = consecutiveFailures
        let alreadyGone = invalidated
        lock.unlock()
        guard !alreadyGone else { return }
        let hostReportsHealthy = status?.failed == true ? false : status?.healthy
        let decision = VortXEngineHostPolicy.failover(
            consecutiveControlFailures: failures,
            hostReportsHealthy: hostReportsHealthy)
        guard decision == .failOverToDevice else { return }
        DiagnosticsLog.log(
            "engine",
            "host session lost session=\(identity.sessionID) failures=\(failures) "
                + "reportedHealthy=\(String(describing: status?.healthy)) "
                + "reportedFailed=\(String(describing: status?.failed)) -> falling back on-device")
        VXProbe.log("dv", "external engine mount lost -> on-device remount at current position")
        invalidate()
        onLost(self)
    }

    /// Wait, bounded, for the host to publish classify signalling.
    ///
    /// The client needs this BEFORE it attaches an item, because on tvOS the Dolby Vision panel must be switched
    /// before the AVPlayerItem is assigned. Bounded and fail-soft: timeout returns an explicit reason and the
    /// caller logs it before rebuilding the same source on-device.
    func awaitSignalling(
        timeoutSeconds: Double = VortXRemoteRemuxMount.signallingTimeoutSeconds
    ) async -> Result<ReadinessReceipt, ReadinessFailure> {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            if isInvalidated { return .failure(.retired) }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .failure(.timeout) }
            if let status = await engine.status(session, timeoutSeconds: remaining) {
                cacheSuccessfulStatus(status)
                let decision = VortXEngineHostPolicy.remoteReadiness(
                    statusReceived: true,
                    healthy: status.healthy,
                    initPublished: status.initPublished,
                    failed: status.failed,
                    signalingPublished: status.signalingPublished,
                    deadlineExpired: Date() >= deadline)
                switch decision {
                case .pending:
                    break
                case .ready:
                    return .success(ReadinessReceipt(identity: identity, status: status))
                case .failed(.explicitFailure):
                    return .failure(.explicitFailure)
                case .failed(.unhealthy):
                    return .failure(.unhealthy)
                case .failed(.timeout):
                    return .failure(.timeout)
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Refresh the host's HDR recovery capability at the exact failure boundary. The background poll can cache
    /// `false` before init surgery settles, so a CoreMedia rejection performs its own bounded status read rather
    /// than treating that young value as final. Only an explicit `true` succeeds; timeout, an unhealthy host,
    /// invalidation, cancellation and an older host's nil field all fail closed.
    func awaitHDRFallbackCapability(timeoutSeconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while Date() < deadline, !isInvalidated, !Task.isCancelled {
            if let status = await engine.status(session) {
                cacheSuccessfulStatus(status)
                if status.supportsHDRFallback == true { return true }
                if !status.healthy { return false }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    // MARK: - The seven answers

    private var cached: VortXEngineProtocol.SessionStatus? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Tell the host our player reached first frame, so its producer lead widens exactly as the on-device lane's
    /// does. Returns whether this was the FIRST such call, matching the local server's contract (the engine uses
    /// the answer to detect a mount that already expired).
    @discardableResult
    func markEngineReady() -> Bool {
        lock.lock()
        let first = !readyMarked
        readyMarked = true
        let gone = invalidated
        lock.unlock()
        guard first, !gone else { return false }
        Task.detached(priority: .userInitiated) { [engine, session] in
            _ = await engine.markReady(session)
        }
        return true
    }

    var sourceDurationSeconds: Double { cached?.durationSeconds ?? 0 }
    var timelineOriginSeconds: Double { cached?.timelineOriginSeconds ?? 0 }
    var authoritativeFrameRate: Double { cached?.frameRate ?? 0 }
    var videoWidth: Int { cached?.width ?? 0 }
    var videoHeight: Int { cached?.height ?? 0 }
    var declaredBandwidth: Int { cached?.bandwidth ?? 0 }
    var videoRange: String? { cached?.videoRange }
    var supportsHDRFallback: Bool { cached?.supportsHDRFallback ?? false }
    var sourceAudioTracks: [VortXEngineProtocol.AudioTrack] { cached?.audioTracks ?? [] }
    var selectedSourceAudioIndex: Int? { cached?.selectedAudioStreamIndex }
    var sourceSubtitleTracks: [VortXEngineProtocol.SubtitleTrack] {
        cached?.subtitleTracks ?? []
    }

    var chapters: [(start: Double, title: String)] {
        (cached?.chapters ?? []).map { ($0.start, $0.title) }
    }

    /// Healthy until proven otherwise. Before the first poll lands there is no evidence either way, and
    /// answering false would make the engine's healthy-mount retry treat a mount that is merely young as dead.
    var isMountHealthy: Bool { cached?.healthy ?? true }

    /// The furthest source second the host has produced. Forward seeks clamp against this exactly as they do
    /// on-device; unlike on-device, it cannot be inferred from AVPlayer's seekable ranges, because a retaining
    /// session advertises the whole timeline regardless of how much has actually been produced.
    var producedEdgeSeconds: Double { cached?.producedEdgeSeconds ?? 0 }

    var mountProgress: VortXMKVRemuxStream.MountProgress {
        guard let status = cached else {
            return VortXMKVRemuxStream.MountProgress(
                producedBytes: 0, segmentCount: 0, initPublished: false,
                signalingPublished: false, ended: false, failed: false)
        }
        return VortXMKVRemuxStream.MountProgress(
            producedBytes: status.producedBytes,
            segmentCount: status.producedSegments,
            // The host does not report init publication separately; a published segment implies a published
            // init, since no segment can be advertised before the init exists.
            initPublished: status.initPublished ?? (status.producedSegments > 0),
            signalingPublished: status.signalingPublished,
            ended: status.ended,
            failed: status.failed ?? !status.healthy)
    }

    /// Stop polling and request release. Ordinary replacement remains best effort; AV→MPV fallback calls
    /// `quiescenceReceipt()` before this invalidation and will fail closed unless the exact remote receipt lands.
    func invalidate() {
        lock.lock()
        let already = invalidated
        invalidated = true
        let task = poller
        poller = nil
        lock.unlock()
        guard !already else { return }
        task?.cancel()
        _ = quiescenceReceipt()
    }

    /// A remote producer cannot be observed locally.  This receipt polls only the authenticated, generation-
    /// bound control acknowledgement; no HTTP 200 or listener cancellation is considered proof by itself.
    func quiescenceReceipt() -> VortXRemuxQuiescenceReceipt {
        lock.lock()
        if let teardownReceipt {
            lock.unlock()
            return teardownReceipt
        }
        let terminal = VortXRemuxProducerTerminalRelay()
        let receipt = VortXRemuxQuiescenceReceipt(terminal: terminal)
        teardownReceipt = receipt
        lock.unlock()
        Task.detached(priority: .userInitiated) { [engine, session] in
            guard await engine.closeAndAwaitReceipt(session) != nil else { return }
            terminal.fire()
        }
        return receipt
    }
}
#endif
