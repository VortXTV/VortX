// Source contract for the macOS in-window navigation and category Settings workspace.
//
// Run from the repository root:
//
//   swift app/Tests/MacSettingsShellContractTests.swift
//
// This intentionally checks source wiring, not a physical Mac interaction receipt. The native build
// remains the compiler/UI verification for SwiftUI and AppKit.

import Foundation

private var failures = 0

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

private func source(_ relativePath: String, root: URL) -> String? {
    try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
guard let app = source("app/SourcesiOS/VortXiOSApp.swift", root: root),
      let rootView = source("app/SourcesiOS/iOSRootView.swift", root: root),
      let settings = source("app/SourcesiOS/iOSSettingsView.swift", root: root) else {
    fputs("FAIL  read Mac shell sources\n", stderr)
    exit(1)
}

require(!app.contains("\n        Settings {"), "Mac app declares no separate Settings scene")
require(!app.contains("MacSettingsSurface"), "Mac app has no duplicate settings TabView host")
require(app.contains("CommandGroup(replacing: .appSettings)"), "standard app Settings command is replaced")
require(app.contains("Button(\"Settings…\") { MacCommands.go(.settings) }"), "app Settings command routes in-window")
require(app.contains("CommandMenu(\"Go\")"), "Mac restores the Go menu")
require(app.contains("Button(\"Live TV\")  { MacCommands.go(.live) }.keyboardShortcut(\"3\", modifiers: .command)"),
        "Go menu exposes Live TV with Cmd-3")
require(app.contains("Button(\"Add-ons\")  { MacCommands.go(.addons) }.keyboardShortcut(\"5\", modifiers: .command)"),
        "Go menu exposes Add-ons with Cmd-5")
require(app.contains("Button(\"Search\")   { MacCommands.go(.search) }.keyboardShortcut(\"f\", modifiers: .command)"),
        "Go menu exposes Search with Cmd-F")

require(!rootView.contains("@Environment(\\.openSettings)"), "root does not use openSettings")
require(!rootView.contains("SettingsLink"), "root has no SettingsLink")
require(rootView.contains("private var macDesktopShell: some View"), "root has a dedicated desktop shell")
require(!rootView.contains("macSidebar"), "desktop main navigation has no rejected sidebar")
require(rootView.contains(".safeAreaInset(edge: .top, spacing: 0) { cinematicTopBar }"),
        "desktop shell hosts horizontal TV-inspired top navigation without obscuring forms")
require(rootView.contains("ForEach(visibleTabs, id: \\.rawValue) { item in\n                        horizontalTabButton(item)"),
        "horizontal navigation uses the same visibility-filtered destinations")
require(rootView.contains("ScrollView(.horizontal, showsIndicators: false)") && rootView.contains("proxy.scrollTo(item.rawValue, anchor: .center)"),
        "narrow desktop navigation scrolls selected routes into view")
require(rootView.contains("geometry.size.width >= 760") && rootView.contains("UIDevice.current.userInterfaceIdiom == .pad"),
        "wide iPad uses top navigation while phones and narrow windows retain a bottom bar")
require(rootView.contains("TabBarPrefs.compactLayout(visible: visibleTabs") && rootView.contains("ForEach(compactTabLayout.overflow"),
        "compact More menu cannot resurrect hidden destinations")
require(rootView.contains("private var selectedTabContent: some View"), "one route owner feeds phone and Mac")
require(rootView.contains("case .addons:\n            AddonsView()"), "Add-ons route renders AddonsView")
require(rootView.contains("case .settings:\n            iOSSettingsView()"), "Settings route renders the in-window form")
require(occurrences(of: "iOSSettingsView()", in: rootView) == 1,
        "root owns exactly one Settings form route")
require(rootView.contains("@FocusState private var tabFocus: MacBrowseFocus?"), "horizontal navigation retains keyboard focus state")
require(rootView.contains("@State private var macQuery = \"\""), "desktop chrome retains media search state")
require(rootView.contains(".focused($macSearchFocused)") && rootView.contains("private func submitMacSearch()") && rootView.contains(".popover(isPresented: $macSearchPresented)"),
        "Cmd-F search remains focusable and routes to the existing search host")
require(rootView.contains(".frame(minWidth: 28, minHeight: 28)") && rootView.contains(".accessibilityLabel(\"Clear search\")"),
        "desktop clear-search control has an accessible hit target")
require(rootView.contains(".onExitCommand") && rootView.contains("tabFocus = .tab(tab.rawValue)"),
        "Escape returns desktop chrome focus to the active route")
require(rootView.contains("if item == .library, activeDownloadCount > 0"), "download badge survives in Library navigation")
require(rootView.contains("reduceMotion ? nil : .easeOut"), "shell respects Reduce Motion")

require(settings.contains("private var macSettingsShell: some View"), "Settings has a desktop workspace")
require(settings.contains("private var macSettingsCategoryRail: some View"), "Settings exposes navigable categories")
require(settings.contains("@State private var macSettingsCategory: MacSettingsCategory = .profile"),
        "Settings keeps explicit category selection")
require(settings.contains("ForEach(MacSettingsCategory.allCases)"), "all desktop categories are navigable")
require(settings.contains("private func macSettingsSection(_ section: SettingsSearchSection) -> some View"),
        "desktop category content reuses typed real-section routing")
require(settings.contains("SettingsSearchSection.allCases.filter(sectionMatches)"),
        "settings search spans every category")
for required in ["accountSection", "playbackSection", "streamsSection", "serverSection", "audioSubtitleSection", "subtitleSection", "advancedSection", "backupSection"] {
    require(settings.contains(required), "desktop settings retains \(required)")
}
require(settings.contains(".sheet(isPresented: $showDiagExport") && settings.contains(".fileExporter(isPresented: $showBackupExporter"),
        "desktop workspace retains existing settings presentations")

if failures > 0 {
    fputs("\n\(failures) Mac settings shell contract failure(s)\n", stderr)
    exit(1)
}

print("\nALL PASS")
