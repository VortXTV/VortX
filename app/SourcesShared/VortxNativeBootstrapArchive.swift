import Foundation
import CoreFoundation

/// Account-attributed recovery material, sealed beside (never inserted into) the kernel snapshot.
/// This is deliberately NOT a byte-identical raw cloud backup: explicit credential carriers are
/// excluded, while typed migration clocks and every inspectable noncredential host field survive.
enum VortxNativeBootstrapArchive {
    struct RecoveryConflict: LocalizedError {
        var errorDescription: String? {
            "Two saved recovery records disagree. Both original records are unchanged. Keep this account data and contact support before replacing either record."
        }
    }
    // These fields have their own scoped append/replace policies. All other host fields are
    // opaque recovery material: absence is not deletion, and a disagreement is not an ACK.
    static let managedRecoveryHostKeys: Set<String> = ["ownAccountSources", "ownAccountOverlayPending",
        "ownAccountOverlayQuarantine", "nativeLegacyMembershipPending", "nativeWatchedMigrationEvidence",
        "nativeWatchedMigrationPending", "nativeWatchedMigrationSources"]
    static func mergingRecoveryEnvelope(_ incoming: Data, prior: Data?) throws -> Data {
        try validate(incoming)
        guard let prior else { return incoming }
        try validate(prior)
        guard var result = try decodeJSON(with: incoming) as? [String: Any],
              let old = try decodeJSON(with: prior) as? [String: Any],
              var host = result["hostDocument"] as? [String: Any],
              let oldHost = old["hostDocument"] as? [String: Any] else { throw Failure.malformed }
        func equal(_ left: Any, _ right: Any) throws -> Bool {
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
            return try JSONSerialization.data(withJSONObject: left, options: options)
                == JSONSerialization.data(withJSONObject: right, options: options)
        }
        for (key, value) in oldHost where !managedRecoveryHostKeys.contains(key) {
            if let fresh = host[key] { guard try equal(value, fresh) else { throw RecoveryConflict() } }
            else { host[key] = value }
        }
        for key in ["legacyImportMaterial", "authenticatedSourceArchive"] {
            guard let value = old[key] else { continue }
            if let fresh = result[key] { guard try equal(value, fresh) else { throw RecoveryConflict() } }
            else { result[key] = value }
        }
        let exclusions = (old["excludedCredentialPaths"] as! [String]) + (result["excludedCredentialPaths"] as! [String])
        let exactPaths = Dictionary(exclusions.map { (Data($0.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        result["excludedCredentialPaths"] = exactPaths.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { exactPaths[$0]! }
        result["hostDocument"] = host
        let merged = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        try validate(merged)
        return merged
    }
    enum Failure: Error { case malformed, ambiguousCredentialCarrier, opaquePreference }
    private static let credentials: Set<String> = [
        "auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey",
        "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials", "nativeprovidercredentials"
    ]
    /// Fresh authenticated capture only. Do not use this to rewrite an archived source. The caller
    /// supplies the strict-decoded object so binary64 provenance is not reparsed by Foundation.
    static func credentialFreeDocument(_ source: [String: Any], diagnostics: ((String) -> Void)? = nil) throws -> Data {
        var exclusions: [String] = []
        let value = try sanitize(source, path: "", exclusions: &exclusions, diagnostics: diagnostics, textContext: .legacyHost)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func encode(document: Data, material: Data? = nil, authenticatedSourceArchive: Data? = nil) throws -> Data {
        guard let source = try decodeJSON(with: document) as? [String: Any] else { throw Failure.malformed }
        try requireUnambiguousJSON(document)
        var exclusions: [String] = []
        let sanitized = try sanitize(source, path: "", exclusions: &exclusions, textContext: .legacyHost)
        var archive: [String: Any] = ["schemaVersion": 1, "hostDocument": sanitized,
                                      "excludedCredentialPaths": exclusions.sorted()]
        if let material {
            guard let typed = try decodeJSON(with: material) as? [String: Any],
                  [1, 2].contains(typed["schemaVersion"] as? Int ?? 0) else { throw Failure.malformed }
            try requireUnambiguousJSON(material)
            var forbidden: [String] = []
            _ = try sanitize(typed, path: "/legacyImportMaterial", exclusions: &forbidden)
            guard forbidden.isEmpty else { throw Failure.ambiguousCredentialCarrier }
            archive["legacyImportMaterial"] = typed // never rewrite typed input/receipt source clocks
        }
        if let authenticatedSourceArchive {
            try validate(authenticatedSourceArchive)
            guard let source = try decodeJSON(with: authenticatedSourceArchive) as? [String: Any],
                  let host = source["hostDocument"] as? [String: Any] else { throw Failure.malformed }
            // This field is historically a host document, not a recursively nested envelope.
            // Preserve compatible outer witnesses, or fail before returning a lossy flattened
            // replacement. Never create recursively growing recovery history.
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
            if let retainedMaterial = source["legacyImportMaterial"] {
                if let freshMaterial = archive["legacyImportMaterial"] {
                    guard try JSONSerialization.data(withJSONObject: retainedMaterial, options: options)
                        == JSONSerialization.data(withJSONObject: freshMaterial, options: options) else { throw RecoveryConflict() }
                } else { archive["legacyImportMaterial"] = retainedMaterial }
            }
            if let retainedSource = source["authenticatedSourceArchive"] {
                guard try JSONSerialization.data(withJSONObject: retainedSource, options: options)
                    == JSONSerialization.data(withJSONObject: host, options: options) else { throw RecoveryConflict() }
            }
            let paths = exclusions + (source["excludedCredentialPaths"] as! [String])
            let uniquePaths = Dictionary(paths.map { (Data($0.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            archive["excludedCredentialPaths"] = uniquePaths.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { uniquePaths[$0]! }
            archive["authenticatedSourceArchive"] = host
        }
        return try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    /// Updating a device-local journal must not discard the rest of its recovery envelope or
    /// sanitize new credentials into apparently valid evidence. Both old and updated envelopes
    /// pass the complete inspector; the other envelope fields retain their original values.
    static func replacingHostDocument(in archive: Data, with document: Data) throws -> Data {
        try validate(archive)
        guard var envelope = try decodeJSON(with: archive) as? [String: Any],
              let host = try decodeJSON(with: document) as? [String: Any] else { throw Failure.malformed }
        try requireUnambiguousJSON(document)
        envelope["hostDocument"] = host
        let result = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        try validate(result)
        return result
    }
    static func validate(_ archive: Data) throws {
        guard let object = try decodeJSON(with: archive) as? [String: Any],
              object["schemaVersion"] as? Int == 1, let host = object["hostDocument"] as? [String: Any],
              let excluded = object["excludedCredentialPaths"] as? [String],
              excluded.allSatisfy({ $0.hasPrefix("/") }),
              Set(object.keys).isSubset(of: ["schemaVersion", "hostDocument", "excludedCredentialPaths", "legacyImportMaterial", "authenticatedSourceArchive"])
        else { throw Failure.malformed }
        var forbidden: [String] = []
        try requireUnambiguousJSON(archive)
        _ = try sanitize(host, path: "", exclusions: &forbidden, textContext: .legacyHost)
        if let material = object["legacyImportMaterial"] {
            guard material is [String: Any] else { throw Failure.malformed }
            _ = try sanitize(material, path: "/legacyImportMaterial", exclusions: &forbidden)
        }
        if let source = object["authenticatedSourceArchive"] {
            _ = try sanitize(source, path: "/authenticatedSourceArchive", exclusions: &forbidden, textContext: .legacyHost)
        }
        guard forbidden.isEmpty else { throw Failure.ambiguousCredentialCarrier }
    }
    private static func pointer(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
    // Only fixed schema words may reach diagnostics. Profile IDs, URL keys, preference names,
    // fingerprints and source values are never logged, including in a rejected document.
    private static let diagnosticFields: Set<String> = [
        "settings", "payloadBase64", "nativeSync", "legacyImport", "accountSlots", "slots",
        "sourceHistory", "ownAccountSourceHistory", "acceptedFingerprints", "roster", "profiles",
        "library", "watches", "valueHash", "fingerprint", "vortx", "addons", "manifest", "name", "description",
        "byProfile", "records", "value", "items", "sourceBaseline", "baseline", "ownAccountSources",
        "sourceDocumentBase64", "addonsResponseBase64", "result", "webAddonEdits", "events", "mutations", "addon", "observed"
    ]
    private enum InspectionCarrier: String {
        case depthLimit = "depth_limit", backupEnvelope = "backup_envelope", settingsEnvelope = "settings_envelope"
        case opaqueData = "opaque_data", base64Prefix = "base64_prefix", plainTextPrefix = "plain_text_prefix"
    }
    private enum InspectionPreferenceFamily: String {
        case profileRoster = "profile_roster", profileWatch = "profile_watch", sourcePin = "source_pin"
        case seriesSourceChoice = "series_source_choice", ownerHistory = "owner_history", forYouLocal = "for_you_local"
    }
    private static func diagnosticPreferenceFamily(_ path: String) -> InspectionPreferenceFamily? {
        // Classification only, never inspection authority. Return closed labels, not the raw
        // preference name, profile/account suffix, dictionary key, value, or encoded bytes.
        guard let marker = path.range(of: "/settings/payloadBase64/"),
              let key = path[marker.upperBound...].split(separator: "/").first else { return nil }
        if key == "stremiox.profiles" { return .profileRoster }
        if key.hasPrefix("stremiox.profiles.watch.") { return .profileWatch }
        if key.hasPrefix("stremiox.sourcePins.") { return .sourcePin }
        if key.hasPrefix("stremiox.seriesSourceSticky.") { return .seriesSourceChoice }
        if key.hasPrefix("vortx.owner.history.v1.") { return .ownerHistory }
        if key == "vortx.forYou.local" { return .forYouLocal }
        return nil
    }
    private static func rejected(_ failure: Failure, path: String, diagnostics: ((String) -> Void)?,
                                 carrier: InspectionCarrier? = nil) -> Failure {
        if let diagnostics {
            let reason: String
            switch failure {
            case .malformed: reason = "malformed"
            case .ambiguousCredentialCarrier: reason = "ambiguous_credential_carrier"
            case .opaquePreference: reason = "opaque_preference"
            }
            let field = "/" + path.split(separator: "/").prefix(12).map {
                diagnosticFields.contains(String($0)) ? String($0) : "*"
            }.joined(separator: "/")
            let detail = carrier.map { " carrier=" + $0.rawValue } ?? ""
            let family = diagnosticPreferenceFamily(path).map { " preference_family=" + $0.rawValue } ?? ""
            diagnostics("archive_inspection result=failed reason=\(reason) field=\(field)\(detail)\(family)")
        }
        return failure
    }
    private enum TextContext {
        case ordinary, addonManifest, addonDisplayText
        case settingsDomain, profileRosterData, profileRoster, profileRosterItem, profileName, profileAvatar
        case seriesChoiceData, seriesChoices, seriesChoice, seriesAddonName
        case legacyHost, legacyVortx, legacyLibraryRows, legacyLibraryRow, libraryName
    }
    private static func isSeriesChoicePreference(_ key: String) -> Bool {
        // SeriesSourceSticky.key writes only the active UUID, or the pre-roster default.
        // In particular, an undecodable quarantine copy is not an active Choice store.
        let prefix = "stremiox.seriesSourceSticky."
        guard key.hasPrefix(prefix) else { return false }
        let profile = String(key.dropFirst(prefix.count))
        return profile == "default" || UUID(uuidString: profile) != nil
    }
    private static func isSeriesSourceChoice(_ object: [String: Any]) -> Bool {
        // Match the JSONEncoder representation of SeriesSourceSticky.Choice without
        // decoding/re-encoding the DTO: future fields must survive and remain inspected.
        guard object["addon"] is String,
              let ts = object["ts"] as? NSNumber, CFGetTypeID(ts) != CFBooleanGetTypeID(),
              ts.doubleValue.isFinite else { return false }
        for key in ["bingeGroup", "audioLanguage"] {
            guard object[key] == nil || object[key] is NSNull || object[key] is String else { return false }
        }
        if let resolution = object["resolution"], !(resolution is NSNull) {
            guard let number = resolution as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  Int(exactly: number.doubleValue) != nil else { return false }
        }
        return true
    }
    private static func isProfileRosterItem(_ object: [String: Any]) -> Bool {
        // ProfileStore.persist writes JSON Data containing UUID/name/avatar roster records.
        // Unknown fields are still inspected; a field name alone never grants display semantics.
        guard let id = object["id"] as? String, UUID(uuidString: id) != nil,
              object["name"] is String, object["avatar"] is String else { return false }
        return true
    }
    private static func isLegacyLibraryRow(_ object: [String: Any]) -> Bool {
        // Match the legacy owner row's identity and display fields, without requiring a
        // supported type: the downstream projector must still be able to hold an odd row.
        // Unknown siblings retain full inspection and do not receive display semantics.
        guard let id = object["id"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.rangeOfCharacter(from: .controlCharacters) == nil,
              object["type"] is String, object["name"] is String else { return false }
        return true
    }
    private static func hasLiteralTaggedDisplayLabel(_ text: String) -> Bool {
        guard hasLiteralDisplayLabel(text) else { return false }
        // A title or add-on display name may have a literal tag. Do not let it conceal
        // a JSON/plist/quoted carrier in the remainder, including a base64-encoded one.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing: Character = trimmed.first == "[" ? "]" : "}"
        guard let end = trimmed.firstIndex(of: closing) else { return false }
        let carrierPadding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        func normalizedCarrierText(_ bytes: Data) -> String {
            let view = (try? jsonUTF8View(bytes)) ?? bytes
            return String(decoding: view, as: UTF8.self).trimmingCharacters(in: carrierPadding)
        }
        // Normalize the complete padding run before BOTH inspection and base64 decoding.
        // A BOM before encoded text must not make the decoder fail open after a safe sniff.
        let suffix = normalizedCarrierText(Data(trimmed[trimmed.index(after: end)...].utf8))
        func carrierPrefix(_ bytes: Data) -> Bool {
            let significant = normalizedCarrierText(bytes).unicodeScalars
            let prefix = String(String.UnicodeScalarView(significant.prefix(32)))
            return structuredPrefix(Data(prefix.utf8)) || prefix.hasPrefix("\"")
        }
        guard !carrierPrefix(Data(suffix.utf8)) else { return false }
        if let decoded = Data(base64Encoded: suffix), carrierPrefix(decoded) { return false }
        return true
    }
    private static func isAddonDescriptor(_ object: [String: Any]) -> Bool {
        guard let transport = object["transportUrl"] as? String, let url = URLComponents(string: transport),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              let manifest = object["manifest"] as? [String: Any] else { return false }
        return ["id", "name", "version"].allSatisfy { (manifest[$0] as? String)?.isEmpty == false }
    }
    private static func hasLiteralDisplayLabel(_ text: String) -> Bool {
        // A public manifest label such as [4K], [Community] or {Public} is not a broken JSON
        // document. Admit only a short balanced label with no key/value, quoting or nested syntax.
        // All real JSON/plist/base64 decoding happens first; this never exempts encoded bytes.
        let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        guard let first = scalars.first, first == "[" || first == "{" else { return false }
        let closing: Unicode.Scalar = first == "[" ? "]" : "}"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-+&"))
        var count = 0
        for index in scalars.indices.dropFirst() {
            let scalar = scalars[index]
            if scalar == closing {
                let next = scalars.index(after: index)
                guard count > 0, next == scalars.endIndex || CharacterSet.whitespacesAndNewlines.contains(scalars[next]) else { return false }
                // A valid JSON prefix followed by extra text is still a malformed container,
                // not a literal tag: `[true] {"token":...}` must retain the rejection fence.
                let prefix = String(scalars[...index])
                return (try? decodeJSON(with: Data(prefix.utf8), options: [.fragmentsAllowed])) == nil
            }
            guard count < 64, allowed.contains(scalar) else { return false }
            count += 1
        }
        return false
    }
    private static func sanitize(_ value: Any, path: String, exclusions: inout [String], depth: Int = 0,
                                 diagnostics: ((String) -> Void)? = nil, textContext: TextContext = .ordinary) throws -> Any {
        guard depth <= 64 else { throw rejected(.opaquePreference, path: path, diagnostics: diagnostics, carrier: .depthLimit) }
        // Typed SHA-256 evidence is hexadecimal, not a base64 JSON carrier. Some valid hashes
        // (for example e9...) decode to a leading brace plus arbitrary bytes under base64 probing.
        let typedDigest = ["/valueHash", "/fingerprint", "/sourceDocumentSha256", "/metadataResponseSha256", "/profileOverlaySha256", "/typedCarrierFingerprint"].contains(where: path.hasSuffix)
            || path.range(of: #"(?:^|/)ownAccountOverlayQuarantine/[0-9a-f]{64}/rootDocumentSha256$"#, options: .regularExpression) != nil
            || path.range(of: #"/nativeSync/legacyImport/acceptedFingerprints/[0-9]+$"#, options: .regularExpression) != nil
            || path.range(of: #"/nativeSync/legacyImport/ownAccountSourceHistory/[0-9A-F-]{36}/[0-9a-f]{64}$"#, options: .regularExpression) != nil
            || path.range(of: #"/nativeSync/accountSlots/[^/]+/slots/[^/]+/sourceHistory/[0-9a-f]{64}$"#, options: .regularExpression) != nil
        if let text = value as? String, typedDigest,
           text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { return text }
        if var object = value as? [String: Any] {
            let websiteEventID = typedWebsiteEventID(object)
            let addonDescriptor = isAddonDescriptor(object)
            var inspectedBackupPayload: String?
            // Backups may be nested under future preference keys, not just `settings`. Recognize
            // their envelope by content and inspect the plist before traversing envelope metadata.
            if object["format"] as? String == "vortx-backup" {
                guard object["schema"] as? Int == 1,
                      let payload = object["payloadBase64"] as? String, let bytes = Data(base64Encoded: payload),
                      let domain = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any]
                else { throw rejected(.opaquePreference, path: path, diagnostics: diagnostics, carrier: .backupEnvelope) }
                let safe = try sanitize(domain, path: path + "/payloadBase64", exclusions: &exclusions, depth: depth + 1,
                                        diagnostics: diagnostics, textContext: .settingsDomain)
                guard let safe = safe as? [String: Any] else { throw rejected(.malformed, path: path, diagnostics: diagnostics) }
                inspectedBackupPayload = try PropertyListSerialization.data(fromPropertyList: safe, format: .binary, options: 0).base64EncodedString()
                object["payloadBase64"] = inspectedBackupPayload
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
                    throw rejected(.ambiguousCredentialCarrier, path: child, diagnostics: diagnostics)
                }
                if key == "payloadBase64", let inspectedBackupPayload {
                    // This exact replacement has already passed complete inspection above. A
                    // second generic decode would discard the validated preference-domain role.
                    // No sibling or unrecognized envelope receives this treatment.
                    result[key] = inspectedBackupPayload
                } else if key == "eventId", let websiteEventID {
                    // A validated protocol identifier is hexadecimal, not opaque base64. Other
                    // values, even alongside this identifier, still traverse the complete policy.
                    result[key] = websiteEventID
                } else if key == "settings", let encoded = object[key] as? String {
                    result[key] = try settings(encoded, path: child, exclusions: &exclusions, depth: depth + 1, diagnostics: diagnostics)
                } else {
                    // Context is one-hop and content-typed, so the same descriptor remains valid in
                    // legacy material, native registers and retained independent-source archives.
                    // Never let a display-field exemption flow into another key or decoded carrier.
                    let context: TextContext
                    if textContext == .settingsDomain, key == "stremiox.profiles", object[key] is Data {
                        context = .profileRosterData
                    } else if textContext == .settingsDomain, isSeriesChoicePreference(key), object[key] is Data {
                        context = .seriesChoiceData
                    } else if textContext == .seriesChoices,
                              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              key.rangeOfCharacter(from: .controlCharacters) == nil,
                              let choice = object[key] as? [String: Any], isSeriesSourceChoice(choice) {
                        context = .seriesChoice
                    } else if textContext == .seriesChoice, key == "addon", object[key] is String {
                        context = .seriesAddonName
                    } else if textContext == .profileRosterItem, object[key] is String, key == "name" {
                        context = .profileName
                    } else if textContext == .legacyLibraryRow, object[key] is String, key == "name" {
                        context = .libraryName
                    } else if textContext == .legacyHost, key == "vortx", object[key] is [String: Any] {
                        context = .legacyVortx
                    } else if (textContext == .legacyHost || textContext == .legacyVortx),
                              key == "library", object[key] is [Any] {
                        context = .legacyLibraryRows
                    } else if textContext == .profileRosterItem, object[key] is String, key == "avatar" {
                        context = .profileAvatar
                    } else {
                        context = key == "manifest" && addonDescriptor ? .addonManifest
                            : textContext == .addonManifest && ["name", "description"].contains(key) && object[key] is String ? .addonDisplayText : .ordinary
                    }
                    result[key] = try sanitize(object[key]!, path: child, exclusions: &exclusions, depth: depth + 1,
                                               diagnostics: diagnostics, textContext: context)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.enumerated().map {
                let context: TextContext
                if textContext == .profileRoster && ($0.element as? [String: Any]).map(isProfileRosterItem) == true {
                    context = .profileRosterItem
                } else if textContext == .legacyLibraryRows && ($0.element as? [String: Any]).map(isLegacyLibraryRow) == true {
                    context = .legacyLibraryRow
                } else {
                    context = .ordinary
                }
                return try sanitize($0.element, path: path + "/" + String($0.offset), exclusions: &exclusions, depth: depth + 1,
                                    diagnostics: diagnostics, textContext: context)
            }
        }
        if let data = value as? Data {
            // Preference Data is frequently JSON (full roster/playback fields) or a plist. Inspect
            // both, preserving its Data type. Unknown binary payloads require reconciliation.
            if let object = try? decodeJSON(with: data) {
                try requireUnambiguousJSON(data)
                let context: TextContext
                if textContext == .profileRosterData && object is [Any] { context = .profileRoster }
                else if textContext == .seriesChoiceData && object is [String: Any] { context = .seriesChoices }
                else { context = .ordinary }
                let safe = try sanitize(object, path: path, exclusions: &exclusions, depth: depth + 1,
                                        diagnostics: diagnostics, textContext: context)
                // Always serialize only the inspected value. Foundation may collapse duplicate
                // JSON keys before inspection; returning raw Data could retain a hidden credential.
                return try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes])
            }
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) {
                return try PropertyListSerialization.data(fromPropertyList: sanitize(object, path: path, exclusions: &exclusions, depth: depth + 1, diagnostics: diagnostics), format: format, options: 0)
            }
            throw rejected(.opaquePreference, path: path, diagnostics: diagnostics, carrier: .opaqueData)
        }
        if let text = value as? String, let nested = try? decodeJSON(with: Data(text.utf8), options: [.fragmentsAllowed]),
           nested is [String: Any] || nested is [Any] || nested is String {
            try requireUnambiguousJSON(Data(text.utf8))
            let prior = exclusions.count
            let safe = try sanitize(nested, path: path, exclusions: &exclusions, depth: depth + 1, diagnostics: diagnostics)
            // Keep the original noncredential string byte-for-byte unless actual exclusions were
            // necessary. A structured string must not hide credentials from the recursive policy.
            if exclusions.count == prior { return text }
            return String(decoding: try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
        }
        if let text = value as? String, let bytes = Data(base64Encoded: text) {
            // Inspect recognizable base64 JSON/plist containers wherever they occur. Ordinary
            // strings (including configured URLs) remain exact, and encoding stays base64.
            let prior = exclusions.count
            if let nested = try? decodeJSON(with: bytes, options: [.fragmentsAllowed]),
               nested is [String: Any] || nested is [Any] || nested is String {
                try requireUnambiguousJSON(bytes)
                let safe = try sanitize(nested, path: path, exclusions: &exclusions, depth: depth + 1, diagnostics: diagnostics)
                if exclusions.count == prior { return text }
                return try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]).base64EncodedString()
            }
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let nested = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) {
                let safe = try sanitize(nested, path: path, exclusions: &exclusions, depth: depth + 1, diagnostics: diagnostics)
                if exclusions.count == prior { return text }
                return try PropertyListSerialization.data(fromPropertyList: safe, format: format, options: 0).base64EncodedString()
            }
            if structuredPrefix(bytes) { throw rejected(.opaquePreference, path: path, diagnostics: diagnostics, carrier: .base64Prefix) }
        }
        if let text = value as? String, structuredPrefix(Data(text.utf8)),
           !(textContext == .addonDisplayText && hasLiteralDisplayLabel(text)),
           !((textContext == .profileName || textContext == .profileAvatar) && (text == "[" || text == "{")),
           !(textContext == .profileName && hasLiteralDisplayLabel(text)),
           !((textContext == .libraryName || textContext == .seriesAddonName) && hasLiteralTaggedDisplayLabel(text)) {
            throw rejected(.opaquePreference, path: path, diagnostics: diagnostics, carrier: .plainTextPrefix)
        }
        guard value is String || value is NSNumber || value is NSNull || value is Date else { throw rejected(.malformed, path: path, diagnostics: diagnostics) }
        return value
    }
    /// One encoding view for Foundation and the member scanner. Retain original caller bytes;
    /// only UTF-16/32 require transcoding. BOM detection precedes zero-byte encoding detection.
    private static func jsonUTF8View(_ data: Data) throws -> Data {
        let raw = Array(data.prefix(4)) // Encoding sniff only: no whole-input byte-array copy.
        let encoding: String.Encoding
        let skip: Int
        if raw.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32BigEndian; skip = 4 }
        else if raw.starts(with: [0xff, 0xfe, 0, 0]) { encoding = .utf32LittleEndian; skip = 4 }
        else if raw.starts(with: [0xef, 0xbb, 0xbf]) { encoding = .utf8; skip = 3 }
        else if raw.starts(with: [0xfe, 0xff]) { encoding = .utf16BigEndian; skip = 2 }
        else if raw.starts(with: [0xff, 0xfe]) { encoding = .utf16LittleEndian; skip = 2 }
        else if raw.count >= 4, raw[0] == 0, raw[1] == 0, raw[2] == 0 { encoding = .utf32BigEndian; skip = 0 }
        else if raw.count >= 4, raw[1] == 0, raw[2] == 0, raw[3] == 0 { encoding = .utf32LittleEndian; skip = 0 }
        // JSON begins with ASCII syntax/whitespace; the next code unit may be non-ASCII.
        else if raw.count >= 2, raw[0] == 0 { encoding = .utf16BigEndian; skip = 0 }
        else if raw.count >= 2, raw[1] == 0 { encoding = .utf16LittleEndian; skip = 0 }
        else { encoding = .utf8; skip = 0 }
        let payload = skip == 0 ? data : Data(data.dropFirst(skip)) // Strip at most one BOM.
        if encoding == .utf8 { return payload }
        guard let text = String(data: payload, encoding: encoding) else { throw Failure.malformed }
        return Data(text.utf8)
    }
    private static func decodeJSON(with data: Data, options: JSONSerialization.ReadingOptions = []) throws -> Any {
        try JSONSerialization.jsonObject(with: jsonUTF8View(data), options: options)
    }
    /// Lexical admission companion to a complete value parse, not a value decoder.
    /// Callers must separately decode and validate the complete value.
    /// Foundation dictionaries can erase duplicate/escaped/canonically equivalent member names.
    /// Inspect the original member stream before admitting any raw carrier. Keep this throwing
    /// call outside JSON probes' try? so ambiguity cannot fall through to another carrier policy.
    /// No value tree, number conversion, credential policy, byte cap or key-count cap is added.
    static func requireUnambiguousJSON(_ data: Data) throws {
        let bytes = Array(try jsonUTF8View(data))
        var scanner = JSONMemberScanner(bytes: bytes)
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == bytes.count else { throw Failure.malformed }
    }

    /// Raw values for narrow session-bound cache retention. This adds no credential/sanitizer
    /// exemption: it only reuses lexical ambiguity admission and a complete JSON value parse.
    /// Callers own their byte cap and must keep owned keys authoritative when merging the result.
    struct RawJSONMember: Sendable {
        let key: String
        let keyJSON: Data
        let valueJSON: Data
    }
    static func rawJSONObjectMembers(_ data: Data, maximumBytes: Int, maximumMembers: Int = 512) throws -> [RawJSONMember] {
        guard maximumMembers >= 0 else { throw Failure.malformed }
        let bytes = try rawJSONBytes(data, maximumBytes: maximumBytes)
        var scanner = JSONMemberScanner(bytes: bytes)
        scanner.whitespace()
        guard scanner.take(123) else { throw Failure.malformed }
        scanner.whitespace()
        if scanner.take(125) { return [] }
        var result: [RawJSONMember] = []
        while true {
            scanner.whitespace()
            let keyRange = try scanner.stringToken()
            guard let key = try decodeJSON(with: Data(bytes[keyRange]), options: [.fragmentsAllowed]) as? String else {
                throw Failure.malformed
            }
            scanner.whitespace()
            guard scanner.take(58) else { throw Failure.malformed }
            scanner.whitespace()
            let start = scanner.index
            try scanner.value(depth: 1)
            guard result.count < maximumMembers else { throw Failure.malformed }
            result.append(.init(key: key, keyJSON: Data(bytes[keyRange]),
                                valueJSON: Data(bytes[start..<scanner.index])))
            scanner.whitespace()
            if scanner.take(125) { return result }
            guard scanner.take(44) else { throw Failure.malformed }
        }
    }
    static func rawJSONArrayValues(_ data: Data, maximumBytes: Int, maximumValues: Int = 400) throws -> [Data] {
        guard maximumValues >= 0 else { throw Failure.malformed }
        let bytes = try rawJSONBytes(data, maximumBytes: maximumBytes)
        var scanner = JSONMemberScanner(bytes: bytes)
        scanner.whitespace()
        guard scanner.take(91) else { throw Failure.malformed }
        scanner.whitespace()
        if scanner.take(93) { return [] }
        var result: [Data] = []
        while true {
            scanner.whitespace()
            let start = scanner.index
            try scanner.value(depth: 1)
            guard result.count < maximumValues else { throw Failure.malformed }
            result.append(Data(bytes[start..<scanner.index]))
            scanner.whitespace()
            if scanner.take(93) { return result }
            guard scanner.take(44) else { throw Failure.malformed }
        }
    }
    private static func rawJSONBytes(_ data: Data, maximumBytes: Int) throws -> [UInt8] {
        guard maximumBytes >= 0, data.count <= maximumBytes,
              String(data: data, encoding: .utf8) != nil else { throw Failure.malformed }
        // No transcoding: retained source value bytes must be the original UTF-8 bytes.
        let bytes = Array(data)
        var scanner = JSONMemberScanner(bytes: bytes)
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == bytes.count else { throw Failure.malformed }
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return bytes
    }

    private struct JSONMemberScanner {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func value(depth: Int) throws {
            // Deliberate raw-JSON admission tightening, not redundant with sanitizer depth 64:
            // even a credential subtree the sanitizer would discard must fit this scan bound.
            // Fail before replacement; never skip an uninspected deep subtree to preserve bytes.
            guard depth <= 128 else { throw Failure.malformed }
            whitespace()
            guard index < bytes.count else { throw Failure.malformed }
            switch bytes[index] {
            case 123:
                index += 1; whitespace()
                var keys = Set<String>()
                if take(125) { return }
                while true {
                    whitespace()
                    let token = try stringToken()
                    // Reuse Foundation's string escape/surrogate/UTF-8 decoding, as the existing
                    // overlay witness does. Swift String equality also rejects canonical Unicode
                    // collisions which byte-keyed legacy JSON intentionally treats as distinct.
                    guard let key = (try? VortxNativeBootstrapArchive.decodeJSON(with: Data(bytes[token]), options: [.fragmentsAllowed])) as? String,
                          keys.insert(key).inserted else { throw Failure.malformed }
                    whitespace(); guard take(58) else { throw Failure.malformed }
                    try value(depth: depth + 1); whitespace()
                    if take(125) { return }
                    guard take(44) else { throw Failure.malformed }
                }
            case 91:
                index += 1; whitespace()
                if take(93) { return }
                while true {
                    try value(depth: depth + 1); whitespace()
                    if take(93) { return }
                    guard take(44) else { throw Failure.malformed }
                }
            case 34: _ = try stringToken()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            case 45, 48...57: try number()
            default: throw Failure.malformed
            }
        }
        mutating func stringToken() throws -> Range<Int> {
            let start = index
            guard take(34) else { throw Failure.malformed }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return start..<index }
                guard byte >= 32 else { throw Failure.malformed }
                if byte != 92 { continue }
                guard index < bytes.count else { throw Failure.malformed }
                let escaped = bytes[index]; index += 1
                switch escaped {
                case 34, 92, 47, 98, 102, 110, 114, 116: break
                case 117:
                    for _ in 0..<4 {
                        guard index < bytes.count else { throw Failure.malformed }
                        let hex = bytes[index]; index += 1
                        guard (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw Failure.malformed }
                    }
                default: throw Failure.malformed
                }
            }
            throw Failure.malformed
        }
        mutating func number() throws {
            // Lexical only. Do not import the witness's binary64 bound or legacy token cap.
            _ = take(45)
            if take(48) {
                guard index == bytes.count || !(48...57).contains(bytes[index]) else { throw Failure.malformed }
            } else {
                guard digit() else { throw Failure.malformed }
                while digit() {}
            }
            if take(46) { guard digit() else { throw Failure.malformed }; while digit() {} }
            if take(101) || take(69) {
                _ = take(43) || take(45)
                guard digit() else { throw Failure.malformed }; while digit() {}
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { guard take(byte) else { throw Failure.malformed } }
        }
        mutating func digit() -> Bool {
            guard index < bytes.count, (48...57).contains(bytes[index]) else { return false }
            index += 1; return true
        }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
    }
    private static func structuredPrefix(_ bytes: Data) -> Bool {
        let view = (try? jsonUTF8View(bytes)) ?? bytes
        let prefix = String(decoding: view.prefix(32), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static func settings(_ encoded: String, path: String, exclusions: inout [String], depth: Int,
                                 diagnostics: ((String) -> Void)?) throws -> String {
        guard let bytes = Data(base64Encoded: encoded),
              let envelope = try decodeJSON(with: bytes) as? [String: Any],
              envelope["format"] as? String == "vortx-backup"
        else { throw rejected(.opaquePreference, path: path, diagnostics: diagnostics, carrier: .settingsEnvelope) }
        try requireUnambiguousJSON(bytes)
        let safeEnvelope = try sanitize(envelope, path: path, exclusions: &exclusions, depth: depth + 1, diagnostics: diagnostics)
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
        return try VortxNativeBootstrapArchive.replacingHostDocument(in: archive, with: canonical(host))
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
