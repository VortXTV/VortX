import Foundation

// The runner extracts the actual pure CoreBridge presentation method and localized constants.
// These flags are synthetic observations, not a native runtime, credential or storage fixture.
// Production observation/capture wiring and unchanged mutation guards have a separate source contract.
@main
private enum AddonMutationFailurePresentationTests {
    private struct Case {
        let label: String
        let publicationCurrent: Bool
        let operationCredentialCurrent: Bool
        let installedCredentialCurrent: Bool?
        let logoutPending: Bool
        let nativeAvailable: Bool
        let expectsUnavailable: Bool
    }

    static func main() {
        let transition = "Your account is switching or signing out. Try again in a moment."
        let unavailable = "Your profile data is unavailable right now. Try opening your profile again. If this continues, export diagnostic logs from the profile picker."
        let cases: [Case] = [
            .init(label: "no installed session with stable owner", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: nil, logoutPending: false, nativeAvailable: false, expectsUnavailable: true),
            .init(label: "closed native session with current installed owner", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: true, logoutPending: false, nativeAvailable: false, expectsUnavailable: true),
            .init(label: "available facade without installed credential", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: nil, logoutPending: false, nativeAvailable: true, expectsUnavailable: true),
            .init(label: "publication epoch changed while fetch awaited", publicationCurrent: false, operationCredentialCurrent: true, installedCredentialCurrent: nil, logoutPending: false, nativeAvailable: false, expectsUnavailable: false),
            .init(label: "original operation owner retired while fetch awaited", publicationCurrent: true, operationCredentialCurrent: false, installedCredentialCurrent: nil, logoutPending: false, nativeAvailable: false, expectsUnavailable: false),
            .init(label: "installed session still belongs to retired owner", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: false, logoutPending: false, nativeAvailable: false, expectsUnavailable: false),
            .init(label: "pending sign-out wins over unavailable session", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: nil, logoutPending: true, nativeAvailable: false, expectsUnavailable: false),
            .init(label: "ready facade retains existing other-refusal response", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: true, logoutPending: false, nativeAvailable: true, expectsUnavailable: false),
            .init(label: "old operation cannot borrow newly ready session", publicationCurrent: true, operationCredentialCurrent: false, installedCredentialCurrent: true, logoutPending: false, nativeAvailable: true, expectsUnavailable: false),
            .init(label: "ready session cannot hide pending sign-out", publicationCurrent: true, operationCredentialCurrent: true, installedCredentialCurrent: true, logoutPending: true, nativeAvailable: true, expectsUnavailable: false),
        ]
        for item in cases {
            let actual = CoreBridge.present(
                publicationCurrent: item.publicationCurrent,
                operationCredentialCurrent: item.operationCredentialCurrent,
                installedCredentialCurrent: item.installedCredentialCurrent,
                logoutPending: item.logoutPending,
                nativeAvailable: item.nativeAvailable)
            precondition(actual == (item.expectsUnavailable ? unavailable : transition), item.label)
        }
        print("PASS: 10 actual-source add-on failure presentation cases (synthetic observations)")
    }
}
