// Source contract for the macOS in-window Settings and floating glass navigation shell.
//
// Run from the repository root:
//
//   swift app/Tests/MacSettingsShellContractTests.swift
//
// The native Mac build proves these SwiftUI declarations compile. This focused contract prevents the
// routing regression where a second SwiftUI Settings scene replaced the main-window Settings tab and
// replaced the single-window floating glass shell with a sidebar and duplicate Settings window.

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

private func section(in text: String, from start: String, to end: String) -> String? {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
        return nil
    }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
guard let app = source("app/SourcesiOS/VortXiOSApp.swift", root: root),
      let rootView = source("app/SourcesiOS/iOSRootView.swift", root: root) else {
    fputs("FAIL  read Mac shell sources\n", stderr)
    exit(1)
}

require(!app.contains("\n        Settings {"), "Mac app declares no separate Settings scene")
require(!app.contains("MacSettingsSurface"), "Mac app has no duplicate settings TabView host")
require(app.contains("CommandGroup(replacing: .appSettings)"), "standard app Settings command is replaced")
require(app.contains("Button(\"Settings…\") { MacCommands.go(.settings) }"), "app Settings command routes in-window")
require(app.contains("Button(\"Add-ons\")  { MacCommands.go(.addons) }.keyboardShortcut(\"5\", modifiers: .command)"),
        "Go menu exposes Add-ons with Cmd-5")
require(app.contains("CommandMenu(\"Go\")"), "Mac restores the Go menu")
require(app.contains("Button(\"Live TV\")  { MacCommands.go(.live) }.keyboardShortcut(\"3\", modifiers: .command)"),
        "Go menu restores Live TV with Cmd-3")
require(app.contains("Button(\"Search\")   { MacCommands.go(.search) }.keyboardShortcut(\"f\", modifiers: .command)"),
        "Go menu restores Search with Cmd-F")
require(app.contains(".frame(minWidth: 900, minHeight: 600)"), "Mac restores the prior content minimum")

require(!rootView.contains("@Environment(\\.openSettings)"), "root does not use openSettings")
require(!rootView.contains("SettingsLink"), "root has no SettingsLink")
require(!rootView.contains("NavigationSplitView"), "root has no sidebar shell")
require(!rootView.contains("platformShell"), "root has no platform-shell indirection")
require(!rootView.contains("sidebarItem"), "root has no sidebar route helper")

guard let body = section(in: rootView, from: "var body: some View {", to: ".onChange(of: tab)") else {
    fputs("FAIL  locate root body\n", stderr)
    exit(1)
}
require(body.contains("VStack(spacing: 0)"), "root restores the single-window VStack shell")
require(body.contains("case .addons:\n                    AddonsView()"), "Add-ons route renders AddonsView")
require(body.contains("case .settings:\n                    iOSSettingsView()"), "Settings route renders the main-window form")
require(occurrences(of: "iOSSettingsView()", in: rootView) == 1,
        "root owns exactly one Settings form route")
require(rootView.contains("@FocusState private var tabFocus: MacBrowseFocus?"), "glass tabs restore keyboard focus state")
require(rootView.contains("@State private var macQuery = \"\""), "glass shell restores persistent search state")
require(rootView.contains("@FocusState private var macSearchFocused: Bool"), "glass shell restores search focus state")
require(rootView.contains("@State private var macTopChromeHeight: CGFloat = 64"), "glass shell restores measured chrome state")
require(rootView.contains(".safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: macTopChromeHeight) }"),
        "scrolling content reserves measured top chrome")
require(rootView.contains(".overlay(alignment: .top) { macTopNavOverlay }"), "root overlays floating Mac chrome")
require(rootView.contains(".onPreferenceChange(MacTopChromeHeightKey.self) { macTopChromeHeight = $0 }"),
        "root receives measured chrome height")
require(rootView.contains("private var macTopBar: some View"), "glass shell restores top search bar")
require(rootView.contains(".frame(minWidth: 24, minHeight: 24)\n                    .contentShape(Rectangle())\n                    .accessibilityLabel(\"Clear search\")"),
        "Mac clear-search control has a 24-point hit target")
require(rootView.contains("private var macNavPill: some View"), "glass shell restores navigation pill")
require(rootView.contains("private func submitMacSearch()"), "glass shell restores submitted-search routing")
require(rootView.contains("@ViewBuilder private var bottomTabBarRow: some View"), "Mac keeps the iOS bottom-bar split")
require(rootView.contains("private struct MacTopChromeHeightKey: PreferenceKey"), "root restores chrome measurement key")

if failures > 0 {
    fputs("\n\(failures) Mac settings shell contract failure(s)\n", stderr)
    exit(1)
}

print("\nALL PASS")
