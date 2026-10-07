import Foundation

// Compile the production tombstone sources without the unrelated Keychain/session stack.
// Migration/storage below runs real production functions against an isolated defaults suite.
final class CredentialScopeRegistry: @unchecked Sendable {
    static let shared = CredentialScopeRegistry()
    struct Capture { let namespace: String }
    private let lock = NSLock()
    private var namespace = "signed-out-device"
    func setNamespace(_ value: String) { lock.lock(); defer { lock.unlock() }; namespace = value }
    func capture() -> Capture { lock.lock(); defer { lock.unlock() }; return Capture(namespace: namespace) }
    func isCurrent(_ capture: Capture) -> Bool { true }
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }

@main enum AddonOwnerStorageTests {
    static func main() {
        let suite = "AddonOwnerStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = "account.11111111-1111-1111-1111-111111111111"
        let b = "account.22222222-2222-2222-2222-222222222222"
        let url = "https://example.invalid/addon/manifest.json"
        let removed = "stremiox.addons.removedAt", added = "stremiox.addons.addedAt"
        defaults.set([url: 100.0], forKey: removed)
        defaults.set([url: 200.0], forKey: AddonOwnerStorage.key(added, namespace: a))
        defaults.set([url], forKey: "stremiox.addons.deleted")
        defaults.set([url], forKey: "vortx.sync.appliedAddonOrder")
        defaults.set(true, forKey: "vortx.sync.addonBaselineStampedV2")
        precondition(!AddonOwnerStorage.migrateLegacy(namespace: "signed-out-device", authenticated: true, defaults: defaults))
        precondition(!AddonOwnerStorage.migrateLegacy(namespace: a, authenticated: false, defaults: defaults))
        precondition(AddonOwnerStorage.migrateLegacy(namespace: a, authenticated: true, defaults: defaults))
        precondition((defaults.dictionary(forKey: AddonOwnerStorage.key(added, namespace: a))?[url] as? NSNumber)?.doubleValue == 200)
        precondition(defaults.stringArray(forKey: AddonOwnerStorage.key("vortx.sync.appliedAddonOrder", namespace: a)) == [url])
        precondition(!AddonOwnerStorage.migrateLegacy(namespace: b, authenticated: true, defaults: defaults))
        precondition(defaults.object(forKey: AddonOwnerStorage.key(removed, namespace: b)) == nil)
        precondition(defaults.object(forKey: AddonOwnerStorage.key(removed, namespace: "signed-out-device")) == nil)
        precondition(defaults.dictionary(forKey: removed) != nil, "legacy source stays quarantined, recoverable")
        CredentialScopeRegistry.shared.setNamespace(a)
        precondition(AddonTombstones.all(defaults: defaults).isEmpty, "newer existing install out-races migrated removal")
        AddonTombstones.tombstone("https://example.invalid/a", defaults: defaults)
        CredentialScopeRegistry.shared.setNamespace(b)
        precondition(AddonTombstones.all(defaults: defaults).isEmpty)
        AddonTombstones.tombstone("https://example.invalid/b", defaults: defaults)
        CredentialScopeRegistry.shared.setNamespace("signed-out-device")
        precondition(AddonTombstones.all(defaults: defaults).isEmpty)
        AddonTombstones.tombstone("https://example.invalid/guest", defaults: defaults)
        CredentialScopeRegistry.shared.setNamespace(a)
        precondition(AddonTombstones.all(defaults: defaults) == ["https://example.invalid/a"])
        CredentialScopeRegistry.shared.setNamespace(b)
        precondition(AddonTombstones.all(defaults: defaults) == ["https://example.invalid/b"])
        CredentialScopeRegistry.shared.setNamespace("signed-out-device")
        precondition(AddonTombstones.all(defaults: defaults) == ["https://example.invalid/guest"])
        defaults.set([url: 300.0], forKey: AddonOwnerStorage.key(removed, namespace: b))
        precondition((defaults.dictionary(forKey: AddonOwnerStorage.key(removed, namespace: a))?[url] as? NSNumber)?.doubleValue == 100)
        precondition(AddonOwnerStorage.migrateLegacy(namespace: a, authenticated: true, defaults: defaults), "same owner may retry after interrupted migration")
        defaults.set("bad-marker", forKey: "vortx.sync.addons.legacyClaim.v2")
        precondition(!AddonOwnerStorage.migrateLegacy(namespace: a, authenticated: true, defaults: defaults))
        print("PASS production add-on owner key isolation, authenticated legacy claim, max receipts, order/baseline, retry and malformed marker")
    }
}
