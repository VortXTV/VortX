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

        expect(JSProviderURLPolicy.isPublicNumericAddress("8.8.8.8"), "public IPv4 accepted")
        expect(JSProviderURLPolicy.isPublicNumericAddress("2001:4860:4860::8888"), "public IPv6 accepted")
        ["127.0.0.1", "10.0.0.1", "169.254.1.1", "100.64.0.1", "::1", "fc00::1", "::ffff:127.0.0.1"].forEach {
            expect(!JSProviderURLPolicy.isPublicNumericAddress($0), "private numeric address rejected \($0)")
        }
        expectFailure({ _ = try PinnedHTTPClient.endpoint(for: signed, answers: ["8.8.8.8", "127.0.0.1"]) }, .unsafeResolution, "mixed DNS answer rejected")
        expectFailure({ _ = try PinnedHTTPClient.endpoint(for: signed, answers: ["127.0.0.1"]) }, .unsafeResolution, "rebound private answer rejected")
        expectFailure({ _ = try PinnedHTTPClient.requestBytes(for: .init(url: signed, headers: ["Host": "bad"]), endpoint: endpoint) }, .unsafeHeader, "caller cannot override Host")

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

        let complete = Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello".utf8)
        let parsed = try! PinnedHTTPClient.decodeResponse(complete, limits: .init())!
        expect(parsed.statusCode == 206 && parsed.body == Data("hello".utf8), "bounded content-length framing")
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(chunked, limits: .init())?.body == Data("hello".utf8), "chunked framing")
        let caseFoldedChunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: ChUnKeD\r\n\r\n1\r\nx\r\n0\r\n\r\n".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(caseFoldedChunked, limits: .init())?.body == Data("x".utf8), "transfer-encoding token is case insensitive")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "TE plus CL is rejected before response body handling")
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8), limits: .init()) }, .malformedResponse, "unsupported transfer-encoding chain is rejected")
        let headResponse = try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n".utf8), limits: .init(), method: "HEAD")!
        expect(headResponse.body.isEmpty, "HEAD succeeds without a declared response body")
        let closeResponse = Data("HTTP/1.1 200 OK\r\nX-Test: close\r\n\r\nabc".utf8)
        expect(try! PinnedHTTPClient.decodeResponse(closeResponse, limits: .init()) == nil, "close-delimited execute waits for EOF")
        expect(try! PinnedHTTPClient.decodeResponse(closeResponse, limits: .init(), isComplete: true)?.body == Data("abc".utf8), "close-delimited execute accepts clean EOF")
        let redirect = try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 302 Found\r\nLocation: https://other.example/\r\nContent-Length: 0\r\n\r\n".utf8), limits: .init())!
        expect(redirect.statusCode == 302 && redirect.headers["location"] == "https://other.example/", "redirect is returned for manual revalidation")
        var small = PinnedHTTPClient.Limits(); small.maximumBodyBytes = 4
        expectFailure({ _ = try PinnedHTTPClient.decodeResponse(complete, limits: small) }, .responseTooLarge, "response body cap")
        expect(try! PinnedHTTPClient.decodeResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nsmall".utf8), limits: .init()) == nil, "incomplete framing waits")

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

        var hugeFramer = StreamFramer(method: "GET", limits: .init())
        let hugeA = try! hugeFramer.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100000000\r\na".utf8), endOfStream: false)
        let hugeB = try! hugeFramer.consume(Data("bc".utf8), endOfStream: false)
        let hugeBody = (hugeA + hugeB).compactMap { event -> Data? in if case let .body(bytes) = event { return bytes }; return nil }
        expect(hugeBody.reduce(Data(), +) == Data("abc".utf8), "huge declared chunk forwards tiny available pieces")
        expect(hugeFramer.bufferedByteCount == 0, "huge declared chunk retains no unbounded pending body")

        var closeDelimited = StreamFramer(method: "GET", limits: .init())
        let closeA = try! closeDelimited.consume(Data("HTTP/1.1 200 OK\r\nX-Test: close\r\n\r\nabc".utf8), endOfStream: false)
        let closeB = try! closeDelimited.consume(Data(), endOfStream: true)
        expect((closeA + closeB).contains(.complete), "close-delimited streaming completes on clean EOF")
        var partial = StreamFramer(method: "GET", limits: .init())
        expectFailure({ _ = try partial.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8), endOfStream: true) }, .malformedResponse, "partial fixed-length stream fails at EOF")

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
