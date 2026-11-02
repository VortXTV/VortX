import Foundation
import CoreFoundation
import CryptoKit

/// File-only legacy conversion. This service has no store, transport, singleton, UI,
/// checkpoint, provider-credential writer or live native session. Context is INPUT,
/// not an authentication capability: the dedicated app adapter must capture it from
/// the same established account and an independently authenticated owner receipt.
/// A selected file, username, or caller-supplied UUID cannot establish that receipt.
enum VortxAccountBackupRepair {
    typealias Exact = OwnerHistoryExactJSON
    static let maximumFileBytes = VortxAccountBackupFile.maximumFileBytes
    static let maximumPlaintextBytes = 5 * 1024 * 1024
    static let repairKey = "vortxFileRepair"
    static let sourceArchiveDomain = "vortx/file-repair-original/1\n"

    enum Failure: String, Error, Sendable {
        case tooLarge, invalidEnvelope, unsupportedFormat, unsupportedVersion
        case matchingAccountRequired, cannotAuthenticate, superseded
        case ownerReceiptRequired, rosterUnavailable, ambiguousRoster, ownerMismatch
        case independentAccountUnsupported, existingNativeRequiresTypedValidation
        case queuedEditsRequireLiveReconciliation, heldSourceUnits, pendingSourceEvidence
        case sourceRequiresReconciliation, nativeRejected, preservationFailed, encryptionFailed
    }
    enum Format: Sendable, Equatable {
        case encryptedAccount(version: Int, versionBound: Bool)
        case settingsOnly
        case unsupported
    }
    struct Context: Sendable {
        let accountID: String
        let credentialCapture: CredentialScopeRegistry.Capture
        let dataKey: Data
        let expectedOwnerProfileID: UUID
        /// Exact authenticated locator/checkpoint receipt identity captured by the adapter.
        /// Never construct this from the selected file or just hash its owner UUID.
        let ownerReceiptSHA256: String
    }
    struct Candidate: Sendable {
        let file: Data
        let sourceSHA256: String
        let candidatePlaintextSHA256: String
        let ownerReceiptSHA256: String
        let originalVersion: Int
        let profileCount: Int
        let nativeSchema: Int
        fileprivate init(file: Data, sourceSHA256: String, candidatePlaintextSHA256: String,
            ownerReceiptSHA256: String, originalVersion: Int, profileCount: Int, nativeSchema: Int) {
            self.file = file; self.sourceSHA256 = sourceSHA256
            self.candidatePlaintextSHA256 = candidatePlaintextSHA256
            self.ownerReceiptSHA256 = ownerReceiptSHA256; self.originalVersion = originalVersion
            self.profileCount = profileCount; self.nativeSchema = nativeSchema
        }
    }

    /// Classification reads no key and produces no repaired bytes or ownership claim.
    static func inspect(_ original: Data) throws -> Format {
        guard original.count <= maximumFileBytes else { throw Failure.tooLarge }
        let root: Exact.Object
        do { root = try Exact.Object(original) } catch { throw Failure.invalidEnvelope }
        if let raw = root["format"], (try? JSONDecoder().decode(String.self, from: raw)) == SettingsBackup.formatTag {
            guard try integer(root.required("schema")) == 1 else { throw Failure.unsupportedVersion }
            return .settingsOnly
        }
        guard root["vortxBackup"] != nil else { return .unsupported }
        _ = try accountEnvelope(original, allowRepairMetadata: true)
        return .encryptedAccount(version: try integer(root.required("version")),
            versionBound: try root.text("document").hasPrefix("v2."))
    }

    /// Returns a SEPARATE encrypted account-format candidate. It never restores it.
    /// v1 deliberately refuses every existing native carrier, independent account,
    /// held unit, pending membership receipt and queued website edit. Such refusal
    /// does not modify or "clean" the source. Unknown/credential siblings stay exact.
    static func convert(_ original: Data, context: Context, abi: any VortxRuntimeABI,
                        isCurrent: () -> Bool) throws -> Candidate {
        func current() throws {
            guard !Task.isCancelled, isCurrent() else { throw Failure.superseded }
        }
        try current()
        guard let account = UUID(uuidString: context.accountID),
              context.accountID == account.uuidString.lowercased(),
              context.credentialCapture.scope == .account(account), context.dataKey.count == 32 else {
            throw Failure.matchingAccountRequired
        }
        guard context.ownerReceiptSHA256.count == 64,
              context.ownerReceiptSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.ownerReceiptRequired
        }
        var envelope = try accountEnvelope(original)
        let fileVersion = try integer(envelope.required("version"))
        let encrypted = try envelope.text("document")
        guard let plaintext = VortXSyncCrypto.openDocument(dataKey: context.dataKey, stored: encrypted,
            accountId: context.accountID, version: fileVersion) else { throw Failure.cannotAuthenticate }
        guard plaintext.count <= maximumPlaintextBytes else { throw Failure.tooLarge }
        try current()
        let raw = try Exact.Object(plaintext)
        // Even null is an existing carrier. Never downgrade, replace, or label a typed
        // source-bearing native account as a legacy account merely because it is unreadable.
        try requireLegacyOnlyKeys(Set(raw.fields.keys))
        // Deferral is not completion. v1 cannot mint host receipts for a queued web edit.
        for key in ["profileEdits", "profileEditEvents", "webAddonEdits"] where raw[key] != nil {
            throw Failure.queuedEditsRequireLiveReconciliation
        }
        _ = try VortxProfileOverlayWitness.decodeObject(json: plaintext)
        let roster = try resolvedRoster(raw, expectedOwner: context.expectedOwnerProfileID)
        guard !roster.profiles.contains(where: { $0.usesOwnAccount }) else {
            throw Failure.independentAccountUnsupported
        }
        let scope = VortxAccountScope(account: context.credentialCapture.namespace,
                                      ownerProfileID: context.expectedOwnerProfileID.uuidString)
        guard let owner = roster.profiles.first(where: { $0.isOwner }) else { throw Failure.ownerMismatch }
        let prepared: VortxLegacyBootstrapMaterial.Preparation
        do {
            prepared = try VortxLegacyBootstrapMaterial.prepare(document: plaintext,
                roster: roster.profiles, ownerProfileID: owner.id, rosterModifiedSeconds: roster.modified,
                deferProfileEdits: false, accountID: scope.account)
        } catch { throw Failure.sourceRequiresReconciliation }
        guard prepared.held.isEmpty else { throw Failure.heldSourceUnits }
        guard prepared.pendingCount == 0, prepared.pendingMembershipReceipts == nil else {
            throw Failure.pendingSourceEvidence
        }
        try current()
        let native: VortxJSON
        do {
            native = try VortxNativeSession.detachedLegacySync(scope: scope, ownerName: owner.name,
                                                               material: prepared.material, abi: abi)
            // A separate disposable kernel candidate must accept the exact import receipt
            // and material replay. .held is refusal, never "mostly converted".
            let replay = try VortxNativeSession.validateLegacyCompatibility(scope: scope,
                ownerName: owner.name, snapshot: nil, nativeSync: native,
                material: prepared.material, abi: abi)
            guard replay == .accepted else { throw Failure.nativeRejected }
        } catch { throw Failure.nativeRejected }
        try current()
        let nativeBytes = try JSONEncoder().encode(native)
        let nativeObject = try Exact.Object(nativeBytes)
        let nativeSchema = try integer(nativeObject.required("schemaVersion"))
        guard (1...5).contains(nativeSchema), nativeObject["ownerHistory"] == nil,
              try nativeObject.text("scope") == scope.account,
              try nativeObject.text("ownerProfileId") == scope.ownerProfileID else { throw Failure.nativeRejected }
        // Preserve each original top-level VALUE slice verbatim, including settings,
        // apiKeys, unknown numeric lexemes, source strings, nested order and tombstones.
        let repaired = try OwnerHistoryAccountExport(completeAccountPlaintext: plaintext)
            .replacingOwned(["nativeSync": nativeBytes])
        let next = try repaired.validatedPlaintext(writeV2: true)
        try requireConservation(original: raw, candidate: Exact.Object(next))
        guard let sealed = VortXSyncCrypto.sealDocument(dataKey: context.dataKey, plaintext: next,
            accountId: context.accountID, version: fileVersion, writeV2: true),
              VortXSyncCrypto.openDocument(dataKey: context.dataKey, stored: sealed,
                accountId: context.accountID, version: fileVersion) == next else { throw Failure.encryptionFailed }
        // Preserve the ENTIRE original file inside a second AEAD envelope with a distinct
        // purpose domain. The COPY includes unknown outer fields; their original outer
        // values still remain plaintext in the output envelope. The outer manifest is
        // unsigned/untrusted, not authenticatedSourceArchive or a server observation receipt.
        guard let originalArchive = VortXSyncCrypto.sealDocument(dataKey: context.dataKey, plaintext: original,
            accountId: sourceArchiveDomain + context.accountID, version: fileVersion, writeV2: true),
              VortXSyncCrypto.openDocument(dataKey: context.dataKey, stored: originalArchive,
                accountId: sourceArchiveDomain + context.accountID, version: fileVersion) == original else {
            throw Failure.encryptionFailed
        }
        var manifest = try Exact.Object(Data("{}".utf8))
        manifest.set("schemaVersion", Data("1".utf8))
        manifest.set("sourceKind", try Exact.string("user_selected_file"))
        manifest.set("conversion", try Exact.string("legacy_to_native_cold_v1"))
        manifest.set("sourceSHA256", try Exact.string(digest(original)))
        manifest.set("candidatePlaintextSHA256", try Exact.string(digest(next)))
        manifest.set("originalFileDocument", try Exact.string(originalArchive))
        manifest.set("nativeSchema", Data(String(nativeSchema).utf8))
        envelope.set("document", try Exact.string(sealed))
        envelope.set(repairKey, try manifest.encoded())
        let file = try envelope.encoded()
        guard file.count <= maximumFileBytes else { throw Failure.tooLarge }
        _ = try VortxAccountBackupFile.inspect(file)
        // ExportedAt and version remain the original file values; no server revision,
        // ratchet, live acknowledgement, profile selection or historical clock is advanced.
        try current()
        return Candidate(file: file, sourceSHA256: digest(original), candidatePlaintextSHA256: digest(next),
            ownerReceiptSHA256: context.ownerReceiptSHA256, originalVersion: fileVersion,
            profileCount: roster.profiles.count, nativeSchema: nativeSchema)
    }

    static func requireConservation(original: Exact.Object, candidate: Exact.Object) throws {
        guard Set(candidate.fields.keys) == Set(original.fields.keys).union(["nativeSync"]),
              original.fields.allSatisfy({ candidate[$0.key] == $0.value }) else { throw Failure.preservationFailed }
    }
    private static func accountEnvelope(_ bytes: Data, allowRepairMetadata: Bool = false) throws -> Exact.Object {
        // Reuse the reviewed current full-account framing/limit/duplicate-key contract.
        do { _ = try VortxAccountBackupFile.inspect(bytes) }
        catch let failure as VortxAccountBackupFile.Failure {
            switch failure {
            case .tooLarge: throw Failure.tooLarge
            case .wrongFormat: throw Failure.unsupportedFormat
            case .unsupportedFormat: throw Failure.unsupportedVersion
            default: throw Failure.invalidEnvelope
            }
        }
        let root = try Exact.Object(bytes)
        guard allowRepairMetadata || root[repairKey] == nil else { throw Failure.existingNativeRequiresTypedValidation }
        return root
    }
    private static func integer(_ bytes: Data) throws -> Int {
        guard !bytes.isEmpty, bytes.utf8DigitsOnly, bytes.count == 1 || bytes.first != 48,
              let value = Int(String(decoding: bytes, as: UTF8.self)), value <= 9_007_199_254_740_991 else {
            throw Failure.invalidEnvelope
        }
        return value
    }
    // Actual recovery producers own these keys at hostDocument (and own-account sources
    // at the account root). A file converter cannot settle their historical provenance.
    // Also refuse their presence at the recognized legacy vortx/settings carrier roots;
    // arbitrary unknown descendants are preserved, not recursively interpreted as authority.
    static let unsupportedNativeKeys: Set<String> = [
        "nativeSync", "nativeHostPreferences", "nativeProviderCredentials",
        "nativeOwnerHistorySources", "profileEditResults",
        "ownAccountSources", "ownAccountOverlayPending", "ownAccountOverlayQuarantine",
        "nativeLegacyMembershipPending", "nativeWatchedMigrationEvidence",
        "nativeWatchedMigrationPending", "nativeWatchedMigrationSources",
        "hostDocument", "legacyImportMaterial", "authenticatedSourceArchive", "excludedCredentialPaths"
    ]
    private static func requireLegacyOnlyKeys(_ keys: Set<String>) throws {
        guard keys.isDisjoint(with: unsupportedNativeKeys) else {
            throw Failure.existingNativeRequiresTypedValidation
        }
    }
    /// Strict owner discovery for an independently authenticated CURRENT legacy account read.
    /// This is a pure interpretation, never an authentication capability. The manager must supply
    /// actual server bytes under its original account/key capture; selected file bytes do not qualify.
    static func legacyOwnerID(in plaintext: Data) throws -> UUID {
        guard plaintext.count <= maximumPlaintextBytes else { throw Failure.tooLarge }
        let raw = try Exact.Object(plaintext)
        try requireLegacyOnlyKeys(Set(raw.fields.keys))
        _ = try VortxProfileOverlayWitness.decodeObject(json: plaintext)
        let roster = try resolvedRoster(raw, expectedOwner: nil)
        guard let owner = roster.profiles.first(where: \.isOwner) else { throw Failure.rosterUnavailable }
        return owner.id
    }
    private static func resolvedRoster(_ source: Exact.Object, expectedOwner: UUID?) throws -> ProfileRosterSnapshot {
        do {
            var fromSettings: ProfileRosterSnapshot?
            if source["settings"] != nil {
                guard let bytes = Data(base64Encoded: try source.text("settings")) else { throw Failure.rosterUnavailable }
                let envelope = try Exact.Object(bytes)
                guard try envelope.text("format") == SettingsBackup.formatTag,
                      try integer(envelope.required("schema")) == 1,
                      let payload = Data(base64Encoded: try envelope.text("payloadBase64")),
                      payload.count <= maximumPlaintextBytes,
                      let domain = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any] else {
                    throw Failure.rosterUnavailable
                }
                var nodes = 0
                try validatePlist(domain, depth: 0, nodes: &nodes)
                try requireLegacyOnlyKeys(Set(domain.keys))
                // Never decodeDomain/restoreValues: their filtering is an apply policy.
                let clock = try plistRosterClock(domain["stremiox.profiles.modified"])
                if let present = domain["stremiox.profiles"] {
                    guard let bytes = present as? Data else { throw Failure.rosterUnavailable }
                    fromSettings = ProfileRosterSnapshot(profiles: try admittedRoster(bytes), modified: clock)
                } else if clock != nil { throw Failure.rosterUnavailable }
            }
            var fromFull: ProfileRosterSnapshot?
            if let bytes = source["vortx"] {
                // Present null/scalar/object-with-invalid-roster never counts as absence.
                let vortx = try Exact.Object(bytes)
                try requireLegacyOnlyKeys(Set(vortx.fields.keys))
                let clock = try jsonRosterClock(vortx["rosterModified"])
                if let rows = vortx["roster"] {
                    fromFull = ProfileRosterSnapshot(profiles: try admittedRoster(rows), modified: clock)
                } else if clock != nil { throw Failure.rosterUnavailable }
                // vortx.profiles is only a lossy dashboard summary, never full authority.
            }
            if let a = fromSettings, let b = fromFull {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(a.profiles) == encoder.encode(b.profiles), a.modified == b.modified else {
                    throw Failure.ambiguousRoster
                }
            }
            guard let roster = fromFull ?? fromSettings else { throw Failure.rosterUnavailable }
            let owners = roster.profiles.filter(\.isOwner)
            guard owners.count == 1 else { throw Failure.ownerMismatch }
            if let expectedOwner, owners[0].id != expectedOwner { throw Failure.ownerMismatch }
            return roster
        } catch let failure as Failure { throw failure }
        catch { throw Failure.rosterUnavailable }
    }
    private static func plistRosterClock(_ raw: Any?) throws -> Double? {
        guard let raw else { return nil } // Only genuine absence has no legacy watermark.
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw Failure.rosterUnavailable
        }
        // JSON serialization retains a plist integer's precision for the comparison below.
        return try jsonRosterClock(JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed]))
    }
    private static func jsonRosterClock(_ raw: Data?) throws -> Double? {
        guard let raw else { return nil }
        let clock = try JSONDecoder().decode(Double.self, from: raw)
        guard clock.isFinite, clock >= 0 else { throw Failure.rosterUnavailable }
        try sameScalar(raw, JSONEncoder().encode(clock))
        return clock
    }
    private static func admittedRoster(_ bytes: Data) throws -> [UserProfile] {
        let rows = try Exact.array(bytes)
        guard !rows.isEmpty else { throw Failure.rosterUnavailable }
        var ids = Set<String>(), profiles: [UserProfile] = []
        for bytes in rows {
            let raw = try Exact.Object(bytes)
            // Codable is intentionally tolerant for live legacy startup. Here, required
            // fields and every PRESENT known value must also survive projection exactly.
            let profile = try JSONDecoder().decode(UserProfile.self, from: bytes)
            let projected = try Exact.Object(JSONEncoder().encode(profile))
            try validateProjection(raw, projected, record: .profile)
            let id = try raw.text("id")
            guard UUID(uuidString: id)?.uuidString == id, ids.insert(id).inserted,
                  !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !profile.avatar.isEmpty, !profile.accentID.isEmpty,
                  profile.textScale.isFinite, profile.textScale > 0, profile.textScale <= 100 else {
                throw Failure.rosterUnavailable
            }
            if let pin = profile.pin, !pin.isEmpty {
                guard pin.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                    throw Failure.rosterUnavailable
                }
            }
            profiles.append(profile)
        }
        return profiles
    }

    // Explicit current model contract. No missing nonoptional field can acquire a
    // random id, default owner/account/parental policy, name, or appearance via Codable.
    // Optional absent/null values retain the declared legacy nil meaning; they are not
    // converted to modern initializers' defaults (notably addonPreferences must stay nil).
    private enum ProfileRecord {
        case profile, playback, discovery, addonPreferences, ranking
        var required: Set<String> {
            switch self {
            case .profile: return ["id", "name", "avatar", "accentID", "oled", "textScale",
                                   "usesOwnAccount", "isOwner", "familyEdit", "isKids"]
            case .playback: return ["audioLang", "subtitleLang", "forcedPolicy", "subFont", "subSize", "subColor", "subBackground"]
            case .ranking: return ["sourceTypeOrder", "useAddonOrder"]
            case .discovery, .addonPreferences: return []
            }
        }
        var optional: Set<String> {
            switch self {
            case .profile: return ["pin", "email", "playback", "discovery", "disabledAddons", "addonPreferences"]
            case .playback: return ["subSizeScale", "subBrightness", "sourceTypeOrder", "useAddonOrder",
                "safetyMode", "instantOnly", "hideDeadTorrents", "hdrOnly", "excludeAV1", "excludeKeywords",
                "includeKeywords", "keywordsAreRegex", "maxResolution", "maxFileSizeGB", "titleMatchThreshold",
                "minResolution", "hideUnknownResolution", "preferredAudioOnly", "preferKeywords", "avoidBehavior", "autoPickBest"]
            case .discovery: return ["hiddenCatalogs", "catalogOrder", "hiddenHubCategories", "regionOverrideCaptured",
                "regionOverride", "filtersCaptured", "filtersData", "selectedProviders", "providerOrder",
                "tabVisibilityCaptured", "hideLiveTab", "hideDiscoverTab", "hideLibraryTab", "hideSearchTab",
                "showCollectionsHome", "showCollectionsDiscover", "continueWatchingSource", "continueWatchingWindow"]
            case .addonPreferences: return ["disabledAddonURLsOverride", "rankingOverride"]
            case .ranking: return ["addonOrder"]
            }
        }
        func nested(_ key: String) -> ProfileRecord? {
            switch (self, key) {
            case (.profile, "playback"): return .playback
            case (.profile, "discovery"): return .discovery
            case (.profile, "addonPreferences"): return .addonPreferences
            case (.addonPreferences, "rankingOverride"): return .ranking
            default: return nil
            }
        }
    }
    private static func validateProjection(_ raw: Exact.Object, _ typed: Exact.Object, record: ProfileRecord) throws {
        let known = record.required.union(record.optional)
        guard record.required.isSubset(of: Set(raw.fields.keys)),
              Set(typed.fields.keys).isSubset(of: known) else { throw Failure.rosterUnavailable }
        for key in known {
            guard let original = raw[key] else {
                // Only explicitly optional absence is admitted, and it must remain nil.
                guard record.optional.contains(key), typed[key] == nil else { throw Failure.rosterUnavailable }
                continue
            }
            if original == Data("null".utf8) {
                guard record.optional.contains(key), typed[key] == nil else { throw Failure.rosterUnavailable }
            } else {
                guard let projected = typed[key] else { throw Failure.rosterUnavailable }
                if let nested = record.nested(key) {
                    try validateProjection(Exact.Object(original), Exact.Object(projected), record: nested)
                } else { try sameScalar(original, projected) }
            }
        }
        // Unknown fields stay in the untouched raw account slices; they grant no typed authority.
    }
    private static func sameScalar(_ original: Data, _ projected: Data) throws {
        if original.first == 91, projected.first == 91 {
            let left = try Exact.array(original), right = try Exact.array(projected)
            guard left.count == right.count else { throw Failure.rosterUnavailable }
            for (a, b) in zip(left, right) { try sameScalar(a, b) }
        } else if let first = original.first, first == 45 || (48...57).contains(first) {
            // Compare decimal values without a second floating-point round trip. Admit
            // harmless 1 vs 1.0 syntax, but refuse a known number rounded by typed decoding.
            guard try numberIdentity(original) == numberIdentity(projected) else { throw Failure.rosterUnavailable }
        } else {
            guard try Exact.canonical(original) == Exact.canonical(projected) else { throw Failure.rosterUnavailable }
        }
    }
    private static func numberIdentity(_ bytes: Data) throws -> String {
        guard bytes.count <= 128 else { throw Failure.rosterUnavailable }
        let value = String(decoding: bytes, as: UTF8.self).lowercased()
        let parts = value.split(separator: "e", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let mantissa = parts.first,
              let exponent = Int(parts.count == 2 ? String(parts[1]) : "0"), (-10_000...10_000).contains(exponent) else {
            throw Failure.rosterUnavailable
        }
        let negative = mantissa.first == "-"
        let unsigned = negative ? mantissa.dropFirst() : mantissa[...]
        let decimal = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(decimal.count) else { throw Failure.rosterUnavailable }
        var digits = decimal.joined()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.rosterUnavailable }
        let fraction = decimal.count == 2 ? decimal[1].count : 0
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        var shift = exponent - fraction
        while digits.last == "0" { digits.removeLast(); shift += 1 }
        return (negative ? "-" : "") + digits + "e" + String(shift)
    }
    private static func validatePlist(_ value: Any, depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 64, nodes <= 100_000 else { throw Failure.tooLarge }
        if let object = value as? [String: Any] {
            for nested in object.values { try validatePlist(nested, depth: depth + 1, nodes: &nodes) }
        } else if let array = value as? [Any] {
            for nested in array { try validatePlist(nested, depth: depth + 1, nodes: &nodes) }
        } else if let bytes = value as? Data {
            guard bytes.count <= maximumPlaintextBytes else { throw Failure.tooLarge }
        }
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var utf8DigitsOnly: Bool { allSatisfy { (48...57).contains($0) } }
}
