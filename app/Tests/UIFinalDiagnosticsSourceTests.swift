import Foundation

// Source-only regression coverage for the eight-file FsEUSd UI owner cut.
// This is not an SDK/typecheck, AppKit notification, navigation, or playback runtime proof.
// Supply the exact candidate checkout as the only argument; no network/app bootstrap is used.
private struct SourceFailure: Error { let message: String }

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SourceFailure(message: message) }
}

private func region(_ text: String, from start: String, to end: String) throws -> String {
    guard let startRange = text.range(of: start),
          let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
        throw SourceFailure(message: "Missing source boundary: " + start + " / " + end)
    }
    return String(text[startRange.lowerBound..<endRange.lowerBound])
}

private func ordered(_ text: String, _ first: String, _ second: String) -> Bool {
    guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
    return a.lowerBound < b.lowerBound
}

private func fullscreenContract(_ source: String) throws {
    let observe = try region(source, from: "    private func observeMacFullScreen() {",
                             to: "    private func unobserveMacFullScreen() {")
    let retire = try region(source, from: "    private func unobserveMacFullScreen() {", to: "    #else")
    try require(observe.contains("guard macFullScreenObservers.isEmpty else { return }"), "Keep duplicate-install guard")
    try require(ordered(observe, "let observationID = UUID()", "let receive: @MainActor @Sendable (Bool) -> Void"), "Capture original observation before its receiver")
    try require(ordered(observe, "guard macFullScreenObservationID == observationID, !playbackExited else { return }",
                        "macIsFullScreen = fullScreen"), "Receiver must check original observation and exited state before UI mutation")
    try require(ordered(observe, "macIsFullScreen = fullScreen",
                        "resyncDynamicRangeForWindowChange()"), "Accepted event updates glyph and EDR in one owner turn")
    let callbacks = try region(observe, from: "        let enter = nc.addObserver", to: "        macFullScreenObservers = [enter, exit]")
    try require(callbacks.components(separatedBy: "guard windowID == nil || eventWindowID == windowID else { return }").count == 3,
                "Both callbacks retain exact original window identity filtering, including nil-window fallback")
    try require(callbacks.contains("DispatchQueue.main.async { receive(true) }") &&
                callbacks.contains("DispatchQueue.main.async { receive(false) }"), "Both native callbacks route immutable values to owner")
    try require(!callbacks.contains("macIsFullScreen =") && !callbacks.contains("coordinator.player") &&
                !callbacks.contains("Task {"), "Native callback cannot perform owned effects or schedule an unguarded second effect")
    try require(ordered(retire, "macFullScreenObservationID = nil", "NotificationCenter.default.removeObserver(token)"),
                "Revoke queued callbacks before observer removal")
    try require(retire.contains("macFullScreenObservers = []"), "Teardown must clear observer handles")
}

private func platformContract(_ source: String) throws {
    try require(source.contains("@MainActor\nfinal class MacPlayerHost: ObservableObject") &&
                source.contains("@MainActor\nfinal class MacProfileCoverHost: ObservableObject"), "Both mutable presentation hosts are actor-owned")
    try require(source.contains("@MainActor\n    final class Coordinator"), "Chrome lifetime and AppKit fields are actor-owned")
    try require(source.contains("DispatchQueue.main.async { [weak view, c] in"), "Explicit original coordinator lifetime in delayed attachment")
    let observer = try region(source, from: "            c.titlebarObserver = NotificationCenter.default.addObserver(",
                              to: "            // DO NOT toggle")
    try require(observer.contains(") { [weak c] _ in") &&
                observer.contains("DispatchQueue.main.async { [weak c] in") &&
                observer.contains("guard let c, !c.cancelled, let host = c.host,"), "Observer carries original weak receiver and checks cancellation after ingress")
    let teardown = try region(source, from: "    static func dismantleNSView(", to: "    func makeCoordinator()")
    try require(ordered(teardown, "coordinator.cancelled = true", "NotificationCenter.default.removeObserver(obs)"), "Revoke chrome observer before removal")
    try require(ordered(teardown, "coordinator.chromeSubscription = nil", "host.titleVisibility = coordinator.savedTitleVisibility"), "Unsubscribe before restoring original chrome")
    try require(teardown.contains("node.view.isHidden = node.wasHidden"), "Restore every saved titlebar node state")
    let follow = try region(source, from: "        func follow(_ window: NSWindow) {", to: "        /// Hide the whole titlebar chain")
    try require(!follow.contains("assumeIsolated") && !follow.contains(".receive(on:"), "No scheduler-based actor assertion or duplicate scheduling")
    try require(follow.contains("DispatchQueue.main.async { [weak self, weak window] in") &&
                follow.contains("guard let self, !self.cancelled, let window, !window.styleMask.contains(.fullScreen)"),
                "Chrome values retain queued delivery and original receiver/window cancellation guard")
    try require(source.components(separatedBy: "guard ownerID == owner else { return }").count == 3,
                "Both hosts preserve stale-bridge owner checks")
}

private func detailContract(_ source: String) throws {
    let destination = try region(source, from: "                .navigationDestination(isPresented: Binding(",
                                 to: "                .onPreferenceChange(EpisodeTopOffsetPreferenceKey.self)")
    try require(source.contains(".overlay(alignment: .top) { pinnedSeasonStrip(proxy: proxy) }\n                #if !os(tvOS)\n                // Shell quick-view"),
                "Destination is registered on the stable scroll container, outside the optional episode branch")
    try require(destination.contains("get: { self.autoPlayEpisode != nil }") &&
                destination.contains("set: { active in if !active { self.autoPlayEpisode = nil; randomPickPlayIntent?.revoke() } }"),
                "Dismissal retains exact binding and original intent revocation")
    for field in [
        "if let autoPlayEpisode, let m = meta", "video: autoPlayEpisode",
        "season: autoPlayEpisode.season ?? season", "seasonEpisodes: sortedEpisodes(m.videos ?? [])",
        "initialStartAtSeconds: autoPlayEpisode.id == validInitialVideoID",
        "? validInitialResumeSeconds", "initialTraktSessionID: initialTraktSessionID",
        "initialContinueWatchingIntent: initialContinueWatchingIntent",
        "initialTraktNextEpisodeOffer: initialTraktNextEpisodeOffer",
        "autoPlayOnAppear: true,\n                            randomPickPlayIntent: randomPickPlayIntent",
        "suppressPreferenceAutoPlay: randomPickPlayIntent != nil"
    ] { try require(destination.contains(field), "Missing original episode handoff field: " + field) }
    try require(!destination.contains("NavigationLink(") && !destination.contains("isActive:"), "Retire deprecated hidden link")
}

@main enum UIFinalDiagnosticsSourceTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SourceFailure(message: "Pass exact candidate checkout root")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let player = try read("app/Sources/PlayerScreen.swift")
        let platform = try read("app/SourcesiOS/PlatformModifiers.swift")
        let detail = try read("app/SourcesiOS/iOSDetailView.swift")
        try fullscreenContract(player)
        try platformContract(platform)
        try detailContract(detail)
        let addon = try read("app/SourcesShared/AddonStoreView.swift")
        try require(addon.contains("nonisolated private static let url = URL(string: \"https://api.strem.io/addonscollection.json\")!") &&
                    addon.contains("nonisolated private static func fetch() async"), "Immutable endpoint remains available to unchanged worker fetch")
        let health = try read("app/SourcesShared/AddonsView.swift")
        for constant in ["okThresholdMs = 1500", "timeout: TimeInterval = 6", "rateLimit: TimeInterval = 20"] {
            try require(health.contains("nonisolated private static let " + constant), "Unchanged immutable health policy: " + constant)
        }
        try require(try read("app/SourcesShared/HomeCollectionGroups.swift").contains("nonisolated private static let maxItemsPerRail = 30"),
                    "Keep thirty-card cap worker-readable")
        let hero = try read("app/SourcesiOS/FeaturedHeroModel.swift")
        for effect in ["advanceIfNotHeld()", "releaseInteractionHold()"] {
            try require(hero.contains("guard !Task.isCancelled else { return }\n" + (effect == "advanceIfNotHeld()" ? "                " : "            ") + "self?." + effect),
                        "Inherited owner task checks cancellation immediately before " + effect)
            try require(!hero.contains("await self?." + effect), "No unnecessary await on inherited owner call")
        }
        let youtube = try read("app/SourcesiOS/YouTubeEmbedView.swift")
        try require(youtube.contains("@MainActor\n    static func make(_ coordinator: YouTubeEmbedCoordinator"), "Real WebKit configuration is constructed on owner")
        try require(youtube.components(separatedBy: "removeScriptMessageHandler(forName: YouTubeEmbedConfig.handlerName)").count == 3,
                    "Both platform dismantles retain handler teardown")

        // In-memory negative cases prove the source guard rejects removal of each key lifetime fence.
        let mutants: [(String, (String) throws -> Void)] = [
            (player.replacingOccurrences(of: "macFullScreenObservationID == observationID, ", with: ""), fullscreenContract),
            (player.replacingOccurrences(of: "        macFullScreenObservationID = nil\n", with: ""), fullscreenContract),
            (platform.replacingOccurrences(of: "guard let c, !c.cancelled, let host = c.host,", with: "guard let c, let host = c.host,"), platformContract),
            (detail.replacingOccurrences(of: "self.autoPlayEpisode = nil; randomPickPlayIntent?.revoke()", with: "self.autoPlayEpisode = nil"), detailContract)
        ]
        for (mutant, check) in mutants {
            var rejected = false
            do { try check(mutant) } catch is SourceFailure { rejected = true }
            try require(rejected, "A missing lifetime/intent fence escaped the regression contract")
        }
        print("PASS source-only UI owner boundaries: eight production sources and four rejected in-memory fence removals; SDK/runtime gates remain separate")
    }
}
