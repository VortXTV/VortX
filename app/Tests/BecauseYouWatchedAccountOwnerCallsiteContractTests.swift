// Standalone source contract for account-aware Apple Home recommendation ownership.
//
// Run from repository root:
//   swiftc -parse-as-library -warnings-as-errors -o /tmp/because-you-watched-account-owner-contract \
//     app/Tests/BecauseYouWatchedAccountOwnerCallsiteContractTests.swift && \
//   /tmp/because-you-watched-account-owner-contract .

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

@MainActor
private func read(_ root: String, _ relativePath: String) -> String? {
    let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
    return try? String(contentsOf: path, encoding: .utf8)
}

@main
@MainActor
enum BecauseYouWatchedAccountOwnerCallsiteContractTests {
    static func main() {
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        guard let model = read(root, "app/SourcesShared/BecauseYouWatchedModel.swift"),
              let tv = read(root, "app/SourcesTV/HomeView.swift"),
              let ios = read(root, "app/SourcesiOS/iOSRootView.swift"),
              let account = read(root, "app/SourcesShared/StremioAccount.swift") else {
            print("FAIL  could not read Apple recommendation/account sources")
            exit(1)
        }

        check(model.contains("static func recommendationOwnerKey(") &&
                model.contains("authorityGeneration: UInt64?") &&
                model.contains("accountEmail: String?"),
              "shared recommendation ownership accepts principal and auth authority without token material")
        check(model.contains("No auth\n    /// token or credential material belongs in this key."),
              "shared ownership contract explicitly excludes raw credentials")

        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            check(source.contains("BecauseYouWatchedModel.recommendationOwnerKey("),
                  "\(name) Home uses the shared account-aware owner key")
            check(source.contains("principal: binding?.uid") &&
                    source.contains("authorityGeneration: binding?.generation"),
                  "\(name) Home uses only the settled principal and authority generation")
            check(!source.contains("principal: binding?.uid ?? core.currentUID()"),
                  "\(name) Home never falls back to the resident engine UID for recommendation ownership")
            check(source.contains(".onChange(of: becauseYouWatchedOwnerKey) { _ in refreshTopPicks() }"),
                  "\(name) Home refreshes when the settled owner key changes")
            check(source.contains(".onReceive(account.$email) { _ in refreshTopPicks() }"),
                  "\(name) Home observes the published same-slot account event")
            check(!source.contains("ownerKey: \"\\(profiles.activeKeychainAccount)|\\(account.isSignedIn)|\\(profiles.activeUsesEngineHistory)\""),
                  "\(name) Home does not use the pre-fix slot/sign-in-only owner key")
        }

        check(account.contains("authKey = key") &&
                account.contains("if !isSignedIn { isSignedIn = true }"),
              "Stremio sign-in replaces credentials without relying on a true-to-true isSignedIn event")
        check(!model.contains("Keychain.string") && !tv.contains("Keychain.string") && !ios.contains("Keychain.string"),
              "recommendation ownership never reads or embeds a raw Keychain token")

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
