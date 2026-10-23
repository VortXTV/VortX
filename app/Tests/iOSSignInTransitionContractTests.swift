// Standalone source contract for the iOS Stremio sign-in handoff.
//
// Run from the repository root:
//
//   xcrun swiftc -warnings-as-errors \
//     -o app/build/ios-signin-transition-contract \
//     app/Tests/iOSSignInTransitionContractTests.swift &&
//   app/build/ios-signin-transition-contract
//
// A Combine @Published publisher immediately emits its current value to each new subscriber. The sign-in
// sheet therefore must observe a real false-to-true transition with SwiftUI onChange, never subscribe to
// account.$isSignedIn with onReceive. This gate reads the shipping view source so a future reversion fails.

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

private func executableSource(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

private func violations(in source: String) -> [String] {
    let executable = executableSource(source)
    var found: [String] = []
    if executable.contains(".onReceive(account.$isSignedIn)") {
        found.append("replaying account publisher is subscribed with onReceive")
    }
    if !executable.contains(".onChange(of: account.isSignedIn)") {
        found.append("real account sign-in transition is not observed with onChange")
    }
    return found
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let relativePath = "app/SourcesiOS/iOSSignInView.swift"
let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath).path

guard let production = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("FAIL  could not read \(path)")
    exit(1)
}

let productionViolations = violations(in: production)
check(productionViolations.isEmpty, "shipping iOS sign-in observes only real sign-in transitions")
for violation in productionViolations {
    print("      \(violation)")
}

let replayingFixture = """
struct iOSSignInView {
    var body: some View {
        content
            .onReceive(account.$isSignedIn) { signedIn in
                guard signedIn else { return }
                dismiss()
            }
    }
}
"""
check(!violations(in: replayingFixture).isEmpty, "gate rejects the pre-fix replaying publisher shape")

// Native authentication closes the sign-in sheet immediately. The fenced manager restore is
// intentionally separate: it owns the loading/Retry surface, not a second UI reconciliation.
func nativeQRHandoffViolations(_ source: String) -> [String] {
    let executable = executableSource(source)
    guard let signedIn = executable.range(of: "case .signedIn(let email):\n                status = .signedIn(email)"),
          let native = executable[signedIn.upperBound...].range(of: "#if VORTX_NATIVE_DATA_ENGINE"),
          let legacy = executable[native.upperBound...].range(of: "#else") else {
        return ["native QR authentication handoff is absent"]
    }
    let handoff = executable[native.upperBound..<legacy.lowerBound]
    var found: [String] = []
    if !handoff.contains("onSignedIn()") { found.append("authenticated QR sheet does not close") }
    if handoff.contains("await ") { found.append("authenticated QR sheet waits for restore instead of handing off") }
    return found
}

let joinerPath = URL(fileURLWithPath: root).appendingPathComponent("app/SourcesShared/VortXAccountJoinerView.swift").path
let settingsPath = URL(fileURLWithPath: root).appendingPathComponent("app/SourcesShared/SyncSettingsView.swift").path
guard let joiner = try? String(contentsOfFile: joinerPath, encoding: .utf8),
      let settings = try? String(contentsOfFile: settingsPath, encoding: .utf8) else {
    print("FAIL  could not read native authentication handoff sources")
    exit(1)
}
let signInExecutable = executableSource(production)
check(signInExecutable.contains("SyncSettingsView(onSignedIn: { dismiss() })"),
      "typed sign-in explicitly closes the outer sign-in sheet")
let qrViolations = nativeQRHandoffViolations(joiner)
check(qrViolations.isEmpty, "native QR sign-in closes before account restoration")
for violation in qrViolations { print("      \(violation)") }
let settingsExecutable = executableSource(settings)
let callback = "if let onSignedIn {\n                onSignedIn()\n                return"
check(settingsExecutable.contains(callback), "typed authentication callback returns before a second restore")
check(settingsExecutable.contains("showQRSignIn = false\n                    onSignedIn?()"),
      "QR success also closes the embedding recovery sign-in surface")
let profilesPath = URL(fileURLWithPath: root).appendingPathComponent("app/SourcesShared/ProfilesView.swift").path
guard let profiles = try? String(contentsOfFile: profilesPath, encoding: .utf8) else {
    print("FAIL  could not read profile recovery sign-in source")
    exit(1)
}
check(executableSource(profiles).contains("SyncSettingsView(onSignedIn: { dismiss() })"),
      "profile recovery closes after typed or QR authentication without requiring Escape")
let waitingQRFixture = """
case .signedIn(let email):
                status = .signedIn(email)
#if VORTX_NATIVE_DATA_ENGINE
                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                onSignedIn()
#else
                onSignedIn()
#endif
"""
check(!nativeQRHandoffViolations(waitingQRFixture).isEmpty,
      "gate rejects the old authenticated-but-still-waiting QR sheet")

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
}

print("\(failures) TEST(S) FAILED")
exit(1)
