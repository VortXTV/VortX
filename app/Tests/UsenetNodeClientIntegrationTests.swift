// Credential-free integration test for Node's NZB POST/key contract using an injected URLSession protocol.
// Run from repository root:
// swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors -o /tmp/usenet-node-client \
//   app/SourcesShared/UsenetNodeClient.swift app/Tests/UsenetNodeClientIntegrationTests.swift && /tmp/usenet-node-client

import Foundation

private final class FakeNodeProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable { let lock = NSLock(); var captured: URLRequest?; var body: Data? }
    private static let state = State()
    static func capturedRequest() -> (URLRequest?, Data?) { state.lock.withLock { (state.captured, state.body) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data?
        if let direct = request.httpBody { body = direct }
        else if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let read = input.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            body = data
        } else { body = nil }
        Self.state.lock.withLock { Self.state.captured = request; Self.state.body = body }
        let data = Data(#"{"key":"node key&other=value#fragment"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor
private enum UsenetNodeClientIntegrationTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeNodeProtocol.self]
        let session = URLSession(configuration: config)
        let stream: URL
        do {
            stream = try await UsenetNodeClient.createStream(
                base: "http://127.0.0.1:45678", nzbURLs: ["https://nzb.example/a.nzb", "https://nzb.example/b.nzb"],
                servers: ["nntps://user:pass@news.example:563/4"], session: session, timeout: 1
            )
        } catch { throw error }
        let (request, body) = FakeNodeProtocol.capturedRequest()
        guard request?.httpMethod == "POST", request?.url?.absoluteString == "http://127.0.0.1:45678/nzb/create",
              let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["nzbUrls"] as? [String])?.count == 2,
              (object["servers"] as? [String])?.count == 1,
              stream.absoluteString == "http://127.0.0.1:45678/nzb/stream?key=node%20key%26other%3Dvalue%23fragment",
              URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems == [
                URLQueryItem(name: "key", value: "node key&other=value#fragment")
              ] else {
            throw NSError(domain: "UsenetNodeClientIntegration", code: 1)
        }
        print("PASS  injected Node POST/key/redirect contract follows dynamic local port")
    }
}
