// Executable contract:
//
//   xcrun swiftc -o /tmp/sync-entropy-contract \
//     app/SourcesShared/VortXSecureEntropy.swift \
//     app/Tests/SyncEntropyContractTests.swift \
//     -framework Security &&
//     /tmp/sync-entropy-contract

import Foundation

@main
private enum SyncEntropyContractTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name)")
            }
        }

        check(
            "entropy provider failure returns nil instead of zero bytes",
            VortXSecureEntropy.randomBytes(32, fill: { _ in false }) == nil)

        let known = Data((0..<16).map(UInt8.init))
        let code = VortXSecureEntropy.recoveryCode(from: known)
        check("recovery code requires exactly 128 bits",
              VortXSecureEntropy.recoveryCode(from: Data(repeating: 1, count: 15)) == nil
                  && VortXSecureEntropy.recoveryCode(from: Data(repeating: 1, count: 17)) == nil)
        check("known entropy produces the stable Crockford shape",
              code?.hasPrefix("VX-") == true
                  && code?.replacingOccurrences(of: "-", with: "").count == 28)

        if failures > 0 {
            print("\n\(failures) FAILED")
            exit(1)
        }
        print("\nALL PASS")
    }
}
