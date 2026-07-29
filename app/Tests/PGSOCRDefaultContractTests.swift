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

        guard PGSOCRPolicy.isEnabled(in: defaults) else {
            fputs("FAIL: a missing override must default safe asynchronous PGS OCR on\n", stderr)
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

        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let profiles = try? String(
            contentsOf: appRoot.appendingPathComponent("SourcesShared/Profiles.swift"),
            encoding: .utf8),
              !profiles.contains(PGSOCRPolicy.overrideKey) else {
            fputs("FAIL: profile capture/apply must not mutate the device-local OCR key\n", stderr)
            exit(1)
        }
        for relativePath in ["SourcesTV/SettingsView.swift", "SourcesiOS/iOSSettingsView.swift"] {
            guard let settings = try? String(
                contentsOf: appRoot.appendingPathComponent(relativePath),
                encoding: .utf8),
                  settings.contains("@AppStorage(PGSOCRPolicy.overrideKey)"),
                  settings.contains("Recognize image subtitles") else {
                fputs("FAIL: \(relativePath) must expose the device-local OCR toggle\n", stderr)
                exit(1)
            }
        }

        print("PASS: PGS OCR defaults on, honors device-local overrides, and is not profile-mutated")
    }
}
