// SMB client against the libsmbclient the app ships (MPVKit-GPL), linked for macOS. No SMB server is needed:
// it proves the shim links, the context initializes, and a refused connection maps to a clear error.
// Run: scripts/test-network-shares.sh (skipped when the SwiftPM artifact cache is absent).

import Foundation
@main enum SMBLink {
    static func main() async {
        let root = NetworkSharePolicy.smbRootURL("smb://127.0.0.1/Movies")!
        do {
            _ = try await NetworkShareSMBClient.list(root, root: root, login: .init(username: "me", password: "pw"))
            print("FAIL  listed a share that does not exist"); exit(1)
        } catch let error as NetworkShareError {
            print("PASS  libsmbclient links, initializes and reports a refused connection as \(error)")
        } catch { print("FAIL  unexpected \(error)"); exit(1) }
    }
}
