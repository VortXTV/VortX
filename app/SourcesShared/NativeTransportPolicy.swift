import Foundation

/// Selecting the native data engine also selects native transport. An unavailable native build
/// must fail closed; a preference can never downgrade it to the legacy runtime.
enum NativeTransportPolicy {
    static var isRequired: Bool {
        #if VORTX_NATIVE_DATA_ENGINE
        return true
        #else
        return false
        #endif
    }

    static func selectsNative(required: Bool, preference: Bool) -> Bool { required || preference }

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
