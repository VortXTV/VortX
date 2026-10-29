#if os(iOS) || os(tvOS) || os(macOS)
import AVFoundation
import CoreMedia
import Foundation

/// Account/domain retirement may arrive on a non-UI queue. Deny further publication synchronously,
/// then report cleanup complete ONLY after the original overlay was cleared on its owning actor.
/// No synchronous actor hop or owner/coordinator call occurs inside the revocation callback.
final class AVKitSubtitleAlignmentPublication: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var ownerRevoked = false
    /// The first default AV-selection retirement is serialized with owner revoke. A selected true
    /// result means the outbox's revoke won; a selected false result means the selection event won.
    private var defaultRetirementWasOwnerRevoke: Bool?
    private var scheduled = false
    private var completed = false
    private var registration: CredentialPublicationOutbox.SubtitleRendererRegistration?
    private let clear: @MainActor @Sendable (AVKitSubtitleAlignmentPublication) -> Void

    init(clear: @escaping @MainActor @Sendable (AVKitSubtitleAlignmentPublication) -> Void) {
        self.clear = clear
    }

    var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }

    /// Resolve the original owner's cause atomically against `revoke()`. Ordinary `close()` does
    /// not set `ownerRevoked`, so manual retirement cannot masquerade as an owner revocation.
    func claimOwnerRevocationForDefaultRetirement() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let defaultRetirementWasOwnerRevoke { return defaultRetirementWasOwnerRevoke }
        defaultRetirementWasOwnerRevoke = ownerRevoked
        return ownerRevoked
    }

    func install(_ value: CredentialPublicationOutbox.SubtitleRendererRegistration) -> Bool {
        lock.lock()
        registration = value
        let accepts = !revoked && !completed
        let retry = completed
        lock.unlock()
        if retry { _ = CredentialPublicationOutbox.unregisterSubtitleRenderer(value) }
        return accepts
    }

    func revoke() -> Bool {
        lock.lock()
        ownerRevoked = true
        if defaultRetirementWasOwnerRevoke == nil { defaultRetirementWasOwnerRevoke = true }
        revoked = true
        let done = completed
        let enqueue = !completed && !scheduled
        scheduled = true
        lock.unlock()
        if enqueue { Task { @MainActor in self.close() } }
        return done
    }

    @MainActor
    func close() {
        lock.lock()
        revoked = true
        let needsClear = !completed
        lock.unlock()
        if needsClear { clear(self) }
        lock.lock()
        completed = true
        let original = registration
        lock.unlock()
        // A repeated original registration drain now sees completed=true and can wake its writer.
        if let original { _ = CredentialPublicationOutbox.unregisterSubtitleRenderer(original) }
    }
}

/// The actual original AVPlayerItem/AVAssetTrack relationship, captured before ordinary external
/// selection deselects native text. No media-option ordinal or newly constructed URL asset is used.
/// Attached AVAssetTrack and reader accesses remain on AVPlayer's default notification/MainActor.
@MainActor
final class AVKitSubtitleReferenceCapture {
    private let item: AVPlayerItem
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let trackID: CMPersistentTrackID
    private var observedFile: SubtitleEmbeddedExtractor.LocalTimingSource?
    private var activeReader: AVAssetReader?

    static func capture(item: AVPlayerItem) -> AVKitSubtitleReferenceCapture? {
        guard item.status == .readyToPlay, let asset = item.asset as? AVURLAsset,
              asset.url.isFileURL else { return nil }
        var selected: AVAssetTrack?
        for row in item.tracks where row.isEnabled {
            guard let candidate = row.assetTrack,
                  candidate.mediaType == .text || candidate.mediaType == .subtitle else { continue }
            guard selected == nil, candidate.asset === asset else { return nil }
            selected = candidate
        }
        guard let selected else { return nil }
        return .init(item: item, asset: asset, track: selected)
    }

    private init(item: AVPlayerItem, asset: AVURLAsset, track: AVAssetTrack) {
        self.item = item; self.asset = asset; self.track = track; trackID = track.trackID
    }

    enum Failure: Error { case unavailable, superseded, incomplete, budget }

    /// The capture retains only the original SDK objects. It is legal for our OWN raw mount to
    /// disable the original row, so admission is supplied by the original selection transaction,
    /// never by recapturing an enabled track after an await.
    func read(isCurrent: @escaping @MainActor () -> Bool) async throws -> [SubtitleReferenceNativeQuery.Timing] {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, *),
              isCurrent(), item.asset === asset, track.asset === asset, track.trackID == trackID else {
            throw Failure.unavailable
        }
        return try await withTaskCancellationHandler {
            try await readModern(isCurrent: isCurrent)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelReader() }
        }
    }

    private func cancelReader() {
        if activeReader?.status == .reading { activeReader?.cancelReading() }
    }

    private func requireCurrent(_ isCurrent: @MainActor () -> Bool) throws {
        guard isCurrent(), !Task.isCancelled, item.asset === asset,
              track.asset === asset, track.trackID == trackID else { throw Failure.superseded }
    }

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
    private func readModern(isCurrent: @escaping @MainActor () -> Bool) async throws
        -> [SubtitleReferenceNativeQuery.Timing] {
        let contained = try await track.load(.isSelfContained)
        try requireCurrent(isCurrent)
        guard contained else { throw Failure.unavailable }
        let readable = try await asset.load(.isReadable)
        try requireCurrent(isCurrent)
        let protected = try await asset.load(.hasProtectedContent)
        try requireCurrent(isCurrent)
        let duration = try await asset.load(.duration)
        try requireCurrent(isCurrent)
        let segments = try await track.load(.segments)
        try requireCurrent(isCurrent)
        let formats = try await track.load(.formatDescriptions)
        try requireCurrent(isCurrent)
        guard readable, !protected, contained, duration.isNumeric, duration.epoch == 0,
              duration.seconds.isFinite, duration.seconds > 0,
              !segments.isEmpty, segments.allSatisfy({ Self.isIdentitySegment($0) }),
              !formats.isEmpty, formats.allSatisfy({
                  CMFormatDescriptionGetMediaSubType($0) == AVSubtitleReferenceSamplePolicy.tx3g
              }) else { throw Failure.unavailable }

        // Supplemental local resource observation, not an invented FF/source grant. Reading is
        // still from the SAME retained original AVAsset. Refuse a nonregular/symlink leaf and
        // detect observed descriptor/path replacement or content metadata mutation around reading.
        let path = asset.url.path
        let file = try await Task.detached(priority: .utility) {
            try SubtitleEmbeddedExtractor.LocalTimingSource.open(input: path)
        }.value
        guard isCurrent(), !Task.isCancelled else { throw Failure.superseded }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero,
            duration: CMTime(seconds: min(duration.seconds, 1_080), preferredTimescale: 1_000_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw Failure.unavailable }
        let provider = reader.outputProvider(for: output)
        activeReader = reader
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            reader.cancelReading()
        }
        defer {
            deadline.cancel()
            if reader.status == .reading { reader.cancelReading() }
            activeReader = nil
        }
        try reader.start()
        var window = AVSubtitleReferenceSamplePolicy.Window()
        while let ready = try await provider.next() {
            guard isCurrent(), !Task.isCancelled else { throw Failure.superseded }
            let sample = try ready.withUnsafeSampleBuffer { buffer -> AVSubtitleReferenceSamplePolicy.Sample in
                let count = CMSampleBufferGetNumSamples(buffer)
                if count == 0 {
                    return .init(count: 0, subtype: 0, presentationSeconds: 0,
                        durationSeconds: 0, numericEpochZero: true, bytes: Data())
                }
                guard count == 1,
                      let format = CMSampleBufferGetFormatDescription(buffer),
                      let block = CMSampleBufferGetDataBuffer(buffer) else { throw Failure.unavailable }
                let size = CMBlockBufferGetDataLength(block)
                guard size >= 2, size <= AVSubtitleReferenceSamplePolicy.maximumSampleBytes,
                      size <= AVSubtitleReferenceSamplePolicy.maximumCopiedBytes - window.copiedBytes else {
                    throw Failure.budget
                }
                var bytes = Data(count: size)
                let status = bytes.withUnsafeMutableBytes { destination -> OSStatus in
                    guard let base = destination.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size,
                        destination: base)
                }
                guard status == kCMBlockBufferNoErr else { throw Failure.unavailable }
                let pts = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
                let span = CMSampleBufferGetOutputDuration(buffer)
                let rawPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
                let rawSpan = CMSampleBufferGetDuration(buffer)
                // Identity segment mapping plus exact original/output equality refuses reader
                // boundary trims. A cue crossing1080 must never become a shorter invented cue.
                let wholeOccurrence = CMTimeCompare(rawPTS, pts) == 0 && CMTimeCompare(rawSpan, span) == 0
                return .init(count: count, subtype: CMFormatDescriptionGetMediaSubType(format),
                    presentationSeconds: pts.seconds, durationSeconds: span.seconds,
                    numericEpochZero: wholeOccurrence && pts.isNumeric && span.isNumeric
                        && rawPTS.isNumeric && rawSpan.isNumeric
                        && pts.epoch == 0 && span.epoch == 0 && rawPTS.epoch == 0 && rawSpan.epoch == 0,
                    bytes: bytes)
            }
            try window.consume(sample)
            if window.samples.isMultiple(of: 32) { await Task.yield() }
        }
        guard reader.status == .completed, isCurrent(), !Task.isCancelled else { throw Failure.incomplete }
        let unchanged = try await Task.detached(priority: .utility) {
            try file.validateUnchanged()
            let currentPath = try SubtitleEmbeddedExtractor.LocalTimingSource.open(input: path)
            return currentPath.identity == file.identity
        }.value
        guard unchanged, isCurrent(), !Task.isCancelled, (8...1_024).contains(window.timings.count) else {
            throw Failure.incomplete
        }
        observedFile = file
        return window.timings.map { .init(startMs: $0.startMs, endMs: $0.endMs) }
    }

    /// Revalidate the original observation after utility scoring/preparation, before its original
    /// controller publishes. This is metadata/change detection around a framework-owned asset read,
    /// not a claim that AVFoundation read through our descriptor or that local files are immutable.
    func validateAfterPreparation(isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard let file = observedFile, isCurrent(), !Task.isCancelled,
              item.asset === asset, track.asset === asset, track.trackID == trackID else {
            throw Failure.superseded
        }
        let path = asset.url.path
        let unchanged = try await Task.detached(priority: .utility) {
            try file.validateUnchanged()
            return try SubtitleEmbeddedExtractor.LocalTimingSource.open(input: path).identity == file.identity
        }.value
        guard unchanged, isCurrent(), !Task.isCancelled else { throw Failure.superseded }
    }

    private static func isIdentitySegment(_ segment: AVAssetTrackSegment) -> Bool {
        let mapping = segment.timeMapping
        return !segment.isEmpty && mapping.source.isValid && mapping.target.isValid
            && mapping.source.start.isNumeric && mapping.target.start.isNumeric
            && mapping.source.duration.isNumeric && mapping.target.duration.isNumeric
            && mapping.source.start.epoch == 0 && mapping.target.start.epoch == 0
            && mapping.source.duration.epoch == 0 && mapping.target.duration.epoch == 0
            && CMTimeCompare(mapping.source.start, mapping.target.start) == 0
            && CMTimeCompare(mapping.source.duration, mapping.target.duration) == 0
            && CMTimeCompare(mapping.source.duration, .zero) > 0
    }
}
#endif
