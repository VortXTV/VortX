import Foundation

final class TorrentCreateRedirectProbe: URLProtocol, @unchecked Sendable {
    struct OriginalRequest: Equatable {
        let path: String
        let method: String
        let body: Data
        let contentType: String?
    }

    struct Snapshot {
        let originalRequests: [OriginalRequest]
        let targetHits: Int
        let targetMethods: [String]
        let targetBodies: [Data]
        let slowHits: Int
        let slowStops: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var originalRequests: [OriginalRequest] = []
    nonisolated(unsafe) private static var targetHits = 0
    nonisolated(unsafe) private static var targetMethods: [String] = []
    nonisolated(unsafe) private static var targetBodies: [Data] = []
    nonisolated(unsafe) private static var slowHits = 0
    nonisolated(unsafe) private static var slowStops = 0

    static func reset() {
        lock.lock()
        originalRequests = []
        targetHits = 0
        targetMethods = []
        targetBodies = []
        slowHits = 0
        slowStops = 0
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            originalRequests: originalRequests,
            targetHits: targetHits,
            targetMethods: targetMethods,
            targetBodies: targetBodies,
            slowHits: slowHits,
            slowStops: slowStops
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "create.test" || request.url?.host == "redirect-target.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { return data }
            data.append(buffer, count: read)
        }
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/slow" {
            Self.lock.lock()
            Self.slowHits += 1
            Self.lock.unlock()
            return
        }
        if url.host == "redirect-target.test" {
            Self.lock.lock()
            Self.targetHits += 1
            Self.targetMethods.append(request.httpMethod ?? "")
            Self.targetBodies.append(request.httpBody ?? Data())
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "0"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.lock.lock()
        Self.originalRequests.append(
            OriginalRequest(
                path: url.path,
                method: request.httpMethod ?? "",
                body: bodyData(for: request),
                contentType: request.value(forHTTPHeaderField: "Content-Type")
            )
        )
        Self.lock.unlock()
        let status = Int(url.lastPathComponent) ?? 302
        let target = URL(string: "https://redirect-target.test/create")!
        var redirected = request
        redirected.url = target
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Location": target.absoluteString,
                "Content-Length": "0",
            ]
        )!
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard request.url?.path == "/slow" else { return }
        Self.lock.lock()
        Self.slowStops += 1
        Self.lock.unlock()
    }
}

@main
struct TorrentCreateTransportTests {
    @MainActor
    static var failures = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    @MainActor
    static func main() async {
        TorrentCreateRedirectProbe.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TorrentCreateRedirectProbe.self]
        let transport = TorrentCreateTransport(configuration: configuration)
        let body = Data(#"{"torrent":{"infoHash":"0123456789abcdef"},"peerSearch":{"sources":["https://tracker.test/announce"]}}"#.utf8)

        let redirectStatuses = [301, 302, 303, 307, 308]
        var statuses: [Int] = []
        for redirectStatus in redirectStatuses {
            do {
                let status = try await transport.create(
                    url: URL(string: "https://create.test/\(redirectStatus)")!,
                    jsonBody: body
                )
                statuses.append(status)
            } catch {
                print("FAIL  redirect \(redirectStatus) returns its original status: \(error)")
                failures += 1
            }
        }

        let snapshot = TorrentCreateRedirectProbe.snapshot()
        expect(statuses == redirectStatuses, "every redirect class surfaces as its exact original response status")
        expect(
            snapshot.originalRequests.map(\.path) == redirectStatuses.map { "/\($0)" },
            "each original redirect endpoint receives exactly one request"
        )
        expect(
            snapshot.originalRequests.allSatisfy { $0.method == "POST" },
            "every original endpoint receives POST"
        )
        expect(
            snapshot.originalRequests.allSatisfy { $0.body == body },
            "every original endpoint receives the exact tracker-bearing body"
        )
        expect(
            snapshot.originalRequests.allSatisfy { $0.contentType == "application/json" },
            "every original endpoint receives application/json content type"
        )
        expect(snapshot.targetHits == 0, "redirect target receives zero requests")
        expect(snapshot.targetMethods.isEmpty, "redirect target receives zero methods")
        expect(snapshot.targetBodies.isEmpty, "redirect target receives zero tracker-bearing bodies")

        let canceledCreate = Task {
            try await transport.create(
                url: URL(string: "https://create.test/slow")!,
                jsonBody: body
            )
        }
        for _ in 0..<100 where TorrentCreateRedirectProbe.snapshot().slowHits == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        canceledCreate.cancel()
        do {
            _ = try await canceledCreate.value
            expect(false, "canceled create does not complete successfully")
        } catch {
            let canceled = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            expect(canceled, "task cancellation cancels the in-flight URLSession create")
        }
        for _ in 0..<100 where TorrentCreateRedirectProbe.snapshot().slowStops == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(
            TorrentCreateRedirectProbe.snapshot().slowStops == 1,
            "canceling create stops its underlying URL loading exactly once"
        )

        if failures > 0 {
            exit(1)
        }
    }
}
