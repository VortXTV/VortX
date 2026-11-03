#if VORTX_AETHER_ENGINE
import Foundation
#if os(iOS)
import UIKit
#endif

/// The AetherEngine lane behind the shared `PlayerEngine` contract. Property changes reach the chrome with
/// the same keys the libmpv controller emits, so `handleProperty()` runs unchanged against this engine.
/// AetherEngine itself lives in VortXAetherKit, loaded at runtime; this file only sees `VortXAetherBridging`.
@MainActor
final class AetherEngineController: NSObject, PlayerEngine {
    /// Nil when the engine could not start on this device; the first load then reports `startError`, which the
    /// chrome answers by handing the source to libmpv.
    let player: (any VortXAetherBridging)?
    private let startError: String?
    weak var playDelegate: MPVPlayerDelegate?
    /// Styled primary text cues. AetherKit owns authored bitmap and independent secondary presentation.
    let subtitleOverlay = SubtitleOverlayView()

    private(set) var activeLoadToken: PlayerLoadToken?
    private var resumeOriginSeconds = 0.0
    private var loadedResumeOriginSeconds: Double?
    private var settledProgressPosition: Double?
    private var seekRevision = 0
    private var awaitingSeekCompletion = false
    private var speed = 1.0
    private var subtitleDelay = 0.0
    private var userVolume = 100.0
    private var isMuted = false
    private var lastPaused: Bool?
    /// Position ticks count as settled only once this load has shown a frame and no seek is running. The
    /// engine's clock can sit on a resume or seek target before any frame, and the chrome treats a settled
    /// position above zero as "playback started", which retires its no-frame watchdogs.
    private var hasFirstFrame = false
    private var lastSeekable: Bool?
    /// One-shot: the next load mounts paused (the surface was asked to start paused).
    var holdsNextLoadPaused = false
    /// The local copy of the selected add-on subtitle, and the request allowed to replace it.
    private var sidecarFile: URL?
    private var sidecarFiles: Set<URL> = []
    private var sidecarRevision: UInt64 = 0
    private var localSubtitleTask: Task<Void, Never>?
    private var contributionLoad: SubtitlePoolClient.ContributionLoad?
    private var subtitlePublications: [Bool: AetherSubtitlePublication] = [:]
    private struct ExternalRecord {
        let source: PlayerLocalSubtitleSource
        let title: String
        let lang: String
        let owner: PlayerSubtitleAlignmentOwner?
        let credential: CredentialScopeRegistry.Capture
        let epoch: UUID
        let lifetime: SubtitlePoolClient.ContributionLoad
    }
    private var externalRecords: [Int: ExternalRecord] = [:]
    var contentIsDolbyVision = false
    var isFullPlayerPresentation = false
    private(set) var videoSizeMode = "fit"

    override init() {
        do {
            player = try AetherEngineLoader.makePlayer()
            startError = nil
        } catch {
            player = nil
            startError = error.localizedDescription
        }
        super.init()
        wire()
    }

    private func emit(_ name: String, _ data: Any?) {
        guard let token = activeLoadToken else { return }
        playDelegate?.propertyChange(propertyName: name, data: data, loadToken: token)
    }

    private func wire() {
        guard let player else { return }
        player.onState = { [weak self] (state: VortXAetherBridgeState, message: String?) in
            guard let self else { return }
            switch state {
            case .playing: emitPause(false)
            case .paused: emitPause(true)
            case .ended: emit(MPVProperty.endFileEof, nil)
            case .failed: emit(MPVProperty.endFileError, message ?? "AetherEngine stopped")
            case .idle, .loading, .seeking: break
            }
        }
        player.onFirstFrame = { [weak self] in self?.hasFirstFrame = true }
        player.onTime = { [weak self] (seconds: Double) in self?.publishTime(seconds) }
        player.onDuration = { [weak self] (seconds: Double) in
            guard let self, seconds.isFinite, seconds > 0 else { return }
            emit(MPVProperty.duration, seconds)
            emitSeekability()
        }
        player.onBuffering = { [weak self] (buffering: Bool) in self?.emit(MPVProperty.pausedForCache, buffering) }
        player.onBufferedPosition = { [weak self] (seconds: Double) in
            guard seconds.isFinite else { return }
            self?.emit(MPVProperty.demuxerCacheTime, seconds)
        }
        player.onTracksChanged = { [weak self] in self?.emit(MPVProperty.trackList, nil) }
        player.onSubtitleText = { [weak self] (text: String?) in
            guard let self, activeLoadToken != nil, subtitlePublications[false]?.isRevoked != true else { return }
            subtitleOverlay.setText(text)
        }
    }

    private func publishTime(_ seconds: Double) {
        guard let token = activeLoadToken, seconds.isFinite, seconds >= 0 else { return }
        emitSeekability()
        let settled = hasFirstFrame && !awaitingSeekCompletion && player?.positionIsSettled == true
        if settled { settledProgressPosition = seconds }
        playDelegate?.propertyChange(propertyName: MPVProperty.timePos,
            data: PlayerTimePositionEvent(seconds: seconds, loadToken: token, positionSettled: settled),
            loadToken: token)
    }

    private func emitSeekability() {
        guard activeLoadToken != nil else { return }
        let seekable = player?.canSeek ?? false
        guard seekable != lastSeekable else { return }
        lastSeekable = seekable
        emit(MPVProperty.seekable, seekable)
    }

    private func emitPause(_ paused: Bool) {
        guard paused != lastPaused else { return }
        lastPaused = paused
        emit(MPVProperty.pause, paused)
    }

    // MARK: Loading and transport

    @discardableResult
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool, audioSidecar: URL?,
                  reusing loadToken: PlayerLoadToken?) -> PlayerLoadToken {
        let token = loadToken ?? PlayerLoadToken()
        // Configuration belongs to this issue, including an issue that cannot start.
        let start = !live && resumeOriginSeconds > 0 ? NSNumber(value: resumeOriginSeconds) : nil
        resumeOriginSeconds = 0
        let autoplay = !holdsNextLoadPaused
        holdsNextLoadPaused = false
        // A retry may retain its logical token, but never an older subtitle request.
        retireAllSubtitlePublications()
        contributionLoad?.retire(); contributionLoad = nil
        localSubtitleTask?.cancel(); localSubtitleTask = nil
        activeLoadToken = nil
        sidecarRevision &+= 1
        player?.cancelLoad()
        replaceSidecarFile(with: nil); externalRecords.removeAll()
        activeLoadToken = token
        loadedResumeOriginSeconds = nil
        settledProgressPosition = nil
        seekRevision &+= 1
        awaitingSeekCompletion = false
        contributionLoad = .init(token: token)
        lastPaused = nil
        hasFirstFrame = false
        lastSeekable = nil
        subtitleOverlay.setText(nil)
        guard let player else {
            // Reported on the next turn, after the surface finishes mounting, like any engine's own failure.
            let reason = startError ?? "AetherEngine could not start"
            Task { @MainActor [weak self] in
                guard let self, activeLoadToken == token else { return }
                emit(MPVProperty.endFileError, reason)
            }
            return token
        }
        guard audioSidecar == nil else {
            // A separate audio URL needs libmpv; report it so the chrome's failure handling can move on.
            emit(MPVProperty.endFileError, String(localized: "AetherEngine can't play a source with separate audio. Choose VortX Player for this source."))
            return token
        }
        loadedResumeOriginSeconds = start?.doubleValue ?? 0
        player.load(url: url, headers: headers, live: live, startPosition: start, autoplay: autoplay) { [weak self] (error: NSError?) in
            guard let self, activeLoadToken == token else { return }
            guard let error else {
                emitSeekability()
                self.player?.setRate(speed)
                return
            }
            if error.domain == VortXAetherBridgeErrorDomain, error.code == VortXAetherBridgeErrorCode.cancelled.rawValue {
                return
            }
            emit(MPVProperty.endFileError, error.localizedDescription)
        }
        return token
    }

    func invalidateLoadToken() {
        retireAllSubtitlePublications()
        contributionLoad?.retire(); contributionLoad = nil
        localSubtitleTask?.cancel(); localSubtitleTask = nil
        activeLoadToken = nil
        loadedResumeOriginSeconds = nil
        settledProgressPosition = nil
        seekRevision &+= 1
        awaitingSeekCompletion = false
        sidecarRevision &+= 1
        player?.cancelLoad()
        replaceSidecarFile(with: nil); externalRecords.removeAll()
        subtitleOverlay.setText(nil)
    }

    func configureResumeOrigin(seconds: Double) {
        resumeOriginSeconds = seconds.isFinite ? max(0, seconds) : 0
    }

    func ownsLoadResumeOrigin(seconds: Double) -> Bool {
        guard activeLoadToken != nil, seconds.isFinite, seconds >= 0 else { return false }
        return loadedResumeOriginSeconds == seconds
    }

    func admittedProgressPosition(_ requested: Double, owner: PlayerLoadToken?) -> Double? {
        guard let owner, owner == activeLoadToken else { return nil }
        return settledProgressPosition
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func togglePause() { lastPaused == true ? player?.play() : player?.pause() }
    func seek(to seconds: Double) {
        guard seconds.isFinite, let player, let token = activeLoadToken else { return }
        // Fence immediately, before the bridge's queued seek enters the engine. A preceding
        // clock publication cannot consume a manual seek's pending progress receipt.
        loadedResumeOriginSeconds = nil
        seekRevision &+= 1
        let revision = seekRevision
        awaitingSeekCompletion = true
        player.seek(to: max(0, seconds)) { [weak self] in
            Task { @MainActor [weak self] in
                // The wrapper settles its @Published mutation on the next actor turn.
                await Task.yield()
                guard let self, activeLoadToken == token, seekRevision == revision else { return }
                awaitingSeekCompletion = false
                // Completion alone is not landing: publishTime still requires the wrapper's
                // explicit outcome/readiness verdict; a stalled/superseded seek stays unsettled.
                publishTime(player.currentTime)
            }
        }
    }
    func seek(by seconds: Double) { seek(to: (player?.currentTime ?? 0) + seconds) }
    func setSpeed(_ speed: Double) {
        self.speed = speed
        player?.setRate(speed)
        emit(MPVProperty.speed, speed)
    }
    func stop() {
        retireAllSubtitlePublications()
        contributionLoad?.retire(); contributionLoad = nil
        localSubtitleTask?.cancel(); localSubtitleTask = nil
        // Retire callback authority before synchronous engine teardown can publish.
        activeLoadToken = nil
        sidecarRevision &+= 1
        player?.stop()
        hasFirstFrame = false
        loadedResumeOriginSeconds = nil
        settledProgressPosition = nil
        seekRevision &+= 1
        awaitingSeekCompletion = false
        resumeOriginSeconds = 0
        holdsNextLoadPaused = false
        replaceSidecarFile(with: nil); externalRecords.removeAll()
        subtitleOverlay.setText(nil)
    }

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        player?.setVideoSize(mode)
    }

    // MARK: Tracks and subtitles

    /// One engine track, read from the bridge's plain dictionary.
    private struct Track {
        let id: Int
        let title: String
        let language: String
        let codec: String
        let channels: Int
        let isForced: Bool

        init?(_ values: [String: Any]) {
            guard let id = values[VortXAetherBridgeTrackKey.id] as? Int else { return nil }
            self.id = id
            title = values[VortXAetherBridgeTrackKey.title] as? String ?? ""
            language = values[VortXAetherBridgeTrackKey.language] as? String ?? ""
            codec = values[VortXAetherBridgeTrackKey.codec] as? String ?? ""
            channels = values[VortXAetherBridgeTrackKey.channels] as? Int ?? 0
            isForced = values[VortXAetherBridgeTrackKey.isForced] as? Bool ?? false
        }

        var displayTitle: String {
            if !title.isEmpty { return title }
            if !language.isEmpty { return language }
            return codec.uppercased()
        }
    }

    private var audioTracks: [Track] { (player?.audioTracks ?? []).compactMap(Track.init) }
    private var subtitleTracks: [Track] { (player?.subtitleTracks ?? []).compactMap(Track.init) }

    func tracks(ofType type: String) -> [MPVTrack] {
        switch type {
        case "audio":
            let active = player?.activeAudioTrackID?.intValue
            return audioTracks.map { track in
                MPVTrack(id: track.id, type: "audio", title: track.displayTitle, lang: track.language,
                         selected: track.id == active, forced: track.isForced)
            }
        case "sub":
            let active = player?.activeSubtitleTrackID?.intValue
            return subtitleTracks.map { track in
                MPVTrack(id: track.id, type: "sub", title: track.displayTitle, lang: track.language,
                         selected: track.id == active, forced: track.isForced,
                         unavailableReason: track.codec.lowercased() == "xsub"
                            ? String(localized: "This subtitle format is unavailable in AetherEngine") : nil)
            }
        default:
            return []
        }
    }

    func setAudioTrack(_ id: Int) { player?.selectAudioTrack(id: id) }
    func setSubtitleTrack(_ id: Int) {
        let originalRecord = externalRecords[id]
        if id >= 0, id == secondarySubtitleID { retireSubtitlePublication(secondary: true); player?.clearSecondarySubtitle() }
        if let originalRecord { selectStoredExternal(originalRecord, secondary: false); return }
        guard id < 100_000 else { return } // Unknown native external ID grants no file-reopen authority.
        // A manual Off/embedded pick supersedes any still-downloading add-on file.
        retireSubtitlePublication(secondary: false)
        sidecarRevision &+= 1
        localSubtitleTask?.cancel(); localSubtitleTask = nil
        if id < 0 { player?.clearSubtitle() } else { player?.selectSubtitleTrack(id: id) }
    }
    var currentExternalSubtitle: (url: String, title: String, lang: String)? {
        guard let record = externalRecords[primarySubtitleID], record.source.permitsUse(),
              record.lifetime.isCurrent, CredentialScopeRegistry.shared.isCurrent(record.credential),
              LegacyWatchOwnership.applicationEpochIsCurrent(record.epoch) else { return nil }
        return (record.source.identityURL.absoluteString, record.title, record.lang)
    }
    var supportsSecondarySubtitles: Bool { player != nil }
    var primarySubtitleID: Int { player?.activeSubtitleTrackID?.intValue ?? -1 }
    var secondarySubtitleID: Int { player?.activeSecondarySubtitleTrackID?.intValue ?? -1 }
    func setSecondarySubtitleTrack(_ id: Int) {
        guard id < 0 || id != primarySubtitleID else { return }
        if let record = externalRecords[id] { selectStoredExternal(record, secondary: true); return }
        guard id < 100_000 else { return }
        retireSubtitlePublication(secondary: true)
        sidecarRevision &+= 1
        localSubtitleTask?.cancel(); localSubtitleTask = nil
        if id < 0 { player?.clearSecondarySubtitle() } else { player?.selectSecondarySubtitleTrack(id: id) }
    }
    var subtitleAlignmentRevision: UInt64? { activeLoadToken == nil ? nil : sidecarRevision }
    func captureSubtitleContributionLoad(for token: PlayerLoadToken) -> SubtitlePoolClient.ContributionLoad? {
        guard activeLoadToken == token, let original = contributionLoad,
              original.token == token, original.isCurrent else { return nil }
        return original
    }
    func cancelAutomaticSubtitleAlignment(ifRequestGeneration request: UInt64) {
        guard sidecarRevision == request else { return }
        sidecarRevision &+= 1
        localSubtitleTask?.cancel(); localSubtitleTask = nil
        player?.cancelSubtitlePreparation()
    }
    func selectLocalExternalSubtitleAutomatically(_ source: PlayerLocalSubtitleSource,
        title: String, lang: String, owner: PlayerSubtitleAlignmentOwner?,
        expectedLoad: PlayerLoadToken, expectedRevision: UInt64,
        completion: @escaping (PlayerExternalSubtitleSelectionResult) -> Void) -> UInt64? {
        selectLocalSubtitle(source, title: title, lang: lang, owner: owner, expectedLoad: expectedLoad,
            expectedRevision: expectedRevision, secondary: false, completion: completion)
    }
    private func selectStoredExternal(_ record: ExternalRecord, secondary: Bool) {
        guard record.source.permitsUse(), record.lifetime.isCurrent,
              CredentialScopeRegistry.shared.isCurrent(record.credential),
              LegacyWatchOwnership.applicationEpochIsCurrent(record.epoch),
              let load = activeLoadToken else { return }
        _ = selectLocalSubtitle(record.source, title: record.title, lang: record.lang, owner: record.owner,
            expectedLoad: load, expectedRevision: sidecarRevision, secondary: secondary) { _ in }
    }
    private func selectLocalSubtitle(_ source: PlayerLocalSubtitleSource,
        title: String, lang: String, owner: PlayerSubtitleAlignmentOwner?,
        expectedLoad: PlayerLoadToken, expectedRevision: UInt64, secondary: Bool,
        completion: @escaping (PlayerExternalSubtitleSelectionResult) -> Void) -> UInt64? {
        guard let player, source.permitsUse(), activeLoadToken == expectedLoad,
              sidecarRevision == expectedRevision,
              let lifetime = captureSubtitleContributionLoad(for: expectedLoad) else {
            completion(.superseded); return nil
        }
        retireSubtitlePublication(secondary: secondary)
        sidecarRevision &+= 1
        localSubtitleTask?.cancel()
        player.cancelSubtitlePreparation()
        let request = sidecarRevision
        let credential = CredentialScopeRegistry.shared.capture()
        guard let applicationEpoch = LegacyWatchOwnership.captureApplicationEpoch() else {
            completion(.superseded); return nil
        }
        localSubtitleTask = Task { @MainActor [weak self] in
            let prepared = await Task.detached(priority: .utility) { source.preparedNativeSubtitle() }.value
            guard let self, !Task.isCancelled, activeLoadToken == expectedLoad,
                  sidecarRevision == request, lifetime.isCurrent, source.permitsUse() else {
                completion(.superseded); return
            }
            guard self.sidecarFiles.count < 16, let prepared,
                  let file = Self.writeSidecar(prepared.data,
                    remote: URL(fileURLWithPath: "subtitle." + prepared.format)) else {
                completion(.failed); return
            }
            var effect: CredentialPublicationOutbox.SubtitleEffectLease?
            var commitWasAdmitted = false
            var committedTrackID: Int?
            let publication = AetherSubtitlePublication { [weak self] original in
                guard let self, self.subtitlePublications[secondary] === original else { return }
                self.subtitlePublications[secondary] = nil
                if self.sidecarRevision == request {
                    self.sidecarRevision &+= 1
                    self.localSubtitleTask?.cancel(); self.localSubtitleTask = nil
                    self.player?.cancelSubtitlePreparation()
                }
                guard commitWasAdmitted else { return }
                if let id = committedTrackID {
                    self.player?.removeExternalSubtitleTrack(id: id)
                    self.externalRecords[id] = nil
                }
                self.sidecarFiles.remove(file)
                try? FileManager.default.removeItem(at: file)
                // Removing the exact registered ID already clears its native channel. A generic
                // bridge clear here would cancel a newer preparation on the other channel.
                if !secondary { self.subtitleOverlay.setText(nil) }
            }
            self.subtitlePublications[secondary] = publication
            guard let epochObservation = LegacyWatchOwnership.observeSubtitleRendererRetirement(
                ifCurrent: applicationEpoch, retire: { _ = publication.revoke() }) else {
                publication.finishPreparation(); publication.close()
                try? FileManager.default.removeItem(at: file); completion(.superseded); return
            }
            publication.observeEpoch(epochObservation)
            if let owner {
                guard owner.account == credential, owner.applicationEpoch == applicationEpoch,
                      let admission = CredentialPublicationOutbox.tryBeginSubtitleEffect(owner.mount) else {
                    publication.finishPreparation(); publication.close()
                    try? FileManager.default.removeItem(at: file); completion(.superseded); return
                }
                let registration = CredentialPublicationOutbox.registerSubtitleRenderer(admission,
                    revoke: { publication.revoke() })
                let installed = registration.map(publication.install) ?? false
                CredentialPublicationOutbox.endSubtitleEffect(admission)
                guard installed, !publication.isRevoked else {
                    publication.finishPreparation(); publication.close()
                    try? FileManager.default.removeItem(at: file); completion(.superseded); return
                }
            }
            let permitsPreparation: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.activeLoadToken == expectedLoad && self.sidecarRevision == request
                    && lifetime.isCurrent && source.permitsUse() && !publication.isRevoked
                    && CredentialScopeRegistry.shared.isCurrent(credential)
                    && LegacyWatchOwnership.applicationEpochIsCurrent(applicationEpoch)
            }
            player.selectLocalSubtitle(url: file, title: title, lang: lang, secondary: secondary,
                permitsPreparation: permitsPreparation, permitsCommit: { [weak self] in
                guard let self else { return false }
                guard self.activeLoadToken == expectedLoad && self.sidecarRevision == request,
                      lifetime.isCurrent, source.permitsUse(), !publication.isRevoked,
                      CredentialScopeRegistry.shared.isCurrent(credential),
                      LegacyWatchOwnership.applicationEpochIsCurrent(applicationEpoch) else { return false }
                if let owner {
                    guard owner.account == credential, owner.applicationEpoch == applicationEpoch,
                          let lease = CredentialPublicationOutbox.tryBeginSubtitleEffect(owner.mount) else { return false }
                    effect = lease
                    guard !publication.isRevoked else {
                        effect = nil; CredentialPublicationOutbox.endSubtitleEffect(lease); return false
                    }
                }
                commitWasAdmitted = true
                return true
            }, committedTrack: { [weak self] id in
                guard let self else { return }
                committedTrackID = id
                self.replaceSidecarFile(with: file)
                self.externalRecords[id] = .init(source: source, title: title, lang: lang, owner: owner,
                    credential: credential, epoch: applicationEpoch, lifetime: lifetime)
            }, finishedCommit: {
                if let lease = effect { effect = nil; CredentialPublicationOutbox.endSubtitleEffect(lease) }
            }) { [weak self] success in
                // The underlying await has returned, so its prepared handle/decoder has retired.
                publication.finishPreparation()
                guard let self, self.activeLoadToken == expectedLoad,
                      self.sidecarRevision == request, lifetime.isCurrent, source.permitsUse(),
                      !publication.isRevoked, CredentialScopeRegistry.shared.isCurrent(credential),
                      LegacyWatchOwnership.applicationEpochIsCurrent(applicationEpoch) else {
                    publication.close()
                    try? FileManager.default.removeItem(at: file)
                    completion(.superseded); return
                }
                self.localSubtitleTask = nil
                if success {
                    completion(.selectedWithoutAlignment)
                } else {
                    publication.close()
                    try? FileManager.default.removeItem(at: file)
                    completion(.failed)
                }
            }
        }
        return request
    }
    private func retireSubtitlePublication(secondary: Bool) {
        let original = subtitlePublications[secondary]
        original?.close()
        if subtitlePublications[secondary] === original { subtitlePublications[secondary] = nil }
    }
    private func retireAllSubtitlePublications() {
        retireSubtitlePublication(secondary: false)
        retireSubtitlePublication(secondary: true)
    }
    /// Add-on subtitles download through the shared pinned transport, like the other lanes: HTTPS only, the
    /// connected address vetted, no redirects, size-capped. The engine opens only the local copy, never the
    /// add-on's URL, so its own fetcher never reaches an address the policy refused.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) {
        sidecarRevision &+= 1
        let revision = sidecarRevision
        guard let remote = URL(string: url), let token = activeLoadToken, player != nil else { completion?(false); return }
        let finish: @MainActor @Sendable (Bool) -> Void = { ok in completion?(ok) }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            let file = data.flatMap { Self.writeSidecar($0, remote: remote) }
            Task { @MainActor in
                guard let self, let file, self.activeLoadToken == token, self.sidecarRevision == revision else {
                    if let file { try? FileManager.default.removeItem(at: file) }
                    finish(false)
                    return
                }
                self.replaceSidecarFile(with: file)
                self.player?.selectSidecarSubtitle(url: file, headers: nil)
                finish(true)
            }
        }
    }

    private func replaceSidecarFile(with file: URL?) {
        // Native external track IDs remain selectable for this physical load. Keep their
        // authorized files until load retirement rather than deleting the preceding track's input.
        if let file { sidecarFiles.insert(file) }
        else {
            sidecarFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            sidecarFiles.removeAll()
        }
        sidecarFile = file
    }

    /// The fetched bytes as a temporary file the engine can open, keeping the add-on's extension when it
    /// names a subtitle format (the engine also probes the content).
    nonisolated private static func writeSidecar(_ data: Data, remote: URL) -> URL? {
        let known: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup"]
        let pathExtension = remote.pathExtension.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-subtitles", isDirectory: true)
        let file = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(known.contains(pathExtension) ? pathExtension : "srt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
    func setSubDelay(_ seconds: Double) {
        subtitleDelay = seconds
        player?.setSubtitleDelay(seconds)
    }
    func setAudioDelay(_ seconds: Double) { player?.setAudioDelay(seconds) }
    func applySubtitleStyle() { subtitleOverlay.applyStyle() }
    func currentSubDelaySeconds() -> Double { subtitleDelay }

    // MARK: Facts and diagnostics

    func mediaDurationSeconds() -> Double { activeLoadToken == nil ? 0 : (player?.duration ?? 0) }
    func chapters() -> [MPVChapter] {
        guard activeLoadToken != nil else { return [] }
        return (player?.mediaChapters ?? []).compactMap { values in
            guard let start = values["start"] as? Double, start.isFinite, start >= 0 else { return nil }
            return MPVChapter(title: values["title"] as? String ?? "", start: start)
        }
    }
    func containerFrameRate() -> Double {
        guard activeLoadToken != nil, let fps = player?.videoFrameRate?.doubleValue,
              fps.isFinite, fps > 0 else { return 0 }
        return fps
    }
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int) {
        guard activeLoadToken != nil else { return (0, 0, "", 0) }
        let active = player?.activeAudioTrackID?.intValue
        let audio = audioTracks.first { $0.id == active }
        return (player?.videoWidth ?? 0, player?.videoHeight ?? 0, audio?.codec ?? "", audio?.channels ?? 0)
    }
    func playbackMetadataFacts() -> PlaybackMetadataFacts {
        guard activeLoadToken != nil, let player else { return PlaybackMetadataFacts() }
        var facts = PlaybackMetadataFacts()
        facts.width = max(0, player.videoWidth)
        facts.height = max(0, player.videoHeight)
        facts.dynamicRange = PlaybackMetadataFacts.DynamicRange(rawValue: player.videoDynamicRange) ?? .unknown
        let selectedBefore = player.activeAudioTrackID?.intValue
        let audio = audioTracks.first { $0.id == selectedBefore }
        if let audio, PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: audio.id,
            beforeID: selectedBefore, afterID: player.activeAudioTrackID?.intValue) {
            facts.audioSelected = true
            facts.audioLanguage = audio.language
            facts.audioCodec = audio.codec
            facts.audioChannels = audio.channels
        }
        return facts
    }
    func playbackStats() -> [(String, String)] {
        guard let player else { return [("Engine", "AetherEngine (not started)")] }
        var rows: [(String, String)] = [("Engine", "AetherEngine"), ("Route", player.videoRoute),
                                        ("Video", player.videoFormat), ("Source video", player.sourceVideoFormat),
                                        ("Audio delivery", player.audioDelivery)]
        if let profile = player.sourceDolbyVisionProfile { rows.append(("Dolby Vision profile", profile.stringValue)) }
        if let decoder = player.videoDecoder { rows.append(("Video decoder", decoder)) }
        if let decoder = player.audioDecoder { rows.append(("Audio decoder", decoder)) }
        return rows
    }

    func setHardwareDecoding(_ on: Bool) {}
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) { completion(nil) }
    var hdrAvailable: Bool {
        guard activeLoadToken != nil, let player else { return false }
        return ["pq", "hlg", "dolbyVision"].contains(player.videoDynamicRange)
    }
    var playbackPositionSeconds: Double { player?.currentTime ?? 0 }

    func setVolume(_ volume0to100: Double) {
        userVolume = min(max(volume0to100, 0), 100)
        player?.volume = isMuted ? 0 : userVolume / 100
    }
    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.volume = muted ? 0 : userVolume / 100
    }

    #if os(iOS)
    /// Force the player into landscape (or back to portrait) for viewers who keep auto-rotation off, the same
    /// scene geometry request the libmpv lane makes.
    func setOrientation(landscape: Bool) {
        guard let window = subtitleOverlay.window, let scene = window.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    #endif
}
/// One pending native decode and its eventual renderer. Account retirement denies publication
/// synchronously, cancels on the owning actor, and acknowledges cleanup only after preparation returns.
private final class AetherSubtitlePublication: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false, clearScheduled = false, clearFinished = false, preparationFinished = false
    private var registration: CredentialPublicationOutbox.SubtitleRendererRegistration?
    private var epochObservation: LegacyWatchOwnership.SubtitleRendererEpochObservation?
    private let clear: @MainActor @Sendable (AetherSubtitlePublication) -> Void
    init(clear: @escaping @MainActor @Sendable (AetherSubtitlePublication) -> Void) { self.clear = clear }
    var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
    func install(_ registration: CredentialPublicationOutbox.SubtitleRendererRegistration) -> Bool {
        lock.lock(); self.registration = registration; let current = !revoked; lock.unlock(); return current
    }
    func observeEpoch(_ observation: LegacyWatchOwnership.SubtitleRendererEpochObservation) {
        lock.lock(); epochObservation = observation; lock.unlock()
    }
    func revoke() -> Bool {
        lock.lock(); revoked = true
        let done = clearFinished && preparationFinished
        let schedule = !clearScheduled; clearScheduled = true; lock.unlock()
        if schedule { Task { @MainActor in self.close() } }
        return done
    }
    @MainActor func close() {
        lock.lock(); revoked = true; let needsClear = !clearFinished; clearScheduled = true; lock.unlock()
        if needsClear { clear(self) }
        lock.lock(); clearFinished = true
        let original = preparationFinished ? registration : nil
        let observation = preparationFinished ? epochObservation : nil
        if preparationFinished { epochObservation = nil }
        lock.unlock()
        if let observation { LegacyWatchOwnership.removeSubtitleRendererRetirement(observation) }
        if let original { _ = CredentialPublicationOutbox.unregisterSubtitleRenderer(original) }
    }
    @MainActor func finishPreparation() {
        lock.lock(); preparationFinished = true; let closeNow = revoked; lock.unlock()
        if closeNow { close() }
    }
}

#endif
