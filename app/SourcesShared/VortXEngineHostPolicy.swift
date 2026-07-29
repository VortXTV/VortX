import Foundation

/// EXTERNAL ENGINE MODE, the pure decisions.
///
/// The CEO's ask is "let the Mac do the heavy lifting so the Apple TV can spend its whole chip on showing
/// Dolby Vision". The one thing that cannot move is the DECODE: Dolby Vision reaches the panel as a
/// DV-signalled elementary stream emitted by the device in the HDMI chain, so the Apple TV is always the
/// decoder (see `AVPlayerEngine.loadFile`'s Tech Talk 503 note). What CAN move is everything upstream of the
/// decoder: the MKV demux, the Profile 7 -> 8.1 RPU rewrite, the fMP4 mux, the segment cutting and the disk
/// spool. That work is a STREAM COPY. It never re-encodes a video sample, which is exactly why it is lossless
/// and why it keeps true DV alive. Nothing in this file, and nothing built on it, may introduce a transcode
/// into the DV path.
///
/// This enum holds every decision that is a pure function of its inputs, split out of the networking for the
/// same reason `VXDiagExportPolicy` was split out of `VXDiagExport`: what actually needs proving is WHO may
/// fetch a session's bytes, WHICH host a session binds to, HOW a byte range resolves, and WHEN a remote mount
/// is abandoned for the on-device one. All four are pure. The sockets are not, and are not here.
///
/// TOP INVARIANT, and the reason the shapes below look asymmetric: **with external mode off, every decision
/// here must reduce to today's behaviour exactly.** The DV lane was stabilised after two field regressions
/// (build 189's fail-closed topology check, build 190's window-slide), and the overwhelming majority of users
/// have no Mac. So a session with no capability returns `.legacy`, which is the request parse the server has
/// always done: method-blind, Range-blind, path-exact. The strict HTTP layer (method checking, capability
/// gating, Range/206) activates only when a capability exists, which is only ever true for a LAN-hosted
/// session. `VortXEngineHostPolicyTests.defaultOff*` pins that equivalence.
enum VortXEngineHostPolicy {

    // MARK: - Capability (the media-surface credential)

    /// Bytes of capability material minted per hosted session. 16 bytes is 128 bits, rendered below as 32 hex
    /// characters of URL path. Same size and same CSPRNG as `VXDiagExportPolicy.makeCapabilityPath`.
    static let capabilityBytes = 16

    /// The path segment every hosted session's resources hang under: `/r/<capability>/<resource>`.
    static let sessionPathPrefix = "/r/"

    /// Mint fresh capability material. Uses the system CSPRNG (`SystemRandomNumberGenerator` backs
    /// `UInt8.random`), minted per session, so a previous session's path is worthless.
    static func makeCapability() -> String {
        var bytes = [UInt8](repeating: 0, count: capabilityBytes)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A capability is well-formed iff it is exactly the minted shape: `2 * capabilityBytes` lowercase hex
    /// characters. Checked on the serving side so a caller cannot configure a session with a weak or empty
    /// credential and silently get an open relay.
    static func isWellFormedCapability(_ capability: String) -> Bool {
        guard capability.count == capabilityBytes * 2 else { return false }
        return capability.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The absolute path a hosted session's resource is fetched at. Every playlist URI the remux server emits
    /// is RELATIVE (`media.m3u8`, `init.mp4`, `seg{N}.m4s`, `audio{id}.m3u8`, `subs{id}.m3u8`), so prefixing
    /// the mount authenticates every child fetch for free: the client resolves each child against the parent's
    /// directory, which already carries the capability. No playlist generator changes, and no reliance on
    /// AVFoundation propagating `AVURLAssetHTTPHeaderFieldsKey` to HLS child requests.
    static func mountPath(capability: String, resource: String) -> String {
        let leaf = resource.hasPrefix("/") ? String(resource.dropFirst()) : resource
        return sessionPathPrefix + capability + "/" + leaf
    }

    // MARK: - Bind host

    /// Which local endpoint a session's listener binds to.
    enum BindHost: Equatable {
        /// Today's behaviour, and the default: loopback only, never reachable off-device.
        case loopback
        /// Reachable on the LAN. Only ever chosen for a session that has a capability.
        case allInterfaces

        var hostString: String {
            switch self {
            case .loopback: return "127.0.0.1"
            case .allInterfaces: return "0.0.0.0"
            }
        }
    }

    /// A session binds the LAN only when it is being HOSTED for another device, which is exactly when it has a
    /// well-formed capability. Tying the bind to the credential rather than to a separate flag makes "bound to
    /// 0.0.0.0 with no gate" unrepresentable rather than merely discouraged, which is risk R2 in the design.
    static func bindHost(capability: String?) -> BindHost {
        guard let capability, isWellFormedCapability(capability) else { return .loopback }
        return .allInterfaces
    }

    // MARK: - Client-side mount plan (the default-off gate)

    /// Where the client should build its remux mount.
    enum MountPlan: Equatable {
        /// Byte-identical to today: mount the remux in-process on loopback.
        case onDevice
        /// Ask the named engine host to build the remux and mount its LAN URL instead.
        case external(host: String, port: Int)
    }

    /// Default control port of a VortX engine host. Deliberately NOT 11470 (the streaming server's port), so a
    /// host can run both without collision and a user cannot paste one into the other's field by accident.
    static let defaultControlPort = 11471

    /// Canonical URL authority for every engine-host control and media request.
    ///
    /// Network.framework may report an interface-scoped address with either a raw zone delimiter (`%en0`) or
    /// the URL-encoded form (`%25en0`). Canonicalising by decoding that delimiter once and encoding it once
    /// makes this operation idempotent, so discovery, persistence and later URL construction cannot accumulate
    /// `%2525`. IPv6 literals are bracketed; hostnames, IPv4 and interface-scoped IPv4 remain unbracketed.
    static func authority(host rawHost: String, port: Int) -> String {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        host = host.replacingOccurrences(of: "%25", with: "%", options: .caseInsensitive)
        host = host.replacingOccurrences(of: "%", with: "%25")
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Build an engine-host HTTP URL through the same authority renderer used by discovery and persistence.
    /// `URLComponents.host` cannot represent a bracketed IPv6 literal, and setting a raw scoped host can
    /// double-encode its zone, so the already-canonical authority is the single source of truth.
    static func httpURL(host: String, port: Int, path: String) -> URL? {
        guard port > 0, port <= 65535, isSafeHost(host) else { return nil }
        let absolutePath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: "http://\(authority(host: host, port: port))\(absolutePath)")
    }

    /// Host text is interpolated into a URL authority only after URI delimiters and controls are excluded.
    /// In particular, `@` must never turn a user-entered host into URL userinfo and silently change the peer.
    private static func isSafeHost(_ rawHost: String) -> Bool {
        var host = rawHost
        let hasOpeningBracket = host.hasPrefix("[")
        let hasClosingBracket = host.hasSuffix("]")
        guard hasOpeningBracket == hasClosingBracket else { return false }
        if hasOpeningBracket {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty, !host.contains("["), !host.contains("]") else { return false }
        let forbidden = CharacterSet(charactersIn: "@/\\?#")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return host.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// Split a user-typed engine address into host + port. Accepts `192.168.1.33`, `192.168.1.33:11471`,
    /// `http://192.168.1.33:11471`, `mac.local`, and trailing slashes / whitespace. Returns nil for anything
    /// that is not a usable authority, which the caller treats as "not configured" (i.e. on-device).
    ///
    /// IPv6 literals are accepted in their bracketed form (`[fe80::1]:11471`) because that is the only form
    /// that is unambiguous once a port is appended.
    static func normalizeHost(_ raw: String?) -> (host: String, port: Int)? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let schemeEnd = text.range(of: "://") { text = String(text[schemeEnd.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var host = text
        var port = defaultControlPort
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let parsed = Int(rest.dropFirst()) else { return nil }
                port = parsed
            } else if !rest.isEmpty {
                return nil
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            // EXACTLY ONE colon is host:port. Two or more with no brackets is a bare IPv6 literal, which we
            // take whole and give the default port rather than mangling its last group into a port number.
            //
            // The count is the whole check and it has to be. An earlier form of this line asked
            // `!text.dropFirst().contains(":")`, which reads like "no colon after the first character" but
            // actually drops one character from the front of the WHOLE string, so the colon in `host:9000`
            // survives and the branch never ran. The visible effect was that a user typing `192.168.1.33:9000`
            // was silently sent to the default port, and every port-validation guard below was dead code.
            guard let parsed = Int(text[text.index(after: colon)...]) else { return nil }
            host = String(text[..<colon])
            port = parsed
        }
        guard !host.isEmpty, port > 0, port <= 65535, isSafeHost(host) else { return nil }
        return (host, port)
    }

    /// THE DEFAULT-OFF GATE. External mode requires all three of: the user turned it on, the fleet kill switch
    /// is still on, and a usable host is configured. Any one missing means `.onDevice`, which is the shipping
    /// lane untouched. There is deliberately no "auto-adopt a discovered host" path here: silently rerouting a
    /// user's playback to another machine is not acceptable behaviour, so adoption is always an explicit act
    /// that ends in a stored host.
    static func mountPlan(userEnabled: Bool, killSwitchOn: Bool, host: String?) -> MountPlan {
        guard userEnabled, killSwitchOn, let resolved = normalizeHost(host) else { return .onDevice }
        return .external(host: resolved.host, port: resolved.port)
    }

    // MARK: - Host lifecycle and pairing

    enum ListenerReadiness: Equatable {
        case stopped
        case starting
        case ready
    }

    enum PairingCodeDecision: Equatable {
        case issueCode
        case refuseDisabled
        case refuseListenerDown
    }

    /// A pairing code is useful only while the service that redeems it is reachable.
    static func pairingCodeDecision(
        isEnabled: Bool,
        listenerReadiness: ListenerReadiness
    ) -> PairingCodeDecision {
        guard isEnabled else { return .refuseDisabled }
        guard listenerReadiness == .ready else { return .refuseListenerDown }
        return .issueCode
    }

    /// A delayed bind result belongs to the lifecycle request that opened it only while its epoch is current.
    static func lifecycleResultIsCurrent(requestEpoch: UInt64, currentEpoch: UInt64) -> Bool {
        requestEpoch == currentEpoch
    }

    /// A hosted remux may become visible only while both its opening epoch and the control listener remain
    /// current. This is the pure guard used immediately before the producer is started and committed.
    static func hostedSessionMayCommit(
        openingEpoch: UInt64,
        currentEpoch: UInt64,
        listenerReadiness: ListenerReadiness
    ) -> Bool {
        lifecycleResultIsCurrent(requestEpoch: openingEpoch, currentEpoch: currentEpoch)
            && listenerReadiness == .ready
    }

    /// A newly-created power assertion is committed only if a session still needs it and another concurrent
    /// acquisition did not already win. Otherwise its caller must end the uncommitted assertion immediately.
    static func activityAcquisitionMayCommit(hasSessions: Bool, alreadyHasToken: Bool) -> Bool {
        hasSessions && !alreadyHasToken
    }

    // MARK: - Request routing

    enum Method: String, Equatable {
        case get = "GET"
        case head = "HEAD"
    }

    /// An unresolved `Range:` request, before it is measured against a known resource length.
    enum RangeSpec: Equatable {
        /// `bytes=start-end`, both inclusive.
        case fromTo(Int, Int)
        /// `bytes=start-`, to the end of the resource.
        case from(Int)
        /// `bytes=-n`, the final n bytes.
        case suffix(Int)
    }

    /// What the connection handler should do with one parsed request.
    enum Route: Equatable {
        /// No capability configured: this is a loopback session, so answer exactly as the server always has.
        /// Method-blind and Range-blind by construction, because that is what shipping does and the DV lane is
        /// not worth destabilising for HTTP correctness on a socket only CoreMedia can reach.
        case legacy(path: String)
        /// A hosted session's authenticated request, with the capability prefix already stripped so the
        /// existing resource switch sees the same paths it always has.
        case guarded(method: Method, path: String, range: RangeSpec?)
        /// Refuse. `status` nil means CLOSE WITHOUT WRITING A BYTE: an error body is still a reply, and a reply
        /// is still a signal to a scanner that something is here. Reserved for a failed capability check, so an
        /// unauthorised peer on the LAN learns nothing beyond "a TCP port is open", which it could see anyway.
        case reject(status: String?)
    }

    /// Longest request line we will even look at.
    static let maxRequestLineBytes = 2048

    /// Decide from the raw request header text (request line plus headers, no body).
    ///
    /// Pure: the same header and the same capability always give the same answer.
    static func route(header: String, capability: String?) -> Route {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .reject(status: "400 Bad Request") }
        guard requestLine.utf8.count <= maxRequestLineBytes else { return .reject(status: "400 Bad Request") }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return .reject(status: "400 Bad Request") }
        let target = parts[1].components(separatedBy: "?").first ?? parts[1]

        // LOOPBACK SESSION: the shipping parse, unchanged. Everything below this line is unreachable with
        // external mode off, which is what makes default-off byte-identical.
        guard let capability, isWellFormedCapability(capability) else {
            return .legacy(path: target)
        }

        // HOSTED SESSION: strict from here.
        guard let method = Method(rawValue: parts[0]) else { return .reject(status: "405 Method Not Allowed") }
        let prefix = sessionPathPrefix + capability + "/"
        guard target.hasPrefix(prefix) else { return .reject(status: nil) }
        let resource = "/" + target.dropFirst(prefix.count)
        // Defensive only: the resource switch matches exact names and parsed `seg{N}` / `audio{id}` / `subs{id}`
        // patterns, so no path here reaches a filesystem. Rejecting traversal anyway keeps that a property of
        // the router rather than a consequence of what the handlers happen to do today.
        guard !resource.contains(".."), !resource.contains("//") else { return .reject(status: nil) }
        return .guarded(method: method, path: resource, range: parseRange(header: lines))
    }

    /// Extract and parse a single `Range:` header. Multi-range requests (`bytes=0-9,20-29`) are deliberately
    /// unsupported and resolve to nil, i.e. the whole resource with a 200: a multipart/byteranges body is
    /// pointless complexity for a segment fetcher and no HLS client asks for one.
    static func parseRange(header lines: [String]) -> RangeSpec? {
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].lowercased() == "range" else { continue }
            return parseRangeValue(String(line[line.index(after: colon)...]))
        }
        return nil
    }

    static func parseRangeValue(_ raw: String) -> RangeSpec? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        let lower = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let upper = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if lower.isEmpty {
            guard let n = Int(upper), n > 0 else { return nil }
            return .suffix(n)
        }
        guard let start = Int(lower), start >= 0 else { return nil }
        if upper.isEmpty { return .from(start) }
        guard let end = Int(upper), end >= start else { return nil }
        return .fromTo(start, end)
    }

    /// Measure a range against a known resource length. Returns the inclusive byte range to serve, or nil when
    /// the request is UNSATISFIABLE, which the caller answers with 416 rather than silently serving something
    /// else. A zero-length resource is unsatisfiable for every range by definition.
    static func resolve(_ spec: RangeSpec, length: Int) -> ClosedRange<Int>? {
        guard length > 0 else { return nil }
        switch spec {
        case .fromTo(let start, let end):
            guard start < length else { return nil }
            return start...min(end, length - 1)
        case .from(let start):
            guard start < length else { return nil }
            return start...(length - 1)
        case .suffix(let count):
            let start = max(0, length - count)
            return start...(length - 1)
        }
    }

    // MARK: - Failover (the "Mac disappeared" decision)

    /// Whether a client should stay on its remote mount or rebuild it on-device.
    enum Failover: Equatable {
        case keepRemote
        /// Tear the remote mount down and re-mount the SAME source in-process at the current position, via
        /// `RemuxResumeConfiguration`. The user sees a rebuffer, never a stall.
        case failOverToDevice
    }

    /// Consecutive control-plane failures tolerated before giving up on a host. Three at the poll cadence below
    /// is a few seconds of silence, which is long enough to ride out a Wi-Fi hiccup and short enough that a
    /// closed lid does not read as a stall.
    static let controlFailureThreshold = 3

    /// How often the client asks a hosted session how it is doing.
    static let healthPollSeconds: TimeInterval = 2

    /// THE DECISION. Two distinct signals, and the difference matters:
    ///
    /// - `hostReportsHealthy == false` is the host telling us its own remux DIED. That is authoritative and
    ///   final, so one report is enough. Waiting for a threshold here would only add dead air to a failure the
    ///   host has already diagnosed.
    /// - a nil report is a request that did not complete (host asleep, Wi-Fi dropped, process gone). That is
    ///   ambiguous, so it is counted, and only a run of them fails over.
    ///
    /// - `hostReportsHealthy == true` is positive evidence that arrived over a control request that COMPLETED,
    ///   so it wins outright. In normal operation the caller has already reset its counter on that success and
    ///   this case is unreachable; making it explicit rather than falling through to the threshold means the
    ///   function is self-consistent read in isolation, instead of depending on a caller convention to avoid
    ///   contradicting its own documentation.
    static func failover(consecutiveControlFailures: Int, hostReportsHealthy: Bool?) -> Failover {
        if hostReportsHealthy == false { return .failOverToDevice }
        if hostReportsHealthy == true { return .keepRemote }
        if consecutiveControlFailures >= controlFailureThreshold { return .failOverToDevice }
        return .keepRemote
    }

    // MARK: - Remote mount readiness and ownership

    /// A stable receipt for one hosted session. Session ids are host-minted and the media URL also carries the
    /// per-session capability, so both fields must match before a delayed readiness result can attach.
    struct RemoteMountIdentity: Equatable, Sendable {
        let sessionID: String
        let playlistURL: String
    }

    enum RemoteReadinessFailure: Equatable {
        case explicitFailure
        case unhealthy
        case timeout
    }

    enum RemoteReadiness: Equatable {
        case pending
        case ready
        case failed(RemoteReadinessFailure)
    }

    /// Decide whether a newly opened hosted session is ready to attach.
    ///
    /// `healthy` is the original aggregate wire field. On older hosts it is false both while init is pending
    /// and after a pre-init failure, so false alone cannot be terminal during startup. New hosts publish the
    /// optional `initPublished` and `failed` facts. Their absence preserves old-host compatibility under the
    /// same bounded deadline.
    static func remoteReadiness(
        statusReceived: Bool,
        healthy: Bool?,
        initPublished: Bool?,
        failed: Bool?,
        signalingPublished: Bool,
        deadlineExpired: Bool
    ) -> RemoteReadiness {
        if failed == true { return .failed(.explicitFailure) }
        if statusReceived, initPublished == true, healthy == false {
            return .failed(.unhealthy)
        }
        if deadlineExpired { return .failed(.timeout) }
        let initIsReady = initPublished ?? (healthy == true)
        if statusReceived, initIsReady, signalingPublished, healthy != false {
            return .ready
        }
        return .pending
    }

    static func readinessReceiptMatches(
        expected: RemoteMountIdentity,
        received: RemoteMountIdentity
    ) -> Bool {
        expected == received
    }

    /// A load token may intentionally survive an internal replacement, so it is not enough by itself to own a
    /// delayed host callback. The opening generation, current item generation, and exact hosted session must
    /// all still belong to the mounted object.
    static func remoteCallbackIsCurrent(
        loadTokenMatches: Bool,
        expectedOpeningGeneration: UInt64?,
        emittingOpeningGeneration: UInt64,
        itemGenerationMatches: Bool,
        mountedIdentity: RemoteMountIdentity?,
        emittingIdentity: RemoteMountIdentity
    ) -> Bool {
        loadTokenMatches
            && expectedOpeningGeneration == emittingOpeningGeneration
            && itemGenerationMatches
            && mountedIdentity == emittingIdentity
    }

}
