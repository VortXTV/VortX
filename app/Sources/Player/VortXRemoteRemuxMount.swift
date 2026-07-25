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

    /// Where the client's AVPlayer mounts. Composed against the address this client dialled, never against an
    /// address the host guessed about itself.
    let playlistURL: URL

    /// Whether the host granted full-timeline retention. When true the whole produced timeline is seekable and
    /// the client must NOT clamp backward seeks; when false a hosted session behaves exactly like a local one.
    let retainsFullTimeline: Bool

    private let session: VortXExternalEngine.OpenedSession
    private let engine: VortXExternalEngine
    private let onLost: @Sendable () -> Void

    private let lock = NSLock()
    private var latest: VortXEngineProtocol.SessionStatus?
    private var consecutiveFailures = 0
    private var invalidated = false
    private var poller: Task<Void, Never>?
    private var readyMarked = false

    private init(session: VortXExternalEngine.OpenedSession,
                 engine: VortXExternalEngine,
                 onLost: @escaping @Sendable () -> Void) {
        self.session = session
        self.engine = engine
        self.playlistURL = session.playlistURL
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
                     engine: VortXExternalEngine = .shared,
                     onLost: @escaping @Sendable () -> Void) async -> VortXRemoteRemuxMount? {
        guard let opened = await engine.openSession(
            input: input, headers: headers, mode: mode,
            startAtSeconds: max(0, startAtSeconds)) else { return nil }
        return VortXRemoteRemuxMount(session: opened, engine: engine, onLost: onLost)
    }

    /// Begin polling. Mirrors `VortXRemuxHLSServer.start()` in that the caller invokes it once the mount is
    /// about to be used; the host has already begun producing the moment the session was created.
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
        let decision = VortXEngineHostPolicy.failover(
            consecutiveControlFailures: failures,
            hostReportsHealthy: status?.healthy)
        guard decision == .failOverToDevice else { return }
        DiagnosticsLog.log(
            "engine",
            "host session lost (failures=\(failures) reportedHealthy=\(String(describing: status?.healthy))) -> falling back on-device")
        VXProbe.log("dv", "external engine mount lost -> on-device remount at current position")
        invalidate()
        onLost()
    }

    /// Wait, bounded, for the host to publish classify signalling.
    ///
    /// The client needs this BEFORE it attaches an item, because on tvOS the Dolby Vision panel must be switched
    /// before the AVPlayerItem is assigned. Bounded and fail-open: on timeout the item is attached anyway and
    /// playback proceeds without the switch, which is the same outcome the on-device lane produces when its own
    /// switch request is refused.
    func awaitSignalling(timeoutSeconds: Double = 12) async -> VortXEngineProtocol.SessionStatus? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline, !isInvalidated {
            if let status = await engine.status(session) {
                lock.lock(); latest = status; consecutiveFailures = 0; lock.unlock()
                if status.signalingPublished { return status }
                if !status.healthy { return nil }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
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
            initPublished: status.producedSegments > 0,
            signalingPublished: status.signalingPublished,
            ended: status.ended,
            failed: !status.healthy)
    }

    /// Stop polling and tell the host to release the session. Idempotent, and best-effort on the wire: a host
    /// reaps an abandoned session on its own timer, so a client that dies costs it a minute of producer time
    /// rather than leaking one.
    func invalidate() {
        lock.lock()
        let already = invalidated
        invalidated = true
        let task = poller
        poller = nil
        lock.unlock()
        guard !already else { return }
        task?.cancel()
        engine.close(session)
    }
}
#endif
