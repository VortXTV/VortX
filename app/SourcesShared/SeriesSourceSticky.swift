import Foundation

/// The source a viewer chose BY HAND for a series, remembered so the next episode keeps picking it.
///
/// diag-21: auto-next re-ranked from scratch on every episode, so the only memory of a manual pick was the
/// in-session `curBinge` string - an add-on-authored `bingeGroup` that cannot match across add-ons at all and,
/// at +2500, loses to the cached (+8000) and source-type (15000) terms anyway. The CEO re-picked his source
/// every single episode. This store is the durable half of the fix: one record per series, per profile, keyed
/// on the app-owned add-on NAME (`manifest.name`, identical in the preload's groups and the engine's) rather
/// than on `bingeGroup` structure, which `SourceIndexContract` forbids parsing.
///
/// It is a PREFERENCE, never a lock: the read side is `StreamRanking.stickyBonus`, a score bonus the player's
/// invisible failover hops straight off when the remembered source turns out to be dead. Restricting the next
/// episode to the remembered add-on would be exactly the fail-closed shape MIS-260731-03 forbids - the add-on
/// that has nothing for episode N+1 would strand the viewer.
///
/// Only MANUAL picks are recorded. Writing on every auto-next would also be pointless churn, and writes here
/// deliberately do NOT call `StreamRanking.invalidateCaches()`: the sticky preference is applied OUTSIDE the
/// score memo, so the memo stays valid and the 32768-entry cache that exists to keep re-ranks off the main
/// thread is never dropped.
enum SeriesSourceSticky {
    /// One remembered manual pick. Both signals are optional because a pick can arrive with only one in hand
    /// (many add-ons set no `bingeGroup`), and either one alone is enough to earn the ranking bonus.
    struct Choice: Codable {
        /// The source group's add-on name, as `StreamRanking.pinBonus` / `SourcePinStore.matches` key on it.
        var addon: String?
        /// The add-on's own same-release id (`behaviorHints.bingeGroup`) when it sets one.
        var bingeGroup: String?
        /// When the pick was made, so the cap below evicts the least recently chosen series.
        var ts: Date
    }

    /// Per-profile cap, pruned on the write that crosses it (the `LastStreamStore` shape): the headroom means
    /// pruning is rare rather than per-write.
    private static let maxSeries = 200
    private static let keepSeries = 180

    private static func key(_ profile: String) -> String { "stremiox.seriesSourceSticky.\(profile)" }

    /// The active profile's stable key, mirroring `SourcePinStore`: `activeID` is a `UUID?`, so a not-yet-loaded
    /// roster still has a namespace.
    private static var activeProfileKey: String { ProfileStore.shared.activeID?.uuidString ?? "default" }

    /// Guards ONLY the in-memory dictionary. Every `UserDefaults` read/write below happens with the lock
    /// released: MIS-260731-02 shipped a launch deadlock by holding an app-level lock across UserDefaults I/O,
    /// whose change notification re-enters app code on the main thread.
    private static let lock = NSLock()
    private static var cache: [String: Choice]?
    private static var cachedProfile: String?

    /// The active profile's picks, decoded once and kept in memory (the ranking sites read this per pick, and
    /// a JSON decode per read would land in a render path). Two threads racing the first load both decode the
    /// same bytes, so the redundant work is harmless.
    private static func loaded() -> (profile: String, choices: [String: Choice]) {
        let profile = activeProfileKey
        lock.lock()
        if cachedProfile == profile, let hit = cache { lock.unlock(); return (profile, hit) }
        lock.unlock()
        var decoded: [String: Choice] = [:]
        if let data = UserDefaults.standard.data(forKey: key(profile)),
           let blob = try? JSONDecoder().decode([String: Choice].self, from: data) {
            decoded = blob
        }
        lock.lock(); cachedProfile = profile; cache = decoded; lock.unlock()
        return (profile, decoded)
    }

    /// Remember the source the viewer just chose by hand for `seriesKey` (the show's meta id, so every episode
    /// shares it). A pick carrying neither signal is not worth a record.
    static func record(seriesKey: String, addon: String?, bingeGroup: String?) {
        guard !seriesKey.isEmpty,
              addon?.isEmpty == false || bingeGroup?.isEmpty == false else { return }
        let (profile, existing) = loaded()
        var dict = existing
        dict[seriesKey] = Choice(addon: addon, bingeGroup: bingeGroup, ts: Date())
        if dict.count > maxSeries {   // cap per profile, least recently chosen out
            dict = Dictionary(uniqueKeysWithValues:
                dict.sorted { $0.value.ts > $1.value.ts }.prefix(keepSeries).map { ($0.key, $0.value) })
        }
        lock.lock(); cachedProfile = profile; cache = dict; lock.unlock()
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key(profile))   // outside the lock, deliberately
        }
    }

    /// The remembered pick for `seriesKey`, in the shape `StreamRanking.best` / `rankedCandidates` take.
    /// `nil` when the viewer has never chosen a source for this show.
    static func preference(for seriesKey: String) -> (addon: String?, bingeGroup: String?)? {
        guard !seriesKey.isEmpty, let choice = loaded().choices[seriesKey] else { return nil }
        return (addon: choice.addon, bingeGroup: choice.bingeGroup)
    }
}

/// Short-lived, in-memory memory of which add-on just FAILED, so ranking stops handing it the next episode.
///
/// diag-21: the only failure memory in the player is `exhaustedURLs`, which is keyed by exact URL (so it cannot
/// generalize to "this provider") and is wiped on every source switch and every episode advance. A provider that
/// TRUE-STALLED on episode N was therefore fully re-eligible on episode N+1 - and, being fast to answer, was
/// repeatedly re-picked, which is why the CEO had to re-pick the source every episode.
///
/// Deliberately in-memory only: this is a "just now" signal, not a durable verdict on a provider, and it must
/// not survive a relaunch or reach `SettingsBackup`. The lock guards only the dictionary; the clock read and
/// the comparison happen outside it (MIS-260731-02). Consumed as `StreamRanking.healthPenalty`, a demotion and
/// never an exclusion - a penalized provider still plays when it is the only thing that answers.
enum ProviderHealth {
    /// How long one failure keeps demoting its provider. Long enough to cover the next episode or two of a
    /// binge (where the re-pick loop happens), short enough that a transient outage is forgotten by the time
    /// the viewer comes back.
    static let failureDecaySeconds: TimeInterval = 600

    private static let lock = NSLock()
    /// Add-on NAME (lowercased) -> the monotonic `systemUptime` of its last failure. The name is `manifest.name`,
    /// the app-owned identity a pin and the sticky record also key on - NOT the add-on's transport base URL,
    /// which is what "addon base" means everywhere else in this codebase (`engineAddonBase`). `systemUptime`
    /// rather than `Date` so a clock change cannot make a failure look older or newer than it is.
    private static var failures: [String: TimeInterval] = [:]

    /// Record that `addonName` just failed to produce playable video.
    static func noteFailure(addonName: String) {
        guard !addonName.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let key = addonName.lowercased()   // outside the lock: no work under it (MIS-260731-02)
        lock.lock()
        failures[key] = now
        if failures.count > 64 {   // defensive cap; drop everything already decayed
            failures = failures.filter { now - $0.value < failureDecaySeconds }
        }
        lock.unlock()
    }

    /// Whether `addonName` failed inside the decay window. `nil`/empty is never penalized.
    static func penaltyActive(addonName: String?) -> Bool {
        guard let addonName, !addonName.isEmpty else { return false }
        let key = addonName.lowercased()   // outside the lock: no work under it (MIS-260731-02)
        lock.lock(); let failedAt = failures[key]; lock.unlock()
        guard let failedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - failedAt < failureDecaySeconds
    }
}
