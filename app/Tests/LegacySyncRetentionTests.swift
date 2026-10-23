import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { print("FAIL \(label)"); exit(1) }
    print("PASS \(label)")
}
private func equal(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
}
private func projected(existingVortx: [String: Any]?, v: [String: Any]) -> [String: Any] {
    /* PRODUCTION_SUMMARY_RETURN */
}

@main private enum RetentionChecks {
    static func main() throws {
        let peer: [String: Any] = ["addonIdentityVersion": 3, "future": ["nested": [1, 2, 3]],
            "activeProfile": "removed", "profiles": [
                ["id": "live", "name": "Old", "futureProfile": ["keep": true], "settings": [
                    "avatar": "old", "futureSetting": 17, "playback": ["audioLang": "old", "subBrightness": "80", "futurePlayback": ["opaque": true]]]],
                ["id": "removed", "futureProfile": "must not resurrect"]],
            "roster": [["id": "live", "name": "Old", "pin": "old-pin", "futureRoster": true,
                "playback": ["audioLang": "old", "subBrightness": "80", "futurePlayback": true],
                "discovery": ["regionOverride": "old", "futureDiscovery": true],
                "addonPreferences": ["rankingOverride": ["useAddonOrder": false, "futureRanking": true], "futurePreference": true]]],
            "byProfile": ["live": ["futureBucket": true,
                "library": [["id": "title", "t": 99, "futureRow": ["keep": true]], ["id": "removed-title", "futureRow": true]],
                "watched": ["title": ["w": ["old"], "ma": ["old": 1], "futureWatched": true]],
                "removed": [["keys": ["removed-title"], "removedAt": 1, "futureRemoval": true]]],
                "removed": ["futureBucket": "must not resurrect"]],
            "library": [["id": "owner-title", "t": 30, "futureOwnerRow": true], ["id": "gone", "futureOwnerRow": true]],
            "addons": [["transportUrl": "https://synthetic.invalid/addon", "futureAddon": true,
                "manifest": ["id": "addon", "futureManifest": true], "flags": ["official": false, "futureFlag": true]]],
            "deletedAddons": ["previously-removed"],
            "deletedAddonsTs": ["addon": ["removedAt": 1, "futureStamp": true]]]
        let next: [String: Any] = ["profiles": [["id": "live", "name": "New", "settings": ["avatar": "new", "playback": ["audioLang": "new"]]]],
            "roster": [["id": "live", "name": "New", "playback": ["audioLang": "new"],
                "discovery": ["regionOverrideCaptured": true], "addonPreferences": ["rankingOverride": ["useAddonOrder": true]]]],
            "deletedProfiles": ["removed"], "byProfile": ["live": ["library": [["id": "title", "t": 0]],
                "watched": ["title": ["w": [], "ua": ["old": 2]]],
                "removed": [["keys": ["removed-title"], "removedAt": 2]]], "removed": ["futureBucket": "must not resurrect"]],
            "library": [["id": "owner-title", "t": 0]],
            "addons": [["transportUrl": "https://synthetic.invalid/addon", "manifest": ["id": "addon"], "flags": ["official": true]]],
            "deletedAddonsTs": ["addon": ["addedAt": 2]]]
        let result = projected(existingVortx: peer, v: next)
        expect(equal(result["future"], peer["future"]) && result["addonIdentityVersion"] as? Int == 3, "unknown top-level summary and identity marker survive")
        let profile = (result["profiles"] as! [[String: Any]])[0]
        let settings = profile["settings"] as! [String: Any]
        let playback = settings["playback"] as! [String: Any]
        expect(equal(profile["futureProfile"], ["keep": true]) && settings["futureSetting"] as? Int == 17 && playback["futurePlayback"] != nil,
               "unknown profile, settings, and playback children survive rewritten boundaries")
        expect(profile["name"] as? String == "New" && playback["audioLang"] as? String == "new" && playback["subBrightness"] == nil,
               "known update and omitted known optional deletion remain authoritative")
        let roster = (result["roster"] as! [[String: Any]])[0]
        expect(roster["pin"] == nil && roster["futureRoster"] as? Bool == true, "PIN clear does not erase unrelated roster extension")
        expect((roster["discovery"] as! [String: Any])["regionOverride"] == nil && (roster["discovery"] as! [String: Any])["futureDiscovery"] as? Bool == true,
               "explicit captured discovery reset retains unknown discovery field")
        let buckets = result["byProfile"] as! [String: Any]
        let bucket = buckets["live"] as! [String: Any]
        let rows = bucket["library"] as! [[String: Any]]
        expect(bucket["futureBucket"] as? Bool == true && rows.count == 1 && rows[0]["futureRow"] != nil && rows[0]["t"] as? Int == 0,
               "overlay row extensions survive zero progress without resurrecting removed rows")
        let watched = (bucket["watched"] as! [String: [String: Any]])["title"]!
        expect(watched["futureWatched"] as? Bool == true && equal(watched["w"], [String]()) && watched["ma"] == nil,
               "watched unmark and removed known clock do not become blind unions")
        expect(buckets["removed"] == nil && result["activeProfile"] == nil && (result["profiles"] as! [[String: Any]]).count == 1,
               "profile tombstone and active-profile clear exclude old unknown children")
        expect((result["library"] as! [[String: Any]]).count == 1 && (result["library"] as! [[String: Any]])[0]["futureOwnerRow"] as? Bool == true,
               "owner membership selection retains included row extensions only")
        let addon = (result["addons"] as! [[String: Any]])[0]
        expect(addon["futureAddon"] as? Bool == true && (addon["manifest"] as! [String: Any])["futureManifest"] as? Bool == true && (addon["flags"] as! [String: Any])["futureFlag"] as? Bool == true,
               "addon descriptor, manifest and flag extensions survive")
        let stamp = (result["deletedAddonsTs"] as! [String: [String: Any]])["addon"]!
        expect(result["deletedAddons"] == nil && stamp["removedAt"] == nil && stamp["futureStamp"] as? Bool == true,
               "re-add retires known tombstone without erasing its extension")
        let oldData = try JSONSerialization.data(withJSONObject: peer["roster"]!)
        let nextData = try JSONSerialization.data(withJSONObject: next["roster"]!)
        let carried = try JSONSerialization.jsonObject(with: LegacySyncRetention.rosterData(existing: oldData, replacement: nextData)!) as! [[String: Any]]
        expect(carried[0]["futureRoster"] as? Bool == true && carried[0]["pin"] == nil, "settings plist roster receives identical retention/deletion behavior")
        expect(LegacySyncRetention.rosterData(existing: Data("corrupt".utf8), replacement: nextData) == nil, "unreadable prior roster refuses settings rewrite")
        let cleared = projected(existingVortx: peer, v: ["roster": [["id": "live", "name": "New"]]])
        expect((cleared["roster"] as! [[String: Any]])[0]["playback"] == nil, "explicit whole playback reset is not resurrected as an invalid future-only object")
        let oldEnvelope = try JSONSerialization.data(withJSONObject: ["format": "vortx-backup", "payloadBase64": "old", "futureEnvelope": ["keep": true]])
        let newEnvelope = try JSONSerialization.data(withJSONObject: ["format": "vortx-backup", "payloadBase64": "new"])
        let envelope = try JSONSerialization.jsonObject(with: LegacySyncRetention.settingsEnvelope(existing: oldEnvelope.base64EncodedString(), replacement: newEnvelope)!) as! [String: Any]
        expect(envelope["futureEnvelope"] != nil && envelope["payloadBase64"] as? String == "new", "settings envelope extensions follow the new payload")
    }
}
