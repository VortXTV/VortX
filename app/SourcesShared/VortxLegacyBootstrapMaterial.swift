import Foundation
import CoreFoundation
import CryptoKit

/// Pure projection of a COMPLETE, authenticated, host-reconciled legacy account snapshot.
/// The caller supplies the resolved roster and actual owner UUID, and must atomically retain the
/// original encrypted document (including all preferences and unknown fields) beside the native
/// checkpoint and import receipt. This projection is never a replacement for that source document.
/// It does not read a profile store, credentials, defaults, the network, or the wall clock.
enum VortxLegacyBootstrapMaterial {
    struct ReconciliationRequired: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "Native migration reconciliation required: " + reason }
    }

    /// A caller-owned, server-authenticated source receipt for one secondary profile's independent
    /// streaming account. The caller must keep its credential-generation proof private; neither a
    /// token nor a token-derived fingerprint may enter this value or the native material.
    struct OwnAccountSource: Sendable, Equatable {
        let profileID: UUID
        let verifiedStreamingUID: String
        let sourceDocument: Data
        let profileOverlaySHA256: String?

        init(profileID: UUID, verifiedStreamingUID: String, sourceDocument: Data, profileOverlaySHA256: String? = nil) {
            self.profileID = profileID
            self.verifiedStreamingUID = verifiedStreamingUID
            self.sourceDocument = sourceDocument
            self.profileOverlaySHA256 = profileOverlaySHA256
        }

        var sourceDocumentSHA256: String {
            SHA256.hash(data: sourceDocument).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// An exact, token-free own-source envelope retained by the authenticated host archive.  It is
    /// usable only to prove that a current UUID-scoped root overlay is the same overlay already
    /// bound into a kernel-validated retained tuple; it never creates a new source assertion.
    struct RetainedOwnAccountSourceEnvelope: Sendable, Equatable {
        let profileID: UUID
        let sourceDocument: Data

        init(profileID: UUID, sourceDocument: Data) {
            self.profileID = profileID
            self.sourceDocument = sourceDocument
        }

        fileprivate var sourceDocumentSHA256: String {
            SHA256.hash(data: sourceDocument).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A Sendable UTF-8 JSON result that can cross the caller's authentication/MainActor boundary.
    /// The result is the `material` member of `import_legacy_sync`, not a runtime or sync document.
    ///
    /// `profileEdits` is an authenticated, independently reconciled website authority channel. A
    /// caller that has retained and will process that channel separately may defer only its
    /// material-side reconciliation check; the edits themselves never enter this projection.
    /// The default remains strict so ordinary legacy imports cannot acknowledge pending edits.
    /// `retainedOwnAccountBaseline` is accepted only from the authenticated nativeSync helper after
    /// it has detached-merged and validated a nativeSync 3 / legacyImport 2 receipt. It is the
    /// exact `legacyImport.baseline` material 2 bytes, never an engine snapshot or raw source.
    static func encode(document: Data, roster: [UserProfile], ownerProfileID: UUID,
                       rosterModifiedSeconds: Double?, deferProfileEdits: Bool = false,
                       ownAccountSources: [OwnAccountSource] = [], retainedOwnAccountBaseline: Data? = nil,
                       retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope] = []) throws -> Data {
        guard let source = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw ReconciliationRequired(reason: "Account document must be an object")
        }
        let adapter = try Adapter(document: source, roster: roster, ownerID: ownerProfileID,
                                  modified: rosterModifiedSeconds, deferProfileEdits: deferProfileEdits)
        return try JSONSerialization.data(withJSONObject: adapter.build(ownAccountSources: ownAccountSources,
                                                                         retainedOwnAccountBaseline: retainedOwnAccountBaseline,
                                                                         retainedOwnAccountSourceEnvelopes: retainedOwnAccountSourceEnvelopes), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private final class Adapter {
        typealias Object = [String: Any]
        let document: Object
        let vortx: Object
        let roster: [UserProfile]
        let owner: UserProfile
        let modified: Double?
        let profiles: [String: UserProfile]
        let deferProfileEdits: Bool
        let independentSource: Bool
        var deleted = Set<String>()
        var watches: [String: [Object]] = [:]
        var titles: [String: [String: Object]] = [:]

        init(document: Object, roster: [UserProfile], ownerID: UUID, modified: Double?,
             deferProfileEdits: Bool, allowIndependentSource: Bool = false) throws {
            self.document = document
            self.vortx = try object(document, "vortx") ?? [:]
            self.roster = roster
            self.modified = modified
            self.deferProfileEdits = deferProfileEdits
            self.independentSource = allowIndependentSource
            try require(!roster.isEmpty && Set(roster.map(\.id)).count == roster.count, "Duplicate or empty profile roster")
            let owners = roster.filter(\.isOwner)
            if allowIndependentSource {
                try require(roster.count == 1 && roster[0].id == ownerID,
                            "Independent account source must bind exactly one profile")
                self.owner = roster[0]
            } else {
                try require(owners.count == 1 && owners[0].id == ownerID, "A unique resolved owner UUID is required")
                self.owner = owners[0]
            }
            profiles = Dictionary(uniqueKeysWithValues: roster.map { ($0.id.uuidString, $0) })
        }

        func build(ownAccountSources: [OwnAccountSource], retainedOwnAccountBaseline: Data?,
                   retainedOwnAccountSourceEnvelopes: [RetainedOwnAccountSourceEnvelope]) throws -> Object {
            if let modified { _ = try validClock(modified, "rosterModifiedSeconds") }
            // The native `own` binding represents a secondary independently authenticated
            // streaming persona. The resolved primary owner remains local-only, never silently
            // downgraded from an impossible owner-owned source claim.
            try require(!roster.contains { $0.isOwner && $0.usesOwnAccount },
                        "Owner profile cannot use an independent streaming account")
            deleted = Set(try strings(vortx, "deletedProfiles").map { raw in
                guard let id = UUID(uuidString: raw) else { throw fail("Invalid deleted profile identity") }
                return id.uuidString
            })
            try require(!deleted.contains(owner.id.uuidString), "Owner profile is tombstoned")
            let sources = try resolveOwnAccountSources(ownAccountSources, retainedBaseline: retainedOwnAccountBaseline,
                                                        retainedSourceEnvelopes: retainedOwnAccountSourceEnvelopes)
            for profile in roster {
                watches[profile.id.uuidString] = []
                titles[profile.id.uuidString] = [:]
            }
            let nativeRoster = try roster.map { try projectProfile($0, ownSource: sources[$0.id.uuidString]) }
            let addons = try addonBucket()
            let library = try ownerLibrary()
            try validateOwnProfileOverlayBindings(sources)
            // An independent source owns its profile's overlay context. Avoid parsing the root
            // bucket first: watched-only rows can rely on metadata in that independent library,
            // and accepting then overwriting them would make a stale root slice authoritative.
            try importOverlays(excluding: Set(sources.keys))
            try importOwnerIntents()
            if !deferProfileEdits { try validateProfileEdits(ownerLibrary: library) }
            var addonBuckets: [String: Object] = [owner.id.uuidString: addons]
            var libraryBuckets: [String: Object] = [owner.id.uuidString: library]
            var ownSourceMaterial: [String: Object] = [:]
            var identityLinks = Dictionary(uniqueKeysWithValues: roster.map { ($0.id.uuidString, [[String]]()) })
            var retainedWatchProfiles = Set<String>()
            for (profileID, source) in sources {
                let buckets = try source.buckets()
                addonBuckets[profileID] = buckets.addons
                libraryBuckets[profileID] = buckets.library
                watches[profileID] = buckets.watches
                titles[profileID] = buckets.titles
                identityLinks[profileID] = buckets.identityLinks
                if source.isRetained { retainedWatchProfiles.insert(profileID) }
                var proof: Object = ["verifiedStreamingUid": source.verifiedStreamingUID, "sourceDocumentSha256": source.sourceDocumentSHA256]
                if let witness = source.profileOverlaySHA256 { proof["profileOverlaySha256"] = witness }
                ownSourceMaterial[profileID] = proof
            }
            var result: Object = [
                "schemaVersion": sources.isEmpty ? 1 : 2, "roster": nativeRoster, "deletedProfileIds": deleted.sorted(),
                "addons": addonBuckets, "libraries": libraryBuckets,
                "watches": try Dictionary(uniqueKeysWithValues: watches.map { profileID, rows in
                    (profileID, retainedWatchProfiles.contains(profileID) ? rows : try resolveWatches(rows))
                }),
                // Removal keys do not establish an IMDb/TMDB equivalence edge. The caller must
                // reconcile such aliases explicitly; this adapter never guesses an identity link.
                "identityLinks": identityLinks
            ]
            if !ownSourceMaterial.isEmpty { result["ownAccountSources"] = ownSourceMaterial }
            if let modified { result["rosterModifiedSeconds"] = modified }
            try rejectCredentials(result)
            return result
        }

        private func projectProfile(_ profile: UserProfile, ownSource: ResolvedOwnAccountSource?) throws -> Object {
            try require(profile.textScale.isFinite && profile.textScale > 0 && profile.textScale <= 100,
                        "Invalid profile text scale")
            let inherited = owner.addonPreferences?.disabledAddonURLsOverride ?? owner.disabledAddons ?? []
            // Follow the shipping profile policy without consulting the active profile/defaults.
            let disabled = profile.addonPreferences?.disabledAddonURLsOverride
                ?? (profile.addonPreferences == nil ? profile.disabledAddons : nil)
                ?? (profile.isOwner ? profile.disabledAddons ?? [] : inherited)
            let languages = unique([profile.playback?.audioLang, profile.playback?.subtitleLang].compactMap { $0 }.filter { !$0.isEmpty })
            var settings: Object = ["accent": profile.accentID, "oled": profile.oled,
                                    "textScale": Int((profile.textScale * 1000).rounded()),
                                    "languages": languages, "disabledAddons": unique(try disabled.map(normalizeURL))]
            if let playback = profile.playback {
                var ranking: Object = ["preferred_languages": unique(terms(playback.audioLang)).sorted()]
                if let resolution = playback.maxResolution, resolution != 0 {
                    let values = [480: "480p", 720: "720p", 1080: "1080p", 2160: "2160p", 4000: "2160p"]
                    guard let value = values[resolution] else { throw fail("Unsupported profile resolution cap") }
                    ranking["max_resolution"] = value
                }
                if let size = playback.maxFileSizeGB {
                    try require(size.isFinite && size >= 0, "Invalid profile file-size cap")
                    if size > 0 { ranking["max_filesize_gb"] = size }
                }
                // Transport classes (debrid/torrent/etc.) are NOT native quality classes
                // (remux/web/etc.). Transport order, regex filters, and UI overrides remain in the
                // adjacent full roster; only directly compatible native fields are projected here.
                if playback.keywordsAreRegex != true {
                    ranking["keyword_include"] = terms(playback.includeKeywords)
                    if playback.avoidBehavior != "rank" { ranking["keyword_exclude"] = terms(playback.excludeKeywords) }
                }
                settings["ranking"] = ranking
            }
            let account: Object
            let addons: String
            if let ownSource {
                account = ["kind": "own", "value": ownSource.verifiedStreamingUID]
                addons = "own"
            } else {
                account = profile.isOwner ? ["kind": "local_only"] : ["kind": "shared", "value": owner.id.uuidString]
                addons = "share_primary"
            }
            var result: Object = ["id": profile.id.uuidString, "name": profile.name, "owner": profile.isOwner,
                                  "account": account, "addons": addons, "settings": settings,
                                  "parental": ["kids": profile.isKids, "familyEdit": profile.familyEdit]]
            if let pin = profile.pin, !pin.isEmpty {
                try require(pin.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                            "Legacy plaintext or malformed PIN requires explicit reconciliation")
                result["pin"] = pin
            }
            return result
        }

        private struct OwnAccountBuckets {
            let addons: Object
            let library: Object
            let watches: [Object]
            let titles: [String: Object]
            let identityLinks: [[String]]
        }

        private struct ResolvedOwnAccountSource {
            let profileID: String
            let verifiedStreamingUID: String
            let sourceDocumentSHA256: String
            let profileOverlaySHA256: String?
            let sourceDocument: Object?
            let retainedBuckets: OwnAccountBuckets?
            var isRetained: Bool { retainedBuckets != nil }

            func buckets() throws -> OwnAccountBuckets {
                if let retainedBuckets { return retainedBuckets }
                guard let sourceDocument else { throw fail("Missing own-account source material") }
                // An independently authenticated account has the same root membership/history
                // carriers as the primary account, but never borrows root-document data from the
                // profile roster's account. Its envelope carries only the authenticated, exact
                // UUID-scoped overlay slice when that profile has durable local intents.
                let profile = UserProfile(id: UUID(uuidString: profileID)!, name: "Independent", avatar: "🍿")
                let adapter = try Adapter(independentSource: sourceDocument, profile: profile)
                adapter.watches[profileID] = []
                adapter.titles[profileID] = [:]
                let addons = try adapter.addonBucket()
                let library = try adapter.ownerLibrary()
                try adapter.importOverlays()
                try adapter.validateProfileEdits(ownerLibrary: library)
                return OwnAccountBuckets(addons: addons, library: library,
                                         watches: try VortxLegacyBootstrapMaterial.resolveWatches(adapter.watches[profileID] ?? []),
                                         titles: adapter.titles[profileID] ?? [:], identityLinks: [])
            }
        }

        /// The authenticated producer retains the exact datastore and add-on response bodies inside
        /// this small envelope.  The source digest covers the envelope bytes, not a host-reserialized
        /// projection; parsing below creates a private compatibility view only after that proof.
        private static func decodeOwnAccountEnvelope(_ source: Data, profileID: String) throws -> Object {
            guard let envelope = try JSONSerialization.jsonObject(with: source) as? Object,
                  Set(envelope.keys) == ["schemaVersion", "libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64"],
                  let version = envelope["schemaVersion"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), (version.intValue == 1 || version.intValue == 2),
                  Double(version.intValue) == version.doubleValue,
                  let libraryBase64 = envelope["libraryResponseBase64"] as? String,
                  let addonsBase64 = envelope["addonsResponseBase64"] as? String,
                  let overlayBase64 = envelope["profileOverlayBase64"] as? String,
                  let libraryBytes = Data(base64Encoded: libraryBase64),
                  let addonBytes = Data(base64Encoded: addonsBase64),
                  let overlayBytes = Data(base64Encoded: overlayBase64),
                  libraryBytes.base64EncodedString() == libraryBase64,
                  addonBytes.base64EncodedString() == addonsBase64,
                  overlayBytes.base64EncodedString() == overlayBase64,
                  let libraryEnvelope = try JSONSerialization.jsonObject(with: libraryBytes) as? Object,
                  let addonEnvelope = try JSONSerialization.jsonObject(with: addonBytes) as? Object,
                  let overlay = try JSONSerialization.jsonObject(with: overlayBytes) as? Object,
                  (Set(libraryEnvelope.keys) == ["result"] ||
                    (Set(libraryEnvelope.keys) == ["result", "error"] && libraryEnvelope["error"] is NSNull)),
                  (Set(addonEnvelope.keys) == ["result"] ||
                    (Set(addonEnvelope.keys) == ["result", "error"] && addonEnvelope["error"] is NSNull)),
                  let libraryRows = libraryEnvelope["result"] as? [Any],
                  let addonResult = addonEnvelope["result"] as? Object,
                  Set(addonResult.keys) == ["addons"],
                  let addons = addonResult["addons"] as? [Any] else {
                throw fail("Own-account source envelope requires exact library and add-on responses")
            }
            try VortxLegacyBootstrapMaterial.rejectCredentials(envelope)
            try VortxLegacyBootstrapMaterial.rejectCredentials(libraryEnvelope)
            try VortxLegacyBootstrapMaterial.rejectCredentials(addonEnvelope)
            try VortxLegacyBootstrapMaterial.rejectCredentials(overlay)
            let rows = try libraryRows.map(projectOwnLibraryRow)
            let descriptors = try addons.map { raw -> Object in
                guard let descriptor = raw as? Object else { throw fail("Malformed own-account add-on descriptor") }
                _ = try string(descriptor, "transportUrl")
                guard let manifest = try object(descriptor, "manifest") else { throw fail("Own-account add-on requires a manifest") }
                _ = try string(manifest, "id"); _ = try string(manifest, "name"); _ = try string(manifest, "version")
                return descriptor
            }
            var vortx: Object = ["library": rows, "addons": descriptors]
            var document: Object = ["vortx": vortx,
                                    "addonOrder": try descriptors.map { try string($0, "transportUrl") }]
            guard Set(overlay.keys).isSubset(of: ["vortx", "webProgress"]) else {
                throw fail("Own-account overlay has unsupported source carrier")
            }
            if let rawVortx = try object(overlay, "vortx") {
                guard Set(rawVortx.keys) == ["byProfile"],
                      let byProfile = try object(rawVortx, "byProfile"),
                      Set(byProfile.keys) == [profileID],
                      byProfile[profileID] is Object else {
                    throw fail("Own-account overlay must be scoped to its authenticated profile")
                }
                vortx["byProfile"] = byProfile
                document["vortx"] = vortx
            }
            if let rawProgress = try object(overlay, "webProgress") {
                guard Set(rawProgress.keys) == ["removed"],
                      let removed = try object(rawProgress, "removed"),
                      Set(removed.keys) == ["byProfile"],
                      let byProfile = try object(removed, "byProfile"),
                      Set(byProfile.keys) == [profileID],
                      byProfile[profileID] is [Any] else {
                    throw fail("Own-account overlay removals must be scoped to its authenticated profile")
                }
                document["webProgress"] = ["removed": ["byProfile": byProfile]]
            }
            return document
        }

        private static func projectOwnLibraryRow(_ raw: Any) throws -> Object {
            guard let row = raw as? Object else { throw fail("Malformed own-account library row") }
            let id = try string(row, "_id")
            let type = try contentType(row)
            var projected: Object = ["id": id, "type": type]
            if let name = try optionalString(row, "name") { projected["name"] = name }
            if let poster = try optionalString(row, "poster") { projected["poster"] = poster }
            if let removed = try boolean(row, "removed") { projected["removed"] = removed }
            if let temporary = try boolean(row, "temp") { projected["temp"] = temporary }
            guard let state = try object(row, "state") else { return projected }
            if let offset = try ownMilliseconds(state, "timeOffset") { projected["t"] = ownSeconds(offset) }
            if let duration = try ownMilliseconds(state, "duration") { projected["d"] = ownSeconds(duration) }
            if let watchedAt = try optionalString(state, "lastWatched") { projected["lastWatched"] = watchedAt }
            if let video = try optionalString(state, "video_id") { projected["v"] = video }
            if let count = try ownCount(state, "timesWatched") { projected["timesWatched"] = count }
            if let flagged = try ownFlag(state, "flaggedWatched") { projected["currentVideoWatched"] = flagged }
            if let opaque = try optionalString(state, "watched") { projected["watched"] = opaque }
            return projected
        }

        private static func ownMilliseconds(_ root: Object, _ key: String) throws -> Int64? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 9_007_199_254_740_990,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw fail("Malformed own-account millisecond state " + key)
            }
            return number.int64Value
        }

        /// `milliseconds` below parses the decimal representation and multiplies it by 1,000.
        /// Preserve an incoming integral millisecond value as Decimal seconds so values close to
        /// the documented 2^53-safe bound do not take an IEEE-754 rounding detour.
        private static func ownSeconds(_ milliseconds: Int64) -> NSDecimalNumber {
            let decimal = Decimal(string: String(milliseconds), locale: Locale(identifier: "en_US_POSIX"))!
            return NSDecimalNumber(decimal: decimal / 1000)
        }

        private static func ownCount(_ root: Object, _ key: String) throws -> Int64? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 0xffff_ffff,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw fail("Malformed own-account count " + key)
            }
            return number.int64Value
        }

        private static func ownFlag(_ root: Object, _ key: String) throws -> Bool? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 0 || number.doubleValue == 1 else {
                throw fail("Malformed own-account watched flag")
            }
            return number.doubleValue == 1
        }

        private convenience init(independentSource document: Object, profile: UserProfile) throws {
            try self.init(document: document, roster: [profile], ownerID: profile.id, modified: nil,
                          deferProfileEdits: false, allowIndependentSource: true)
        }

        private func resolveOwnAccountSources(_ rawSources: [OwnAccountSource], retainedBaseline: Data?,
                                              retainedSourceEnvelopes: [RetainedOwnAccountSourceEnvelope]) throws -> [String: ResolvedOwnAccountSource] {
            let ownProfiles = roster.filter { !$0.isOwner && $0.usesOwnAccount }
            var sources: [String: ResolvedOwnAccountSource] = [:]
            for source in rawSources {
                let profileID = source.profileID.uuidString
                try require(sources[profileID] == nil, "Duplicate own-account source receipt")
                try require(source.verifiedStreamingUID == source.verifiedStreamingUID.trimmingCharacters(in: .whitespacesAndNewlines)
                            && !source.verifiedStreamingUID.isEmpty
                            && source.verifiedStreamingUID.utf8.count <= 256
                            && !source.verifiedStreamingUID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                            "Own-account source lacks a verified streaming identity")
                try require(source.sourceDocumentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                            "Own-account source has an invalid document digest")
                try require(source.profileOverlaySHA256 == nil || source.profileOverlaySHA256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                            "Own-account source has an invalid overlay witness")
                let envelopeVersion = try Self.ownAccountEnvelopeVersion(source.sourceDocument)
                try require(envelopeVersion == 1 || envelopeVersion == 2, "Own-account source has an unsupported envelope version")
                try require(envelopeVersion == 2 ? source.profileOverlaySHA256 != nil : source.profileOverlaySHA256 == nil,
                            envelopeVersion == 2 ? "Own-account source v2 requires an overlay witness" : "Own-account source v1 cannot invent an overlay witness")
                if let witness = source.profileOverlaySHA256 {
                    try require(witness == Self.envelopeOverlayWitness(source.sourceDocument),
                                "Own-account source overlay witness does not match its exact envelope")
                }
                let document = try Self.decodeOwnAccountEnvelope(source.sourceDocument, profileID: profileID)
                sources[profileID] = ResolvedOwnAccountSource(profileID: profileID,
                    verifiedStreamingUID: source.verifiedStreamingUID,
                    sourceDocumentSHA256: source.sourceDocumentSHA256, profileOverlaySHA256: source.profileOverlaySHA256, sourceDocument: document, retainedBuckets: nil)
            }
            let freshSourceIDs = Set(sources.keys)
            let retained = try retainedOwnAccountSources(retainedBaseline, requiredProfiles: ownProfiles)
            for profile in ownProfiles where sources[profile.id.uuidString] == nil {
                guard let source = retained[profile.id.uuidString] else {
                    throw fail("Own-account profiles require exactly one authenticated streaming-account source")
                }
                sources[profile.id.uuidString] = source
            }
            var retainedEnvelopeIDs = Set<String>()
            for envelope in retainedSourceEnvelopes {
                let profileID = envelope.profileID.uuidString
                try require(retainedEnvelopeIDs.insert(profileID).inserted, "Duplicate retained own-account source envelope")
                try require(!freshSourceIDs.contains(profileID), "Retained source envelope conflicts with a fresh authenticated source")
                guard let retainedSource = retained[profileID], let retainedBuckets = retainedSource.retainedBuckets else {
                    throw fail("Retained source envelope lacks a validated own-account tuple")
                }
                try require(envelope.sourceDocumentSHA256 == retainedSource.sourceDocumentSHA256,
                            "Retained source envelope does not match the acknowledged source digest")
                let document = try Self.decodeOwnAccountEnvelope(envelope.sourceDocument, profileID: profileID)
                try require(sources[profileID]?.isRetained == true, "Retained source envelope has no active own-account profile")
                sources[profileID] = ResolvedOwnAccountSource(profileID: profileID,
                    verifiedStreamingUID: retainedSource.verifiedStreamingUID,
                    sourceDocumentSHA256: retainedSource.sourceDocumentSHA256,
                    profileOverlaySHA256: retainedSource.profileOverlaySHA256,
                    sourceDocument: document, retainedBuckets: retainedBuckets)
            }
            let ownIDs = Set(ownProfiles.map { $0.id.uuidString })
            try require(Set(sources.keys) == ownIDs, "Own-account profiles require exactly one authenticated streaming-account source")
            return sources
        }

        private static func envelopeOverlayWitness(_ source: Data) throws -> String {
            guard let envelope = try JSONSerialization.jsonObject(with: source) as? Object,
                  let raw = envelope["profileOverlayBase64"] as? String, let bytes = Data(base64Encoded: raw),
                  bytes.base64EncodedString() == raw else { throw fail("Own-account source envelope lacks an exact overlay") }
            return try VortxProfileOverlayWitness.digest(json: bytes)
        }

        private static func ownAccountEnvelopeVersion(_ source: Data) throws -> Int {
            guard let envelope = try JSONSerialization.jsonObject(with: source) as? Object,
                  let version = envelope["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                  Double(version.intValue) == version.doubleValue else { throw fail("Own-account source envelope is malformed") }
            return version.intValue
        }

        /// A cold peer can retain only the kernel-validated typed tuple. The caller has already
        /// validated nativeSync's receipt/history and selected `legacyImport.baseline`; this local
        /// structural check prevents a stale, cross-profile, or partial tuple from standing in for
        /// a fresh authenticated source. It intentionally never derives a new source digest.
        private func retainedOwnAccountSources(_ bytes: Data?, requiredProfiles: [UserProfile]) throws -> [String: ResolvedOwnAccountSource] {
            guard let bytes else { return [:] }
            guard let baseline = try JSONSerialization.jsonObject(with: bytes) as? Object,
                  let version = baseline["schemaVersion"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 2,
                  Double(version.intValue) == version.doubleValue,
                  let roster = try array(baseline, "roster"),
                  let sourceRows = try object(baseline, "ownAccountSources"),
                  let addons = try object(baseline, "addons"),
                  let libraries = try object(baseline, "libraries"),
                  let watches = try object(baseline, "watches"),
                  let links = try object(baseline, "identityLinks") else {
                throw fail("Retained own-account baseline is not complete material 2")
            }
            var profiles: [String: Object] = [:]
            for raw in roster {
                guard let profile = raw as? Object else { throw fail("Retained own-account baseline has a malformed roster") }
                let id = try string(profile, "id")
                try require(profiles[id] == nil, "Retained own-account baseline has duplicate profiles")
                profiles[id] = profile
            }
            var retained: [String: ResolvedOwnAccountSource] = [:]
            for profile in requiredProfiles {
                let id = profile.id.uuidString
                guard let source = try object(sourceRows, id),
                      Set(source.keys).isSubset(of: ["verifiedStreamingUid", "sourceDocumentSha256", "profileOverlaySha256"]),
                      let uid = try optionalString(source, "verifiedStreamingUid"),
                      uid == uid.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
                      uid.utf8.count <= 256, uid.rangeOfCharacter(from: .controlCharacters) == nil,
                      let digest = try optionalString(source, "sourceDocumentSha256"),
                      digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      let retainedProfile = profiles[id],
                      try boolean(retainedProfile, "owner") == false,
                      let account = try object(retainedProfile, "account"),
                      try optionalString(account, "kind") == "own", try optionalString(account, "value") == uid,
                      try optionalString(retainedProfile, "addons") == "own",
                      let addonBucket = try object(addons, id),
                      Set(addonBucket.keys) == ["items", "order", "intents"],
                      let addonItems = try array(addonBucket, "items"),
                      let addonOrder = try array(addonBucket, "order"),
                      let addonIntents = try array(addonBucket, "intents"),
                      let libraryBucket = try object(libraries, id),
                      Set(libraryBucket.keys) == ["items", "intents"],
                      let libraryItems = try array(libraryBucket, "items"),
                      let libraryIntents = try array(libraryBucket, "intents"),
                      let watchRows = try array(watches, id),
                      let linkRows = try array(links, id) else {
                    throw fail("Retained own-account baseline lacks a complete authenticated profile tuple")
                }
                let identityLinks = try linkRows.map { raw -> [String] in
                    guard let row = raw as? [String] else { throw fail("Retained own-account baseline has malformed identity links") }
                    return row
                }
                let witness = try optionalString(source, "profileOverlaySha256")
                try require(witness == nil || witness!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                            "Retained own-account baseline has an invalid overlay witness")
                retained[id] = ResolvedOwnAccountSource(profileID: id, verifiedStreamingUID: uid,
                    sourceDocumentSHA256: digest, profileOverlaySHA256: witness, sourceDocument: nil,
                    retainedBuckets: OwnAccountBuckets(addons: ["items": addonItems, "order": addonOrder, "intents": addonIntents],
                                                       library: ["items": libraryItems, "intents": libraryIntents],
                                                       watches: try watchRows.map { raw in
                        guard let row = raw as? Object else { throw fail("Retained own-account baseline has malformed watches") }
                        return row
                    }, titles: [:], identityLinks: identityLinks))
            }
            return retained
        }

        private func validateOwnProfileOverlayBindings(_ sources: [String: ResolvedOwnAccountSource]) throws {
            for (profileID, source) in sources {
                let rootSlice = try Self.profileOverlaySlice(document, profileID: profileID)
                if let sourceDocument = source.sourceDocument {
                    let sourceSlice = try Self.profileOverlaySlice(sourceDocument, profileID: profileID)
                    try require(try Self.equivalentJSON(rootSlice, sourceSlice),
                                "Own-account root overlay differs from its authenticated source")
                } else {
                    // Retained material is a sealed typed tuple. A live root overlay needs a new
                    // authenticated raw envelope so its clocks become part of a new source proof.
                    try require(rootSlice.isEmpty,
                                "Current own-account overlay requires an authenticated source refresh")
                }
            }
        }

        /// Extract the only two scoped overlay carriers. A lowercased or duplicate UUID key would
        /// make the root and source disagree about the authenticated identity, so refuse it rather
        /// than normalizing a potentially unrelated bucket into a source proof.
        private static func profileOverlaySlice(_ document: Object, profileID: String) throws -> Object {
            var slice: Object = [:]
            if let vortx = try object(document, "vortx"), let byProfile = try object(vortx, "byProfile") {
                let keys = byProfile.keys.filter { UUID(uuidString: $0)?.uuidString == profileID }
                try require(keys.count <= 1 && (keys.isEmpty || keys[0] == profileID),
                            "Own-account overlay has an ambiguous profile identity")
                if let bucket = byProfile[profileID] {
                    guard bucket is Object else { throw fail("Own-account overlay has a malformed profile bucket") }
                    slice["vortx"] = ["byProfile": [profileID: bucket]]
                }
            }
            if let progress = try object(document, "webProgress"), let removed = try object(progress, "removed"),
               let byProfile = try object(removed, "byProfile") {
                let keys = byProfile.keys.filter { UUID(uuidString: $0)?.uuidString == profileID }
                try require(keys.count <= 1 && (keys.isEmpty || keys[0] == profileID),
                            "Own-account overlay removals have an ambiguous profile identity")
                if let removals = byProfile[profileID] {
                    guard removals is [Any] else { throw fail("Own-account overlay has malformed profile removals") }
                    slice["webProgress"] = ["removed": ["byProfile": [profileID: removals]]]
                }
            }
            return slice
        }

        private static func equivalentJSON(_ lhs: Object, _ rhs: Object) throws -> Bool {
            try JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys, .withoutEscapingSlashes]) ==
                JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        func addonBucket() throws -> Object {
            var descriptors: [String: Object] = [:]
            var descriptorOrder: [String] = []
            // The app-owned descriptor wins against a stale generic imported descriptor.
            for rows in [try objects(vortx, "addons"), try objects(document, "addons")] {
                for raw in rows {
                    let url = try normalizeURL(string(raw, "transportUrl"))
                    guard let manifest = try object(raw, "manifest") else { throw fail("URL-only add-on requires manifest reconciliation") }
                    _ = try string(manifest, "id"); _ = try string(manifest, "name"); _ = try string(manifest, "version")
                    if let flags = try object(raw, "flags") {
                        _ = try boolean(flags, "official"); _ = try boolean(flags, "protected")
                    }
                    if descriptors[url] == nil {
                        var row = raw; row["transportUrl"] = url
                        descriptors[url] = row; descriptorOrder.append(url)
                    }
                }
            }
            func resolve(_ raw: String) throws -> String {
                let url = try normalizeURL(raw)
                let matches = descriptors.keys.filter { $0.lowercased() == url.lowercased() }
                // Old writers lowercased the whole URL. Even an exact lowercase descriptor cannot
                // disambiguate that spelling when a second configured path differs only by case.
                if url == url.lowercased() { try require(matches.count <= 1, "Ambiguous legacy add-on URL identity") }
                if descriptors[url] != nil { return url }
                try require(matches.count <= 1, "Ambiguous legacy add-on URL identity")
                return matches.first ?? url
            }
            var intents: [String: Object] = [:]
            var publishedStamps = Set<String>()
            for (raw, value) in try object(vortx, "deletedAddonsTs") ?? [:] {
                guard let entry = value as? Object else { throw fail("Malformed add-on intent") }
                try require(Set(entry.keys).isSubset(of: ["addedAt", "removedAt"]), "Unsupported add-on intent carrier")
                let url = try resolve(raw)
                if try clock(entry, "addedAt") != nil || clock(entry, "removedAt") != nil { publishedStamps.insert(url) }
                var intent = intents[url] ?? ["transportUrl": url]
                try mergeClock(entry, into: &intent, from: "addedAt", to: "addedAtMs")
                try mergeClock(entry, into: &intent, from: "removedAt", to: "removedAtMs")
                intents[url] = intent
            }
            for raw in try strings(vortx, "deletedAddons") {
                let url = try resolve(raw)
                // Shipping AddonTombstones migration epoch is 1ms, not a fabricated 'now'.
                if intents[url]?["addedAtMs"] == nil && intents[url]?["removedAtMs"] == nil {
                    try require(!publishedStamps.contains(url), "Ambiguous zero-stamp add-on removal requires reconciliation")
                    intents[url] = ["transportUrl": url, "removedAtMs": 1.0]
                }
            }
            for raw in try strings(document, "webAddonRemovals") {
                let intent = intents[try resolve(raw)] ?? [:]
                try require((try clock(intent, "addedAtMs") ?? 0) > 0 || (try clock(intent, "removedAtMs") ?? 0) > 0,
                            "Unclocked web add-on removal requires reconciliation")
            }
            for (url, row) in intents {
                let added = try clock(row, "addedAtMs") ?? 0, removed = try clock(row, "removedAtMs") ?? 0
                try require(added <= 0 || added < removed || descriptors[url] != nil,
                            "Live add-on install requires descriptor reconciliation")
            }
            let order = try strings(document, "addonOrder").map(resolve)
            try require(Set(order).count == order.count && order.allSatisfy { descriptors[$0] != nil },
                        "Add-on order has duplicate or unknown descriptors")
            return ["items": descriptorOrder.compactMap { descriptors[$0] }, "order": order,
                    "intents": intents.keys.sorted().compactMap { intents[$0] }]
        }

        func ownerLibrary() throws -> Object {
            let ownerID = owner.id.uuidString
            let rows = try array(vortx, "library") ?? array(document, "library") ?? []
            var items: [String: Object] = [:], intents: [String: Object] = [:]
            var removedRows = Set<String>(), publishedStamps = Set<String>()
            var seen = Set<String>()
            for value in rows {
                guard let row = value as? Object else { throw fail("Malformed owner library row") }
                let id = try string(row, "id"), type = try contentType(row)
                try known(ownerID, id, row)
                let key = type + ":" + id
                try require(seen.insert(key).inserted, "Duplicate owner library identity")
                var item: Object = ["kind": "standard", "id": id, "type": type, "name": try optionalString(row, "name") ?? ""]
                if let poster = try optionalString(row, "poster"), !poster.isEmpty { item["poster"] = poster }
                let temporary = try boolean(row, "temp") == true
                let removed = try boolean(row, "removed") == true
                if temporary && !independentSource { throw fail("Temporary owner-library membership requires reconciliation") }
                if removed && !temporary {
                    // eventEpochMs/lastWatched describe viewing, not membership removal. Require
                    // a separately proven library tombstone below; never promote a viewing clock.
                    // A freshly authenticated own-account baseline has no causal deletion clock;
                    // its explicit `removed:true` is represented by the documented weak epoch 1.
                    removedRows.insert(key)
                    if independentSource { intents[key] = ["key": key, "removedAtMs": 1.0] }
                } else if !temporary { items[key] = item }
                try importWatch(ownerID, id, row, history: false, overlay: false)
                try importMarks(ownerID, id, row)
            }
            if !independentSource {
                let buckets = try object(vortx, "byProfile") ?? [:]
                for (rawID, value) in buckets where UUID(uuidString: rawID) == UserProfile.ownerID || UUID(uuidString: rawID) == owner.id {
                    guard let bucket = value as? Object else { throw fail("Malformed owner-history bucket") }
                    for row in try objects(bucket, "ownerHistory") {
                        let id = try string(row, "id")
                        try known(ownerID, id, row)
                        try importWatch(ownerID, id, row, history: true, overlay: false)
                        try importMarks(ownerID, id, row)
                    }
                }
            }
            func keyFor(_ raw: String) throws -> String {
                let matches = (titles[ownerID] ?? [:]).filter { id, row in
                    let type = row["type"] as? String ?? ""
                    return id.lowercased() == raw.lowercased() || (type + ":" + id).lowercased() == raw.lowercased()
                }
                if matches.isEmpty, let split = raw.firstIndex(of: ":") {
                    let type = String(raw[..<split]), id = String(raw[raw.index(after: split)...])
                    if ["movie", "series"].contains(type) && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return raw // Already typed removal needs no invented catalog metadata.
                    }
                }
                try require(matches.count == 1, "Untyped library removal requires title-type reconciliation")
                let match = matches.first!
                return (try contentType(match.value)) + ":" + match.key
            }
            for (raw, value) in try object(vortx, "deletedLibraryTs") ?? [:] {
                guard let entry = value as? Object else { throw fail("Malformed library intent") }
                try require(Set(entry.keys).isSubset(of: ["addedAt", "removedAt"]), "Unsupported library intent carrier")
                let key = try keyFor(raw)
                if try clock(entry, "addedAt") != nil || clock(entry, "removedAt") != nil { publishedStamps.insert(key) }
                var intent = intents[key] ?? ["key": key]
                try mergeClock(entry, into: &intent, from: "addedAt", to: "addedAtMs")
                try mergeClock(entry, into: &intent, from: "removedAt", to: "removedAtMs")
                intents[key] = intent
            }
            for raw in try strings(vortx, "deletedLibrary") {
                let key = try keyFor(raw)
                if intents[key]?["addedAtMs"] == nil && intents[key]?["removedAtMs"] == nil {
                    try require(!publishedStamps.contains(key), "Ambiguous zero-stamp library removal requires reconciliation")
                    intents[key] = ["key": key, "removedAtMs": 1.0]
                }
            }
            for key in removedRows {
                let intent = intents[key] ?? [:]
                try require((try clock(intent, "removedAtMs") ?? 0) > (try clock(intent, "addedAtMs") ?? 0),
                            "Owner-library removal lacks a proven membership tombstone")
            }
            for (key, row) in intents {
                let added = try clock(row, "addedAtMs") ?? 0, removed = try clock(row, "removedAtMs") ?? 0
                try require(added <= 0 || added < removed || items[key] != nil,
                            "Live library addition requires descriptor reconciliation")
            }
            return ["items": items.keys.sorted().compactMap { items[$0] }, "intents": intents.keys.sorted().compactMap { intents[$0] }]
        }

        func importOverlays(excluding excludedProfiles: Set<String> = []) throws {
            let buckets = try object(vortx, "byProfile") ?? [:]
            let progress = try object(document, "webProgress") ?? [:]
            let removed = try object(progress, "removed") ?? [:]
            let web = try object(removed, "byProfile") ?? [:]
            var seen = Set<String>()
            for rawID in Set(buckets.keys).union(web.keys).sorted() {
                guard let uuid = UUID(uuidString: rawID) else { throw fail("Watch carrier references an unknown profile") }
                let id = uuid.uuidString
                if excludedProfiles.contains(id) { continue }
                try require(seen.insert(id).inserted, "Duplicate profile bucket identity")
                let bucket = try object(buckets, rawID) ?? [:]
                if deleted.contains(id) { continue } // Retained verbatim in the original encrypted carrier.
                if uuid == UserProfile.ownerID && profiles[id] == nil {
                    try require(!["library", "watched", "removed"].contains { bucket[$0] != nil } && web[rawID] == nil,
                                "Ambiguous historical owner overlay")
                    continue
                }
                try require(profiles[id] != nil, "Watch carrier references an unknown profile")
                if uuid != owner.id && uuid != UserProfile.ownerID && bucket["ownerHistory"] != nil {
                    throw fail("Owner history attached to a secondary profile")
                }
                let rows = try objects(bucket, "library")
                let railTitles = Set(try rows.map { try string($0, "id") })
                try require(railTitles.count == rows.count, "Duplicate overlay title snapshots require reconciliation")
                for row in rows {
                    let meta = try string(row, "id")
                    try known(id, meta, row)
                    try importWatch(id, meta, row, history: false, overlay: true)
                    try importMarks(id, meta, row)
                }
                for (meta, value) in try object(bucket, "watched") ?? [:] {
                    guard let row = value as? Object else { throw fail("Malformed durable watched row") }
                    try require(!meta.isEmpty, "Empty durable watch identity")
                    // Apple account-doc ingress gives the complete rail snapshot precedence over
                    // the ENTIRE duplicate durable row, including its explicit ma/ua clocks. The
                    // durable map fills titles beyond the rail; it is not an independent operation log.
                    if !railTitles.contains(meta) { try importMarks(id, meta, row) }
                }
                let removals = try objects(bucket, "removed") + objects(web, rawID)
                for removal in removals {
                    let keys = try strings(removal, "keys")
                    guard let at = try clock(removal, "removedAt"), at > 0, !keys.isEmpty else { throw fail("Unclocked or empty watch removal") }
                    let matches = (titles[id] ?? [:]).filter { meta, row in
                        keys.contains { removalMatches($0, meta: meta, type: row["type"] as? String ?? "") }
                    }
                    // Several matched titles are NOT proof that they are equivalent. An explicit
                    // alias reconciliation must precede this extraction in that case.
                    try require(matches.count == 1 && keys.allSatisfy { key in
                        matches.contains { removalMatches(key, meta: $0.key, type: $0.value["type"] as? String ?? "") }
                    }, "Watch removal requires verified title reconciliation")
                    let match = matches.first!
                    var row = context(id, match.key)
                    row["removedAtMs"] = at
                    watches[id, default: []].append(row)
                }
            }
        }

        func importWatch(_ profile: String, _ meta: String, _ raw: Object, history: Bool, overlay: Bool) throws {
            let position = try milliseconds(raw, "t"), duration = try milliseconds(raw, "d")
            let iso = try lastWatched(raw)
            let event = try clock(raw, "eventEpochMs")
            if history { try require(event != nil && event! > 0 && iso != nil, "Malformed genuine owner history") }
            let played = history ? event : iso
            let video = try optionalString(raw, "v").flatMap { $0.isEmpty ? nil : $0 }
            let bits = try optionalString(raw, "watched")
            try require(bits == nil || bits!.isEmpty, "Opaque watched bitfield requires episode reconciliation")
            let watched = try boolean(raw, "currentVideoWatched"), whole = try boolean(raw, "wholeTitleWatched")
            let type = try contentType(raw)
            try require(type != "series" || whole != true, "Whole-series watch intent requires episode reconciliation")
            let marks = try strings(raw, "w")
            let marked = try object(raw, "ma") ?? [:], reset = try object(raw, "ua") ?? [:]
            let hasMarks = !marks.isEmpty || !marked.isEmpty || !reset.isEmpty
            let count = try unsigned(raw, "timesWatched", maximum: 0xffff_ffff)
            if overlay && (position ?? 0) == 0 && !hasMarks && watched != true && whole != true {
                throw fail("Saved-only overlay membership requires explicit reconciliation")
            }
            // Ordinary saved rows can contain a synthetic lastWatched. Only a positive position or
            // an explicit genuine-history carrier proves playback; a watched bit alone proves no play.
            let hasProgress = (position ?? 0) > 0 || history
            if !hasProgress && watched != true && whole != true && count == nil { return }
            if type == "series" && (hasProgress || watched == true) {
                try require(video != nil, "Series progress or completion requires an exact video identity")
                try require(watched != true || video != meta, "Whole-series completion requires episode reconciliation")
            }
            if hasProgress {
                try require(played != nil && played! > 0 && position != nil, "Progress lacks a genuine viewing clock")
            }
            var row = context(profile, meta)
            for field in ["name", "poster"] {
                if let value = try optionalString(raw, field), !value.isEmpty { row[field] = value }
            }
            if let video { row["videoId"] = video }
            if hasProgress {
                row["positionMs"] = position; row["lastPlayedAtMs"] = played
            }
            if let duration { row["durationMs"] = duration }
            if watched == true || whole == true { row["watched"] = true }
            if let count { row["timesWatched"] = count }
            watches[profile, default: []].append(row)
        }

        func importMarks(_ profile: String, _ meta: String, _ raw: Object) throws {
            let watched = Set(try strings(raw, "w"))
            let marked = try object(raw, "ma") ?? [:], reset = try object(raw, "ua") ?? [:]
            for video in watched.union(marked.keys).union(reset.keys).sorted() {
                try require(!video.isEmpty, "Empty watched video identity")
                let ma = try clock(marked, video), ua = try clock(reset, video)
                let bareWatched = (ma ?? 0) == 0 && (ua ?? 0) == 0 && watched.contains(video)
                if (ma ?? 0) == 0 && (ua ?? 0) == 0 && !bareWatched { continue }
                if video == meta {
                    try require(titles[profile]?[meta]?["type"] as? String == "movie",
                                "Whole-title watched intent requires verified movie or episode reconciliation")
                }
                var row = context(profile, meta); row["videoId"] = video
                if (try optionalString(raw, "v")) == video || (video == meta && row["type"] as? String == "movie"),
                   let duration = try milliseconds(raw, "d") { row["durationMs"] = duration }
                if let ma, ma > 0 { row["markedAtMs"] = ma }
                if let ua, ua > 0 { row["resetAtMs"] = ua }
                // The account-doc ingress filters nonpositive clocks before overlay merging. Zero
                // and null therefore mean no operation here and do not suppress a bare watched bit.
                if bareWatched { row["watched"] = true }
                if row["markedAtMs"] != nil || row["resetAtMs"] != nil || row["watched"] != nil { watches[profile, default: []].append(row) }
            }
        }

        func importOwnerIntents() throws {
            struct Intent { let title: String; let video: String; let watched: Bool; let clock: Double; let actor: String }
            var winners: [String: Intent] = [:]
            for value in (try object(vortx, "ownerWatched") ?? [:]).values {
                guard let raw = value as? Object else { throw fail("Malformed owner watched intent") }
                let title = try string(raw, "t"), video = try string(raw, "v"), actor = try string(raw, "a")
                guard let watched = try boolean(raw, "w"), let at = try clock(raw, "u"), at > 0 else { throw fail("Unclocked owner watched intent") }
                let next = Intent(title: title, video: video, watched: watched, clock: at, actor: actor)
                let key = title + "\u{1f}" + video
                if let old = winners[key] {
                    try require(old.clock != at || old.actor != actor || old.watched == watched, "Conflicting owner watched intent tie")
                    if at < old.clock || (at == old.clock && actor < old.actor) { continue }
                }
                winners[key] = next
            }
            for intent in winners.values {
                let id = owner.id.uuidString
                try require(intent.title != intent.video || titles[id]?[intent.title]?["type"] as? String == "movie",
                            "Whole-title owner intent requires verified movie or episode reconciliation")
                var row = context(id, intent.title); row["videoId"] = intent.video
                row[intent.watched ? "markedAtMs" : "resetAtMs"] = intent.clock
                watches[id, default: []].append(row)
            }
        }

        func known(_ profile: String, _ meta: String, _ row: Object) throws {
            let type = try contentType(row)
            if let prior = titles[profile]?[meta] {
                try require(prior["type"] as? String == type, "Same media ID has conflicting movie/series ownership")
            }
            var metadata = titles[profile]?[meta] ?? ["type": type]
            for key in ["name", "poster"] {
                if let value = try optionalString(row, key), !value.isEmpty {
                    // Stable metadata fallback independent of carrier/map iteration; each progress
                    // fragment below keeps its own source metadata for strictly-newer selection.
                    if let prior = metadata[key] as? String { metadata[key] = min(prior, value) }
                    else { metadata[key] = value }
                }
            }
            titles[profile, default: [:]][meta] = metadata
        }

        /// Pending web edits are a separate authority channel. A roster snapshot alone cannot prove
        /// that web membership changes have been consumed; consult only this authenticated carrier.
        func validateProfileEdits(ownerLibrary: Object) throws {
            guard let edits = try object(document, "profileEdits") else { return }
            let rows = try objects(edits, "roster"), adds = try object(edits, "libraryAdds") ?? [:]
            guard !rows.isEmpty || !adds.isEmpty else { return }
            guard let at = try clock(edits, "editedAt"), at > 0 else { throw fail("Unclocked profile edits require reconciliation") }
            if !rows.isEmpty {
                try require(modified != nil && at <= modified! * 1000, "Pending profile roster edits require reconciliation")
            }
            for row in rows {
                guard let uuid = UUID(uuidString: try string(row, "id")) else { throw fail("Invalid profile edit identity") }
                let id = uuid.uuidString
                if try boolean(row, "deleted") == true {
                    try require(uuid != owner.id && deleted.contains(id), "Profile deletion edit lacks its permanent tombstone")
                } else {
                    // Missing IDs are created even by stale web edits in the shipping host.
                    try require(profiles[id] != nil || deleted.contains(id), "Profile edit identity is absent from resolved roster")
                }
            }
            let ownerItems = try objects(ownerLibrary, "items")
            let ownerIntents = try objects(ownerLibrary, "intents")
            for (rawID, raw) in adds {
                guard let uuid = UUID(uuidString: rawID), let items = raw as? [Object] else { throw fail("Malformed profile library additions") }
                let id = uuid.uuidString
                if deleted.contains(id) { continue }
                try require(profiles[id] != nil, "Library additions reference an unknown profile")
                if items.isEmpty { continue }
                // A secondary's old add operation manufactures a zero-offset overlay observation.
                // An existing progress row does not prove it was applied. Do not emulate that reset.
                try require(uuid == owner.id, "Secondary profile library additions require an explicit applied receipt")
                for item in items {
                    let meta = try string(item, "id"), type = try contentType(item), key = type + ":" + meta
                    let intent = ownerIntents.first { $0["key"] as? String == key } ?? [:]
                    let removed = try clock(intent, "removedAtMs") ?? 0, added = try clock(intent, "addedAtMs") ?? 0
                    let saved = ownerItems.contains { $0["id"] as? String == meta && $0["type"] as? String == type }
                    try require(saved && removed <= added, "Owner library addition is absent from resolved saved membership")
                }
            }
        }

        func context(_ profile: String, _ meta: String) -> Object {
            var row = titles[profile]?[meta] ?? [:]
            row["metaId"] = meta
            return row
        }
    }

    private static func resolveWatches(_ source: [[String: Any]]) throws -> [[String: Any]] {
        var units: [String: [String: Any]] = [:]
        // A stable source ordering makes omitted-field fallback independent of the dictionary or
        // carrier traversal order, including duration metadata with equal source clocks.
        let ordered = try source.map { row in
            (row, try clock(row, "lastPlayedAtMs") ?? 0,
             try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        }.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.2.lexicographicallyPrecedes(rhs.2) : lhs.1 < rhs.1 }
        for (incoming, _, _) in ordered {
            let meta = try string(incoming, "metaId")
            let key = try optionalString(incoming, "videoId") ?? meta
            guard var old = units[key] else { units[key] = incoming; continue }
            try require(old["metaId"] as? String == meta, "Watch unit belongs to conflicting title identities")
            let oldType = old["type"] as? String, newType = incoming["type"] as? String
            try require(oldType == nil || newType == nil || oldType == newType, "Watch unit belongs to conflicting content types")
            let before = try clock(old, "lastPlayedAtMs") ?? 0, after = try clock(incoming, "lastPlayedAtMs") ?? 0
            if let a = old["positionMs"] as? Int64, let b = incoming["positionMs"] as? Int64, before == after {
                try require(a == b, "Equal viewing clocks have conflicting positions")
            }
            if old["durationMs"] == nil { old["durationMs"] = incoming["durationMs"] }
            if after > before || old["positionMs"] == nil {
                for field in ["lastPlayedAtMs", "positionMs", "durationMs"] where incoming[field] != nil { old[field] = incoming[field] }
            }
            for field in ["name", "type", "poster", "videoId"] {
                guard let value = incoming[field] as? String, !value.isEmpty else { continue }
                if let prior = old[field] as? String, !prior.isEmpty {
                    if after > before { old[field] = value }
                    else if after == before { old[field] = min(prior, value) }
                } else { old[field] = value }
            }
            for field in ["markedAtMs", "resetAtMs", "removedAtMs", "timesWatched"] {
                if let value = try clock(incoming, field) { old[field] = max(value, try clock(old, field) ?? 0) }
            }
            if incoming["watched"] as? Bool == true { old["watched"] = true }
            units[key] = old
        }
        return units.keys.sorted().map { key in
            var row = units[key]!
            if row["markedAtMs"] != nil || row["resetAtMs"] != nil { row.removeValue(forKey: "watched") }
            return row
        }
    }

    private static func fail(_ reason: String) -> ReconciliationRequired { ReconciliationRequired(reason: reason) }
    private static func require(_ condition: Bool, _ reason: String) throws { if !condition { throw fail(reason) } }
    private static func object(_ root: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? [String: Any] else { throw fail("Malformed object carrier " + key) }
        return value
    }
    private static func array(_ root: [String: Any], _ key: String) throws -> [Any]? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? [Any] else { throw fail("Malformed array carrier " + key) }
        return value
    }
    private static func objects(_ root: [String: Any], _ key: String) throws -> [[String: Any]] {
        try (array(root, key) ?? []).map { value in
            guard let row = value as? [String: Any] else { throw fail("Malformed object row " + key) }
            return row
        }
    }
    private static func strings(_ root: [String: Any], _ key: String) throws -> [String] {
        try (array(root, key) ?? []).map { value in
            guard let row = value as? String, !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("Malformed identity " + key) }
            return row
        }
    }
    private static func optionalString(_ root: [String: Any], _ key: String) throws -> String? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw fail("Malformed string " + key) }
        return value
    }
    private static func string(_ root: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(root, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { throw fail("Missing or invalid " + key) }
        return value
    }
    private static func boolean(_ root: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw fail("Malformed boolean " + key) }
        return value.boolValue
    }
    private static func contentType(_ root: [String: Any]) throws -> String {
        let value = try string(root, "type")
        try require(value == "movie" || value == "series", "Unsupported catalog content type")
        return value
    }
    private static func validClock(_ value: Double, _ key: String) throws -> Double {
        try require(value.isFinite && value >= 0 && value <= 9_007_199_254_740_990, "Invalid clock " + key)
        return value
    }
    private static func clock(_ root: [String: Any], _ key: String) throws -> Double? {
        guard let raw = root[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw fail("Malformed clock " + key) }
        return try validClock(value.doubleValue, key)
    }
    private static func mergeClock(_ source: [String: Any], into target: inout [String: Any], from: String, to: String) throws {
        if let value = try clock(source, from), value > 0 { target[to] = max(value, try clock(target, to) ?? 0) }
    }
    private static func milliseconds(_ root: [String: Any], _ key: String) throws -> Int64? {
        guard try clock(root, key) != nil, let number = root[key] as? NSNumber else { return nil }
        guard var value = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) else { throw fail("Malformed progress") }
        value *= 1000
        var integer = Decimal(); NSDecimalRound(&integer, &value, 0, .plain)
        try require(integer == value && value <= Decimal(9_007_199_254_740_990 as Int64),
                    "Sub-millisecond or excessive progress cannot be represented")
        return NSDecimalNumber(decimal: integer).int64Value
    }
    private static func unsigned(_ root: [String: Any], _ key: String, maximum: Double) throws -> Int64? {
        guard let value = try clock(root, key) else { return nil }
        try require(value <= maximum && value.rounded(.towardZero) == value, "Invalid count " + key)
        return Int64(value)
    }
    private static func lastWatched(_ root: [String: Any]) throws -> Double? {
        guard let raw = try optionalString(root, "lastWatched"), !raw.isEmpty else { return nil }
        // Parse whole seconds independently: ISO8601DateFormatter rounds fractional timestamps on
        // some OS versions. Add the original decimal fraction afterwards to preserve Double clocks.
        let pattern = "^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d+))?(Z|[+-]\\d{2}:\\d{2})$"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let secondsRange = Range(match.range(at: 1), in: raw), let zoneRange = Range(match.range(at: 3), in: raw) else { throw fail("Invalid lastWatched clock") }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: String(raw[secondsRange]) + String(raw[zoneRange])) else { throw fail("Invalid lastWatched clock") }
        let fraction = Range(match.range(at: 2), in: raw).flatMap { Double("0." + raw[$0]) } ?? 0
        let value = try validClock(date.timeIntervalSince1970 * 1000 + fraction * 1000, "lastWatched")
        return value > 0 ? value : nil
    }
    private static func normalizeURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { throw fail("Unsupported add-on transport URL") }
        url.scheme = scheme; url.host = host.lowercased()
        guard let normalized = url.string else { throw fail("Unsupported add-on transport URL") }
        return normalized
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert($0).inserted }
    }
    private static func terms(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    private static func removalMatches(_ key: String, meta: String, type: String) -> Bool {
        let prefix = type + "\u{1f}"
        guard key.hasPrefix(prefix) else { return false }
        let provider = String(key.dropFirst(prefix.count))
        if provider == meta.lowercased() { return true }
        if meta.range(of: "^tt[0-9]+$", options: .regularExpression) != nil { return provider == "imdb:" + meta.lowercased() }
        if meta.range(of: "^tmdb:[0-9]+$", options: .regularExpression) != nil { return provider == "tmdb:" + type + ":" + meta.dropFirst(5) }
        return false
    }
    private static func rejectCredentials(_ raw: Any) throws {
        if let object = raw as? [String: Any] {
            for (key, value) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                try require(!["token", "accesstoken", "refreshtoken", "authkey", "password", "authorization", "bearer", "datakey", "apikey", "clientsecret"].contains(normalized),
                            "Credential-bearing material is not native state")
                try rejectCredentials(value)
            }
        } else if let array = raw as? [Any] { for value in array { try rejectCredentials(value) } }
    }
}
