import Foundation

/// Classifies the FIRST `av_read_frame` failure the base-video timeline-origin pre-scan hits before it has
/// mapped a single timestamped base-video packet (root-cause report section 3).
///
/// Before this classification existed, the pre-scan discarded the read's return code entirely and every
/// zero-packet source - a genuinely empty/expired/truncated link exactly as much as a merely slow one -
/// collapsed into one generic "produced no timestamped base-video packet" string. Every consumer of that
/// string treated it identically: AVPlayer 404s the local HLS master, the chrome demotes to libmpv on the
/// SAME dead bytes, and libmpv burns another ~30 seconds before it too reports zero frames. A source that
/// closed at EOF before any media packet can never produce a frame on a second decode engine either, so that
/// second attempt is pure wasted time. This type only names the decision; the remux loop still owns packet
/// allocation, the actual FFmpeg calls, and publishing the result to `VortXRemuxBuffer.fail`.
enum RemuxFirstPacketFailure: Equatable, Sendable {
    /// The demuxer reached genuine end-of-stream (AVERROR_EOF, or `avio_feof` true on the input's AVIOContext)
    /// before any timestamped base-video packet arrived. The source is EMPTY, not slow: no retry and no
    /// engine switch can manufacture bytes the far end never sent. The caller must mark the source terminal
    /// for this session and hop to the next candidate immediately, without trying libmpv on the same link.
    case emptyEOF
    /// A read timed out (AVERROR(ETIMEDOUT) - the `rw_timeout` option expiring) before any timestamped
    /// base-video packet. This can be a genuinely slow or cold-cache link, so it is owed one bounded retry
    /// before the caller gives up on it.
    case timeout(code: Int32)
    /// A non-EOF, non-timeout AVIO error (dropped connection, TLS reset, EIO, ...) before any timestamped
    /// base-video packet. Plausibly transient like a timeout, so the same one-bounded-retry policy applies.
    case ioError(code: Int32)
    /// OUR OWN interrupt callback fired (AVERROR_EXIT) because this session was being cancelled/torn down,
    /// not because the source failed. `VortXMKVRemuxStream.cancel()` has already published the buffer's
    /// terminal state itself; the caller must never publish a second, source-blaming failure over it and must
    /// never penalise the source for our own teardown.
    case cancelled(code: Int32)

    /// AVERROR_EOF = FFERRTAG('E','O','F',' ') = -541478725. Matches the constant already hardcoded at the
    /// live mid-stream read loop below (the Swift importer does not surface the AVERROR macro).
    private static let avErrorEOF: Int32 = -541478725
    /// AVERROR(ETIMEDOUT) = -60 on Darwin (rw_timeout expiry), the same value the cold-debrid open retry gate
    /// already hardcodes elsewhere in this file.
    private static let avErrorTimedOut: Int32 = -60

    /// One bounded retry of the SAME already-open AVIOContext is owed for `.timeout`/`.ioError`: FFmpeg's own
    /// `reconnect`/`reconnect_streamed`/`reconnect_delay_max` options (already enabled on this input, see the
    /// mid-stream read loop's retry comment) re-establish the connection transparently, so a second
    /// `av_read_frame` on the same context IS the bounded reopen, not a fresh `avformat_open_input`.
    static let maxPreScanReadRetries = 1

    /// Classifies one failing `av_read_frame` return from the pre-scan. `avioEOF`/`avioError` must come from
    /// the SAME AVIOContext the failing read used (`inCtx.pointee.pb`), sampled immediately after the call so
    /// no later read can overwrite them. `isCancelled` is checked first: a torn-down session's read commonly
    /// also surfaces AVERROR_EXIT as `readResult`, but the cancellation flag is the ground truth regardless of
    /// which rc libav happened to hand back.
    static func classify(
        readResult: Int32,
        avioEOF: Bool,
        avioError: Int32,
        isCancelled: Bool
    ) -> RemuxFirstPacketFailure {
        if isCancelled { return .cancelled(code: readResult) }
        if readResult == avErrorEOF || avioEOF { return .emptyEOF }
        if readResult == avErrorTimedOut { return .timeout(code: readResult) }
        if avioError != 0 { return .ioError(code: avioError) }
        return .ioError(code: readResult)
    }

    /// True when this classification proves the source is exhausted for this session: hop to the next source
    /// candidate immediately, and never attempt the other decode engine on the same bytes.
    var isSourceTerminal: Bool {
        if case .emptyEOF = self { return true }
        return false
    }

    /// True when the failure must never be surfaced as a source-blaming error: it is our own teardown.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// See `maxPreScanReadRetries`. `.emptyEOF`/`.cancelled` never retry: retrying a proven-empty source only
    /// re-creates the exact wasted-time symptom this classification exists to remove.
    var deservesOneBoundedRetry: Bool {
        switch self {
        case .timeout, .ioError: return true
        case .emptyEOF, .cancelled: return false
        }
    }

    /// Every `VortXRemuxBuffer.fail` message this classification can publish is tagged with one of these
    /// prefixes, mirroring `DVPlaybackPolicy.sourceCapabilityMismatchPrefix`: the classification crosses into
    /// the local HLS server (`terminalFailureReason`) and the player chrome purely as plain text today, so the
    /// prefix is what lets `isTerminalZeroPacket`/`isTransientZeroPacket` recover it downstream without a new
    /// cross-module type or ABI change.
    static let terminalZeroPacketPrefix = "zero-packet source (terminal):"
    static let transientZeroPacketPrefix = "zero-packet source (transient, retries exhausted):"

    /// The exact `buffer.fail` message this classification should publish once no more retries remain.
    /// `isResume` mirrors the fresh-vs-resume origin wording the pre-scan already used for its generic
    /// message, so no diagnostic distinction is lost. `evidence` is the bounded, privacy-safe pre-scan
    /// receipt (scanned/mappedBase counts) the caller already builds for `DiagnosticsLog`.
    func failureMessage(isResume: Bool, evidence: String) -> String {
        let originWord = isResume ? "resume" : "fresh"
        switch self {
        case .emptyEOF:
            return "\(Self.terminalZeroPacketPrefix) \(originWord) input reached end-of-stream before any "
                + "timestamped base-video packet (\(evidence))"
        case .timeout(let code):
            return "\(Self.transientZeroPacketPrefix) \(originWord) input read timed out (rc=\(code)) before "
                + "any timestamped base-video packet (\(evidence))"
        case .ioError(let code):
            return "\(Self.transientZeroPacketPrefix) \(originWord) input read failed (rc=\(code)) before any "
                + "timestamped base-video packet (\(evidence))"
        case .cancelled(let code):
            return "cancelled (rc=\(code)) before any timestamped base-video packet"
        }
    }

    static func isTerminalZeroPacket(_ message: String) -> Bool {
        message.hasPrefix(terminalZeroPacketPrefix)
    }

    static func isTransientZeroPacket(_ message: String) -> Bool {
        message.hasPrefix(transientZeroPacketPrefix)
    }
}
