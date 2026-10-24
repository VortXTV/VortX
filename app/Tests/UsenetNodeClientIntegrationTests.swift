// Credential-free integration test for the native NZB capabilities/POST/key contract.
// Run from repository root: bash scripts/test-native-transport.sh

import Foundation

private final class FakeNodeProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var captured: URLRequest?
        var body: Data?
        var requests: [URLRequest] = []
    }
    private static let state = State()
    static func capturedRequest() -> (URLRequest?, Data?) { state.lock.withLock { (state.captured, state.body) } }
    static var controlRequests: [URLRequest] {
        state.lock.withLock { state.requests.filter { !$0.url!.path.hasSuffix("/cancel") } }
    }

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
        let requestPath = request.url!.path
        Self.state.lock.withLock {
            Self.state.requests.append(request)
            // Cleanup is asynchronous. It must never replace the create payload under test.
            if requestPath == "/nzb/create" {
                Self.state.captured = request
                Self.state.body = body
            }
        }
        let status: Int
        let responseBody: String
        switch requestPath {
        case "/nzb/capabilities":
            status = 200
            responseBody = #"{"version":1,"raw":true,"multipartYenc":true,"checksumsRequired":true,"archives":["rar4-store","rar5-store","7z-copy"],"operationCancellation":true,"operationIdFormat":"uuid","selection":{"fileIdx":true,"fileMustInclude":true,"episode":true,"fileIdxOrder":"nzb-media-or-archive-entry-order","regexSyntax":"bare-or-js-ims"}}"#
        case "/nzb/create":
            status = 200
            responseBody = #"{"key":"node key&other=value#fragment"}"#
        default:
            precondition(requestPath.hasSuffix("/cancel"), "Unexpected native control route")
            status = 204
            responseBody = ""
        }
        let data = Data(responseBody.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
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
        defer { session.invalidateAndCancel() }
        let created = try await UsenetNodeClient.createStream(
            base: "http://127.0.0.1:45678", nzbURLs: ["https://nzb.example/a.nzb", "https://nzb.example/b.nzb"],
            servers: ["nntps://user:pass@news.example:563/4"], session: session, timeout: 1,
            ownerIsCurrent: { true })
        defer { created.lease?.close() }
        let stream = created.url
        let (request, body) = FakeNodeProtocol.capturedRequest()
        guard request?.httpMethod == "POST", request?.url?.absoluteString == "http://127.0.0.1:45678/nzb/create",
              let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["nzbUrls"] as? [String])?.count == 2,
              (object["servers"] as? [String])?.count == 1,
              let lease = created.lease, !lease.isClosed,
              (object["operationId"] as? String) == lease.id, UUID(uuidString: lease.id) != nil,
              FakeNodeProtocol.controlRequests.map({ $0.url!.path }) == ["/nzb/capabilities", "/nzb/create"],
              FakeNodeProtocol.controlRequests.map(\.httpMethod) == ["GET", "POST"],
              stream.absoluteString == "http://127.0.0.1:45678/nzb/stream?key=node%20key%26other%3Dvalue%23fragment",
              URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems == [
                URLQueryItem(name: "key", value: "node key&other=value#fragment")
              ] else {
            throw NSError(domain: "UsenetNodeClientIntegration", code: 1)
        }
        print("PASS  injected native capability/leased POST/key contract follows dynamic local port")
    }
}
