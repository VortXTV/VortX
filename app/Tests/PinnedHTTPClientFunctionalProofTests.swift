import Foundation

/// Deterministic proof for the exact-address transport contract. It deliberately avoids live DNS and sockets:
/// endpoint selection, SNI/Host preservation, byte framing, redirect refusal, unsafe DNS results, and bounded
/// response handling remain repeatable on every Apple platform.
@main
struct PinnedHTTPClientFunctionalProofTests {
    actor AttemptLog {
        private(set) var addresses: [String] = []
        func record(_ address: String) { addresses.append(address) }
        func snapshot() -> [String] { addresses }
    }

    static func main() async {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Pinned HTTP proof failed: \(message)") }
            checks += 1
        }
        func expectFailure(_ body: () throws -> Void, _ expected: PinnedHTTPClient.Failure, _ message: String) {
            do { try body(); fatalError("Pinned HTTP proof unexpectedly succeeded: \(message)") }
            catch let error as PinnedHTTPClient.Failure { expect(error == expected, message) }
            catch { fatalError("Pinned HTTP proof wrong error: \(error)") }
        }
        func expectAsyncFailure<T: Sendable>(_ body: () async throws -> T, _ expected: PinnedHTTPClient.Failure, _ message: String) async {
            do { _ = try await body(); fatalError("Pinned HTTP proof unexpectedly succeeded: \(message)") }
            catch let error as PinnedHTTPClient.Failure { expect(error == expected, message) }
            catch { fatalError("Pinned HTTP proof wrong error: \(error)") }
        }

        let signed = URL(string: "https://media.example.test:8443/a%2Fb.ts?sig=a%2Bb&sig=c%2Fd&x=%7E")!
        let endpoint = try! PinnedHTTPClient.endpoint(for: signed, answers: ["8.8.8.8", "2001:4860:4860::8888"])
        expect(endpoint.address == "2001:4860:4860::8888", "deterministic exact peer")
        expect(endpoint.tlsServerName == "media.example.test", "original TLS SNI")
        expect(endpoint.hostHeader == "media.example.test:8443", "original Host header")
        let request = try! String(decoding: PinnedHTTPClient.requestBytes(for: .init(url: signed, headers: ["Authorization": "Bearer test"]), endpoint: endpoint), as: UTF8.self)
        expect(request.contains("GET /a%2Fb.ts?sig=a%2Bb&sig=c%2Fd&x=%7E HTTP/1.1"), "signed query byte fidelity")
        expect(request.contains("Host: media.example.test:8443"), "request Host preservation")
        expect(!request.contains("203.0.114.8"), "numeric peer never leaks into HTTP framing")
        let literalURL = URL(string: "https://[2001:4860:4860::8888]:8443/live")!
        let literalEndpoint = try! PinnedHTTPClient.endpoint(for: literalURL, answers: ["2001:4860:4860::8888"])
        let literalRequest = try! String(decoding: PinnedHTTPClient.requestBytes(for: .init(url: literalURL), endpoint: literalEndpoint), as: UTF8.self)
        expect(literalRequest.contains("Host: [2001:4860:4860::8888]:8443"), "IPv6 literals are bracketed in Host")

        expect(JSProviderURLPolicy.isPublicNumericAddress("8.8.8.8"), "public IPv4 accepted")
        expect(JSProviderURLPolicy.isPublicNumericAddress("2001:4860:4860::8888"), "public IPv6 accepted")
        ["127.0.0.1", "10.0.0.1", "169.254.1.1", "100.64.0.1", "::1", "fc00::1", "::ffff:127.0.0.1"].forEach {
            expect(!JSProviderURLPolicy.isPublicNumericAddress($0), "private numeric address rejected \($0)")
        }
        expectFailure({ _ = try PinnedHTTPClient.endpoint(for: signed, answers: ["8.8.8.8", "127.0.0.1"]) }, .unsafeResolution, "mixed DNS answer rejected")
        expectFailure({ _ = try PinnedHTTPClient.endpoint(for: signed, answers: ["127.0.0.1"]) }, .unsafeResolution, "rebound private answer rejected")
        expectFailure({ _ = try PinnedHTTPClient.endpoint(for: signed, answers: ["resolver.example.test"]) }, .unsafeResolution, "hostname resolver answers are never reparsed")
        ["::ffff:8.8.8.8", "64:ff9b::808:808", "64:ff9b:1::808:808", "2002:0808:0808::1", "2001:0000::1"].forEach { unsafeAddress in
            expectFailure({ _ = try PinnedHTTPClient.endpoint(for: signed, answers: [unsafeAddress]) }, .unsafeResolution, "mapped, PREF64, and transition address rejected \(unsafeAddress)")
        }
        let duplicateIPv6 = try! PinnedHTTPClient.endpoints(for: signed, answers: ["2001:4860:4860::8888", "2001:4860:4860:0:0:0:0:8888"])
        expect(duplicateIPv6.count == 1, "binary-equivalent IPv6 answers are deduplicated")
        let synthesized = NumericAddress.parse("2606:4700:1234:5678:9abc:def0:c0a8:0001")!
        expect(synthesized.usesPREF64Prefix([Data(synthesized.bytes.prefix(12))]), "active network PREF64 synthesis is identified by binary prefix")
        var cappedPeers = PinnedHTTPClient.Limits(); cappedPeers.maximumPeers = 2; cappedPeers.maximumPeersPerFamily = 2
        let capped = try! PinnedHTTPClient.endpoints(for: signed, answers: ["1.1.1.1", "8.8.8.8", "9.9.9.9"], limits: cappedPeers)
        expect(capped.count == 2, "peer snapshot is bounded per transport policy")
        let hostileRequest = try! String(decoding: PinnedHTTPClient.requestBytes(for: .init(url: signed, headers: [
            "Authorization": "Bearer safe", "Range": "bytes=10-20", "Host": "bad", "Content-Length": "9",
            "Transfer-Encoding": "chunked", "Connection": "keep-alive", "tE": "trailers", "Trailer": "X-Test",
            "Keep-Alive": "timeout=5", "Proxy-Authorization": "Basic secret", "Proxy-Authenticate": "Basic",
            "Proxy-Connection": "keep-alive", "Upgrade": "websocket"
        ]), endpoint: endpoint), as: UTF8.self)
        expect(hostileRequest.contains("Authorization: Bearer safe") && hostileRequest.contains("Range: bytes=10-20"),
               "origin and dynamic Range headers survive request defense")
        expect(!["Host: bad", "Content-Length: 9", "Transfer-Encoding:", "Connection: keep-alive", "tE:",
                 "Trailer:", "Keep-Alive:", "Proxy-Authorization:", "Proxy-Authenticate:", "Proxy-Connection:", "Upgrade:"]
            .contains(where: hostileRequest.contains), "request defense strips hop and framing headers case-insensitively")
        ["bad\u{0000}", "bad\u{000B}", "bad\u{000C}", "bad\u{007F}"].forEach { value in
            let clean = try! String(decoding: PinnedHTTPClient.requestBytes(for: .init(url: signed, headers: ["X-Test": value]), endpoint: endpoint), as: UTF8.self)
            expect(!clean.contains("X-Test:"), "invalid outbound field bytes are stripped")
        }

        // A DNS snapshot yields every vetted peer. The first dead peer does not prevent the next peer from
        // completing under the same caller-owned deadline.
        let attempts = AttemptLog()
        let peers = try! PinnedHTTPClient.endpoints(for: signed, answers: ["8.8.8.8", "1.1.1.1"])
        let liveAddress = try! await PinnedHTTPClient.firstSuccessful(peers) { peer in
            await attempts.record(peer.address)
            if peer.address == "1.1.1.1" { throw PinnedHTTPClient.Failure.connectionFailed }
            return peer.address
        }
        expect(liveAddress == "8.8.8.8", "live second peer succeeds after dead first peer")
        let attemptedAddresses = await attempts.snapshot()
        expect(attemptedAddresses == ["1.1.1.1", "8.8.8.8"], "every DNS-snapshot peer is sequenced once")
        expect(PinnedHTTPClient.fairPeerAttemptTimeout(remaining: 9, peersRemaining: 3, minimum: 0.25) == 3, "blackholed peer receives only its fair pre-head share")
        expect(PinnedHTTPClient.timeoutNanoseconds(0.5) == 500_000_000, "finite timeout converts to checked nanoseconds")
        expect(PinnedHTTPClient.timeoutNanoseconds(Double.greatestFiniteMagnitude) == nil, "overflowing timeout is rejected")

        await expectAsyncFailure({
            let credentialURL = URL(string: "https://user:secret@media.example.test/live")!
            return try await PinnedHTTPClient.execute(.init(url: credentialURL), resolver: { _ in
                [NumericAddress.parse("8.8.8.8")!]
            })
        }, .invalidURL, "userinfo is refused before resolution or dialing")

        let complete = Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello".utf8)
        let parsed = try! PinnedHTTPClient.decodeResponse(complete, limits: .init())!
        expect(parsed.statusCode == 206 && parsed.body == Data("hello".utf8), "bounded content-length framing")
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(chunked, limits: .init())?.body == Data("hello".utf8), "chunked framing")
        let caseFoldedChunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: ChUnKeD\r\n\r\n1\r\nx\r\n0\r\n\r\n".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(caseFoldedChunked, limits: .init())?.body == Data("x".utf8), "transfer-encoding token is case insensitive")
        let subtitleBody = Data("1\n00:00:01,000 --> 00:00:02,000\nhello\n".utf8)
        let subtitleHead = Data((
            "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/x-subrip; charset=utf-8\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "Server-Timing: edge;dur=4\r\n"
                + "Server-Timing: origin;dur=52\r\n"
                + "Set-Cookie: first=one\r\n"
                + "Set-Cookie: second=two\r\n\r\n"
                + String(subtitleBody.count, radix: 16) + "\r\n"
        ).utf8)
        let duplicateMetadataSubtitle = subtitleHead + subtitleBody + Data("\r\n0\r\n\r\n".utf8)
        let parsedSubtitle = try! PinnedHTTPClient.decodeResponse(duplicateMetadataSubtitle, limits: .init())!
        expect(parsedSubtitle.body == subtitleBody, "duplicate metadata headers preserve the subtitle response body")
        expect(parsedSubtitle.headers["server-timing"] == "edge;dur=4, origin;dur=52", "duplicate list metadata is comma-folded in wire order")
        expect(parsedSubtitle.headers["set-cookie"] == "first=one", "Set-Cookie is never comma-folded")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx".utf8), limits: .init()) }, .malformedResponse, "duplicate content-length is rejected even when values agree")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "duplicate transfer-encoding is rejected")
        let withContinue = Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(withContinue, limits: .init())?.body == Data("x".utf8), "bounded interim response chain is consumed before final head")
        expect(try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), limits: .init(), isComplete: true) == nil, "EOF after informational response is not a final response")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "protocol upgrade response is rejected")
        let manyInterims = Data(String(repeating: "HTTP/1.1 100 Continue\r\n\r\n", count: 9).utf8)
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(manyInterims, limits: .init()) }, .malformedResponse, "interim response chain has a bounded count")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "TE plus CL is rejected before response body handling")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n".utf8), limits: .init(), method: "HEAD") }, .malformedResponse, "HEAD cannot bypass TE plus CL validation")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "unsupported transfer-encoding chain is rejected")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "HTTP 1.0 transfer encoding is rejected")
        let headResponse = try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n".utf8), limits: .init(), method: "HEAD")!
        expect(headResponse.body.isEmpty, "HEAD succeeds without a declared response body")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nx".utf8), limits: .init(), method: "HEAD") }, .malformedResponse, "HEAD rejects a surplus response body")
        let notModified = try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n".utf8), limits: .init())!
        expect(notModified.body.isEmpty, "304 permits content-length metadata without a body")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "204 prohibits framing metadata")
        ["HTTP/1.2 200 OK", "HTTP/1.1 20 OK", "HTTP/1.1 200X", "HTTP/1.1\t200 OK", "HTTP/1.1 200 \u{000B}"].forEach { status in
            expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("\(status)\r\nContent-Length: 0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "strict HTTP status grammar rejects \(status)")
        }
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nX-Test: bad\u{000B}\r\nContent-Length: 0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "non-ASCII-OWS field value is rejected")
        let closeResponse = Data("HTTP/1.1 200 OK\r\nX-Test: close\r\n\r\nabc".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(closeResponse, limits: .init()) == nil, "close-delimited execute waits for EOF")
        expect(try! PinnedHTTPClient.decodeResponse(closeResponse, limits: .init(), isComplete: true)?.body == Data("abc".utf8), "close-delimited execute accepts clean EOF")
        let redirect = try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 302 Found\r\nLocation: https://other.example/\r\nContent-Length: 0\r\n\r\n".utf8), limits: .init())!
        expect(redirect.statusCode == 302 && redirect.headers["location"] == "https://other.example/", "redirect is returned for manual revalidation")
        var small = PinnedHTTPClient.Limits(); small.maximumBodyBytes = 4
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(complete, limits: small) }, .responseTooLarge, "response body cap")
        expect(try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nsmall".utf8), limits: .init()) == nil, "incomplete framing waits")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nab".utf8), limits: .init()) }, .malformedResponse, "fixed-length execute rejects buffered surplus")

        // Chunk headers and payloads may arrive split across arbitrary receives. Payload is emitted as it
        // arrives, so a huge declared chunk cannot force the client to retain the whole declaration.
        var splitFramer = StreamFramer(method: "GET", limits: .init())
        let splitA = try! splitFramer.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r".utf8), endOfStream: false)
        expect(splitA.contains { if case .head = $0 { return true }; return false }, "split chunk header emits response head")
        expect(!splitFramer.isComplete, "partial chunk header waits")
        let splitB = try! splitFramer.consume(Data("\nhe".utf8), endOfStream: false)
        let splitC = try! splitFramer.consume(Data("llo\r\n0\r".utf8), endOfStream: false)
        let splitD = try! splitFramer.consume(Data("\n\r\n".utf8), endOfStream: false)
        let splitBody = (splitB + splitC + splitD).compactMap { event -> Data? in if case let .body(bytes) = event { return bytes }; return nil }
        expect(splitBody.reduce(Data(), +) == Data("hello".utf8), "split chunk payload is forwarded incrementally")
        expect(splitFramer.isComplete, "split chunk terminator completes framing")

        var zeroLength = StreamFramer(method: "GET", limits: .init())
        expectFailure({ _ = try zeroLength.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nx".utf8), endOfStream: false) }, .malformedResponse, "zero content length rejects surplus bytes")
        var trailerSurplus = StreamFramer(method: "GET", limits: .init())
        expectFailure({ _ = try trailerSurplus.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Test: yes\r\n\r\nx".utf8), endOfStream: false) }, .malformedResponse, "chunk trailers reject surplus bytes")
        var extensionFramer = StreamFramer(method: "GET", limits: .init())
        expectFailure({ _ = try extensionFramer.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;foo=bar\r\nx\r\n".utf8), endOfStream: false) }, .malformedResponse, "chunk extensions fail closed")
        var prohibitedTrailer = StreamFramer(method: "GET", limits: .init())
        expectFailure({ _ = try prohibitedTrailer.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 1\r\n\r\n".utf8), endOfStream: false) }, .malformedResponse, "prohibited trailer field is rejected")
        var longChunkLine = StreamFramer(method: "GET", limits: .init())
        let oversizedChunkLine = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "A", count: 1_025) + "\r\n").utf8)
        expectFailure({ _ = try longChunkLine.consume(oversizedChunkLine, endOfStream: false) }, .malformedResponse, "coalesced oversized chunk line is rejected")
        var shortTrailerLimit = PinnedHTTPClient.Limits(); shortTrailerLimit.maximumHeaderBytes = 64
        var longTrailer = StreamFramer(method: "GET", limits: shortTrailerLimit)
        let oversizedTrailer = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Test: " + String(repeating: "a", count: 64) + "\r\n\r\n").utf8)
        expectFailure({ _ = try longTrailer.consume(oversizedTrailer, endOfStream: false) }, .responseTooLarge, "coalesced oversized trailer block is rejected")

        var hugeFramer = StreamFramer(method: "GET", limits: .init())
        let hugeA = try! hugeFramer.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100000000\r\na".utf8), endOfStream: false)
        let hugeB = try! hugeFramer.consume(Data("bc".utf8), endOfStream: false)
        let hugeBody = (hugeA + hugeB).compactMap { event -> Data? in if case let .body(bytes) = event { return bytes }; return nil }
        expect(hugeBody.reduce(Data(), +) == Data("abc".utf8), "huge declared chunk forwards tiny available pieces")
        expect(hugeFramer.bufferedByteCount == 0, "huge declared chunk retains no unbounded pending body")
        var streamCap = PinnedHTTPClient.Limits(); streamCap.maximumStreamBytes = 3
        var fixedOverCap = StreamFramer(method: "GET", limits: streamCap)
        expectFailure({ _ = try fixedOverCap.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8), endOfStream: false) }, .responseTooLarge, "declared fixed stream length is rejected before payload")
        var chunkOverCap = StreamFramer(method: "GET", limits: streamCap)
        expectFailure({ _ = try chunkOverCap.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n2\r\ncd".utf8), endOfStream: false) }, .responseTooLarge, "chunk stream cap is overflow-safe and cumulative")
        var closeOverCap = StreamFramer(method: "GET", limits: streamCap)
        expectFailure({ _ = try closeOverCap.consume(Data("HTTP/1.1 200 OK\r\nX-Test: close\r\n\r\nabcd".utf8), endOfStream: false) }, .responseTooLarge, "close-delimited stream cap applies before EOF")
        expect(PinnedHTTPClient.Limits().maximumStreamDuration == nil, "feature-length streams have no implicit post-head hard deadline")

        var closeDelimited = StreamFramer(method: "GET", limits: .init())
        let closeA = try! closeDelimited.consume(Data("HTTP/1.1 200 OK\r\nX-Test: close\r\n\r\nabc".utf8), endOfStream: false)
        let closeB = try! closeDelimited.consume(Data(), endOfStream: true)
        expect((closeA + closeB).contains(.complete), "close-delimited streaming completes on clean EOF")
        var partial = StreamFramer(method: "GET", limits: .init())
        expectFailure({ _ = try partial.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8), endOfStream: true) }, .malformedResponse, "partial fixed-length stream fails at EOF")
        expect(PinnedHTTPClient.isCleanEOF(true, hasError: false), "only a terminal callback without an error is clean EOF")
        expect(!PinnedHTTPClient.isCleanEOF(true, hasError: true), "errored terminal callback is never clean EOF")

        await expectAsyncFailure({
            try await PinnedHTTPClient.withTimeout(0.02) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return 1
            }
        }, .timedOut, "aggregate timeout cancels an in-flight operation")
        let cancellation = Task {
            try await PinnedHTTPClient.withTimeout(10) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        cancellation.cancel()
        do { _ = try await cancellation.value; fatalError("Pinned HTTP proof cancellation unexpectedly succeeded") }
        catch let error as PinnedHTTPClient.Failure { expect(error == .cancelled, "cancellation interrupts in-flight operation") }
        catch { fatalError("Pinned HTTP proof cancellation wrong error: \(error)") }
        print("Pinned HTTP functional proof: PASS (\(checks) checks)")
    }
}
