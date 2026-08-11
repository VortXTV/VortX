#if os(iOS) || os(tvOS) || os(macOS)
import Foundation

/// A transport-only next-episode remux. It owns no AVPlayerItem, AVPlayer, layer or visual decoder. The exact
/// owner and source identity can consume it once; every rejection retires its listener, producer and spool.
final class VortXPreparedRemuxHandle: @unchecked Sendable {
    /// Long enough to remain queued behind a full current episode, but finite so an abandoned preload cannot
    /// retain a listener forever if its caller loses cancellation ownership.
    private static let readinessTimeoutSeconds: Double = 3 * 60 * 60

    struct ReadinessReceipt: Equatable, Sendable {
        let segmentCount: Int
        let producedBytes: Int
        let waitMilliseconds: Int
    }

    struct AdoptedTransport {
        let server: VortXRemuxHLSServer
        let playlistURL: URL
    }

    enum AdoptionOutcome {
        case adopted(AdoptedTransport)
        case rejected(VortXPreparedRemuxAdoptionState.Rejection)
    }

    let identity: VortXPreparedRemuxIdentity
    let readinessReceipt: ReadinessReceipt
    private let server: VortXRemuxHLSServer
    private let playlistURL: URL
    private let lock = NSLock()
    private var adoptionState = VortXPreparedRemuxAdoptionState()

    private init(identity: VortXPreparedRemuxIdentity,
                 readinessReceipt: ReadinessReceipt,
                 server: VortXRemuxHLSServer,
                 playlistURL: URL) {
        self.identity = identity
        self.readinessReceipt = readinessReceipt
        self.server = server
        self.playlistURL = playlistURL
    }

    static func prepare(
        input: URL,
        headers: [String: String]?,
        mode: VortXPreparedRemuxMode,
        startAtSeconds: Double = 0,
        ownerIdentity: VortXPreparedRemuxOwnerIdentity,
        selectedAudioStreamIndex: Int? = nil,
        preferredAudioLanguages: [String]? = nil,
        audioRejectTerms: [String]? = nil
    ) async -> VortXPreparedRemuxHandle? {
        guard !Task.isCancelled else { return nil }
        let identity = VortXPreparedRemuxIdentity(
            owner: ownerIdentity,
            input: input,
            headers: headers,
            mode: mode,
            startAtSeconds: startAtSeconds,
            selectedAudioStreamIndex: selectedAudioStreamIndex,
            preferredAudioLanguages: preferredAudioLanguages,
            audioRejectTerms: audioRejectTerms)
        guard let mounted = VortXRemuxHLSServer.make(
            input: input,
            headers: headers,
            mode: mode == .plain ? .plain : .dolbyVision,
            startAtSeconds: identity.startAtSeconds,
            selectedAudioStreamIndex: selectedAudioStreamIndex,
            preferredAudioLanguages: preferredAudioLanguages,
            audioRejectTerms: audioRejectTerms
        ) else {
            DiagnosticsLog.log("binge", "prepared-remux phase=rejected reason=create-failed")
            return nil
        }
        mounted.server.beginPreparation()
        let readiness = await mounted.server.awaitPreparedReadiness(
            timeoutSeconds: readinessTimeoutSeconds)
        guard case .ready(let segmentCount, let producedBytes, let waitMilliseconds) = readiness,
              !Task.isCancelled else {
            let reason: String
            if Task.isCancelled {
                reason = "preparation-task-cancelled"
            } else if case .rejected(let rejection) = readiness {
                reason = rejection
            } else {
                reason = "preparation-not-ready"
            }
            DiagnosticsLog.log("binge", "prepared-remux phase=rejected reason=\(reason)")
            mounted.server.invalidate()
            return nil
        }
        return VortXPreparedRemuxHandle(
            identity: identity,
            readinessReceipt: ReadinessReceipt(
                segmentCount: segmentCount,
                producedBytes: producedBytes,
                waitMilliseconds: waitMilliseconds),
            server: mounted.server,
            playlistURL: mounted.playlistURL)
    }

    func adopt(
        expectedIdentity: VortXPreparedRemuxIdentity,
        onStartupTimeout: @escaping @Sendable (VortXRemuxHLSServer) -> Void
    ) -> AdoptionOutcome {
        var shouldCleanup = false
        let rejection: VortXPreparedRemuxAdoptionState.Rejection?
        lock.lock()
        var candidate = adoptionState
        let decision = candidate.consume(
            expected: expectedIdentity,
            actual: identity,
            ready: server.isPreparedForAdoption)
        switch decision {
        case .adopt:
            if server.adoptPrepared(onStartupTimeout: onStartupTimeout) {
                adoptionState = candidate
                lock.unlock()
                return .adopted(AdoptedTransport(server: server, playlistURL: playlistURL))
            }
            shouldCleanup = adoptionState.retire()
            rejection = .notReady
        case .coldLoad(let reason, let cleanup):
            adoptionState = candidate
            shouldCleanup = cleanup
            rejection = reason
        }
        lock.unlock()
        if shouldCleanup { server.invalidate() }
        let reason = rejection ?? .alreadyConsumed
        DiagnosticsLog.log("binge", "prepared-remux phase=rejected reason=\(reason)")
        return .rejected(reason)
    }

    func abandon(reason: String = "stale-owner") {
        lock.lock()
        let shouldCleanup = adoptionState.retire()
        lock.unlock()
        guard shouldCleanup else { return }
        DiagnosticsLog.log("binge", "prepared-remux phase=rejected reason=\(reason)")
        server.invalidate()
    }

    deinit {
        abandon(reason: "handle-released")
    }
}

/// The ready transport plus the immutable owner minted by the preparation request. Views retain this value
/// beside their exact prepared episode and reconstruct the expected owner at admission; the engine still
/// rechecks URL, normalized headers, remux mode, resume origin and audio preferences before adoption.
struct VortXPreparedRemuxAttachment: @unchecked Sendable {
    let handle: VortXPreparedRemuxHandle
    let ownerIdentity: VortXPreparedRemuxOwnerIdentity

    func abandon(reason: String) {
        handle.abandon(reason: reason)
    }
}
#endif
