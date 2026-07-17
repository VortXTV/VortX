// ExternalSyncToggleSyncTests: a standalone, runnable verification of the cross-surface carriage for the
// five Trakt / SIMKL toggles (ExternalSyncToggleSync.swift).
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so this
// follows the HouseholdCryptoTests / StreamRankingChipsTests convention: a self-contained executable run with
// the system toolchain. The REAL ExternalSyncToggleSync.swift is compiled in and is what gets exercised:
//
//     swiftc -o /tmp/extsync \
//       app/SourcesShared/ExternalSyncToggleSync.swift \
//       app/Tests/ExternalSyncToggleSyncTests.swift && /tmp/extsync
//
// Its one dependency, the `ExternalSyncToggle` enum, lives in ExternalScrobbleProvider.swift, which imports
// only Foundation but references TraktProvider / SIMKLProvider / TraktSyncEngine / TraktIDs from elsewhere in
// the app and so cannot link standalone. So, exactly as HouseholdCryptoTests does with the crypto primitives,
// that ONE enum is re-declared below, and `testShimMatchesRealEnum` then PARSES the real source and fails if
// the two ever drift. The logic under test is real; only the constant table is mirrored.
//
// The three load-bearing tests are the drift guards, because each invariant spans surfaces with no compiler
// link between them:
//   - testShimMatchesRealEnum ................ the five literal UserDefaults key strings
//   - testDefaultsMatchAppStorageDeclarations  every `defaultOn` vs that key's real @AppStorage default.
//     If those drift, a never-touched switch renders in one position while `isOn` resolves the other, and the
//     dashboard mirror publishes the wrong value to every surface. Nothing else catches it.
//   - testWireContractMatchesDashboard ....... the doc SHAPE the dashboard actually reads/writes. This one
//     pins a contract that lives in ANOTHER REPO (vortx-site/src/lib/vault.ts), which this runner cannot
//     open, so it asserts the shape literally rather than by parsing. Drift here is invisible at compile
//     time on both sides and is exactly how the playback.safetyMode app/web enum drift shipped.

import Foundation

// MARK: - Mirror of ExternalSyncToggle (SourcesShared/ExternalScrobbleProvider.swift:92-108)
//
// Verbatim copy, kept honest by testShimMatchesRealEnum. Do not "improve" it: it exists to match.

enum ExternalSyncToggle {
    static let traktScrobble = "vortx.trakt.scrobble"
    static let traktWatchlist = "vortx.trakt.watchlist"
    static let simklScrobble = "vortx.simkl.scrobble"
    static let simklWatchlist = "vortx.simkl.watchlist"
    static let traktImportWatched = "vortx.trakt.importWatched"

    static func isOn(_ key: String, default defaultOn: Bool = true) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultOn }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// Resolve a path inside `app/` from this test's own location, so the runner works from any cwd.
func appSource(_ relative: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // app/
        .appendingPathComponent(relative)
}

var failures: [String] = []
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures.append(what) }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want { failures.append("\(what): got \(got), want \(want)") }
}

/// Clear all five keys so each test starts from "user has never touched this switch".
func resetToggles() {
    for t in ExternalSyncToggleSync.toggles {
        UserDefaults.standard.removeObject(forKey: t.key)
    }
}

/// The service block out of a summary, for brevity in the assertions below.
func block(_ s: [String: Any], _ svc: String) -> [String: Any] { (s[svc] as? [String: Any]) ?? [:] }

// MARK: - 1. The table itself

func testTableShape() {
    expectEqual(ExternalSyncToggleSync.toggles.count, 5, "table carries exactly the five toggles")

    let keys = Set(ExternalSyncToggleSync.toggles.map(\.key))
    expectEqual(keys.count, 5, "no duplicate UserDefaults keys")
    // The keys are the contract with every other surface (Android reads the same strings). Pin them literally:
    // a rename here is a silent cross-surface break, not a refactor.
    expectEqual(keys, ["vortx.trakt.scrobble", "vortx.trakt.watchlist", "vortx.trakt.importWatched",
                       "vortx.simkl.scrobble", "vortx.simkl.watchlist"], "literal key strings")

    // Trakt owns three toggles, SIMKL two. importWatched is Trakt-only: the app has no such toggle on SIMKL
    // and vault.ts:1005-1006 deliberately never invents it there.
    expectEqual(Set(ExternalSyncToggleSync.toggles(for: .trakt).map(\.wire)), ["scrobble", "watchlist", "importWatched"],
                "trakt block carries its three toggles")
    expectEqual(Set(ExternalSyncToggleSync.toggles(for: .simkl).map(\.wire)), ["scrobble", "watchlist"],
                "simkl block carries its two toggles")
}

// MARK: - 2a. The shim vs the real enum (drift guard)

func testShimMatchesRealEnum() {
    let realURL = appSource("SourcesShared/ExternalScrobbleProvider.swift")
    guard let src = try? String(contentsOf: realURL, encoding: .utf8) else {
        failures.append("could not read ExternalScrobbleProvider.swift at \(realURL.path)")
        return
    }
    // Scope the parse to `enum ExternalSyncToggle { ... }` so an unrelated `static let` elsewhere in the
    // file cannot be mistaken for one of the toggle keys.
    guard let start = src.range(of: "enum ExternalSyncToggle {") else {
        failures.append("enum ExternalSyncToggle not found in ExternalScrobbleProvider.swift")
        return
    }
    let body = String(src[start.upperBound...])

    let re = try! NSRegularExpression(pattern: #"static let (\w+)\s*=\s*"([^"]+)""#)
    let ns = body as NSString
    var real: [String: String] = [:]
    for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: m.range(at: 1))
        let value = ns.substring(with: m.range(at: 2))
        if real[name] == nil { real[name] = value }   // first hit only: we walk past the enum's closing brace
    }

    let shim: [String: String] = [
        "traktScrobble": ExternalSyncToggle.traktScrobble,
        "traktWatchlist": ExternalSyncToggle.traktWatchlist,
        "simklScrobble": ExternalSyncToggle.simklScrobble,
        "simklWatchlist": ExternalSyncToggle.simklWatchlist,
        "traktImportWatched": ExternalSyncToggle.traktImportWatched,
    ]
    for (name, want) in shim {
        guard let got = real[name] else {
            failures.append("ExternalSyncToggle.\(name) no longer exists in the real source")
            continue
        }
        expectEqual(got, want, "shim key ExternalSyncToggle.\(name) matches the real source")
    }
}

// MARK: - 2b. Defaults vs the real @AppStorage declarations (the cross-file drift guard)

func testDefaultsMatchAppStorageDeclarations() {
    let viewURL = appSource("SourcesShared/ExternalServicesSettingsView.swift")

    guard let src = try? String(contentsOf: viewURL, encoding: .utf8) else {
        failures.append("could not read ExternalServicesSettingsView.swift at \(viewURL.path)")
        return
    }

    // @AppStorage(ExternalSyncToggle.traktScrobble) private var scrobble = true
    let pattern = #"@AppStorage\(ExternalSyncToggle\.(\w+)\)[^\n=]*=\s*(true|false)"#
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = src as NSString
    var declared: [String: Bool] = [:]
    for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
        let caseName = ns.substring(with: m.range(at: 1))
        let value = ns.substring(with: m.range(at: 2)) == "true"
        declared[caseName] = value
    }

    expectEqual(declared.count, 5, "found all five @AppStorage declarations in the settings view")

    // The settings view declares by ENUM CASE name (traktScrobble); the table stores the service + the
    // in-block wire name (.trakt / "scrobble"). Rebuild the case name to map the two 1:1.
    for t in ExternalSyncToggleSync.toggles {
        let caseName = t.service.rawValue + t.wire.prefix(1).uppercased() + t.wire.dropFirst()
        guard let want = declared[caseName] else {
            failures.append("no @AppStorage declaration found for \(caseName)")
            continue
        }
        expectEqual(t.defaultOn, want, "default for \(caseName) matches its @AppStorage default")
    }

    // Belt and braces on the one that is deliberately different from the rest.
    expectEqual(declared["traktImportWatched"], false, "traktImportWatched is opt-in (default OFF)")
}

// MARK: - 2c. The wire contract vs the dashboard (cross-REPO drift guard)

func testWireContractMatchesDashboard() {
    // These literals are the contract with vortx-site/src/lib/vault.ts, which this runner cannot open
    // (different repo). Pinned here so a Swift-side rename fails loudly instead of silently producing a doc
    // the dashboard reads as "no data". Counterpart lines, keep in sync by hand:
    //   readIntegrations ....... vault.ts:979-992   (doc.vortx.integrations, doc.integrations)
    //   readService ............ vault.ts:955-975   (vx.protocol, vx[svc].connected, vx[svc][toggle])
    //   INTEGRATION_DEFAULTS ... vault.ts:935-938
    //   saveIntegrationToggles . vault.ts:1001-1008 (the nested edit payload this applies)
    expectEqual(Set(ExternalSyncToggleSync.Service.allCases.map(\.rawValue)), ["trakt", "simkl"],
                "service block names match vault.ts IntegrationService")

    let s = ExternalSyncToggleSync.summary(traktConnected: true, simklConnected: false)

    // vault.ts:961 is STRICT: `typeof vx.protocol === "number" && vx.protocol >= 1`. A String here (or a
    // bumped-but-unannounced number) leaves every card stuck on "Needs a newer app" forever.
    expect(s["protocol"] is Int, "protocol is a JSON number, not a string")
    expectEqual(s["protocol"] as? Int, 1, "protocol is the version the dashboard gates on")

    // vault.ts:966 is equally strict on the toggles: `typeof mirror[k] === "boolean"`, else it falls back to
    // its own default and the user's real setting is invisible.
    for svc in ExternalSyncToggleSync.Service.allCases {
        let b = block(s, svc.rawValue)
        expect(b["connected"] is Bool, "\(svc.rawValue).connected is a real boolean")
        for t in ExternalSyncToggleSync.toggles(for: svc) {
            expect(b[t.wire] is Bool, "\(svc.rawValue).\(t.wire) is a real boolean")
        }
    }

    expectEqual(block(s, "trakt")["connected"] as? Bool, true, "trakt connection is reported per service")
    expectEqual(block(s, "simkl")["connected"] as? Bool, false, "simkl connection is independent of trakt")

    // importWatched is Trakt-only. Inventing it on SIMKL would publish a toggle the app cannot honor.
    expect(block(s, "simkl")["importWatched"] == nil, "importWatched is never invented on simkl")
    expect(block(s, "trakt")["importWatched"] != nil, "trakt carries importWatched")

    // No devices key: the tokens ride doc.apiKeys (VortXSyncManager.swift:831-839, :960-966), so the
    // connection follows the ACCOUNT and a per-device list would misrepresent the model. The dashboard
    // already tolerates its absence (integrations.astro:127 skips the row on an empty array).
    expect(block(s, "trakt")["devices"] == nil, "no devices key is fabricated")
}

// MARK: - 3. summary(): the JSON view

func testSummaryEmitsResolvedDefaults() {
    resetToggles()
    let s = ExternalSyncToggleSync.summary(traktConnected: false, simklConnected: false)

    expectEqual(s.count, 3, "summary emits protocol + the two service blocks")
    expectEqual(block(s, "trakt")["scrobble"] as? Bool, true, "untouched trakt.scrobble resolves to its default ON")
    expectEqual(block(s, "trakt")["watchlist"] as? Bool, true, "untouched trakt.watchlist resolves to its default ON")
    expectEqual(block(s, "simkl")["scrobble"] as? Bool, true, "untouched simkl.scrobble resolves to its default ON")
    expectEqual(block(s, "simkl")["watchlist"] as? Bool, true, "untouched simkl.watchlist resolves to its default ON")
    expectEqual(block(s, "trakt")["importWatched"] as? Bool, false, "untouched trakt.importWatched resolves to its default OFF")
}

func testSummaryReflectsExplicitValues() {
    resetToggles()
    UserDefaults.standard.set(false, forKey: ExternalSyncToggle.traktScrobble)
    UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktImportWatched)

    let s = ExternalSyncToggleSync.summary(traktConnected: true, simklConnected: true)
    expectEqual(block(s, "trakt")["scrobble"] as? Bool, false, "an explicitly disabled toggle is emitted false")
    expectEqual(block(s, "trakt")["importWatched"] as? Bool, true, "an explicitly enabled opt-in toggle is emitted true")
    expectEqual(block(s, "simkl")["scrobble"] as? Bool, true, "an untouched sibling still resolves to its default")
}

func testSummaryIsNotGatedOnConnection() {
    resetToggles()
    UserDefaults.standard.set(false, forKey: ExternalSyncToggle.simklWatchlist)
    // A lapsed token must not make the PREFERENCE vanish from the doc: the dashboard would then fall back to
    // its default and show the switch in the wrong position the moment a sign-in expired.
    let s = ExternalSyncToggleSync.summary(traktConnected: false, simklConnected: false)
    expectEqual(block(s, "simkl")["watchlist"] as? Bool, false, "toggles are emitted even when disconnected")
}

func testSummaryIsJSONSerializable() {
    resetToggles()
    // The view has to survive the exact trip it takes in production: JSONSerialization into the sync doc,
    // then a browser parse. A non-plist value here would throw at push time.
    expect(JSONSerialization.isValidJSONObject(ExternalSyncToggleSync.summary(traktConnected: true, simklConnected: true)),
           "summary is a valid JSON object")
}

// MARK: - 4. applyEdits(): the web-authored edit channel

func testApplyEditsWritesPresentKeys() {
    resetToggles()
    let changed = ExternalSyncToggleSync.applyEdits([
        "editedAt": 1_700_000_000_000,
        "trakt": ["scrobble": false],
        "simkl": ["watchlist": false],
    ])

    expect(changed, "applying a real change reports changed")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble, default: true), false, "trakt.scrobble applied")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.simklWatchlist, default: true), false, "simkl.watchlist applied")
}

func testApplyEditsAcceptsTheRealDashboardPayload() {
    resetToggles()
    // The exact shape saveIntegrationToggles writes (vault.ts:1001-1008): one service block per save, with
    // the peer service's earlier block still present from its read-merge.
    let changed = ExternalSyncToggleSync.applyEdits([
        "editedAt": 1_700_000_000_000,
        "trakt": ["scrobble": true, "watchlist": false, "importWatched": true],
        "simkl": ["scrobble": false, "watchlist": true],
    ])
    expect(changed, "the real dashboard payload applies")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktWatchlist, default: true), false, "trakt.watchlist applied")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false), true, "trakt.importWatched applied")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.simklScrobble, default: true), false, "simkl.scrobble applied")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble, default: true), true, "trakt.scrobble stays at its default")
}

func testApplyEditsIsUnionSafe() {
    resetToggles()
    UserDefaults.standard.set(false, forKey: ExternalSyncToggle.simklScrobble)

    // A partial edit that does not mention simkl at all must leave its toggles exactly as they were.
    _ = ExternalSyncToggleSync.applyEdits(["trakt": ["scrobble": false]])
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.simklScrobble, default: true), false,
                "an unmentioned service is left untouched")

    // A block that mentions ONE toggle must not reset its siblings.
    UserDefaults.standard.set(false, forKey: ExternalSyncToggle.traktWatchlist)
    _ = ExternalSyncToggleSync.applyEdits(["trakt": ["scrobble": true]])
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktWatchlist, default: true), false,
                "an unmentioned toggle inside a present block is left untouched")
}

func testApplyEditsIgnoresEditedAtAndUnknownKeys() {
    resetToggles()
    let changed = ExternalSyncToggleSync.applyEdits(["editedAt": 1_700_000_000_000, "somethingElse": true])
    expect(!changed, "an edit with no known service blocks changes nothing")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble, default: true), true,
                "envelope metadata never writes a toggle")

    // A future dashboard adding a service this build does not know must not throw or write anything.
    expect(!ExternalSyncToggleSync.applyEdits(["letterboxd": ["scrobble": false]]),
           "an unknown service block is ignored, not fatal")
}

func testApplyEditsIgnoresAMalformedServiceBlock() {
    resetToggles()
    // A block that is not an object at all (a browser bug, or a hand-edited doc) must be skipped, never
    // crash and never coerce.
    expect(!ExternalSyncToggleSync.applyEdits(["trakt": "nonsense"]), "a non-object service block is ignored")
    expect(!ExternalSyncToggleSync.applyEdits(["trakt": ["scrobble": ["nested": true]]]),
           "a non-scalar toggle value is ignored")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble, default: true), true,
                "malformed input never flips a toggle")
}

func testApplyEditsNoOpWhenAlreadyAtValue() {
    resetToggles()
    // trakt.scrobble already resolves to true (its default). An edit setting it to true is not a change:
    // reporting one would set syncDown's `restored` flag and churn a pointless UserDefaults write.
    let changed = ExternalSyncToggleSync.applyEdits(["trakt": ["scrobble": true]])
    expect(!changed, "an edit matching the resolved value is not a change")
}

func testApplyEditsIsIdempotent() {
    resetToggles()
    let edit: [String: Any] = ["trakt": ["scrobble": false, "importWatched": true]]
    expect(ExternalSyncToggleSync.applyEdits(edit), "first apply changes state")
    expect(!ExternalSyncToggleSync.applyEdits(edit), "re-applying the same edit is a no-op")
}

// MARK: - 5. Hostile / malformed payloads

func testMalformedValuesNeverFlipAToggle() {
    resetToggles()
    // A browser-authored payload is untrusted input. Anything unrecognized must be treated as "not
    // mentioned", never coerced to false: silently switching a user's scrobbling off is the worst outcome.
    let changed = ExternalSyncToggleSync.applyEdits([
        "trakt": ["scrobble": NSNull(), "watchlist": "maybe", "importWatched": [1, 2]],
        "simkl": ["scrobble": Double.nan],
    ])
    expect(!changed, "no malformed value is treated as a change")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble, default: true), true, "trakt.scrobble untouched")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktWatchlist, default: true), true, "trakt.watchlist untouched")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false), false, "trakt.importWatched untouched")
}

func testBoolValueAcceptsTheWireShapes() {
    // A browser JSON `true` parses to NSNumber, not Bool, through JSONSerialization. Accepting only `Bool`
    // would drop every real dashboard edit on the floor.
    expectEqual(ExternalSyncToggleSync.boolValue(true), true, "Bool true")
    expectEqual(ExternalSyncToggleSync.boolValue(false), false, "Bool false")
    expectEqual(ExternalSyncToggleSync.boolValue(NSNumber(value: 1)), true, "NSNumber 1")
    expectEqual(ExternalSyncToggleSync.boolValue(NSNumber(value: 0)), false, "NSNumber 0")
    expectEqual(ExternalSyncToggleSync.boolValue("true"), true, "string true")
    expectEqual(ExternalSyncToggleSync.boolValue("FALSE"), false, "string FALSE is case-insensitive")
    expectEqual(ExternalSyncToggleSync.boolValue(" on "), true, "string on is trimmed")
    expect(ExternalSyncToggleSync.boolValue("maybe") == nil, "unrecognized string is nil, not false")
    expect(ExternalSyncToggleSync.boolValue(nil) == nil, "absent is nil")
    expect(ExternalSyncToggleSync.boolValue(NSNull()) == nil, "JSON null is nil, not false")
}

// MARK: - 6. Round trip

func testSummaryRoundTripsThroughJSONAndBack() {
    resetToggles()
    UserDefaults.standard.set(false, forKey: ExternalSyncToggle.traktScrobble)
    UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktImportWatched)

    // Emit -> JSON -> parse (what a browser sees) -> feed the service blocks back as an edit. The values must
    // survive unchanged: this is the loop the doc actually performs, and NSNumber/Bool bridging is where a
    // naive cast breaks it.
    let s = ExternalSyncToggleSync.summary(traktConnected: true, simklConnected: true)
    let data = try! JSONSerialization.data(withJSONObject: s)
    let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

    resetToggles()
    let changed = ExternalSyncToggleSync.applyEdits(parsed)
    expect(changed, "the round-tripped view re-applies its non-default values")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktScrobble, default: true), false, "value preserved")
    expectEqual(ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false), true, "value preserved")
}

// MARK: - 7. doc.settings is the real source of truth (the premise this whole design rests on)

func testAllFiveKeysAreSyncableThroughSettingsBackup() {
    // The premise: these keys already ride doc.settings, so this file is a cross-surface VIEW and not a new
    // source of truth. That rests on SettingsBackup.isSyncable(key) being true for all five. SettingsBackup
    // cannot be linked in standalone, so mirror its two rules literally (skipPrefixes at :25, deviceLocalKeys
    // at :37-44) and assert against them. If anyone ever adds one of these keys to deviceLocalKeys, this
    // fails loudly instead of silently dropping the toggle out of the account.
    let skipPrefixes = ["Apple", "NS", "com.apple.", "WebKit", "WebDatabase", "PK", "MetricKit", "INNext"]
    let deviceLocalKeys: Set<String> = [
        "stremiox.diskCacheBytes",
        "stremiox.serverURL",
        "stremiox.videoUpscaling",
        "stremiox.dvRemux",
    ]
    for t in ExternalSyncToggleSync.toggles {
        expect(!skipPrefixes.contains { t.key.hasPrefix($0) }, "\(t.service.rawValue).\(t.wire) is an app pref")
        expect(!deviceLocalKeys.contains(t.key), "\(t.service.rawValue).\(t.wire) is not device-local, so it rides doc.settings")
    }
}

func testDeviceLocalKeysMirrorMatchesRealSource() {
    // Guard the mirror above against the real file, so this premise cannot rot silently.
    let url = appSource("SourcesShared/SettingsBackup.swift")
    guard let src = try? String(contentsOf: url, encoding: .utf8) else {
        failures.append("could not read SettingsBackup.swift at \(url.path)")
        return
    }
    guard let start = src.range(of: "static let deviceLocalKeys: Set<String> = ["),
          let end = src.range(of: "]", range: start.upperBound..<src.endIndex) else {
        failures.append("deviceLocalKeys not found in SettingsBackup.swift")
        return
    }
    // Strip `//` comments FIRST. The real declaration carries trailing prose that itself contains quoted
    // words (`... why enabling it never "took"`), and a naive string scan happily reads those as keys. This
    // guard exists to catch drift, so it must not invent a key that is not there.
    let body = String(src[start.upperBound..<end.lowerBound])
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let slashes = line.range(of: "//") else { return line }
            return line[line.startIndex..<slashes.lowerBound]
        }
        .joined(separator: "\n")

    let re = try! NSRegularExpression(pattern: #""([^"]+)""#)
    let ns = body as NSString
    var real: Set<String> = []
    for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
        real.insert(ns.substring(with: m.range(at: 1)))
    }
    expectEqual(real, ["stremiox.diskCacheBytes", "stremiox.serverURL", "stremiox.videoUpscaling", "stremiox.dvRemux"],
                "deviceLocalKeys mirror matches the real source")
    // The actual invariant: none of the five is device-local.
    for t in ExternalSyncToggleSync.toggles {
        expect(!real.contains(t.key), "\(t.key) is not in the real deviceLocalKeys")
    }
}

// MARK: - Runner
//
// `@main` rather than bare top-level calls: this runner is compiled TOGETHER with the real
// ExternalSyncToggleSync.swift, and Swift only allows top-level statements in a file named main.swift, so a
// bare `testTableShape()` here fails to compile. (The single-file HouseholdCryptoTests can use top-level
// code precisely because it is compiled alone.)

@main
struct ExternalSyncToggleSyncTests {
    static func main() {
        testTableShape()
        testShimMatchesRealEnum()
        testDefaultsMatchAppStorageDeclarations()
        testWireContractMatchesDashboard()
        testSummaryEmitsResolvedDefaults()
        testSummaryReflectsExplicitValues()
        testSummaryIsNotGatedOnConnection()
        testSummaryIsJSONSerializable()
        testApplyEditsWritesPresentKeys()
        testApplyEditsAcceptsTheRealDashboardPayload()
        testApplyEditsIsUnionSafe()
        testApplyEditsIgnoresEditedAtAndUnknownKeys()
        testApplyEditsIgnoresAMalformedServiceBlock()
        testApplyEditsNoOpWhenAlreadyAtValue()
        testApplyEditsIsIdempotent()
        testMalformedValuesNeverFlipAToggle()
        testBoolValueAcceptsTheWireShapes()
        testSummaryRoundTripsThroughJSONAndBack()
        testAllFiveKeysAreSyncableThroughSettingsBackup()
        testDeviceLocalKeysMirrorMatchesRealSource()
        // Leave no state behind: these tests write the REAL keys in the runner's own defaults domain.
        resetToggles()

        if failures.isEmpty {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAIL: \(failures.count) of \(checks) checks")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }
}
