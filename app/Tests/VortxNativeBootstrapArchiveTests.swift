import Foundation
import CryptoKit

@main enum VortxNativeBootstrapArchiveTests {
    static func check(_ condition: Bool, line: Int = #line) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: bootstrap archive at \(line)\n".utf8))
            exit(1)
        }
    }
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
        let innerJSON = #"{"token":"quoted-hidden-fixture","unknown":true}"#
        let quotedJSON = String(decoding: try JSONSerialization.data(withJSONObject: innerJSON, options: [.fragmentsAllowed]), as: UTF8.self)
        let quotedArchive = try JSONSerialization.jsonObject(with: VortxNativeBootstrapArchive.encode(document: data(["future": quotedJSON]))) as! [String: Any]
        let sanitizedQuoted = (quotedArchive["hostDocument"] as! [String: String])["future"]!
        let sanitizedInner = try JSONSerialization.jsonObject(with: Data(sanitizedQuoted.utf8), options: [.fragmentsAllowed]) as! String
        let sanitizedObject = try JSONSerialization.jsonObject(with: Data(sanitizedInner.utf8)) as! [String: Any]
        check(sanitizedObject["token"] == nil && sanitizedObject["unknown"] as? Bool == true)
        check((quotedArchive["excludedCredentialPaths"] as! [String]).contains("/future/token"))
        let unchanged = try data(["keep": true]).base64EncodedString()
        let hashThatLooksStructured = "e9" + String(repeating: "0", count: 62)
        let evidence = try data(["sourceDocumentSha256": hashThatLooksStructured, "typedCarrierFingerprint": hashThatLooksStructured,
            "nativeSync": ["legacyImport": ["acceptedFingerprints": [hashThatLooksStructured], "ownAccountSourceHistory": [
                "00000000-0000-0000-0000-00000000A11C": [hashThatLooksStructured: hashThatLooksStructured]]]]])
        let hashArchive = try VortxNativeBootstrapArchive.encode(document: evidence)
        try VortxNativeBootstrapArchive.validate(hashArchive)
        try ownAccountSlotSourceHistory()
        try structuredCarrierAdmission()
        try archiveInspectionDiagnostics()
        do { try literalProfileDisplayFields() }
        catch { print("FAIL: producer-shaped literal profile text blocked account preparation: \(error)"); exit(1) }
        do { try literalAddonManifestLabels() }
        catch { print("FAIL: literal add-on manifest text blocked account preparation: \(error)"); exit(1) }
        do { try literalLegacyLibraryNames() }
        catch { print("FAIL: literal library title blocked account preparation: \(error)"); exit(1) }
        do { try literalSeriesSourceAddonNames() }
        catch { print("FAIL: literal series source add-on name blocked account preparation: \(error)"); exit(1) }
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
        try membershipReceiptRetention()
        let exactMaterial = try data(["schemaVersion": 1, "original": 125.375])
        let originalSource = try VortxNativeBootstrapArchive.encode(document: data(["original": ["exact": true], "token": "excluded"]), material: exactMaterial)
        let enclosing = try VortxNativeBootstrapArchive.encode(document: data(["fresh": true, "password": "excluded"]), authenticatedSourceArchive: originalSource)
        let enclosingObject = try JSONSerialization.jsonObject(with: enclosing) as! [String: Any]
        check(try data(enclosingObject["legacyImportMaterial"]!) == exactMaterial)
        check(Set(enclosingObject["excludedCredentialPaths"] as! [String]) == ["/token", "/password"])
        _ = try VortxNativeBootstrapArchive.encode(document: data([:]), material: exactMaterial, authenticatedSourceArchive: originalSource)
        do {
            _ = try VortxNativeBootstrapArchive.encode(document: data([:]), material: data(["schemaVersion": 1, "different": true]), authenticatedSourceArchive: originalSource)
            fatalError("flattening discarded a conflicting retained material witness")
        } catch is VortxNativeBootstrapArchive.RecoveryConflict {}
        do {
            _ = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: enclosing)
            fatalError("flattening discarded a distinct nested authenticated source")
        } catch is VortxNativeBootstrapArchive.RecoveryConflict {}
        let unchangedSource = try JSONSerialization.jsonObject(with: originalSource) as! [String: Any]
        check(try data(unchangedSource["legacyImportMaterial"]!) == exactMaterial)
        print("Native bootstrap archive: exact fractional material, full noncredential settings/unknown fields, nested credential exclusions and ambiguity fences passed")
    }

    static func structuredCarrierAdmission() throws {
        typealias Object = [String: Any]
        func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        func quoted(_ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        func rejects(_ operation: () throws -> Void) throws {
            do { try operation(); check(false) }
            catch VortxNativeBootstrapArchive.Failure.malformed {}
        }
        let empty = try VortxNativeBootstrapArchive.encode(document: data([:]))
        let pairs = [
            (#""future""#, #""future""#),
            (#""\u0066uture""#, #""future""#),
            (#""future""#, #""fut\u0075re""#),
            (#""é""#, #""e\u0301""#),
            (#""\u00e9""#, #""é""#),
            (#""😀""#, #""\ud83d\ude00""#),
            (#""a\\b""#, #""a\u005cb""#),
            (#""""#, #""""#)
        ]
        var rejectedCarriers = 0
        for (left, right) in pairs {
            let secret = left + #":{"token":"fixture-shadow-only"}"#
            let safe = right + #":{"keep":true}"#
            for members in [[secret, safe], [safe, secret]] {
                let object = "{" + members.joined(separator: ",") + "}"
                for raw in [object, "[" + object + "]", "{\"outer\":[" + object + "]}"] {
                    for carrier in [raw, try quoted(raw), Data(raw.utf8).base64EncodedString(), try quoted(Data(raw.utf8).base64EncodedString())] {
                        let original: Object = ["future": carrier]
                        let bytes = try data(original); let originalHash = digest(bytes)
                        try rejects { _ = try VortxNativeBootstrapArchive.credentialFreeDocument(original) }
                        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: bytes) }
                        try rejects { try VortxNativeBootstrapArchive.validate(data(["schemaVersion": 1,
                            "hostDocument": original, "excludedCredentialPaths": []])) }
                        try rejects { _ = try VortxNativeBootstrapArchive.replacingHostDocument(in: empty, with: bytes) }
                        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data([:]), material: data([
                            "schemaVersion": 1, "future": carrier])) }
                        check(digest(bytes) == originalHash)
                        check(try data(original) == bytes)
                        rejectedCarriers += 1
                    }
                }
                let raw = Data(object.utf8)
                // Outer document/envelope and preference Data are also materialized by Foundation.
                try rejects { _ = try VortxNativeBootstrapArchive.encode(document: raw) }
                try rejects { _ = try VortxNativeBootstrapArchive.replacingHostDocument(in: empty, with: raw) }
                let envelope = Data(("{\"schemaVersion\":1,\"hostDocument\":" + object + ",\"excludedCredentialPaths\":[]}").utf8)
                try rejects { try VortxNativeBootstrapArchive.validate(envelope) }
                let backup = try SettingsBackup.encode(domain: ["future": raw], bundleID: "fixture.bundle", app: "Fixture")
                try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["settings": backup.base64EncodedString()])) }
            }
        }
        check(rejectedCarriers == 192)
        // Reject even duplicate safe values: unchanged exclusion count is not uniqueness proof.
        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["future": #"{"same":true,"same":true}"#])) }
        let duplicateEnvelope = Data(#"{"format":"vortx-backup","schema":1,"payloadBase64":"YWJj","payloadBase64":"YWJj"}"#.utf8)
        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["settings": duplicateEnvelope.base64EncodedString()])) }

        let longNumber = "0." + String(repeating: "0", count: 80) + "1"
        let exact = " \n{\"z\":[9007199254740992,-0.0,1e100," + longNumber + ",true,null],\"a\":\"slash\\/quote\\\"\",\"é\":1,\"A\":2,\"a2\":3} \t"
        let positives = [exact, "[" + exact + "]", #"{"left":{"same":1},"right":{"same":2}}"#,
                         #"{"a":1,"A":2,"\ud83d\ude00":"ordinary","unknown":{"keep":"yes"}}"#]
        func preserved(_ carrier: String) throws {
            let input = Data(carrier.utf8)
            let sourceBytes = Data(base64Encoded: carrier) ?? input
            let expectedHash = digest(sourceBytes)
            let source: Object = ["sourceDocumentBase64": carrier, "sourceDocumentSha256": expectedHash,
                                  "unknown": ["complete": true]]
            let encoded = try VortxNativeBootstrapArchive.encode(document: data(source))
            try VortxNativeBootstrapArchive.validate(encoded)
            let result = try JSONSerialization.jsonObject(with: encoded) as! Object
            let host = result["hostDocument"] as! Object
            check(Data((host["sourceDocumentBase64"] as! String).utf8) == input)
            let stored = host["sourceDocumentBase64"] as! String
            check(digest(Data(base64Encoded: stored) ?? Data(stored.utf8)) == expectedHash)
            check(host["sourceDocumentSha256"] as? String == expectedHash)
            check((host["unknown"] as? [String: Bool])?["complete"] == true)
            let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: encoded)
            try VortxNativeBootstrapArchive.validate(retained)
            let retainedHost = (try JSONSerialization.jsonObject(with: retained) as! Object)["authenticatedSourceArchive"] as! Object
            check(Data((retainedHost["sourceDocumentBase64"] as! String).utf8) == input)
            check(source["sourceDocumentBase64"] as? String == carrier)
        }
        for positive in positives {
            try preserved(positive)
            try preserved(quoted(positive))
            try preserved(Data(positive.utf8).base64EncodedString())
        }
        // Whitelist only the observed raw-Foundation quirks; a future decoder fix may succeed.
        // Every matrix entry still runs the normalized production assertions; no dynamic skips.
        let encodings: [(String.Encoding, [UInt8])] = [(.utf8, [0xef, 0xbb, 0xbf]),
            (.utf16LittleEndian, [0xff, 0xfe]), (.utf16BigEndian, [0xfe, 0xff]),
            (.utf32LittleEndian, [0xff, 0xfe, 0, 0]), (.utf32BigEndian, [0, 0, 0xfe, 0xff])]
        var fragmentProbeFailures = 0
        var objectProbeFailures = 0
        var preservedFragments = 0
        var checkedEncodings = 0
        let safeBackup = try SettingsBackup.encode(domain: ["future": "safe"], bundleID: "fixture.bundle", app: "Fixture")
        let archiveText = String(decoding: empty, as: UTF8.self)
        for (encoding, bom) in encodings {
            for prefix in [Data(), Data(bom)] {
                func encoded(_ text: String) -> Data { prefix + text.data(using: encoding)! }
                let rawObjectFailureAllowed = encoding == .utf32LittleEndian && !prefix.isEmpty
                let fragments = [(#""日""#, "日"), (#""😀""#, "😀"),
                    (#""\u65e5""#, "日"), (#""\ud83d\ude00""#, "😀"),
                    (#""quote\"slash\\日""#, "quote\"slash\\日")]
                for (fragmentIndex, (fragment, expected)) in fragments.enumerated() {
                    let fragmentBytes = encoded(fragment)
                    let rawFragmentFailureAllowed = rawObjectFailureAllowed || (prefix.isEmpty && fragmentIndex < 2
                        && (encoding == .utf16LittleEndian || encoding == .utf16BigEndian))
                    do {
                        let decoded = try JSONSerialization.jsonObject(with: fragmentBytes, options: [.fragmentsAllowed]) as? String
                        check(decoded == expected)
                    } catch {
                        let failure = error as NSError
                        check(rawFragmentFailureAllowed && failure.domain == NSCocoaErrorDomain && failure.code == 3840)
                        fragmentProbeFailures += 1
                    }
                    try preserved(fragmentBytes.base64EncodedString())
                    preservedFragments += 1
                }
                let bytes = encoded(#"{"future":[1,true,"ordinary"]}"#)
                do {
                    let decoded = try JSONSerialization.jsonObject(with: bytes) as? Object
                    check(decoded != nil)
                    check(try data(decoded!) == data(["future": [1, true, "ordinary"] as [Any]]))
                } catch {
                    let failure = error as NSError
                    check(rawObjectFailureAllowed && failure.domain == NSCocoaErrorDomain && failure.code == 3840)
                    objectProbeFailures += 1
                }
                try preserved(bytes.base64EncodedString())
                // Prove normalized production inspection, not just unchanged opaque fallback:
                // every encoding/BOM form rejects duplicates in both orders and removes a unique
                // explicit credential through the existing exclusion policy.
                for raw in [#"{"future":{"token":"fixture-shadow-only"},"future":{"keep":true}}"#,
                            #"{"future":{"keep":true},"future":{"token":"fixture-shadow-only"}}"#] {
                    let ambiguous = encoded(raw)
                    try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["future": ambiguous.base64EncodedString()])) }
                    try rejects { _ = try VortxNativeBootstrapArchive.encode(document: ambiguous) }
                    let backup = try SettingsBackup.encode(domain: ["future": ambiguous], bundleID: "fixture.bundle", app: "Fixture")
                    try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["settings": backup.base64EncodedString()])) }
                }
                let unique = encoded(#"{"token":"fixture-excluded-only","keep":true}"#)
                let uniqueHash = digest(unique)
                let clean = try VortxNativeBootstrapArchive.encode(document: data(["future": unique.base64EncodedString()]))
                try VortxNativeBootstrapArchive.validate(clean)
                let cleanEnvelope = try JSONSerialization.jsonObject(with: clean) as! Object
                let cleanHost = cleanEnvelope["hostDocument"] as! Object
                let cleanBytes = Data(base64Encoded: cleanHost["future"] as! String)!
                let cleanObject = try JSONSerialization.jsonObject(with: cleanBytes) as! Object
                check(cleanObject["token"] == nil && cleanObject["keep"] as? Bool == true)
                check(!String(decoding: cleanBytes, as: UTF8.self).contains("fixture-excluded-only"))
                check((cleanEnvelope["excludedCredentialPaths"] as! [String]).contains("/future/token"))
                check(digest(unique) == uniqueHash)

                // Cover raw document/material/archive ingress and all archive reread paths.
                let rawArchive = try VortxNativeBootstrapArchive.encode(document: bytes,
                    material: encoded(#"{"schemaVersion":1,"future":{"keep":true}}"#))
                try VortxNativeBootstrapArchive.validate(rawArchive)
                let unicodeArchive = encoded(archiveText)
                try VortxNativeBootstrapArchive.validate(unicodeArchive)
                _ = try VortxNativeBootstrapArchive.replacingHostDocument(in: unicodeArchive, with: bytes)
                _ = try VortxNativeBootstrapArchive.mergingRecoveryEnvelope(unicodeArchive, prior: unicodeArchive)
                _ = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: unicodeArchive)
                let unicodeSettings = encoded(String(decoding: safeBackup, as: UTF8.self))
                let settingsArchive = try VortxNativeBootstrapArchive.encode(document: data(["settings": unicodeSettings.base64EncodedString()]))
                try VortxNativeBootstrapArchive.validate(settingsArchive)
                // Successfully transcoded but malformed brace containers must not become opaque.
                do {
                    _ = try VortxNativeBootstrapArchive.encode(document: data(["future": encoded("{").base64EncodedString()]))
                    check(false)
                } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
                checkedEncodings += 1
            }
        }
        check(fragmentProbeFailures <= 9 && objectProbeFailures <= 1)
        check(preservedFragments == 50 && checkedEncodings == 10)
        print("Raw Foundation baseline: fragments accepted=\(50 - fragmentProbeFailures) rejected=\(fragmentProbeFailures); objects accepted=\(10 - objectProbeFailures) rejected=\(objectProbeFailures)")
        // This guard must not inherit the unrelated watched parser's 2 MiB limit.
        let large = "{\"future\":\"" + String(repeating: "x", count: 2 * 1024 * 1024 + 1) + "\"}"
        try preserved(Data(large.utf8).base64EncodedString())
        // The scanner's raw-JSON depth128 is a deliberate new fail-closed admission bound.
        let deep = String(repeating: "[", count: 140) + "0" + String(repeating: "]", count: 140)
        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["future": deep])) }
        let deepExcluded = Data(("{\"token\":" + deep + ",\"keep\":true}").utf8)
        let deepHash = digest(deepExcluded)
        let decodedExcluded = try JSONSerialization.jsonObject(with: deepExcluded) as! Object
        // The existing dictionary sanitizer excludes token before traversing its value. Preserve
        // this positive to expose the stricter raw-admission behavior, not claim it is redundant.
        let sanitizedExcluded = try VortxNativeBootstrapArchive.credentialFreeDocument(decodedExcluded)
        let sanitizedObject = try JSONSerialization.jsonObject(with: sanitizedExcluded) as! Object
        check(sanitizedObject["token"] == nil && sanitizedObject["keep"] as? Bool == true)
        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: deepExcluded) }
        try rejects { _ = try VortxNativeBootstrapArchive.encode(document: data(["future": String(decoding: deepExcluded, as: UTF8.self)])) }
        check(digest(deepExcluded) == deepHash)
        // A credential-only subtree exceeding sanitizer64 but within scanner128 still takes the
        // existing exclusion path; no blanket deep-credential rejection or numeric cap is added.
        let within = String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100)
        let withinBytes = Data(("{\"token\":" + within + ",\"keep\":true}").utf8)
        let withinHash = digest(withinBytes)
        let withinArchive = try VortxNativeBootstrapArchive.encode(document: withinBytes)
        try VortxNativeBootstrapArchive.validate(withinArchive)
        let withinEnvelope = try JSONSerialization.jsonObject(with: withinArchive) as! Object
        let withinHost = withinEnvelope["hostDocument"] as! Object
        check(withinHost["token"] == nil && withinHost["keep"] as? Bool == true)
        check((withinEnvelope["excludedCredentialPaths"] as! [String]).contains("/token"))
        check(digest(withinBytes) == withinHash)
        print("Structured JSON carriers: duplicate/canonical collision rejection and hash-bound original-byte retention passed")
    }

    static func ownAccountSlotSourceHistory() throws {
        // Exact schema-4 slot identifiers and source fingerprint from the website carrier fixture.
        // A typed SHA-256 fingerprint can decode to a leading brace under base64 probing.
        let profile = "00000000-0000-0000-0000-00000000B22C"
        let slot = "own:86d5e2a3d69627f41d23a87c36f06a5351a97392d06e62b9fc1e429889ea5a47"
        let sourceDigest = "7b04ac2853c664a15255369c5424b2099df38715a43d56b80feb9edd1824d7e5"
        let fingerprints = ["e563698769b687e82770b9150d5b655c0c4b7e3cbee814d75f58b512157336d7",
                            "e9" + String(repeating: "0", count: 62)]
        for fingerprint in fingerprints {
            let document: [String: Any] = ["nativeSync": ["schemaVersion": 4, "accountSlots": [profile: ["slots": [slot: [
                "sourceHistory": [sourceDigest: fingerprint], "future": ["token": "fixture-hidden", "keep": true]
            ]]]]]]
            let clean: Data
            do { clean = try VortxNativeBootstrapArchive.credentialFreeDocument(document) }
            catch { preconditionFailure("Valid native own-account slot sourceHistory fingerprint rejected: \(error)") }
            func checkHistory(_ host: [String: Any]) {
                let native = host["nativeSync"] as! [String: Any]
                let accounts = native["accountSlots"] as! [String: Any]
                let slots = (accounts[profile] as! [String: Any])["slots"] as! [String: Any]
                let account = slots[slot] as! [String: Any]
                check((account["sourceHistory"] as! [String: String])[sourceDigest] == fingerprint)
                let future = account["future"] as! [String: Any]
                check(future["token"] == nil && future["keep"] as? Bool == true)
            }
            checkHistory(try JSONSerialization.jsonObject(with: clean) as! [String: Any])
            let archive = try VortxNativeBootstrapArchive.encode(document: data(document))
            try VortxNativeBootstrapArchive.validate(archive)
            checkHistory((try JSONSerialization.jsonObject(with: archive) as! [String: Any])["hostDocument"] as! [String: Any])
            let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: archive)
            try VortxNativeBootstrapArchive.validate(retained)
            checkHistory((try JSONSerialization.jsonObject(with: retained) as! [String: Any])["authenticatedSourceArchive"] as! [String: Any])
            // The protocol exemption must not make an arbitrary digest-shaped carrier opaque.
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(["future": ["sourceHistory": [sourceDigest: fingerprint]]])
                preconditionFailure("Nonprotocol sourceHistory fingerprint skipped credential inspection")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
        }
    }

    static func literalProfileDisplayFields() throws {
        // Uses the actual SettingsBackup.encode implementation extracted by the source-unit runner.
        // The roster Data has ProfileStore.persist's JSON-array shape. Its deliberately noncanonical
        // formatting must not affect semantic conservation; archive Data is inspected/re-encoded.
        // Original input bytes remain unchanged. This is not a recovered customer leaf.
        typealias Object = [String: Any]
        let profileID = "00000000-0000-0000-0000-00000000A11C"
        let privateKey = "fixture-private-preference"
        func row(name: Any = "Fixture", avatar: Any = "🍿") -> Object {
            ["id": profileID, "name": name, "avatar": avatar, "accentID": "ember",
             "oled": false, "textScale": 1.0, "usesOwnAccount": false, "isOwner": true,
             "familyEdit": false, "isKids": false, "future": ["safe": true]]
        }
        func roster(_ rows: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        func document(_ preference: Any, key: String = "stremiox.profiles") throws -> Object {
            var domain: Object = [privateKey: ["safe": "unchanged"],
                                  "fixture-date": Date(timeIntervalSince1970: 42)]
            // Negative cases deliberately use privateKey as the preference key. Assignment
            // models that one persisted key without a duplicate-key dictionary-literal trap.
            domain[key] = preference
            let backup = try SettingsBackup.encode(domain: domain, bundleID: "fixture.bundle", app: "Fixture",
                                                   now: Date(timeIntervalSince1970: 10))
            return ["settings": backup.base64EncodedString(), "futureHost": ["safe": true]]
        }
        func domain(_ host: Object) throws -> Object {
            let backup = try JSONSerialization.jsonObject(with: Data(base64Encoded: host["settings"] as! String)!) as! Object
            return try PropertyListSerialization.propertyList(from: Data(base64Encoded: backup["payloadBase64"] as! String)!,
                                                               options: [], format: nil) as! Object
        }
        func inspect(_ host: Object, expected: Data) throws {
            let values = try domain(host)
            check(values["stremiox.profiles"] is Data)
            let actualRows = try JSONSerialization.jsonObject(with: values["stremiox.profiles"] as! Data)
            let expectedRows = try JSONSerialization.jsonObject(with: expected)
            check(try data(actualRows) == data(expectedRows))
            check((values[privateKey] as? [String: String])?["safe"] == "unchanged")
            check(values["fixture-date"] as? Date == Date(timeIntervalSince1970: 42))
            check((host["futureHost"] as? [String: Bool])?["safe"] == true)
        }
        // First case must fail against the old owning inspector, before any new-policy assertions.
        let positive: [(String, String)] = [("Fixture", "["), ("Fixture", "{"),
            ("[Kids]", "🍿"), ("{Family} Room", "🍿"), ("[", "🍿"), ("{", "🍿"),
            ("[Kids] Family viewing", "{"), ("[日本語] 家族", "["), ("[true]", "🍿"), ("Normal", "A")]
        for (name, avatar) in positive {
            let rawRoster = try roster([row(name: name, avatar: avatar)])
            let original = try document(rawRoster)
            let originalSettings = original["settings"] as! String
            let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(original)
            try inspect(try JSONSerialization.jsonObject(with: clean) as! Object, expected: rawRoster)
            let archive = try VortxNativeBootstrapArchive.encode(document: data(original))
            try VortxNativeBootstrapArchive.validate(archive)
            let envelope = try JSONSerialization.jsonObject(with: archive) as! Object
            check((envelope["excludedCredentialPaths"] as! [String]).isEmpty)
            try inspect(envelope["hostDocument"] as! Object, expected: rawRoster)
            let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: archive)
            try VortxNativeBootstrapArchive.validate(retained)
            try inspect((try JSONSerialization.jsonObject(with: retained) as! Object)["authenticatedSourceArchive"] as! Object,
                        expected: rawRoster)
            check(original["settings"] as? String == originalSettings)
            check((try domain(original))["stremiox.profiles"] as? Data == rawRoster)
        }
        func refused(_ input: Object) throws {
            let before = try data(input)
            var messages: [String] = []
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(input, diagnostics: { messages.append($0) })
                preconditionFailure("Profile context escaped into an opaque carrier")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
            check(try data(input) == before)
            check(messages.count == 1)
            // Diagnostics may contain only schema words and closed categories, never private inputs.
            for hidden in [profileID, privateKey, "stremiox.profiles", "fixture-hidden", "bingeGroup"] {
                check(!messages[0].contains(hidden))
            }
        }
        let label = "[Kids] Family viewing"
        for malformed in [#"{'token':'fixture-hidden'}"#, #"{token=fixture-hidden;}"#, #"{"token":"unfinished"#,
                          #"[true] {"token":"fixture-hidden"}"#, "[[Kids]]", "[Kids]no separator",
                          "[" + String(repeating: "x", count: 65) + "] Room", "bplist00broken"] {
            try refused(document(roster([row(name: malformed)])))
        }
        try refused(document(roster([row(avatar: label)]))) // Avatar is not a manifest/name label.
        try refused(document(roster([row(name: "Fixture", avatar: "[ ")])))
        var unknown = row(); unknown["future"] = ["avatar": "["]
        try refused(document(roster([unknown])))
        var sibling = row(); sibling["accentID"] = "["
        try refused(document(roster([sibling])))
        var wrongIdentity = row(avatar: "["); wrongIdentity["id"] = "not-a-profile-uuid"
        try refused(document(roster([wrongIdentity])))
        var missingName = row(avatar: "["); missingName.removeValue(forKey: "name")
        try refused(document(roster([missingName])))
        try refused(document(roster(["0": row(avatar: "[")])))
        try refused(document(roster([[row(avatar: "[")]])))
        try refused(document(roster([row(avatar: ["avatar": "["])])))
        try refused(document(roster([row(avatar: "[")]), key: privateKey))
        try refused(document(["stremiox.profiles": try roster([row(avatar: "[")])], key: privateKey))
        // Only the real JSON Data preference carrier establishes the new role.
        let rawRoster = try roster([row(avatar: "[")])
        try refused(document(String(decoding: rawRoster, as: UTF8.self)))
        try refused(document(rawRoster.base64EncodedString()))
        try refused(document([row(avatar: "[")]))
        let plistRoster = try PropertyListSerialization.data(fromPropertyList: [row(avatar: "[")], format: .binary, options: 0)
        try refused(document(plistRoster))
        let quotedBracket = String(decoding: try JSONSerialization.data(withJSONObject: "[", options: [.fragmentsAllowed]), as: UTF8.self)
        let quotedLabel = String(decoding: try JSONSerialization.data(withJSONObject: label, options: [.fragmentsAllowed]), as: UTF8.self)
        for encoded in [quotedBracket, quotedLabel, Data("[".utf8).base64EncodedString(),
                        Data(#"{"token":"unfinished"#.utf8).base64EncodedString(),
                        Data("bplist00broken".utf8).base64EncodedString()] {
            try refused(document(roster([row(name: encoded)])))
            try refused(document(roster([row(avatar: encoded)])))
        }
        // Real nested credential carriers are still inspected and sanitized, not exempted as labels.
        let secret = #"{"token":"fixture-hidden","keep":true}"#
        let quotedSecret = String(decoding: try JSONSerialization.data(withJSONObject: secret, options: [.fragmentsAllowed]), as: UTF8.self)
        let secretPlist = try PropertyListSerialization.data(fromPropertyList: ["password": "fixture-hidden", "keep": true],
                                                            format: .binary, options: 0).base64EncodedString()
        let carriers: [(String, (String) throws -> Object)] = [
            (secret, { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object }),
            (quotedSecret, {
                let inner = try JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) as! String
                return try JSONSerialization.jsonObject(with: Data(inner.utf8)) as! Object
            }),
            (Data(secret.utf8).base64EncodedString(), { try JSONSerialization.jsonObject(with: Data(base64Encoded: $0)!) as! Object }),
            (secretPlist, { try PropertyListSerialization.propertyList(from: Data(base64Encoded: $0)!, options: [], format: nil) as! Object })
        ]
        for (carrier, unwrap) in carriers {
            for field in ["name", "avatar"] {
                var item = row(); item[field] = carrier
                let input = try document(roster([item]))
                let archive = try VortxNativeBootstrapArchive.encode(document: data(input))
                try VortxNativeBootstrapArchive.validate(archive)
                let envelope = try JSONSerialization.jsonObject(with: archive) as! Object
                let safeDomain = try domain(envelope["hostDocument"] as! Object)
                let safeRows = try JSONSerialization.jsonObject(with: safeDomain["stremiox.profiles"] as! Data) as! [Object]
                let nested = try unwrap(safeRows[0][field] as! String)
                check(nested["token"] == nil && nested["password"] == nil && nested["keep"] as? Bool == true)
                check(!(envelope["excludedCredentialPaths"] as! [String]).isEmpty)
                // The immutable original input still contains its exact source Data on failure/retry.
                let originalRows = try JSONSerialization.jsonObject(with: (try domain(input))["stremiox.profiles"] as! Data) as! [Object]
                check(originalRows[0][field] as? String == carrier)
            }
        }
        // Build raw bytes: constructing a Swift Dictionary would erase the duplicate-key witness
        // before the production inspector sees it. Both orders are required; Foundation's chosen
        // duplicate member is deliberately not assumed. Escaped spellings collide after decoding.
        let duplicateMembers: [[String]] = [
            [#""future":{"token":"fixture-shadow-secret","keep":true}"#, #""future":{"safe":true}"#],
            [#""future":{"futureCredentialBox":"fixture-shadow-secret"}"#, #""future":{"safe":true}"#],
            [#""\u0066uture":{"token":"fixture-shadow-secret","keep":true}"#, #""future":{"safe":true}"#],
            [#""futureCredentialBox":"fixture-shadow-secret""#, #""futureCredentialBox":{"safe":true}"#],
            [#""to\u006ben":"fixture-shadow-secret""#, #""token":"fixture-other-secret""#]
        ]
        func containsCredentialKey(_ value: Any) -> Bool {
            if let object = value as? Object {
                return object.contains { key, child in
                    key == "token" || key == "password" || key.lowercased().contains("credential") || containsCredentialKey(child)
                }
            }
            if let array = value as? [Any] { return array.contains(where: containsCredentialKey) }
            return false
        }
        var duplicateCases = 0
        for pair in duplicateMembers {
            for members in [pair, Array(pair.reversed())] {
                let prefix = #"[{"id":"00000000-0000-0000-0000-00000000A11C","name":"Fixture","avatar":"[","sentinel":{"keep":true},"#
                let raw = Data((prefix + members.joined(separator: ",") + "}]").utf8)
                let input = try document(raw)
                let inputBytes = try data(input)
                func checkAccepted(_ host: Object) throws {
                    let stored = (try domain(host))["stremiox.profiles"] as! Data
                    let text = String(decoding: stored, as: UTF8.self)
                    check(!text.contains("fixture-shadow-secret") && !text.contains("fixture-other-secret"))
                    check(stored != raw) // Never preserve a collapsed raw duplicate-key carrier.
                    let rows = try JSONSerialization.jsonObject(with: stored) as! [Object]
                    check(!containsCredentialKey(rows))
                    check(rows.count == 1 && rows[0]["id"] as? String == profileID)
                    check(rows[0]["name"] as? String == "Fixture" && rows[0]["avatar"] as? String == "[")
                    check((rows[0]["sentinel"] as? [String: Bool])?["keep"] == true)
                }
                do {
                    let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(input)
                    try checkAccepted(try JSONSerialization.jsonObject(with: clean) as! Object)
                    let archive = try VortxNativeBootstrapArchive.encode(document: data(input))
                    try VortxNativeBootstrapArchive.validate(archive)
                    let envelope = try JSONSerialization.jsonObject(with: archive) as! Object
                    try checkAccepted(envelope["hostDocument"] as! Object)
                    let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: archive)
                    try VortxNativeBootstrapArchive.validate(retained)
                    try checkAccepted((try JSONSerialization.jsonObject(with: retained) as! Object)["authenticatedSourceArchive"] as! Object)
                } catch VortxNativeBootstrapArchive.Failure.ambiguousCredentialCarrier {
                    // A retained unknown credential-like key is a safe rejection, not an exemption.
                } catch VortxNativeBootstrapArchive.Failure.opaquePreference {
                    // A future stricter inspector may reject the entire ambiguous carrier.
                } catch VortxNativeBootstrapArchive.Failure.malformed {
                    // Structural rejection is also safe; no replacement archive was returned.
                }
                check(try data(input) == inputBytes)
                check((try domain(input))["stremiox.profiles"] as? Data == raw)
                duplicateCases += 1
            }
        }
        check(duplicateCases == 10)
        var ambiguous = row(avatar: "["); ambiguous["futureCredentialBox"] = "fixture-hidden"
        do {
            _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(roster([ambiguous])))
            preconditionFailure("Unknown credential carrier was granted profile display semantics")
        } catch VortxNativeBootstrapArchive.Failure.ambiguousCredentialCarrier {}
        // Provider-authored opaque identities retain their existing fail-closed policy.
        try refused(document(roster(["global": ["bingeGroup": label]]), key: "stremiox.sourcePins.fixture-profile"))
        try refused(document(roster(["fixture-series": ["bingeGroup": label]]), key: "stremiox.seriesSourceSticky.fixture-profile"))
        let classified: [(String, Any, String, String)] = [
            ("stremiox.profiles", try roster([row(avatar: "[ ")]), "profile_roster", "/*/*/*"),
            ("stremiox.profiles.watch.fixture-private-owner", try roster(["fixture-private-series": ["poster": "["]]), "profile_watch", "/*/*/*"),
            ("stremiox.sourcePins.fixture-private-owner", try roster(["global": ["bingeGroup": "["]]), "source_pin", "/*/*/*"),
            ("stremiox.seriesSourceSticky.fixture-private-owner", try roster(["fixture-private-series": ["bingeGroup": "["]]), "series_source_choice", "/*/*/*"),
            ("vortx.owner.history.v1.fixture-private-owner", try roster([["v": "["]]), "owner_history", "/*/*/*"),
            ("vortx.forYou.local", try roster(["fixture-private-owner": ["fixture-private-field": "["]]), "for_you_local", "/*/*/*")
        ]
        for (key, value, family, suffix) in classified {
            var messages: [String] = []
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(value, key: key),
                                                                          diagnostics: { messages.append($0) })
                preconditionFailure("Diagnostic fixture was unexpectedly accepted")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
            check(messages == ["archive_inspection result=failed reason=opaque_preference field=/settings/payloadBase64" + suffix
                               + " carrier=plain_text_prefix preference_family=" + family])
            for hidden in [key, "fixture-private-owner", "fixture-private-series", "fixture-private-field", "bingeGroup"] {
                check(!messages[0].contains(hidden))
            }
        }
        print("Issue #262: profile display semantic conservation, unchanged inputs, duplicate-key credential fences and context controls passed")
    }

    static func literalAddonManifestLabels() throws {
        // #263's five masked path segments match /vortx/addons/0/manifest/name.
        // Add-on display labels are text, not necessarily JSON just because they start with '['.
        // This is a synthetic reproduction, not a recovered customer value.
        typealias Object = [String: Any]
        let profile = "00000000-0000-0000-0000-00000000A11C"
        let url = "https://addon.example/manifest.json"
        func descriptor(_ name: Any, description: Any = "Fixture", extra: Object = [:]) -> Object {
            var manifest: Object = ["id": "fixture.community", "version": "1.0.0", "name": name, "description": description]
            manifest.merge(extra) { _, value in value }
            return ["transportUrl": url, "manifest": manifest]
        }
        func journey(_ document: Object, material: Object? = nil) throws {
            var messages: [String] = []
            let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(document, diagnostics: { messages.append($0) })
            check(messages.isEmpty)
            check(NSDictionary(dictionary: try JSONSerialization.jsonObject(with: clean) as! Object).isEqual(to: document))
            let archive = try VortxNativeBootstrapArchive.encode(document: clean, material: material.map { try data($0) })
            try VortxNativeBootstrapArchive.validate(archive)
            let root = try JSONSerialization.jsonObject(with: archive) as! Object
            check(NSDictionary(dictionary: root["hostDocument"] as! Object).isEqual(to: document))
            if let material { check(NSDictionary(dictionary: root["legacyImportMaterial"] as! Object).isEqual(to: material)) }
            let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: archive)
            try VortxNativeBootstrapArchive.validate(retained)
            let retainedRoot = try JSONSerialization.jsonObject(with: retained) as! Object
            check(NSDictionary(dictionary: retainedRoot["authenticatedSourceArchive"] as! Object).isEqual(to: document))
        }
        let labels = ["[4K] Community catalog", "[Community]", "{Public} Catalog", " \n[EN] Films and shows.", "[日本語] アニメ", "[true]", "[123]"]
        var journeys = 0
        for label in labels {
            let addon = descriptor(label, description: label)
            let items: Object = ["items": [addon], "order": [url]]
            let register: Object = ["records": [url: ["value": addon]]]
            let response = try data(["result": ["addons": [addon]]]).base64EncodedString()
            let sourceEnvelope = try data(["addonsResponseBase64": response]).base64EncodedString()
            let documents: [Object] = [
                ["addons": [addon]], ["vortx": ["addons": [addon]]],
                ["nativeSync": ["legacyImport": ["baseline": ["addons": [profile: items]]]]],
                ["nativeSync": ["addons": [profile: register]]],
                ["nativeSync": ["accountSlots": [profile: ["slots": ["own:fixture": ["sourceBaseline": ["addons": items]]]]]]],
                ["ownAccountSources": [profile: ["sourceDocumentBase64": sourceEnvelope]]],
                ["webAddonEdits": ["events": [["mutations": [["addon": addon]], "observed": register]]]],
                ["future": ["descriptor": addon]] // Full descriptors are content-typed, not tied to one account path.
            ]
            for document in documents { try journey(document); journeys += 1 }
            try journey(["vortx": ["addons": [addon]]], material: ["schemaVersion": 1, "addons": [profile: items]])
            journeys += 1
        }
        func refused(_ document: Object) throws {
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document)
                preconditionFailure("Opaque or non-display carrier was admitted")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
        }
        let label = labels[0]
        try refused(["future": label])
        try refused(["name": label])
        try refused(["addons": [descriptor("Fixture", extra: ["future": label])]])
        try refused(["addons": [descriptor("Fixture", extra: ["extension": ["name": label]])]])
        // Missing descriptor identity is not sufficient evidence for display semantics.
        try refused(["addons": [["manifest": ["name": label, "id": "fixture", "version": "1.0.0"]]]])
        try refused(["addons": [["transportUrl": "file:///private/fixture", "manifest": ["name": label, "id": "fixture", "version": "1.0.0"]]]])
        let malformed = [#"{"token":"unfinished"#, #"[{"password":"unfinished"#, #"{'token':'fixture'}"#, "{token=fixture;}",
                         "[[Community]]", "[Community]no separator", "[" + String(repeating: "x", count: 65) + "] Label",
                         #"[true] {"token":"fixture-hidden"}"#, #"[123] {"password":"fixture-hidden"}"#,
                         #"[ ] {"token":"fixture-hidden"}"#, "[null] trailing"]
        for value in malformed {
            for field in ["name", "description"] {
                let addon = field == "name" ? descriptor(value) : descriptor("Fixture", description: value)
                try refused(["vortx": ["addons": [addon]]])
            }
        }
        for bytes in [Data("[Community]".utf8), Data(#"{"token":"unfinished"#.utf8), Data([0x7b, 0xff, 0]), Data("bplist00broken".utf8)] {
            try refused(["addons": [descriptor(bytes.base64EncodedString())]])
        }
        // Context never flows through arrays/objects or into an encoded container's inner strings.
        try refused(["addons": [descriptor([label])]])
        try refused(["addons": [descriptor(["name": label])]])
        let quotedLabel = String(decoding: try JSONSerialization.data(withJSONObject: label, options: [.fragmentsAllowed]), as: UTF8.self)
        try refused(["addons": [descriptor(quotedLabel)]])

        let secretJSON = #"{"token":"fixture-hidden","keep":true}"#
        let quotedSecret = String(decoding: try JSONSerialization.data(withJSONObject: secretJSON, options: [.fragmentsAllowed]), as: UTF8.self)
        let secretPlist = try PropertyListSerialization.data(fromPropertyList: ["password": "fixture-hidden", "keep": true], format: .binary, options: 0)
        let encoded: [(String, (String) throws -> Object)] = [
            (secretJSON, { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object }),
            (quotedSecret, { raw in
                let inner = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as! String
                return try JSONSerialization.jsonObject(with: Data(inner.utf8)) as! Object
            }),
            (Data(secretJSON.utf8).base64EncodedString(), { try JSONSerialization.jsonObject(with: Data(base64Encoded: $0)!) as! Object }),
            (secretPlist.base64EncodedString(), { try PropertyListSerialization.propertyList(from: Data(base64Encoded: $0)!, options: [], format: nil) as! Object })
        ]
        for (value, unwrap) in encoded {
            for field in ["name", "description"] {
                let addon = field == "name" ? descriptor(value) : descriptor("Fixture", description: value)
                let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(["addons": [addon]])
                let root = try JSONSerialization.jsonObject(with: clean) as! Object
                let manifest = ((root["addons"] as! [Object])[0]["manifest"] as! Object)
                let safe = try unwrap(manifest[field] as! String)
                check(safe["token"] == nil && safe["password"] == nil && safe["keep"] as? Bool == true)
            }
        }
        let sibling: Object = ["transportUrl": url, "token": "fixture-hidden", "manifest": [
            "id": "fixture.community", "version": "1.0.0", "name": label, "password": "fixture-hidden"
        ]]
        let cleanSibling = try JSONSerialization.jsonObject(with: VortxNativeBootstrapArchive.credentialFreeDocument(["addons": [sibling]])) as! Object
        let safeSibling = (cleanSibling["addons"] as! [Object])[0]
        check(safeSibling["token"] == nil && (safeSibling["manifest"] as! Object)["password"] == nil)

        var messages: [String] = []
        do {
            _ = try VortxNativeBootstrapArchive.credentialFreeDocument(["vortx": ["addons": [descriptor("[private:token]")]]], diagnostics: { messages.append($0) })
            preconditionFailure("Malformed display label was admitted")
        } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
        check(messages == ["archive_inspection result=failed reason=opaque_preference field=/vortx/addons/*/manifest/name carrier=plain_text_prefix"])
        print("Issue #263: \(journeys) exact display-text carrier journeys, nested credential inspection and malformed/opaque rejection controls passed")
    }

    static func literalLegacyLibraryNames() throws {
        // #262 reports /vortx/library/*/name with plain_text_prefix. The customer value
        // is unknown: these labels reproduce only the bounded literal-label class.
        typealias Object = [String: Any]
        func row(_ name: Any, type: Any = "movie", extra: Object = [:]) -> Object {
            var result: Object = ["id": "tt-fixture-library", "type": type, "name": name,
                                  "poster": "https://poster.example/fixture.jpg",
                                  "futureRow": ["keep": "unchanged", "clock": 125.375]]
            result.merge(extra) { _, value in value }
            return result
        }
        func document(_ entry: Object, legacyRoot: Bool = false) -> Object {
            let host: Object = legacyRoot ? ["library": [entry]] : ["vortx": ["library": [entry]]]
            return host.merging(["futureHost": ["keep": true]]) { current, _ in current }
        }
        func entry(_ host: Object, legacyRoot: Bool = false) -> Object {
            let bucket = legacyRoot ? host : host["vortx"] as! Object
            return (bucket["library"] as! [Object])[0]
        }
        func journey(_ source: Object) throws {
            let original = try data(source)
            let originalHash = SHA256.hash(data: original)
            let legacyRoot = source["library"] != nil
            let titleBytes = Data((entry(source, legacyRoot: legacyRoot)["name"] as! String).utf8)
            func checkHost(_ host: Object) {
                check(NSDictionary(dictionary: host).isEqual(to: source))
                check(Data((entry(host, legacyRoot: legacyRoot)["name"] as! String).utf8) == titleBytes)
                check((entry(host, legacyRoot: legacyRoot)["futureRow"] as! Object)["keep"] as? String == "unchanged")
                check((host["futureHost"] as! [String: Bool])["keep"] == true)
            }
            var messages: [String] = []
            let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(source, diagnostics: { messages.append($0) })
            check(messages.isEmpty)
            checkHost(try JSONSerialization.jsonObject(with: clean) as! Object)
            // Exercise raw original-document admission as well as the decoded preparation path.
            for bytes in [original, clean] {
                let archive = try VortxNativeBootstrapArchive.encode(document: bytes)
                try VortxNativeBootstrapArchive.validate(archive)
                let root = try JSONSerialization.jsonObject(with: archive) as! Object
                check((root["excludedCredentialPaths"] as! [String]).isEmpty)
                checkHost(root["hostDocument"] as! Object)
                let retained = try VortxNativeBootstrapArchive.encode(document: data(["fresh": true]), authenticatedSourceArchive: archive)
                try VortxNativeBootstrapArchive.validate(retained)
                let retainedRoot = try JSONSerialization.jsonObject(with: retained) as! Object
                checkHost(retainedRoot["authenticatedSourceArchive"] as! Object)
            }
            check(try data(source) == original && SHA256.hash(data: original) == originalHash)
        }
        let labels = ["[REC]", "[4K] Fixture title", "{Family} Film", " \n[日本語] アニメ", "[true]", "[123]"]
        for label in labels {
            for legacyRoot in [false, true] {
                try journey(document(row(label), legacyRoot: legacyRoot))
            }
        }
        // Preserve the downstream per-unit hold policy for unsupported legacy content types.
        try journey(document(row("[Live] Fixture channel", type: "channel")))
        func refused(_ source: Object) throws {
            let original = try data(source)
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(source)
                preconditionFailure("Unrecognized library display context was admitted")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
            check(try data(source) == original)
        }
        let label = "[REC] Fixture title"
        try refused(["name": label])
        try refused(["future": row(label)])
        try refused(["future": ["library": [row(label)]]])
        try refused(["vortx": ["future": ["library": [row(label)]]]])
        // Only actual source/archive ingress grants host roles. Decoding a parent or
        // forging a host field with an archive's name must never reacquire those roles.
        try refused(["authenticatedSourceArchive": document(row(label))])
        let encodedParents = [
            String(decoding: try data(["library": [row(label)]]), as: UTF8.self),
            try data(["library": [row(label)]]).base64EncodedString(),
            try PropertyListSerialization.data(fromPropertyList: ["library": [row(label)]], format: .xml, options: 0).base64EncodedString()
        ]
        for parent in encodedParents {
            try refused(["vortx": parent])
            try refused(["authenticatedSourceArchive": parent])
        }
        try refused(document(row("Fixture", extra: ["future": label])))
        try refused(document(row("Fixture", extra: ["extension": ["name": label]])))
        var missingID = row(label); missingID.removeValue(forKey: "id")
        try refused(document(missingID))
        var missingType = row(label); missingType.removeValue(forKey: "type")
        try refused(document(missingType))
        var malformedID = row(label); malformedID["id"] = "\n"
        try refused(document(malformedID))
        try refused(document(row(label, type: 1)))
        try refused(document(row([label])))
        try refused(document(row(["name": label])))
        let malformed = ["[", "{", #"{"token":"unfinished"#, #"[{"password":"unfinished"#,
                         #"{'token':'fixture'}"#, "{token=fixture;}", "[[REC]]", "[REC]no separator",
                         "[" + String(repeating: "x", count: 65) + "] Film",
                         #"[true] {"token":"fixture-hidden"}"#, #"[123] {"password":"fixture-hidden"}"#,
                         #"[REC] {"token":"fixture-hidden"}"#, #"[REC] ["fixture-hidden"]"#,
                         "[REC] bplist00broken", "[REC] <?xml broken", "[REC] \"quoted\"",
                         "[null] trailing", "bplist00broken", "<?xml broken"]
        for name in malformed { try refused(document(row(name))) }
        // Display roles never flow through a quoted string, base64 or another decoded carrier.
        let quotedLabel = String(decoding: try JSONSerialization.data(withJSONObject: label, options: [.fragmentsAllowed]), as: UTF8.self)
        try refused(document(row(quotedLabel)))
        for bytes in [Data(label.utf8), Data(#"{"token":"unfinished"#.utf8), Data([0x7b, 0xff, 0]), Data("bplist00broken".utf8)] {
            try refused(document(row(bytes.base64EncodedString())))
        }
        let secretJSON = #"{"token":"fixture-hidden","keep":true}"#
        let quotedSecret = String(decoding: try JSONSerialization.data(withJSONObject: secretJSON, options: [.fragmentsAllowed]), as: UTF8.self)
        let secretPlist = try PropertyListSerialization.data(fromPropertyList: ["password": "fixture-hidden", "keep": true], format: .binary, options: 0)
        let secretXML = String(decoding: try PropertyListSerialization.data(fromPropertyList: ["password": "fixture-hidden"], format: .xml, options: 0), as: UTF8.self)
        let beforeBase64 = ["\u{FEFF}", " \t\u{FEFF}\u{2003}\n\u{FEFF}",
                            String(repeating: " ", count: 64) + "\u{FEFF}" + String(repeating: "\u{00A0}", count: 32)]
        for carrier in [Data(secretJSON.utf8).base64EncodedString(), Data(quotedSecret.utf8).base64EncodedString(),
                        secretPlist.base64EncodedString(), Data(secretXML.utf8).base64EncodedString()] {
            for leading in beforeBase64 {
                try refused(document(row("[REC] " + leading + carrier)))
                try refused(document(row("[REC] " + leading + carrier + "\u{FEFF} \t")))
            }
        }
        let padding = [String(repeating: " ", count: 32), String(repeating: " ", count: 64),
                       String(repeating: "\u{2003}", count: 64),
                       "\u{FEFF}" + String(repeating: "\u{00A0}\u{2003}\n", count: 32) + "\u{FEFF}"]
        for leading in padding {
            for carrier in [secretJSON, quotedSecret, secretXML, "bplist00broken"] {
                let suffix = leading + carrier
                try refused(document(row("[REC] " + suffix)))
                try refused(document(row("[REC] " + Data(suffix.utf8).base64EncodedString())))
                // Normalize BOM-bearing UTF-16 before scanning all leading whitespace.
                let utf16 = Data([0xff, 0xfe]) + suffix.data(using: .utf16LittleEndian)!
                try refused(document(row("[REC] " + utf16.base64EncodedString())))
            }
            let paddedBinaryPlist = Data(leading.utf8) + secretPlist
            try refused(document(row("[REC] " + paddedBinaryPlist.base64EncodedString())))
        }
        let encoded: [(String, (String) throws -> Object)] = [
            (secretJSON, { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object }),
            (quotedSecret, { raw in
                let inner = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as! String
                return try JSONSerialization.jsonObject(with: Data(inner.utf8)) as! Object
            }),
            (Data(secretJSON.utf8).base64EncodedString(), { try JSONSerialization.jsonObject(with: Data(base64Encoded: $0)!) as! Object }),
            (secretPlist.base64EncodedString(), { try PropertyListSerialization.propertyList(from: Data(base64Encoded: $0)!, options: [], format: nil) as! Object })
        ]
        for (name, unwrap) in encoded {
            // A tag cannot convert a structured or encoded credential suffix into display text.
            try refused(document(row("[REC] " + name)))
            let source = document(row(name)), original = try data(document(row(name)))
            let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(source)
            let safeHost = try JSONSerialization.jsonObject(with: clean) as! Object
            let safe = try unwrap(entry(safeHost)["name"] as! String)
            check(safe["token"] == nil && safe["password"] == nil && safe["keep"] as? Bool == true)
            let archive = try VortxNativeBootstrapArchive.encode(document: original)
            try VortxNativeBootstrapArchive.validate(archive)
            let root = try JSONSerialization.jsonObject(with: archive) as! Object
            let expectedExclusions = ["/vortx/library/0/name/" + (name == secretPlist.base64EncodedString() ? "password" : "token")]
            check((root["excludedCredentialPaths"] as! [String]) == expectedExclusions)
            let stored = try unwrap(entry(root["hostDocument"] as! Object)["name"] as! String)
            check(stored["token"] == nil && stored["password"] == nil && stored["keep"] as? Bool == true)
            let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: archive)
            try VortxNativeBootstrapArchive.validate(retained)
            let retainedRoot = try JSONSerialization.jsonObject(with: retained) as! Object
            check((retainedRoot["excludedCredentialPaths"] as! [String]) == expectedExclusions)
            let retainedName = try unwrap(entry(retainedRoot["authenticatedSourceArchive"] as! Object)["name"] as! String)
            check(retainedName["token"] == nil && retainedName["password"] == nil && retainedName["keep"] as? Bool == true)
            check(try data(source) == original)
        }
        let siblingSource = document(row(label, extra: ["token": "fixture-hidden"]))
        let siblingClean = try JSONSerialization.jsonObject(with: VortxNativeBootstrapArchive.credentialFreeDocument(siblingSource)) as! Object
        check(entry(siblingClean)["token"] == nil && entry(siblingClean)["name"] as? String == label)
        let siblingArchive = try VortxNativeBootstrapArchive.encode(document: data(siblingSource))
        try VortxNativeBootstrapArchive.validate(siblingArchive)
        let siblingRoot = try JSONSerialization.jsonObject(with: siblingArchive) as! Object
        check((siblingRoot["excludedCredentialPaths"] as! [String]) == ["/vortx/library/0/token"])
        let siblingRetained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: siblingArchive)
        try VortxNativeBootstrapArchive.validate(siblingRetained)
        let siblingRetainedRoot = try JSONSerialization.jsonObject(with: siblingRetained) as! Object
        check((siblingRetainedRoot["excludedCredentialPaths"] as! [String]) == ["/vortx/library/0/token"])
        let retainedSibling = entry(siblingRetainedRoot["authenticatedSourceArchive"] as! Object)
        check(retainedSibling["token"] == nil && (retainedSibling["futureRow"] as! Object)["keep"] as? String == "unchanged")
        do {
            _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(row(label, extra: ["futureCredentialBox": "fixture-hidden"])))
            preconditionFailure("Unknown credential carrier inherited library display semantics")
        } catch VortxNativeBootstrapArchive.Failure.ambiguousCredentialCarrier {}
        // Raw duplicate witnesses must reach the production scanner before Foundation collapses them.
        let duplicates = [
            #""future":{"token":"fixture-hidden"},"future":{"keep":true}"#,
            #""future":{"keep":true},"future":{"token":"fixture-hidden"}"#,
            #""na\u006de":"[REC] Title","name":"Fixture""#
        ]
        for members in duplicates {
            let raw = Data((#"{"vortx":{"library":[{"id":"tt-fixture","type":"movie","name":"[REC] Title","# + members + "}]}}").utf8)
            let originalHash = SHA256.hash(data: raw)
            do {
                _ = try VortxNativeBootstrapArchive.encode(document: raw)
                preconditionFailure("Duplicate library source members were admitted")
            } catch VortxNativeBootstrapArchive.Failure.malformed {}
            check(SHA256.hash(data: raw) == originalHash)
        }
        let duplicateName = #"{"token":"fixture-hidden","to\u006ben":"fixture-other","keep":true}"#
        for name in [duplicateName, Data(duplicateName.utf8).base64EncodedString()] {
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(row(name)))
                preconditionFailure("Duplicate nested title members were admitted")
            } catch VortxNativeBootstrapArchive.Failure.malformed {}
        }
        var messages: [String] = []
        do {
            _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(row("[private:token]")), diagnostics: { messages.append($0) })
            preconditionFailure("Malformed library display label was admitted")
        } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
        check(messages == ["archive_inspection result=failed reason=opaque_preference field=/vortx/library/*/name carrier=plain_text_prefix"])
        print("Issue #262: typed legacy library labels, exact archive retention and unchanged-source credential/malformed controls passed")
    }

    static func literalSeriesSourceAddonNames() throws {
        // The attachment identifies the field/carrier, not the raw customer name.
        // These synthetic Choice-shaped values exercise the actual shipping inspector
        // and SettingsBackup.encode serializer, including the retained archive paths.
        typealias Object = [String: Any]
        let profile = "00000000-0000-0000-0000-00000000A11C"
        let preference = "stremiox.seriesSourceSticky." + profile
        let series = "tt-fixture-series"
        let label = "[Community] Fixture add-on"
        func choice(_ addon: Any, extra: Object = [:]) -> Object {
            var row: Object = ["addon": addon, "bingeGroup": "fixture-release", "ts": 125.375,
                               "audioLanguage": "en", "resolution": 1080,
                               "futureChoice": ["keep": true, "clock": 250.125]]
            row.merge(extra) { _, replacement in replacement }
            return row
        }
        func document(_ value: Any, key: String? = nil) throws -> Object {
            let domain: Object = [key ?? preference: value, "future.preference": ["keep": "unchanged"],
                                  "fixture.date": Date(timeIntervalSince1970: 42)]
            let settings = try SettingsBackup.encode(domain: domain, bundleID: "fixture.bundle", app: "Fixture",
                                                     now: Date(timeIntervalSince1970: 10))
            return ["settings": settings.base64EncodedString(), "futureHost": ["keep": true],
                    "ownAccountOverlayPending": ["fixture-pending": ["draft": "untouched"]]]
        }
        func domain(_ host: Object) throws -> Object {
            let envelope = try JSONSerialization.jsonObject(with: Data(base64Encoded: host["settings"] as! String)!) as! Object
            return try PropertyListSerialization.propertyList(from: Data(base64Encoded: envelope["payloadBase64"] as! String)!,
                                                               options: [], format: nil) as! Object
        }
        func rows(_ host: Object, key: String? = nil) throws -> Object {
            let values = try domain(host)
            check(values[key ?? preference] is Data)
            return try JSONSerialization.jsonObject(with: values[key ?? preference] as! Data) as! Object
        }
        func inspect(_ host: Object, expected: Object, key: String) throws {
            check(try data(rows(host, key: key)) == data(expected))
            let actual = (try rows(host, key: key))[series] as! Object
            check(Data((actual["addon"] as! String).utf8) == Data(((expected[series] as! Object)["addon"] as! String).utf8))
            let values = try domain(host)
            check((values["future.preference"] as! [String: String])["keep"] == "unchanged")
            check(values["fixture.date"] as? Date == Date(timeIntervalSince1970: 42))
            check((host["futureHost"] as! [String: Bool])["keep"] == true)
            check((host["ownAccountOverlayPending"] as! [String: [String: String]])["fixture-pending"]?["draft"] == "untouched")
        }
        for name in [label, "[RD+] Fixture", "{Public} Fixture", " \n[日本語] Fixture", "[true]", "[123]"] {
            for key in [preference, "stremiox.seriesSourceSticky.default"] {
                let expected: Object = [series: choice(name)]
                let raw = try data(expected)
                let input = try document(raw, key: key), original = try data(input)
                let hash = SHA256.hash(data: original)
                var diagnostics: [String] = []
                let clean = try VortxNativeBootstrapArchive.credentialFreeDocument(input, diagnostics: { diagnostics.append($0) })
                check(diagnostics.isEmpty)
                try inspect(try JSONSerialization.jsonObject(with: clean) as! Object, expected: expected, key: key)
                let archive = try VortxNativeBootstrapArchive.encode(document: original)
                try VortxNativeBootstrapArchive.validate(archive)
                let envelope = try JSONSerialization.jsonObject(with: archive) as! Object
                check((envelope["excludedCredentialPaths"] as! [String]).isEmpty)
                try inspect(envelope["hostDocument"] as! Object, expected: expected, key: key)
                let retained = try VortxNativeBootstrapArchive.encode(document: data([:]), authenticatedSourceArchive: archive)
                try VortxNativeBootstrapArchive.validate(retained)
                try inspect((try JSONSerialization.jsonObject(with: retained) as! Object)["authenticatedSourceArchive"] as! Object,
                            expected: expected, key: key)
                // Recovery merging compares opaque host values exactly. A second fresh
                // sanitizer pass may serialize the equivalent binary plist differently;
                // it is not authority to replace that archived settings string.
                var replacementHost = envelope["hostDocument"] as! Object
                replacementHost["futureReplacement"] = ["keep": true]
                let replaced = try VortxNativeBootstrapArchive.replacingHostDocument(in: archive, with: data(replacementHost))
                try VortxNativeBootstrapArchive.validate(replaced)
                let merged = try VortxNativeBootstrapArchive.mergingRecoveryEnvelope(archive, prior: replaced)
                try VortxNativeBootstrapArchive.validate(merged)
                let mergedHost = (try JSONSerialization.jsonObject(with: merged) as! Object)["hostDocument"] as! Object
                check((mergedHost["futureReplacement"] as! [String: Bool])["keep"] == true)
                try inspect((try JSONSerialization.jsonObject(with: merged) as! Object)["hostDocument"] as! Object,
                            expected: expected, key: key)
                check(try data(input) == original && SHA256.hash(data: original) == hash)
                check((try domain(input))[key] as? Data == raw)
            }
        }
        func refused(_ source: Object) throws {
            let original = try data(source)
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(source)
                preconditionFailure("Unrecognized or opaque series-choice carrier was admitted")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
            check(try data(source) == original)
        }
        let raw = try data([series: choice(label)])
        for key in ["future.unrecognized.preference", "stremiox.seriesSourceSticky.fixture-profile",
                    preference + ".undecodable", "stremiox.sourcePins." + profile] {
            try refused(document(raw, key: key))
        }
        try refused(["future": [series: choice(label)]])
        try refused(document([series: choice(label)])) // Data is the producer's carrier.
        try refused(document(String(decoding: raw, as: UTF8.self)))
        try refused(document(raw.base64EncodedString()))
        try refused(document(PropertyListSerialization.data(fromPropertyList: [series: choice(label)], format: .binary, options: 0)))
        var missingClock = choice(label); missingClock.removeValue(forKey: "ts")
        try refused(document(data([series: missingClock])))
        for invalid in [true as Any, "125.375" as Any] {
            try refused(document(data([series: choice(label, extra: ["ts": invalid])])))
        }
        try refused(document(data([series: choice(label, extra: ["resolution": true])])))
        try refused(document(data([series: choice(label, extra: ["bingeGroup": 5])])))
        try refused(document(data([series: choice("Fixture", extra: ["bingeGroup": label])])))
        try refused(document(data([series: choice("Fixture", extra: ["future": label])])))
        try refused(document(data([series: choice("Fixture", extra: ["extension": ["addon": label]])])))
        try refused(document(Data([0xff, 0, 1])))
        let secretJSON = #"{"token":"fixture-hidden","keep":true}"#
        let secretPlist = try PropertyListSerialization.data(fromPropertyList: ["password": "fixture-hidden", "keep": true], format: .binary, options: 0)
        let malformed = ["[", "{", #"{"token":"unfinished"#, "[[Community]]", "[Community]no separator",
                         "[" + String(repeating: "x", count: 65) + "] Fixture",
                         "[Community] " + secretJSON, "[Community] \"quoted\"", "[Community] bplist00broken",
                         "[Community] <?xml broken", "[true] trailing",
                         Data(label.utf8).base64EncodedString(), Data([0x7b, 0xff, 0]).base64EncodedString()]
        for name in malformed { try refused(document(data([series: choice(name)]))) }
        for carrier in [Data(secretJSON.utf8).base64EncodedString(), secretPlist.base64EncodedString()] {
            for padding in ["", "\u{FEFF}", String(repeating: " \u{2003}\n", count: 64) + "\u{FEFF}"] {
                try refused(document(data([series: choice("[Community] " + padding + carrier)])))
            }
        }
        let quotedLabel = String(decoding: try JSONSerialization.data(withJSONObject: label, options: [.fragmentsAllowed]), as: UTF8.self)
        try refused(document(data([series: choice(quotedLabel)])))
        // Valid nested carriers still follow credential exclusion, and never receive display context.
        for name in [secretJSON, Data(secretJSON.utf8).base64EncodedString()] {
            let input = try document(data([series: choice(name, extra: ["password": "fixture-sibling"])]))
            let original = try data(input)
            let archive = try VortxNativeBootstrapArchive.encode(document: original)
            try VortxNativeBootstrapArchive.validate(archive)
            let envelope = try JSONSerialization.jsonObject(with: archive) as! Object
            let safe = (try rows(envelope["hostDocument"] as! Object))[series] as! Object
            let nestedBytes = name == secretJSON ? Data((safe["addon"] as! String).utf8) : Data(base64Encoded: safe["addon"] as! String)!
            let nested = try JSONSerialization.jsonObject(with: nestedBytes) as! Object
            check(nested["token"] == nil && nested["keep"] as? Bool == true && safe["password"] == nil)
            let paths = envelope["excludedCredentialPaths"] as! [String]
            check(Set(paths) == ["/settings/payloadBase64/" + preference + "/" + series + "/addon/token",
                                 "/settings/payloadBase64/" + preference + "/" + series + "/password"])
            check(try data(input) == original)
        }
        do {
            _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(data([series: choice(label, extra: ["futureCredentialBox": "fixture-hidden"])])))
            preconditionFailure("Unknown credential carrier received display semantics")
        } catch VortxNativeBootstrapArchive.Failure.ambiguousCredentialCarrier {}
        let duplicates = [
            #"{"tt-fixture-series":{"addon":"[Community] Fixture","ts":125.375,"future":{"token":"fixture-hidden"},"future":{"keep":true}}}"#,
            #"{"tt-fixture-series":{"addon":"[Community] Fixture","ts":125.375,"future":{"keep":true},"future":{"token":"fixture-hidden"}}}"#,
            #"{"tt-fixture-series":{"addon":"[Community] Fixture","ad\u0064on":"Fixture","ts":125.375}}"#
        ]
        for duplicate in duplicates {
            let input = try document(Data(duplicate.utf8)), original = try data(input)
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(input)
                preconditionFailure("Ambiguous series-choice JSON was admitted")
            } catch VortxNativeBootstrapArchive.Failure.malformed {}
            check(try data(input) == original)
        }
        var messages: [String] = []
        do {
            _ = try VortxNativeBootstrapArchive.credentialFreeDocument(document(data([series: choice("[private:token]")])), diagnostics: { messages.append($0) })
            preconditionFailure("Malformed add-on label was admitted")
        } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
        check(messages == ["archive_inspection result=failed reason=opaque_preference field=/settings/payloadBase64/*/*/addon carrier=plain_text_prefix preference_family=series_source_choice"])
        print("Series-choice display names: typed preference admission, exact field retention, unchanged source and opaque/credential controls passed")
    }

    static func archiveInspectionDiagnostics() throws {
        var messages: [String] = []
        _ = try VortxNativeBootstrapArchive.credentialFreeDocument(["library": [["name": "Fixture title"]]],
                                                                 diagnostics: { messages.append($0) })
        check(messages.isEmpty)

        func rejected(_ source: [String: Any], field: String, carrier: String) throws {
            messages = []
            do {
                _ = try VortxNativeBootstrapArchive.credentialFreeDocument(source, diagnostics: { messages.append($0) })
                preconditionFailure("Opaque source unexpectedly accepted")
            } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
            check(messages == ["archive_inspection result=failed reason=opaque_preference field=" + field + " carrier=" + carrier])
        }
        try rejected(["settings": "fixture-private-malformed-settings"], field: "/settings", carrier: "settings_envelope")

        let privateKey = "https://private-user.example/Personal/manifest.json?key=fixture-private-value"
        let preferences = try PropertyListSerialization.data(fromPropertyList: [privateKey: Data([0, 255, 0])], format: .binary, options: 0)
        let backup = try data(["format": "vortx-backup", "schema": 1, "payloadBase64": preferences.base64EncodedString()])
        try rejected(["settings": backup.base64EncodedString()], field: "/settings/payloadBase64/*", carrier: "opaque_data")

        let profile = "00000000-0000-0000-0000-00000000B22C"
        let sourceDigest = String(repeating: "a", count: 64)
        try rejected(["nativeSync": ["accountSlots": [profile: ["slots": [privateKey: [
            "sourceHistory": [sourceDigest: Data([0, 255, 0])]
        ]]]]]], field: "/nativeSync/accountSlots/*/slots/*/sourceHistory/*", carrier: "opaque_data")
        try rejected(["private-personal-field": ["sourceHistory": [sourceDigest: "e9" + String(repeating: "0", count: 62)]]],
                     field: "/*/sourceHistory/*", carrier: "base64_prefix")
    }

    static func membershipReceiptRetention() throws {
        let scope = "account.fixture"
        let owner = "00000000-0000-0000-0000-00000000A11C"
        let digest = String(repeating: "a", count: 64)
        let receipt: [String: Any] = ["profileId": owner, "kind": "addon_install",
            "identity": "https://addon.example/retired/manifest.json", "sourceField": "/vortx/deletedAddonsTs",
            "receipt": ["deletedAddonsTs": ["https://addon.example/retired/manifest.json": ["addedAt": 1000.125, "removedAt": 0]],
                        "deletedAddons": [], "webAddonRemovals": []], "sourceDocumentSha256": digest]
        let source = try VortxNativeBootstrapArchive.encode(document: data(["ownAccountSources": [:]]))
        let archive = try VortxLegacyMembershipReceiptArchive.appending(data([receipt]), to: source,
            scope: scope, ownerProfileID: owner, sourceDocumentSHA256: digest)
        try VortxNativeBootstrapArchive.validate(archive)
        let host = (try JSONSerialization.jsonObject(with: archive) as! [String: Any])["hostDocument"] as! [String: Any]
        let pending = host[VortxLegacyMembershipReceiptArchive.key] as! [String: Any]
        let initial = try data(pending)
        var next = receipt; next["sourceDocumentSha256"] = String(repeating: "b", count: 64)
        let refreshed: [String: Any] = ["schemaVersion": 1, "scope": scope, "ownerProfileId": owner, "receipts": [next]]
        let merged = try VortxLegacyMembershipReceiptArchive.merging(initial, with: data(refreshed), scope: scope, ownerProfileID: owner)!
        let retained = (try JSONSerialization.jsonObject(with: merged) as! [String: Any])["receipts"] as! [[String: Any]]
        check(retained.count == 1 && retained[0]["sourceDocumentSha256"] as? String == digest)
        check((((retained[0]["receipt"] as! [String: Any])["deletedAddonsTs"] as! [String: Any])[receipt["identity"] as! String] as! [String: Any])["addedAt"] as? Double == 1000.125)
        next["receipt"] = ["deletedAddonsTs": [receipt["identity"] as! String: ["addedAt": 1000.875, "removedAt": 0]],
                           "deletedAddons": [], "webAddonRemovals": []]
        let changed: [String: Any] = ["schemaVersion": 1, "scope": scope, "ownerProfileId": owner, "receipts": [next]]
        let history = try VortxLegacyMembershipReceiptArchive.merging(merged, with: data(changed), scope: scope, ownerProfileID: owner)!
        check(((try JSONSerialization.jsonObject(with: history) as! [String: Any])["receipts"] as! [Any]).count == 2)
        check(try VortxLegacyMembershipReceiptArchive.merging(history, with: nil, scope: scope, ownerProfileID: owner) == history)
        do { _ = try VortxLegacyMembershipReceiptArchive.merging(history, with: nil, scope: "account.other", ownerProfileID: owner); fatalError("foreign scope accepted") } catch {}
        do { _ = try VortxLegacyMembershipReceiptArchive.appending(data([receipt]), to: source, scope: scope, ownerProfileID: owner,
                sourceDocumentSHA256: String(repeating: "c", count: 64)); fatalError("wrong source accepted") } catch {}
        var credential = receipt; credential["receipt"] = ["password": "fixture-only"]
        do { _ = try VortxLegacyMembershipReceiptArchive.appending(data([credential]), to: source, scope: scope, ownerProfileID: owner,
                sourceDocumentSHA256: digest); fatalError("credential carrier accepted") } catch {}
        var unknown = receipt; unknown["kind"] = "ignore_everything"
        let invalid: [String: Any] = ["schemaVersion": 1, "scope": scope, "ownerProfileId": owner, "receipts": [unknown]]
        do { _ = try VortxLegacyMembershipReceiptArchive.merging(nil, with: data(invalid), scope: scope, ownerProfileID: owner); fatalError("unknown pending kind accepted") } catch {}
        var malformedKind = receipt; malformedKind["sourceField"] = "/unrelated/path"
        var noSources = receipt; noSources["kind"] = "watch_identity_conflict"
        noSources["sourceField"] = "/vortx/byProfile/\(owner)/watch_identity_conflicts"; noSources["receipt"] = [:] as [String: Any]
        var wrongProfile = receipt; wrongProfile["kind"] = "profile_saved_overlay"
        wrongProfile["identity"] = "title"; wrongProfile["sourceField"] = "/vortx/byProfile/00000000-0000-0000-0000-00000000ABCD/library/0"
        wrongProfile["receipt"] = ["id": "title", "type": "series"]
        var wrongIdentity = wrongProfile; wrongIdentity["sourceField"] = "/vortx/byProfile/\(owner)/library/0"
        wrongIdentity["receipt"] = ["id": "different", "type": "series"]
        for malformed in [malformedKind, noSources, wrongProfile, wrongIdentity] {
            let candidate: [String: Any] = ["schemaVersion": 1, "scope": scope, "ownerProfileId": owner, "receipts": [malformed]]
            do { _ = try VortxLegacyMembershipReceiptArchive.merging(nil, with: data(candidate), scope: scope, ownerProfileID: owner); fatalError("malformed known kind accepted") } catch {}
        }
        let excessive: [String: Any] = ["schemaVersion": 1, "scope": scope, "ownerProfileId": owner, "receipts": Array(repeating: receipt, count: 10_001)]
        do { _ = try VortxLegacyMembershipReceiptArchive.merging(nil, with: data(excessive), scope: scope, ownerProfileID: owner); fatalError("unbounded journal accepted") } catch {}
        print("Pending membership receipts: exact values, account binding, no resurrection, bounded idempotent retention and credential fences passed")
    }
}
