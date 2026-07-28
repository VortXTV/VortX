// Standalone regression contract for the Build 200 PGS OCR producer stall.
//
// Run with:
//   swiftc -parse-as-library -o /tmp/pgs-ocr-default \
//     app/Sources/Player/PGSOCRPolicy.swift app/Tests/PGSOCRDefaultContractTests.swift \
//     && /tmp/pgs-ocr-default

import Foundation

@main
struct PGSOCRDefaultContractTests {
    static func main() {
        let suiteName = "vortx.tests.pgs-ocr-default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("FAIL: could not create isolated defaults\n", stderr)
            exit(1)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        guard !PGSOCRPolicy.isEnabled(in: defaults) else {
            fputs("FAIL: a missing override must default PGS OCR off\n", stderr)
            exit(1)
        }

        defaults.set(true, forKey: PGSOCRPolicy.overrideKey)
        guard PGSOCRPolicy.isEnabled(in: defaults) else {
            fputs("FAIL: an explicit true override must enable PGS OCR\n", stderr)
            exit(1)
        }

        defaults.set(false, forKey: PGSOCRPolicy.overrideKey)
        guard !PGSOCRPolicy.isEnabled(in: defaults) else {
            fputs("FAIL: an explicit false override must disable PGS OCR\n", stderr)
            exit(1)
        }

        print("PASS: PGS OCR defaults off and honors explicit true and false overrides")
    }
}
