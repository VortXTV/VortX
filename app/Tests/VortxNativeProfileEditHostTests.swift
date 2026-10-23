import Foundation

@main
struct VortxNativeProfileEditHostTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "website host fixture line \(line)") }
    static func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS \(label)") }
    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation() } catch { print("PASS \(label)"); return }
        preconditionFailure(label)
    }
    static func main() throws {
        let vectors = try JSONDecoder().decode(VortxJSON.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for vector in vectors.array! {
            check(try VortxNativeProfileEditHost.canonicalJSON(vector["value"]!) == vector["canonical"]!.decode(String.self))
            check(try VortxNativeProfileEditHost.valueHash(vector["value"]!) == vector["sha256"]!.decode(String.self))
        }
        let scope = VortxAccountScope(account: "account.fixture", ownerProfileID: "00000000-0000-0000-0000-00000000A11C")
        let actor = "00000000-0000-0000-0000-000000000001", eventID = "00000000-0000-0000-0000-000000000002"
        try VortxNativeProfileEditHost.validateSource([.object(["hostBases": .object(["owner": .object(["avatar": .object([
            "absent": .bool(true), "valueHash": .string("e9" + String(repeating: "0", count: 62))])])])])])
        let base: VortxJSON = .object(["audioLang": .string("eng"), "subtitleLang": .string("hin"), "maxFileSizeGB": .number(12.5),
            "forcedPolicy": .string("forced"), "subFont": .string("system"), "subSize": .string("medium"),
            "subColor": .string("white"), "subBackground": .string("none"),
            "futurePlayback": .object(["precision": .number(0.125), "nested": .null])])
        let baseline = [scope.ownerProfileID: ["avatar": VortxJSON.string("🍿"), "playback": base]]
        let original = try VortxNativeHostPreferences(scope: scope, actor: actor)
        let event: VortxJSON = .object(["eventId": .string(eventID), "observedHostClock": .integer(0), "hostBases": .object([
            scope.ownerProfileID: .object(["playback": .object(["absent": .bool(true), "valueHash": .string(try VortxNativeProfileEditHost.valueHash(base))])])])])
        let patch: VortxJSON = .object([scope.ownerProfileID: .object(["settings.playback.audioLang": .string("fra")])])
        let admitted = try VortxNativeProfileEditHost.admit(event: event, hostPatch: patch, preferences: original,
            scope: scope, baseline: baseline, committedReplay: false)
        check(admitted.conflict == nil)
        let changed = admitted.preferences.local.document.profiles[scope.ownerProfileID]!.fields["playback"]!
        check(changed.clock == 1 && changed.actor == eventID)
        check(changed.value["audioLang"] == .string("fra") && changed.value["subtitleLang"] == .string("hin"))
        check(changed.value["maxFileSizeGB"] == .number(12.5))
        let conflict = try VortxNativeProfileEditHost.admit(event: event, hostPatch: patch, preferences: admitted.preferences,
            scope: scope, baseline: baseline, committedReplay: false)
        check(conflict.conflict?.code == "host_base_changed")
        check(conflict.preferences.local.document == admitted.preferences.local.document)
        let replay = try VortxNativeProfileEditHost.admit(event: event, hostPatch: patch, preferences: admitted.preferences,
            scope: scope, baseline: baseline, committedReplay: true)
        check(replay.conflict == nil && replay.preferences.local.document == admitted.preferences.local.document)
        let divergent = [scope.ownerProfileID: ["avatar": VortxJSON.string("🍿"), "playback": VortxJSON.object(["audioLang": .string("ita")])]]
        check(try VortxNativeProfileEditHost.admit(event: event, hostPatch: patch, preferences: original,
            scope: scope, baseline: divergent, committedReplay: false).conflict != nil)
        var newer = admitted.preferences
        guard case .object(var newerPlayback) = base else { fatalError("fixture base") }; newerPlayback["audioLang"] = .string("deu")
        try newer.edit(profileID: scope.ownerProfileID, fields: ["playback": .object(newerPlayback)], scope: scope)
        let delayed = try VortxNativeProfileEditHost.admit(event: event, hostPatch: patch, preferences: newer,
            scope: scope, baseline: baseline, committedReplay: true)
        check(delayed.conflict == nil && delayed.preferences.local.document == newer.local.document)
        try uuidInterop(scope: scope, actor: actor, eventID: eventID, base: base, baseline: baseline)
        print("Website host-CAS: shared JavaScript canonical hashes, absent authenticated baseline, sparse siblings, conflict atomicity and exact/newer replay passed")
    }

    static func uuidInterop(scope: VortxAccountScope, actor: String, eventID: String, base: VortxJSON,
                            baseline: VortxNativeProfileEditHost.Baselines) throws {
        let upper = scope.ownerProfileID, lower = scope.ownerProfileID.lowercased()
        let watch = try VortxNativeWatchlist.field(id: "tt-case-fixture", type: "series")
        let entry = VortxNativeWatchlist.Entry(id: "tt-case-fixture", type: "series", name: "Case fixture", poster: nil, addedAt: 123.5)
        func register(_ value: VortxJSON, clock: UInt64 = 7) -> VortxJSON {
            .object(["clock": .integer(Int64(clock)), "actor": .string(actor), "value": value])
        }
        let fields: VortxJSON = .object(["fields": .object([
            "playback": register(base), "avatar": register(.string("Case avatar")),
            watch: register(try VortxNativeWatchlist.value(entry)),
            "futurePreference": register(.object(["nested": .array([.string("unchanged"), .null])]))])])
        func carrier(_ profiles: [String: VortxJSON]) -> VortxJSON {
            .object(["schemaVersion": .integer(1), "scope": .string(scope.account), "ownerProfileId": .string(upper),
                "profiles": .object(profiles), "globals": .object(["fields": .object(["futureGlobal": register(.string("retained"))])])])
        }
        var host = try VortxNativeHostPreferences(scope: scope, actor: actor)
        let legacyIDs = ["legacy-Case-ID", "0-0-0-0-a11c", "{\(lower)}", "urn:uuid:\(lower)", " \(lower)",
            lower + "\n", lower + "-suffix", lower.replacingOccurrences(of: "-", with: ""),
            lower.replacingOccurrences(of: "a", with: "ａ")]
        var groups = Dictionary(uniqueKeysWithValues: legacyIDs.map { ($0, fields) })
        groups[lower] = fields
        try host.merge(carrier(groups), scope: scope)
        let canonical = try host.document
        check(canonical["profiles"]?[upper] == fields && canonical["profiles"]?[lower] == nil,
              "lowercase UUID ingress preserves exact registers under the uppercase native identity")
        check(legacyIDs.allSatisfy { canonical["profiles"]?[$0] == fields },
              "legacy, shortened, braced, URN, whitespace, newline, suffixed, compact and Unicode IDs remain byte-exact")
        let state: VortxJSON = .object(["roster": .object(["profiles": .object([
            upper: .object(["id": .string(upper), "name": .string("Owner"), "owner": .bool(true)])])])])
        let projected = try VortxNativeProfiles.project(state: state, host: canonical, baseline: [])
        check(projected.first?.avatar == "Case avatar" && projected.first?.playback?.audioLang == "eng"
              && projected.first?.playback?.maxFileSizeGB == 12.5,
              "actual native profile projection finds lowercase-authored playback and avatar")
        check(try VortxNativeWatchlist.entries(host: canonical, profileID: UUID(uuidString: upper)!) == [entry],
              "actual watchlist projection finds the canonicalized host group")
        try host.edit(profileID: lower, fields: ["avatar": .string("Edited")], scope: scope)
        check(host.local.document.profiles[upper]?.fields["avatar"]?.value == .string("Edited")
              && host.local.document.profiles[lower] == nil && host.local.document.profiles.count == legacyIDs.count + 1,
              "lowercase local edit updates the same group without minting a second identity")

        let evidence: VortxJSON = .object(["absent": .bool(true), "valueHash": .string(try VortxNativeProfileEditHost.valueHash(base))])
        let bases: VortxJSON = .object(["playback": evidence])
        let patchFields: VortxJSON = .object(["settings.playback.audioLang": .string("fra")])
        func event(_ groups: [String: VortxJSON], clock: UInt64 = 0) -> VortxJSON {
            .object(["eventId": .string(eventID), "observedHostClock": .integer(Int64(clock)), "hostBases": .object(groups)])
        }
        let immutableEvent = event([lower: bases]), immutablePatch = VortxJSON.object([upper: patchFields])
        let eventFingerprint = try VortxNativeProfileEditHost.valueHash(immutableEvent)
        let patchFingerprint = try VortxNativeProfileEditHost.valueHash(immutablePatch)
        let empty = try VortxNativeHostPreferences(scope: scope, actor: actor)
        let existingEvent = event([lower: .object(["playback": .object(["clock": .integer(7), "actor": .string(actor),
            "valueHash": .string(try VortxNativeProfileEditHost.valueHash(base))])])], clock: 8)
        let existingAdmitted = try VortxNativeProfileEditHost.admit(event: existingEvent, hostPatch: immutablePatch,
            preferences: host, scope: scope, baseline: baseline, committedReplay: false)
        check(existingAdmitted.conflict == nil
              && existingAdmitted.preferences.local.document.profiles[upper]?.fields["playback"]?.clock == 9
              && existingAdmitted.preferences.local.document.profiles[upper]?.fields["playback"]?.actor == eventID,
              "mixed-case exact existing base admits without changing the author clock or actor")
        let admitted = try VortxNativeProfileEditHost.admit(event: immutableEvent, hostPatch: immutablePatch,
            preferences: empty, scope: scope, baseline: baseline, committedReplay: false)
        check(admitted.conflict == nil && admitted.preferences.local.document.profiles[upper]?.fields["playback"]?.value["audioLang"] == .string("fra"),
              "uppercase patch admits against lowercase absent evidence and canonical authenticated baseline")
        check(admitted.preferences.local.document.profiles[upper]?.fields["playback"]?.value["futurePlayback"] == base["futurePlayback"],
              "mixed-case sparse admission retains unknown nested playback siblings")
        check(try VortxNativeProfileEditHost.valueHash(immutableEvent) == eventFingerprint
              && VortxNativeProfileEditHost.valueHash(immutablePatch) == patchFingerprint,
              "admission does not rewrite immutable event, host bases, patch or fingerprint")
        let lowerPatch = VortxJSON.object([lower: patchFields])
        let alternate = try VortxNativeProfileEditHost.admit(event: event([upper: bases]), hostPatch: lowerPatch,
            preferences: empty, scope: scope, baseline: baseline, committedReplay: false)
        check(alternate.preferences.local.document == admitted.preferences.local.document,
              "lowercase patch and uppercase bases derive the identical canonical register")
        let absentMismatch = try VortxNativeProfileEditHost.admit(event: immutableEvent, hostPatch: immutablePatch,
            preferences: admitted.preferences, scope: scope, baseline: baseline, committedReplay: false)
        check(absentMismatch.conflict != nil && absentMismatch.preferences.local.document == admitted.preferences.local.document,
              "absent evidence cannot overwrite an existing canonical register")
        let stale = event([lower: .object(["playback": .object(["clock": .integer(0), "actor": .string(actor),
            "valueHash": .string(try VortxNativeProfileEditHost.valueHash(base))])])], clock: 1)
        check(try VortxNativeProfileEditHost.admit(event: stale, hostPatch: immutablePatch, preferences: admitted.preferences,
            scope: scope, baseline: baseline, committedReplay: false).conflict != nil,
              "stale mixed-case register evidence remains a conflict")
        for remote in [false, true] {
            let replay = try VortxNativeProfileEditHost.admit(event: immutableEvent, hostPatch: lowerPatch,
                preferences: admitted.preferences, scope: scope, baseline: baseline, committedReplay: !remote, remoteReplay: remote)
            check(replay.conflict == nil && replay.preferences.local.document == admitted.preferences.local.document,
                  "\(remote ? "remote" : "committed") replay finds the exact canonical register")
        }
        var newerNull = admitted.preferences
        try newerNull.edit(profileID: lower, fields: ["playback": .null], scope: scope)
        for remote in [false, true] {
            let replay = try VortxNativeProfileEditHost.admit(event: immutableEvent, hostPatch: lowerPatch,
                preferences: newerNull, scope: scope, baseline: baseline, committedReplay: !remote, remoteReplay: remote)
            check(replay.conflict == nil && replay.preferences.local.document == newerNull.local.document,
                  "\(remote ? "remote" : "committed") replay cannot resurrect a newer canonical null")
        }

        var legacy = host.local
        legacy.document.profiles[lower] = legacy.document.profiles.removeValue(forKey: upper)
        legacy.websitePending = [immutableEvent]
        let reopened = try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: JSONEncoder().encode(legacy))
        check(reopened.local.document == host.local.document && reopened.local.websitePending == [immutableEvent],
              "sealed local reopen canonicalizes only profile identity and retains opaque siblings and immutable journal")
        check(try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: reopened.encoded()).local.document == reopened.local.document,
              "canonical sealed payload reopens without register drift")
        var crossCase = reopened
        try crossCase.merge(carrier([upper: .object(["fields": .object(["playback": register(.null, clock: 9)])])]), scope: scope)
        try crossCase.merge(carrier([lower: fields]), scope: scope)
        check(crossCase.local.document.profiles[upper]?.fields["playback"]?.value == .null
              && crossCase.local.document.profiles[upper]?.fields["playback"]?.clock == 9
              && crossCase.local.document.profiles[upper]?.fields["playback"]?.actor == actor
              && crossCase.local.document.profiles[lower] == nil
              && crossCase.local.document.profiles[upper]?.fields["futurePreference"] == reopened.local.document.profiles[upper]?.fields["futurePreference"],
              "separate case variants merge by existing register order without resurrecting newer null or dropping opaque siblings")
        let crossCaseBefore = crossCase.local.document
        rejects("case aliases with equal register stamp and different values fail closed") {
            try crossCase.merge(carrier([lower: .object(["fields": .object(["playback": register(base, clock: 9)])])]), scope: scope)
        }
        check(crossCase.local.document == crossCaseBefore, "cross-case divergent register rejection makes no host commit")
        let before = host.local.document
        rejects("equal lowercase/uppercase remote groups are rejected atomically") {
            try host.merge(carrier([lower: fields, upper: fields]), scope: scope)
        }
        check(host.local.document == before, "ambiguous ingress makes no host commit")
        legacy.document.profiles[upper] = legacy.document.profiles[lower]
        rejects("equal canonical aliases in a sealed document are rejected") {
            _ = try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: JSONEncoder().encode(legacy))
        }
        for mode in ["ordinary", "committed", "remote"] {
            rejects("duplicate host bases fail closed before \(mode) admission") {
                _ = try VortxNativeProfileEditHost.admit(event: event([lower: bases, upper: bases]), hostPatch: immutablePatch,
                    preferences: admitted.preferences, scope: scope, baseline: baseline, committedReplay: mode == "committed", remoteReplay: mode == "remote")
            }
            rejects("duplicate host patch groups fail closed before \(mode) admission") {
                _ = try VortxNativeProfileEditHost.admit(event: immutableEvent, hostPatch: .object([lower: patchFields, upper: patchFields]),
                    preferences: admitted.preferences, scope: scope, baseline: baseline, committedReplay: mode == "committed", remoteReplay: mode == "remote")
            }
        }
        rejects("empty host patch cannot bypass duplicate base rejection") {
            _ = try VortxNativeProfileEditHost.admit(event: event([lower: bases, upper: bases]), hostPatch: .object([:]),
                preferences: empty, scope: scope, baseline: baseline, committedReplay: false)
        }
        check(try VortxNativeProfileEditHost.admit(event: .object(["eventId": .string(eventID)]), hostPatch: .object([:]),
            preferences: empty, scope: scope, baseline: baseline, committedReplay: false).conflict == nil,
              "kernel-only empty patch still needs no fabricated host evidence")
        var ambiguousLocal = host
        ambiguousLocal.local.document.profiles[lower] = ambiguousLocal.local.document.profiles[upper]
        let ambiguousBefore = ambiguousLocal.local.document
        rejects("local edit rejects preexisting canonical aliases before mutation") {
            try ambiguousLocal.edit(profileID: lower, fields: ["avatar": .string("must not commit")], scope: scope)
        }
        check(ambiguousLocal.local.document == ambiguousBefore, "ambiguous local edit makes no host commit")
        rejects("admission rejects ambiguous current groups before inspecting registers") {
            _ = try VortxNativeProfileEditHost.admit(event: immutableEvent, hostPatch: immutablePatch,
                preferences: ambiguousLocal, scope: scope, baseline: baseline, committedReplay: true)
        }
        rejects("missing mixed-case base remains invalid rather than inventing evidence") {
            _ = try VortxNativeProfileEditHost.admit(event: event([:]), hostPatch: immutablePatch,
                preferences: empty, scope: scope, baseline: baseline, committedReplay: false)
        }
    }
}
