import Foundation

/// Pure decision logic for the EMBEDDED SUBTITLE renditions served alongside the MKV -> fMP4 remux,
/// deliberately kept in a file that imports nothing but Foundation.
///
/// Why a separate rendition at all, rather than muxing the subtitles into the fMP4: the mp4 muxer cannot
/// stream-copy Matroska text or PGS subtitle codecs. `avformat_write_header` fails and takes the whole session
/// down with it, which is why subtitles are absent from the remuxed output today and why the mux map below is
/// left untouched. HLS has a first-class answer for exactly this shape: a SEPARATE subtitle rendition
/// (`EXT-X-MEDIA:TYPE=SUBTITLES`) whose media playlist points at WebVTT segments. AVPlayer selects those
/// natively through its own media-selection group, so the video/audio pipeline, the Dolby Vision signaling and
/// the delayed moov are all completely unaffected by anything in this file.
///
/// SCOPE, stated honestly: native text subtitles plus HDMV PGS packets that the caller's bounded asynchronous
/// recognizer has already converted to UTF-8. Other bitmap formats remain explicitly unavailable because this
/// policy has no pixel payload path.
///
/// Why the decisions live here: the code that USES them is split between `VortXMKVRemuxStream` (which pulls in
/// the whole FFmpeg vendor tree) and `VortXRemuxHLSServer` (Network.framework). A suite written against either
/// could only have asserted on source text, and a substring assertion proves a line exists, not that it runs.
/// A mutant that preserved every asserted string while appending `false` to a guard has already passed a whole
/// suite on this codebase. Keeping the decisions here makes them executable, so
/// `app/Tests/SubtitleRenditionPolicyTests.swift` calls the real functions and a SEMANTIC break turns it red.
enum SubtitleRenditionPolicy {

    // MARK: - Formats

    /// The text subtitle payload shapes this file can turn into WebVTT cue text.
    ///
    /// Carried as a case rather than a libav codec id because AVCodecID raw values are not stable across
    /// FFmpeg versions, and this file must stay free of libav. The caller maps `codec_id` to a case where the
    /// libav headers are already imported, including PGS only when its recognition pipeline is available.
    enum TextFormat: Equatable, Sendable {
        /// SubRip. The demuxer hands over the cue text itself, which may carry `<i>`/`<b>`/`<u>` markup that
        /// WebVTT understands unchanged.
        /// HDMV PGS: BluRay bitmap subtitles, recognised to text by VortXPGSSubtitleOCR before they reach
        /// this policy. By the time a payload carries this format it is already UTF-8 text, so the cue path
        /// treats it exactly like plain text while preserving the source track's original order.
        case pgs
        case subRip
        /// ASS/SSA. The demuxer hands over ONE dialogue line's fields without the `Dialogue:` keyword and
        /// without timing: `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
        case ass
        /// mov_text (tx3g). A 2-byte big-endian length followed by that many bytes of UTF-8. Style records
        /// may follow the text and are ignored.
        case movText
        /// WebVTT carried inside the container. The payload is already cue text.
        case webVTT
        /// Raw text with no markup convention.
        case plainText
    }

    // MARK: - Track qualification

    /// One subtitle track eligible for WebVTT delivery, carried as plain values so this file needs no libav types.
    struct SourceTrack: Equatable, Sendable {
        let index: Int          // the libav input stream index; the caller's key for routing packets back
        let format: TextFormat
        let language: String    // the stream's "language" metadata tag, raw
        let title: String       // the stream's "title" metadata tag, raw ("" when absent)
        let isDefault: Bool     // AV_DISPOSITION_DEFAULT
        let isForced: Bool      // AV_DISPOSITION_FORCED

        init(index: Int, format: TextFormat, language: String, title: String,
             isDefault: Bool, isForced: Bool) {
            self.index = index
            self.format = format
            self.language = language
            self.title = title
            self.isDefault = isDefault
            self.isForced = isForced
        }
    }

    /// One subtitle rendition as it will be advertised and served.
    struct Rendition: Equatable, Sendable {
        let id: Int             // 0-based ordinal; names every URI this rendition serves
        let sourceIndex: Int
        let format: TextFormat
        let name: String        // the human label AVPlayer shows in its subtitle picker
        let language: String    // normalised language key, or the explicit HLS fallback "und"
        let isDefault: Bool
        let isAutoSelect: Bool
        let isForced: Bool
    }

    /// Applies the server's explicit optional-rendition withdrawals to a producer snapshot. Reapplying the
    /// same set to a later snapshot is also the stale-topology check: unrelated additions/removals remain
    /// visible instead of being mistaken for the withdrawal itself.
    static func survivors(_ snapshot: [Rendition], withdrawing ids: Set<Int>) -> [Rendition] {
        snapshot.filter { !ids.contains($0.id) }
    }

    /// Comparison form of a language tag: trimmed and lowercased. Same normalisation `MultiAudioPolicy` uses,
    /// repeated rather than shared because both files are deliberately dependency-free.
    static func languageKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when a language key names no actual language. The matroska demuxer substitutes a spec default for
    /// an untagged track and MP4 files commonly carry "und", so these tags prove nothing.
    static func isUnknownLanguage(_ key: String) -> Bool {
        key.isEmpty || key == "und" || key == "unk" || key == "mis" || key == "zxx"
    }

    /// A bitmap subtitle can be decoded only when its source stream owns one of the bounded OCR contexts. This
    /// reason is attached before the HLS master is advertised, so a row that cannot produce cues is disabled
    /// rather than presented as a working selection.
    static let pgsCapacityUnavailableReason =
        "PGS subtitle unavailable because this playback session reached its OCR track limit"

    /// Selects the PGS streams the bounded recognizer can actually serve while retaining every ordinary text
    /// subtitle. Default, forced, and preferred-language PGS rows receive capacity first. The returned list
    /// remains in source order so stable track identity and picker ordering do not change.
    static func admittedTracks(
        from tracks: [SourceTrack],
        maximumPGSStreams: Int,
        preferredLanguages: [String]
    ) -> [SourceTrack] {
        let capacity = max(0, maximumPGSStreams)
        let pgs = tracks.enumerated().filter { $0.element.format == .pgs }
        guard pgs.count > capacity else { return tracks }

        let preferred = preferredLanguages.map(languageMatchKey)
        func preferredRank(_ language: String) -> Int? {
            preferred.firstIndex(of: languageMatchKey(language))
        }
        let ranked = pgs.sorted { lhs, rhs in
            func rank(_ item: (offset: Int, element: SourceTrack)) -> (Int, Int, Int) {
                if item.element.isDefault { return (0, 0, item.offset) }
                if item.element.isForced { return (1, 0, item.offset) }
                if let preferred = preferredRank(item.element.language) {
                    return (2, preferred, item.offset)
                }
                return (3, 0, item.offset)
            }
            let left = rank(lhs)
            let right = rank(rhs)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
        let admitted = Set(ranked.prefix(capacity).map { $0.element.index })
        return tracks.filter { $0.format != .pgs || admitted.contains($0.index) }
    }

    private static func languageMatchKey(_ raw: String) -> String {
        let key = languageKey(raw)
        guard !isUnknownLanguage(key) else { return key }
        return Locale(identifier: key).language.languageCode?.identifier.lowercased() ?? key
    }

    /// English names for the language tags a media file actually carries, keyed by ISO 639-2/B and 639-1.
    /// Anything not listed falls back to the uppercased tag, which is still a usable label ("KAZ") and is
    /// honest about what the file said. Deliberately short: this is a display convenience, not a locale
    /// database, and pretending otherwise would mean shipping a table nobody maintains.
    private static let languageNames: [String: String] = [
        "eng": "English", "en": "English",
        "spa": "Spanish", "es": "Spanish",
        "fre": "French", "fra": "French", "fr": "French",
        "ger": "German", "deu": "German", "de": "German",
        "ita": "Italian", "it": "Italian",
        "por": "Portuguese", "pt": "Portuguese",
        "rus": "Russian", "ru": "Russian",
        "jpn": "Japanese", "ja": "Japanese",
        "kor": "Korean", "ko": "Korean",
        "chi": "Chinese", "zho": "Chinese", "zh": "Chinese",
        "ara": "Arabic", "ar": "Arabic",
        "hin": "Hindi", "hi": "Hindi",
        "dut": "Dutch", "nld": "Dutch", "nl": "Dutch",
        "swe": "Swedish", "sv": "Swedish",
        "nor": "Norwegian", "no": "Norwegian",
        "dan": "Danish", "da": "Danish",
        "fin": "Finnish", "fi": "Finnish",
        "pol": "Polish", "pl": "Polish",
        "tur": "Turkish", "tr": "Turkish",
        "heb": "Hebrew", "he": "Hebrew",
        "tha": "Thai", "th": "Thai",
        "vie": "Vietnamese", "vi": "Vietnamese",
        "ces": "Czech", "cze": "Czech", "cs": "Czech",
        "gre": "Greek", "ell": "Greek", "el": "Greek",
        "ukr": "Ukrainian", "uk": "Ukrainian",
        "ind": "Indonesian", "id": "Indonesian",
        "hun": "Hungarian", "hu": "Hungarian",
        "ron": "Romanian", "rum": "Romanian", "ro": "Romanian",
    ]

    /// The label AVPlayer shows. The source's own title wins when it has one (rips label their tracks
    /// "English SDH", "Signs & Songs", "Forced", and that is more informative than any name derived from a
    /// three-letter tag), otherwise the language name. "Forced" is appended only when the track says forced
    /// and the title has not already said so, so a track never reads "Forced (Forced)".
    static func displayName(language: String, title: String, isForced: Bool) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = languageKey(language)
        let base: String
        if !trimmedTitle.isEmpty {
            base = trimmedTitle
        } else if isUnknownLanguage(key) {
            base = "Unknown"
        } else {
            base = languageNames[key] ?? key.uppercased()
        }
        if isForced, !base.lowercased().contains("forced") { return "\(base) (Forced)" }
        return base
    }

    /// The renditions to advertise for a source's text subtitle tracks, in source order.
    ///
    /// Rules, each of which the suite asserts both ways:
    ///   - source order is kept, so the track the rip put first stays first in the picker;
    ///   - every text track is retained, including same-language tracks with identical metadata;
    ///   - colliding labels gain a deterministic source-index suffix so the viewer never has to guess;
    ///   - at most ONE rendition carries DEFAULT=YES, which HLS requires, and it is the FIRST track the source
    ///     itself marked default. We never invent a default: turning subtitles on for a user who did not ask
    ///     is a worse failure than leaving them off.
    static func renditions(from tracks: [SourceTrack]) -> [Rendition] {
        var drafts: [Rendition] = []
        var takenNames = Set<String>()
        var defaultTaken = false
        for track in tracks {
            let key = languageKey(track.language)
            let language = isUnknownLanguage(key) ? "und" : key
            let sourceName = displayName(language: track.language, title: track.title, isForced: track.isForced)
            var name = sourceName
            if takenNames.contains(name.lowercased()) {
                name = "\(sourceName) (Source \(track.index))"
            }
            let disambiguationBase = name
            var disambiguator = 1
            while takenNames.contains(name.lowercased()) {
                name = "\(disambiguationBase) \(disambiguator)"
                disambiguator += 1
            }
            takenNames.insert(name.lowercased())

            let isDefault = track.isDefault && !defaultTaken
            if isDefault { defaultTaken = true }
            drafts.append(Rendition(id: drafts.count,
                                    sourceIndex: track.index,
                                    format: track.format,
                                    name: name,
                                    language: language,
                                    isDefault: isDefault,
                                    isAutoSelect: false,
                                    isForced: track.isForced))
        }

        // RFC 8216 requires every AUTOSELECT=YES member of one group to have a distinct selection tuple.
        // Prefer the source's one default inside its tuple, then the first source-ordered rendition.
        var autoSelectWinner: [String: Int] = [:]
        for rendition in drafts where rendition.isDefault {
            autoSelectWinner[autoSelectTuple(rendition)] = rendition.id
        }
        for rendition in drafts where autoSelectWinner[autoSelectTuple(rendition)] == nil {
            autoSelectWinner[autoSelectTuple(rendition)] = rendition.id
        }
        return drafts.map { rendition in
            Rendition(id: rendition.id,
                      sourceIndex: rendition.sourceIndex,
                      format: rendition.format,
                      name: rendition.name,
                      language: rendition.language,
                      isDefault: rendition.isDefault,
                      isAutoSelect: autoSelectWinner[autoSelectTuple(rendition)] == rendition.id,
                      isForced: rendition.isForced)
        }
    }

    private static func autoSelectTuple(_ rendition: Rendition) -> String {
        "\(rendition.language)|\(rendition.isForced)"
    }

    // MARK: - Master playlist advertising

    /// The GROUP-ID every subtitle rendition of a session shares, and the value the variants reference.
    static let groupID = "subs"

    /// The URI of a rendition's media playlist, relative to the master. Flat on purpose: the server routes on
    /// exact path shapes, and a flat name needs no directory semantics.
    static func playlistURI(_ rendition: Rendition) -> String { playlistURI(renditionID: rendition.id) }

    /// Same URI from a bare rendition id, for the serve path (which has routed an id, not a Rendition) and
    /// its diagnostic line. One owner of the shape, matching `segmentURI(renditionID:segmentID:)`.
    static func playlistURI(renditionID: Int) -> String { "subs\(renditionID).m3u8" }

    /// The URI of one WebVTT segment of a rendition, relative to the master.
    static func segmentURI(renditionID: Int, segmentID: Int) -> String { "subs\(renditionID)-\(segmentID).vtt" }

    /// What a request path names, when it names a subtitle resource at all.
    enum Request: Equatable, Sendable {
        case playlist(renditionID: Int)
        case segment(renditionID: Int, segmentID: Int)
    }

    /// Parse a request path into the subtitle resource it names, or nil when it names none.
    ///
    /// This lives here rather than inline in the server's router for a reason found the hard way in this very
    /// change: the first version was written inline and dropped the wrong number of trailing characters, so
    /// every subtitle playlist would have 404'd, and nothing outside a device could have caught it. Parsing
    /// the URIs this file GENERATES belongs with the generator, where a test can hold both ends.
    static func parseRequest(path: String) -> Request? {
        guard path.hasPrefix("/subs") else { return nil }
        let body = path.dropFirst("/subs".count)
        if body.hasSuffix(".m3u8") {
            guard let id = Int(body.dropLast(".m3u8".count)), id >= 0 else { return nil }
            return .playlist(renditionID: id)
        }
        if body.hasSuffix(".vtt") {
            let parts = body.dropLast(".vtt".count).components(separatedBy: "-")
            guard parts.count == 2, let id = Int(parts[0]), let segmentID = Int(parts[1]),
                  id >= 0, segmentID >= 0 else { return nil }
            return .segment(renditionID: id, segmentID: segmentID)
        }
        return nil
    }

    /// One `EXT-X-MEDIA` line. LANGUAGE is always present; unknown source metadata is represented by the
    /// standard `und` code so every row has a valid, non-empty selection tuple.
    static func mediaTag(_ rendition: Rendition) -> String {
        var tag = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(groupID)\",NAME=\"\(quoteSafe(rendition.name))\""
        tag += ",LANGUAGE=\"\(quoteSafe(rendition.language))\""
        tag += ",DEFAULT=\(rendition.isDefault ? "YES" : "NO")"
        tag += ",AUTOSELECT=\(rendition.isAutoSelect ? "YES" : "NO")"
        tag += ",FORCED=\(rendition.isForced ? "YES" : "NO")"
        tag += ",URI=\"\(playlistURI(rendition))\""
        return tag
    }

    /// Attribute appended to every `EXT-X-STREAM-INF` so its variant can see the group. Empty when there is
    /// nothing to advertise, which is what keeps a subtitle-less source's master byte-identical to before.
    static func streamInfAttribute(renditionCount: Int) -> String {
        renditionCount > 0 ? ",SUBTITLES=\"\(groupID)\"" : ""
    }

    /// Strip the characters that cannot appear inside an HLS quoted-string (double quote, CR, LF). A rip's
    /// track title is source-derived text, so it is sanitised before it reaches a playlist rather than
    /// trusted.
    static func quoteSafe(_ raw: String) -> String {
        String(raw.map { ch in
            if ch == "\"" { return "'" }
            if ch == "\r" || ch == "\n" { return " " }
            return ch
        })
    }

    // MARK: - Subtitle media playlist

    /// A rendition's media playlist mirrors the one immutable resident VIDEO window. Absolute ids survive
    /// eviction, durations are inherited from video, and a sliding active playlist is never falsely EVENT.
    ///
    /// There is deliberately no `EXT-X-MAP`: WebVTT segments are self-contained documents with no init.
    /// `isEvent` defaults false so a sliding active playlist is never falsely EVENT, which is the invariant the
    /// paragraph above states. An engine host retaining its whole timeline sets it, because there the promise is
    /// true. See the note on `DVPlaybackPolicy.mediaPlaylistLines`.
    static func mediaPlaylist(renditionID: Int, window: VortXHLSWindow,
                              ended: Bool, targetDuration: Int,
                              isEvent: Bool = false) -> [String] {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, targetDuration))",
            "#EXT-X-MEDIA-SEQUENCE:\(window.mediaSequence)",
        ]
        if isEvent { lines.append("#EXT-X-PLAYLIST-TYPE:EVENT") }
        if window.mediaSequence == 0 {
            lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
        }
        for segment in window.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segmentURI(renditionID: renditionID, segmentID: segment.id))
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines
    }

    // MARK: - Cues

    /// Bounds applied by the demux caller before it copies a packet and again before decoded text is retained.
    /// Checked subtraction in `canStore` makes the combined bound safe even for hostile integer inputs.
    static let maxPacketBytes = 1 << 20
    static let maxStoredBytes = 8 << 20

    static func canDecodePayload(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maxPacketBytes
    }

    static func canStore(existingBytes: Int, incomingBytes: Int) -> Bool {
        guard existingBytes >= 0,
              existingBytes <= maxStoredBytes,
              canDecodePayload(byteCount: incomingBytes) else { return false }
        return incomingBytes <= maxStoredBytes - existingBytes
    }

    /// One subtitle cue on the OUTPUT timeline, in seconds.
    struct Cue: Equatable, Sendable {
        /// Provenance retained only where the source format supplies an unambiguous event identity. It never
        /// reaches the WebVTT document, so native cue identifiers remain a function of the visible timeline.
        enum Provenance: Equatable, Sendable {
            case assEvent(String)
        }

        let start: Double
        let end: Double
        let text: String
        let provenance: Provenance?

        init(start: Double, end: Double, text: String, provenance: Provenance? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.provenance = provenance
        }
    }

    /// Shown-for duration used when the container gives a packet no duration. Two seconds is the common
    /// authoring floor for a short line; guessing is better than dropping the cue, and better than leaving it
    /// on screen indefinitely.
    static let fallbackCueDuration = 2.0
    /// A cue may not be shorter than this. Some containers round a short line to zero.
    static let minCueDuration = 0.1
    /// A cue may not outlast this. A malformed duration field (seen as multi-hour values on badly muxed rips)
    /// would otherwise pin one line on screen for the rest of the film.
    static let maxCueDuration = 30.0
    /// The most cues this policy will leave on screen at one instant.
    ///
    /// `webVTTDocument` writes no cue settings (no `line:`/`position:`/`align:`, because ASS positioning is
    /// stripped long before it reaches here), so AVFoundation draws every simultaneously active cue at the same
    /// default bottom-centre position and they stack. Three is deliberately generous: two-speaker dialogue plus
    /// one forced-narrative line is real content, and past that a stack is an authoring artefact (layered
    /// typesetting, animation steps) that no viewer could read anyway.
    static let maxSimultaneousCues = 3
    /// The maximum packet timestamp skew for duplicate records from one already-proven ASS event. This never
    /// applies to SRT/WebVTT/plain/PGS cues or to ASS records without explicit event provenance.
    private static let assEventDuplicateTimingTolerance = 0.15
    /// Seven days is far beyond any supported playback asset while keeping millisecond conversion safely
    /// inside `Int` on every product architecture.
    static let maximumTimelineSeconds = 7.0 * 24 * 60 * 60

    /// Build one cue from a demuxed packet, or nil when the payload carries nothing displayable.
    ///
    /// Returns nil rather than a placeholder for: a packet with no usable timestamp (`startSeconds` negative,
    /// which is how the caller reports AV_NOPTS_VALUE), an undecodable payload, and text that is empty once
    /// markup is stripped. Dropping one cue is always preferable to emitting a malformed WebVTT document,
    /// because a malformed document costs the whole rendition.
    static func cue(payload: Data, format: TextFormat,
                    startSeconds: Double, durationSeconds: Double) -> Cue? {
        guard canDecodePayload(byteCount: payload.count),
              startSeconds >= 0,
              startSeconds.isFinite,
              startSeconds <= maximumTimelineSeconds else { return nil }
        let decoded = decodedCue(payload: payload, format: format)
        guard let text = decoded.text else { return nil }
        var duration = durationSeconds
        if !duration.isFinite || duration <= 0 { duration = fallbackCueDuration }
        duration = min(max(duration, minCueDuration), maxCueDuration)
        guard duration <= maximumTimelineSeconds - startSeconds else { return nil }
        return Cue(start: startSeconds, end: startSeconds + duration, text: text,
                   provenance: decoded.provenance)
    }

    /// The displayable text of a packet payload, or nil when there is none.
    static func plainText(payload: Data, format: TextFormat) -> String? {
        decodedCue(payload: payload, format: format).text
    }

    /// Decode one packet's visible text and, for ASS only, preserve a source event identity when it is strong
    /// enough to prove two packets came from the same dialogue event. The identity deliberately requires a
    /// nonzero numeric ReadOrder and every non-text header field. Many loose ASS-like payloads use `0` for every
    /// row, so treating that placeholder as an event identity would collapse intentional simultaneous cues.
    private static func decodedCue(payload: Data, format: TextFormat)
        -> (text: String?, provenance: Cue.Provenance?) {
        let raw: String
        let provenance: Cue.Provenance?
        switch format {
        case .movText:
            guard let unwrapped = movTextBody(payload) else { return (nil, nil) }
            raw = unwrapped
            provenance = nil
        case .ass:
            let dialogue = assDialogue(decodeUTF8(payload))
            raw = dialogue.text
            provenance = dialogue.eventIdentity.map(Cue.Provenance.assEvent)
        case .subRip, .webVTT, .plainText, .pgs:
            raw = decodeUTF8(payload)
            provenance = nil
        }
        // ASS override blocks and escapes appear inside SRT payloads too (rips convert one to the other and
        // leave `{\an8}` in place), so the unescape runs for every text format.
        let unescaped = stripASSMarkup(raw)
        return (sanitizeCueText(unescaped, escapeAngleBrackets: format != .subRip && format != .webVTT),
                provenance)
    }

    /// Decode bytes as UTF-8, substituting replacement characters for invalid sequences rather than failing:
    /// one bad byte in a two-hour track must not cost the whole cue.
    private static func decodeUTF8(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// The text of a tx3g sample: a 2-byte big-endian length followed by that many UTF-8 bytes. Trailing style
    /// boxes are ignored. Returns nil when the sample is too short to carry the length itself, or when the
    /// declared length overruns the sample.
    static func movTextBody(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, 2 + length <= bytes.count else { return nil }
        return String(decoding: bytes[2..<(2 + length)], as: UTF8.self)
    }

    /// Number of comma-separated fields that precede the Text field of an ASS dialogue line
    /// (ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect).
    private static let assFieldsBeforeText = 8

    /// The Text field of an ASS/SSA dialogue payload. A payload with fewer fields than a dialogue line is
    /// returned whole: it is more likely a plain line than a truncated ASS record, and showing it is better
    /// than showing nothing.
    ///
    /// There is deliberately no special handling for a leading `Dialogue:` keyword. The demuxer strips it, and
    /// a payload that still carried it would put it in field 0 (ReadOrder), which is never part of the Text
    /// field, so the keyword cannot reach the screen either way. A strip step was written here first and then
    /// deleted: a mutant that disabled it changed no output, which is the definition of a clause that enforces
    /// nothing.
    static func assDialogueText(_ raw: String) -> String {
        assDialogue(raw).text
    }

    /// Parsed ASS dialogue text plus a conservative source-event identity. The source stream's rendition is
    /// already fixed at the caller, so the ReadOrder plus complete non-text dialogue header is enough to bind
    /// duplicate records to one event without comparing rendered text, style tags, or timestamps.
    private static func assDialogue(_ raw: String) -> (text: String, eventIdentity: String?) {
        let fields = raw.split(separator: ",", maxSplits: assFieldsBeforeText, omittingEmptySubsequences: false)
        guard fields.count > assFieldsBeforeText else { return (raw, nil) }
        let readOrder = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let identity: String?
        if isExplicitASSReadOrder(readOrder) {
            identity = fields[..<assFieldsBeforeText].joined(separator: ",")
        } else {
            identity = nil
        }
        return (String(fields[assFieldsBeforeText]), identity)
    }

    /// `0` is a common anonymous placeholder in ASS-like payloads. A nonzero decimal ReadOrder is the narrow
    /// form we can treat as an explicit source event identifier; every other spelling remains unproven.
    private static func isExplicitASSReadOrder(_ readOrder: String) -> Bool {
        guard !readOrder.isEmpty,
              readOrder.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(readOrder), value > 0 else { return false }
        return true
    }

    /// Remove ASS override blocks (`{\an8}`, `{\i1}`) and expand the ASS escapes that carry line structure.
    /// The override blocks are positioning and styling instructions with no WebVTT equivalent; leaving them in
    /// would print them on screen as literal text.
    static func stripASSMarkup(_ raw: String) -> String {
        var out = ""
        var depth = 0
        var iterator = raw.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? iterator.next() {
            pending = nil
            if ch == "{" { depth += 1; continue }
            if ch == "}" { if depth > 0 { depth -= 1 }; continue }
            if depth > 0 { continue }
            if ch == "\\" {
                guard let next = iterator.next() else { out.append(ch); break }
                switch next {
                case "N", "n": out.append("\n")
                case "h": out.append(" ")
                default: out.append(ch); pending = next
                }
                continue
            }
            out.append(ch)
        }
        return out
    }

    /// Make text safe to place in a WebVTT cue body, or nil when nothing displayable is left.
    ///
    /// Three things here are load-bearing, all of them about not corrupting the DOCUMENT:
    ///   - a BLANK LINE terminates a cue, so runs of newlines are collapsed;
    ///   - the literal sequence `-->` inside a body would read as a new cue's timing line, so it is broken up;
    ///   - `&` starts a WebVTT entity, so a bare one is escaped. Angle brackets are escaped only for formats
    ///     with no markup convention of their own: SRT and WebVTT payloads use `<i>`/`<b>`/`<u>` exactly as
    ///     WebVTT does, and escaping those would print the tags instead of applying them.
    static func sanitizeCueText(_ raw: String, escapeAngleBrackets: Bool) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = escapeAmpersands(text)
        if escapeAngleBrackets {
            text = text.replacingOccurrences(of: "<", with: "&lt;")
            text = text.replacingOccurrences(of: ">", with: "&gt;")
        }
        text = text.replacingOccurrences(of: "-->", with: "--&gt;")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Escape every `&` that does not already begin an entity, so re-escaping an already-escaped payload does
    /// not print `&amp;amp;`.
    private static func escapeAmpersands(_ raw: String) -> String {
        var out = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            if ch == "&" {
                let tail = raw[index...]
                let isEntity = tail.hasPrefix("&amp;") || tail.hasPrefix("&lt;")
                    || tail.hasPrefix("&gt;") || tail.hasPrefix("&nbsp;") || tail.hasPrefix("&quot;")
                out += isEntity ? "&" : "&amp;"
            } else {
                out.append(ch)
            }
            index = raw.index(after: index)
        }
        return out
    }

    // MARK: - WebVTT documents

    /// `HH:MM:SS.mmm`, the only timestamp form WebVTT accepts for a cue over an hour, and accepted for shorter
    /// cues too, so one form covers everything. Negative and non-finite inputs clamp to zero; huge positive
    /// values clamp to the supported timeline before integer conversion, so malformed metadata cannot trap.
    static func timestamp(_ seconds: Double) -> String {
        let safe: Double
        if !seconds.isFinite || seconds <= 0 {
            safe = 0
        } else {
            safe = min(seconds, maximumTimelineSeconds)
        }
        let totalMillis = Int((safe * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        return String(format: "%02d:%02d:%02d.%03d",
                      totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, millis)
    }

    /// Resolve duplicated and stacked cues on one rendition's timeline, in start order.
    ///
    /// The producer appends every converted packet unconditionally and nothing downstream compares a cue with
    /// its neighbours, so two shapes that are normal in real rips reach the screen as a wall of text:
    ///   - an ASS animation, karaoke or fade run, authored as many short events carrying IDENTICAL text, all
    ///     of which collapse to the same string once the override blocks are stripped (and each becomes a
    ///     `fallbackCueDuration` cue when the container reports no duration, so they all overlap);
    ///   - layered typesetting authored to sit at different screen positions, which all lands on the one
    ///     position a cue-setting-free WebVTT document has.
    /// Both are answered with pure interval work: identical text that overlaps or touches becomes ONE cue
    /// spanning the run, and beyond `maxSimultaneousCues` the OLDEST cues are truncated to the newcomer's start.
    ///
    /// Truncation rather than deletion is what keeps this fail-soft: a clipped cue is still shown, just not
    /// past the point where the stack made it unreadable, so genuine two-speaker dialogue and forced narrative
    /// survive intact. The single exception is a cue left with less than `minCueDuration` to run, which is not
    /// displayable at all and would only emit a degenerate range.
    ///
    /// Cross-segment repetition of a straddling cue is NOT touched here: RFC 8216 section 3.5 requires it, and
    /// this function never sees a segment boundary.
    ///
    /// Idempotent by construction, which matters because the caller runs it once per served segment over the
    /// same array: the result holds no identical-text cues that overlap or touch, and no instant with more than
    /// `maxSimultaneousCues` active, so a second pass finds nothing to do.
    static func normalizedCues(_ all: [Cue]) -> [Cue] {
        guard all.count > 1 else { return all }
        // A TOTAL order, not merely by start: equal starts must not depend on whether the sort happens to be
        // stable, or two runs over one array could produce two different documents for the same segment.
        let ordered = all.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.text < $1.text
        }

        // Pass 1, coalesce identical text across the whole run it spans. `open` holds only the cues that can
        // still reach the next start, which is what keeps this linear in practice rather than a scan of
        // everything stored so far. Ends only grow here, so the array stays start-ordered.
        var merged: [Cue] = []
        merged.reserveCapacity(ordered.count)
        var open: [Int] = []
        for cue in ordered {
            open.removeAll { merged[$0].end < cue.start }
            if let slot = open.first(where: { canCoalesce(merged[$0], cue) }) {
                merged[slot] = Cue(start: merged[slot].start,
                                   end: max(merged[slot].end, cue.end),
                                   text: merged[slot].text,
                                   provenance: merged[slot].provenance)
                continue
            }
            merged.append(cue)
            open.append(merged.count - 1)
        }

        // Pass 2, cap simultaneity. The active count can only RISE at a cue's start, so checking every start is
        // a complete check of the timeline, and a truncation written here is visible to every later start.
        var dropped = Set<Int>()
        var active: [Int] = []
        for index in merged.indices {
            let start = merged[index].start
            active.removeAll { merged[$0].end <= start }
            if active.count >= maxSimultaneousCues {
                let excess = active.count - (maxSimultaneousCues - 1)
                for slot in active.prefix(excess) {
                    if start - merged[slot].start < minCueDuration {
                        dropped.insert(slot)
                    } else {
                        merged[slot] = Cue(start: merged[slot].start,
                                           end: start,
                                           text: merged[slot].text,
                                           provenance: merged[slot].provenance)
                    }
                }
                active.removeFirst(excess)
            }
            active.append(index)
        }
        guard !dropped.isEmpty else { return merged }
        return merged.indices.filter { !dropped.contains($0) }.map { merged[$0] }
    }

    /// The legacy literal-text merge remains valid unless both cues carry explicit, conflicting ASS event
    /// identities. Once ASS markup has been stripped, two different source dialogue events can render to
    /// exactly the same visible text, so visible equality alone is not enough to collapse proven events.
    /// Unproven and non-ASS cues retain the established literal-text behavior.
    static func canCoalesce(_ lhs: Cue, _ rhs: Cue) -> Bool {
        if lhs.text == rhs.text {
            if case let .assEvent(lhsEvent)? = lhs.provenance,
               case let .assEvent(rhsEvent)? = rhs.provenance {
                return lhsEvent == rhsEvent
            }
            return true
        }
        return isDuplicateASSRenderRecord(lhs, rhs)
    }

    /// Coalesce only an ASS duplicate record whose originating event is explicitly identical. Text is compared
    /// after whitespace flattening because ASS override blocks and hard spaces have already lost their visual
    /// semantics before this policy sees them. Nothing based only on visible text, styling, or timing qualifies.
    private static func isDuplicateASSRenderRecord(_ lhs: Cue, _ rhs: Cue) -> Bool {
        guard lhs.text != rhs.text,
              case let .assEvent(lhsEvent)? = lhs.provenance,
              case let .assEvent(rhsEvent)? = rhs.provenance,
              lhsEvent == rhsEvent,
              withinASSDuplicateTimingTolerance(lhs.start, rhs.start),
              withinASSDuplicateTimingTolerance(lhs.end, rhs.end),
              let lhsText = assFlattenedTextKey(lhs.text),
              let rhsText = assFlattenedTextKey(rhs.text),
              lhsText == rhsText else { return false }
        return true
    }

    /// Decimal packet times such as `10.15` cannot always subtract to the exact mathematical 150 ms boundary.
    /// Admit only the few ULPs required by that representation error, while retaining the inclusive 150 ms rule.
    private static func withinASSDuplicateTimingTolerance(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(abs(lhs), abs(rhs), assEventDuplicateTimingTolerance)
        let roundingAllowance = scale * Double.ulpOfOne * 8
        return abs(lhs - rhs) <= assEventDuplicateTimingTolerance + roundingAllowance
    }

    /// A deliberately literal ASS comparison key: only whitespace is flattened. Punctuation, words, markup,
    /// and every other character remain significant, so this cannot turn a translation or a different lyric
    /// into a duplicate merely because it shares a visual style.
    private static func assFlattenedTextKey(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// The cues that fall inside `start..<end`, in start order.
    ///
    /// OVERLAP, not containment: a cue straddling a segment boundary belongs to BOTH segments, because a
    /// player that starts inside the second segment has never seen the first and would otherwise show
    /// nothing. Duplicating it is exactly what the HLS spec expects, and identical cues in adjacent segments
    /// are the normal case, not an error. A cue is included when it is still on screen after `start` and
    /// appeared before `end`.
    ///
    /// Normalization runs on the FULL array BEFORE the window filter, not after, for two reasons: a run of
    /// identical cues can begin before this segment, and a stack can only be resolved against the cues on both
    /// sides of the boundary. This is the one funnel every served document passes through, so normalizing here
    /// covers every rendition and every segment.
    static func cues(_ all: [Cue], overlapping start: Double, end: Double) -> [Cue] {
        normalizedCues(normalizedCues(all), overlapping: start, end: end)
    }

    /// The window filter over an ALREADY-normalized array, so a caller serving many segments off one cue array
    /// pays the normalization once instead of once per segment (see `NormalizedCueCache`). Split out rather than
    /// duplicated: the boundary predicate that decides which cues straddle a segment has exactly ONE definition,
    /// and `cues(_:overlapping:end:)` is this plus the normalization.
    static func normalizedCues(_ normalized: [Cue], overlapping start: Double, end: Double) -> [Cue] {
        guard end > start else { return [] }
        return normalized.filter { $0.end > start && $0.start < end }
    }

    /// A caller-owned memo over `normalizedCues(_:)`.
    ///
    /// The served path renders one WebVTT document per (rendition, segment), and each one normalized the FULL
    /// cue array: on a 20k-cue title that is a sort plus two array copies PER SEGMENT, on the producer thread
    /// (FAIL-260804-06, which is exactly the thread that must not be spending time on repeated work).
    ///
    /// `(count, last cue's interval)` is a SUFFICIENT identity for that array, checked against every way the
    /// collector actually mutates it: an append moves the count; extending a run's LAST cue in place (the one
    /// in-place edit that exists - identical text whose end grows) strictly raises `lastEnd`; a reset empties it.
    /// Nothing rewrites a cue in the middle, which is the only shape these two terms would miss. The interval
    /// term doubles as cross-rendition safety, so a same-count array from a different timeline misses too.
    ///
    /// `normalizedCues` itself stays pure and independently tested; this only decides when to call it.
    struct NormalizedCueCache {
        /// How many times the pure function actually ran. Exposed for the memo's own test (and cheap enough to
        /// keep in production, where it is the one number that says whether the memo is working).
        private(set) var recomputeCount = 0

        private struct Fingerprint: Equatable {
            let count: Int
            let lastStart: Double
            let lastEnd: Double
        }

        private var fingerprint: Fingerprint?
        private var cached: [Cue] = []

        init() {}

        /// `normalizedCues(all)`, computed at most once per distinct input.
        mutating func normalized(_ all: [Cue]) -> [Cue] {
            let mark = Fingerprint(count: all.count,
                                   lastStart: all.last?.start ?? -1,
                                   lastEnd: all.last?.end ?? -1)
            if let fingerprint, fingerprint == mark { return cached }
            recomputeCount += 1
            fingerprint = mark
            cached = SubtitleRenditionPolicy.normalizedCues(all)
            return cached
        }

        /// `cues(all, overlapping: start, end: end)` with the normalization memoized. Same result by
        /// construction: both compose the same two pure steps.
        mutating func cues(_ all: [Cue], overlapping start: Double, end: Double) -> [Cue] {
            SubtitleRenditionPolicy.normalizedCues(normalized(all), overlapping: start, end: end)
        }
    }

    // MARK: - Global demux settlement

    /// A bounded allowance for normal packet interleave. Segment completeness advances from the maximum
    /// timestamp observed across the whole demux, never from the next subtitle packet, so a dialogue-free
    /// stretch can still publish valid empty WebVTT segments.
    static let interleaveMarginSeconds = 2.0

    /// User-facing reason used only at EOF, after the complete source proved that a convertible track produced
    /// no valid cue. Silence and rejected packets remain provisional while the producer can still deliver a
    /// later valid cue.
    static let cueConversionUnavailableReason = "Subtitle conversion produced no usable cues"

    enum CueTruthStatus: Equatable, Sendable {
        /// No packet from this source track has reached the collector yet. This is normal during silent spans.
        case waitingForPacket
        /// One or more packets failed conversion, but the track remains recoverable until EOF.
        case waitingForEOF
        /// At least one packet produced a valid cue.
        case available
        /// EOF proved that the complete track produced no usable cue.
        case unavailable
    }

    /// Per-source conversion truth. Global settlement still owns playlist completeness; this state answers the
    /// separate question of whether one advertised source track has ever produced a usable cue.
    struct CueTruthState: Equatable, Sendable {
        private(set) var status: CueTruthStatus = .waitingForPacket
        private(set) var arrivedPacketCount = 0
        private(set) var validCueCount = 0

        /// Record a packet whose text parser or bitmap recognizer produced no cue. A rejected packet is never
        /// permanent evidence by itself because a later packet from the same track may still be valid.
        mutating func observeRejectedPacket() {
            arrivedPacketCount += 1
            guard validCueCount == 0, status != .unavailable else { return }
            status = .waitingForEOF
        }

        /// One real cue is sufficient proof that the rendition works. This also permits a row to recover from
        /// a previously published unavailable state if an out-of-order producer callback arrives.
        mutating func observeValidCue() {
            arrivedPacketCount += 1
            validCueCount += 1
            status = .available
        }

        /// Only EOF is permanent negative evidence. The demux frontier proves an interval is complete, not that
        /// a track cannot produce valid dialogue later in the title.
        mutating func settleAtEOF() {
            guard validCueCount == 0, status != .unavailable else { return }
            status = .unavailable
        }
    }

    enum InvalidationReason: String, Equatable, Sendable {
        case lateTimestampRegression
        case timelineBounds
        case payloadBound
        case storedBound
        case cueCountBound
    }

    struct SettlementState: Equatable, Sendable {
        private var maximumGlobalTimestamp = 0.0
        private(set) var settledBefore = 0.0
        private(set) var isValid = true
        private(set) var invalidationReason: InvalidationReason?
        private var reachedEOF = false
        /// Pending asynchronous work keyed by a mount-local token. The value is the earliest point at which
        /// the eventual cue could overlap the media window.
        private var pending: [UInt64: Double] = [:]

        var hasReachedEOF: Bool { reachedEOF }
        var pendingCount: Int { pending.count }

        mutating func invalidate(_ reason: InvalidationReason) {
            guard isValid else { return }
            isValid = false
            invalidationReason = reason
            pending.removeAll(keepingCapacity: false)
        }

        /// Register OCR work before the same packet advances the global watermark. A pending token holds the
        /// publication frontier at its timestamp until a cue or terminal no-cue result resolves it.
        @discardableResult
        mutating func registerPending(token: UInt64, timestamp: Double) -> Bool {
            guard isValid, pending[token] == nil else { return false }
            guard timestamp.isFinite,
                  timestamp >= 0,
                  timestamp <= maximumTimelineSeconds else {
                invalidate(.timelineBounds)
                return false
            }
            guard timestamp >= settledBefore else {
                invalidate(.lateTimestampRegression)
                return false
            }
            pending[token] = timestamp
            recomputeSettledBefore()
            return true
        }

        func containsPending(token: UInt64) -> Bool {
            pending[token] != nil
        }

        /// The caller appends any recognised cue before resolving the token.
        @discardableResult
        mutating func resolvePending(token: UInt64) -> Bool {
            guard pending.removeValue(forKey: token) != nil else { return false }
            recomputeSettledBefore()
            return true
        }

        /// Returns false and permanently invalidates this optional feature when input arrives behind the
        /// already published frontier or outside the supported timeline.
        mutating func observeGlobalTimestamp(_ timestamp: Double) -> Bool {
            guard isValid else { return false }
            guard timestamp.isFinite,
                  timestamp >= 0,
                  timestamp <= maximumTimelineSeconds else {
                invalidate(.timelineBounds)
                return false
            }
            guard timestamp >= settledBefore else {
                invalidate(.lateTimestampRegression)
                return false
            }
            maximumGlobalTimestamp = max(maximumGlobalTimestamp, timestamp)
            recomputeSettledBefore()
            return true
        }

        @discardableResult
        mutating func finish() -> Bool {
            guard isValid, pending.isEmpty else { return false }
            reachedEOF = true
            settledBefore = maximumTimelineSeconds
            return true
        }

        /// Returns the fully settled prefix of the exact resident video window. A failure is represented by
        /// nil so the caller omits subtitle signaling; an empty-but-valid prefix is a real empty window.
        func settledWindow(videoWindow: VortXHLSWindow) -> VortXHLSWindow? {
            guard isValid,
                  videoWindow.segments.allSatisfy({
                      $0.start.isFinite && $0.duration.isFinite && $0.duration > 0
                  }) else { return nil }
            if reachedEOF { return videoWindow }
            let settled = Array(videoWindow.segments.prefix {
                $0.end <= settledBefore
            })
            guard !settled.isEmpty else { return nil }
            return VortXHLSWindow(segments: settled)
        }

        private mutating func recomputeSettledBefore() {
            guard isValid, !reachedEOF else { return }
            let globalCandidate = max(0, maximumGlobalTimestamp - interleaveMarginSeconds)
            let pendingCandidate = pending.values.min() ?? maximumTimelineSeconds
            settledBefore = max(settledBefore, min(globalCandidate, pendingCandidate))
        }
    }

    /// A complete WebVTT segment document.
    ///
    /// `X-TIMESTAMP-MAP` ties cue time zero to media time zero. The remux timeline starts at zero (the media
    /// playlist states `EXT-X-START:TIME-OFFSET=0`) and cue times here are absolute remux times, so every
    /// segment uses the same identity map. Keeping the full interval in every overlapping segment is required by
    /// RFC 8216 section 3.5 and prevents AVFoundation from treating a clipped copy as a second cue.
    /// A cue-less segment still produces a valid document with a header and no cues, which is what a stretch
    /// of film with no dialogue must serve.
    /// Renders a self-contained HLS WebVTT segment. Timings remain absolute on the zero-origin remux timeline;
    /// `segmentStart` and `segmentEnd` are retained for the call-site contract and overlap selection, but are not
    /// used to clip or rebase the cue. Without the full repeated interval AVFoundation can retain a cue from the
    /// previous sliding segment and render its overlapping copy as a second native subtitle.
    static func webVTTDocument(cues: [Cue], segmentStart: Double? = nil,
                               segmentEnd: Double? = nil) -> String {
        _ = segmentStart // Segment overlap selects cues; a selected cue retains its complete interval.
        _ = segmentEnd
        let mpegTimestamp: Int64 = 0
        var lines = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:\(mpegTimestamp),LOCAL:00:00:00.000", ""]
        for cue in cues {
            // A zero-or-negative-length cue is not displayable and some parsers reject the whole document
            // over one, so it is skipped here as a last line of defence even though `cue(payload:...)`
            // already enforces a minimum length.
            // RFC 8216 requires a full cue in every segment it overlaps. Repeating the absolute interval keeps
            // fresh joiners and AVFoundation's native cue identity on the same remux timeline.
            let start = cue.start
            let end = cue.end
            let startMilliseconds = Int((max(0, start) * 1_000).rounded())
            let endMilliseconds = Int((max(0, end) * 1_000).rounded())
            guard endMilliseconds > startMilliseconds else { continue }
            lines.append("")
            // A STABLE cue identifier, derived from the cue's immutable absolute identity (start, text) so every
            // segment's copy of a straddling cue carries the SAME id. A remux may extend the already-spooled
            // cue's end as it learns more of the stream; including that mutable boundary would create a second
            // AVFoundation cue identity and stack both native subtitles. Apple's HLS authoring guidance uses the
            // id so AVFoundation recognises cross-segment copies as one cue and renders it once.
            lines.append(Self.cueIdentifier(startSeconds: cue.start, endSeconds: cue.end, text: cue.text,
                                            provenance: cue.provenance))
            lines.append("\(timestamp(start)) --> \(timestamp(end))")
            lines.append(cue.text)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// FNV-1a over the cue's immutable identity: the same cue served from any segment, or with a later-known
    /// end, gets the same id. `endSeconds` remains an explicit call-site argument because it is the cue's actual
    /// timing, but it intentionally does not participate in identity. The id carries no user text; it only needs
    /// uniqueness among distinct cue starts and bodies. Proven ASS event identity is included when available so
    /// two legitimate events with equal start and visible text cannot collide; the mutable end is excluded.
    static func cueIdentifier(startSeconds: Double, endSeconds _: Double, text: String,
                              provenance: Cue.Provenance? = nil) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let provenanceKey: String
        if case let .assEvent(event)? = provenance {
            provenanceKey = event
        } else {
            provenanceKey = ""
        }
        for byte in "\(startSeconds)|\(provenanceKey)|\(text)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return "cue-" + String(hash, radix: 16)
    }
}
