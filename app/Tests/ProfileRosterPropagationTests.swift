import Foundation

// The script compiles the real UserProfile, discovery value, roster policy and two observer methods.
// No app, Keychain, standard defaults, media or live account is touched.
enum SettingsBackup {
    static func isSyncable(_ key: String) -> Bool { !key.hasPrefix("vortx.sync.") && key != "device-only" }
}

final class ObserverFixture {
    struct Capture: Equatable { let epoch: Int }
    final class Authority {
        var epoch = 1
        func capture() -> Capture { Capture(epoch: epoch) }
    }
    let credentialAuthority = Authority()
    var pendingLocalRosterPush: Capture?
    func isCurrent(_ capture: Capture) -> Bool { capture == credentialAuthority.capture() }
    var isSignedIn = true
    var isApplyingRemote = false
    var settingsShadow: [String: Any] = [:]
    var domain: [String: Any] = [:]
    var dirtySettings: [String: Double] = [:]
    var pushes = 0
    func currentSyncableDomain() -> [String: Any] { domain.filter { SettingsBackup.isSyncable($0.key) } }
    func requestSyncSoon() { pushes += 1 }
    // Extracted methods are supplied by the script as an extension, not copied here.
}

@main enum ProfileRosterPropagationTests {
    static func main() throws {
        let clock = ProfileRosterSyncPolicy.self
        precondition(clock.nextLocalClock(now: 100, prior: 100) > 100)
        precondition(clock.nextLocalClock(now: 90, prior: 100) > 100, "clock rollback cannot hide a local edit")
        precondition(clock.clockDecision(local: 100, incoming: 200).preferIncoming)
        precondition(!clock.clockDecision(local: 200, incoming: 100).preferIncoming)
        precondition(clock.clockDecision(local: 100, incoming: 200).watermark == 200)
        precondition(clock.validClock(true) == nil && clock.validClock(Double.nan) == nil)

        let owner = UserProfile(id: UserProfile.ownerID, name: "Owner", avatar: "🍿", isOwner: true)
        var old = UserProfile(name: "Old", avatar: "🌻", usesOwnAccount: true, email: "fixture@example.invalid")
        old.pin = UserProfile.pinHash("1234", profileID: old.id)
        old.discovery = ProfileDiscoveryPreferences(catalogOrder: ["fixture"])
        var renamed = old
        renamed.name = "New"
        renamed.avatar = "🚀"
        let new = UserProfile(name: "Created on TV", avatar: "🌙")
        let local = [owner, old]
        let remote = [owner, renamed, new]
        let decision = clock.clockDecision(local: 100, incoming: 200)
        let merged = clock.union(local: local, incoming: remote, preferIncoming: decision.preferIncoming)
        precondition(merged == remote, "unrelated stale-device push must retain the peer rename and new profile")
        precondition(clock.union(local: local, incoming: remote, preferIncoming: false) == [owner, old, new],
                     "newer local same-id edit and cloud-only ids both survive")

        let settings: [String: Any] = ["stremiox.profiles": try JSONEncoder().encode(local),
                                       "stremiox.profiles.modified": 100.0]
        let wire = ProfileRosterSnapshot.wire(remote)!
        let full: [String: Any] = ["roster": wire, "rosterModified": 200.0, "updatedAt": 999999999999.0]
        let resolved = ProfileRosterSnapshot.resolve(settingsDomain: settings, vortx: full)!
        precondition(resolved.profiles == remote && resolved.modified == 200)
        precondition(resolved.profiles[1].pin == old.pin && resolved.profiles[1].usesOwnAccount
                     && resolved.profiles[1].email == old.email && resolved.profiles[1].discovery == old.discovery,
                     "lossless cross-platform carrier retains account binding, PIN and discovery")
        precondition(ProfileRosterSnapshot.resolve(settingsDomain: nil, vortx: full)?.profiles == remote,
                     "Android full roster with no settings blob is applied")
        let summary: [String: Any] = ["profiles": [["id": old.id.uuidString, "name": "Lossy", "main": false]],
                                      "updatedAt": 999999999999.0]
        let lossless = ProfileRosterSnapshot.resolve(settingsDomain: settings, vortx: summary)!
        precondition(lossless.profiles == local && lossless.modified == 100,
                     "summary updatedAt is not a roster clock and cannot strip full records")
        let malformed: [String: Any] = ["roster": [["id": "invalid", "name": "bad"]]]
        precondition(ProfileRosterSnapshot.resolve(settingsDomain: nil, vortx: malformed) == nil)
        let partial: [String: Any] = ["roster": [["id": old.id.uuidString, "name": "Partial"]], "rosterModified": 999.0]
        precondition(ProfileRosterSnapshot.resolve(settingsDomain: settings, vortx: partial)?.profiles == local,
                     "partial full carrier cannot erase own-account/PIN/preferences")

        let observer = ObserverFixture()
        observer.observeDefaultsChange()
        precondition(observer.pushes == 0, "unchanged defaults notification must not queue a push")
        observer.domain = ["vortx.sync.version": 200, "device-only": true]
        observer.observeDefaultsChange()
        precondition(observer.pushes == 0 && observer.dirtySettings.isEmpty)
        observer.domain["stremiox.profiles"] = try JSONEncoder().encode(remote)
        observer.observeDefaultsChange()
        precondition(observer.pushes == 1 && observer.dirtySettings["stremiox.profiles"] != nil)
        observer.observeDefaultsChange()
        precondition(observer.pushes == 1, "bookkeeping/duplicate notifications cannot reset debounce")
        observer.isApplyingRemote = true
        observer.domain["stremiox.profiles"] = try JSONEncoder().encode(local)
        observer.observeDefaultsChange()
        precondition(observer.pushes == 1, "suppressed pull cannot self-echo")
        observer.settingsShadow = observer.currentSyncableDomain()
        observer.isApplyingRemote = false
        observer.observeDefaultsChange()
        precondition(observer.pushes == 1, "delayed remote notification after rebaseline cannot self-echo")

        let localEdit = ObserverFixture()
        localEdit.domain = ["stremiox.profiles": try JSONEncoder().encode(remote),
                            "stremiox.profiles.modified": 200.0]
        localEdit.noteLocalRosterMutation()
        localEdit.isApplyingRemote = true // same-turn touch:false selection housekeeping
        localEdit.observeDefaultsChange()
        localEdit.settingsShadow = localEdit.currentSyncableDomain()
        localEdit.isApplyingRemote = false
        localEdit.drainLocalRosterPush()
        precondition(localEdit.pushes == 1 && Set(localEdit.dirtySettings.keys) ==
                     ["stremiox.profiles", "stremiox.profiles.modified"],
                     "housekeeping cannot erase the synchronous dirty mark or queued push")

        let drainingEdit = ObserverFixture()
        drainingEdit.isApplyingRemote = true
        drainingEdit.noteLocalRosterMutation()
        precondition(drainingEdit.pushes == 0 && drainingEdit.dirtySettings.count == 2)
        drainingEdit.isApplyingRemote = false
        drainingEdit.drainLocalRosterPush()
        drainingEdit.drainLocalRosterPush()
        precondition(drainingEdit.pushes == 1, "local edit during suppression drains exactly once")

        let staleEdit = ObserverFixture()
        staleEdit.isApplyingRemote = true
        staleEdit.noteLocalRosterMutation()
        staleEdit.credentialAuthority.epoch += 1 // sign out/account swap or same-account reopen
        staleEdit.isApplyingRemote = false
        staleEdit.drainLocalRosterPush()
        precondition(staleEdit.pushes == 0 && staleEdit.pendingLocalRosterPush == nil,
                     "retired account intent cannot arm the replacement account")

        let housekeepingOnly = ObserverFixture()
        housekeepingOnly.isApplyingRemote = true
        housekeepingOnly.observeDefaultsChange()
        housekeepingOnly.isApplyingRemote = false
        housekeepingOnly.drainLocalRosterPush()
        precondition(housekeepingOnly.dirtySettings.isEmpty && housekeepingOnly.pushes == 0)
        let signedOut = ObserverFixture()
        signedOut.isSignedIn = false
        signedOut.noteLocalRosterMutation()
        precondition(signedOut.dirtySettings.isEmpty && signedOut.pushes == 0)
        print("PASS profile propagation: actual model/carriers/clocks/merge/observer; no account or media")
    }
}
