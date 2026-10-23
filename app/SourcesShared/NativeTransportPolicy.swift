import Foundation

/// Transport rules for the VortX streaming server. An unavailable server fails closed.
enum NativeTransportPolicy {
    /// App launches must verify upstream TLS even when the parent shell carries a daemon-only
    /// development override. Preserve the rest of the environment and the server's normal policy.
    static func nativeServerEnvironment(from inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["VORTX_PROXY_INSECURE_TLS"] = "0"
        return environment
    }

    /// A running process alone does not prove it owns its listening port. The caller supplies
    /// only this launch's unique port-file receipt, emitted by the native daemon after bind.
    static func boundNativePort(processRunning: Bool, receipt: String?) -> Int? {
        guard processRunning, let receipt,
              let port = Int(receipt.trimmingCharacters(in: .whitespacesAndNewlines)), port == 11470 else { return nil }
        return port
    }

    /// Only a literal loopback origin can receive provider credentials. No DNS aliases, URL
    /// credentials, custom paths or redirects are accepted by the credential-control client.
    static func localControlBase(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw), parts.scheme == "http",
              let host = parts.host, ["127.0.0.1", "[::1]", "::1"].contains(host),
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        return parts.url
    }
}
