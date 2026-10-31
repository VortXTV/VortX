import Foundation

/// Genuine worker join: an already-owned local descriptor, original selected track/window and
/// bounded external SRT bytes -> libav timing extraction -> existing C/JSON parse/align/retime.
/// This type deliberately cannot mount a file or acquire fresh authority after work completes.
enum SubtitleReferencePreparation {
    struct Identity: Sendable, Equatable {
        let originalJob: UUID
        let originalLoad: PlayerLoadToken
        let originalReferenceTrackID: Int
        let originalReferenceStreamIndex: Int
        let originalManualGeneration: UInt64
        let originalAccount: CredentialScopeRegistry.Capture
        let originalApplicationEpoch: UUID
        let originalProfileID: UUID
    }

    struct Request: Sendable {
        let identity: Identity
        let source: SubtitleEmbeddedExtractor.LocalTimingSource
        let originalTimestampOriginSeconds: Double
        let referenceWindow: SubtitleEmbeddedExtractor.TimingWindow
        /// Exact already-fetched external bytes. The worker never fetches or reopens a URL/path.
        let externalSRT: Data
        let cancellation: SubtitleEmbeddedExtractor.TimingWindowCancellation
    }

    struct Prepared: Sendable {
        let originalIdentity: Identity
        /// Retention keeps the ORIGINAL descriptor alive through the eventual owner decision.
        let originalSource: SubtitleEmbeddedExtractor.LocalTimingSource
        let originalSourceIdentity: SubtitleEmbeddedExtractor.TimingLocalFileIdentity
        let originalTimestampOriginSeconds: Double
        let originalReferenceWindow: SubtitleEmbeddedExtractor.TimingWindow
        let actualIndexedStartSeconds: Double
        let file: SubtitleReferenceNativeQuery.RetimedFile
        /// Already prepared on the worker. Final admission must not reparse, sort or discard cues.
        let presentation: SubtitleReferencePresentation.Prepared
        let inputBytesRead: Int64
        let packetsRead: Int
    }

    enum Failure: Error, Sendable {
        case foregroundThread
        case invalidRequest
        case cancelled
        case extraction(SubtitleEmbeddedExtractor.TimingWindowFailure)
        case originalExtractionMismatch
        case nativeUnavailableOrRejected
        case presentation(SubtitleReferencePresentation.Failure)
    }

    /// One lossless projection policy for every whole reference occurrence. This is called by
    /// the real worker after its extraction/owner receipt checks; it grants no source authority.
    nonisolated static func referenceTimings(
        from cues: [SubtitleEmbeddedExtractor.TimingCue],
        window: SubtitleEmbeddedExtractor.TimingWindow
    ) -> [SubtitleReferenceNativeQuery.Timing]? {
        guard window.purpose == .reference,
              window.startSeconds == Double(SubtitleReferenceNativeQuery.scoringWindowStartMs) / 1000,
              window.endSeconds == Double(SubtitleReferenceNativeQuery.referenceWindowEndMs) / 1000,
              (8...1024).contains(cues.count) else { return nil }
        var timings: [SubtitleReferenceNativeQuery.Timing] = []
        timings.reserveCapacity(cues.count)
        var previous: UInt64?
        var previousSeconds: Double?
        for cue in cues {
            guard cue.startSeconds.isFinite, cue.endSeconds.isFinite,
                  cue.startSeconds >= window.startSeconds, cue.endSeconds <= window.endSeconds,
                  cue.endSeconds > cue.startSeconds,
                  previousSeconds.map({ cue.startSeconds >= $0 }) ?? true else { return nil }
            let start = UInt64((cue.startSeconds * 1000).rounded())
            let end = UInt64((cue.endSeconds * 1000).rounded())
            // Distinct real starts may round to the same millisecond. Preserve all occurrences,
            // while still rejecting backward original order and zero-width represented cues.
            guard start < end, previous.map({ start >= $0 }) ?? true else { return nil }
            timings.append(.init(startMs: start, endMs: end))
            previous = start
            previousSeconds = cue.startSeconds
        }
        return timings
    }

    /// Blocking utility-worker operation. No owner lock, MainActor hop, user callback, player seek,
    /// native sub-add, live query, credentials, upload, account write or checkpoint is permitted here.
    nonisolated static func prepare(_ request: Request) -> Result<Prepared, Failure> {
        guard !Thread.isMainThread else { return .failure(.foregroundThread) }
        guard !request.cancellation.isCancelled else { return .failure(.cancelled) }
        // The initial native wire estimates against the full first fifteen minutes. Retain this
        // full denominator even when extraction starts at a later known index; never score only a
        // sampled suffix. Other window selection needs a future explicit query contract.
        guard request.referenceWindow.purpose == .reference,
              request.referenceWindow.startSeconds
                == Double(SubtitleReferenceNativeQuery.scoringWindowStartMs) / 1000,
              request.referenceWindow.endSeconds
                == Double(SubtitleReferenceNativeQuery.referenceWindowEndMs) / 1000,
              !request.externalSRT.isEmpty, request.externalSRT.count <= 1024 * 1024,
              request.originalTimestampOriginSeconds.isFinite,
              request.identity.originalReferenceTrackID > 0,
              (0..<128).contains(request.identity.originalReferenceStreamIndex) else {
            return .failure(.invalidRequest)
        }
        do { try request.source.validateUnchanged() }
        catch let error as SubtitleEmbeddedExtractor.TimingWindowFailure { return .failure(.extraction(error)) }
        catch { return .failure(.invalidRequest) }

        let extraction = SubtitleEmbeddedExtractor.extractSelectedTextTimingWindow(
            source: request.source,
            originalStreamIndex: request.identity.originalReferenceStreamIndex,
            originalTimestampOriginSeconds: request.originalTimestampOriginSeconds,
            window: request.referenceWindow,
            cancellation: request.cancellation
        )
        let result: SubtitleEmbeddedExtractor.TimingWindowResult
        switch extraction {
        case let .success(value): result = value
        case let .failure(error): return .failure(.extraction(error))
        }
        guard !request.cancellation.isCancelled else { return .failure(.cancelled) }
        guard result.originalStreamIndex == request.identity.originalReferenceStreamIndex,
              result.originalTimestampOriginSeconds == request.originalTimestampOriginSeconds,
              result.sourceIdentity == request.source.identity,
              result.window == request.referenceWindow,
              result.actualIndexedStartSeconds.isFinite,
              result.actualIndexedStartSeconds >= request.referenceWindow.startSeconds,
              result.actualIndexedStartSeconds <= request.referenceWindow.startSeconds + 30,
              (8...1024).contains(result.cues.count),
              result.inputBytesRead > 0, result.inputBytesRead <= 128 * 1024 * 1024,
              (1...100_000).contains(result.packetsRead) else {
            return .failure(.originalExtractionMismatch)
        }
        guard let timings = referenceTimings(from: result.cues, window: request.referenceWindow) else {
            return .failure(.originalExtractionMismatch)
        }
        guard let file = SubtitleReferenceNativeQuery.align(
            externalSRT: request.externalSRT,
            reference: timings,
            originalJob: request.identity.originalJob
        ) else { return .failure(.nativeUnavailableOrRejected) }
        guard !request.cancellation.isCancelled else { return .failure(.cancelled) }
        let presentation: SubtitleReferencePresentation.Prepared
        do { presentation = try SubtitleReferencePresentation.prepare(file) }
        catch let failure as SubtitleReferencePresentation.Failure { return .failure(.presentation(failure)) }
        catch { return .failure(.invalidRequest) }
        guard !request.cancellation.isCancelled else { return .failure(.cancelled) }
        do { try request.source.validateUnchanged() }
        catch let error as SubtitleEmbeddedExtractor.TimingWindowFailure { return .failure(.extraction(error)) }
        catch { return .failure(.invalidRequest) }
        return .success(Prepared(
            originalIdentity: request.identity, originalSource: request.source,
            originalSourceIdentity: result.sourceIdentity,
            originalTimestampOriginSeconds: result.originalTimestampOriginSeconds,
            originalReferenceWindow: result.window,
            actualIndexedStartSeconds: result.actualIndexedStartSeconds,
            file: file, presentation: presentation,
            inputBytesRead: result.inputBytesRead, packetsRead: result.packetsRead
        ))
    }
}
