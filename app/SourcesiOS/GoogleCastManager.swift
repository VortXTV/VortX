#if os(iOS) && !CINEMA_UI_SMOKE_RENDERER
import Foundation
import Combine
import UIKit
@preconcurrency import GoogleCast

/// Real SDK adapter, main-thread confined. Never adopts an arbitrary resumed session and never loads a
/// URL until the user presses Cast. The presented player remains the account/source/lifetime owner.
@MainActor final class GoogleCastManager: NSObject, ObservableObject, @preconcurrency GCKSessionManagerListener,
                                            @preconcurrency GCKRemoteMediaClientListener, @preconcurrency GCKRequestDelegate {
    static let shared = GoogleCastManager()
    private override init() { super.init() }
    struct Item {
        let owner: UUID
        let url: URL
        let title: String
        let position: Double
        let duration: Double
        let paused: Bool
        let torrent: Bool
        let selectedServer: URL?
        let nativeBase: URL?
        let isCurrent: () -> Bool
        let takeOver: () -> Void
        let progress: (Double, Double) -> Void
        let returnLocal: (Double, Bool) -> Void
    }
    struct State {
        var owned = false
        var connecting = false
        var suspended = false
        var paused = false
        var position: Double = 0
        var duration: Double = 0
        var device = "Google Cast"
        var message: String?
    }
    @Published private(set) var state = State()
    private var item: Item?
    private var policy = GoogleCastPlaybackPolicy()
    private var client: GCKRemoteMediaClient?
    private var bindingGeneration = UUID()
    private var loadRequest: GCKRequest?
    private var loadRequestBinding: UUID?
    private var loadPauseGeneration: UInt64?
    private var transportRequest: GCKRequest?
    private var transportRequestBinding: UUID?
    private var transportPauseGeneration: UInt64?
    private var statusSequence: UInt64 = 0
    private var pauseAckStatusSequence: UInt64?
    private var relay: CastTorrentRelay?
    private var preparation: Task<Void, Never>?
    private var clock: Timer?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private weak var boundSession: GCKCastSession?
    private weak var pendingSession: GCKSession?
    private weak var resumeCandidate: GCKCastSession?
    private var pendingLocalReturn: (() -> Void)?
    private var attached = false
    private var loadIssued = false
    private var receivedPlayableState = false
    private var generation = UUID()
    private var seekingUntil: Date?
    private var progressAt = Date.distantPast
    private var loadDeadline: Date?
    private struct RetiredLoad {
        let session: GCKCastSession
        let client: GCKRemoteMediaClient
        let owner: UUID
        let expires: Date
        var nextStopAttempt = Date.distantPast
    }
    private var retiredLoads: [UUID: RetiredLoad] = [:]

    /// Called once during iOS launch before the first button/session manager is touched. Compiling iOS
    /// requires GoogleCast; there is deliberately no canImport/no-op fallback hiding a missing dependency.
    static func configure() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        // Do not install GCKLogger: its messages can contain private stream URLs and capability tokens.
    }
    func attach() {
        guard !attached else { return }; attached = true
        GCKCastContext.sharedInstance().sessionManager.add(self)
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.relay != nil else { return }
                // The native server stops in background. Revoke the relay and stop remote playback; iOS
                // background execution is not a promise that a phone-owned torrent can keep streaming.
                self.finish(resumeLocal: true, stopReceiver: true,
                            message: "Phone-hosted Cast stopped when VortX entered the background. Keep VortX open or choose a LAN/debrid source.")
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let callback = self.pendingLocalReturn; self.pendingLocalReturn = nil; callback?()
            }
        }
        if clock == nil { clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        } }
    }
    func retire() {
        pendingLocalReturn = nil
        finish(resumeLocal: false, stopReceiver: true, message: nil)
    }
    func detach() {
        retire()
        if attached { GCKCastContext.sharedInstance().sessionManager.remove(self) }
        attached = false
        if retiredLoads.isEmpty { clock?.invalidate(); clock = nil }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }
    func dismissMessage() { state.message = nil }

    func cast(_ item: Item) {
        guard item.isCurrent() else { return }
        guard retiredLoads.count < 8 else { state.message = "Waiting for the previous receiver load to stop. Try Cast again shortly."; return }
        pendingLocalReturn = nil
        finish(resumeLocal: false, stopReceiver: true, message: nil)
        self.item = item; generation = UUID()
        let generation = generation
        state.connecting = true
        loadDeadline = Date().addingTimeInterval(60)
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let probe = CastMediaProbe(selectedServer: item.selectedServer, torrent: item.torrent,
                                           localTorrentBase: item.nativeBase)
                var (url, type) = try await probe.prepare(item.url)
                try Task.checkCancellation()
                guard self.generation == generation, item.isCurrent() else { return }
                if let nativeBase = item.nativeBase {
                    let relay = try CastTorrentRelay(source: url, nativeBase: nativeBase)
                    self.relay = relay
                    url = try await relay.start(); type = "video/mp4"
                    try Task.checkCancellation()
                    guard self.generation == generation, item.isCurrent() else { relay.stop(); return }
                }
                self.preparedURL = url; self.preparedType = type
                if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
                    self.bind(session); self.loadExplicitItem()
                }
                // The supplied GCKUICastButton already owns the permission/device picker action.
                // If it is still choosing, didStart binds the session once selection completes. If
                // selection finished before preflight, currentCastSession above loads it now.
            } catch is CancellationError {
                if self.generation == generation { self.finish(resumeLocal: false, stopReceiver: false, message: nil) }
            } catch {
                guard self.generation == generation else { return }
                // Fixed user messages only. NSError descriptions/URLs can reveal a debrid capability.
                let message = (error as? CastMediaProbe.Failure)?.errorDescription ?? "Google Cast could not prepare this source. Check Wi-Fi or choose another source."
                self.finish(resumeLocal: false, stopReceiver: false, message: message)
            }
        }
    }
    private var preparedURL: URL?
    private var preparedType: String?
    private func bind(_ session: GCKCastSession) {
        // Identical SDK objects can reconnect. Their old failure callbacks still belong to
        // the preceding binding, while successful ACKs retain their existing pause-generation fence.
        bindingGeneration = UUID()
        pendingSession = nil; resumeCandidate = nil
        policy.resume()
        if client !== session.remoteMediaClient {
            if let client, !retiredLoads.values.contains(where: { $0.client === client }) { client.remove(self) }
            client = session.remoteMediaClient
            if let client, !retiredLoads.values.contains(where: { $0.client === client }) { client.add(self) }
        }
        boundSession = session
        state.device = session.device.friendlyName ?? "Google Cast"
    }
    private func loadExplicitItem() {
        guard !loadIssued, let item, item.isCurrent(), let url = preparedURL, let type = preparedType, let client else { return }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)
        // No artwork/subtitle URLs are implicitly exported; each can contain separate private or local data.
        let media = GCKMediaInformationBuilder(contentURL: url)
        media.streamType = .buffered; media.contentType = type; media.metadata = metadata
        media.customData = ["vortxLoad": item.owner.uuidString]
        let options = GCKMediaLoadOptions()
        options.playPosition = item.position.isFinite ? min(604800, max(0, item.position)) : 0
        options.autoplay = !item.paused
        policy.begin(owner: item.owner, position: options.playPosition, duration: item.duration)
        loadPauseGeneration = policy.requestPaused(item.paused)
        state.position = policy.confirmedPosition; state.duration = policy.duration; state.paused = item.paused
        loadIssued = true
        let requestBinding = bindingGeneration
        let request = client.loadMedia(media.build(), with: options)
        loadRequest = request; loadRequestBinding = requestBinding; request.delegate = self
        // A matching receiver status, rather than an optimistic load call, pauses the local engine.
    }
    func togglePause() {
        guard state.owned, item?.isCurrent() == true else { return }
        setPaused(!(policy.pendingPaused ?? state.paused))
    }
    func setPaused(_ paused: Bool) {
        guard let client = currentCommandClient() else { return }
        transportPauseGeneration = policy.requestPaused(paused)
        pauseAckStatusSequence = nil
        transportRequest?.delegate = nil
        let requestBinding = bindingGeneration
        transportRequest = paused ? client.pause() : client.play()
        transportRequestBinding = requestBinding
        transportRequest?.delegate = self
    }
    func seek(to position: Double) {
        guard let client = currentCommandClient(), policy.seek(position) else { return }
        let options = GCKMediaSeekOptions(); options.interval = policy.resumePosition
        client.seek(with: options)
        seekingUntil = Date().addingTimeInterval(15)
        // Do not persist the requested target as observed receiver progress.
    }
    private func currentCommandClient() -> GCKRemoteMediaClient? {
        guard state.owned, let item, item.isCurrent(), let session = boundSession,
              let client, let status = client.mediaStatus,
              [.playing, .paused, .buffering].contains(status.playerState),
              policy.permitsReceiverCommand(
                echoedOwner: (status.mediaInformation?.customData as? [String: Any])?["vortxLoad"] as? String,
                onCurrentSession: session === GCKCastContext.sharedInstance().sessionManager.currentCastSession,
                onBoundClient: session.remoteMediaClient === client) else { return nil }
        return client
    }
    func stopCasting() { finish(resumeLocal: true, stopReceiver: true, message: nil) }
    private func finishExpiredReconnect(at uptime: TimeInterval) -> Bool {
        guard policy.reconnectExpired(at: uptime) else { return false }
        finish(resumeLocal: true, stopReceiver: false,
               message: "The resumed receiver did not confirm this video. Continuing locally.")
        return true
    }
    @discardableResult private func bindResumedCandidate(at uptime: TimeInterval) -> Bool {
        guard let item, item.isCurrent(), let candidate = resumeCandidate,
              let candidateClient = candidate.remoteMediaClient,
              policy.permitsReconnect(session: candidate, client: candidateClient,
                echoedOwner: (candidateClient.mediaStatus?.mediaInformation?.customData as? [String: Any])?["vortxLoad"] as? String,
                onCurrentSession: candidate === GCKCastContext.sharedInstance().sessionManager.currentCastSession,
                onCurrentClient: candidate.remoteMediaClient === candidateClient, at: uptime) else { return false }
        bind(candidate); state.suspended = false
        return true
    }
    private func tick() {
        observeRetiredLoads()
        guard let item else { return }
        guard item.isCurrent() else { retire(); return }
        let uptime = ProcessInfo.processInfo.systemUptime
        // Expiry wins even when a matching status arrives on this same tick. Weak candidate loss
        // and repeated callbacks cannot extend the policy's original monotonic attempt.
        if finishExpiredReconnect(at: uptime) { return }
        bindResumedCandidate(at: uptime)
        if !receivedPlayableState, let deadline = loadDeadline, Date() >= deadline {
            finish(resumeLocal: true, stopReceiver: true, message: "Google Cast did not start playback. Check the receiver and source format, then tap Cast to try again.")
            return
        }
        if let deadline = seekingUntil, Date() >= deadline, policy.pendingSeek != nil {
            finish(resumeLocal: true, stopReceiver: true,
                   message: "The receiver did not confirm that seek. Continuing locally at your requested position.")
            return
        }
        observeStatus()
    }
    private func observeStatus(freshStatus: Bool = false) {
        guard loadIssued, let item, item.isCurrent(), let status = client?.mediaStatus else { return }
        let data = status.mediaInformation?.customData as? [String: Any]
        guard data?["vortxLoad"] as? String == item.owner.uuidString else {
            if state.owned {
                // Park this local video at our last accepted Cast position without interrupting
                // the other sender or starting a second player automatically.
                finish(resumeLocal: true, stopReceiver: false,
                       message: "The receiver is now playing different media.", playLocally: false)
            }
            return
        }
        if status.playerState == .idle {
            // EOF is not translated into the local player's completion/episode-advance path without the
            // existing asset/dwell/completion evidence. Save the last confirmed remote point, then return.
            if state.owned { finish(resumeLocal: true, stopReceiver: false, message: nil) }
            return
        }
        guard [.playing, .paused, .buffering].contains(status.playerState),
              !state.suspended, let client else { return }
        if !state.owned {
            state.owned = true; state.connecting = false
            item.takeOver()
        }
        if status.playerState == .playing || status.playerState == .paused {
            receivedPlayableState = true; loadDeadline = nil
            state.paused = status.playerState == .paused
            policy.observePaused(state.paused, freshAfterAcknowledgement:
                freshStatus && pauseAckStatusSequence.map { statusSequence > $0 } == true)
        }
        if status.playerState != .buffering, policy.sample(owner: item.owner, position: client.approximateStreamPosition(),
                         duration: status.mediaInformation?.streamDuration ?? 0) {
            state.position = policy.confirmedPosition; state.duration = policy.duration
            if policy.pendingSeek == nil { seekingUntil = nil }
            if Date().timeIntervalSince(progressAt) >= 5 {
                progressAt = Date(); item.progress(policy.confirmedPosition, policy.duration)
            }
        }
    }
    private func finish(resumeLocal: Bool, stopReceiver: Bool, message: String?, playLocally: Bool? = nil) {
        let oldItem = item
        let owned = state.owned
        let returnPosition = policy.resumePosition
        let returnPlaying = playLocally ?? !(policy.pendingPaused ?? state.paused)
        let currentSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        let echoedOwner = (client?.mediaStatus?.mediaInformation?.customData as? [String: Any])?["vortxLoad"] as? String
        let mayStopReceiver = loadIssued && boundSession === currentSession && echoedOwner == oldItem?.owner.uuidString
        // Before a receiver echoes our load, cancel the local request. A session whose media has been
        // replaced by another sender never grants us authority to stop that sender's new media.
        generation = UUID(); preparation?.cancel(); preparation = nil
        relay?.stop(); relay = nil
        // Canceling a sender GCKRequest is not a remote LOAD cancellation guarantee. Retain a bounded,
        // session-and-UUID-scoped observer for an unacknowledged direct load; a late echo is stopped only
        // through that exact session's client. It must never stop replacement media from another sender.
        let retirementSession = resumeCandidate ?? boundSession
        let retirementClient = resumeCandidate?.remoteMediaClient ?? client
        if stopReceiver, loadIssued, (!owned && !mayStopReceiver) || resumeCandidate != nil,
           let oldItem, let retirementSession, let retirementClient {
            if client !== retirementClient, !retiredLoads.values.contains(where: { $0.client === retirementClient }) { retirementClient.add(self) }
            retiredLoads[oldItem.owner] = RetiredLoad(session: retirementSession, client: retirementClient,
                                                      owner: oldItem.owner, expires: Date().addingTimeInterval(120))
        }
        if let client, !retiredLoads.values.contains(where: { $0.client === client }) { client.remove(self) }
        client = nil
        retireRequestCallbacks()
        boundSession = nil; pendingSession = nil; resumeCandidate = nil
        item = nil; preparedURL = nil; preparedType = nil; loadIssued = false; receivedPlayableState = false; seekingUntil = nil
        loadDeadline = nil
        policy.retire(); state = State(message: message)
        if stopReceiver, mayStopReceiver { GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true) }
        guard let oldItem, owned, oldItem.isCurrent() else { return }
        if resumeLocal {
            let callback = { if oldItem.isCurrent() { oldItem.returnLocal(returnPosition, returnPlaying) } }
            if UIApplication.shared.applicationState == .active { callback() }
            else { pendingLocalReturn = callback }
        }
    }

    private func retireRequestCallbacks() {
        let previousLoad = loadRequest, previousTransport = transportRequest
        // Revoke identities before SDK cancellation can deliver an already queued callback.
        loadRequest = nil; loadRequestBinding = nil
        transportRequest = nil; transportRequestBinding = nil
        loadPauseGeneration = nil; transportPauseGeneration = nil; pauseAckStatusSequence = nil
        previousLoad?.delegate = nil; previousTransport?.delegate = nil
        previousLoad?.cancel()
    }
    func requestDidComplete(_ request: GCKRequest) {
        if loadRequest === request {
            loadRequest = nil; loadRequestBinding = nil
            if let generation = loadPauseGeneration, policy.acknowledgePause(generation: generation) { pauseAckStatusSequence = statusSequence }
            loadPauseGeneration = nil
            observeStatus()
        } else if transportRequest === request {
            if let generation = transportPauseGeneration, policy.acknowledgePause(generation: generation) { pauseAckStatusSequence = statusSequence }
            transportRequest = nil; transportRequestBinding = nil; transportPauseGeneration = nil
        }
    }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        let currentLoad = loadRequest === request && loadRequestBinding == bindingGeneration
        let currentTransport = transportRequest === request && transportRequestBinding == bindingGeneration
        guard !policy.suspended, currentLoad || currentTransport else { return }
        finish(resumeLocal: true, stopReceiver: true,
               message: "The receiver could not play this source. Choose a compatible SDR MP4 or HLS source; receiver codec support varies.")
    }
    private func observeRetiredLoads() {
        for (key, var retired) in Array(retiredLoads) {
            let status = retired.client.mediaStatus
            let owner = (status?.mediaInformation?.customData as? [String: Any])?["vortxLoad"] as? String
            if Date() >= retired.expires || owner == retired.owner.uuidString && status?.playerState == .idle {
                retiredLoads.removeValue(forKey: key)
                if client !== retired.client, !retiredLoads.values.contains(where: { $0.client === retired.client }) { retired.client.remove(self) }
            } else if owner == retired.owner.uuidString, Date() >= retired.nextStopAttempt {
                retired.client.stop()
                retired.nextStopAttempt = Date().addingTimeInterval(5)
                retiredLoads[key] = retired
            }
        }
        if !attached, retiredLoads.isEmpty { clock?.invalidate(); clock = nil }
    }
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        observeRetiredLoads()
        if self.client === client { statusSequence &+= 1; observeStatus(freshStatus: true) }
    }
    func sessionManager(_ sessionManager: GCKSessionManager, willStart session: GCKSession) {
        guard item?.isCurrent() == true, preparedURL != nil, !loadIssued else { return }
        pendingSession = session
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        guard !loadIssued, let session = session as? GCKCastSession, session === sessionManager.currentCastSession,
              pendingSession == nil || pendingSession === session, item?.isCurrent() == true else { return }
        bind(session); loadExplicitItem()
    }
    func sessionManager(_ sessionManager: GCKSessionManager, willResume session: GCKSession) {
        guard loadIssued, let session = session as? GCKCastSession, item?.isCurrent() == true else { return }
        // This is an actual GCKSessionManagerListener callback. Tracking the attempt grants no media
        // authority: didResume readiness and the echoed load UUID are both required before bind.
        resumeCandidate = session
        state.suspended = true; policy.suspend(at: ProcessInfo.processInfo.systemUptime)
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKSession) {
        guard loadIssued, let session = session as? GCKCastSession, session === sessionManager.currentCastSession,
              let item, item.isCurrent() else { return }
        let resumedClient = session.remoteMediaClient
        let echoedOwner = (resumedClient?.mediaStatus?.mediaInformation?.customData as? [String: Any])?["vortxLoad"] as? String
        if state.owned, !policy.suspended, session === boundSession, resumedClient === client,
           echoedOwner == item.owner.uuidString {
            // A duplicate completion for the already-bound load must not reset a newer request's
            // binding or acknowledgement. A real pending attempt or changed pair still takes the gate below.
            observeStatus()
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        resumeCandidate = session; state.suspended = true
        policy.didResume(session: session, client: session.remoteMediaClient, at: uptime)
        if finishExpiredReconnect(at: uptime) { return }
        if bindResumedCandidate(at: uptime) { observeStatus() }
        // Resume observes the matching receipt; it never reloads from a stale local playhead.
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason) {
        guard loadIssued, session === boundSession else { return }
        state.suspended = true; policy.suspend(at: ProcessInfo.processInfo.systemUptime)
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        if let candidate = resumeCandidate, candidate !== session, candidate === sessionManager.currentCastSession { return }
        guard session === boundSession || session === pendingSession || session === resumeCandidate else { return }
        finish(resumeLocal: true, stopReceiver: false,
               message: error == nil ? nil : "The Cast connection ended. Continuing locally.")
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        guard session === pendingSession else { return }
        finish(resumeLocal: false, stopReceiver: false, message: "Google Cast could not connect. Check that both devices use the same Wi-Fi.")
    }
}
#endif
