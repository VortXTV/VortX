import Foundation

/// Dependency-free encoder-configuration decisions for `VortXAudioTranscoder`, split out so the executable
/// test harness can run them without linking libav (the DVPlaybackContractTests pattern).
///
/// WHY THIS EXISTS (#148): the transcoder used to hand the AAC encoder the SOURCE sample rate unchanged
/// ("AAC keeps the source rate"). FFmpeg's native AAC encoder only accepts the 13 MPEG-4 rates up to
/// 96 kHz, so a hi-res lossless track (192 kHz / 176.4 kHz TrueHD or DTS-HD MA, legal and common on
/// remuxes) failed `avcodec_open2` (rc=-22, "Specified sample rate 192000 is not supported"), the
/// fail-soft `init?` returned nil, and the WHOLE Dolby Vision session demoted to the libmpv HDR10
/// tone-map: the "TrueHD reverts to HDR" field report. Proven end-to-end against the shipped
/// libavcodec 62.12.102: 192 kHz open fails, every rate in the table below opens, and the E2E harness
/// shows `HDR10 FALLBACK: audio transcode init failed` for a 192 kHz TrueHD MKV. Snapping DOWN to the
/// nearest supported rate keeps the DV lane alive; swresample (already in the transcode pipeline)
/// handles the rate conversion, exactly as it already did for the EAC3 48 kHz cap.
enum VortXAudioTranscodePolicy {

    /// FFmpeg's native AAC encoder accepts exactly the MPEG-4 sampling frequency table
    /// (aacenc / ff_mpeg4audio_sample_rates), descending. Anything else fails avcodec_open2.
    static let aacSupportedRates: [Int32] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// FFmpeg's eac3 encoder accepts only the AC-3 rates. Unreachable with today's bundled binaries
    /// (no eac3 encoder is compiled in), but the day one ships this keeps its open from failing on a
    /// low-rate source the same way the AAC lane failed on a hi-res one.
    static let eac3SupportedRates: [Int32] = [48_000, 44_100, 32_000]

    /// The sample rate the encoder context is opened with for a source of rate `source`.
    /// Keeps the source rate when the encoder supports it; otherwise snaps DOWN to the nearest
    /// supported rate, preferring the source's own 44.1/48 k family so the resample ratio stays an
    /// integer (192k -> 96k, 176.4k -> 88.2k). A source below the whole table snaps UP to the table
    /// floor. A non-positive source (unset codecpar) takes the proven 48 kHz default.
    static func encoderSampleRate(source: Int32, isEAC3: Bool) -> Int32 {
        let table = isEAC3 ? eac3SupportedRates : aacSupportedRates
        guard source > 0 else { return 48_000 }
        if table.contains(source) { return source }
        if source % 44_100 == 0, let familySnap = table.first(where: { $0 <= source && $0 % 44_100 == 0 }) {
            return familySnap
        }
        if let snapped = table.first(where: { $0 <= source }) { return snapped }
        return table[table.count - 1]
    }
}
