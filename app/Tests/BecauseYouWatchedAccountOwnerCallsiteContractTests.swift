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
              let account = read(root, "app/SourcesShared/StremioAccount.swift"),
              let bridge = read(root, "app/SourcesShared/CoreBridge.swift") else {
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
            let ownerRefresh = name == "tvOS"
                ? ".onChange(of: becauseYouWatchedOwnerKey) { refreshTopPicks() }"
                : ".onValueChange(of: becauseYouWatchedOwnerKey) { _ in refreshTopPicks() }"
            check(source.contains(ownerRefresh),
                  "\(name) Home refreshes when the settled owner key changes")
            check(source.contains(".onReceive(account.$email) { _ in refreshTopPicks() }"),
                  "\(name) Home observes the published same-slot account event")
            check(!source.contains("ownerKey: \"\\(profiles.activeKeychainAccount)|\\(account.isSignedIn)|\\(profiles.activeUsesEngineHistory)\""),
                  "\(name) Home does not use the pre-fix slot/sign-in-only owner key")
        }

        func boundedBody(_ text: String, after marker: String, until next: String) -> String {
            guard let start = text.range(of: marker),
                  let end = text.range(of: next, range: start.upperBound..<text.endIndex) else {
                preconditionFailure("Missing bounded production method: " + marker)
            }
            return String(text[start.lowerBound..<end.lowerBound])
        }
        let passwordLogin = boundedBody(account, after: "    func signIn(email rawEmail:",
            until: "    enum LinkSignInOutcome:")
        let linkLogin = boundedBody(account, after: "    func signInWithAuthKey(", until: "    func signOut()")
        let ownLogin = boundedBody(bridge, after: "@MainActor func authenticateNativeOwnAccount(",
            until: "    @MainActor private func authenticateNativeOwnerAccount(")
        let ownerLogin = boundedBody(bridge, after: "@MainActor private func authenticateNativeOwnerAccount(",
            until: "    private static func readNativeCredential")
        check(passwordLogin.contains("captureNativeAccountLogin(importOwnerAddons: true)") &&
                passwordLogin.contains("try await CoreBridge.shared.authenticateNativeOwnAccount(token: key, target: nativeTarget)") &&
                passwordLogin.contains("guard authOperationStillCurrent(context) else { return }") &&
                passwordLogin.contains("if !isSignedIn { isSignedIn = true }"),
              "password sign-in retains its admitted native target and captured auth operation")
        check(linkLogin.contains("captureNativeAccountLogin(importOwnerAddons: true)") &&
                linkLogin.contains("try await CoreBridge.shared.authenticateNativeOwnAccount(token: token, target: target)") &&
                linkLogin.contains("CredentialScopeRegistry.shared.isCurrent(nativeCapture)") &&
                linkLogin.contains("authOperationGeneration == context.generation") &&
                linkLogin.contains("ProfileStore.shared.active?.id == context.profileID"),
              "link sign-in independently retains its credential, operation and selected-profile capture")
        check(ownerLogin.contains("expectedSelection: target.expectedOwnerSelection, authority: authority, read: Self.readNativeCredential") &&
                ownLogin.contains("try Self.stageNativeCredential(token: token, source: source, transactionID: target.transactionID, capture: capture, authority: authority)"),
              "owner and own-profile routes each retain their real secure credential-selection boundary")
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
