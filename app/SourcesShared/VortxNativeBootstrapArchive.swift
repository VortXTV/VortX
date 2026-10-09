import Foundation
import CoreFoundation

/// Account-attributed recovery material, sealed beside (never inserted into) the kernel snapshot.
/// This is deliberately NOT a byte-identical raw cloud backup: explicit credential carriers are
/// excluded, while typed migration clocks and every inspectable noncredential host field survive.
enum VortxNativeBootstrapArchive {
    enum Failure: Error { case malformed, ambiguousCredentialCarrier, opaquePreference }
    private static let credentials: Set<String> = [
        "auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey",
        "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials", "nativeprovidercredentials"
    ]
    /// Fresh authenticated capture only. Do not use this to rewrite an archived source. The caller
    /// supplies the strict-decoded object so binary64 provenance is not reparsed by Foundation.
    static func credentialFreeDocument(_ source: [String: Any]) throws -> Data {
        var exclusions: [String] = []
        let value = try sanitize(source, path: "", exclusions: &exclusions)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
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
        let typedDigest = ["/valueHash", "/fingerprint", "/sourceDocumentSha256", "/metadataResponseSha256", "/profileOverlaySha256", "/typedCarrierFingerprint"].contains(where: path.hasSuffix)
            || path.range(of: #"/nativeSync/legacyImport/acceptedFingerprints/[0-9]+$"#, options: .regularExpression) != nil
            || path.range(of: #"/nativeSync/legacyImport/ownAccountSourceHistory/[0-9A-F-]{36}/[0-9a-f]{64}$"#, options: .regularExpression) != nil
        if let text = value as? String, typedDigest,
           text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { return text }
        if var object = value as? [String: Any] {
            let websiteEventID = typedWebsiteEventID(object)
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
                if key == "eventId", let websiteEventID {
                    // A validated protocol identifier is hexadecimal, not opaque base64. Other
                    // values, even alongside this identifier, still traverse the complete policy.
                    result[key] = websiteEventID
                } else if key == "settings", let encoded = object[key] as? String {
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
    private static func typedWebsiteEventID(_ object: [String: Any]) -> String? {
        guard let id = object["eventId"] as? String, id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              let rawCounter = object["counter"] as? String, let counter = UInt64(rawCounter), counter < UInt64.max,
              String(counter) == rawCounter else { return nil }
        func number(_ key: String, integer: Bool = true) -> Double? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let n = value.doubleValue
            return n.isFinite && n >= 0 && n <= 9_007_199_254_740_990 && (!integer || n.rounded(.towardZero) == n) ? n : nil
        }
        let keys = Set(object.keys)
        if number("version") == 3, keys == ["version", "counter", "eventId", "state", "wallTime", "legacyRemovedSeen", "legacyAddedSeen"],
           ["present", "removed"].contains(object["state"] as? String ?? ""),
           ["wallTime", "legacyRemovedSeen", "legacyAddedSeen"].allSatisfy({ number($0, integer: false) != nil }) { return id }
        guard number("schemaVersion") == 1 else { return nil }
        let digest = (object["fingerprint"] as? String)?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        if keys == ["schemaVersion", "counter", "eventId", "fingerprint", "observedClock"], digest, number("observedClock") != nil { return id }
        guard ["scope", "ownerProfileId", "profileId"].allSatisfy({ (object[$0] as? String)?.isEmpty == false }),
              let binding = object["expectedBinding"] as? [String: Any], Set(binding.keys) == ["account", "revision", "transactionId"],
              binding["account"] is [String: Any], binding["revision"] is NSNumber,
              binding["transactionId"] is String || binding["transactionId"] is NSNull else { return nil }
        if keys == ["schemaVersion", "counter", "eventId", "fingerprint", "scope", "ownerProfileId", "profileId", "expectedBinding"], digest { return id }
        let required: Set<String> = ["schemaVersion", "counter", "eventId", "wallTime", "scope", "ownerProfileId", "profileId", "expectedBinding", "observed", "mutations"]
        if required.isSubset(of: keys), keys.isSubset(of: required.union(["order"])), number("wallTime") != nil,
           object["observed"] is [String: Any], object["mutations"] is [[String: Any]],
           object["order"] == nil || object["order"] is [String] { return id }
        return nil
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

/// Unresolved historical membership evidence is not an install/remove command. Keep it sealed
/// with the accepted account checkpoint rather than blocking unrelated profiles, guessing a title
/// type, resurrecting an add-on, or acknowledging evidence that has not been imported by the kernel.
enum VortxLegacyMembershipReceiptArchive {
    enum Failure: Error { case malformed, wrongScope, excessive, credentialCarrier }
    static let key = "nativeLegacyMembershipPending"
    private static let maximumEntries = 10_000
    private static let maximumBytes = 32 * 1_024 * 1_024
    private static let kinds: Set<String> = ["addon_install", "library_removal", "profile_saved_overlay", "watch_identity_conflict"]

    static func appending(_ receipts: Data?, to archive: Data, scope: String, ownerProfileID: String,
                          sourceDocumentSHA256: String) throws -> Data {
        guard let receipts else { return archive }
        guard let rows = try JSONSerialization.jsonObject(with: receipts) as? [[String: Any]],
              rows.allSatisfy({ $0["sourceDocumentSha256"] as? String == sourceDocumentSHA256 }) else {
            throw Failure.malformed
        }
        try VortxNativeBootstrapArchive.validate(archive)
        guard let envelope = try JSONSerialization.jsonObject(with: archive) as? [String: Any],
              var host = envelope["hostDocument"] as? [String: Any] else { throw Failure.malformed }
        let incoming: [String: Any] = ["schemaVersion": 1, "scope": scope,
                                       "ownerProfileId": ownerProfileID, "receipts": rows]
        let existing = try host[key].map { try canonical($0) }
        let merged = try merging(existing, with: canonical(incoming), scope: scope, ownerProfileID: ownerProfileID)
        if let merged { host[key] = try JSONSerialization.jsonObject(with: merged) }
        return try VortxNativeBootstrapArchive.encode(document: canonical(host))
    }

    static func merging(_ prior: Data?, with incoming: Data?, scope: String,
                        ownerProfileID: String) throws -> Data? {
        guard prior != nil || incoming != nil else { return nil }
        guard !scope.isEmpty, UUID(uuidString: ownerProfileID)?.uuidString == ownerProfileID else { throw Failure.wrongScope }
        var distinct: [Data: [String: Any]] = [:]
        // A playback update from an old client changes the full document hash, not an unchanged
        // orphan receipt. Retain its first authenticated capture instead of copying it on every pull.
        for encoded in [prior, incoming].compactMap({ $0 }) {
            guard encoded.count <= maximumBytes,
                  let value = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  Set(value.keys) == ["schemaVersion", "scope", "ownerProfileId", "receipts"],
                  let schema = value["schemaVersion"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.intValue == 1, schema.doubleValue == 1,
                  let rows = value["receipts"] as? [[String: Any]], rows.count <= maximumEntries else { throw Failure.malformed }
            guard value["scope"] as? String == scope, value["ownerProfileId"] as? String == ownerProfileID else { throw Failure.wrongScope }
            for row in rows {
                try validate(row)
                var identity = row
                identity.removeValue(forKey: "sourceDocumentSha256")
                let fingerprint = try canonical(identity)
                if distinct[fingerprint] == nil { distinct[fingerprint] = row }
                guard distinct.count <= maximumEntries else { throw Failure.excessive }
            }
        }
        let rows = distinct.keys.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { distinct[$0] }
        let merged = try canonical(["schemaVersion": 1, "scope": scope,
                                    "ownerProfileId": ownerProfileID, "receipts": rows])
        guard merged.count <= maximumBytes else { throw Failure.excessive }
        return merged
    }

    private static func validate(_ row: [String: Any]) throws {
        guard Set(row.keys) == ["profileId", "kind", "identity", "sourceField", "receipt", "sourceDocumentSha256"],
              let profile = row["profileId"] as? String, UUID(uuidString: profile)?.uuidString == profile,
              let kind = row["kind"] as? String, kinds.contains(kind),
              let identity = row["identity"] as? String, !identity.isEmpty, identity.utf8.count <= 8192,
              let field = row["sourceField"] as? String, !field.isEmpty, field.utf8.count <= 4096,
              let digest = row["sourceDocumentSha256"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let receipt = row["receipt"] as? [String: Any] else { throw Failure.malformed }
        switch kind {
        case "addon_install":
            guard field == "/vortx/deletedAddonsTs",
                  Set(receipt.keys) == ["deletedAddonsTs", "deletedAddons", "webAddonRemovals"],
                  let clocks = receipt["deletedAddonsTs"] as? [String: Any], !clocks.isEmpty,
                  let removed = receipt["deletedAddons"] as? [String],
                  let webRemoved = receipt["webAddonRemovals"] as? [String] else { throw Failure.malformed }
            for (url, value) in clocks {
                guard try normalizedURL(url) == identity, let values = value as? [String: Any] else { throw Failure.malformed }
                try validateClocks(values, allowV3: true)
            }
            for url in removed + webRemoved { guard try normalizedURL(url) == identity else { throw Failure.malformed } }
        case "library_removal":
            guard ["/vortx/deletedLibraryTs", "/vortx/deletedLibrary"].contains(field),
                  Set(receipt.keys).isSubset(of: ["deletedLibraryTs", "deletedLibrary"]),
                  let removed = receipt["deletedLibrary"] as? [String], removed.allSatisfy({ $0 == identity }) else { throw Failure.malformed }
            if let raw = receipt["deletedLibraryTs"] {
                guard let clocks = raw as? [String: Any], Set(clocks.keys) == [identity],
                      let values = clocks[identity] as? [String: Any] else { throw Failure.malformed }
                try validateClocks(values, allowV3: false)
            } else if field == "/vortx/deletedLibraryTs" || removed.isEmpty { throw Failure.malformed }
        case "profile_saved_overlay":
            let parts = field.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 6, parts[0].isEmpty, parts[1] == "vortx", parts[2] == "byProfile",
                  UUID(uuidString: String(parts[3]))?.uuidString == profile, parts[4] == "library",
                  nonnegativeIndex(String(parts[5])), receipt["id"] as? String == identity,
                  ["movie", "series"].contains(receipt["type"] as? String ?? "") else { throw Failure.malformed }
            for key in ["t", "d"] where receipt[key] != nil && !(receipt[key] is NSNull) {
                let seconds = try number(receipt[key]!)
                guard seconds * 1_000 <= 9_007_199_254_740_990 else { throw Failure.malformed }
            }
            if let epoch = receipt["eventEpochMs"], !(epoch is NSNull) { _ = try number(epoch) }
            for key in ["name", "poster", "v", "lastWatched"] where receipt[key] != nil && !(receipt[key] is NSNull) {
                guard receipt[key] is String else { throw Failure.malformed }
            }
            if let watched = receipt["lastWatched"] as? String, !watched.isEmpty { try validateLastWatched(watched) }
        case "watch_identity_conflict":
            guard field == "/vortx/byProfile/\(profile)/watch_identity_conflicts",
                  Set(receipt.keys) == ["sources"], let sources = receipt["sources"] as? [[String: Any]],
                  sources.count >= 2 else { throw Failure.malformed }
            var seen = Set<String>()
            for source in sources {
                guard Set(source.keys) == ["sourceField", "receipt"],
                      let path = source["sourceField"] as? String, path.hasPrefix("/"),
                      !path.contains("<captured-profile>"), path.utf8.count <= 4096,
                      source["receipt"] is [String: Any], seen.insert(path).inserted else { throw Failure.malformed }
                // A raw library overlay belongs to this profile. Owner history may legitimately
                // live in a different captured profile bucket, and its exact path is preserved.
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                if parts.count >= 5, parts[1] == "vortx", parts[2] == "byProfile", parts[4] == "library" {
                    guard UUID(uuidString: String(parts[3]))?.uuidString == profile else { throw Failure.malformed }
                }
            }
        default: throw Failure.malformed
        }
        let original = try canonical(row)
        let safe = try VortxNativeBootstrapArchive.credentialFreeDocument(row)
        guard original == safe else { throw Failure.credentialCarrier }
    }

    private static func nonnegativeIndex(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) && UInt64(value) != nil
    }

    private static func number(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_990 else { throw Failure.malformed }
        return number.doubleValue
    }

    private static func validateClocks(_ values: [String: Any], allowV3: Bool) throws {
        let allowed: Set<String> = allowV3 ? ["addedAt", "removedAt", "intentV3"] : ["addedAt", "removedAt"]
        guard Set(values.keys).isSubset(of: allowed) else { throw Failure.malformed }
        for key in ["addedAt", "removedAt"] where values[key] != nil && !(values[key] is NSNull) { _ = try number(values[key]!) }
        if let raw = values["intentV3"] {
            guard let v3 = raw as? [String: Any],
                  Set(v3.keys) == ["version", "counter", "eventId", "state", "wallTime", "legacyRemovedSeen", "legacyAddedSeen"],
                  try number(v3["version"]!) == 3, let counter = v3["counter"] as? String,
                  let parsed = UInt64(counter), parsed < UInt64.max, String(parsed) == counter,
                  let event = v3["eventId"] as? String, event.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
                  ["present", "removed"].contains(v3["state"] as? String ?? "") else { throw Failure.malformed }
            for key in ["wallTime", "legacyRemovedSeen", "legacyAddedSeen"] { _ = try number(v3[key]!) }
        }
    }

    private static func normalizedURL(_ raw: String) throws -> String {
        guard var url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { throw Failure.malformed }
        url.scheme = scheme; url.host = host.lowercased()
        guard let normalized = url.string else { throw Failure.malformed }
        return normalized
    }

    private static func validateLastWatched(_ raw: String) throws {
        let regex = try NSRegularExpression(pattern: #"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]+))?(Z|[+-][0-9]{2}:[0-9]{2})$"#)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.range == range,
              let seconds = Range(match.range(at: 1), in: raw), let zone = Range(match.range(at: 3), in: raw),
              let date = ISO8601DateFormatter().date(from: String(raw[seconds]) + String(raw[zone])) else { throw Failure.malformed }
        let fraction = Range(match.range(at: 2), in: raw).flatMap { Double("0." + raw[$0]) } ?? 0
        _ = try number(NSNumber(value: date.timeIntervalSince1970 * 1_000 + fraction * 1_000))
    }

    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
