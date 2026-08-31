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
let tvSettingsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SourcesTV/SettingsView.swift")
let tvSettingsSource = (try? String(contentsOf: tvSettingsRoot, encoding: .utf8)) ?? ""
let iOSSettingsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SourcesiOS/iOSSettingsView.swift")
let iOSSettingsSource = (try? String(contentsOf: iOSSettingsRoot, encoding: .utf8)) ?? ""
let iOSRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SourcesiOS/iOSRootView.swift")
let iOSRootSource = (try? String(contentsOf: iOSRoot, encoding: .utf8)) ?? ""
let promptRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SourcesShared/UpdatePromptView.swift")
let promptSource = (try? String(contentsOf: promptRoot, encoding: .utf8)) ?? ""
let checks = [
    (source.contains("@Environment(\\.scenePhase) private var scenePhase"), "tvOS observes lifecycle phase"),
    (source.contains("if phase == .active { updates.startMonitoring() }"), "foreground retries monitoring"),
    (source.contains(".onChange(of: updates.forcePresentationNonce) { _, _ in presentUpdateIfReady(force: true) }"), "manual update nonce forces tvOS presentation"),
    (source.contains("updates.presentAvailableIfNeeded(force: force)"), "tvOS passes force through to single-claim presentation"),
    (source.contains("else { updates.stopMonitoring() }"), "tvOS cancels monitoring while inactive"),
    (appSource.contains(".onAppear { UpdateChecker.shared.startMonitoring() }"), "iOS and macOS start monitoring on cold launch"),
    (appSource.contains("UpdateChecker.shared.startMonitoring()"), "iOS and macOS start monitoring when active"),
    (appSource.contains("UpdateChecker.shared.stopMonitoring()"), "iOS and macOS cancel monitoring while inactive"),
    (appSource.contains("UpdateChecker.shared.checkNow()"), "macOS menu uses the explicit manual check API"),
    (tvSettingsSource.contains("updates.checkNow()") && iOSSettingsSource.contains("updates.checkNow()"), "Apple Settings expose an explicit update check"),
    (tvSettingsSource.contains("updates.presentAvailableIfNeeded(force: true)") && iOSSettingsSource.contains("updates.presentAvailableIfNeeded(force: true)"), "Settings use the root-owned update sheet without competing bindings"),
    (tvSettingsSource.contains(".accessibilityLabel(\"Check for Updates\")") && iOSSettingsSource.contains(".accessibilityLabel(\"Check for Updates\")"), "manual checks have native accessibility labels"),
    (tvSettingsSource.contains("Unable to check. Try again.") && iOSSettingsSource.contains("You’re up to date"), "Settings visibly report manual check outcomes"),
    (tvSettingsSource.contains("accessibilityValue(updates.manualOutcome.accessibilityText)") && iOSSettingsSource.contains("accessibilityValue(updates.manualOutcome.accessibilityText)"), "manual check state has a dynamic VoiceOver value"),
    (tvSettingsSource.contains("UIAccessibility.post(notification: .announcement") && iOSSettingsSource.contains("UIAccessibility.post(notification: .announcement"), "manual check results announce to assistive technology"),
    (tvSettingsSource.contains(".focused($updateCheckFocused)") && tvSettingsSource.contains("if oldOutcome.isChecking, !outcome.isChecking { updateCheckFocused = true }"), "tvOS restores update-check focus only after a real manual completion"),
    (source.contains("!showSeedingNag") && source.contains("updates.prompt == nil") && source.contains("guard presenter.request == nil, updates.prompt == nil else { return false }") && source.contains(".sheet(item: updatePromptBinding, onDismiss:") && source.contains("Task { await armSeedingNag() }"), "tvOS gives updates and seeding one symmetric accepted modal slot"),
    (iOSRootSource.contains("!showSeedingNag") && iOSRootSource.contains("updates.prompt == nil") && iOSRootSource.contains("guard presenter.request == nil, updates.prompt == nil else { return false }") && iOSRootSource.contains(".sheet(item: updatePromptBinding, onDismiss:") && iOSRootSource.contains("Task { await armSeedingNag() }"), "iOS and macOS give updates and seeding one symmetric accepted modal slot"),
    (iOSRootSource.contains("UpdateCheckFeedback") && iOSRootSource.contains(".alert(item: $updateCheckFeedback)"), "macOS menu checks have visible current and failure feedback"),
    (promptSource.contains(".accessibilityHidden(true)") && promptSource.contains(".accessibilityAddTraits(.isHeader)"), "update prompt exposes a clean accessibility hierarchy"),
    (promptSource.contains("Open release page") && promptSource.contains("Apple TV cannot install an IPA from inside VortX"), "tvOS prompt does not claim that opening a page installs an IPA"),
    (promptSource.contains("UIAccessibility.post(notification: .announcement") && promptSource.contains("accessibilityValue(openFailed ? openFailureMessage : \"\")"), "tvOS open failures are exposed to VoiceOver"),
    (!tvSettingsSource.contains("GitHub releases page") && !iOSSettingsSource.contains("GitHub releases page"), "Settings hint copy does not name an implementation host")
]
var failures = 0
for (condition, message) in checks {
    if condition { print("PASS  \(message)") } else { print("FAIL  \(message)"); failures += 1 }
}
exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
