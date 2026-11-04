import Foundation
import CryptoKit

/// Synthetic files only. This fixture deliberately uses the ACTUAL linked native ABI
/// for success/replay, not a fake runtime that unconditionally accepts an import.
/// Parent owns compilation/execution and must pin the linked SDK/header provenance.
@main
private enum VortxAccountBackupRepairTests {
    typealias Repair = VortxAccountBackupRepair
    typealias Exact = OwnerHistoryExactJSON
    static let accountID = "10000000-0000-0000-0000-000000000001"
    static let owner = UserProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                                   name: "[RD] Owner", avatar: "O", isOwner: true)
    static let key = Data(repeating: 0x41, count: 32)
    // Synthetic receipt identity. The production adapter must capture a real authenticated
    // locator/checkpoint witness; passing this value is not a substitute for that adapter test.
    static let receipt = String(repeating: "a", count: 64)
    static func context(key: Data = key, ownerID: UUID = owner.id) -> Repair.Context {
        .init(accountID: accountID,
              credentialCapture: .init(scope: .account(UUID(uuidString: accountID)!), generation: 7),
              dataKey: key, expectedOwnerProfileID: ownerID, ownerReceiptSHA256: receipt)
    }
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: " + message)
    }
    static func rejected(_ message: String, expected: Repair.Failure? = nil,
                         _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("accepted: " + message) }
        catch {
            if let expected { precondition((error as? Repair.Failure) == expected, "wrong rejection: " + message) }
            print("PASS: " + message)
        }
    }
    static func source(profiles: [UserProfile] = [owner], extra: [String: Data] = [:]) throws -> Data {
        let rows = try JSONEncoder().encode(profiles)
        var vortx = try Exact.Object(Data("{}".utf8))
        vortx.set("roster", rows)
        vortx.set("rosterModified", Data("1700000000".utf8))
        vortx.set("library", Data(#"[{"id":"tt123","type":"movie","name":"[RD] Film","poster":"https://example.test/movie.jpg","t":33,"d":100,"lastWatched":"2026-01-01T00:00:00Z"}]"#.utf8))
        vortx.set("addons", Data(#"[{"transportUrl":"https://example.test/manifest.json","manifest":{"id":"fixture.addon","version":"1.0.0","name":"[Community] Add-on","description":"{Public} Description"}}]"#.utf8))
        var root = try Exact.Object(Data("{}".utf8))
        root.set("vortx", try vortx.encoded())
        root.set("apiKeys", Data(#"{"synthetic-provider":"synthetic-secret-preserve-only"}"#.utf8))
        root.set("future", Data(#"{"negativeZero":-0.0,"exactDecimal":0.10000000000000001,"order":[3,2,1]}"#.utf8))
        for (name, bytes) in extra { root.set(name, bytes) }
        return try root.encoded()
    }
    static func file(_ plaintext: Data, version: Int = 12, writeV2: Bool = false) throws -> Data {
        let encrypted = VortXSyncCrypto.sealDocument(dataKey: key, plaintext: plaintext,
            accountId: accountID, version: version, writeV2: writeV2)!
        var root = try Exact.Object(Data("{}".utf8))
        root.set("vortxBackup", Data("1".utf8)); root.set("username", try Exact.string("Fixture"))
        root.set("exportedAt", Data("1700000000000".utf8))
        root.set("document", try Exact.string(encrypted)); root.set("version", Data(String(version).utf8))
        root.set("futureEnvelope", Data(#"{"exact":1.00,"label":"[preserve]"}"#.utf8))
        return try root.encoded()
    }
    static func array(_ rows: [Data]) -> Data {
        var result = Data("[".utf8)
        for (index, row) in rows.enumerated() { if index > 0 { result.append(44) }; result.append(row) }
        result.append(93); return result
    }
    static func carriers(full: Data?, settings: Data?, fullClock: Data? = Data("1700000000".utf8),
                         settingsClock: Any? = 1_700_000_000, settingsExtra: [String: Any] = [:]) throws -> Data {
        var root = try Exact.Object(source()), vortx = try Exact.Object(root.required("vortx"))
        if let full { vortx.set("roster", full) } else { vortx.remove("roster") }
        if let fullClock, full != nil { vortx.set("rosterModified", fullClock) } else { vortx.remove("rosterModified") }
        root.set("vortx", try vortx.encoded())
        if settings != nil || !settingsExtra.isEmpty {
            var domain = settingsExtra
            if let settings { domain["stremiox.profiles"] = settings }
            if let settingsClock { domain["stremiox.profiles.modified"] = settingsClock }
            let envelope = try SettingsBackup.encode(domain: domain, bundleID: "fixture", app: "Fixture")
            root.set("settings", try Exact.string(envelope.base64EncodedString()))
        }
        return try root.encoded()
    }
    static func rejectedBeforeABI(_ message: String, plaintext: Data,
                                  expected: Repair.Failure = .rosterUnavailable) throws {
        let original = try file(plaintext), digest = SHA256.hash(data: original)
        rejected(message, expected: expected) {
            _ = try Repair.convert(original, context: context(), abi: MustNotReachABI(), isCurrent: { true })
        }
        precondition(SHA256.hash(data: original) == digest, "refusal changed original input")
    }
    static func rosterAdmissionCases(realABI: any VortxRuntimeABI) throws {
        let row = try Exact.Object(JSONEncoder().encode(owner)), valid = array([try row.encoded()])
        // Concrete original counterexamples in BOTH directions: no malformed present
        // carrier may become nil and then donate authority to the other valid carrier.
        let wrongFields: [(String, String)] = [
            ("id", "42"), ("name", "false"), ("avatar", "[]"), ("accentID", "{}"),
            ("oled", "1"), ("textScale", "true"), ("pin", "7"), ("usesOwnAccount", "0"),
            ("email", "false"), ("isOwner", "1"), ("familyEdit", "0"), ("isKids", "1"),
            ("playback", "[]"), ("discovery", "[]"), ("disabledAddons", "[1]"), ("addonPreferences", "[]")]
        for (field, value) in wrongFields {
            var malformed = row; malformed.set(field, Data(value.utf8))
            let rows = array([try malformed.encoded()])
            try rejectedBeforeABI("valid full cannot hide malformed settings " + field,
                                  plaintext: carriers(full: valid, settings: rows))
            try rejectedBeforeABI("valid settings cannot hide malformed full " + field,
                                  plaintext: carriers(full: rows, settings: valid))
        }
        for field in ["id", "name", "avatar", "accentID", "oled", "textScale", "usesOwnAccount", "isOwner", "familyEdit", "isKids"] {
            var missing = row; missing.remove(field)
            try rejectedBeforeABI("missing required full field cannot acquire decoder default: " + field,
                                  plaintext: carriers(full: array([try missing.encoded()]), settings: valid))
            missing.set(field, Data("null".utf8))
            try rejectedBeforeABI("present-null required settings field cannot acquire decoder default: " + field,
                                  plaintext: carriers(full: valid, settings: array([try missing.encoded()])))
        }
        let invalidSemantics: [(String, String)] = [
            ("name", #""   ""#), ("avatar", #""""#), ("accentID", #""""#),
            ("textScale", "0"), ("textScale", "101"), ("textScale", "0.10000000000000001"),
            ("pin", #""1234""#), ("pin", #""sha256:abcd""#),
            ("id", #""not-a-uuid""#)]
        for (field, value) in invalidSemantics {
            var malformed = row; malformed.set(field, Data(value.utf8))
            try rejectedBeforeABI("invalid identity/PIN/known numeric semantics " + field + " " + value,
                                  plaintext: carriers(full: valid, settings: array([try malformed.encoded()])))
        }
        let playback = try Exact.Object(Data(#"{"audioLang":"en","subtitleLang":"en","forcedPolicy":"auto","subFont":"system","subSize":"medium","subColor":"white","subBackground":"none","subSizeScale":1,"subBrightness":"100","sourceTypeOrder":["debrid","torrent"],"useAddonOrder":false,"safetyMode":"balanced","instantOnly":false,"hideDeadTorrents":true,"hdrOnly":false,"excludeAV1":false,"excludeKeywords":"cam","includeKeywords":"","keywordsAreRegex":false,"maxResolution":1080,"maxFileSizeGB":10,"titleMatchThreshold":70,"minResolution":720,"hideUnknownResolution":false,"preferredAudioOnly":false,"preferKeywords":"remux","avoidBehavior":"hide","autoPickBest":false}"#.utf8))
        let discovery = try Exact.Object(Data(#"{"hiddenCatalogs":[],"catalogOrder":[],"hiddenHubCategories":[],"regionOverrideCaptured":true,"regionOverride":"GB","filtersCaptured":true,"filtersData":"e30=","selectedProviders":[8],"providerOrder":[8],"tabVisibilityCaptured":true,"hideLiveTab":false,"hideDiscoverTab":false,"hideLibraryTab":false,"hideSearchTab":false,"showCollectionsHome":true,"showCollectionsDiscover":true,"continueWatchingSource":"local","continueWatchingWindow":"20"}"#.utf8))
        let addons = try Exact.Object(Data(#"{"disabledAddonURLsOverride":[],"rankingOverride":{"addonOrder":[],"sourceTypeOrder":["debrid","torrent"],"useAddonOrder":true}}"#.utf8))
        for (field, object) in [("playback", playback), ("discovery", discovery), ("addonPreferences", addons)] {
            for key in object.fields.keys.sorted() {
                var invalid = object; invalid.set(key, Data("42".utf8))
                // Numeric fields must get a nonnumeric wrong type.
                if ["subSizeScale", "maxResolution", "maxFileSizeGB", "titleMatchThreshold", "minResolution"].contains(key) {
                    invalid.set(key, Data("false".utf8))
                }
                var malformed = row; malformed.set(field, try invalid.encoded())
                try rejectedBeforeABI("present nested policy cannot disappear: " + field + "." + key,
                    plaintext: carriers(full: valid, settings: array([try malformed.encoded()])))
            }
        }
        let ranking = try Exact.Object(addons.required("rankingOverride"))
        for key in ranking.fields.keys.sorted() {
            var invalid = ranking; invalid.set(key, Data("42".utf8))
            var malformedAddon = addons; malformedAddon.set("rankingOverride", try invalid.encoded())
            var malformed = row; malformed.set("addonPreferences", try malformedAddon.encoded())
            try rejectedBeforeABI("present ranking policy cannot disappear: " + key,
                plaintext: carriers(full: array([try malformed.encoded()]), settings: valid))
        }
        for clock in ["null", "true", #""1700000000""#, "-1", "0.10000000000000001", "{}"] {
            try rejectedBeforeABI("present invalid full clock cannot disappear: " + clock,
                plaintext: carriers(full: valid, settings: valid, fullClock: Data(clock.utf8)))
        }
        let invalidSettingsClocks: [Any] = [true, "1700000000", -1, ["invalid": 1]]
        for clock in invalidSettingsClocks {
            try rejectedBeforeABI("present invalid settings clock cannot disappear",
                plaintext: carriers(full: valid, settings: valid, settingsClock: clock))
        }
        try rejectedBeforeABI("two admitted clocks must match", plaintext: carriers(full: valid, settings: valid,
            fullClock: Data("1700000001".utf8)), expected: .ambiguousRoster)
        try rejectedBeforeABI("present vs missing clock cannot silently merge", plaintext: carriers(full: valid, settings: valid,
            fullClock: nil), expected: .ambiguousRoster)
        var changed = row; changed.set("isKids", Data("true".utf8))
        try rejectedBeforeABI("two valid rosters with different parental policy cannot merge",
            plaintext: carriers(full: valid, settings: array([try changed.encoded()])), expected: .ambiguousRoster)
        changed = row; changed.set("pin", try Exact.string("sha256:" + String(repeating: "a", count: 64)))
        try rejectedBeforeABI("two valid rosters with different PIN policy cannot merge",
            plaintext: carriers(full: valid, settings: array([try changed.encoded()])), expected: .ambiguousRoster)
        for malformed in [Data("null".utf8), Data("{}".utf8), Data("[]".utf8)] {
            try rejectedBeforeABI("present malformed/empty full roster never means absent", plaintext: carriers(full: malformed, settings: valid))
            try rejectedBeforeABI("present malformed/empty settings roster never means absent", plaintext: carriers(full: valid, settings: malformed))
        }
        var malformedRoot = try Exact.Object(carriers(full: nil, settings: valid)); malformedRoot.set("vortx", Data("null".utf8))
        try rejectedBeforeABI("present malformed vortx cannot hide behind settings", plaintext: malformedRoot.encoded())
        try rejectedBeforeABI("present non-Data settings roster cannot hide behind full",
            plaintext: carriers(full: valid, settings: nil, settingsExtra: ["stremiox.profiles": "not-data"]))
        // Native round trips for explicitly supported absence, null optional fields,
        // identical dual carriers and unknown raw siblings: these use the REAL ABI.
        var legacy = row
        for key in ["pin", "email", "playback", "discovery", "disabledAddons", "addonPreferences"] { legacy.remove(key) }
        let legacyRows = array([try legacy.encoded()])
        _ = try Repair.convert(file(carriers(full: legacyRows, settings: nil, fullClock: nil)), context: context(), abi: realABI, isCurrent: { true })
        check(true, "explicit optional legacy nils and absent roster clock convert through actual ABI")
        for key in ["pin", "email", "playback", "discovery", "disabledAddons", "addonPreferences"] { legacy.set(key, Data("null".utf8)) }
        _ = try Repair.convert(file(carriers(full: nil, settings: array([try legacy.encoded()]), settingsClock: nil)), context: context(), abi: realABI, isCurrent: { true })
        check(true, "explicit-null optional legacy policy remains nil through actual ABI")
        var rich = row
        rich.set("pin", try Exact.string("sha256:" + String(repeating: "a", count: 64)))
        rich.set("isKids", Data("true".utf8)); rich.set("familyEdit", Data("true".utf8))
        rich.set("playback", try playback.encoded()); rich.set("discovery", try discovery.encoded())
        rich.set("addonPreferences", try addons.encoded())
        rich.set("futureProfile", Data(#"{"pin":123,"isKids":"unknown","number":0.10000000000000001}"#.utf8))
        let richRows = array([try rich.encoded()]), richSource = try carriers(full: richRows, settings: richRows)
        let candidate = try Repair.convert(file(richSource), context: context(), abi: realABI, isCurrent: { true })
        let candidateEnvelope = try Exact.Object(candidate.file)
        let repaired = VortXSyncCrypto.openDocument(dataKey: key, stored: try candidateEnvelope.text("document"), accountId: accountID, version: 12)!
        try Repair.requireConservation(original: Exact.Object(richSource), candidate: Exact.Object(repaired))
        check(true, "identical admitted dual rosters preserve exact PIN/kids/policy/unknown source bytes")
        // These names come from the actual archive/host producers, independently of
        // the helper's deny-list. Both null and nonempty present values are refused.
        // A preserved unknown descendant with a coincidentally matching key is not
        // a recognized native authority surface and must not be stripped or recategorized.
        let unknownSource = try source(extra: ["futureAuthorityNamespace": Data(#"{"nativeWatchedMigrationPending":null,"ownAccountSources":{"opaque":true}}"#.utf8)])
        let unknownResult = try Repair.convert(file(unknownSource), context: context(), abi: realABI, isCurrent: { true })
        let unknownEnvelope = try Exact.Object(unknownResult.file)
        let unknownPlaintext = VortXSyncCrypto.openDocument(dataKey: key, stored: try unknownEnvelope.text("document"), accountId: accountID, version: 12)!
        try Repair.requireConservation(original: Exact.Object(unknownSource), candidate: Exact.Object(unknownPlaintext))
        check(true, "unknown namespaces retain exact content without acquiring native authority")
        let existing = ["nativeSync", "nativeHostPreferences", "nativeProviderCredentials", "nativeOwnerHistorySources", "profileEditResults",
            "ownAccountSources", "ownAccountOverlayPending", "ownAccountOverlayQuarantine", "nativeLegacyMembershipPending",
            "nativeWatchedMigrationEvidence", "nativeWatchedMigrationPending", "nativeWatchedMigrationSources",
            "hostDocument", "legacyImportMaterial", "authenticatedSourceArchive", "excludedCredentialPaths"]
        for key in existing {
            for value in [Data("null".utf8), Data(#"{"pending":true}"#.utf8)] {
                try rejectedBeforeABI("existing root native/recovery carrier: " + key,
                    plaintext: source(extra: [key: value]), expected: .existingNativeRequiresTypedValidation)
                var nested = try Exact.Object(source()), vx = try Exact.Object(nested.required("vortx"))
                vx.set(key, value); nested.set("vortx", try vx.encoded())
                try rejectedBeforeABI("existing vortx native/recovery carrier: " + key,
                    plaintext: nested.encoded(), expected: .existingNativeRequiresTypedValidation)
            }
            try rejectedBeforeABI("existing settings native/recovery carrier: " + key,
                plaintext: carriers(full: valid, settings: valid, settingsExtra: [key: ["pending": true]]),
                expected: .existingNativeRequiresTypedValidation)
        }
    }
    static func main() throws {
        let abi = VortxCABI()
        try nativeOutputAssertions(abi: abi)
        try rosterAdmissionCases(realABI: abi)
        let plaintext = try source(), original = try file(plaintext)
        let originalHash = SHA256.hash(data: original)
        check(try Repair.inspect(original) == .encryptedAccount(version: 12, versionBound: false), "recognizes actual full account envelope")
        let result = try Repair.convert(original, context: context(), abi: abi, isCurrent: { true })
        let boundResult = try Repair.convert(file(plaintext, writeV2: true), context: context(), abi: abi, isCurrent: { true })
        check(boundResult.originalVersion == 12, "valid original v2 account file also converts through the actual kernel")
        check(SHA256.hash(data: original) == originalHash, "source bytes remain untouched")
        check(result.file != original && result.profileCount == 1 && (1...5).contains(result.nativeSchema), "real kernel creates a separate supported native candidate")
        let output = try Exact.Object(result.file), input = try Exact.Object(original)
        let ciphertext = try output.text("document")
        check(ciphertext.hasPrefix("v2."), "new encrypted file is version-bound")
        let opened = VortXSyncCrypto.openDocument(dataKey: key, stored: ciphertext, accountId: accountID, version: 12)!
        let sourceFields = try Exact.Object(plaintext), nextFields = try Exact.Object(opened)
        try Repair.requireConservation(original: sourceFields, candidate: nextFields)
        check(nextFields["future"] == sourceFields["future"], "unknown numeric lexemes, array order and negative zero survive byte-exactly")
        check(nextFields["apiKeys"] == sourceFields["apiKeys"], "encrypted source credentials remain exact and do not become native credentials")
        check(nextFields["vortx"] == sourceFields["vortx"], "roster, original clocks, library and tagged labels remain exact")
        check(output["futureEnvelope"] == input["futureEnvelope"] && output["exportedAt"] == input["exportedAt"] && output["version"] == input["version"], "outer unknown values, timestamp and original file revision stay exact")
        let metadata = try Exact.Object(output.required(Repair.repairKey))
        let archived = VortXSyncCrypto.openDocument(dataKey: key,
            stored: try metadata.text("originalFileDocument"), accountId: Repair.sourceArchiveDomain + accountID, version: 12)
        check(archived == original, "encrypted source archive recovers the entire original file exactly")
        check(try metadata.text("sourceKind") == "user_selected_file", "file evidence is never labelled an authenticated cloud observation")
        check(VortXSyncCrypto.openDocument(dataKey: key, stored: ciphertext, accountId: accountID, version: 13) == nil, "candidate cannot be replayed under a fabricated server revision")
        check(VortXSyncCrypto.openDocument(dataKey: key, stored: try metadata.text("originalFileDocument"), accountId: accountID, version: 12) == nil, "archived original is separated from account-document encryption purpose")
        rejected("wrong account key", expected: .cannotAuthenticate) {
            _ = try Repair.convert(original, context: context(key: Data(repeating: 0x42, count: 32)), abi: abi, isCurrent: { true })
        }
        rejected("independent owner mismatch", expected: .ownerMismatch) {
            _ = try Repair.convert(original, context: context(ownerID: UUID()), abi: abi, isCurrent: { true })
        }
        rejected("retired account operation", expected: .superseded) {
            _ = try Repair.convert(original, context: context(), abi: abi, isCurrent: { false })
        }
        var admissions = 0
        rejected("retirement before native dispatch", expected: .superseded) {
            _ = try Repair.convert(original, context: context(), abi: abi, isCurrent: { admissions += 1; return admissions < 3 })
        }
        admissions = 0
        rejected("retirement after native replay discards the candidate", expected: .superseded) {
            _ = try Repair.convert(original, context: context(), abi: abi, isCurrent: { admissions += 1; return admissions < 4 })
        }
        rejected("kernel-held replay cannot be reported as repaired", expected: .nativeRejected) {
            _ = try Repair.convert(original, context: context(), abi: RejectReplayABI(), isCurrent: { true })
        }
        for key in ["nativeSync", "nativeHostPreferences", "nativeProviderCredentials", "nativeOwnerHistorySources"] {
            let source = try source(extra: [key: Data("null".utf8)])
            rejected("existing carrier including null is not downgraded: " + key, expected: .existingNativeRequiresTypedValidation) {
                _ = try Repair.convert(file(source), context: context(), abi: abi, isCurrent: { true })
            }
        }
        for key in ["profileEdits", "profileEditEvents", "webAddonEdits"] {
            rejected("queued edits are not silently acknowledged: " + key, expected: .queuedEditsRequireLiveReconciliation) {
                _ = try Repair.convert(file(source(extra: [key: Data("{}".utf8)])), context: context(), abi: abi, isCurrent: { true })
            }
        }
        var own = owner; own.isOwner = false; own.id = UUID(); own.usesOwnAccount = true
        rejected("unverified independent-account source", expected: .independentAccountUnsupported) {
            _ = try Repair.convert(file(source(profiles: [owner, own])), context: context(), abi: abi, isCurrent: { true })
        }
        var bad = try Exact.Object(plaintext), badVortx = try Exact.Object(bad.required("vortx"))
        badVortx.set("addons", Data(#"[{"transportUrl":"https://example.test/missing-manifest.json"}]"#.utf8))
        bad.set("vortx", try badVortx.encoded())
        rejected("one held addon prevents a falsely complete repaired file", expected: .heldSourceUnits) {
            _ = try Repair.convert(file(bad.encoded()), context: context(), abi: abi, isCurrent: { true })
        }
        var pending = try Exact.Object(plaintext), pendingVortx = try Exact.Object(pending.required("vortx"))
        pendingVortx.set("deletedAddonsTs", Data(#"{"https://example.test/missing/manifest.json":{"addedAt":2000.75,"removedAt":1000.125}}"#.utf8))
        pending.set("vortx", try pendingVortx.encoded())
        rejected("unresolved membership evidence prevents complete output", expected: .pendingSourceEvidence) {
            _ = try Repair.convert(file(pending.encoded()), context: context(), abi: abi, isCurrent: { true })
        }
        rejected("duplicate envelope key") { _ = try Repair.inspect(Data(#"{"vortxBackup":1,"vortxBackup":1}"#.utf8)) }
        var futureEnvelope = try Exact.Object(original); futureEnvelope.set("vortxBackup", Data("2".utf8))
        rejected("future outer schema", expected: .unsupportedVersion) { _ = try Repair.inspect(futureEnvelope.encoded()) }
        rejected("wrong file version fails v2 authentication", expected: .cannotAuthenticate) {
            var bound = try Exact.Object(file(plaintext, writeV2: true)); bound.set("version", Data("13".utf8))
            _ = try Repair.convert(bound.encoded(), context: context(), abi: abi, isCurrent: { true })
        }
        let settings = try SettingsBackup.encode(domain: ["theme":"dark"], bundleID: "fixture", app: "Fixture")
        check(try Repair.inspect(settings) == .settingsOnly, "settings are classified without claiming full-account repair")
        rejected("settings envelope cannot enter native account conversion", expected: .unsupportedFormat) {
            _ = try Repair.convert(settings, context: context(), abi: abi, isCurrent: { true })
        }
        var mutated = nextFields; mutated.set("future", Data("{}".utf8))
        rejected("preservation check detects an altered unknown", expected: .preservationFailed) {
            try Repair.requireConservation(original: sourceFields, candidate: mutated)
        }
        print("All synthetic backup repair checks passed with the linked native ABI; no live account or file I/O was used.")
    }
}

/// Fault injection around the REAL ABI: only the second import/reconciliation answer
/// is rejected. Creation, scope binding, accepted first import, merge, state and free
/// still execute the installed kernel. This proves .held is not accepted by the wrapper.
private final class RejectReplayABI: VortxRuntimeABI, @unchecked Sendable {
    private let real = VortxCABI()
    private let lock = NSLock()
    private var imports = 0
    func create(ownerID: String, ownerName: String) -> UInt { real.create(ownerID: ownerID, ownerName: ownerName) }
    func hydrate(_ snapshot: String) -> UInt { real.hydrate(snapshot) }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        let object = try? JSONDecoder().decode(VortxJSON.self, from: Data(action.utf8))
        if object?["type"] == .string("import_legacy_sync") {
            lock.lock(); imports += 1; let reject = imports > 1; lock.unlock()
            if reject { return #"{"ok":false,"error":"fixture replay rejected"}"# }
        }
        if object?["type"] == .string("reconcile_legacy_sync") {
            return #"{"ok":false,"error":"fixture reconciliation rejected"}"#
        }
        return real.dispatch(handle, action: action, now: now)
    }
    func resolve(_ handle: UInt, request: String) -> String? { real.resolve(handle, request: request) }
    func state(_ handle: UInt) -> String? { real.state(handle) }
    func delta(_ handle: UInt) -> String? { real.delta(handle) }
    func canonicalizeOwnerHistoryEvidence(_ evidence: String) -> String? { real.canonicalizeOwnerHistoryEvidence(evidence) }
    func free(_ handle: UInt) { real.free(handle) }
}

/// Negative preflight tests abort if any native allocation/dispatch is attempted.
/// This is not a success oracle: every success above uses the real linked ABI.
private struct MustNotReachABI: VortxRuntimeABI {
    func create(ownerID: String, ownerName: String) -> UInt { preconditionFailure("preflight reached native create") }
    func hydrate(_ snapshot: String) -> UInt { preconditionFailure("preflight reached native hydrate") }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? { preconditionFailure("preflight reached native dispatch") }
    func resolve(_ handle: UInt, request: String) -> String? { preconditionFailure("preflight reached native resolve") }
    func state(_ handle: UInt) -> String? { preconditionFailure("preflight reached native state") }
    func delta(_ handle: UInt) -> String? { preconditionFailure("preflight reached native delta") }
    func canonicalizeOwnerHistoryEvidence(_ evidence: String) -> String? { preconditionFailure("preflight reached native evidence") }
    func free(_ handle: UInt) { preconditionFailure("preflight reached native free") }
}

// Appended to the frozen fixture in the GENERATED compiler input only. The runner
// injects one call into its main and records both original and generated SHA-256.
extension VortxAccountBackupRepairTests {
    static func nativeOutputAssertions(abi: any VortxRuntimeABI) throws {
        var primary = owner
        primary.pin = "sha256:" + String(repeating: "a", count: 64)
        primary.isKids = false
        primary.familyEdit = false
        let shared = UserProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Synthetic shared child", avatar: "C",
            pin: "sha256:" + String(repeating: "b", count: 64), usesOwnAccount: false,
            isOwner: false, familyEdit: true, isKids: true)
        let plaintext = try source(profiles: [primary, shared])
        let converted = try Repair.convert(file(plaintext), context: context(), abi: abi, isCurrent: { true })
        let envelope = try Exact.Object(converted.file)
        guard let opened = VortXSyncCrypto.openDocument(dataKey: key, stored: try envelope.text("document"),
                accountId: accountID, version: 12) else { preconditionFailure("cannot open generated candidate") }
        let output = try Exact.Object(opened)
        try Repair.requireConservation(original: Exact.Object(plaintext), candidate: output)
        let native = try JSONDecoder().decode(VortxJSON.self, from: output.required("nativeSync"))
        guard case .object(let nativeProfiles) = native["profiles"] else {
            preconditionFailure("generated native profiles missing")
        }
        check(Set(nativeProfiles.keys) == [primary.id.uuidString, shared.id.uuidString],
              "generated native document contains the owner and secondary shared profile")
        let scope = VortxAccountScope(account: context().credentialCapture.namespace,
                                     ownerProfileID: primary.id.uuidString)
        check(native["scope"] == .string(scope.account) && native["ownerProfileId"] == .string(scope.ownerProfileID),
              "generated native document retains actual owner/account scope")

        // Consume the GENERATED native document in a third genuine disposable kernel.
        // Read its actual roster, not the retained legacy roster or importer baseline.
        let runtime = try VortxNativeRuntime(abi: abi, ownerID: primary.id.uuidString, ownerName: primary.name)
        defer { precondition(runtime.close(), "scratch runtime did not close") }
        func dispatch(_ action: VortxJSON) throws {
            let reply = try runtime.dispatch(String(decoding: JSONEncoder().encode(action), as: UTF8.self),
                                             now: 1_700_000_100)
            check(try JSONDecoder().decode(VortxJSON.self, from: Data(reply.utf8))["ok"] == .bool(true),
                  "real kernel accepts native output verification action")
        }
        try dispatch(.object(["type": .string("bind_sync_scope"), "scope": .string(scope.account)]))
        try dispatch(.object(["type": .string("merge_native_sync"), "document": native]))
        let state = try scope.validateSnapshot(runtime.stateJSON())
        for profile in [primary, shared] {
            guard let actual = state["roster"]?["profiles"]?[profile.id.uuidString] else {
                preconditionFailure("real kernel lost an admitted profile")
            }
            let kind = profile.isOwner ? "local_only" : "shared"
            check(actual["id"] == .string(profile.id.uuidString) && actual["name"] == .string(profile.name)
                && actual["owner"] == .bool(profile.isOwner), "actual native output retains profile identity/owner flag")
            check(actual["pin"] == .string(profile.pin!), "actual native output retains exact hashed PIN")
            check(actual["parental"]?["kids"] == .bool(profile.isKids)
                && actual["parental"]?["familyEdit"] == .bool(profile.familyEdit),
                  "actual native output retains kids and family-edit policy")
            check(actual["account"]?["kind"] == .string(kind), "actual native output retains owner/shared account kind")
            if !profile.isOwner {
                check(actual["account"]?["value"] == .string(primary.id.uuidString),
                      "actual native shared profile remains bound to the original owner")
            }
            check(actual["addons"] == .string("share_primary"), "actual native output retains shared add-on policy")
        }
        check(converted.profileCount == 2, "converter reports both actually admitted profiles")
    }
}
