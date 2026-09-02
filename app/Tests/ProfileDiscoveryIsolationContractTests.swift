// Executable behavior contract for profile-scoped catalog and Discover preferences.
//
// Run from the repository root:
//
//   xcrun swiftc -warnings-as-errors \
//     app/SourcesShared/ProfileDiscoveryPreferences.swift \
//     app/Tests/ProfileDiscoveryIsolationContractTests.swift \
//     -o /tmp/profile-discovery-isolation-contract && \
//   /tmp/profile-discovery-isolation-contract
//
// The isolation tests compile and execute the shipping Foundation-only persistence bridge. They
// therefore cover the exact capture/apply state transition ProfileStore uses, not a test duplicate.

import Foundation

private var failures = 0

private func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func suite() -> UserDefaults {
    let name = "ProfileDiscoveryIsolationContractTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else { fatalError("could not create isolated suite") }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let allKeys = [
    ProfileDiscoveryPreferencesStore.Key.hiddenCatalogs,
    ProfileDiscoveryPreferencesStore.Key.catalogOrder,
    ProfileDiscoveryPreferencesStore.Key.hiddenHubCategories,
    ProfileDiscoveryPreferencesStore.Key.regionOverride,
    ProfileDiscoveryPreferencesStore.Key.filters,
    ProfileDiscoveryPreferencesStore.Key.selectedProviders,
    ProfileDiscoveryPreferencesStore.Key.providerOrder,
]

private let profileA = ProfileDiscoveryPreferences(
    hiddenCatalogs: ["addon|movie|hidden"],
    catalogOrder: ["addon|series|first", "addon|movie|hidden"],
    hiddenHubCategories: ["discover:upcoming", "genre:horror"],
    regionOverrideCaptured: true,
    regionOverride: "gb",
    filtersCaptured: true,
    filtersData: Data("{\"includedGenres\":[\"Drama\"],\"upcomingOnly\":true}".utf8),
    selectedProviders: [9, 8],
    providerOrder: [8, 9])

@main
private enum ProfileDiscoveryIsolationContract {
    static func main() {
// Profile A's state must return exactly after a clean profile B has been selected in between.
do {
    let defaults = suite()
    ProfileDiscoveryPreferencesStore.apply(profileA, resetUnset: true, to: defaults)
    let capturedA = ProfileDiscoveryPreferencesStore.capture(from: defaults)
    ProfileDiscoveryPreferencesStore.apply(nil, resetUnset: true, to: defaults)
    check(allKeys.allSatisfy { defaults.object(forKey: $0) == nil },
          "a fresh profile clears every discovery and provider flat key")
    ProfileDiscoveryPreferencesStore.apply(capturedA, resetUnset: true, to: defaults)
    check(ProfileDiscoveryPreferencesStore.capture(from: defaults) == capturedA,
          "switching back restores profile A without inheriting profile B defaults")
}

// A synced explicit clear is different from a legacy missing field. It must clear the active
// viewer immediately during a background fold and remain cleared when the next edit is captured.
do {
    let defaults = suite()
    ProfileDiscoveryPreferencesStore.apply(profileA, resetUnset: true, to: defaults)
    let remoteClear = ProfileDiscoveryPreferences(
        hiddenCatalogs: ["other|catalog"],
        regionOverrideCaptured: true,
        regionOverride: nil,
        filtersCaptured: true,
        filtersData: nil)
    ProfileDiscoveryPreferencesStore.apply(remoteClear, resetUnset: false, to: defaults)
    check(defaults.object(forKey: ProfileDiscoveryPreferencesStore.Key.regionOverride) == nil &&
          defaults.object(forKey: ProfileDiscoveryPreferencesStore.Key.filters) == nil,
          "remote explicit clears remove active region and filters during sync fold")
    ProfileDiscoveryPreferencesStore.setCatalogOrder(["new-order"], in: defaults)
    let recaptured = ProfileDiscoveryPreferencesStore.capture(from: defaults)
    check(recaptured.regionOverrideCaptured == true && recaptured.regionOverride == nil &&
          recaptured.filtersCaptured == true && recaptured.filtersData == nil,
          "a later discovery edit cannot recapture stale cleared region or filters")
}

// Upgrade migration belongs to the stored active profile only. Inactive old records deliberately
// remain nil, so their first switch takes the documented clean-default path rather than A's state.
do {
    let defaults = suite()
    ProfileDiscoveryPreferencesStore.apply(profileA, resetUnset: true, to: defaults)
    var oldRoster: [ProfileDiscoveryPreferences?] = [nil, nil]
    oldRoster[0] = ProfileDiscoveryPreferencesStore.capture(from: defaults) // active-only migration
    check(oldRoster[0]?.regionOverride == "GB" && oldRoster[0]?.filtersData == profileA.filtersData,
          "active pre-upgrade profile receives the existing flat snapshot")
    check(oldRoster[1] == nil, "inactive pre-upgrade profile is not cloned from the active viewer")
    ProfileDiscoveryPreferencesStore.apply(oldRoster[1], resetUnset: true, to: defaults)
    check(allKeys.allSatisfy { defaults.object(forKey: $0) == nil },
          "inactive legacy profile starts from clean defaults on first switch")
}

// A partial synced roster has a snapshot but no region/filter fields. It must not wipe the visible
// profile during an adoption fold, while selecting it for real must deliberately reset to defaults.
do {
    let defaults = suite()
    ProfileDiscoveryPreferencesStore.apply(profileA, resetUnset: true, to: defaults)
    let partial = ProfileDiscoveryPreferences(hiddenCatalogs: ["other|catalog"])
    ProfileDiscoveryPreferencesStore.apply(partial, resetUnset: false, to: defaults)
    check(ProfileDiscoveryPreferencesStore.regionOverride(from: defaults) == "GB" &&
          ProfileDiscoveryPreferencesStore.filtersData(from: defaults) == profileA.filtersData,
          "partial sync snapshot leaves absent region and filters live until selection")
    ProfileDiscoveryPreferencesStore.apply(partial, resetUnset: true, to: defaults)
    check(defaults.object(forKey: ProfileDiscoveryPreferencesStore.Key.regionOverride) == nil &&
          defaults.object(forKey: ProfileDiscoveryPreferencesStore.Key.filters) == nil,
          "real switch resolves absent region and filters to clean defaults")
}

// Older sync roster entries omit discovery entirely. Optional Codable decoding must accept them.
do {
    let oldPayload = "{\"name\":\"Legacy\"}".data(using: .utf8)!
    struct LegacyCompatibleProfile: Codable { var name: String; var discovery: ProfileDiscoveryPreferences? }
    let decoded = try? JSONDecoder().decode(LegacyCompatibleProfile.self, from: oldPayload)
    check(decoded?.name == "Legacy" && decoded?.discovery == nil,
          "old roster payloads decode with an absent discovery snapshot")
}

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
}

print("\(failures) TEST(S) FAILED")
exit(1)
    }
}
