import Foundation

@main enum VortxNativeBootstrapArchiveTests {
    static func check(_ condition: Bool, line: Int = #line) { precondition(condition, "bootstrap archive at \(line)") }
    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func main() throws {
        let configured = "https://addon.example/CaseSensitive?secret=fixture-only"
        let preferences: [String: Any] = [
            "kcfallback.legacy": "fixture-secret", "future.pref": ["color": "blue", "key": "non-secret-record-id"],
            "stremiox.profiles": try data([["id": "historical-owner", "pin": "sha256:fixture", "future": ["custom": true]]]),
            "nested": try data(["password": "nested-fixture-secret", "retained": 4,
                                 "jsonString": #"{"token":"string-hidden-fixture","unknown":true}"#]),
            "date": Date(timeIntervalSince1970: 42)
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        let backup = try data(["format": "vortx-backup", "schema": 1, "payloadBase64": plist.base64EncodedString(), "futureEnvelope": ["keep": true]])
        let source: [String: Any] = ["settings": backup.base64EncodedString(), "apiKeys": ["provider": "fixture-key"],
                                     "addons": [["transportUrl": configured]], "unknown": ["key": "movie:tt1", "fractionalClock": 1000.125],
                                     "vortx": ["deletedAddonsTs": [configured: ["addedAt": 1000.125]]],
                                     "authKey": "fixture-auth", "nested": ["accessToken": "fixture-access", "safe": ["name": "keep"]]]
        let material = try data(["schemaVersion": 1, "roster": [], "watches": ["owner": [["lastPlayedAtMs": 1000.125]]]])
        let archive = try VortxNativeBootstrapArchive.encode(document: data(source), material: material)
        try VortxNativeBootstrapArchive.validate(archive)
        let object = try JSONSerialization.jsonObject(with: archive) as! [String: Any]
        let host = object["hostDocument"] as! [String: Any]
        check(host["authKey"] == nil && host["apiKeys"] == nil)
        check((host["addons"] as! [[String: Any]])[0]["transportUrl"] as? String == configured)
        check(((host["vortx"] as! [String: Any])["deletedAddonsTs"] as! [String: Any])[configured] != nil)
        check((host["unknown"] as! [String: Any])["key"] as? String == "movie:tt1")
        check((host["unknown"] as! [String: Any])["fractionalClock"] as? Double == 1000.125)
        let safeBackup = try JSONSerialization.jsonObject(with: Data(base64Encoded: host["settings"] as! String)!) as! [String: Any]
        let safeDomain = try PropertyListSerialization.propertyList(from: Data(base64Encoded: safeBackup["payloadBase64"] as! String)!, options: [], format: nil) as! [String: Any]
        check(safeDomain["kcfallback.legacy"] == nil && safeDomain["date"] as? Date == Date(timeIntervalSince1970: 42))
        check((safeBackup["futureEnvelope"] as! [String: Bool])["keep"] == true)
        let nested = try JSONSerialization.jsonObject(with: safeDomain["nested"] as! Data) as! [String: Any]
        check(nested["password"] == nil && nested["retained"] as? Int == 4)
        let nestedString = try JSONSerialization.jsonObject(with: Data((nested["jsonString"] as! String).utf8)) as! [String: Any]
        check(nestedString["token"] == nil && nestedString["unknown"] as? Bool == true)
        check(try data(object["legacyImportMaterial"]!) == material)
        let exclusions = object["excludedCredentialPaths"] as! [String]
        check(exclusions.contains("/settings/payloadBase64/kcfallback.legacy") && exclusions.contains("/nested/accessToken"))
        let genericJSON = try data(["token": "must-be-excluded", "keep": "value", "url": configured]).base64EncodedString()
        let genericPlist = try PropertyListSerialization.data(fromPropertyList: ["password": "must-be-excluded", "date": Date(timeIntervalSince1970: 5)], format: .xml, options: 0).base64EncodedString()
        let nestedBackup = try VortxNativeBootstrapArchive.encode(document: data(["future": ["backup": backup.base64EncodedString(),
                                                                                              "json": genericJSON, "plist": genericPlist]]))
        try VortxNativeBootstrapArchive.validate(nestedBackup)
        let nestedObject = try JSONSerialization.jsonObject(with: nestedBackup) as! [String: Any]
        let future = (nestedObject["hostDocument"] as! [String: Any])["future"] as! [String: String]
        let futureBackup = try JSONSerialization.jsonObject(with: Data(base64Encoded: future["backup"]!)!) as! [String: Any]
        let futureDomain = try PropertyListSerialization.propertyList(from: Data(base64Encoded: futureBackup["payloadBase64"] as! String)!, options: [], format: nil) as! [String: Any]
        check(futureDomain["kcfallback.legacy"] == nil && futureDomain["date"] as? Date == Date(timeIntervalSince1970: 42))
        let futureJSON = try JSONSerialization.jsonObject(with: Data(base64Encoded: future["json"]!)!) as! [String: String]
        check(futureJSON["token"] == nil && futureJSON["keep"] == "value" && futureJSON["url"] == configured)
        let futurePlist = try PropertyListSerialization.propertyList(from: Data(base64Encoded: future["plist"]!)!, options: [], format: nil) as! [String: Any]
        check(futurePlist["password"] == nil && futurePlist["date"] as? Date == Date(timeIntervalSince1970: 5))
        check((nestedObject["excludedCredentialPaths"] as! [String]).contains("/future/backup/payloadBase64/kcfallback.legacy"))
        let unchanged = try data(["keep": true]).base64EncodedString()
        let unchangedArchive = try JSONSerialization.jsonObject(with: VortxNativeBootstrapArchive.encode(document: data(["future": unchanged]))) as! [String: Any]
        check((unchangedArchive["hostDocument"] as! [String: String])["future"] == unchanged)
        let malformedBackup = try data(["format": "vortx-backup", "schema": 1, "payloadBase64": "opaque"]).base64EncodedString()
        do { _ = try VortxNativeBootstrapArchive.encode(document: data(["future": malformedBackup])); fatalError("nested malformed backup was archived") } catch {}
        for malformed in [Data(#"{"token":"unfinished"# .utf8), Data("bplist00broken".utf8)] {
            do { _ = try VortxNativeBootstrapArchive.encode(document: data(["future": malformed.base64EncodedString()])); fatalError("recognizable malformed container was archived") } catch {}
        }
        var deep: [String: Any] = ["keep": true]
        for _ in 0..<70 { deep = ["nested": deep] }
        do { _ = try VortxNativeBootstrapArchive.encode(document: data(deep)); fatalError("unbounded archive recursion") } catch {}
        for source: [String: Any] in [["futureSecretBox": "opaque"], ["settings": "not-a-backup"], ["custom_token": "unknown"]] {
            do { _ = try VortxNativeBootstrapArchive.encode(document: data(source)); fatalError("ambiguous source was archived") } catch {}
        }
        let opaque = try PropertyListSerialization.data(fromPropertyList: ["unknown": Data([0, 255, 0])], format: .binary, options: 0)
        let opaqueBackup = try data(["format": "vortx-backup", "schema": 1, "payloadBase64": opaque.base64EncodedString()])
        do { _ = try VortxNativeBootstrapArchive.encode(document: data(["settings": opaqueBackup.base64EncodedString()])); fatalError("opaque preference was archived") } catch {}
        do { _ = try VortxNativeBootstrapArchive.encode(document: data([:]), material: data(["schemaVersion": 1, "password": "not-allowed"])); fatalError("typed input was silently sanitized") } catch {}
        var injected = object; injected["password"] = "not-allowed-at-archive-root"
        do { try VortxNativeBootstrapArchive.validate(data(injected)); fatalError("unknown archive root persisted") } catch {}
        print("Native bootstrap archive: exact fractional material, full noncredential settings/unknown fields, nested credential exclusions and ambiguity fences passed")
    }
}
