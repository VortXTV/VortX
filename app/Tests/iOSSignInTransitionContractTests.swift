// Standalone source contract for the iOS Stremio sign-in handoff.
//
// Run from the repository root:
//
//   xcrun swiftc -warnings-as-errors \
//     -o /tmp/ios-signin-transition-contract \
//     app/Tests/iOSSignInTransitionContractTests.swift &&
//   /tmp/ios-signin-transition-contract
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

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
}

print("\(failures) TEST(S) FAILED")
exit(1)
