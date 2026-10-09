import Foundation

/// Public adapter for immutable website add-on events. The private runtime owns fingerprints,
/// causality, binding validation and membership ordering; this host only stages their receipts.
enum VortxNativeWebsiteAddonEdits {
    typealias Conflict = VortxNativeProfileEditHost.Conflict
    static let maximumEvents = 128
    static let maximumBytes = 2 * 1024 * 1024

    static func events(_ carrier: VortxJSON?) throws -> [VortxJSON] {
        guard let carrier else { return [] }
        let events: [VortxJSON]
        if case .object(let fields) = carrier, Set(fields.keys) == ["schemaVersion", "events"],
           carrier["schemaVersion"] == .integer(1), let rows = carrier["events"]?.array {
            events = rows
        } else {
            // Keep an unsupported carrier intact as rejected work. It cannot prevent independent
            // valid events/profiles from syncing, and is never silently interpreted as an empty list.
            events = [carrier]
        }
        try validateSource(events)
        try validateIncomingIdentities(events)
        return events
    }

    /// A carrier cannot choose between duplicate identifiers. Sealed historical conflicts are
    /// different: retain their exact payloads and quarantine the entire colliding union group.
    static func validateIncomingIdentities(_ events: [VortxJSON]) throws {
        let ids = events.compactMap { event -> String? in
            guard case .string(let id) = event["eventId"] else { return nil }; return id
        }
        guard Set(ids).count == ids.count else { throw VortxNativeError.invalidSnapshot }
    }

    static func collidingIdentities(_ events: [VortxJSON]) -> Set<String> {
        var byID: [String: VortxJSON] = [:], collisions = Set<String>()
        for event in events {
            guard case .string(let id) = event["eventId"] else { continue }
            if let previous = byID[id], previous != event { collisions.insert(id) }
            else { byID[id] = event }
        }
        return collisions
    }

    static func validateSource(_ events: [VortxJSON]) throws {
        guard events.count <= maximumEvents,
              try JSONEncoder().encode(VortxJSON.object(["schemaVersion": .integer(1), "events": .array(events)])).count <= maximumBytes else {
            throw VortxNativeError.invalidSnapshot
        }
        try VortxNativeProfileEditHost.validateSource(events)
    }

    static func validateJournal(_ local: VortxNativeHostPreferences.Local) throws {
        try validateSource(local.websiteAddonPending ?? [])
        for (id, fingerprint) in local.websiteAddonReceipts ?? [:] {
            guard hex(id, length: 32), hex(fingerprint, length: 64) else { throw VortxNativeError.invalidSnapshot }
        }
    }

    static func request(event: VortxJSON, scope: VortxAccountScope) -> VortxJSON {
        .object(["type": .string("apply_website_addon_edits"), "scope": .string(scope.account),
                 "ownerProfileId": .string(scope.ownerProfileID), "event": event])
    }

    /// The exact raw event must have been dispatched to this trial, including on replay. A matching
    /// event ID in a remote receipt alone does not prove that its immutable payload was considered.
    static func validatedReceipt(event: VortxJSON, result: VortxJSON, state: VortxJSON,
                                 scope: VortxAccountScope) throws -> (id: String, fingerprint: String) {
        guard result["ok"] == .bool(true), let results = result["events"]?.array, results.count == 1,
              results[0]["event"] == .string("website_addon_edits_applied"), let receipt = results[0]["receipt"],
              case .object(let fields) = receipt,
              Set(fields.keys) == ["schemaVersion", "eventId", "counter", "fingerprint", "scope", "ownerProfileId", "profileId", "expectedBinding"],
              receipt["schemaVersion"] == .integer(1), case .string(let id) = event["eventId"], hex(id, length: 32),
              case .string(let fingerprint) = receipt["fingerprint"], hex(fingerprint, length: 64),
              receipt["eventId"] == event["eventId"], receipt["counter"] == event["counter"],
              receipt["scope"] == .string(scope.account), event["scope"] == .string(scope.account),
              receipt["ownerProfileId"] == .string(scope.ownerProfileID), event["ownerProfileId"] == .string(scope.ownerProfileID),
              receipt["profileId"] == event["profileId"], receipt["expectedBinding"] == event["expectedBinding"],
              state["nativeSync"]?["schemaVersion"] == .integer(5),
              state["nativeSync"]?["websiteAddonReceipts"]?[id] == receipt else { throw VortxNativeError.invalidResponse }
        return (id, fingerprint)
    }

    /// Ask the engine for the materialized result. A receipt acknowledges consideration, and a
    /// newer native uninstall/rebind must remain visible as a conflict instead of a false success.
    static func conflict(event: VortxJSON, receipt: (id: String, fingerprint: String),
                         state: VortxJSON, runtime: VortxNativeRuntime) throws -> Conflict? {
        guard case .string(let profileID) = event["profileId"], let profile = state["roster"]?["profiles"]?[profileID] else {
            throw VortxNativeError.invalidResponse
        }
        let binding = state["nativeSync"]?["accountSlots"]?[profileID]?["activeBinding"]
            ?? .object(["account": profile["account"] ?? .null, "revision": .integer(0), "transactionId": .null])
        guard profile["deleted"] != .bool(true), binding == event["expectedBinding"] else {
            return .init(eventId: receipt.id, code: "account_binding_changed", paths: ["expectedBinding"])
        }
        let query: VortxJSON = .object(["kind": .string("installed_addons"), "profileId": .string(profileID)])
        let response = try JSONDecoder().decode(VortxJSON.self, from: Data(runtime.resolve(String(decoding: JSONEncoder().encode(query), as: UTF8.self)).utf8))
        guard response["kind"] == .string("installed_addons"), response["profileId"] == .string(profileID),
              let addons = response["addons"]?.array, let mutations = event["mutations"]?.array else { throw VortxNativeError.invalidResponse }
        let urls = try addons.map { addon -> String in
            guard case .string(let url) = addon["transportUrl"], let key = memberKey(url) else { throw VortxNativeError.invalidResponse }; return key
        }
        var paths: [String] = []
        for mutation in mutations {
            guard case .string(let url) = mutation["transportUrl"] else { throw VortxNativeError.invalidResponse }
            if mutation["state"] == .string("removed") {
                if urls.contains(url) { paths.append(url) }
            } else {
                let source = state["nativeSync"]?["addons"]?[profileID]?["records"]?[url]?["webSources"]
                if !urls.contains(url) || source?["addedAt"]?["fingerprint"] != .string(receipt.fingerprint)
                    || source?["valueAt"]?["fingerprint"] != .string(receipt.fingerprint) { paths.append(url) }
            }
        }
        if let order = event["order"], order != .array(urls.map(VortxJSON.string)) { paths.append("order") }
        return paths.isEmpty ? nil : .init(eventId: receipt.id, code: "native_addon_state_changed", paths: paths.sorted())
    }

    /// Match the native identity rule without URL reserialization: preserve credentials, ports,
    /// configured path, query and fragment bytes; fold only scheme and host authority casing.
    static func memberKey(_ raw: String) -> String? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = raw.range(of: "://") else { return nil }
        let scheme = raw[..<separator.lowerBound].lowercased()
        guard ["http", "https"].contains(scheme) else { return nil }
        let rest = raw[separator.upperBound...]
        let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        let authority = rest[..<end]
        let hostStart = authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex
        let host = authority[hostStart...]
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }) else { return nil }
        let foldedHost = String(decoding: host.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
        return "\(scheme)://\(authority[..<hostStart])\(foldedHost)\(rest[end...])"
    }

    private static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
