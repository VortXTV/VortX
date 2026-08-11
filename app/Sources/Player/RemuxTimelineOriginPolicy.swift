import Foundation

/// Pure decisions for the bounded base-video timeline-origin pre-scan receipt.
///
/// The remux loop owns packet allocation, timestamp conversion, fallback failure, and all FFmpeg interaction.
/// This type only names the bounded receipt contract so its observability cannot change the read or recovery
/// behavior of `VortXMKVRemuxStream`.
enum RemuxTimelineOriginPolicy {

    static let preScanPacketLimit = 240

    enum Mode: String, Equatable, Sendable {
        case fresh
        case resume
    }

    enum OriginBasis: String, Equatable, Sendable {
        case dts
        case ptsFallback = "pts-fallback"
        case none
    }

    struct PrescanOutcome: Equatable, Sendable {
        let mode: Mode
        let scanned: Int
        let mappedBase: Int
        let basis: OriginBasis
        let exhausted: Bool
        let achievedShiftSeconds: Double?

        var receipt: String {
            RemuxTimelineOriginPolicy.formatReceipt(
                mode: mode,
                scanned: scanned,
                mappedBase: mappedBase,
                basis: basis,
                exhausted: exhausted,
                achievedShiftSeconds: achievedShiftSeconds)
        }
    }

    /// Preserve the existing loop rule: once a mapped base packet has been examined, stop when no rebase is
    /// required or when the origin has already latched. The packet loop remains responsible for the hard bound.
    static func shouldStopAfterMappedBasePacket(
        isMappedBasePacket: Bool,
        timelineRebaseRequired: Bool,
        originLatched: Bool
    ) -> Bool {
        isMappedBasePacket && (!timelineRebaseRequired || originLatched)
    }

    /// Classify only the timestamp state already observed by the remux loop. A non-nil DTS is finite by the
    /// Int64 representation used at the FFmpeg boundary; the caller excludes AV_NOPTS_VALUE before passing it.
    static func originBasis(dts: Int64?, ptsFallback: Int64?) -> OriginBasis {
        if dts != nil { return .dts }
        if ptsFallback != nil { return .ptsFallback }
        return .none
    }

    /// Fresh mounts always publish source origin zero. Resume mounts publish the shift actually achieved by
    /// the mapped base-video packet, matching the existing latch behavior exactly.
    static func publishedOriginSeconds(mode: Mode, achievedShiftSeconds: Double) -> Double {
        mode == .fresh ? 0 : achievedShiftSeconds
    }

    /// Format the one-line, bounded, privacy-safe receipt. Only a finite shift is included, and it is rounded
    /// to three decimals; no source, track, title, URL, or packet/header data can enter this string.
    static func formatReceipt(
        mode: Mode,
        scanned: Int,
        mappedBase: Int,
        basis: OriginBasis,
        exhausted: Bool,
        achievedShiftSeconds: Double?
    ) -> String {
        let boundedScanned = min(max(scanned, 0), preScanPacketLimit)
        let boundedMappedBase = min(max(mappedBase, 0), boundedScanned)
        var receipt = "timeline-origin-prescan mode=\(mode.rawValue) "
            + "scanned=\(boundedScanned)/\(preScanPacketLimit) "
            + "mappedBase=\(boundedMappedBase) basis=\(basis.rawValue) exhausted=\(exhausted ? 1 : 0)"
        if let shift = achievedShiftSeconds, shift.isFinite {
            receipt += " shift=\(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), shift))"
        }
        return receipt
    }
}
