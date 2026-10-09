import Foundation

@main
struct VortxNativeProfileEditHostTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "website host fixture line \(line)") }
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
            "subColor": .string("white"), "subBackground": .string("none")])
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
        print("Website host-CAS: shared JavaScript canonical hashes, absent authenticated baseline, sparse siblings, conflict atomicity and exact/newer replay passed")
    }
}
