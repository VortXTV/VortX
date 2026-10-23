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
        func boundedBody(_ text: String, after marker: String, until next: String) -> String {
            guard let start = text.range(of: marker),
                  let end = text.range(of: next, range: start.upperBound..<text.endIndex) else {
                preconditionFailure("Missing bounded production method: " + marker)
            }
            return String(text[start.lowerBound..<end.lowerBound])
        }
        let ownLogin = boundedBody(core, after: "@MainActor func authenticateNativeOwnAccount(",
            until: "    @MainActor private func authenticateNativeOwnerAccount(")
        let ownerLogin = boundedBody(core, after: "@MainActor private func authenticateNativeOwnerAccount(",
            until: "    private static func readNativeCredential")
        let passwordLogin = boundedBody(account, after: "    func signIn(email rawEmail:",
            until: "    enum LinkSignInOutcome:")
        let linkLogin = boundedBody(account, after: "    func signInWithAuthKey(", until: "    func signOut()")
        func commitsBeforePublication(_ method: String, call: String) -> Bool {
            guard let commit = method.range(of: call),
                  let event = method.range(of: "publishCredentialBoundary(wasSignedIn: wasSignedIn)",
                                           range: commit.upperBound..<method.endIndex) else { return false }
            return commit.lowerBound < event.lowerBound
        }
        check(commitsBeforePublication(passwordLogin,
                call: "try await CoreBridge.shared.authenticateNativeOwnAccount(token: key, target: nativeTarget)") &&
                commitsBeforePublication(linkLogin,
                call: "try await CoreBridge.shared.authenticateNativeOwnAccount(token: token, target: target)"),
              "each password and link login commits before its own UI credential boundary")
        check(ownLogin.contains("nativePlaybackBinding(.native(target.binding))?.0 === facade") &&
                ownLogin.contains("CredentialScopeRegistry.shared.isCurrent(capture), nativeFacade === facade,") &&
                ownLogin.contains("ProfileStore.shared.activeID == target.profile.id") &&
                ownLogin.contains("try refreshNativeProfiles(reloadCredentials: false)"),
              "own-profile native login independently fences credential, installation and selected profile before refresh")
        check(ownerLogin.contains("nativePlaybackBinding(.native(target.binding))?.0 === facade") &&
                ownerLogin.contains("CredentialScopeRegistry.shared.isCurrent(capture) && facade.isAvailable && facade.accountGeneration == epoch") &&
                ownerLogin.contains("facade.profileSnapshot()?.state[\"activeProfileId\"] == .string(selectedProfileID)") &&
                ownerLogin.contains("expectedSelection: target.expectedOwnerSelection, authority: authority, read: Self.readNativeCredential") &&
                ownerLogin.contains("try refreshNativeProfiles(reloadCredentials: false)"),
              "owner native login independently fences credential, account generation, selected profile and secure selection")
        // iOS also refreshes Continue Watching on the next main turn; what matters is that each Home observes
        // the boundary and rebuilds Top Picks from it.
        for (name, source) in [("tvOS", tv), ("iOS", ios)] {
            let observes: Bool = {
                guard let start = source.range(of: ".onReceive(account.$credentialBoundaryGeneration) { _ in") else { return false }
                let body = source[start.upperBound...].prefix(240)
                return body.contains("refreshTopPicks()")
            }()
            check(observes, "\(name) Home observes the same-slot credential generation")
        }

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
