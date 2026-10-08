import Foundation

/// Public, credential-free host preference carrier. Kernel-owned fields remain in nativeSync.
struct VortxNativeHostPreferences: Sendable {
    static let maxClock: UInt64 = 9_007_199_254_740_991
    struct Register: Codable, Equatable, Sendable { let clock: UInt64; let actor: String; let value: VortxJSON }
    struct Fields: Codable, Equatable, Sendable { var fields: [String: Register] = [:] }
    struct Document: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let scope: String
        let ownerProfileId: String
        var profiles: [String: Fields] = [:]
        var globals = Fields()
    }
    struct Local: Codable, Sendable { var actor: String; var counter: UInt64; var document: Document }
    struct Edit: Sendable { let profileID: String?; let fields: [String: VortxJSON] }
    var local: Local
    var document: VortxJSON { get throws { try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(local.document)) } }
    private static let kernelFields: Set<String> = ["id", "name", "isOwner", "pin", "isKids", "familyEdit", "accentID", "oled", "textScale", "disabledAddons", "usesOwnAccount", "account", "addons", "settings", "parental", "rev", "updatedAt", "deleted"]
    private static let reservedGlobals: Set<String> = ["activeProfileId", "activeID", "profiles", "roster", "nativeSync", "nativeHostPreferences", "account", "scope", "ownerProfileId"]
    static let globalBooleans: Set<String> = ["stremiox.autoAddLibrary", "stremiox.directLinksOnly", "stremiox.autoSkip", "stremiox.autoplayTrailers", "stremiox.autoLandscapeInPlayer", "stremiox.keepPlayingInBackground", "stremiox.communityTrickplay", "stremiox.forceSDRTonemap", "vortx.player.badSourceAutoRetry", "vortx.player.bufferTuning", "vortx.player.matchFrameRate", "vortx.player.focusPrefetch", "vortx.player.adaptiveProbe", "vortx.stillWatchingPrompt", "stremiox.catalog.landscapeCards", "stremiox.catalog.hidePosterLabels", "vortx.home.showCuratedRails", "vortx.home.showCollectionsHub", "vortx.discover.showCollectionsHub", "vortx.mergeDiscoverSearch", "vortx.detail.showFinancials", "vortx.detail.spoilerSafe", "vortx.spoilerBlur", "stremiox.sync.mirror.addons", "stremiox.sync.mirror.library", "stremiox.sync.mirror.cw"]
    static let globalStrings: Set<String> = ["stremiox.audioOutputMode", "stremiox.performanceMode", "stremiox.videoSize", "stremiox.hdrToneMapMode", "stremiox.player.seekBarStyle", "stremiox.trailerLanguage", "vortx.player.bufferIntent", "stremiox.catalog.posterWidthPreset", "stremiox.catalog.posterRadiusPreset", "vortx.home.layout", "vortx.collections.refreshCadence", "stremiox.languageOverride"]
    static let globalIntegers: Set<String> = ["stremiox.autoSkipDelaySeconds", "vortx.stillWatchingAfterEpisodes"]
    static let globalArrays: Set<String> = ["vortx.home.railOrder", "vortx.home.railHidden"]
    static var knownGlobals: Set<String> { globalBooleans.union(globalStrings).union(globalIntegers).union(globalArrays) }
    static func validGlobal(_ key: String, value: VortxJSON) -> Bool {
        guard knownGlobals.contains(key) else { return false }
        if value == .null { return true }
        if globalBooleans.contains(key), case .bool = value { return true }
        if globalStrings.contains(key), case .string = value { return true }
        if globalIntegers.contains(key), case .integer = value { return true }
        return globalArrays.contains(key) && value.array?.allSatisfy { if case .string = $0 { return true }; return false } == true
    }
    static func validActor(_ actor: String) -> Bool { UUID(uuidString: actor)?.uuidString.lowercased() == actor }
    init(scope: VortxAccountScope, actor: String, sealed: Data? = nil) throws {
        guard Self.validActor(actor) else { throw VortxNativeError.invalidSnapshot }
        if let sealed {
            var value = try JSONDecoder().decode(Local.self, from: sealed)
            guard Self.validActor(value.actor), value.counter <= Self.maxClock else { throw VortxNativeError.invalidSnapshot }
            try Self.validate(value.document, scope: scope)
            // The installation supplies its own keychain actor. Never adopt a restored actor.
            value.actor = actor; value.counter = max(value.counter, Self.maximum(value.document)); local = value
        } else { local = Local(actor: actor, counter: 0, document: Document(schemaVersion: 1, scope: scope.account, ownerProfileId: scope.ownerProfileID)) }
    }
    func encoded() throws -> Data { try JSONEncoder().encode(local) }
    mutating func merge(_ remote: VortxJSON?, scope: VortxAccountScope) throws {
        guard let remote else { return }
        guard case .object(let keys) = remote, Set(keys.keys) == ["schemaVersion", "scope", "ownerProfileId", "profiles", "globals"] else { throw VortxNativeError.invalidSnapshot }
        guard case .object(let profiles) = remote["profiles"] else { throw VortxNativeError.invalidSnapshot }
        for group in Array(profiles.values) + [remote["globals"]!] {
            guard case .object(let wrapper) = group, Set(wrapper.keys) == ["fields"], case .object(let fields) = wrapper["fields"] else { throw VortxNativeError.invalidSnapshot }
            for register in fields.values {
                guard case .object(let values) = register, Set(values.keys) == ["clock", "actor", "value"] else { throw VortxNativeError.invalidSnapshot }
            }
        }
        let incoming = try remote.decode(Document.self)
        try Self.validate(incoming, scope: scope)
        var candidate = local.document
        candidate.globals = try Self.mergeFields(candidate.globals, incoming.globals)
        for (id, fields) in incoming.profiles { candidate.profiles[id] = try Self.mergeFields(candidate.profiles[id] ?? Fields(), fields) }
        local.document = candidate; local.counter = max(local.counter, Self.maximum(candidate))
    }
    mutating func edit(profileID: String?, fields: [String: VortxJSON], scope: VortxAccountScope) throws {
        guard !fields.isEmpty else { return }
        if let profileID { guard !profileID.isEmpty else { throw VortxNativeError.invalidSnapshot } }
        var candidate = local
        for name in fields.keys.sorted() {
            try Self.validateField(name, value: fields[name]!, global: profileID == nil)
            guard candidate.counter < Self.maxClock else { throw VortxNativeError.invalidSnapshot }
            candidate.counter += 1
            let value = Register(clock: candidate.counter, actor: candidate.actor, value: fields[name]!)
            if let profileID {
                var current = candidate.document.profiles[profileID] ?? Fields(); current.fields[name] = value; candidate.document.profiles[profileID] = current
            } else { candidate.document.globals.fields[name] = value }
        }
        try Self.validate(candidate.document, scope: scope); local = candidate
    }
    static func validateSealed(_ data: Data, scope: VortxAccountScope) throws {
        let value = try JSONDecoder().decode(Local.self, from: data)
        _ = try Self(scope: scope, actor: value.actor, sealed: data)
    }
    private static func validate(_ document: Document, scope: VortxAccountScope) throws {
        guard document.schemaVersion == 1, document.scope == scope.account, document.ownerProfileId == scope.ownerProfileID else { throw VortxNativeError.invalidSnapshot }
        for (id, fields) in document.profiles {
            guard !id.isEmpty else { throw VortxNativeError.invalidSnapshot }
            for (name, value) in fields.fields { try validateRegister(name, value: value, global: false) }
        }
        for (name, value) in document.globals.fields { try validateRegister(name, value: value, global: true) }
    }
    private static func validateRegister(_ name: String, value: Register, global: Bool) throws {
        guard value.clock <= maxClock, validActor(value.actor) else { throw VortxNativeError.invalidSnapshot }
        try validateField(name, value: value.value, global: global)
    }
    private static func validateField(_ name: String, value: VortxJSON, global: Bool) throws {
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
