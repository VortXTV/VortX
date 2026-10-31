import Foundation

/// State from a receiver is useful only after the receiver echoes this explicit load's opaque ID.
/// URL equality cannot establish ownership across account/source/episode changes or resumed sessions.
struct GoogleCastPlaybackPolicy {
    private(set) var owner: UUID?
    private(set) var confirmedPosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var pendingSeek: Double?
    private(set) var pendingPaused: Bool?
    private(set) var pauseGeneration: UInt64 = 0
    private var acknowledgedPauseGeneration: UInt64?
    private(set) var suspended = false
    private(set) var reconnectDeadline: TimeInterval?
    private var resumedSession: AnyObject?
    private var resumedClient: AnyObject?

    var resumePosition: Double { pendingSeek ?? confirmedPosition }

    /// A previously owned status does not authorize a later command. The SDK adapter supplies
    /// the current session/client identities and the receiver's current opaque load receipt.
    func permitsReceiverCommand(echoedOwner: String?, onCurrentSession: Bool, onBoundClient: Bool) -> Bool {
        guard let owner else { return false }
        return !suspended && onCurrentSession && onBoundClient && echoedOwner == owner.uuidString
    }

    mutating func begin(owner: UUID, position: Double, duration: Double) {
        self.owner = owner
        confirmedPosition = position.isFinite ? min(604800, max(0, position)) : 0
        self.duration = duration.isFinite ? min(604800, max(0, duration)) : 0
        pendingSeek = nil
        pendingPaused = nil
        pauseGeneration = 0
        acknowledgedPauseGeneration = nil
        resume()
    }
    @discardableResult mutating func requestPaused(_ paused: Bool) -> UInt64 {
        pauseGeneration &+= 1
        if owner != nil { pendingPaused = paused; acknowledgedPauseGeneration = nil }
        return pauseGeneration
    }
    mutating func acknowledgePause(generation: UInt64) -> Bool {
        guard owner != nil, pauseGeneration == generation else { return false }
        acknowledgedPauseGeneration = generation
        return true
    }
    mutating func observePaused(_ paused: Bool, freshAfterAcknowledgement: Bool = false) {
        guard freshAfterAcknowledgement, acknowledgedPauseGeneration == pauseGeneration else { return }
        if pendingPaused == paused { pendingPaused = nil }
    }
    mutating func seek(_ target: Double) -> Bool {
        guard owner != nil, target.isFinite, target >= 0, target <= 604800 else { return false }
        pendingSeek = duration > 0 ? min(target, duration) : target
        return true
    }
    mutating func sample(owner: UUID?, position: Double, duration: Double) -> Bool {
        guard let owner, self.owner == owner, !suspended,
              position.isFinite, position >= 0, position <= 604800, duration.isFinite, duration >= 0, duration <= 604800 else { return false }
        if let target = pendingSeek {
            guard abs(position - target) <= 2 else { return false }
            pendingSeek = nil
        }
        confirmedPosition = position
        if duration > 0 { self.duration = duration }
        return true
    }
    /// Suspension and repeated resume callbacks share the first attempt's monotonic bound.
    mutating func suspend(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard owner != nil else { return }
        armReconnect(at: uptime)
        resumedSession = nil; resumedClient = nil
    }
    /// Only an actual SDK didResume callback may make this exact session/client pair ready.
    mutating func didResume(session: AnyObject, client: AnyObject?, at uptime: TimeInterval) {
        guard owner != nil else { return }
        armReconnect(at: uptime)
        resumedSession = nil; resumedClient = nil
        guard !reconnectExpired(at: uptime), let client else { return }
        resumedSession = session; resumedClient = client
    }
    private mutating func armReconnect(at uptime: TimeInterval) {
        suspended = true
        if reconnectDeadline == nil { reconnectDeadline = uptime + 15 }
    }
    func reconnectExpired(at uptime: TimeInterval) -> Bool {
        reconnectDeadline.map { uptime >= $0 } == true
    }
    func permitsReconnect(session: AnyObject, client: AnyObject, echoedOwner: String?,
                          onCurrentSession: Bool, onCurrentClient: Bool, at uptime: TimeInterval) -> Bool {
        guard let owner, suspended, reconnectDeadline != nil, !reconnectExpired(at: uptime) else { return false }
        return resumedSession === session && resumedClient === client &&
            onCurrentSession && onCurrentClient && echoedOwner == owner.uuidString
    }
    mutating func resume() {
        suspended = false; reconnectDeadline = nil
        resumedSession = nil; resumedClient = nil
    }
    mutating func retire() {
        owner = nil; pendingSeek = nil; pendingPaused = nil; acknowledgedPauseGeneration = nil
        resume()
    }
}

enum GoogleCastFormatPolicy {
    static func contentType(responseType: String?, url: URL) -> String? {
        let type = responseType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let type, ["video/mp4", "video/webm", "application/x-mpegurl", "application/vnd.apple.mpegurl", "application/dash+xml"].contains(type) { return type }
        // An explicit unsupported response wins over a suggestive filename.
        if let type, type != "application/octet-stream" { return nil }
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "m3u8": return "application/x-mpegurl"
        case "mpd": return "application/dash+xml"
        default: return nil
        }
    }

    static func unsupportedReason(dynamicRange: PlaybackMetadataFacts.DynamicRange, audioCodec: String) -> String? {
        if [.dolbyVision, .pq, .hlg].contains(dynamicRange) {
            return "This HDR source needs receiver-specific format support. Choose an SDR MP4 or HLS source for Google Cast."
        }
        if ["truehd", "audio/true-hd", "dts", "dts-hd", "dca", "audio/vnd.dts", "audio/vnd.dts.hd"].contains(audioCodec.lowercased()) {
            return "This source uses audio that the standard Cast receiver cannot play. Choose an AAC or compatible Dolby source."
        }
        return nil
    }
}

enum CastTorrentRelayPolicy {
    static func sourceIsPinned(_ url: URL, nativeBase: URL) -> Bool {
        guard url.scheme == "http", nativeBase.scheme == "http",
              ReceiverURLPolicy.normalizedHost(url.host ?? "") == "127.0.0.1",
              ReceiverURLPolicy.sameOrigin(url, nativeBase), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        return url.path.range(of: "^/[a-fA-F0-9]{40}/[0-9]+$", options: .regularExpression) != nil
    }

    struct Request: Equatable {
        let method: String
        let range: String?
    }
    static func request(_ header: String, token: String) -> Request? {
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              header.utf8.count <= 8192, header.hasSuffix("\r\n\r\n") else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              String(first[1]) == "/cast/\(token)/media.mp4", first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { return nil }
        var range: String?
        var hostCount = 0
        for line in lines.dropFirst() where !line.isEmpty {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "host" { hostCount += 1 }
            if name == "transfer-encoding" || name == "expect" || name == "content-length" { return nil }
            if name == "range" {
                guard range == nil,
                      value.range(of: "^bytes=([0-9]+-[0-9]*|-[1-9][0-9]*)$", options: .regularExpression) != nil else { return nil }
                range = value
            }
        }
        guard hostCount == 1 else { return nil }
        return Request(method: String(first[0]), range: range)
    }
}
