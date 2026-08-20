import Foundation

/// THE VORTX ENGINE PROTOCOL: the wire contract between a VortX client and a VortX engine host.
///
/// An engine host is a machine with power and disk to spare (today: a Mac) that does the CONTAINER and I/O
/// work for a client that has neither. The canonical case is the CEO's: an Apple TV plugged into a Dolby Vision
/// panel, with a Mac on the same network. The Mac demuxes the MKV, rewrites the Dolby Vision RPU from Profile 7
/// to 8.1, muxes fragmented MP4, cuts segments and holds the spool; the Apple TV receives one clean
/// DV-signalled stream and spends its entire chip decoding and presenting it.
///
/// THE ONE THING THAT NEVER MOVES. The host is always UPSTREAM of the decoder, never the decoder. Dolby Vision
/// reaches the panel as a DV-signalled elementary stream emitted by the device physically in the HDMI chain, so
/// the Apple TV decodes, always. The moment a design has the host produce PIXELS rather than a BITSTREAM, true
/// DV is forfeit: you must re-encode, the client still has to decode the re-encode, and you have bought
/// generation loss for nothing. Every operation in this protocol is therefore either a stream copy or a
/// side-channel (thumbnails, an explicitly-requested transcode of something the client cannot play at all).
///
/// DELIBERATELY BORING AND CLIENT-AGNOSTIC. Plain HTTP/1.1, JSON bodies, a bearer token, and URLs the client
/// composes itself. Nothing here is Apple-specific: there is no plist, no Keyed Archiver, no AVFoundation type,
/// and no assumption that the client is tvOS. The Android and desktop clients are expected to speak exactly
/// this, and the shapes below are the specification they implement against. Fields are added, never
/// repurposed; every decoder tolerates unknown keys and every optional has a defined absent-meaning.
///
/// TRANSPORT HONESTY. The body crosses the LAN as cleartext, exactly as `VXDiagExportPolicy` documents for its
/// own case. The bearer token and the per-session capability raise the bar from "anyone on this Wi-Fi can pull
/// this household's media" to "you must have completed a pairing the owner physically approved", and that is
/// what they are for. They are NOT transport security and the UI must not imply otherwise.
enum VortXEngineProtocol {

    /// Bumped only for a BREAKING change. Additive fields do not move it. A client refuses a host whose major
    /// version it does not know rather than guessing at a shape.
    static let version = 1

    static let basePath = "/engine/v1"

    enum Path {
        /// Unauthenticated. The one endpoint an unpaired client may call, so it can discover what a host is and
        /// whether pairing is even possible before asking a human for a code.
        static let info = "\(basePath)/info"
        /// Unauthenticated but code-gated and rate-limited. Exchanges a short human code for a bearer token.
        static let pair = "\(basePath)/pair"
        /// Authenticated. Creates a hosted remux session.
        static let session = "\(basePath)/session"

        /// Authenticated per-session routes.
        static func status(_ id: String) -> String { "\(basePath)/session/\(id)/status" }
        static func ready(_ id: String) -> String { "\(basePath)/session/\(id)/ready" }
        static func teardown(_ id: String) -> String { "\(basePath)/session/\(id)" }
    }

    static let authorizationHeader = "Authorization"
    static func bearer(_ token: String) -> String { "Bearer " + token }

    /// Extract a bearer token from an `Authorization` header value. Case-insensitive on the scheme, as RFC 7235
    /// requires; returns nil for any other scheme so a `Basic` header can never be mistaken for a token.
    static func token(fromAuthorization value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: - Capabilities

    /// What a host can do, advertised so a client never has to probe by attempting and failing. A client MUST
    /// treat an unknown capability string as "ignore", so a newer host can advertise more to an older client
    /// without breaking it.
    enum Capability: String, Codable, CaseIterable, Sendable {
        /// Host the Dolby Vision / plain MKV remux. Stream copy. The core of the feature.
        case remux
        /// The hosted remux retains its ENTIRE produced timeline instead of sliding a window, so the client may
        /// seek backwards anywhere into what has been produced. This is the capability the on-device lane
        /// fundamentally cannot have: it is bounded by a jetsam ceiling, and a host is bounded by a disk.
        case seekAnywhere
        /// Host the torrent streaming server for this client (the `stremiox.serverURL` lane).
        case torrentServer
        /// Transcode codecs the client cannot decode at all, using the host's VideoToolbox. This is NEW
        /// CAPABILITY, not an offload: the client's sandbox cannot spawn a transcoder at any price. It is never
        /// used for Dolby Vision, which is stream-copied.
        case transcode
        /// Generate scrub thumbnails host-side, once, instead of repeatedly on the client.
        case trickplay
    }

    // MARK: - GET /engine/v1/info

    struct Info: Codable, Sendable, Equatable {
        /// Human name for the host, shown in the client's pairing UI ("Daksh's Mac Studio").
        let name: String
        /// Protocol major version. A client refuses a host whose value it does not know.
        let protocolVersion: Int
        /// App/daemon version string, for diagnostics only. Never parsed for behaviour.
        let engineVersion: String
        /// "macOS". Informational; the protocol is not platform-specific.
        let platform: String
        let capabilities: [Capability]
        /// True when this host requires pairing before any authenticated call. Always true today. Present so a
        /// client can render an honest UI rather than assuming, and so the field exists if a future deployment
        /// (a single-user appliance) legitimately does not.
        let requiresPairing: Bool
        /// True when the host is currently ACCEPTING pairing (the owner has a code on screen). A client uses
        /// this to say "open VortX on your Mac and turn on pairing" instead of failing opaquely.
        let pairingOpen: Bool
        /// Sessions currently hosted, and the cap. Lets a client explain a refusal before making it.
        let activeSessions: Int
        let maximumSessions: Int
    }

    // MARK: - POST /engine/v1/pair

    struct PairRequest: Codable, Sendable, Equatable {
        /// The short code the owner reads off the host's screen. Compared case-insensitively with separators
        /// stripped, because a human is typing it on a TV remote.
        let code: String
        /// What the client calls itself, shown in the host's paired-devices list so the owner can revoke a
        /// specific device later ("Living Room Apple TV").
        let clientName: String
        /// Stable per-install identifier, so re-pairing the same device replaces its token instead of
        /// accumulating one per attempt.
        let clientID: String
    }

    struct PairResponse: Codable, Sendable, Equatable {
        /// Long-lived bearer token. The client stores it in its Keychain and never writes it to a backup.
        let token: String
        let hostName: String
        let capabilities: [Capability]
    }

    // MARK: - POST /engine/v1/session

    enum RemuxMode: String, Codable, Sendable {
        /// The Dolby Vision lane: Profile 7 to 8.1 RPU rewrite, DV signalling in the master playlist.
        case dolbyVision
        /// A straight container re-wrap for a non-DV source. No RPU handling, no panel switch.
        case plain
    }

    struct AudioSelectionPreferences: Sendable, Equatable {
        let preferredLanguages: [String]?
        let rejectTerms: [String]?
    }

    /// The control body is already capped, but selection cost multiplies source tracks by both lists. Keep the
    /// policy small and deterministic before any remux is created. Nil remains distinct from an explicit empty
    /// list for backward compatibility and English-fallback semantics.
    static let maximumAudioPreferenceCount = 16
    static let maximumAudioPreferenceScalars = 64

    private struct NormalizedOptionalList {
        let value: [String]?
    }

    static func normalizedAudioSelectionPreferences(
        preferredLanguages: [String]?,
        rejectTerms: [String]?
    ) -> AudioSelectionPreferences? {
        guard let languages = normalizedAudioPreferenceList(preferredLanguages),
              let rejects = normalizedAudioPreferenceList(rejectTerms) else {
            return nil
        }
        return AudioSelectionPreferences(
            preferredLanguages: languages.value,
            rejectTerms: rejects.value)
    }

    private static func normalizedAudioPreferenceList(
        _ rawValues: [String]?
    ) -> NormalizedOptionalList? {
        guard let rawValues else { return NormalizedOptionalList(value: nil) }
        guard rawValues.count <= maximumAudioPreferenceCount else { return nil }
        var seen = Set<String>()
        var values: [String] = []
        for raw in rawValues {
            guard raw.unicodeScalars.count <= maximumAudioPreferenceScalars else { return nil }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard seen.insert(normalized).inserted else { continue }
            values.append(normalized)
        }
        return NormalizedOptionalList(value: values)
    }

    struct SessionRequest: Codable, Sendable, Equatable {
        /// The source the HOST will fetch: a debrid URL, a direct URL, or the host's own streaming server.
        let input: String
        /// Headers the host must send when fetching `input`. These carry the user's debrid credentials, which
        /// is precisely why the control surface is token-gated: unauthenticated, this endpoint would be a
        /// request-forgery proxy that also leaks the owner's tokens to anyone on the Wi-Fi.
        let headers: [String: String]?
        let mode: RemuxMode
        /// Source-timeline second to begin producing at. The host seeks its input once before muxing.
        let startAtSeconds: Double
        /// Ask the host to retain the whole produced timeline so the client can seek backwards freely. The host
        /// may decline (returning `retainsFullTimeline: false`) if it lacks the disk; the client must read the
        /// response rather than assume its request was honoured.
        let requestFullTimeline: Bool
        /// Stable source-container stream index to make primary for this remux. Nil preserves the host's
        /// preference-ranked default. This is a source identity, never an HLS option index.
        let selectedAudioStreamIndex: Int?
        /// Ordered source-language preferences captured by the client before it starts the first remux.
        /// Nil means an older client supplied no preference policy. An empty array explicitly permits the
        /// policy's English fallback.
        let preferredAudioLanguages: [String]?
        /// Case-insensitive source-title terms excluded from automatic selection. Explicit source selection
        /// still wins. Nil means an older client supplied no rejection policy.
        let audioRejectTerms: [String]?

        init(input: String,
             headers: [String: String]?,
             mode: RemuxMode,
             startAtSeconds: Double,
             requestFullTimeline: Bool,
             selectedAudioStreamIndex: Int?,
             preferredAudioLanguages: [String]? = nil,
             audioRejectTerms: [String]? = nil) {
            self.input = input
            self.headers = headers
            self.mode = mode
            self.startAtSeconds = startAtSeconds
            self.requestFullTimeline = requestFullTimeline
            self.selectedAudioStreamIndex = selectedAudioStreamIndex
            self.preferredAudioLanguages = preferredAudioLanguages
            self.audioRejectTerms = audioRejectTerms
        }
    }

    struct SessionResponse: Codable, Sendable, Equatable {
        let sessionID: String
        /// Opaque, host-issued generation for this exact mount.  A session id alone is not enough to safely
        /// acknowledge teardown after a delayed request or a host restart.
        let mountGeneration: String
        /// The port the MEDIA is served on. Distinct from the control port: each session's remux server binds
        /// its own OS-assigned ephemeral port.
        let mediaPort: Int
        /// The absolute path of the master playlist, already carrying this session's capability.
        ///
        /// The client composes the URL as `http://<the host it dialled>:<mediaPort><mediaPath>`. The host
        /// deliberately does NOT return a full URL: it does not know which of its own addresses the client can
        /// reach, and guessing breaks the two topologies that matter most (a multi-homed Mac, and Tailscale,
        /// where the reachable address is on a tunnel rather than the LAN).
        let mediaPath: String
        /// Whether the host actually granted full-timeline retention. False means the client must keep clamping
        /// backward seeks exactly as it does on-device.
        let retainsFullTimeline: Bool
    }

    /// Additive teardown handshake.  The protocol major remains compatible; a client that requires this
    /// receipt refuses an older host rather than treating a successful DELETE as proof of producer unwind.
    struct TeardownRequest: Codable, Sendable, Equatable {
        static let currentVersion = 1
        let version: Int
        let sessionID: String
        let mountGeneration: String

        init(sessionID: String, mountGeneration: String) {
            self.version = Self.currentVersion
            self.sessionID = sessionID
            self.mountGeneration = mountGeneration
        }
    }

    struct TeardownReceipt: Codable, Sendable, Equatable {
        let version: Int
        let sessionID: String
        let mountGeneration: String
        /// True only after the host's producer terminal edge released its input/network resources.
        let producerQuiescent: Bool
    }

    /// A receipt is a capability to continue the same source in MPV, not merely a successful HTTP result.
    /// Keep the comparison centralized so every client rejects old, cross-session, cross-mount, and incomplete
    /// replies identically.
    static func acceptsTeardownReceipt(
        _ receipt: TeardownReceipt?,
        for request: TeardownRequest
    ) -> Bool {
        guard let receipt else { return false }
        return receipt.version == TeardownRequest.currentVersion
            && receipt.producerQuiescent
            && receipt.sessionID == request.sessionID
            && receipt.mountGeneration == request.mountGeneration
    }

    // MARK: - Session status

    struct Chapter: Codable, Sendable, Equatable {
        let start: Double
        let title: String
    }

    enum AudioDelivery: String, Codable, Sendable {
        /// The source packet bytes are copied into the remux unchanged.
        case streamCopy
        /// The source codec is decoded and encoded to an AVPlayer-compatible codec by the existing bounded
        /// one-track transcoder. This describes delivery, never the source codec shown beside the row.
        case transcode
    }

    /// One source-container audio identity that the AVPlayer remux can deliver.
    ///
    /// The list is metadata, not an HLS rendition promise. A client selects one source index, then opens a
    /// replacement remux at the same source playhead with that track as the in-band primary. This keeps every
    /// deliverable source track visible without multiplying live muxers and buffers.
    struct AudioTrack: Codable, Sendable, Equatable {
        let sourceIndex: Int
        /// Codec stored in the source container. This remains the picker identity even when the selected row
        /// is decoded and encoded to a different AVPlayer-compatible codec.
        let codec: String
        /// Codec actually carried by the produced primary audio stream. Nil is a legacy host that reported
        /// source identity only, so clients fall back to `codec`.
        let outputCodec: String?
        /// Channel count stored in the source container. This remains source-inventory truth even when the
        /// selected row is transcoded to a narrower produced layout.
        let channels: Int
        /// Channel count carried by the produced primary audio stream. Nil means an older host did not publish
        /// this fact; a known transcode must then remain unknown rather than borrowing the source count.
        let outputChannels: Int?
        let language: String
        let title: String
        /// True only after the selected stream-copy output's structured `dec3` receipt proved JOC. Source
        /// profile metadata alone is not sufficient, and a transcoded row is always false.
        let isAtmosJOC: Bool
        /// Optional so a client can still decode status from an older host. Nil has the legacy meaning:
        /// stream-copyable, because older hosts published only that subset.
        let delivery: AudioDelivery?

        init(sourceIndex: Int, codec: String, channels: Int, language: String, title: String,
             isAtmosJOC: Bool, delivery: AudioDelivery? = nil, outputCodec: String? = nil,
             outputChannels: Int? = nil) {
            self.sourceIndex = sourceIndex
            self.codec = codec
            self.outputCodec = outputCodec
            self.channels = channels
            self.outputChannels = outputChannels
            self.language = language
            self.title = title
            self.isAtmosJOC = isAtmosJOC
            self.delivery = delivery
        }

        /// Best available truth for the audible stream. Older hosts omit `outputCodec`, where source and
        /// output were historically treated as the same value.
        var activeCodec: String { outputCodec ?? codec }

        /// Best available channel truth for the audible stream. Legacy rows omitted `delivery` and represented
        /// only stream-copyable tracks, so their source count remains a safe fallback. Once a row is explicitly
        /// a transcode, a missing output count is unknown rather than the source layout.
        var activeChannels: Int? {
            if let outputChannels, outputChannels > 0 { return outputChannels }
            guard delivery != .transcode, channels > 0 else { return nil }
            return channels
        }
    }

    enum SubtitleDelivery: String, Codable, Sendable {
        /// Text cues are converted into the HLS WebVTT rendition named by `renditionIndex`.
        case webVTT
        /// Legacy unavailable marker retained for wire compatibility with older clients. New hosts pair this
        /// with `SubtitleTrack.unavailableKind` to distinguish bitmap from other unsupported source formats.
        case bitmapUnavailable
    }

    enum SubtitleUnavailableKind: String, Codable, Sendable {
        case bitmap
        case unsupported
    }

    /// Stable source-container subtitle identity. Available text rows map to an HLS media-option index;
    /// unavailable rows remain visible with an honest reason instead of disappearing.
    struct SubtitleTrack: Codable, Sendable, Equatable {
        let sourceIndex: Int
        let codec: String
        let language: String
        let title: String
        let isForced: Bool
        let delivery: SubtitleDelivery
        let renditionIndex: Int?
        let unavailableReason: String?
        /// Optional so older hosts remain decodable. `.bitmapUnavailable` is the legacy unavailable delivery
        /// marker; a missing exact kind therefore resolves to bitmap for backward compatibility.
        let unavailableKind: SubtitleUnavailableKind?

        init(sourceIndex: Int,
             codec: String,
             language: String,
             title: String,
             isForced: Bool,
             delivery: SubtitleDelivery,
             renditionIndex: Int?,
             unavailableReason: String?,
             unavailableKind: SubtitleUnavailableKind? = nil) {
            self.sourceIndex = sourceIndex
            self.codec = codec
            self.language = language
            self.title = title
            self.isForced = isForced
            self.delivery = delivery
            self.renditionIndex = renditionIndex
            self.unavailableReason = unavailableReason
            self.unavailableKind = unavailableKind
        }

        var resolvedUnavailableKind: SubtitleUnavailableKind? {
            guard delivery == .bitmapUnavailable else { return nil }
            return unavailableKind ?? .bitmap
        }
    }

    /// Everything the client's player engine needs from a mount that is not on its own machine.
    ///
    /// This exists because the local mount object is not just a URL: the engine calls seven things on it
    /// (`markEngineReady`, `sourceDurationSeconds`, `timelineOriginSeconds`, `authoritativeFrameRate`,
    /// `chapters`, `isMountHealthy`, `mountProgress`). A remote mount has to answer all seven, and this is that
    /// answer, polled.
    struct SessionStatus: Codable, Sendable, Equatable {
        /// Legacy aggregate: the init segment has published AND the remux buffer has not failed. Before the
        /// optional facts below existed, false also meant "init is still pending", so a client cannot treat a
        /// lone false as terminal during the bounded startup wait.
        let healthy: Bool
        /// Source runtime in seconds, 0 when not yet parsed. The client synthesizes a finite VOD duration from
        /// it, since live HLS delivery keeps `AVPlayerItem.duration` indefinite.
        let durationSeconds: Double
        /// The source-timeline second represented by player clock zero. Established only by a mapped base-video
        /// packet after a successful input seek.
        let timelineOriginSeconds: Double
        /// The classifier's session-authoritative frame rate, 0 when unknown. The client must prefer this over
        /// an asset track (which can be absent for HLS) and must not substitute an invented 60Hz.
        let frameRate: Double
        let chapters: [Chapter]
        /// Monotonic progress counters for the client's progress-aware start watchdog: they let a slow-but-alive
        /// 4K source be told apart from a true stall.
        let producedSegments: Int
        let producedBytes: Int
        /// The remux reached end of source.
        let ended: Bool
        /// Exact init publication state. Optional so a newer client can still decode an older host, where nil
        /// leaves `healthy == true` as the only positive init receipt.
        let initPublished: Bool?
        /// Exact terminal remux failure state. Optional so an older host's pre-init `healthy == false` remains
        /// pending until the startup deadline rather than being mistaken for a diagnosed failure.
        let failed: Bool?
        /// Whether classify has published signalling yet. Until it has, the fields below are meaningless.
        let signalingPublished: Bool
        /// Whether this session is genuinely Dolby Vision, plus the geometry needed to request the panel switch.
        ///
        /// THESE EXIST FOR ONE REASON AND IT IS THE WHOLE POINT OF THE FEATURE. On device, the Dolby Vision panel
        /// switch is fired from inside the remux server, when it serves the master playlist. A host is a Mac, and
        /// that code is compiled out on macOS, so a hosted session would never switch the client's panel and the
        /// Apple TV would present a true DV stream on an HDR10 panel. The client therefore fires the switch
        /// ITSELF, and these three fields are what it needs to do so: the display criteria wants a real frame
        /// rate and real dimensions, and an invented 60Hz is explicitly not acceptable.
        ///
        /// The client can also fire it EARLIER than the on-device lane does, before the item is ever attached,
        /// which is the ordering Apple Tech Talk 503 actually asks for.
        let dolbyVision: Bool
        let width: Int
        let height: Int
        /// Declared primary-variant bandwidth. Optional so a newer client can still decode an older host.
        let bandwidth: Int?
        /// Optional for wire compatibility with a host built before explicit HDR-only recovery existed.
        /// "HLG" identifies a Profile 8.4 base layer; "PQ" and nil-compatible sources recover as HDR10.
        let videoRange: String?
        /// Whether the source has an honest non-DV base layer. Nil means an older host and fails closed.
        let supportsHDRFallback: Bool?
        /// Every source audio track this remux can deliver to AVPlayer. Optional for compatibility with hosts
        /// built before source-track selection was part of the protocol.
        let audioTracks: [AudioTrack]?
        /// The source index actually selected after validation. Optional for older hosts and before classify.
        let selectedAudioStreamIndex: Int?
        /// Stable subtitle inventory. Optional for compatibility with a host built before source identities
        /// and explicit bitmap-unavailable rows were published.
        let subtitleTracks: [SubtitleTrack]?
        /// The furthest source second produced so far. On a full-timeline session everything from
        /// `timelineOriginSeconds` to here is seekable; without it, only the sliding window is.
        let producedEdgeSeconds: Double
    }

    // MARK: - Errors

    struct ErrorBody: Codable, Sendable, Equatable {
        let error: String
        let detail: String?
    }

    // MARK: - Pairing codes

    /// Human-typable pairing code: 6 digits. Digits only, because it is entered on a TV remote where letters
    /// cost a grid navigation each. 10^6 is small, which is why it is defended by being SHORT-LIVED, by being
    /// accepted only while the owner has the pairing screen open, and by a hard attempt cap, rather than by
    /// entropy.
    static let pairingCodeDigits = 6

    static func makePairingCode() -> String {
        (0..<pairingCodeDigits).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// Compare a typed code with the live one, ignoring whitespace and dashes a human may have added.
    static func pairingCodeMatches(typed: String, expected: String) -> Bool {
        let normalize: (String) -> String = { raw in
            String(raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
        }
        let a = normalize(typed)
        let b = normalize(expected)
        guard a.count == pairingCodeDigits, b.count == pairingCodeDigits else { return false }
        return a == b
    }

    /// How long a pairing window stays open once the owner opens it.
    static let pairingWindowSeconds: TimeInterval = 300

    /// Wrong-code attempts tolerated inside one pairing window before it closes itself. Six digits is only a
    /// million possibilities, so the attempt cap is doing the real work here, not the code length.
    static let pairingAttemptLimit = 5

    /// Bearer token size in bytes. 32 bytes is 256 bits, rendered as 64 hex characters.
    static let tokenBytes = 32

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenBytes)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Discovery

    /// Bonjour service type. Registered under the `_tcp` domain because the control surface is HTTP over TCP.
    static let bonjourServiceType = "_vortx-engine._tcp"

    /// TXT record keys. Kept minimal: discovery answers "is there a host, what is it called, and what can it
    /// do", and everything else comes from `/engine/v1/info` over a real connection. Putting capability detail
    /// in TXT would mean two sources of truth that can disagree.
    enum TXTKey {
        static let protocolVersion = "v"
        static let hostName = "name"
        static let capabilities = "caps"
    }
}
