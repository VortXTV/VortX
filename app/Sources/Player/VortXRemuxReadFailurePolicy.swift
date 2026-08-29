import Foundation

/// Classifies a negative `av_read_frame` result before the DV remux decides whether another read is legal.
/// FFmpeg's HTTP protocol handles `rw_timeout` and reconnect internally. `AVERROR_EXIT` is different: it is
/// produced by our interrupt callback, bypasses HTTP reconnect, and becomes sticky on the AVIOContext. It must
/// therefore never enter the ordinary source-error retry ladder.
enum VortXRemuxReadFailurePolicy {
    enum Disposition: Equatable {
        case endOfFile
        case cancelled
        case unexpectedInterrupt
        case sourceError
    }

    private static let avErrorEOF: Int32 = -541478725
    private static let avErrorExit: Int32 = -1414092869

    static func classify(readResult: Int32, isCancelled: Bool) -> Disposition {
        if isCancelled { return .cancelled }
        if readResult == avErrorEOF { return .endOfFile }
        if readResult == avErrorExit { return .unexpectedInterrupt }
        return .sourceError
    }
}
