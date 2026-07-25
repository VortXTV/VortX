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
    }

    struct SessionResponse: Codable, Sendable, Equatable {
        let sessionID: String
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

    // MARK: - Session status

    struct Chapter: Codable, Sendable, Equatable {
        let start: Double
        let title: String
    }

    /// Everything the client's player engine needs from a mount that is not on its own machine.
    ///
    /// This exists because the local mount object is not just a URL: the engine calls seven things on it
    /// (`markEngineReady`, `sourceDurationSeconds`, `timelineOriginSeconds`, `authoritativeFrameRate`,
    /// `chapters`, `isMountHealthy`, `mountProgress`). A remote mount has to answer all seven, and this is that
    /// answer, polled.
    struct SessionStatus: Codable, Sendable, Equatable {
        /// The init segment has published AND the remux buffer has not failed. False is AUTHORITATIVE: the host
        /// is telling the client its remux died, and the client fails over to on-device immediately rather than
        /// waiting out a threshold.
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
