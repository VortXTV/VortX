import Foundation

/// Public, credential-free host preference carrier. Kernel-owned fields remain in nativeSync.
struct VortxNativeHostPreferences: Sendable {
    static let maxClock: UInt64 = VortxRawHostRegister.maximumClock
    struct Register: Codable, Equatable, Sendable { let clock: UInt64; let actor: String; let value: VortxJSON }
    struct Fields: Codable, Equatable, Sendable { var fields: [String: Register] = [:] }
    struct Document: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let scope: String
        let ownerProfileId: String
        var profiles: [String: Fields] = [:]
        var globals = Fields()
    }
    struct Local: Codable, Sendable {
        var actor: String; var counter: UInt64; var document: Document
        // Device-local transaction journal, never part of the exported preference carrier.
        var websitePending: [VortxJSON]? = nil
        var websiteReceipts: [String: String]? = nil
        var websiteConflicts: [VortxNativeProfileEditHost.Conflict]? = nil
        var websiteAddonPending: [VortxJSON]? = nil
        var websiteAddonReceipts: [String: String]? = nil
        var websiteAddonConflicts: [VortxNativeWebsiteAddonEdits.Conflict]? = nil
        var authenticatedSourceArchive: Data? = nil
    }
    struct Edit: Sendable {
        let profileID: String?; let fields: [String: VortxJSON]; let rawFields: [String: Data]
        init(profileID: String?, fields: [String: VortxJSON], rawFields: [String: Data] = [:]) {
            self.profileID = profileID; self.fields = fields; self.rawFields = rawFields
        }
    }
    var local: Local
    // Genuine checkpoint slices, captured before Codable presentation decoding. The baseline
    // detects existing typed writers (including legacy watchlist seeding) without rewriting
    // unchanged raw registers or unknown Local/document/profile/register members.
    private var rawLocalBase: Data? = nil
    private var rawDocumentBase: Data? = nil
    private var rawDocumentBaseline: Document? = nil
    private var rawLocalTypedBaseline: Data? = nil
    var document: VortxJSON { get throws { try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(local.document)) } }
    private static let kernelFields: Set<String> = ["id", "name", "isOwner", "pin", "isKids", "familyEdit", "accentID", "oled", "textScale", "disabledAddons", "usesOwnAccount", "account", "addons", "settings", "parental", "rev", "updatedAt", "deleted"]
    private static let reservedGlobals: Set<String> = ["activeProfileId", "activeID", "profiles", "roster", "nativeSync", "nativeHostPreferences", "account", "scope", "ownerProfileId"]
    static let globalBooleans: Set<String> = ["stremiox.autoAddLibrary", "stremiox.directLinksOnly", "stremiox.autoSkip", "stremiox.autoplayTrailers", "stremiox.autoLandscapeInPlayer", "stremiox.keepPlayingInBackground", "stremiox.communityTrickplay", "stremiox.forceSDRTonemap", "vortx.player.badSourceAutoRetry", "vortx.player.bufferTuning", "vortx.player.matchFrameRate", "vortx.player.focusPrefetch", "vortx.player.adaptiveProbe", "vortx.stillWatchingPrompt", "stremiox.catalog.landscapeCards", "stremiox.catalog.hidePosterLabels", "vortx.home.showCuratedRails", "vortx.home.showCollectionsHub", "vortx.discover.showCollectionsHub", "vortx.mergeDiscoverSearch", "vortx.mergeHomeDiscover", "vortx.quickViewEnabled", "vortx.cinema.quickView", "vortx.downloads.autoDeleteWatched", "vortx.detail.showFinancials", "vortx.detail.spoilerSafe", "vortx.spoilerBlur", "stremiox.sync.mirror.addons", "stremiox.sync.mirror.library", "stremiox.sync.mirror.cw"]
    static let globalStrings: Set<String> = ["stremiox.audioOutputMode", "stremiox.performanceMode", "stremiox.videoSize", "stremiox.hdrToneMapMode", "stremiox.player.seekBarStyle", "stremiox.trailerLanguage", "vortx.player.bufferIntent", "stremiox.catalog.posterWidthPreset", "stremiox.catalog.posterRadiusPreset", "vortx.home.layout", "vortx.collections.refreshCadence", "stremiox.languageOverride"]
    static let globalIntegers: Set<String> = ["stremiox.autoSkipDelaySeconds", "vortx.stillWatchingAfterEpisodes"]
    static let globalArrays: Set<String> = ["vortx.home.railOrder", "vortx.home.railHidden"]
    static var knownGlobals: Set<String> { globalBooleans.union(globalStrings).union(globalIntegers).union(globalArrays) }
    static func validGlobal(_ key: String, value: VortxJSON) -> Bool {
        guard knownGlobals.contains(key) else { return false }
        if value == .null { return true }
        if globalBooleans.contains(key), case .bool = value { return true }
        if globalStrings.contains(key), case .string = value { return true }
        if globalIntegers.contains(key), case .integer(let number) = value { return number >= Int32.min && number <= Int32.max }
        return globalArrays.contains(key) && value.array?.allSatisfy { if case .string = $0 { return true }; return false } == true
    }
    static func validActor(_ actor: String) -> Bool { UUID(uuidString: actor)?.uuidString.lowercased() == actor }
    static func canonicalProfileID(_ id: String) -> String {
        guard id.range(of: "\\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\z",
                       options: .regularExpression) != nil else { return id }
        return UUID(uuidString: id)?.uuidString ?? id
    }
    /// Index only: immutable website evidence can use this without rewriting its fingerprint.
    /// Even equal aliases in one document are ambiguous and must never be silently unioned.
    static func profileKeysByCanonicalID<Value>(_ groups: [String: Value]) throws -> [String: String] {
        var keys: [String: String] = [:]
        for id in groups.keys {
            guard !id.isEmpty, keys.updateValue(id, forKey: canonicalProfileID(id)) == nil else {
                throw VortxNativeError.invalidSnapshot
            }
        }
        return keys
    }
    init(scope: VortxAccountScope, actor: String, sealed: Data? = nil) throws {
        guard Self.validActor(actor) else { throw VortxNativeError.invalidSnapshot }
        if let sealed {
            var presentation = try OwnerHistoryExactJSON.Object(sealed)
            presentation.set("document", try Self.typedDocumentData(presentation.required("document")))
            var value = try JSONDecoder().decode(Local.self, from: presentation.encoded())
            guard Self.validActor(value.actor), value.counter <= Self.maxClock else { throw VortxNativeError.invalidSnapshot }
            value.document = try Self.canonicalDocument(value.document, scope: scope)
            try VortxNativeProfileEditHost.validateJournal(value)
            try VortxNativeWebsiteAddonEdits.validateJournal(value)
            if let archive = value.authenticatedSourceArchive {
                try VortxNativeBootstrapArchive.validate(archive)
                try VortxNativeWatchedArchive.validate(archive, scope: scope)
                let source = try JSONDecoder().decode(VortxJSON.self, from: archive)
                _ = try VortxNativeUnattributedOverlayArchive.merge(nil,
                    source["hostDocument"]?[VortxNativeUnattributedOverlayArchive.key], scope: scope)
                let pending = try source["hostDocument"]?[VortxLegacyMembershipReceiptArchive.key].map { try JSONEncoder().encode($0) }
                _ = try VortxLegacyMembershipReceiptArchive.merging(nil, with: pending,
                    scope: scope.account, ownerProfileID: scope.ownerProfileID)
            }
            // The installation supplies its own keychain actor. Never adopt a restored actor.
            value.actor = actor; value.counter = max(value.counter, Self.maximum(value.document)); local = value
        } else { local = Local(actor: actor, counter: 0, document: Document(schemaVersion: 1, scope: scope.account, ownerProfileId: scope.ownerProfileID)) }
        if let sealed {
            let root = try OwnerHistoryExactJSON.Object(sealed)
            rawLocalBase = sealed
            let sourceDocument = try Self.canonicalRawProfileKeys(root.required("document"))
            try Self.validateRawCarrier(sourceDocument)
            rawDocumentBase = sourceDocument
            rawDocumentBaseline = local.document
            rawLocalTypedBaseline = try JSONEncoder().encode(local)
        }
    }
    func encoded() throws -> Data {
        let owned = try OwnerHistoryExactJSON.Object(JSONEncoder().encode(local))
        var result = try OwnerHistoryExactJSON.Object(rawLocalBase ?? Data("{}".utf8))
        let baseline = try rawLocalTypedBaseline.map(OwnerHistoryExactJSON.Object.init)
        for key in ["actor", "counter", "websitePending", "websiteReceipts", "websiteConflicts",
                    "websiteAddonPending", "websiteAddonReceipts", "websiteAddonConflicts", "authenticatedSourceArchive"] {
            if key != "actor", key != "counter", let baseline,
               VortxNativeHostFieldEvidence.json(try baseline[key].map { try JSONDecoder().decode(VortxJSON.self, from: $0) },
                   try owned[key].map { try JSONDecoder().decode(VortxJSON.self, from: $0) }) { continue }
            if let value = owned[key] { result.set(key, value) } else { result.remove(key) }
        }
        result.set("document", try rawDocumentData())
        return try result.encoded()
    }
    mutating func retainAuthenticatedSourceArchive(_ archive: Data?) throws {
        guard let archive else { return }
        try VortxNativeBootstrapArchive.validate(archive)
        let incoming = try JSONDecoder().decode(VortxJSON.self, from: archive)
        guard case .object(let sources) = incoming["hostDocument"]?["ownAccountSources"] else { throw VortxNativeError.invalidSnapshot }
        var retained: [String: VortxJSON] = [:]
        var pending: VortxJSON?
        var pendingMembership: Data?
        var quarantined: VortxJSON?
        if let prior = local.authenticatedSourceArchive {
            let old = try JSONDecoder().decode(VortxJSON.self, from: prior)
            guard case .object(let values) = old["hostDocument"]?["ownAccountSources"] else { throw VortxNativeError.invalidSnapshot }
            retained = values
            pending = old["hostDocument"]?["ownAccountOverlayPending"]
            quarantined = old["hostDocument"]?[VortxNativeUnattributedOverlayArchive.key]
            pendingMembership = try old["hostDocument"]?[VortxLegacyMembershipReceiptArchive.key].map { try JSONEncoder().encode($0) }
        }
        for (id, source) in sources { retained[id] = source }
        if let incomingPending = incoming["hostDocument"]?["ownAccountOverlayPending"] {
            guard case .object = incomingPending else { throw VortxNativeError.invalidSnapshot }
            pending = incomingPending
        }
        let envelope = try VortxNativeBootstrapArchive.mergingRecoveryEnvelope(archive, prior: local.authenticatedSourceArchive)
        let preserved = try JSONDecoder().decode(VortxJSON.self, from: envelope)["hostDocument"]!.decode([String: VortxJSON].self)
        var documentFields = preserved.filter { !VortxNativeBootstrapArchive.managedRecoveryHostKeys.contains($0.key) }
        documentFields["ownAccountSources"] = .object(retained)
        documentFields[VortxNativeUnattributedOverlayArchive.key] = try VortxNativeUnattributedOverlayArchive.merge(
            quarantined, incoming["hostDocument"]?[VortxNativeUnattributedOverlayArchive.key],
            scope: .init(account: local.document.scope, ownerProfileID: local.document.ownerProfileId))
        if let pending { documentFields["ownAccountOverlayPending"] = pending }
        let incomingMembership = try incoming["hostDocument"]?[VortxLegacyMembershipReceiptArchive.key].map { try JSONEncoder().encode($0) }
        if let membership = try VortxLegacyMembershipReceiptArchive.merging(pendingMembership, with: incomingMembership,
                scope: local.document.scope, ownerProfileID: local.document.ownerProfileId) {
            documentFields[VortxLegacyMembershipReceiptArchive.key] = try JSONDecoder().decode(VortxJSON.self, from: membership)
        }
        let document = try JSONEncoder().encode(VortxJSON.object(documentFields))
        let merged = try VortxNativeBootstrapArchive.replacingHostDocument(in: envelope, with: document)
        let scope = VortxAccountScope(account: local.document.scope, ownerProfileID: local.document.ownerProfileId)
        let historical = try VortxNativeWatchedArchive.retaining(merged, prior: local.authenticatedSourceArchive, scope: scope)
        local.authenticatedSourceArchive = try VortxNativeWatchedArchive.retaining(historical, prior: archive, scope: scope)
    }
    /// Compatibility entry point for callers whose source contract is already typed. It
    /// cannot recover original peer bytes. Authentic raw owner-history imports use mergeRaw.
    mutating func merge(_ remote: VortxJSON?, scope: VortxAccountScope) throws {
        guard let remote else { return }
        try mergeRaw(JSONEncoder().encode(remote), scope: scope)
    }
    mutating func edit(profileID: String?, fields: [String: VortxJSON], scope: VortxAccountScope) throws {
        guard !fields.isEmpty else { return }
        if let profileID { guard !profileID.isEmpty else { throw VortxNativeError.invalidSnapshot } }
        let profileID = profileID.map(Self.canonicalProfileID)
        var candidate = local
        candidate.document = try Self.canonicalDocument(candidate.document, scope: scope)
        for name in fields.keys.sorted() {
            try Self.validateField(name, value: fields[name]!, global: profileID == nil)
            guard candidate.counter < Self.maxClock else { throw VortxNativeError.invalidSnapshot }
            candidate.counter += 1
            let value = Register(clock: candidate.counter, actor: candidate.actor, value: fields[name]!)
            if let profileID {
                var current = candidate.document.profiles[profileID] ?? Fields(); current.fields[name] = value; candidate.document.profiles[profileID] = current
            } else { candidate.document.globals.fields[name] = value }
        }
        candidate.document = try Self.canonicalDocument(candidate.document, scope: scope); local = candidate
    }
    static func validateSealed(_ data: Data, scope: VortxAccountScope) throws {
        let value = try OwnerHistoryExactJSON.Object(data)
        _ = try Self(scope: scope, actor: value.text("actor"), sealed: data)
    }
    private static func canonicalDocument(_ document: Document, scope: VortxAccountScope) throws -> Document {
        guard document.schemaVersion == 1, document.scope == scope.account, document.ownerProfileId == scope.ownerProfileID else { throw VortxNativeError.invalidSnapshot }
        let keys = try profileKeysByCanonicalID(document.profiles)
        for fields in document.profiles.values {
            for (name, value) in fields.fields { try validateRegister(name, value: value, global: false) }
        }
        for (name, value) in document.globals.fields { try validateRegister(name, value: value, global: true) }
        var canonical = document
        canonical.profiles = Dictionary(uniqueKeysWithValues: keys.map { ($0.key, document.profiles[$0.value]!) })
        return canonical
    }
    private static func validateRegister(_ name: String, value: Register, global: Bool) throws {
        guard value.clock <= maxClock, validActor(value.actor) else { throw VortxNativeError.invalidSnapshot }
        try validateField(name, value: value.value, global: global)
    }
    private static func validateField(_ name: String, value: VortxJSON, global: Bool) throws {
        if name.hasPrefix(VortxNativePlaylist.prefix) {
            try VortxNativePlaylist.validateEnvelope(name: name, value: value, global: global)
        }
        if !global, name.hasPrefix(VortxNativeWatchlist.prefix) { try VortxNativeWatchlist.validate(name, value: value) }
        if !global, name.hasPrefix(forYouPrefix) { try validateForYouField(name, value: value) }
        let normalized = name.lowercased()
        guard !name.isEmpty, !Set(kernelFields.map { $0.lowercased() }).contains(normalized),
              !Set(reservedGlobals.map { $0.lowercased() }).contains(normalized),
              !normalized.hasPrefix("stremiox.profiles"), !normalized.hasPrefix("vortx.sync."),
              !normalized.hasPrefix("vortx.native."), normalized != "stremiox.activeprofileid",
              !["stremiox.theme.accent", "stremiox.theme.oled", "stremiox.theme.textscale"].contains(normalized)
        else { throw VortxNativeError.invalidSnapshot }
        if global, knownGlobals.contains(name), !validGlobal(name, value: value) { throw VortxNativeError.invalidSnapshot }
        if !global, value != .null {
            // Validate the actual presentation DTO before durable commit. Unknown safe fields
            // remain opaque, but a known field must never poison subsequent profile hydration.
            switch name {
            case "avatar", "email": _ = try value.decode(String.self)
            case "playback": _ = try value.decode(UserProfile.PlaybackPrefs.self)
            case "discovery": _ = try value.decode(ProfileDiscoveryPreferences.self)
            case "addonPreferences": _ = try value.decode(ProfileAddonPreferences.self)
            default: break
            }
        }
        let bytes = try JSONEncoder().encode(VortxJSON.object([name: value]))
        let archive = try VortxNativeBootstrapArchive.encode(document: bytes)
        let parsed = try JSONDecoder().decode(VortxJSON.self, from: archive)
        guard parsed["excludedCredentialPaths"] == .array([]) else { throw VortxNativeError.invalidSnapshot }
    }
    /// The For You namespace: `forYou.interests` and `forYou.collection.<lowercase uuid>` (see
    /// `ForYouSync`). Every received host document is validated register by register and one failure
    /// rejects the whole document, so this checks structure only (known name, object or null, bounded
    /// size); content is decoded leniently where it is read, so a newer app's value can never stop sync.
    static let forYouPrefix = "forYou."
    static let forYouMaxBytes = 16_384
    static func validateForYouField(_ name: String, value: VortxJSON) throws {
        let collectionPrefix = forYouPrefix + "collection."
        let isCollection = name.hasPrefix(collectionPrefix) && {
            let id = String(name.dropFirst(collectionPrefix.count))
            return UUID(uuidString: id)?.uuidString.lowercased() == id
        }()
        guard name == forYouPrefix + "interests" || isCollection else { throw VortxNativeError.invalidSnapshot }
        if value == .null { return }
        guard case .object = value, try JSONEncoder().encode(value).count <= forYouMaxBytes else { throw VortxNativeError.invalidSnapshot }
    }
    private static func maximum(_ document: Document) -> UInt64 {
        (document.globals.fields.values.map(\.clock) + document.profiles.values.flatMap { $0.fields.values.map(\.clock) }).max() ?? 0
    }
    private static func mergeFields(_ left: Fields, _ right: Fields) throws -> Fields {
        var result = left
        for (name, incoming) in right.fields {
            if let old = result.fields[name] {
                if old.clock == incoming.clock && old.actor == incoming.actor {
                    guard old.value == incoming.value else { throw VortxNativeError.invalidSnapshot }
                } else if incoming.clock > old.clock || (incoming.clock == old.clock && incoming.actor > old.actor) { result.fields[name] = incoming }
            } else { result.fields[name] = incoming }
        }
        return result
    }
}

// Raw host carrier retention is app-owned. The exact checkpoint Data is the source; Local
// remains a disposable, validated presentation/journal API for existing host callers.
extension VortxNativeHostPreferences {
    func rawDocumentData() throws -> Data {
        let current = local.document
        guard let rawDocumentBase, let baseline = rawDocumentBaseline else {
            return try JSONEncoder().encode(current)
        }
        var result = try OwnerHistoryExactJSON.Object(rawDocumentBase)
        let typed = try OwnerHistoryExactJSON.Object(JSONEncoder().encode(current))
        for key in ["schemaVersion", "scope", "ownerProfileId"] { result.set(key, try typed.required(key)) }
        result.set("globals", try Self.overlayFields(result["globals"], old: baseline.globals, current: current.globals))
        var profiles = try OwnerHistoryExactJSON.Object(result.required("profiles"))
        for id in Set(baseline.profiles.keys).union(current.profiles.keys) {
            if let fields = current.profiles[id] {
                profiles.set(id, try Self.overlayFields(profiles[id], old: baseline.profiles[id] ?? Fields(), current: fields))
            } else { profiles.remove(id) }
        }
        result.set("profiles", try profiles.encoded())
        return try result.encoded()
    }
    private static func overlayFields(_ raw: Data?, old: Fields, current: Fields) throws -> Data {
        var wrapper = try OwnerHistoryExactJSON.Object(raw ?? Data(#"{"fields":{}}"#.utf8))
        var fields = try OwnerHistoryExactJSON.Object(wrapper.required("fields"))
        for name in Set(old.fields.keys).union(current.fields.keys) {
            if try sameTypedRegister(old.fields[name], current.fields[name]) { continue }
            guard let value = current.fields[name] else { fields.remove(name); continue }
            // Clock/actor/value are owned. Metadata outside those keys survives an edit too.
            var register = try OwnerHistoryExactJSON.Object(fields[name] ?? Data("{}".utf8))
            let owned = try OwnerHistoryExactJSON.Object(JSONEncoder().encode(value))
            for key in ["clock", "actor", "value"] { register.set(key, try owned.required(key)) }
            fields.set(name, try register.encoded())
        }
        wrapper.set("fields", try fields.encoded()); return try wrapper.encoded()
    }
    private static func sameTypedRegister(_ left: Register?, _ right: Register?) throws -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (a?, b?):
            // Register/VortxJSON Equatable deliberately follows Swift String equality;
            // materialization must still observe a byte-distinct NFC/NFD edit.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(a) == encoder.encode(b)
        default: return false
        }
    }
    /// Unknown Xperience formats remain raw even if their payload has a valid JSON number
    /// outside VortxJSON's range. A null shadow is presentation only, never a tombstone in
    /// rawDocumentData. Other families retain their existing typed admission behavior.
    private static func typedRegisterData(_ bytes: Data, name: String) throws -> Data {
        guard name.hasPrefix("xperience.import.") else { return bytes }
        var register = try OwnerHistoryExactJSON.Object(bytes)
        let value = try register.required("value")
        if (try? JSONDecoder().decode(VortxJSON.self, from: value)) == nil {
            register.set("value", Data("null".utf8)); return try register.encoded()
        }
        return bytes
    }
    private static func typedDocumentData(_ bytes: Data) throws -> Data {
        var document = try OwnerHistoryExactJSON.Object(bytes)
        var profiles = try OwnerHistoryExactJSON.Object(document.required("profiles"))
        for (id, bytes) in profiles.fields {
            var wrapper = try OwnerHistoryExactJSON.Object(bytes)
            var fields = try OwnerHistoryExactJSON.Object(wrapper.required("fields"))
            for (name, value) in fields.fields where name.hasPrefix("xperience.import.") {
                fields.set(name, try typedRegisterData(value, name: name))
            }
            wrapper.set("fields", try fields.encoded()); profiles.set(id, try wrapper.encoded())
        }
        document.set("profiles", try profiles.encoded()); return try document.encoded()
    }
    private static func canonicalRawProfileKeys(_ bytes: Data) throws -> Data {
        var document = try OwnerHistoryExactJSON.Object(bytes)
        let original = try OwnerHistoryExactJSON.Object(document.required("profiles"))
        let keys = try profileKeysByCanonicalID(original.fields)
        var profiles = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        for (canonical, originalKey) in keys { profiles.set(canonical, try original.required(originalKey)) }
        document.set("profiles", try profiles.encoded()); return try document.encoded()
    }
    /// Merge complete raw registers. Equal clock+actor with different complete evidence is
    /// contradictory; never choose a first match or reconcile unknown payload members.
    mutating func mergeRaw(_ remote: Data?, scope: VortxAccountScope) throws {
        guard let remote else { return }
        let normalized = try Self.canonicalRawProfileKeys(remote)
        try Self.validateRawCarrier(normalized)
        let incoming = try Self.canonicalDocument(JSONDecoder().decode(Document.self, from: Self.typedDocumentData(normalized)), scope: scope)
        var left = try OwnerHistoryExactJSON.Object(rawDocumentData())
        let right = try OwnerHistoryExactJSON.Object(normalized)
        try Self.retainUnknown(from: right, in: &left, owned: ["schemaVersion", "scope", "ownerProfileId", "profiles", "globals"])
        left.set("globals", try Self.mergeRawFields(left.required("globals"), right.required("globals")))
        var profiles = try OwnerHistoryExactJSON.Object(left.required("profiles"))
        let remoteProfiles = try OwnerHistoryExactJSON.Object(right.required("profiles"))
        for (id, group) in remoteProfiles.fields {
            if let previous = profiles[id] { profiles.set(id, try Self.mergeRawFields(previous, group)) }
            else { profiles.set(id, group) }
        }
        left.set("profiles", try profiles.encoded())
        let joined = try left.encoded()
        local.document = try Self.canonicalDocument(JSONDecoder().decode(Document.self, from: Self.typedDocumentData(joined)), scope: scope)
        local.counter = max(local.counter, max(Self.maximum(incoming), Self.maximum(local.document)))
        rawDocumentBase = joined; rawDocumentBaseline = local.document
    }
    private static func retainUnknown(from source: OwnerHistoryExactJSON.Object,
                                      in target: inout OwnerHistoryExactJSON.Object, owned: Set<String>) throws {
        for (key, value) in source.fields where !owned.contains(key) {
            if let old = target[key] {
                guard VortxRawHostRegister.sameValue(old, value) else {
                    throw VortxNativeError.invalidSnapshot
                }
            } else { target.set(key, value) }
        }
    }
    private static func mergeRawFields(_ previous: Data, _ incoming: Data) throws -> Data {
        var left = try OwnerHistoryExactJSON.Object(previous)
        let right = try OwnerHistoryExactJSON.Object(incoming)
        try retainUnknown(from: right, in: &left, owned: ["fields"])
        var fields = try OwnerHistoryExactJSON.Object(left.required("fields"))
        let remote = try OwnerHistoryExactJSON.Object(right.required("fields"))
        for (name, bytes) in remote.fields {
            let value = try JSONDecoder().decode(Register.self, from: typedRegisterData(bytes, name: name))
            if let old = fields[name] {
                let prior = try JSONDecoder().decode(Register.self, from: typedRegisterData(old, name: name))
                if prior.clock == value.clock && prior.actor == value.actor {
                    guard VortxRawHostRegister.sameValue(old, bytes) else {
                        throw VortxNativeError.invalidSnapshot
                    }
                } else if value.clock > prior.clock || (value.clock == prior.clock && value.actor > prior.actor) {
                    fields.set(name, bytes)
                }
            } else { fields.set(name, bytes) }
        }
        left.set("fields", try fields.encoded()); return try left.encoded()
    }
    /// One new Xperience value with complete original-register metadata retained. The DTO is
    /// used only for existing reserved-name/credential/schema admission, never as saved bytes.
    mutating func editRaw(profileID: String, field: String, value: Data, scope: VortxAccountScope) throws {
        guard field.hasPrefix("xperience.import.") else { throw VortxNativeError.invalidSnapshot }
        let presentation = try JSONDecoder().decode(VortxJSON.self, from: value)
        try VortxRawHostRegister.validateValue(field: field, bytes: value)
        var document = try OwnerHistoryExactJSON.Object(rawDocumentData())
        var profiles = try OwnerHistoryExactJSON.Object(document.required("profiles"))
        let id = Self.canonicalProfileID(profileID)
        var wrapper = try OwnerHistoryExactJSON.Object(profiles[id] ?? Data(#"{"fields":{}}"#.utf8))
        var fields = try OwnerHistoryExactJSON.Object(wrapper.required("fields"))
        var register = try OwnerHistoryExactJSON.Object(fields[field] ?? Data("{}".utf8))
        try edit(profileID: id, fields: [field: presentation], scope: scope)
        guard let authored = local.document.profiles[id]?.fields[field] else { throw VortxNativeError.invalidSnapshot }
        register.set("clock", try JSONEncoder().encode(authored.clock))
        register.set("actor", try OwnerHistoryExactJSON.string(authored.actor)); register.set("value", value)
        fields.set(field, try register.encoded()); wrapper.set("fields", try fields.encoded())
        profiles.set(id, try wrapper.encoded()); document.set("profiles", try profiles.encoded())
        rawDocumentBase = try document.encoded(); rawDocumentBaseline = local.document
    }
}

extension VortxRawHostRegister {
    static let maximumEvidenceWorkspace = 256 * 1024 * 1024
    /// ExactJSON validates grammar/depth separately. This linear lexical walk charges
    /// 32 bytes per source byte plus 8 for every enclosing container: a conservative
    /// bound on recursive scan/copy work before entering its cold canonicalizer. It is
    /// a work reservation, not a measured allocator/RSS or performance claim.
    static func boundedCanonical(_ bytes: Data) throws -> Data? {
        guard bytes.count <= OwnerHistoryExactJSON.maximumBytes else { throw OwnerHistoryExactJSON.Failure.excessive }
        var depth = 0, quoted = false, escaped = false, reservation = 0
        for byte in bytes {
            if !quoted && (byte == 123 || byte == 91) { depth += 1 }
            let charge = 32 + 8 * max(1, depth)
            guard reservation <= maximumEvidenceWorkspace - charge else { return nil }
            reservation += charge
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        return try OwnerHistoryExactJSON.canonical(bytes)
    }
    static func sameValue(_ left: Data, _ right: Data) -> Bool {
        if left == right { return true }
        guard let a = try? boundedCanonical(left), let b = try? boundedCanonical(right) else { return false }
        return a == b
    }
    static func prepared(_ bytes: Data) throws -> Self {
        var register = try OwnerHistoryExactJSON.Object(bytes)
        let value = try register.required("value")
        for key in ["clock", "actor", "value"] { register.remove(key) }
        return .init(bytes: bytes, canonical: (try? boundedCanonical(bytes)) ?? nil,
            value: value, canonicalValue: (try? boundedCanonical(value)) ?? nil,
            metadata: (try? boundedCanonical(register.encoded())) ?? nil)
    }
    static func validateValue(field: String, bytes: Data) throws {
        guard try boundedCanonical(bytes) != nil else { throw OwnerHistoryExactJSON.Failure.excessive }
        try validateCarrierField(field: field, bytes: bytes)
    }
    static func validateCarrierField(field: String, bytes: Data) throws {
        // Use the EXISTING credential policy on the genuine raw field/complete register.
        // Its output is discarded; it is an unsafe-path detector, never saved source data.
        var source = try OwnerHistoryExactJSON.Object(Data("{}".utf8)); source.set(field, bytes)
        let archive = try VortxNativeBootstrapArchive.encode(document: source.encoded())
        let inspected = try JSONDecoder().decode(VortxJSON.self, from: archive)
        guard inspected["excludedCredentialPaths"] == .array([]) else { throw VortxNativeError.invalidSnapshot }
    }
}

extension VortxNativeHostPreferences {
    static func validatedLocal(_ bytes: Data, scope: VortxAccountScope) throws -> Local {
        let root = try OwnerHistoryExactJSON.Object(bytes)
        return try Self(scope: scope, actor: root.text("actor"), sealed: bytes).local
    }
    private static func validateRawCarrier(_ bytes: Data) throws {
        // New raw members acquire the same credential-free carrier policy as owned values.
        // Inspect the genuine complete host document, including unknown wrapper/register
        // metadata; never use a lossy shadow to decide whether a secret path was excluded.
        let archive = try VortxNativeBootstrapArchive.encode(document: bytes)
        let inspected = try JSONDecoder().decode(VortxJSON.self, from: archive)
        guard inspected["excludedCredentialPaths"] == .array([]) else { throw VortxNativeError.invalidSnapshot }
    }
    /// Prepared before facade publication, not while a final mutation authority is locked.
    func rawProfileRegisters() throws -> [String: [String: VortxRawHostRegister]] {
        let document = try OwnerHistoryExactJSON.Object(rawDocumentData())
        let profiles = try OwnerHistoryExactJSON.Object(document.required("profiles"))
        var result: [String: [String: VortxRawHostRegister]] = [:]
        for (id, bytes) in profiles.fields {
            let group = try OwnerHistoryExactJSON.Object(bytes)
            let fields = try OwnerHistoryExactJSON.Object(group.required("fields"))
            // Existing typed callers keep their existing admission. Only this family needs
            // raw evidence publication; opaque unrelated values are retained in the carrier.
            result[id] = try fields.fields.filter { $0.key.hasPrefix("xperience.import.") }
                .mapValues(VortxRawHostRegister.prepared)
        }
        return result
    }
}
