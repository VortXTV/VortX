import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// `VortXAetherPlayer` behind the runtime boundary the apps load (VortXAetherBridging.swift). The apps find
/// this class by its Objective-C name, so keep `VortXAetherBridgePlayer` stable.
@MainActor
@objc(VortXAetherBridgePlayer)
public final class VortXAetherBridgePlayer: NSObject, VortXAetherBridging {
    private let player: VortXAetherPlayer
    private var loadTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var subtitleGeneration: UInt64 = 0
    private var loadGeneration = 0
    /// Opens only when this generation actually enters its engine load. Cancelling a
    /// completed load Task does not retire the session that Task already opened.
    private var acceptsCallbacks = false

    public static func makePlayer() throws -> VortXAetherBridging {
        VortXAetherBridgePlayer(player: try VortXAetherPlayer())
    }

    private init(player: VortXAetherPlayer) {
        self.player = player
        super.init()
        player.onState = { [weak self] state in
            guard let self, acceptsCallbacks else { return }
            switch state {
            case .idle: self.onState?(.idle, nil)
            case .loading: self.onState?(.loading, nil)
            case .playing: self.onState?(.playing, nil)
            case .paused: self.onState?(.paused, nil)
            case .seeking: self.onState?(.seeking, nil)
            case .ended: self.onState?(.ended, nil)
            case .failed(let message): self.onState?(.failed, message)
            }
        }
        player.onTime = { [weak self] value in
            guard let self, acceptsCallbacks else { return }
            onTime?(value)
        }
        player.onDuration = { [weak self] value in
            guard let self, acceptsCallbacks else { return }
            onDuration?(value)
        }
        player.onBuffering = { [weak self] value in
            guard let self, acceptsCallbacks else { return }
            onBuffering?(value)
        }
        player.onBufferedPosition = { [weak self] value in
            guard let self, acceptsCallbacks else { return }
            onBufferedPosition?(value)
        }
        player.onTracksChanged = { [weak self] in
            guard let self, acceptsCallbacks else { return }
            onTracksChanged?()
        }
        player.onFirstFrame = { [weak self] in
            guard let self, acceptsCallbacks else { return }
            onFirstFrame?()
        }
        player.onSubtitleText = { [weak self] value in
            guard let self, acceptsCallbacks else { return }
            onSubtitleText?(value)
        }
    }

    public var view: VortXAetherBridgeView { player.view }

    public var onState: ((VortXAetherBridgeState, String?) -> Void)?
    public var onTime: ((Double) -> Void)?
    public var onDuration: ((Double) -> Void)?
    public var onBuffering: ((Bool) -> Void)?
    public var onBufferedPosition: ((Double) -> Void)?
    public var onTracksChanged: (() -> Void)?
    public var onFirstFrame: (() -> Void)?
    public var onSubtitleText: ((String?) -> Void)?

    // MARK: Loading and transport

    public func load(url: URL, headers: [String: String]?, live: Bool, startPosition: NSNumber?, autoplay: Bool,
                     completion: @escaping (NSError?) -> Void) {
        cancelLoad()
        loadGeneration &+= 1
        let generation = loadGeneration
        let start = startPosition?.doubleValue
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == self.loadGeneration else {
                completion(Self.error(.cancelled))
                return
            }
            acceptsCallbacks = true
            do {
                try await player.load(url: url, headers: headers, live: live, startPosition: start, autoplay: autoplay)
                completion(Task.isCancelled || generation != loadGeneration ? Self.error(.cancelled) : nil)
            } catch is CancellationError {
                completion(Self.error(.cancelled))
            } catch {
                completion(generation != loadGeneration
                    ? Self.error(.cancelled) : Self.error(.loadFailed, error.localizedDescription))
            }
        }
    }

    /// Retires the physical session synchronously, including one whose load already
    /// completed. No callback may cross the gap before a replacement load enters.
    public func cancelLoad() {
        cancelSubtitlePreparation()
        loadGeneration &+= 1
        let hadEnteredSession = acceptsCallbacks
        acceptsCallbacks = false
        loadTask?.cancel()
        loadTask = nil
        if hadEnteredSession { player.stop() }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public func stop() { cancelLoad() }
    public func seek(to seconds: Double, completion: (() -> Void)?) {
        let generation = loadGeneration
        Task { [weak self] in
            guard let self, generation == self.loadGeneration else { return }
            await player.seek(to: seconds)
            guard generation == loadGeneration else { return }
            completion?()
        }
    }
    public func setRate(_ rate: Double) { player.setRate(rate) }
    public func setVideoSize(_ mode: String) { player.setVideoSize(mode) }
    public func setAudioDelay(_ seconds: Double) { player.setAudioDelay(seconds) }
    public var volume: Double {
        get { player.volume }
        set { player.volume = newValue }
    }

    public var currentTime: Double { acceptsCallbacks ? (player.currentTime) : 0 }
    public var duration: Double { acceptsCallbacks ? (player.duration) : 0 }
    public var canSeek: Bool { acceptsCallbacks ? (player.canSeek) : false }
    public var isSeeking: Bool { acceptsCallbacks ? (player.isSeeking) : false }
    public var positionIsSettled: Bool { acceptsCallbacks && player.positionIsSettled }
    public var bufferedPosition: Double { acceptsCallbacks ? (player.bufferedPosition) : 0 }

    // MARK: Tracks

    public var audioTracks: [[String: Any]] { acceptsCallbacks ? (player.audioTracks.map(Self.dictionary)) : [] }
    public var subtitleTracks: [[String: Any]] { acceptsCallbacks ? (player.subtitleTracks.map(Self.dictionary)) : [] }
    public var activeAudioTrackID: NSNumber? { acceptsCallbacks ? (player.activeAudioTrackID.map { NSNumber(value: $0) }) : nil }
    public var activeSubtitleTrackID: NSNumber? { acceptsCallbacks ? (player.activeSubtitleTrackID.map { NSNumber(value: $0) }) : nil }
    public func selectAudioTrack(id: Int) { player.selectAudioTrack(id: id) }
    public func selectSubtitleTrack(id: Int) {
        cancelSubtitlePreparation()
        player.selectSubtitleTrack(id: id)
    }
    public func clearSubtitle() {
        cancelSubtitlePreparation()
        player.clearSubtitle()
    }
    public var activeSecondarySubtitleTrackID: NSNumber? {
        acceptsCallbacks ? player.activeSecondarySubtitleTrackID.map { NSNumber(value: $0) } : nil
    }
    public func selectSecondarySubtitleTrack(id: Int) {
        cancelSubtitlePreparation()
        player.selectSecondarySubtitleTrack(id: id)
    }
    public func clearSecondarySubtitle() {
        cancelSubtitlePreparation()
        player.clearSecondarySubtitle()
    }
    public func removeExternalSubtitleTrack(id: Int) { player.removeExternalSubtitleTrack(id: id) }
    public func cancelSubtitlePreparation() {
        subtitleGeneration &+= 1
        subtitleTask?.cancel()
        subtitleTask = nil
    }
    public func selectLocalSubtitle(url: URL, title: String, lang: String, secondary: Bool,
        permitsPreparation: @escaping @MainActor () -> Bool, permitsCommit: @escaping @MainActor () -> Bool, committedTrack: @escaping @MainActor (Int) -> Void, finishedCommit: @escaping @MainActor () -> Void, completion: @escaping (Bool) -> Void) {
        cancelSubtitlePreparation()
        let generation = subtitleGeneration, load = loadGeneration
        guard acceptsCallbacks, url.isFileURL, permitsPreparation() else { completion(false); return }
        subtitleTask = Task { @MainActor [weak self] in
            guard let self else { completion(false); return }
            do {
                try await player.selectLocalSubtitle(url: url, title: title, lang: lang, secondary: secondary,
                    permitsPreparation: {
                        !Task.isCancelled && self.acceptsCallbacks && self.loadGeneration == load
                            && self.subtitleGeneration == generation && permitsPreparation()
                    }, permitsCommit: {
                    !Task.isCancelled && self.acceptsCallbacks && self.loadGeneration == load
                        && self.subtitleGeneration == generation && permitsCommit()
                }, committedTrack: committedTrack, finishedCommit: finishedCommit)
                guard !Task.isCancelled, acceptsCallbacks, loadGeneration == load,
                      subtitleGeneration == generation else { completion(false); return }
                subtitleTask = nil
                completion(true)
            } catch {
                if subtitleGeneration == generation { subtitleTask = nil }
                completion(false)
            }
        }
    }
    public func selectSidecarSubtitle(url: URL, headers: [String: String]?) {
        player.selectSidecarSubtitle(url: url, headers: headers)
    }
    public func setSubtitleDelay(_ seconds: Double) { player.setSubtitleDelay(seconds) }

    // MARK: Diagnostics

    public var videoWidth: Int { acceptsCallbacks ? (player.videoWidth) : 0 }
    public var videoHeight: Int { acceptsCallbacks ? (player.videoHeight) : 0 }
    public var videoFrameRate: NSNumber? { acceptsCallbacks ? (player.videoFrameRate.map { NSNumber(value: $0) }) : nil }
    public var videoDynamicRange: String { acceptsCallbacks ? (player.videoDynamicRange) : "unknown" }
    public var mediaChapters: [[String: Any]] { acceptsCallbacks ? (player.mediaChapters) : [] }
    public var videoFormat: String { acceptsCallbacks ? (player.videoFormat) : "unknown" }
    public var sourceVideoFormat: String { acceptsCallbacks ? (player.sourceVideoFormat) : "unknown" }
    public var sourceDolbyVisionProfile: NSNumber? { acceptsCallbacks ? (player.sourceDolbyVisionProfile.map { NSNumber(value: $0) }) : nil }
    public var videoDecoder: String? { acceptsCallbacks ? (player.videoDecoder) : nil }
    public var audioDecoder: String? { acceptsCallbacks ? (player.audioDecoder) : nil }
    public var audioDelivery: String { acceptsCallbacks ? (player.audioDelivery) : "unknown" }
    public var videoRoute: String { acceptsCallbacks ? (player.videoRoute) : "unknown" }
    public var isDolbyVisionPresented: Bool { acceptsCallbacks ? (player.isDolbyVisionPresented) : false }

    private static func dictionary(_ track: VortXAetherTrack) -> [String: Any] {
        [VortXAetherBridgeTrackKey.id: track.id, VortXAetherBridgeTrackKey.title: track.title,
         VortXAetherBridgeTrackKey.language: track.language, VortXAetherBridgeTrackKey.codec: track.codec,
         VortXAetherBridgeTrackKey.channels: track.channels, VortXAetherBridgeTrackKey.isDefault: track.isDefault,
         VortXAetherBridgeTrackKey.isForced: track.isForced]
    }

    private static func error(_ code: VortXAetherBridgeErrorCode, _ description: String? = nil) -> NSError {
        NSError(domain: VortXAetherBridgeErrorDomain, code: code.rawValue,
                userInfo: description.map { [NSLocalizedDescriptionKey: $0] })
    }
}
