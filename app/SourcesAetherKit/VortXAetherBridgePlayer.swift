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
    private var loadGeneration = 0

    public static func makePlayer() throws -> VortXAetherBridging {
        VortXAetherBridgePlayer(player: try VortXAetherPlayer())
    }

    private init(player: VortXAetherPlayer) {
        self.player = player
        super.init()
        player.onState = { [weak self] state in
            switch state {
            case .idle: self?.onState?(.idle, nil)
            case .loading: self?.onState?(.loading, nil)
            case .playing: self?.onState?(.playing, nil)
            case .paused: self?.onState?(.paused, nil)
            case .seeking: self?.onState?(.seeking, nil)
            case .ended: self?.onState?(.ended, nil)
            case .failed(let message): self?.onState?(.failed, message)
            }
        }
    }

    public var view: VortXAetherBridgeView { player.view }

    public var onState: ((VortXAetherBridgeState, String?) -> Void)?
    public var onTime: ((Double) -> Void)? {
        get { player.onTime }
        set { player.onTime = newValue }
    }
    public var onDuration: ((Double) -> Void)? {
        get { player.onDuration }
        set { player.onDuration = newValue }
    }
    public var onBuffering: ((Bool) -> Void)? {
        get { player.onBuffering }
        set { player.onBuffering = newValue }
    }
    public var onBufferedPosition: ((Double) -> Void)? {
        get { player.onBufferedPosition }
        set { player.onBufferedPosition = newValue }
    }
    public var onTracksChanged: (() -> Void)? {
        get { player.onTracksChanged }
        set { player.onTracksChanged = newValue }
    }
    public var onFirstFrame: (() -> Void)? {
        get { player.onFirstFrame }
        set { player.onFirstFrame = newValue }
    }
    public var onSubtitleText: ((String?) -> Void)? {
        get { player.onSubtitleText }
        set { player.onSubtitleText = newValue }
    }

    // MARK: Loading and transport

    public func load(url: URL, headers: [String: String]?, startPosition: NSNumber?, autoplay: Bool,
                     completion: @escaping (NSError?) -> Void) {
        cancelLoad()
        loadGeneration &+= 1
        let generation = loadGeneration
        let start = startPosition?.doubleValue
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await player.load(url: url, headers: headers, startPosition: start, autoplay: autoplay)
                completion(Task.isCancelled || generation != loadGeneration ? Self.error(.cancelled) : nil)
            } catch is CancellationError {
                completion(Self.error(.cancelled))
            } catch {
                completion(generation != loadGeneration
                    ? Self.error(.cancelled) : Self.error(.loadFailed, error.localizedDescription))
            }
        }
    }

    /// Cancels the load in flight; its completion reports `cancelled`.
    public func cancelLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public func stop() {
        cancelLoad()
        player.stop()
    }
    public func seek(to seconds: Double, completion: (() -> Void)?) {
        Task { [weak self] in
            await self?.player.seek(to: seconds)
            completion?()
        }
    }
    public func setRate(_ rate: Double) { player.setRate(rate) }
    public func setAudioDelay(_ seconds: Double) { player.setAudioDelay(seconds) }
    public var volume: Double {
        get { player.volume }
        set { player.volume = newValue }
    }

    public var currentTime: Double { player.currentTime }
    public var duration: Double { player.duration }
    public var canSeek: Bool { player.canSeek }
    public var bufferedPosition: Double { player.bufferedPosition }

    // MARK: Tracks

    public var audioTracks: [[String: Any]] { player.audioTracks.map(Self.dictionary) }
    public var subtitleTracks: [[String: Any]] { player.subtitleTracks.map(Self.dictionary) }
    public var activeAudioTrackID: NSNumber? { player.activeAudioTrackID.map { NSNumber(value: $0) } }
    public var activeSubtitleTrackID: NSNumber? { player.activeSubtitleTrackID.map { NSNumber(value: $0) } }
    public func selectAudioTrack(id: Int) { player.selectAudioTrack(id: id) }
    public func selectSubtitleTrack(id: Int) { player.selectSubtitleTrack(id: id) }
    public func clearSubtitle() { player.clearSubtitle() }
    public func selectSidecarSubtitle(url: URL, headers: [String: String]?) {
        player.selectSidecarSubtitle(url: url, headers: headers)
    }
    public func setSubtitleDelay(_ seconds: Double) { player.setSubtitleDelay(seconds) }

    // MARK: Diagnostics

    public var videoFormat: String { player.videoFormat }
    public var sourceVideoFormat: String { player.sourceVideoFormat }
    public var sourceDolbyVisionProfile: NSNumber? { player.sourceDolbyVisionProfile.map { NSNumber(value: $0) } }
    public var videoDecoder: String? { player.videoDecoder }
    public var audioDecoder: String? { player.audioDecoder }
    public var audioDelivery: String { player.audioDelivery }
    public var videoRoute: String { player.videoRoute }
    public var isDolbyVisionPresented: Bool { player.isDolbyVisionPresented }

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
