// Source contract for tvOS update presentation wiring:
//
//   swift app/Tests/UpdateNotificationPresentationContractTests.swift

import Foundation

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SourcesTV/RootTabView.swift")
let source = (try? String(contentsOf: root, encoding: .utf8)) ?? ""
let appRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SourcesiOS/VortXiOSApp.swift")
let appSource = (try? String(contentsOf: appRoot, encoding: .utf8)) ?? ""
let checks = [
    (source.contains("@Environment(\\.scenePhase) private var scenePhase"), "tvOS observes lifecycle phase"),
    (source.contains("if phase == .active { updates.startMonitoring() }"), "foreground retries monitoring"),
    (source.contains(".onChange(of: updates.forcePresentationNonce) { _, _ in presentUpdateIfReady(force: true) }"), "manual update nonce forces tvOS presentation"),
    (source.contains("updates.presentAvailableIfNeeded(force: force)"), "tvOS passes force through to single-claim presentation"),
    (source.contains("else { updates.stopMonitoring() }"), "tvOS cancels monitoring while inactive"),
    (appSource.contains("UpdateChecker.shared.startMonitoring()"), "iOS and macOS start monitoring when active"),
    (appSource.contains("UpdateChecker.shared.stopMonitoring()"), "iOS and macOS cancel monitoring while inactive")
]
var failures = 0
for (condition, message) in checks {
    if condition { print("PASS  \(message)") } else { print("FAIL  \(message)"); failures += 1 }
}
exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
