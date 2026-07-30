// Standalone source contract for profile deletion and playback-progress ownership.
//
// Run from the repository root:
//
//   xcrun swiftc -warnings-as-errors \
//     -o /tmp/profile-invariant-contract \
//     app/Tests/ProfileInvariantContractTests.swift &&
//   /tmp/profile-invariant-contract
//
// Profile mutations have multiple UI entry points, so the shared ProfileStore boundary must reject
// deletion of the stored owner record. Playback progress similarly crosses both Apple player views,
// so the shared StremioAccount boundary must divert overlay progress before any account persistence.

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

private func functionBody(in source: String, signature: String) -> String? {
    guard let signatureRange = source.range(of: signature),
          let openBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else { return nil }

    var depth = 0
    var cursor = openBrace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openBrace...cursor])
            }
        default:
            break
        }
        cursor = source.index(after: cursor)
    }
    return nil
}

private func deletionViolations(in source: String) -> [String] {
    guard let body = functionBody(in: source, signature: "func remove(_ profile: UserProfile)") else {
        return ["ProfileStore.remove(_:) is missing"]
    }

    var found: [String] = []
    if !body.contains("let target = profiles.first(where: { $0.id == profile.id })") {
        found.append("the stored profile is not resolved before authorization")
    }
    if !body.contains("!target.isOwner") {
        found.append("the stored owner flag is not rejected")
    }
    if !body.contains("target.id != UserProfile.ownerID") {
        found.append("the fixed owner id is not rejected")
    }
    if !body.contains("profiles.removeAll { $0.id == target.id }") {
        found.append("deletion is not keyed to the authorized stored target")
    }
    return found
}

private func overlayProgressViolations(in source: String) -> [String] {
    guard let body = functionBody(
        in: source,
        signature: "func saveProgress(for meta: PlaybackMeta"
    ) else {
        return ["StremioAccount.saveProgress is missing"]
    }

    var found: [String] = []
    guard let overlayGate = body.range(of: "if !ProfileStore.shared.activeUsesEngineHistory"),
          let overlayWrite = body.range(of: "ProfileStore.shared.recordProgress"),
          let accountGate = body.range(of: "guard ProfileSync.alsoSyncToStremio") else {
        return ["overlay progress is not diverted at the shared account boundary"]
    }
    if overlayGate.lowerBound >= overlayWrite.lowerBound || overlayWrite.lowerBound >= accountGate.lowerBound {
        found.append("overlay routing does not precede account persistence")
    }
    let betweenOverlayAndAccount = body[overlayWrite.upperBound..<accountGate.lowerBound]
    if !betweenOverlayAndAccount.contains("return") {
        found.append("overlay progress can fall through to account persistence")
    }
    return found
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let profilesPath = URL(fileURLWithPath: root)
    .appendingPathComponent("app/SourcesShared/Profiles.swift").path
let accountPath = URL(fileURLWithPath: root)
    .appendingPathComponent("app/SourcesShared/StremioAccount.swift").path

guard let profilesSource = try? String(contentsOfFile: profilesPath, encoding: .utf8),
      let accountSource = try? String(contentsOfFile: accountPath, encoding: .utf8) else {
    print("FAIL  could not read production profile sources under \(root)")
    exit(1)
}

let productionDeletionViolations = deletionViolations(in: profilesSource)
check(productionDeletionViolations.isEmpty, "shipping removal rejects the stored owner profile")
for violation in productionDeletionViolations {
    print("      \(violation)")
}

let productionOverlayViolations = overlayProgressViolations(in: accountSource)
check(productionOverlayViolations.isEmpty, "shipping progress diverts overlays before account persistence")
for violation in productionOverlayViolations {
    print("      \(violation)")
}

let callerTrustedDeletionFixture = """
func remove(_ profile: UserProfile) -> SwitchOutcome? {
    guard profiles.count > 1, profiles.contains(where: { $0.id == profile.id }) else { return nil }
    profiles.removeAll { $0.id == profile.id }
    tombstone(profile.id)
    return nil
}
"""
check(
    !deletionViolations(in: callerTrustedDeletionFixture).isEmpty,
    "gate rejects the pre-fix caller-trusted deletion shape"
)

let accountFallthroughFixture = """
func saveProgress(for meta: PlaybackMeta, positionSeconds: Double, durationSeconds: Double) async {
    guard ProfileSync.alsoSyncToStremio else { return }
    await datastorePut(authKey: key, change: item)
}
"""
check(
    !overlayProgressViolations(in: accountFallthroughFixture).isEmpty,
    "gate rejects account progress without an overlay diversion"
)

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
}

print("\(failures) TEST(S) FAILED")
exit(1)
