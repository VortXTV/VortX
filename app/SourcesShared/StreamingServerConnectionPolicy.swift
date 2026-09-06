import Foundation

/// Test, Save & Use, and active-server status must recognize the same endpoint and server contract.
enum StreamingServerConnectionPolicy {
    static let timeoutSeconds: TimeInterval = 6

    static func normalizedBase(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.url != nil else { return nil }
        return value
    }

    static func accepts(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["values"] is [String: Any] else { return false }
        return true
    }
}
