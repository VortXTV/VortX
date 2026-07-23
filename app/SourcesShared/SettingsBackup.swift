import Foundation

/// Portable export / import of the app's local settings, so a user can carry their
/// preferences across the StremioX -> VortX move (a later update ships VortX as a fresh app
/// identity, com.stremiox.* -> com.vortx.*, and therefore starts with empty local storage).
///
/// What it captures: this app's OWN UserDefaults domain, which is every preference the app
/// has written (theme, player toggles, audio output, source filters, profiles, server config,
/// seek step, resume positions, ...). It is read via `persistentDomain(forName:)`, so Apple's
/// global domain is excluded, and the keys are literal strings that do not depend on the bundle
/// id, so a StremioX backup repopulates the same keys when restored into VortX.
///
/// What it deliberately does NOT capture: the account token, which comes back by signing in again (and with
/// it the synced library, add-ons, and history). This used to be justified with "the token lives in the
/// Keychain, not UserDefaults, so it never lands in the backup file". That reasoning was WRONG, and its
/// wrongness is why the token leaked for as long as it did: `Keychain` on iOS/tvOS falls back to UserDefaults
/// when the Keychain refuses it, so "it is in the Keychain" was never a property this file could assume, only
/// one it could ENFORCE. It is now enforced, by `secretKeyPrefixes` below. Do not restore the old claim.
///
/// 0.4 is FREE to rename the `@AppStorage` keys to `vortx.*`: restore runs every key through
/// `migratedKey(_:)`, so a backup written by an older StremioX build still applies. The only place the old
/// names linger is inside an old backup file, and that one function translates them on import.
enum SettingsBackup {
    static let schema = 1
    static let formatTag = "vortx-backup"

    /// Framework/OS keys that can appear in the app domain but are not our preferences.
    /// Filtered out so the backup stays app-only and a restore never re-seeds OS state.
    private static let skipPrefixes = ["Apple", "NS", "com.apple.", "WebKit", "WebDatabase", "PK", "MetricKit", "INNext"]

    static func isAppPref(_ key: String) -> Bool {
        !skipPrefixes.contains { key.hasPrefix($0) }
    }

    /// PER-DEVICE keys that must NEVER sync or transfer between devices. The cross-device settings sync
    /// (VortXSyncManager) reuses this serialization as its `doc.settings` blob, so anything excluded here is
    /// excluded from BOTH the synced blob (makeBackup) and an incoming apply (decodeDomain/restore). Each
    /// device keeps its own value: the streaming-cache size depends on that device's free storage, and the
    /// streaming server is per-device (one device may point at a custom/local server). A device that pulls a
    /// peer's settings keeps its own cache/server choice; its own choice is never pushed up to overwrite others.
    static let deviceLocalKeys: Set<String> = [
        "stremiox.diskCacheBytes",   // Settings -> Streaming cache (sized to the device's own storage)
        "stremiox.serverURL",        // custom streaming server URL (per-device)
        "stremiox.videoUpscaling",   // Settings -> Video upscaling (per-device: standard on Apple TV, scaled on Mac)
        "stremiox.dvRemux",          // Settings -> Dolby Vision for MKV (per-device: depends on THIS device's DV
                                     // display + decode). Was syncing, so a pull kept reverting a freshly-toggled
                                     // device back to a peer's OFF value, which is why enabling it never "took".
        "vortx.downloads.queueOrder",    // an array of download UUIDs whose FILES are device-local, so a peer's
                                         // queue order can never apply here: the UUIDs it names do not exist on
                                         // this device. Was syncing, so a pull replaced this device's real order
                                         // with a peer's meaningless UUIDs until the user next reordered.
        "vortx.downloads.maxConcurrent", // per-device: bandwidth, thermals and storage differ. A Mac's 5 landing
                                         // on an iPhone on cellular is actively harmful. Same class as
                                         // diskCacheBytes above: a number that is only correct for the hardware
                                         // that chose it.
        // DELIBERATELY NOT HERE: "vortx.downloads.autoDeleteWatched". It looks like it belongs with the two
        // above, and it does not. It is a real cross-device POLICY preference ("I do not want to keep watched
        // downloads"), which is true of the user rather than of the hardware, so it must keep syncing. The test
        // for this list is not "does the key say downloads", it is "would a peer's value be WRONG here".
    ]

    /// The sync engine's OWN bookkeeping, which must never travel inside the payload it manages (#145).
    /// The exact-match `deviceLocalKeys` above cannot express these: they are keyed PER ACCOUNT
    /// ("vortx.sync.lastSyncedVersion.<accountId>"), so only a prefix catches them.
    ///
    /// Every key under this prefix is a statement about what THIS DEVICE has done with the account's
    /// document: the version it last applied, whether it has applied one at all, the v2 ratchet it has
    /// seen, the one-shot add-on baseline it has stamped. Carrying them inside doc.settings makes one
    /// device's progress arrive at another device as if it were that device's own. Because this same
    /// filter is what `restore` applies, it also reaches the user-facing backup FILE: a file exported
    /// from a healthy device would otherwise import "I have already applied this account's document,
    /// at version V" onto a fresh one. That is #145 with extra steps, and it defeats the very gate
    /// VortXSyncManager uses to prevent #145: the fresh device would believe it had already applied the
    /// account's doc, push its near-empty domain over the account, and then have its own recovery pull
    /// suppressed by the imported high-water mark. Excluding by PREFIX (rather than naming each key)
    /// keeps that true for bookkeeping keys added later, without them having to remember this file.
    ///
    /// `vortx.sync.appliedAddonOrder` is deliberately covered too, and this costs no sync behavior: the
    /// shared add-on order's real carrier is the doc's own top-level `addonOrder` key, which
    /// VortXSyncManager writes on push and applies on pull. The blob was never its transport.
    static let deviceLocalKeyPrefixes: [String] = ["vortx.sync."]

    /// SECRETS, which must never leave this device in any form. Kept as its OWN list rather than folded into
    /// `deviceLocalKeyPrefixes` on purpose: that list answers a per-device TUNING question (cache size, DV
    /// output), so it is the list someone edits while thinking about preferences. A security control filed
    /// there is one careless "this does not need to be device-local any more" away from deletion. This is not
    /// a preference at all, and its name should say so.
    ///
    /// WHAT LEAKED. `Keychain` (iOS/tvOS) falls back to writing a secret into UserDefaults under
    /// "kcfallback.<account>" when `SecItemAdd` fails, a fallback its own comment attributes to an unsigned
    /// Simulator or an entitlement mismatch. VortX ships UNSIGNED SIDELOADED IPAs, and re-signing is exactly
    /// that named trigger. Those keys are the app's own and look nothing like OS state, so `isAppPref` passed
    /// them, and `deviceLocalKeyPrefixes` did NOT catch them: the key is "kcfallback.vortx.sync.session.v1",
    /// which starts with "kcfallback.", not "vortx.sync.". So `isSyncable` returned true and the ACCOUNT TOKEN
    /// plus the E2E dataKey (VortXSyncManager persists { token, account, dataKey } as ONE blob in ONE slot)
    /// were carried into both `doc.settings` and the user-facing export this very file calls "portable,
    /// human-inspectable JSON". That breaks the standing invariant that the token is Keychain-only and never
    /// enters preferences or backups.
    ///
    /// A PREFIX, not an exact-match entry, because the slot names are open-ended by construction: the fallback
    /// wraps EVERY Keychain account (per-profile authKeys, Trakt access/refresh, the API keys), so no set of
    /// literals can enumerate them and still be correct after the next account slot is added.
    ///
    /// EXCLUDED ON BOTH SIDES via `isSyncable`, which is two distinct jobs and not belt-and-braces:
    ///  - The WRITE side (`makeBackup`, `mergedSyncBlob`) stops new leaks, which is the fix.
    ///  - The READ side (`decodeDomain`, i.e. restore AND pull-apply) matters because accounts in the wild may
    ///    ALREADY carry a token leaked by an earlier push. Filtering on read stops that token being planted
    ///    into a second device's UserDefaults, and since `mergedSyncBlob` rebuilds the blob from a
    ///    `decodeDomain`d base, the next push from an updated device also SCRUBS the stale secret out of the
    ///    account doc. The fix therefore self-heals, but only once an updated device pushes, and it CANNOT
    ///    reach a backup file already written to a user's disk. Those stay compromised and always will.
    static let secretKeyPrefixes: [String] = [Keychain.fallbackKeyPrefix]

    /// An app preference that is ALSO safe to sync/transfer (i.e. not per-device-local, and not a secret).
    static func isSyncable(_ key: String) -> Bool {
        isAppPref(key)
            && !deviceLocalKeys.contains(key)
            && !deviceLocalKeyPrefixes.contains { key.hasPrefix($0) }
            && !secretKeyPrefixes.contains { key.hasPrefix($0) }
    }

    /// 0.4 RENAME SEAM. When VortX renames its `@AppStorage` keys (the `stremiox.` prefix -> `vortx.`,
    /// plus the constant-defined keys), populate these so a backup written by an older StremioX build
    /// still applies. Empty in 0.3.5 (the keys are unchanged). Restore runs every key through
    /// `migratedKey` before writing it. Example for 0.4:
    ///   static let keyPrefixMigrations = ["stremiox.": "vortx."]
    ///   static let keyMigrations = ["legacy.exact.key": "vortx.newKey"]
    static let keyPrefixMigrations: [String: String] = [:]
    static let keyMigrations: [String: String] = [:]

    static func migratedKey(_ key: String) -> String {
        if let exact = keyMigrations[key] { return exact }
        for (old, new) in keyPrefixMigrations where key.hasPrefix(old) {
            return new + key.dropFirst(old.count)
        }
        return key
    }

    struct Envelope: Codable {
        var format: String
        var schema: Int
        var app: String
        var bundleID: String
        var createdAt: Date
        var keyCount: Int
        var payloadBase64: String   // binary plist of the filtered app defaults domain
    }

    enum RestoreError: LocalizedError {
        case notABackup
        case corruptPayload

        var errorDescription: String? {
            switch self {
            case .notABackup: return "This file is not a VortX backup."
            case .corruptPayload: return "This backup file is damaged and could not be read."
            }
        }
    }

    // MARK: Pure serialization (unit-testable, no UserDefaults / Bundle dependency)

    /// Wrap a defaults dictionary into the portable JSON envelope. The values pass through a
    /// binary property list, which natively round-trips every UserDefaults value type
    /// (Bool, Int, Double, String, Data, Date, arrays, dictionaries) that raw JSON cannot.
    static func encode(domain: [String: Any], bundleID: String, app: String, now: Date = Date()) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let env = Envelope(
            format: formatTag, schema: schema, app: app, bundleID: bundleID,
            createdAt: now, keyCount: domain.count, payloadBase64: plist.base64EncodedString()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(env)
    }

    /// Validate and unwrap a backup file back into a defaults dictionary (app keys only).
    static func decodeDomain(from data: Data) throws -> [String: Any] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(Envelope.self, from: data), env.format == formatTag else {
            throw RestoreError.notABackup
        }
        guard let plistData = Data(base64Encoded: env.payloadBase64),
              let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let pairs = object as? [String: Any]
        else {
            throw RestoreError.corruptPayload
        }
        return pairs.filter { isSyncable($0.key) }   // never apply a peer's per-device keys (cache size, server URL)
    }

    // MARK: App I/O

    /// Suggested filename for the exporter (the `.json` extension is appended from the content type).
    static func defaultFilename() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return "VortX-Backup-\(df.string(from: Date()))"
    }

    /// Serialize the app's own preferences into a portable, human-inspectable JSON file.
    ///
    /// This is a snapshot of ONE DEVICE. That is exactly right for the export-to-a-file feature it was built
    /// for, and exactly wrong as a thing to PUSH at a shared account: see `mergedSyncBlob(onto:)`, which is
    /// what the sync push path must use.
    static func makeBackup() throws -> Data {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let full = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        let domain = full.filter { isSyncable($0.key) }   // exclude per-device keys (cache size, server URL)
        let app = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "VortX"
        return try encode(domain: domain, bundleID: bundleID, app: app)
    }

    /// Build the blob to PUSH to the account by MERGING this device's syncable defaults ONTO the account's
    /// CURRENT blob, per key, instead of replacing it wholesale (#145 M2).
    ///
    /// WHY THIS EXISTS. The push path used `makeBackup()` directly as `doc["settings"]`, so a push REPLACED
    /// the account's settings with a picture of one device. On a freshly reinstalled device that domain is
    /// near-empty, so ONE push erased the account's settings, every secondary profile's Continue Watching,
    /// and its searches. Every sibling field in that same push already read-merges: tombstones fold, the
    /// roster unions, `apiKeys` never deletes a key it did not author, the `vortx` block unions the owned
    /// add-on set. The settings blob was the one field that never got its turn, which is precisely why what
    /// SURVIVED a reinstall was exactly the guarded set.
    ///
    /// THE MERGE RULE, and why this one and not a union or a timestamped last-writer-wins:
    ///  - A key present LOCALLY WINS. The device pushing is the device the user just changed something on, so
    ///    a setting they legitimately turned OFF must not be resurrected from the account. This is what makes
    ///    this a merge and not a blind union.
    ///  - A key ABSENT locally is resolved by the applied-blob BASELINE (`appliedBaseline`), the set of syncable
    ///    keys the LAST account document this device applied actually wrote. The claim that used to sit here, that
    ///    "the app has no delete-a-setting path so absence can only mean not-yet-learned", was FALSE, and it is
    ///    false on at least five syncable keys: the language override and the Discover region + filter overrides
    ///    (each cleared with `removeObject` when the user picks "System" / clears the override), per-profile search
    ///    history (`clear`), and the per-profile track/subtitle keys (a `resetUnset` sweep on a profile switch).
    ///    Without the baseline, clearing one of those on a RESTORED device left the key absent locally but still
    ///    present in the account, so the very next pull wrote it back and re-pinned it (the resurrection bug). The
    ///    baseline splits the two meanings of "absent":
    ///      - absent locally AND in the baseline: this device HAD the key (the applied doc wrote it) and the user
    ///        has since removed it, so this is a genuine delete. Drop it from the push so the pull cannot resurrect it.
    ///      - absent locally AND NOT in the baseline: a peer authored it after this device's last apply, so this
    ///        device has no opinion. KEEP it. A fresh install has an EMPTY baseline, so nothing is ever "absent AND
    ///        in baseline" and no account key is ever deleted (the reinstall guard survives intact); and a peer's
    ///        brand-new key is never in this device's baseline, so a queued push never deletes it (the syncUp
    ///        read-merge invariant survives intact). This is the same asymmetric guard `apiKeys` uses one call
    ///        site away, refined so a KNOWN-THEN-CLEARED key is the one exception to "absence is not deletion".
    ///
    /// Per-key LWW with timestamps was considered and rejected: it does not actually solve the reinstall case,
    /// which is the bug. A fresh install's few launch-written keys would carry BRAND NEW stamps and so would
    /// beat the account's older ones under any honest LWW, and there is no per-key change signal to stamp from
    /// anyway (the push is armed by a single global `UserDefaults.didChangeNotification`, which does not say
    /// which key changed). It would add a synced stamp map and a shadow-domain differ to buy a worse answer.
    ///
    /// "Local wins" is safe ONLY because a device may not push until it has applied the account's document
    /// (VortXSyncManager's per-account ordering gate). That gate is what makes "local" mean "the account's
    /// settings, plus what the user changed on this device". WITHOUT it this function is still a large
    /// improvement (the account's near-entire settings survive a reinstall push instead of being erased), but
    /// the handful of keys a fresh install writes at launch, before any restore, would still beat the
    /// account's values for those keys. The two changes are complementary; this one is not a licence to drop
    /// that gate.
    ///
    /// Returns nil when the account's blob is PRESENT but unreadable. That must NOT degrade into "replace it":
    /// decoding the base with a `?? [:]` fallback would quietly reintroduce the exact wholesale replace this
    /// exists to kill, on the one path where we are LEAST sure what we would be destroying. The caller leaves
    /// `doc["settings"]` untouched instead, so an unreadable blob is preserved byte-for-byte.
    static func mergedSyncBlob(onto pulledBlob: Any?, appliedBaseline: Set<String> = []) -> Data? {
        // Absent blob = this account has no settings yet, so there is nothing to merge and seeding it from
        // this device is correct. A PRESENT blob we cannot open is a different thing entirely: refuse, because
        // the fallback ("treat it as empty and carry on") IS the wholesale replace this function exists to
        // kill. The two cases are separated explicitly rather than by an `as? String` that quietly folds the
        // second into the first.
        var merged: [String: Any] = [:]
        if let value = pulledBlob, !(value is NSNull) {
            // JSON null and a missing key both mean "no document"; anything else present must be a blob we
            // can actually read, or we do not touch it.
            guard let b64 = value as? String else { return nil }
            if !b64.isEmpty {   // "" is how the pull layer already spells "no document" (see pullSyncDocResult)
                guard let raw = Data(base64Encoded: b64),
                      let base = try? decodeDomain(from: raw) else { return nil }
                merged = base   // decodeDomain already filtered the base to syncable keys
            }
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let local = (UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:])
            .filter { isSyncable($0.key) }
        // Local overlays the account, key by key. 0.4 RENAME SEAM: neither side is run through `migratedKey`
        // here (it is empty today, so this is a no-op now). Once `keyPrefixMigrations` is non-empty, a base
        // written by an older client will keep its old key names alongside this device's new ones and the two
        // will diverge rather than merge. Revisit this loop when that seam opens.
        for (key, value) in local { merged[key] = value }
        // DELIBERATE-REMOVAL PASS (the baseline). A key the account holds but this device does NOT is kept by the
        // overlay above (absence is not deletion). The one exception: a key in `appliedBaseline` is one this device
        // once applied from the account, so its absence now is the user having CLEARED it (removeObject / a
        // profile-switch resetUnset), not a not-yet-learned key. Drop it so the next pull cannot re-pin it. The
        // `local[key] == nil` guard leaves a key the user still holds alone (the overlay already let it win). A key
        // absent from the baseline is a peer's post-apply authorship and is untouched, which is what keeps BOTH the
        // reinstall guard (a fresh install's baseline is empty, so nothing is ever deleted) and the syncUp
        // read-merge invariant (a peer's brand-new key is never in this device's baseline) intact. Baseline keys are
        // stored in migrated form (VortXSyncManager stamps `appliedKeys(from:)`), matching `local`'s migrated keys,
        // so this comparison still holds once the 0.4 rename seam opens.
        for key in appliedBaseline where local[key] == nil { merged.removeValue(forKey: key) }
        let app = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "VortX"
        return try? encode(domain: merged, bundleID: bundleID, app: app)
    }

    /// Apply a backup file. Merges keys (overwriting matching ones, leaving the rest), so a
    /// partial backup never wipes settings it does not mention. Returns the number of keys
    /// applied.
    ///
    /// A restore writes straight into `UserDefaults`, which NOTHING already running observes: `UserDefaults`
    /// KVO (the substrate `@AppStorage` watches) does not fire for DOTTED keys, and effectively every key this
    /// app owns is dotted (`stremiox.*`, `vortx.*`). So the write lands but no live view or store re-reads it.
    /// Callers MUST follow a successful restore with `reloadLiveStores()` on the main actor, or the restored
    /// values stay invisible until a relaunch AND the stale in-memory copies get flushed back over them.
    ///
    /// `skipping` is the LOCAL-WINS set (empty by default). The cross-device PULL path (VortXSyncManager.syncDown)
    /// passes the account's locally-dirty settings keys here so a value the user just changed on THIS device but
    /// has not yet pushed is NOT overwritten by the account's older value (`SettingsDirtyKeys`, and the "would not
    /// stay" interplay at VortXSyncManager.swift:1175-1182). The set is compared in MIGRATED form (matching how
    /// VortXSyncManager stamps its dirty set and its appliedSettingsBaseline), so it stays correct once the 0.4
    /// rename seam opens. The user-facing backup-FILE import path passes nothing: an explicit "restore from file"
    /// is a deliberate overwrite and honors every key. The count returned is of keys ACTUALLY applied.
    @discardableResult
    @MainActor
    static func restore(from data: Data, skipping dirtyKeys: Set<String> = []) throws -> Int {
        let pairs = try decodeDomain(from: data)
            .filter { dirtyKeys.isEmpty || !dirtyKeys.contains(migratedKey($0.key)) }
        var restoredConsent: Bool?
        var restoredServe: Bool?
        for (key, value) in pairs {
            switch migratedKey(key) {
            case MoatConsent.key:
                restoredConsent = (value as? Bool) ?? (value as? NSNumber)?.boolValue
            case SourceIndexClient.serveKey:
                restoredServe = (value as? Bool) ?? (value as? NSNumber)?.boolValue
            default:
                break
            }
        }
        // Signal before UserDefaults writes so an off/on restore cannot be hidden by a coalesced notification.
        SourceIndexLifecycleScope.shared.preferencesWillApply(
            consent: restoredConsent,
            serve: restoredServe
        )
        let defaults = UserDefaults.standard
        for (key, value) in pairs {
            defaults.set(value, forKey: migratedKey(key))
        }
        return pairs.count
    }

    /// The set of keys a `restore(from:)` of this SAME blob would write, in the SAME migrated form restore uses.
    /// VortXSyncManager stamps this as the per-account applied-blob baseline right where it applies a pulled
    /// settings blob, and `mergedSyncBlob` reads it back to tell a user's deliberate removal (absent locally AND
    /// in the baseline => delete) apart from a not-yet-learned key (absent AND not in the baseline => keep).
    /// Migrated form is load-bearing: `local` in `mergedSyncBlob` also holds migrated keys, so the two must agree
    /// once the 0.4 rename seam opens. Returns empty on an unreadable blob, which is correct: restore would then
    /// have applied nothing, so the baseline it stamps is empty too.
    static func appliedKeys(from data: Data) -> Set<String> {
        guard let pairs = try? decodeDomain(from: data) else { return [] }
        return Set(pairs.keys.map(migratedKey))
    }

    /// Re-read the restored `UserDefaults` into every store that caches it at init, so a restore is actually
    /// VISIBLE without a relaunch and, more importantly, so no store can flush a stale cached value back over
    /// what the restore just wrote (each of these persists its in-memory value on the next change; see the
    /// per-store `reloadFromDefaults` docs for the exact write-back path).
    ///
    /// Deliberately NOT called from `restore` itself: `restore` is nonisolated and both callers run it inside a
    /// synchronous main-actor region, so hopping actors here would push the reload out past
    /// `VortXSyncManager.withRemoteApplySuppressed`'s window and let its writes arm a self-echo push. Callers
    /// invoke it synchronously instead, exactly like the neighbouring `ProfileStore.reloadFromDefaults()` /
    /// `LastStreamStore.invalidateCache()` calls on the sync path.
    ///
    /// Deliberately does NOT reload `ProfileStore`: the sync path has its OWN roster handling around the
    /// restore (capture-before / union-after / apply-tombstones), and a blind re-read here would run after that
    /// union and drop every local-only profile it just preserved.
    ///
    /// Ordering: the per-profile stores go last, because they key off `ProfileStore.activeID` and must see the
    /// settled roster. Every call is idempotent and guarded, so re-running it is a no-op.
    @MainActor
    static func reloadLiveStores() {
        AppLanguage.reapplyOverride()               // re-derive AppleLanguages from the restored override key
        ThemeManager.shared.reloadFromDefaults()    // accent / OLED / text scale (didSet re-persists: worst offender)
        HomeRailPreferences.shared.reloadFromDefaults()
        CatalogPreferences.shared.reloadFromDefaults()
        IPTVPlaylistStore.shared.reloadFromDefaults()
        // Media servers: same init-once shape as the playlists above (syncable metadata in UserDefaults, token
        // in the Keychain). Must run BEFORE the pull's `applySyncBlob`, which union-merges onto this in-memory
        // array: from a stale base the union silently drops any server the settings blob restored but the
        // apiKeys blob does not carry. reloadLiveStores runs synchronously inside the sync path's suppressed
        // region and applySyncBlob is dispatched after it, so that ordering holds.
        MediaServerStore.shared.reloadFromDefaults()
        // The two per-profile LAZY caches. Same write-back hazard as the init-once stores above, but by a
        // different mechanism: neither decodes at init, both memoize per profile on FIRST READ, and both
        // then read-modify-WRITE THE WHOLE per-profile blob through that memo. So once a screen has read
        // them, a restore lands in UserDefaults behind a populated cache and the very next ordinary write
        // flushes the pre-restore blob back over it:
        //  - LastStreamStore.record (`var dict = load(profileID)` -> save) rewrites the whole
        //    "stremiox.lastStream.<profile>" dict on the next play, dropping every Continue-Watching link
        //    the restore just brought back. That is the exact #145 symptom, so it must not depend on which
        //    restore path ran.
        //  - SavedLinksStore.save / .remove (`load(profileID)` -> persist) rewrite the whole
        //    "stremiox.savedLinks.<profile>" list on the next saved magnet, dropping every restored one.
        //    Its own header notes the store rides Backup & Restore and the cloud sync "for free", which is
        //    exactly what makes the stale cache destructive rather than merely stale.
        // Invalidate rather than re-read: both are lazy, so dropping the memo makes the next read decode the
        // restored value, and a write can then only ever build on it. Cheap (no decode here) and idempotent.
        //
        // LastStreamStore is ALSO invalidated explicitly on the sync path before this call. That call is now
        // redundant but deliberately left alone: it sits inside VortXSyncManager's ordered roster region, and
        // removing it would only trade a free no-op for the risk of that ordering changing later. The point of
        // doing it HERE is the OTHER caller: the iOS backup-FILE restore reaches restore() + reloadLiveStores()
        // and nothing else, so without this line that path keeps the stale cache and eats the write-back.
        // SavedLinksStore.invalidate had NO caller anywhere before this, so both restore paths ate it.
        LastStreamStore.invalidateCache()
        SavedLinksStore.invalidate()
        SourcePreferences.shared.reload()           // per-profile: needs the settled roster
        SourcePinStore.shared.reload()
    }
}
