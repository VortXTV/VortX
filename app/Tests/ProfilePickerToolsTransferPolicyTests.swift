import Foundation

/// Actual maintained policy, not a copied parser/model. Authored; no execution receipt yet.
@main @MainActor enum ProfilePickerToolsTransferPolicyTests {
    typealias P = ProfilePickerToolsTransferPolicy
    typealias Page = ProfilePickerToolsTransferPhonePage
    static let endpoint = try! P.Endpoint(ipv4: "192.168.1.20", port: 49152)
    static let first = try! P.Capability(hex: String(repeating: "a1", count: 16))
    static let second = try! P.Capability(hex: String(repeating: "b2", count: 16))
    static let third = try! P.Capability(hex: String(repeating: "c3", count: 16))
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); checks += 1
    }
    static func refuses(_ expected: P.Refusal? = nil, _ label: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure("Accepted: " + label) }
        catch let failure as P.Refusal {
            if let expected { check(failure == expected, label + " expected refusal") }
            else { checks += 1 }
        } catch { preconditionFailure("Unexpected error: " + label) }
    }
    static func owner() -> P.Owner {
        .init(sessionID: UUID(), routeID: UUID(), operationID: UUID(), credentialGeneration: UUID())
    }
    static func session(_ mode: P.Mode = .repair) throws -> P.Session {
        try .init(owner: owner(), mode: mode, capability: first, now: 0)
    }
    static func wire(_ route: String = "POST /input", length: String = "5", token: P.Capability? = first,
                     extra: [String] = [], body: Data = Data()) -> Data {
        var fields = [route + " HTTP/1.1", "Host: " + endpoint.authority]
        if let token { fields.append("Authorization: Bearer " + token.qrFragment) }
        if route == "POST /input" {
            fields += ["Origin: " + endpoint.origin, "Content-Type: application/octet-stream", "Content-Length: " + length]
        }
        return Data((fields.joined(separator: "\r\n") + "\r\n" + extra.joined(separator: "\r\n")
            + (extra.isEmpty ? "" : "\r\n") + "\r\n").utf8) + body
    }
    static func head(_ wire: Data) throws -> P.RequestHead {
        var parser = try P.HeaderParser(endpoint: endpoint, now: 0)
        return try parser.consume(wire, now: 0).head!
    }
    static func permit(_ value: P.Owner) -> Bool { true }

    /// All one-split positions, including between CR and LF, CRLFCRLF and body bytes.
    /// Every byte is either header-consumed or enters the explicitly reserved append path.
    static func allFragmentationSplits() throws {
        let body = Data([0, 13, 10, 255, 128])
        let bytes = wire(body: body)
        for split in 0...bytes.count {
            let model = try session()
            var parser = try P.HeaderParser(endpoint: endpoint, now: 0)
            var claim: P.Claim?
            for part in [Data(bytes.prefix(split)), Data(bytes.dropFirst(split))] {
                if part.isEmpty { continue }
                let tail: Data
                if claim == nil {
                    let feed = try parser.consume(part, now: 1)
                    if let parsed = feed.head {
                        check(model.partialInputByteCount == 0, "parser has no eager body")
                        claim = try model.reserveInput(parsed, now: 1, liveGrant: permit)
                        tail = Data(part.dropFirst(feed.consumed))
                    } else { continue }
                } else { tail = part }
                if !tail.isEmpty { try model.appendInput(tail, claim: claim!, now: 1, liveGrant: permit) }
            }
            let accepted = try model.commitInput(claim: claim!, now: 1, liveGrant: permit)
            check(accepted.bytes == body, "all split points preserve exact non-JSON bytes")
            check(model.inputConsumed, "complete input consumed permanently")
            check(model.inputDrained(claim: claim!), "accepted attempt still requires drain")
        }
        // One-byte TCP fragments, not just two coalesced receive callbacks.
        let model = try session()
        var parser = try P.HeaderParser(endpoint: endpoint, now: 0)
        var claim: P.Claim?
        for byte in bytes {
            if let current = claim { try model.appendInput(Data([byte]), claim: current, now: 1, liveGrant: permit) }
            else if let parsed = try parser.consume(Data([byte]), now: 1).head {
                claim = try model.reserveInput(parsed, now: 1, liveGrant: permit)
            }
        }
        let oneByteAccepted = try model.commitInput(claim: claim!, now: 1, liveGrant: permit)
        check(oneByteAccepted.bytes == body, "one-byte framing")
        for request in [wire("GET /", token: nil), wire("GET /state"), wire("GET /file")] {
            for split in 0...request.count {
                var p = try P.HeaderParser(endpoint: endpoint, now: 0)
                var result: P.RequestHead?
                for part in [Data(request.prefix(split)), Data(request.dropFirst(split))] where !part.isEmpty {
                    result = try p.consume(part, now: 0).head ?? result
                }
                check(result != nil, "GET split boundary")
            }
        }
    }
    static func malformedHeaders() throws {
        let good = wire()
        let text = String(decoding: good, as: UTF8.self)
        let mutations: [String] = [
            text.replacingOccurrences(of: "\r\n", with: "\n"),
            text.replacingOccurrences(of: "Host:", with: " Host:"),
            text.replacingOccurrences(of: "Host:", with: "Host :"),
            text.replacingOccurrences(of: "Host:", with: "Ho\tst:"),
            text.replacingOccurrences(of: "Host:", with: "Host:\u{0}"),
            text.replacingOccurrences(of: "Host:", with: "Host:é"),
            text.replacingOccurrences(of: endpoint.authority, with: "192.168.1.21:49152"),
            text.replacingOccurrences(of: endpoint.authority, with: "192.168.001.20:49152"),
            text.replacingOccurrences(of: endpoint.origin, with: "http://evil.invalid"),
            text.replacingOccurrences(of: "Origin: " + endpoint.origin + "\r\n", with: ""),
            text.replacingOccurrences(of: "Authorization: Bearer ", with: "Authorization: Basic "),
            text.replacingOccurrences(of: "Authorization: Bearer " + first.qrFragment + "\r\n", with: ""),
            text.replacingOccurrences(of: "application/octet-stream", with: "application/json"),
            text.replacingOccurrences(of: "HTTP/1.1", with: "HTTP/2.0"),
            text.replacingOccurrences(of: "POST /input", with: "POST  /input"),
            text.replacingOccurrences(of: "POST /input", with: "POST http://192.168.1.20:49152/input")
        ]
        for mutation in mutations { refuses(nil, "malformed header") { _ = try head(Data(mutation.utf8)) } }
        for extra in ["Host: " + endpoint.authority, "hOsT: " + endpoint.authority,
                      "Authorization: Bearer " + first.qrFragment, "aUtHoRiZaTiOn: Bearer " + second.qrFragment,
                      "Content-Length: 5", "Content-Length: 6", "Origin: " + endpoint.origin,
                      "Transfer-Encoding: chunked", "Content-Encoding: gzip", "Expect: 100-continue",
                      "Range: bytes=0-1", "If-Range: anything", "TE: trailers", "Trailer: Content-Length",
                      "Upgrade: websocket", "Connection: upgrade", "Sec-Fetch-Site: cross-site"] {
            refuses(nil, "duplicate/smuggling header") { _ = try head(wire(extra: [extra])) }
        }
        for value in ["0", "00", "01", "+1", "-1", "1.0", "1e1", "5,5", "5 5", "10485761", "9999999999999999999999999", ""] {
            refuses(.length, "noncanonical/invalid length") { _ = try head(wire(length: value)) }
        }
        for path in ["POST /", "POST /state", "GET /input", "POST /file", "OPTIONS /input", "HEAD /file", "GET /state?x=1", "GET //state", "GET /%73tate", "GET /file#token", "GET /confirm", "GET /account", "GET /redirect"] {
            refuses(.route, "wrong exact route/method") { _ = try head(wire(path)) }
        }
        refuses(.extraBytes, "coalesced pipeline") { _ = try head(wire("GET /state") + wire("GET /state")) }
        refuses(.extraBytes, "coalesced body overflow") { _ = try head(wire(length: "1", body: Data([1, 2]))) }
        refuses(.length, "GET body length") { _ = try head(wire("GET /state", extra: ["Content-Length: 1"])) }
        refuses(.extraBytes, "GET raw body") { _ = try head(wire("GET /state", body: Data([1]))) }
        refuses(.tooManyFields, "32 fields cap") { _ = try head(wire(extra: (0..<32).map { "X-Field-\($0): x" })) }
        _ = try head(wire(extra: (0..<27).map { "X-Field-\($0): x" }))
        checks += 1 // The upload's five required fields + 27 = exactly 32.
        refuses(.headersTooLarge, "16KiB cap") { _ = try head(wire(extra: ["X-Pad: " + String(repeating: "x", count: P.maxHeaderBytes)])) }
        refuses(.lineTooLarge, "2KiB line cap") { _ = try head(Data(("GET /" + String(repeating: "x", count: P.maxRequestLineBytes) + " HTTP/1.1\r\n\r\n").utf8)) }
        let linePrefix = "GET /", lineSuffix = " HTTP/1.1"
        let exactLine = linePrefix + String(repeating: "x", count: P.maxRequestLineBytes - linePrefix.utf8.count - lineSuffix.utf8.count) + lineSuffix
        refuses(.route, "exact 2KiB request line passes framing then wrong route") { _ = try head(Data((exactLine + "\r\nHost: " + endpoint.authority + "\r\n\r\n").utf8)) }
        refuses(.lineTooLarge, "one byte over request line") { _ = try head(Data((exactLine + "x\r\n\r\n").utf8)) }
        // Exact header ceiling accepted, one byte over rejected (not merely a large failure).
        let prefix = wire("GET /", token: nil, extra: ["X-Pad: "])
        let pad = P.maxHeaderBytes - prefix.count
        let limit = wire("GET /", token: nil, extra: ["X-Pad: " + String(repeating: "x", count: pad)])
        check(limit.count == P.maxHeaderBytes, "fixture exact header size")
        _ = try head(limit)
        refuses(.headersTooLarge, "one byte over exact headers") { _ = try head(wire("GET /", token: nil, extra: ["X-Pad: " + String(repeating: "x", count: pad + 1)])) }
        let caseInsensitive = text.replacingOccurrences(of: "Host:", with: "hOsT:").replacingOccurrences(of: "Authorization:", with: "aUtHoRiZaTiOn:")
        _ = try head(Data(caseInsensitive.utf8)); checks += 1
        _ = try head(Data(String(decoding: wire("GET /", token: nil), as: UTF8.self).replacingOccurrences(of: "HTTP/1.1", with: "HTTP/1.0").utf8)); checks += 1
    }
    static func capabilityAndBootstrap() throws {
        let model = try session()
        let publicPage = try head(wire("GET /", token: nil))
        try model.authorize(publicPage, now: 0, liveGrant: permit)
        refuses(.authority, "bootstrap contains no auth") { _ = try head(wire("GET /")) }
        for route in ["GET /state", "POST /input", "GET /file"] {
            refuses(.authority, "protected requires auth") { _ = try head(wire(route, token: nil)) }
            let wrong = try head(wire(route, token: second))
            refuses(.authority, "wrong capability") { try model.authorize(wrong, now: 0, liveGrant: permit) }
        }
        for token in ["", "a", String(repeating: "a", count: 31), String(repeating: "a", count: 33), String(repeating: "a", count: 130), String(repeating: "A", count: 32), String(repeating: "g", count: 32)] {
            refuses(.invalidCapability, "invalid token material") { _ = try P.Capability(hex: token) }
        }
        check(!first.matches(second) && first.matches(first), "bounded exact token match")
        for host in ["localhost", "192.168.001.20", "192.168.1.256", "127.1", "[::1]", "192.168.1.20\r\nX: x"] {
            refuses(.host, "numeric host constructor") { _ = try P.Endpoint(ipv4: host, port: 49152) }
        }
        refuses(.host, "zero port") { _ = try P.Endpoint(ipv4: "192.168.1.20", port: 0) }
        refuses(.route, "download cannot upload") { _ = try session(.download).reserveInput(head(wire()), now: 0, liveGrant: permit) }
        refuses(.route, "restore cannot fetch file") { try session(.restore).authorize(head(wire("GET /file")), now: 0, liveGrant: permit) }
        let other = try session()
        refuses(.denied, "capability never replaces live grant") { try other.authorize(publicPage, now: 0, liveGrant: { _ in false }) }
    }
    static func claimsDrainAndOneShot() throws {
        let model = try session()
        let parsed = try head(wire())
        let owner = model.owner
        var claims: [P.Claim] = []
        for _ in 0..<4 {
            do { claims.append(try model.reserveInput(parsed, now: 0, liveGrant: permit)) }
            catch { check(error as? P.Refusal == .busy, "four upload contenders reject before append") }
        }
        check(claims.count == 1 && model.partialInputByteCount == 0, "exactly one pre-append claim")
        let old = claims[0]
        check(old.owner == owner, "claim captures complete original owner")
        try model.appendInput(Data([0, 255]), claim: old, now: 1, liveGrant: permit)
        model.beginInputDrain(claim: old)
        check(model.partialInputByteCount == 2, "partial buffer retained until actual drain")
        refuses(.busy, "retry before drain") { try model.retryInput(with: second, now: 1, liveGrant: permit) }
        check(model.inputDrained(claim: old), "exact drain discards partial buffer")
        refuses(.retryRequired, "no implicit upload retry") { _ = try model.reserveInput(parsed, now: 1, liveGrant: permit) }
        try model.retryInput(with: second, now: 1, liveGrant: permit)
        refuses(.authority, "old upload token retired") { _ = try model.reserveInput(parsed, now: 1, liveGrant: permit) }
        let newer = try model.reserveInput(head(wire(token: second)), now: 1, liveGrant: permit)
        check(!model.inputDrained(claim: old), "late old drain cannot free successor")
        check(newer != old, "fresh attempt identity")
        try model.appendInput(Data([1, 2, 3, 4, 5]), claim: newer, now: 2, liveGrant: permit)
        let accepted = try model.commitInput(claim: newer, now: 2, liveGrant: permit)
        check(accepted.bytes == Data([1, 2, 3, 4, 5]), "immutable accepted input exact")
        check(model.inputDrained(claim: newer), "accepted drain")
        refuses(.consumed, "accepted input cannot be replaced") { _ = try model.reserveInput(head(wire(token: second)), now: 2, liveGrant: permit) }
        refuses(.consumed, "format refusal cannot unconsume") { try model.retryInput(with: third, now: 2, liveGrant: permit) }
        check(model.acceptedInput?.bytes == accepted.bytes, "input unchanged after replay")
        let denied = try session()
        let claim = try denied.reserveInput(parsed, now: 0, liveGrant: permit)
        refuses(.denied, "grant lost before first body append") { try denied.appendInput(Data([1]), claim: claim, now: 0, liveGrant: { _ in false }) }
        check(denied.partialInputByteCount == 0 && denied.retired, "no eager grant-lost append")
        check(denied.hasUndrainedAttempts, "retired claim still drains")
        check(denied.inputDrained(claim: claim), "retired exact drain")
        try denied.releaseRetiredPayloadsAfterDrain()
        let midUpload = try session()
        let midClaim = try midUpload.reserveInput(parsed, now: 0, liveGrant: permit)
        try midUpload.appendInput(Data([1, 2]), claim: midClaim, now: 1, liveGrant: permit)
        refuses(.denied, "grant lost during upload") { try midUpload.appendInput(Data([3]), claim: midClaim, now: 1, liveGrant: { _ in false }) }
        check(midUpload.partialInputByteCount == 2 && !midUpload.inputConsumed, "revoked partial input never committed")
        let otherOwner = try session()
        refuses(.stale, "foreign session/operation claim rejected") { try otherOwner.appendInput(Data([1]), claim: midClaim, now: 0, liveGrant: permit) }
        let commitDenied = try session()
        let commitClaim = try commitDenied.reserveInput(parsed, now: 0, liveGrant: permit)
        try commitDenied.appendInput(Data([1, 2, 3, 4, 5]), claim: commitClaim, now: 0, liveGrant: permit)
        refuses(.denied, "grant rechecked at immutable commit") { _ = try commitDenied.commitInput(claim: commitClaim, now: 0, liveGrant: { _ in false }) }
        check(!commitDenied.inputConsumed && commitDenied.acceptedInput == nil, "uncommitted complete input is not accepted")
    }
    static func bodyAndTimeBounds() throws {
        let parsed = try head(wire())
        let eof = try session()
        let claim = try eof.reserveInput(parsed, now: 0, liveGrant: permit)
        try eof.appendInput(Data([1]), claim: claim, now: 1, liveGrant: permit)
        refuses(.earlyEOF, "early TCP EOF") { try eof.inputEOF(claim: claim, now: 1, liveGrant: permit) }
        check(eof.hasUndrainedAttempts, "EOF does not free callback ownership")
        let overflow = try session()
        let overClaim = try overflow.reserveInput(parsed, now: 0, liveGrant: permit)
        refuses(.extraBytes, "fragmented overflow") { try overflow.appendInput(Data(repeating: 1, count: 6), claim: overClaim, now: 0, liveGrant: permit) }
        check(overflow.partialInputByteCount == 0, "overflow checked before append")
        let minimum = try session()
        let minClaim = try minimum.reserveInput(head(wire(length: "1")), now: 0, liveGrant: permit)
        try minimum.appendInput(Data([0]), claim: minClaim, now: 0, liveGrant: permit)
        try minimum.inputEOF(claim: minClaim, now: 0, liveGrant: permit)
        let minAccepted = try minimum.commitInput(claim: minClaim, now: 0, liveGrant: permit)
        check(minAccepted.bytes == Data([0]), "one byte length with exact EOF")
        let large = try session()
        let largeHead = try head(wire(length: String(P.maxFileBytes)))
        let largeClaim = try large.reserveInput(largeHead, now: 0, liveGrant: permit)
        refuses(.chunkTooLarge, "receive chunk bounded") { try large.appendInput(Data(repeating: 1, count: P.chunkBytes + 1), claim: largeClaim, now: 0, liveGrant: permit) }
        // Actual maximum accepted through bounded appends, never one unchecked reserveCapacity.
        let maximum = try session()
        let maxClaim = try maximum.reserveInput(largeHead, now: 0, liveGrant: permit)
        let chunk = Data(repeating: 0xA5, count: P.chunkBytes)
        for _ in 0..<(P.maxFileBytes / P.chunkBytes) { try maximum.appendInput(chunk, claim: maxClaim, now: 1, liveGrant: permit) }
        let maxAccepted = try maximum.commitInput(claim: maxClaim, now: 1, liveGrant: permit)
        check(maxAccepted.bytes.count == P.maxFileBytes, "exact 10MiB input")
        let idle = try session()
        _ = try idle.reserveInput(parsed, now: 0, liveGrant: permit)
        refuses(.expired, "idle timer without bytes") { try idle.enforceDeadlines(now: 15, liveGrant: permit) }
        let total = try session()
        let totalClaim = try total.reserveInput(largeHead, now: 0, liveGrant: permit)
        for instant in [10.0, 20, 30, 40, 50] { try total.appendInput(Data([1]), claim: totalClaim, now: instant, liveGrant: permit) }
        refuses(.expired, "60s total body bound") { try total.appendInput(Data([1]), claim: totalClaim, now: 60, liveGrant: permit) }
        var header = try P.HeaderParser(endpoint: endpoint, now: 0)
        refuses(.expired, "15s header bound") { _ = try header.consume(wire(), now: 15) }
        var withinHeader = try P.HeaderParser(endpoint: endpoint, now: 0)
        _ = try withinHeader.consume(wire(), now: 14.999); checks += 1
        var partial = try P.HeaderParser(endpoint: endpoint, now: 0)
        _ = try partial.consume(Data("GET / HTTP/1.1\r\n".utf8), now: 1)
        refuses(.earlyEOF, "partial header EOF") { try partial.eof(now: 1) }
        let clock = try session()
        try clock.enforceDeadlines(now: 10, liveGrant: permit)
        refuses(.clock, "clock rewind") { try clock.enforceDeadlines(now: 9, liveGrant: permit) }
        let nan = try session()
        refuses(.clock, "nonfinite clock") { try nan.enforceDeadlines(now: .nan, liveGrant: permit) }
        let life = try session()
        let state = try head(wire("GET /state"))
        _ = try life.stateBody(for: state, now: 299, liveGrant: permit)
        refuses(.expired, "poll never extends 5min deadline") { _ = try life.stateBody(for: state, now: 300, liveGrant: permit) }
        check(life.deadline == 300 && life.retired, "original expiry immutable")
    }
    static func outputRetryAndRevocation() throws {
        let repair = try session(.repair)
        let repairClaim = try repair.reserveInput(head(wire(length: "1")), now: 0, liveGrant: permit)
        try repair.appendInput(Data([0xFF]), claim: repairClaim, now: 0, liveGrant: permit)
        _ = try repair.commitInput(claim: repairClaim, now: 0, liveGrant: permit)
        refuses(.notReady, "repair output requires TV review phase") { _ = try repair.installOutput(Data([1]), snapshotID: UUID(), now: 0, liveGrant: permit) }
        try repair.showReview(now: 0, liveGrant: permit)
        let repaired = try repair.installOutput(Data([1, 2]), snapshotID: UUID(), now: 0, liveGrant: permit)
        check(repaired.filename == .repaired, "repair fixed output name")
        let stateBody = try repair.stateBody(for: head(wire("GET /state")), now: 0, liveGrant: permit)
        check(String(decoding: stateBody, as: UTF8.self) == "{\"mode\":\"repair\",\"stage\":\"available\"}", "state contains mode/stage only")
        let model = try session(.download)
        let data = Data(repeating: 7, count: P.chunkBytes + 1)
        let id = UUID()
        let info = try model.installOutput(data, snapshotID: id, now: 0, liveGrant: permit)
        let request = try head(wire("GET /file"))
        let old = try model.reserveOutput(request, now: 0, liveGrant: permit)
        let firstChunk = try model.releaseOutputChunk(claim: old, now: 0, liveGrant: permit)!
        check(firstChunk.bytes.count == P.chunkBytes, "bounded output chunk")
        refuses(.busy, "one send chain") { _ = try model.releaseOutputChunk(claim: old, now: 0, liveGrant: permit) }
        try model.localChunkProcessed(claim: old, range: firstChunk.range, now: 0, liveGrant: permit)
        let lastChunk = try model.releaseOutputChunk(claim: old, now: 0, liveGrant: permit)!
        check(lastChunk.bytes.count == 1, "output last exact byte")
        try model.localChunkProcessed(claim: old, range: lastChunk.range, now: 0, liveGrant: permit)
        try model.finishOutput(claim: old, success: true, now: 0, liveGrant: permit)
        check(model.localSendOutcome == .tvFinishedSendingCheckPhone, "local completion explicitly no browser receipt")
        refuses(.busy, "retry cannot overlap draining send") { _ = try model.retryOutput(with: second, now: 1, liveGrant: permit) }
        check(model.outputDrained(claim: old), "real send drain")
        refuses(.retryRequired, "no browser initiated implicit retry") { _ = try model.reserveOutput(request, now: 1, liveGrant: permit) }
        refuses(.retryRequired, "retry requires a fresh token") { _ = try model.retryOutput(with: first, now: 1, liveGrant: permit) }
        let same = try model.retryOutput(with: second, now: 2, liveGrant: permit)
        check(same == info && same.snapshotID == id && same.owner == model.owner, "retry retains snapshot and original owner")
        check(model.deadline == 300, "retry unchanged deadline")
        refuses(.authority, "old output token retired") { _ = try model.reserveOutput(request, now: 2, liveGrant: permit) }
        let next = try model.reserveOutput(head(wire("GET /file", token: second)), now: 2, liveGrant: permit)
        check(!model.outputDrained(claim: old), "stale output cleanup cannot free successor")
        let retryChunk = try model.releaseOutputChunk(claim: next, now: 2, liveGrant: permit)!
        check(retryChunk.bytes == firstChunk.bytes && retryChunk.range.lowerBound == 0, "retry starts same immutable bytes")
        try model.finishOutput(claim: next, success: false, now: 2, liveGrant: permit)
        check(model.outputDrained(claim: next), "failed output drains")
        _ = try model.retryOutput(with: third, now: 299, liveGrant: permit)
        refuses(.snapshotAlreadySet, "retry cannot replace snapshot or call take again") { _ = try model.installOutput(Data([9]), snapshotID: UUID(), now: 299, liveGrant: permit) }
        refuses(.expired, "retry does not extend expiry") { _ = try model.reserveOutput(head(wire("GET /file", token: third)), now: 300, liveGrant: permit) }
        let denied = try session(.download)
        _ = try denied.installOutput(data, snapshotID: UUID(), now: 0, liveGrant: permit)
        let deniedClaim = try denied.reserveOutput(request, now: 0, liveGrant: permit)
        refuses(.denied, "queued output release rechecks grant") { _ = try denied.releaseOutputChunk(claim: deniedClaim, now: 0, liveGrant: { _ in false }) }
        refuses(.draining, "cannot clear transport payload before actual drain") { try denied.releaseRetiredPayloadsAfterDrain() }
        check(denied.outputDrained(claim: deniedClaim), "revoked output callback drains")
        try denied.releaseRetiredPayloadsAfterDrain()
        check(denied.outputInfo == nil, "only retired/drained transport data cleared")
        let midway = try session(.download)
        _ = try midway.installOutput(data, snapshotID: UUID(), now: 0, liveGrant: permit)
        let midwayClaim = try midway.reserveOutput(request, now: 0, liveGrant: permit)
        let alreadyReleased = try midway.releaseOutputChunk(claim: midwayClaim, now: 0, liveGrant: permit)!
        refuses(.denied, "grant loss during local callback cannot advance send") { try midway.localChunkProcessed(claim: midwayClaim, range: alreadyReleased.range, now: 1, liveGrant: { _ in false }) }
        check(midway.retired && midway.hasUndrainedAttempts, "already released bytes cannot be recalled; exact attempt still drains")
        let sendIdle = try session(.download)
        _ = try sendIdle.installOutput(Data([1]), snapshotID: UUID(), now: 0, liveGrant: permit)
        let idleClaim = try sendIdle.reserveOutput(request, now: 0, liveGrant: permit)
        refuses(.expired, "send idle deadline without callbacks") { try sendIdle.enforceDeadlines(now: 15, liveGrant: permit) }
        check(sendIdle.hasUndrainedAttempts, "timed-out send still drains")
        check(sendIdle.outputDrained(claim: idleClaim), "exact timed-out send drain")
        let sendTotal = try session(.download)
        _ = try sendTotal.installOutput(Data(repeating: 1, count: P.chunkBytes * 8), snapshotID: UUID(), now: 0, liveGrant: permit)
        let totalClaim = try sendTotal.reserveOutput(request, now: 0, liveGrant: permit)
        for instant in [10.0, 20, 30, 40, 50] {
            let part = try sendTotal.releaseOutputChunk(claim: totalClaim, now: instant, liveGrant: permit)!
            try sendTotal.localChunkProcessed(claim: totalClaim, range: part.range, now: instant, liveGrant: permit)
        }
        refuses(.expired, "send total deadline") { _ = try sendTotal.releaseOutputChunk(claim: totalClaim, now: 60, liveGrant: permit) }
    }
    static func phoneBoundaries() throws {
        let html = Page.html, js = Page.script
        for unsafe in ["localStorage", "sessionStorage", "document.cookie", "innerHTML", "XMLHttpRequest", "sendBeacon", "/confirm", "/account", "http://evil", "https://", "eval(", "new Function", "file.text(", "JSON.stringify(file"] {
            check(!html.contains(unsafe), "phone excludes unsafe surface: " + unsafe)
        }
        check(js.contains("history.replaceState(null, \"\", \"/\")"), "fragment removed before fetch")
        check(js.contains("request.body = file"), "raw original File, never JSON round trip")
        check(js.contains("now - lastPoll < 1000") && js.contains("document.hidden"), "poll interval and visibility gates")
        check(js.contains("local-send-complete") && js.contains("stop()"), "terminal poll stop")
        check(html.contains("outer file metadata, including preserved unknown fields"), "honest trusted LAN caveat")
        check(html.contains("TV only") && js.contains("does not confirm a saved file"), "no phone restore/save claim")
        let head = try Page.responseHead(status: .ok, kind: .bootstrap, byteCount: Page.bytes.count)
        let response = String(decoding: head, as: UTF8.self)
        for header in ["Cache-Control: no-store", "Referrer-Policy: no-referrer", "X-Content-Type-Options: nosniff", "X-Frame-Options: DENY", "frame-ancestors 'none'", "Connection: close"] {
            check(response.contains(header), "fixed security response header")
        }
        let fileHead = String(decoding: try Page.responseHead(status: .ok, kind: .file(.backup), byteCount: 5), as: UTF8.self)
        check(fileHead.contains("filename=\"vortx-account-backup.json\""), "safe fixed filename")
        check(!response.contains("Access-Control-Allow"), "no CORS")
        // Runner hashes THESE compiled Swift strings, not a stale authoring template.
        print("PAGE_SCRIPT_BASE64=" + Data(Page.script.utf8).base64EncodedString())
        print("PAGE_STYLE_BASE64=" + Data(Page.style.utf8).base64EncodedString())
        print("PAGE_CSP=" + Page.contentSecurityPolicy)
    }
    static func main() throws {
        try allFragmentationSplits(); try malformedHeaders(); try capabilityAndBootstrap()
        try claimsDrainAndOneShot(); try bodyAndTimeBounds(); try outputRetryAndRevocation(); try phoneBoundaries()
        print("PASS actual transfer policy checks=" + String(checks))
        print("UNPROVED: Network schedules/listener readiness/4-connection cap/adapter wall timers/live route/account/PIN wiring/tvOS Full+Lite/Mac+iOS regression/browser/device/save behavior")
    }
}
