import Foundation

@main enum StreamingServerConnectionPolicyTests {
    static func main() {
        typealias P = StreamingServerConnectionPolicy
        precondition(P.normalizedBase("  192.168.1.50:11470///\n") == "http://192.168.1.50:11470")
        precondition(P.normalizedBase("https://server.example/stremio/") == "https://server.example/stremio")
        precondition(P.normalizedBase("http://[::1]:11470/") != nil)
        for raw in ["", " ", "http://", "ftp://server.example", "https://server.example/#fragment", "http://server.example/?key=value"] {
            precondition(P.normalizedBase(raw) == nil, "invalid base: \(raw)")
        }
        precondition(P.accepts(statusCode: 200, body: Data(#"{"values":{},"options":{},"baseUrl":"http://fixture"}"#.utf8)))
        for body in ["<html>Welcome</html>", #"{"online":true}"#, #"{"values":null}"#, #"{"values":[]}"#] {
            precondition(!P.accepts(statusCode: 200, body: Data(body.utf8)))
        }
        precondition(!P.accepts(statusCode: 503, body: Data(#"{"values":{}}"#.utf8)))
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let server = try! String(contentsOf: app.appendingPathComponent("SourcesShared/StremioServer.swift"), encoding: .utf8)
        let view = try! String(contentsOf: app.appendingPathComponent("SourcesShared/ServerConfigView.swift"), encoding: .utf8)
        precondition(server.contains("return await respondsAsServer(\"\\(b)/settings\")"))
        precondition(server.contains("req.timeoutInterval = StreamingServerConnectionPolicy.timeoutSeconds"))
        precondition(view.contains("probe(saveIfReachable: true)") && view.contains("probe(saveIfReachable: false)"))
        precondition(view.contains("guard trimmed == entered else { return }"))
        precondition(view.contains("guard probeGeneration == generation else { return }"))
        precondition(view.contains(".onDisappear { probeGeneration &+= 1 }"))
        precondition(!view.contains("trimmed.isEmpty ? StremioServer.base : trimmed"), "blank remote test must not validate embedded server")
        print("PASS streaming server: shared Test/Save/status contract, consistent timeout, URL validation and stale-input guard")
    }
}
