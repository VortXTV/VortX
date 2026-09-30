// Source contract for the non-secret same-slot Stremio credential boundary.
//
// Run from repository root:
//   swiftc -parse-as-library -warnings-as-errors \
//     -o /tmp/because-you-watched-credential-boundary-contract \
//     app/Tests/BecauseYouWatchedCredentialBoundaryContractTests.swift && \
//   /tmp/because-you-watched-credential-boundary-contract .

import Foundation

@main
@MainActor
private struct BecauseYouWatchedCredentialBoundaryContractTests {
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }

    private static func read(_ root: String, _ path: String) -> String? {
        try? String(
            contentsOf: URL(fileURLWithPath: root).appendingPathComponent(path),
            encoding: .utf8
        )
    }

    static func main() {
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        guard let account = read(root, "app/SourcesShared/StremioAccount.swift"),
              let core = read(root, "app/SourcesShared/CoreBridge.swift"),
              let tv = read(root, "app/SourcesTV/HomeView.swift"),
              let ios = read(root, "app/SourcesiOS/iOSRootView.swift") else {
            print("FAIL  could not read credential-boundary sources")
            exit(1)
        }

        check(account.contains("credentialBoundaryDidChange") &&
                account.contains("credentialBoundaryGeneration") &&
                account.contains("publishCredentialBoundary(wasSignedIn: wasSignedIn)"),
              "StremioAccount publishes a non-secret same-slot credential boundary")
        let eventBody: String = {
            guard let start = account.range(of: "userInfo: ["),
                  let end = account.range(of: "]\n        )", range: start.upperBound..<account.endIndex)
            else { return "" }
            return String(account[start.upperBound..<end.lowerBound])
        }()
        check(eventBody.contains("\"generation\": generation") &&
                eventBody.contains("\"wasSignedIn\": wasSignedIn") &&
                !eventBody.contains("authKey") &&
                !eventBody.contains("token"),
              "credential-boundary event carries only generation and prior sign-in state")
        let orderingIsSafe: Bool = {
            guard let start = account.range(of: "private func publishCredentialBoundary"),
                  let event = account.range(of: "NotificationCenter.default.post",
                                            range: start.upperBound..<account.endIndex),
                  let field = account.range(of: "credentialBoundaryGeneration = generation",
                                            range: start.upperBound..<account.endIndex)
            else { return false }
            return event.lowerBound < field.lowerBound
        }()
        check(orderingIsSafe,
              "CoreBridge rebind notification is posted before the SwiftUI refresh revision")
        check(core.contains("StremioAccount.credentialBoundaryDidChange") &&
                core.contains("lastCredentialBoundaryGeneration") &&
                core.contains("generation > self.lastCredentialBoundaryGeneration") &&
                core.contains("self.signedInWithLegacyAuthKey()") &&
                core.contains("queue: .main"),
              "CoreBridge deduplicates true-to-true boundaries and rebinds on main before history admission")
        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            check(source.contains(".onReceive(account.$credentialBoundaryGeneration) { _ in refreshTopPicks() }"),
                  "\(name) Home observes the same-slot credential generation")
        }

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
