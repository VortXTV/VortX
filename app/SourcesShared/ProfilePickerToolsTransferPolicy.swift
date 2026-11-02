import Foundation

/// RECOVERY PROPOSAL. Four routes only; no listener/account/native/file access.
/// Session methods run synchronously on MainActor. The adapter MUST supply the original
/// live route/operation grant on every call, including each buffered tail and send chunk.
/// A valid QR capability alone is never that grant. Transport drain is external evidence.
enum ProfilePickerToolsTransferPolicy {
    static let maxRequestLineBytes = 2 * 1024
    static let maxHeaderBytes = 16 * 1024
    static let maxHeaderFields = 32
    static let maxFileBytes = 10 * 1024 * 1024
    static let chunkBytes = 64 * 1024
    static let headerSeconds: Double = 15
    static let bodyIdleSeconds: Double = 15
    static let bodyTotalSeconds: Double = 60
    static let sessionSeconds: Double = 300

    enum Refusal: Error, Equatable {
        case malformed, headersTooLarge, lineTooLarge, tooManyFields, framing
        case route, host, origin, authority, length, encoding, extraBytes, earlyEOF
        case expired, clock, denied, busy, stale, draining, consumed, chunkTooLarge
        case notReady, retryRequired, snapshotAlreadySet, invalidCapability
    }
    enum Mode: String, Sendable { case download, repair, restore }
    enum Route: Equatable, Sendable { case bootstrap, state, input, file }
    enum Stage: String, Sendable {
        case waitingForFile = "waiting-for-file", preparing, reviewOnTV = "review-on-tv"
        case available, localSendComplete = "local-send-complete", closed
    }
    enum Filename: String, Sendable {
        case backup = "vortx-account-backup.json"
        case repaired = "vortx-account-repaired.json"
    }
    /// Opaque fences, not account identifiers. Adapter retains the canonical account capture.
    struct Owner: Equatable, Sendable {
        let sessionID: UUID
        let routeID: UUID
        let operationID: UUID
        let credentialGeneration: UUID
    }
    struct Claim: Equatable, Sendable {
        let owner: Owner
        fileprivate let sequence: UInt64
    }
    struct Endpoint: Equatable, Sendable {
        let authority: String
        var origin: String { "http://" + authority }
        /// The initial adapter advertises canonical numeric IPv4 only, matching its LAN helper.
        init(ipv4: String, port: UInt16) throws {
            let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
            guard port != 0, parts.count == 4,
                  parts.allSatisfy({ part in
                      let b = Array(part.utf8)
                      return !b.isEmpty && b.count <= 3 && b.allSatisfy({ $0 >= 48 && $0 <= 57 })
                          && (b.count == 1 || b[0] != 48) && (UInt16(part) ?? 256) <= 255
                  }) else { throw Refusal.host }
            authority = ipv4 + ":" + String(port)
        }
    }
    /// Canonical lowercase hex, 16...64 CSPRNG bytes supplied by the adapter.
    /// Syntax does not prove entropy: the production generator remains a separate review gate.
    struct Capability: Sendable {
        private let hex: [UInt8]
        init(hex: String) throws {
            let b = Array(hex.utf8)
            guard (32...128).contains(b.count), b.count.isMultiple(of: 2),
                  b.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw Refusal.invalidCapability }
            self.hex = b
        }
        /// Fixed upper bound; no string prefix acceptance or early mismatch exit.
        func matches(_ other: Capability) -> Bool {
            guard hex.count == other.hex.count else { return false }
            var difference: UInt8 = 0
            for index in hex.indices { difference |= hex[index] ^ other.hex[index] }
            return difference == 0
        }
        /// Only QR composition may use this value. Never log/persist it.
        var qrFragment: String { String(decoding: hex, as: UTF8.self) }
    }
    struct RequestHead: Sendable {
        let route: Route
        let contentLength: Int
        fileprivate let capability: Capability?
    }
    struct HeaderFeed: Sendable {
        /// Prefix consumed from this call, NOT total bytes across calls.
        let consumed: Int
        let head: RequestHead?
    }

    /// Incremental CRLF framing; retains headers only. Never appends/allocates a body.
    /// The caller retains the bounded receive buffer and submits its unconsumed tail
    /// to Session.appendInput only AFTER reserveInput returned a claim.
    struct HeaderParser {
        private let endpoint: Endpoint
        private let startedAt: Double
        private var lastTime: Double
        private var bytes: [UInt8] = []
        private var lineBytes = 0
        private var firstLine = true
        private var complete = false
        private var failed = false

        init(endpoint: Endpoint, now: Double) throws {
            guard now.isFinite, now >= 0 else { throw Refusal.clock }
            self.endpoint = endpoint; startedAt = now; lastTime = now
        }
        mutating func consume(_ incoming: Data, now: Double) throws -> HeaderFeed {
            guard !complete, !failed else { throw Refusal.stale }
            do {
                try checkTime(now)
                var consumed = 0
                for byte in incoming {
                    guard bytes.count < maxHeaderBytes else { throw Refusal.headersTooLarge }
                    // Only CRLF is a line delimiter; bare CR/LF and controls fail closed.
                    if bytes.last == 13, byte != 10 { throw Refusal.framing }
                    if byte == 10, bytes.last != 13 { throw Refusal.framing }
                    if byte != 13 && byte != 10 && !(32...126).contains(byte) { throw Refusal.malformed }
                    bytes.append(byte); consumed += 1; lineBytes += 1
                    if firstLine && lineBytes > maxRequestLineBytes + 2 { throw Refusal.lineTooLarge }
                    if byte == 10 { firstLine = false; lineBytes = 0 }
                    if bytes.count >= 4 && bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                        let head = try parseHead()
                        let tail = incoming.count - consumed
                        if head.route == .input {
                            guard tail <= head.contentLength else { throw Refusal.extraBytes }
                        } else if tail != 0 { throw Refusal.extraBytes }
                        complete = true
                        return HeaderFeed(consumed: consumed, head: head)
                    }
                }
                return HeaderFeed(consumed: consumed, head: nil)
            } catch { failed = true; throw error }
        }
        mutating func eof(now: Double) throws {
            do { try checkTime(now); guard complete else { throw Refusal.earlyEOF } }
            catch { failed = true; throw error }
        }
        private mutating func checkTime(_ now: Double) throws {
            guard now.isFinite, now >= lastTime else { throw Refusal.clock }
            lastTime = now
            guard now - startedAt < headerSeconds else { throw Refusal.expired }
        }
        private func parseHead() throws -> RequestHead {
            let text = String(decoding: bytes, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            guard lines.count >= 3, lines.suffix(2).allSatisfy(\.isEmpty) else { throw Refusal.framing }
            let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { throw Refusal.malformed }
            let route: Route
            switch (request[0], request[1]) {
            case ("GET", "/"): route = .bootstrap
            case ("GET", "/state"): route = .state
            case ("POST", "/input"): route = .input
            case ("GET", "/file"): route = .file
            default: throw Refusal.route
            }
            let fields = lines.dropFirst().dropLast(2)
            guard fields.count <= maxHeaderFields else { throw Refusal.tooManyFields }
            var headers: [String: String] = [:]
            for field in fields {
                guard !field.isEmpty, field.first != " ", let colon = field.firstIndex(of: ":") else { throw Refusal.malformed }
                let name = field[..<colon]
                let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
                guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }) else { throw Refusal.malformed }
                let key = name.lowercased()
                // Refuse all duplicate fields, including the security-sensitive ones.
                guard headers[key] == nil else { throw Refusal.malformed }
                headers[key] = field[field.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            }
            guard headers["host"] == endpoint.authority else { throw Refusal.host }
            if let origin = headers["origin"], origin != endpoint.origin { throw Refusal.origin }
            if route == .input, headers["origin"] != endpoint.origin { throw Refusal.origin }
            if let site = headers["sec-fetch-site"], !["same-origin", "none"].contains(site) { throw Refusal.origin }
            for name in ["transfer-encoding", "content-encoding", "expect", "range", "if-range", "te", "trailer", "upgrade"] {
                if headers[name] != nil { throw Refusal.encoding }
            }
            if let connection = headers["connection"], !["close", "keep-alive"].contains(connection.lowercased()) { throw Refusal.encoding }
            let capability: Capability?
            if route == .bootstrap {
                guard headers["authorization"] == nil else { throw Refusal.authority }
                capability = nil
            } else {
                guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer ") else { throw Refusal.authority }
                do { capability = try Capability(hex: String(authorization.dropFirst(7))) }
                catch { throw Refusal.authority }
            }
            let length: Int
            if route == .input {
                guard headers["content-type"] == "application/octet-stream", let raw = headers["content-length"] else { throw Refusal.length }
                let digits = Array(raw.utf8)
                guard !digits.isEmpty, digits.count <= 8, digits[0] != 48,
                      digits.allSatisfy({ (48...57).contains($0) }),
                      let value = Int(raw), (1...maxFileBytes).contains(value) else { throw Refusal.length }
                length = value
            } else {
                guard headers["content-length"] == nil || headers["content-length"] == "0",
                      headers["content-type"] == nil else { throw Refusal.length }
                length = 0
            }
            return RequestHead(route: route, contentLength: length, capability: capability)
        }
    }

    struct ImmutableInput: Sendable {
        let owner: Owner
        let attempt: Claim
        let bytes: Data
    }
    struct OutputInfo: Equatable, Sendable {
        let owner: Owner
        let snapshotID: UUID
        let byteCount: Int
        let filename: Filename
    }
    struct OutputChunk: Sendable {
        let claim: Claim
        let range: Range<Int>
        let bytes: Data
    }
    enum LocalSendOutcome: Equatable, Sendable {
        /// Only local contentProcessed success; no phone receipt, disk-save or account result.
        case tvFinishedSendingCheckPhone
        case failedCheckPhone
    }

    @MainActor final class Session {
        let owner: Owner
        let mode: Mode
        let deadline: Double
        private(set) var stage: Stage
        private(set) var retired = false
        private(set) var inputConsumed = false
        private(set) var acceptedInput: ImmutableInput?
        private(set) var localSendOutcome: LocalSendOutcome?
        private var capability: Capability
        private var lastTime: Double
        private var sequence: UInt64 = 0
        private var inputRetryRequired = false
        private var outputRetryRequired = false
        private final class InputAttempt {
            let claim: Claim
            let expected: Int
            let started: Double
            var lastAppend: Double
            var bytes = Data()
            var draining = false
            init(claim: Claim, expected: Int, started: Double, lastAppend: Double) {
                self.claim = claim; self.expected = expected; self.started = started; self.lastAppend = lastAppend
            }
        }
        private struct OutputAttempt {
            let claim: Claim
            let started: Double
            var lastProgress: Double
            var offset = 0
            var pending: Range<Int>?
            var draining = false
        }
        private struct Snapshot { let info: OutputInfo; let bytes: Data }
        private var input: InputAttempt?
        private var output: OutputAttempt?
        private var snapshot: Snapshot?

        init(owner: Owner, mode: Mode, capability: Capability, now: Double) throws {
            guard now.isFinite, now >= 0, (now + sessionSeconds).isFinite else { throw Refusal.clock }
            self.owner = owner; self.mode = mode; self.capability = capability
            lastTime = now; deadline = now + sessionSeconds
            stage = mode == .download ? .preparing : .waitingForFile
        }
        var hasUndrainedAttempts: Bool { input != nil || output != nil }
        var partialInputByteCount: Int { input?.bytes.count ?? 0 }
        var outputInfo: OutputInfo? { snapshot?.info }

        /// Call before EVERY protected response, even /state. Public bootstrap has no capability.
        func authorize(_ head: RequestHead, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            if head.route != .bootstrap {
                guard let supplied = head.capability, capability.matches(supplied) else { throw Refusal.authority }
            }
            if head.route == .input && mode == .download { throw Refusal.route }
            if head.route == .file && mode == .restore { throw Refusal.route }
        }
        /// This is the SINGLE pre-allocation reservation, before any coalesced body tail.
        func reserveInput(_ head: RequestHead, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> Claim {
            try authorize(head, now: now, liveGrant: liveGrant)
            guard head.route == .input else { throw Refusal.route }
            guard !inputConsumed else { throw Refusal.consumed }
            guard input == nil else { throw Refusal.busy }
            guard !inputRetryRequired else { throw Refusal.retryRequired }
            let claim = try nextClaim()
            input = InputAttempt(claim: claim, expected: head.contentLength, started: now, lastAppend: now)
            return claim
        }
        /// No append bypass: not in parser, header authorization, or any eager body initializer.
        /// Caller splits EVERY receive into <=64KiB chunks. Overflow marks this exact attempt draining.
        func appendInput(_ bytes: Data, claim: Claim, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            guard let current = input, current.claim == claim else { throw Refusal.stale }
            guard !current.draining else { throw Refusal.draining }
            do {
                guard now - current.started < bodyTotalSeconds, now - current.lastAppend < bodyIdleSeconds else { throw Refusal.expired }
                guard !bytes.isEmpty, bytes.count <= chunkBytes else { throw Refusal.chunkTooLarge }
                guard bytes.count <= current.expected - current.bytes.count else { throw Refusal.extraBytes }
                current.bytes.append(bytes); current.lastAppend = now; input = current
            } catch {
                current.draining = true; input = current; inputRetryRequired = true; stage = .closed
                throw error
            }
        }
        /// Adapter has checked that this bounded receive had NO extra tail. This consumes input
        /// permanently, before async inspection. Invalid backup content cannot reopen upload.
        func commitInput(claim: Claim, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> ImmutableInput {
            try requireLive(now, liveGrant)
            guard let current = input, current.claim == claim else { throw Refusal.stale }
            guard !current.draining else { throw Refusal.draining }
            guard now - current.started < bodyTotalSeconds, now - current.lastAppend < bodyIdleSeconds else {
                current.draining = true; input = current; inputRetryRequired = true; stage = .closed
                throw Refusal.expired
            }
            guard current.bytes.count == current.expected else {
                beginInputDrain(claim: claim); throw Refusal.earlyEOF
            }
            let accepted = ImmutableInput(owner: owner, attempt: claim, bytes: current.bytes)
            acceptedInput = accepted; inputConsumed = true; stage = .preparing
            current.bytes = Data(); current.draining = true; input = current
            return accepted
        }
        func inputEOF(claim: Claim, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            guard let current = input, current.claim == claim else { throw Refusal.stale }
            if current.draining || current.bytes.count == current.expected { return }
            beginInputDrain(claim: claim)
            throw Refusal.earlyEOF
        }
        /// Synchronous cancellation fence, before asking Network/workers to cancel.
        func beginInputDrain(claim: Claim) {
            guard let current = input, current.claim == claim else { return }
            current.draining = true; input = current
            if !inputConsumed { inputRetryRequired = true; stage = .closed }
        }
        /// ONLY after actual callbacks/workers drained; stale completion cannot free a successor.
        @discardableResult func inputDrained(claim: Claim) -> Bool {
            guard let current = input, current.claim == claim, current.draining else { return false }
            input = nil; return true
        }
        func retryInput(with newCapability: Capability, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            guard mode != .download, !inputConsumed else { throw Refusal.consumed }
            guard input == nil, output == nil else { throw Refusal.busy }
            guard inputRetryRequired, !capability.matches(newCapability) else { throw Refusal.retryRequired }
            capability = newCapability; inputRetryRequired = false; stage = .waitingForFile
        }
        /// Invoke from bounded adapter timers even when a peer stops sending bytes.
        func enforceDeadlines(now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            if let current = input, !current.draining,
               now - current.started >= bodyTotalSeconds || now - current.lastAppend >= bodyIdleSeconds {
                beginInputDrain(claim: current.claim); throw Refusal.expired
            }
            if let current = output, !current.draining { try requireOutputTime(current, now: now) }
        }
        func showReview(now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            guard inputConsumed, mode != .download, stage == .preparing else { throw Refusal.notReady }
            stage = .reviewOnTV
        }
        /// Adapter obtains validated encrypted bytes ONCE from the original manager operation.
        /// In Repair this call follows TV approval/take, never GET /file. No provider filename.
        func installOutput(_ bytes: Data, snapshotID: UUID, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> OutputInfo {
            try requireLive(now, liveGrant)
            guard mode != .restore, mode == .download || inputConsumed else { throw Refusal.route }
            guard snapshot == nil else { throw Refusal.snapshotAlreadySet }
            if mode == .repair, stage != .reviewOnTV { throw Refusal.notReady }
            guard (1...maxFileBytes).contains(bytes.count) else { throw Refusal.length }
            let info = OutputInfo(owner: owner, snapshotID: snapshotID, byteCount: bytes.count,
                                  filename: mode == .repair ? .repaired : .backup)
            snapshot = Snapshot(info: info, bytes: bytes); stage = .available
            return info
        }
        func reserveOutput(_ head: RequestHead, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> Claim {
            try authorize(head, now: now, liveGrant: liveGrant)
            guard head.route == .file, snapshot != nil else { throw Refusal.notReady }
            guard output == nil else { throw Refusal.busy }
            guard !outputRetryRequired else { throw Refusal.retryRequired }
            let claim = try nextClaim(); output = OutputAttempt(claim: claim, started: now, lastProgress: now)
            return claim
        }
        /// At most one chunk handed to Network. Must process its exact callback before next call.
        func releaseOutputChunk(claim: Claim, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> OutputChunk? {
            try requireLive(now, liveGrant)
            guard var current = output, current.claim == claim else { throw Refusal.stale }
            guard !current.draining else { throw Refusal.draining }
            try requireOutputTime(current, now: now)
            guard current.pending == nil, let snapshot else { throw Refusal.busy }
            if current.offset == snapshot.bytes.count { return nil }
            let range = current.offset..<min(current.offset + chunkBytes, snapshot.bytes.count)
            current.pending = range; output = current
            return OutputChunk(claim: claim, range: range, bytes: snapshot.bytes.subdata(in: range))
        }
        /// This says only that Network processed this local chunk; no browser ACK exists.
        func localChunkProcessed(claim: Claim, range: Range<Int>, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            guard var current = output, current.claim == claim else { throw Refusal.stale }
            guard !current.draining, current.pending == range else { throw Refusal.stale }
            try requireOutputTime(current, now: now)
            current.offset = range.upperBound; current.pending = nil; current.lastProgress = now; output = current
        }
        func finishOutput(claim: Claim, success: Bool, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws {
            try requireLive(now, liveGrant)
            guard var current = output, current.claim == claim, !current.draining else { throw Refusal.stale }
            try requireOutputTime(current, now: now)
            if success {
                guard current.pending == nil, current.offset == snapshot?.bytes.count else { throw Refusal.notReady }
            }
            current.draining = true; output = current; outputRetryRequired = true
            localSendOutcome = success ? .tvFinishedSendingCheckPhone : .failedCheckPhone
            stage = success ? .localSendComplete : .closed
        }
        func beginOutputDrain(claim: Claim) {
            guard var current = output, current.claim == claim else { return }
            current.draining = true; output = current; outputRetryRequired = true
        }
        @discardableResult func outputDrained(claim: Claim) -> Bool {
            guard let current = output, current.claim == claim, current.draining else { return false }
            output = nil; return true
        }
        /// Visible TV action only. Same immutable snapshot/owner/deadline; old token retired.
        /// Caller must establish transport AND account-worker drain before calling.
        func retryOutput(with newCapability: Capability, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> OutputInfo {
            try requireLive(now, liveGrant)
            guard output == nil, input == nil else { throw Refusal.busy }
            guard let snapshot, outputRetryRequired, !capability.matches(newCapability) else { throw Refusal.retryRequired }
            capability = newCapability; outputRetryRequired = false; localSendOutcome = nil; stage = .available
            return snapshot.info
        }
        func stateBody(for head: RequestHead, now: Double, liveGrant: @MainActor (Owner) -> Bool) throws -> Data {
            try authorize(head, now: now, liveGrant: liveGrant)
            guard head.route == .state else { throw Refusal.route }
            return Data(("{\"mode\":\"" + mode.rawValue + "\",\"stage\":\"" + stage.rawValue + "\"}").utf8)
        }
        func retire() {
            retired = true; stage = .closed
            if let input { beginInputDrain(claim: input.claim) }
            if let output { beginOutputDrain(claim: output.claim) }
        }
        /// Never deletes account restore journals. Clears only these transport-owned references.
        func releaseRetiredPayloadsAfterDrain() throws {
            guard retired, !hasUndrainedAttempts else { throw Refusal.draining }
            acceptedInput = nil; snapshot = nil
        }
        private func requireLive(_ now: Double, _ grant: @MainActor (Owner) -> Bool) throws {
            guard now.isFinite, now >= lastTime else { retire(); throw Refusal.clock }
            lastTime = now
            guard now < deadline else { retire(); throw Refusal.expired }
            guard !retired, grant(owner) else { retire(); throw Refusal.denied }
        }
        private func requireOutputTime(_ current: OutputAttempt, now: Double) throws {
            guard now - current.started < bodyTotalSeconds, now - current.lastProgress < bodyIdleSeconds else {
                beginOutputDrain(claim: current.claim); stage = .closed
                localSendOutcome = .failedCheckPhone; throw Refusal.expired
            }
        }
        private func nextClaim() throws -> Claim {
            guard sequence < UInt64.max else { retire(); throw Refusal.stale }
            sequence += 1; return Claim(owner: owner, sequence: sequence)
        }
    }
}
