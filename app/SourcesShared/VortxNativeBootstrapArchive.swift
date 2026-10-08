import Foundation

/// Account-attributed recovery material, sealed beside (never inserted into) the kernel snapshot.
/// This is deliberately NOT a byte-identical raw cloud backup: explicit credential carriers are
/// excluded, while typed migration clocks and every inspectable noncredential host field survive.
enum VortxNativeBootstrapArchive {
    enum Failure: Error { case malformed, ambiguousCredentialCarrier, opaquePreference }
    private static let credentials: Set<String> = [
        "auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey",
        "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials", "nativeprovidercredentials"
    ]
    static func encode(document: Data, material: Data? = nil, authenticatedSourceArchive: Data? = nil) throws -> Data {
        guard let source = try JSONSerialization.jsonObject(with: document) as? [String: Any] else { throw Failure.malformed }
        var exclusions: [String] = []
        let sanitized = try sanitize(source, path: "", exclusions: &exclusions)
        var archive: [String: Any] = ["schemaVersion": 1, "hostDocument": sanitized,
                                      "excludedCredentialPaths": exclusions.sorted()]
        if let material {
            guard let typed = try JSONSerialization.jsonObject(with: material) as? [String: Any],
                  [1, 2].contains(typed["schemaVersion"] as? Int ?? 0) else { throw Failure.malformed }
            var forbidden: [String] = []
            _ = try sanitize(typed, path: "/legacyImportMaterial", exclusions: &forbidden)
            guard forbidden.isEmpty else { throw Failure.ambiguousCredentialCarrier }
            archive["legacyImportMaterial"] = typed // never rewrite typed input/receipt source clocks
        }
        if let authenticatedSourceArchive {
            try validate(authenticatedSourceArchive)
            guard let source = try JSONSerialization.jsonObject(with: authenticatedSourceArchive) as? [String: Any],
                  let host = source["hostDocument"] as? [String: Any] else { throw Failure.malformed }
            archive["authenticatedSourceArchive"] = host
        }
        return try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func validate(_ archive: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: archive) as? [String: Any],
              object["schemaVersion"] as? Int == 1, let host = object["hostDocument"] as? [String: Any],
              let excluded = object["excludedCredentialPaths"] as? [String],
              excluded.allSatisfy({ $0.hasPrefix("/") }),
              Set(object.keys).isSubset(of: ["schemaVersion", "hostDocument", "excludedCredentialPaths", "legacyImportMaterial", "authenticatedSourceArchive"])
        else { throw Failure.malformed }
        var forbidden: [String] = []
        _ = try sanitize(host, path: "", exclusions: &forbidden)
        if let material = object["legacyImportMaterial"] {
            guard material is [String: Any] else { throw Failure.malformed }
            _ = try sanitize(material, path: "/legacyImportMaterial", exclusions: &forbidden)
        }
        if let source = object["authenticatedSourceArchive"] {
            _ = try sanitize(source, path: "/authenticatedSourceArchive", exclusions: &forbidden)
        }
        guard forbidden.isEmpty else { throw Failure.ambiguousCredentialCarrier }
    }
    private static func pointer(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
    private static func sanitize(_ value: Any, path: String, exclusions: inout [String], depth: Int = 0) throws -> Any {
        guard depth <= 64 else { throw Failure.opaquePreference }
        // Typed SHA-256 evidence is hexadecimal, not a base64 JSON carrier. Some valid hashes
        // (for example e9...) decode to a leading brace plus arbitrary bytes under base64 probing.
        if let text = value as? String, ["/valueHash", "/fingerprint"].contains(where: path.hasSuffix),
           text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { return text }
        if var object = value as? [String: Any] {
            // Backups may be nested under future preference keys, not just `settings`. Recognize
            // their envelope by content and inspect the plist before traversing envelope metadata.
            if object["format"] as? String == "vortx-backup" {
                guard object["schema"] as? Int == 1,
                      let payload = object["payloadBase64"] as? String, let bytes = Data(base64Encoded: payload),
                      let domain = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any]
                else { throw Failure.opaquePreference }
                let safe = try sanitize(domain, path: path + "/payloadBase64", exclusions: &exclusions, depth: depth + 1)
                guard let safe = safe as? [String: Any] else { throw Failure.malformed }
                object["payloadBase64"] = try PropertyListSerialization.data(fromPropertyList: safe, format: .binary, options: 0).base64EncodedString()
                object["keyCount"] = safe.count
            }
            var result: [String: Any] = [:]
            for key in object.keys.sorted() {
                let child = path + "/" + pointer(key)
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                let url = URLComponents(string: key)
                let configuredIdentity = ["http", "https"].contains(url?.scheme?.lowercased() ?? "") && url?.host?.isEmpty == false
                if !configuredIdentity && (credentials.contains(normalized) || key.lowercased().hasPrefix("kcfallback.")) {
                    exclusions.append(child); continue
                }
                // Unknown credential-like carriers require an explicit policy, not silent deletion
                // or blind persistence. Do not classify ordinary keys or URL string contents.
                if !configuredIdentity && (normalized.contains("secret") || normalized.contains("credential") ||
                    ["token", "password", "authkey", "apikey"].contains(where: { normalized.hasSuffix($0) })) {
                    throw Failure.ambiguousCredentialCarrier
                }
                if key == "settings", let encoded = object[key] as? String {
                    result[key] = try settings(encoded, path: child, exclusions: &exclusions, depth: depth + 1)
                } else { result[key] = try sanitize(object[key]!, path: child, exclusions: &exclusions, depth: depth + 1) }
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.enumerated().map { try sanitize($0.element, path: path + "/" + String($0.offset), exclusions: &exclusions, depth: depth + 1) }
        }
        if let data = value as? Data {
            // Preference Data is frequently JSON (full roster/playback fields) or a plist. Inspect
            // both, preserving its Data type. Unknown binary payloads require reconciliation.
            if let object = try? JSONSerialization.jsonObject(with: data) {
                let safe = try sanitize(object, path: path, exclusions: &exclusions, depth: depth + 1)
                return try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes])
            }
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) {
                return try PropertyListSerialization.data(fromPropertyList: sanitize(object, path: path, exclusions: &exclusions, depth: depth + 1), format: format, options: 0)
            }
            throw Failure.opaquePreference
        }
        if let text = value as? String, let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
           nested is [String: Any] || nested is [Any] || nested is String {
            let prior = exclusions.count
            let safe = try sanitize(nested, path: path, exclusions: &exclusions, depth: depth + 1)
            // Keep the original noncredential string byte-for-byte unless actual exclusions were
            // necessary. A structured string must not hide credentials from the recursive policy.
            if exclusions.count == prior { return text }
            return String(decoding: try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
        }
        if let text = value as? String, let bytes = Data(base64Encoded: text) {
            // Inspect recognizable base64 JSON/plist containers wherever they occur. Ordinary
            // strings (including configured URLs) remain exact, and encoding stays base64.
            let prior = exclusions.count
            if let nested = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
               nested is [String: Any] || nested is [Any] || nested is String {
                let safe = try sanitize(nested, path: path, exclusions: &exclusions, depth: depth + 1)
                if exclusions.count == prior { return text }
                return try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]).base64EncodedString()
            }
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let nested = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) {
                let safe = try sanitize(nested, path: path, exclusions: &exclusions, depth: depth + 1)
                if exclusions.count == prior { return text }
                return try PropertyListSerialization.data(fromPropertyList: safe, format: format, options: 0).base64EncodedString()
            }
            if structuredPrefix(bytes) { throw Failure.opaquePreference }
        }
        if let text = value as? String, structuredPrefix(Data(text.utf8)) { throw Failure.opaquePreference }
        guard value is String || value is NSNumber || value is NSNull || value is Date else { throw Failure.malformed }
        return value
    }
    private static func structuredPrefix(_ bytes: Data) -> Bool {
        let prefix = String(decoding: bytes.prefix(32), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["{", "[", "bplist", "<?xml", "<!DOCTYPE", "<plist"].contains(where: prefix.hasPrefix)
    }
    private static func settings(_ encoded: String, path: String, exclusions: inout [String], depth: Int) throws -> String {
        guard let bytes = Data(base64Encoded: encoded),
              let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              envelope["format"] as? String == "vortx-backup"
        else { throw Failure.opaquePreference }
        let safeEnvelope = try sanitize(envelope, path: path, exclusions: &exclusions, depth: depth + 1)
        return try JSONSerialization.data(withJSONObject: safeEnvelope, options: [.sortedKeys, .withoutEscapingSlashes]).base64EncodedString()
    }
}
