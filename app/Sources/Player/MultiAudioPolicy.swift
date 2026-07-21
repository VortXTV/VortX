import Foundation

/// Pure decision logic for the BOUNDED second audio track in the MKV -> fMP4 remux, deliberately kept in a file
/// that imports nothing but Foundation.
///
/// Why it is separate: the code that USES these decisions lives in `VortXMKVRemuxStream`, which pulls in
/// Libavformat/Libavcodec/Libavutil/Libdovi, so a standalone harness cannot compile it without the whole
/// FFmpeg vendor tree. Asserting on source text instead was already proven inadequate on this codebase: a
/// mutant that preserved every asserted string while appending `false` to a guard passed the whole suite while
/// the guard could never fire. Keeping the decisions here makes them executable, so `app/Tests/
/// MultiAudioPolicyTests.swift` calls the real functions and a SEMANTIC break turns the suite red.
///
/// Scope, and why it is this narrow:
///   - At most ONE additional audio track, which must be a DIFFERENT language and the SAME codec as the
///     primary. Heterogeneous codecs are out of scope: the HLS master advertises one audio CODECS entry, and
///     mixing codecs inside one variant needs a master-playlist redesign that is not part of this change.
///   - The additional track is only mapped after it has provably delivered a first packet inside a bounded
///     probe. The fragmented-mp4 muxer's delayed moov waits for EVERY mapped track to deliver a sample before
///     it writes the moov, so an alternate that is empty, malformed, or merely late starves init and demotes
///     the whole session. Losing a second language is a small regression; losing Dolby Vision and Atmos is a
///     large one, so the alternate is the thing that gets dropped.
enum MultiAudioPolicy {

    // MARK: - Track qualification

    /// One stream-copyable audio track, carried as plain values so this file needs no libav types.
    /// `codecID` is the libav codec id's raw value; the caller passes `codec_id.rawValue` unchanged, and this
    /// file only ever compares it for equality, never interprets it.
    struct AudioTrack: Equatable {
        let index: Int
        let codecID: UInt32
        let channels: Int
        let language: String

        init(index: Int, codecID: UInt32, channels: Int, language: String) {
            self.index = index
            self.codecID = codecID
            self.channels = channels
            self.language = language
        }
    }

    /// Comparison form of a stream language tag: trimmed and lowercased.
    static func languageKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when a language key names no actual language, so "different language" cannot be PROVEN for it.
    ///
    /// This matters more here than it looks. The matroska demuxer substitutes its spec default for a track
    /// with no Language element and MP4 files commonly carry "und", so an untagged file can present several
    /// tracks that are all really the same language under different-looking tags, or all the same tag. Mapping
    /// a second track on an unproven language difference buys the user nothing (two tracks labelled the same
    /// are indistinguishable in the player's picker) while paying the full init-starvation risk, so an unknown
    /// tag on EITHER side disqualifies the pair.
    static func isUnknownLanguage(_ key: String) -> Bool {
        key.isEmpty || key == "und" || key == "unk" || key == "mis" || key == "zxx"
    }

    /// The at-most-one alternate audio track to map alongside `primaryIndex`, or nil when nothing qualifies.
    ///
    /// A candidate qualifies only when all of these hold:
    ///   - it carries the SAME codec id as the primary (see the type note: heterogeneous codecs are out of
    ///     scope because the master playlist advertises a single audio CODECS entry);
    ///   - both its language and the primary's language are known (see `isUnknownLanguage`);
    ///   - its language differs from the primary's.
    ///
    /// There is deliberately NO separate "is not the primary" clause. The primary cannot differ in language
    /// from itself, so the language clause already excludes it, and a mutation run proved an explicit
    /// self-exclusion guard could be deleted with the whole suite still green: it was a clause no test could
    /// make load-bearing. The property still holds and is still asserted; it is enforced here.
    ///
    /// Among qualifying candidates the order is: most channels first (a 5.1 dub is worth more than a 2.0 one),
    /// then input order. Channels-first can pick a different language than input order would; that is
    /// deliberate and arbitrary-but-deterministic, because there is no signal in the container that ranks one
    /// foreign language above another. The primary is chosen elsewhere and is never reconsidered here.
    static func alternate(from tracks: [AudioTrack], primaryIndex: Int) -> AudioTrack? {
        guard let primary = tracks.first(where: { $0.index == primaryIndex }) else { return nil }
        let primaryLanguage = languageKey(primary.language)
        guard !isUnknownLanguage(primaryLanguage) else { return nil }
        let qualifying = tracks.filter { candidate in
            guard candidate.codecID == primary.codecID else { return false }
            let key = languageKey(candidate.language)
            guard !isUnknownLanguage(key) else { return false }
            return key != primaryLanguage
        }
        return qualifying.min { a, b in
            if a.channels != b.channels { return a.channels > b.channels }
            return a.index < b.index
        }
    }

    // MARK: - Probe bounds

    /// Packet budget for the alternate's first-packet probe. Every packet read here is held in memory until
    /// the mux loop drains it, so this is a memory bound as much as a latency one. Generous enough that a
    /// normally-interleaved matroska cluster (audio arrives within a handful of packets of the video) always
    /// clears it, tight enough that a source which simply never emits the track gives up quickly.
    static let alternateProbeMaxPackets = 600

    /// Byte budget for the same probe, and the bound that actually protects the device. A packet count says
    /// nothing about size: 600 4K keyframe packets would be hundreds of megabytes held before write_header,
    /// on the same jetsam budget the player's read-ahead buffers already strain. 8 MiB is several seconds of
    /// even a high-bitrate UHD stream.
    static let alternateProbeMaxBytes = 8 << 20

    /// Wall-clock budget for the same probe. The probe runs BEFORE avformat_write_header, so every second
    /// spent here is a second AVPlayer has no bytes at all. Two seconds is well inside the start watchdog and
    /// well inside the pre-init moov deadline that would otherwise demote the session.
    static let alternateProbeDeadlineSecs = 2.0

    /// Why the alternate was dropped. Deliberately a closed set of fixed strings: these reach the diagnostics
    /// log, and the log must never carry source-derived text of unbounded length.
    enum DropReason: String {
        case packetBudget = "no first packet within the probe packet budget"
        case byteBudget = "no first packet within the probe byte budget"
        case deadline = "no first packet before the probe wall-clock deadline"
        case sourceEnded = "source ended before the alternate delivered a packet"
        case cancelled = "session cancelled during the alternate probe"
        case allocationFailed = "packet allocation failed during the alternate probe"
    }

    /// What the probe loop should do next.
    enum ProbeOutcome: Equatable {
        case keepProbing
        case delivered
        case drop(DropReason)
    }

    /// The probe decision for the state the loop has reached.
    ///
    /// `delivered` is checked FIRST, ahead of every budget. A packet that arrives on the same iteration that
    /// exhausts a budget is a real delivery, and dropping the track for it would throw away a second language
    /// the muxer was about to get for free. Every other ordering here is arbitrary and only decides which
    /// reason is reported when two limits trip together.
    static func probeOutcome(delivered: Bool,
                             packetsRead: Int,
                             bytesRead: Int,
                             elapsedSecs: Double,
                             sourceEnded: Bool,
                             cancelled: Bool,
                             allocationFailed: Bool) -> ProbeOutcome {
        if delivered { return .delivered }
        if cancelled { return .drop(.cancelled) }
        if allocationFailed { return .drop(.allocationFailed) }
        if sourceEnded { return .drop(.sourceEnded) }
        if packetsRead >= alternateProbeMaxPackets { return .drop(.packetBudget) }
        if bytesRead >= alternateProbeMaxBytes { return .drop(.byteBudget) }
        if elapsedSecs >= alternateProbeDeadlineSecs { return .drop(.deadline) }
        return .keepProbing
    }
}
