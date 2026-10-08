import Foundation
import CoreFoundation

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

    /// A Sendable UTF-8 JSON result that can cross the caller's authentication/MainActor boundary.
    /// The result is the `material` member of `import_legacy_sync`, not a runtime or sync document.
    static func encode(document: Data, roster: [UserProfile], ownerProfileID: UUID,
                       rosterModifiedSeconds: Double?) throws -> Data {
        guard let source = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw ReconciliationRequired(reason: "Account document must be an object")
        }
        let adapter = try Adapter(document: source, roster: roster, ownerID: ownerProfileID,
                                  modified: rosterModifiedSeconds)
        return try JSONSerialization.data(withJSONObject: adapter.build(), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private final class Adapter {
        typealias Object = [String: Any]
        let document: Object
        let vortx: Object
        let roster: [UserProfile]
        let owner: UserProfile
        let modified: Double?
        let profiles: [String: UserProfile]
        var deleted = Set<String>()
        var watches: [String: [Object]] = [:]
        var titles: [String: [String: Object]] = [:]

        init(document: Object, roster: [UserProfile], ownerID: UUID, modified: Double?) throws {
            self.document = document
            self.vortx = try object(document, "vortx") ?? [:]
            self.roster = roster
            self.modified = modified
            let owners = roster.filter(\.isOwner)
            try require(owners.count == 1 && owners[0].id == ownerID, "A unique resolved owner UUID is required")
            self.owner = owners[0]
            try require(!roster.isEmpty && Set(roster.map(\.id)).count == roster.count, "Duplicate or empty profile roster")
            profiles = Dictionary(uniqueKeysWithValues: roster.map { ($0.id.uuidString, $0) })
        }

        func build() throws -> Object {
            if let modified { _ = try validClock(modified, "rosterModifiedSeconds") }
            deleted = Set(try strings(vortx, "deletedProfiles").map { raw in
                guard let id = UUID(uuidString: raw) else { throw fail("Invalid deleted profile identity") }
                return id.uuidString
            })
            try require(!deleted.contains(owner.id.uuidString), "Owner profile is tombstoned")
            for profile in roster {
                try require(!profile.usesOwnAccount, "Own-account profile requires an authenticated streaming-account identity")
                watches[profile.id.uuidString] = []
                titles[profile.id.uuidString] = [:]
            }
            let nativeRoster = try roster.map(projectProfile)
            let addons = try addonBucket()
            let library = try ownerLibrary()
            try importOverlays()
            try importOwnerIntents()
            try validateProfileEdits(ownerLibrary: library)
            var result: Object = [
                "schemaVersion": 1, "roster": nativeRoster, "deletedProfileIds": deleted.sorted(),
                "addons": [owner.id.uuidString: addons], "libraries": [owner.id.uuidString: library],
                "watches": try watches.mapValues(resolveWatches),
                // Removal keys do not establish an IMDb/TMDB equivalence edge. The caller must
                // reconcile such aliases explicitly; this adapter never guesses an identity link.
                "identityLinks": Dictionary(uniqueKeysWithValues: roster.map { ($0.id.uuidString, [[String]]()) })
            ]
            if let modified { result["rosterModifiedSeconds"] = modified }
            try rejectCredentials(result)
            return result
        }

        func projectProfile(_ profile: UserProfile) throws -> Object {
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
            var result: Object = ["id": profile.id.uuidString, "name": profile.name, "owner": profile.isOwner,
                                  "account": profile.isOwner ? ["kind": "local_only"] : ["kind": "shared", "value": owner.id.uuidString],
                                  "addons": "share_primary", "settings": settings,
                                  "parental": ["kids": profile.isKids, "familyEdit": profile.familyEdit]]
            if let pin = profile.pin, !pin.isEmpty {
                try require(pin.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                            "Legacy plaintext or malformed PIN requires explicit reconciliation")
                result["pin"] = pin
            }
            return result
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
                if try boolean(row, "temp") == true { throw fail("Temporary owner-library membership requires reconciliation") }
                if try boolean(row, "removed") == true {
                    // eventEpochMs/lastWatched describe viewing, not membership removal. Require
                    // a separately proven library tombstone below; never promote a viewing clock.
                    removedRows.insert(key)
                } else { items[key] = item }
                try importWatch(ownerID, id, row, history: false, overlay: false)
                try importMarks(ownerID, id, row)
            }
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

        func importOverlays() throws {
            let buckets = try object(vortx, "byProfile") ?? [:]
            let progress = try object(document, "webProgress") ?? [:]
            let removed = try object(progress, "removed") ?? [:]
            let web = try object(removed, "byProfile") ?? [:]
            var seen = Set<String>()
            for rawID in Set(buckets.keys).union(web.keys).sorted() {
                guard let uuid = UUID(uuidString: rawID) else { throw fail("Watch carrier references an unknown profile") }
                let id = uuid.uuidString
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
            if hasProgress {
                try require(played != nil && played! > 0 && position != nil, "Progress lacks a genuine viewing clock")
                try require(type != "series" || video != nil, "Series progress requires an exact video identity")
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
