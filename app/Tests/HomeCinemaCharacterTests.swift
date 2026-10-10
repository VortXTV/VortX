import AppKit
import SwiftUI

// Inert glue for exact source-extracted task, callbacks and canvas. No application startup.
enum Theme {
    enum Palette {
        static let canvas = Color.black
        static let accent = Color(red: 0.85, green: 0.47, blue: 0.03)
    }
}
enum FeaturedHeroModel { static let heroCrossfade = 0.32 }
enum PosterImageLoader {
    static let source = TintSampleFixtureSource()
    static func averageColor(_ artwork: String?) async -> Color? { await source.sample(artwork) }
}
actor TintSampleFixtureSource {
    private var pending: [String: CheckedContinuation<Color?, Never>] = [:]
    private var awaitingStart: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var requestCount = 0
    func sample(_ artwork: String?) async -> Color? {
        guard let artwork else { return nil }
        requestCount += 1
        return await withCheckedContinuation { continuation in
            pending[artwork] = continuation
            awaitingStart.removeValue(forKey: artwork)?.resume()
        }
    }
    func waitForRequest(_ artwork: String) async {
        if pending[artwork] != nil { return }
        await withCheckedContinuation { awaitingStart[artwork] = $0 }
    }
    func finish(_ artwork: String, tint: Color?) { pending.removeValue(forKey: artwork)?.resume(returning: tint) }
}

@main @MainActor
enum HomeCinemaCharacterTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }
    static func source(_ path: String, root: String) throws -> String {
        try String(contentsOfFile: root + "/" + path, encoding: .utf8)
    }
    static func render(_ tint: Color, reduced: Bool, contrast: Bool, name: String,
                       directory: String) throws -> NSBitmapImageRep {
        let component = HomeCinemaAtmosphere(tint: tint, reduceTransparency: reduced, highContrast: contrast, reach: 680)
            .frame(width: 390, height: 844)
        let renderer = ImageRenderer(content: component)
        renderer.scale = 1
        guard let image = renderer.cgImage else { preconditionFailure("actual Home canvas render unavailable") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("PNG render unavailable") }
        try png.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        return bitmap
    }
    static func main() async throws {
        let root = CommandLine.arguments[1]
        let directory = CommandLine.arguments[2]
        let hero = ProductionHeroTintHost()
        let home = ProductionHomeTintHost()
        var callbacks = 0
        hero.onTintChange = { snapshot in
            MainActor.assertIsolated()
            callbacks += 1
            home.acceptHomeHeroTint(snapshot)
        }
        let a = FeaturedHeroTintKey(id: "A", type: "movie", artwork: "art-A")
        let b = FeaturedHeroTintKey(id: "B", type: "series", artwork: "art-B")
        hero.heroTintKey = a; home.homeHeroTintKey = a
        let taskA = Task { await hero.sampleCurrentHero() }
        await PosterImageLoader.source.waitForRequest("art-A")
        expect(home.homeHeroTint?.value(for: a) == nil, "cold title starts with nil tint/profile-accent fallback")
        hero.heroTintKey = b; home.homeHeroTintKey = b
        expect(home.homeHeroTint?.value(for: b) == nil, "keyed body read hides the previous title before a new task starts")
        let taskB = Task { await hero.sampleCurrentHero() }
        await PosterImageLoader.source.waitForRequest("art-B")
        await PosterImageLoader.source.finish("art-B", tint: .blue)
        await taskB.value
        expect(home.homeHeroTint?.value(for: b) == .blue, "current title publishes its cached tint on MainActor")
        let acceptedCallbacks = callbacks
        await PosterImageLoader.source.finish("art-A", tint: .red)
        await taskA.value
        expect(home.homeHeroTint?.value(for: b) == .blue && hero.heroTint?.value(for: b) == .blue,
               "late old-title result cannot overwrite either hero or Home tint")
        expect(callbacks == acceptedCallbacks, "stale completion does not call the Home callback")
        home.acceptHomeHeroTint(.init(key: a, tint: .red))
        expect(home.homeHeroTint?.value(for: b) == .blue, "Home independently rejects a stale callback")
        let newerArtwork = FeaturedHeroTintKey(id: b.id, type: b.type, artwork: "art-B-new")
        expect(home.homeHeroTint?.value(for: newerArtwork) == nil,
               "same title with replacement artwork cannot inherit the retired artwork's tint")
        let newType = FeaturedHeroTintKey(id: b.id, type: "movie", artwork: b.artwork)
        expect(home.homeHeroTint?.value(for: newType) == nil,
               "same id/artwork in another media type cannot inherit the old title's tint")
        expect(FeaturedHeroTintSnapshot<Color>.accepting(.red, for: a, current: a, isCancelled: true) == nil,
               "cancelled same-key completion remains rejected after an A-to-B-to-A rotation")
        home.homeHeroTintKey = a
        expect(home.homeHeroTint?.value(for: a) == nil, "ABA rotation cannot revive a retired B snapshot")
        home.homeHeroTintKey = b
        for _ in 0..<1000 { _ = home.homeHeroTint?.value(for: b) }
        let requestCount = await PosterImageLoader.source.requestCount
        expect(requestCount == 2, "1000 canvas reads add no image sampling requests")
        let c = FeaturedHeroTintKey(id: "C", type: "movie", artwork: "art-C")
        hero.heroTintKey = c; home.homeHeroTintKey = c
        let taskC = Task { await hero.sampleCurrentHero() }
        await PosterImageLoader.source.waitForRequest("art-C")
        taskC.cancel()
        let beforeCancelledResult = callbacks
        await PosterImageLoader.source.finish("art-C", tint: .orange)
        await taskC.value
        expect(home.homeHeroTint?.value(for: c) == nil && callbacks == beforeCancelledResult,
               "cancelled current-title sample cannot publish a late result")
        let noArt = FeaturedHeroTintKey(id: "D", type: "movie", artwork: nil)
        hero.heroTintKey = noArt; home.homeHeroTintKey = noArt
        await hero.sampleCurrentHero()
        expect(home.homeHeroTint?.value(for: noArt) == nil, "missing artwork retains the profile-accent fallback")

        expect(HomeAtmospherePolicy.alpha(reduceTransparency: false, highContrast: false) == 0.05,
               "normal atmosphere remains a five-percent static wash")
        expect(HomeAtmospherePolicy.alpha(reduceTransparency: true, highContrast: false) == 0.02,
               "Reduce Transparency limits atmosphere to two percent")
        expect(HomeAtmospherePolicy.alpha(reduceTransparency: false, highContrast: true) == 0
            && HomeAtmospherePolicy.alpha(reduceTransparency: true, highContrast: true) == 0,
               "increased contrast always keeps the plain opaque canvas")

        let normal = try render(.red, reduced: false, contrast: false, name: "home-canvas-red", directory: directory)
        let reduced = try render(.red, reduced: true, contrast: false, name: "home-canvas-reduced", directory: directory)
        let contrast = try render(.red, reduced: false, contrast: true, name: "home-canvas-contrast", directory: directory)
        let profileFallback = try render(Theme.Palette.accent, reduced: false, contrast: false,
                                        name: "home-canvas-profile-fallback", directory: directory)
        let normalTop = normal.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
        let reducedTop = reduced.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
        let plainTop = contrast.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
        expect(normalTop.redComponent > reducedTop.redComponent && reducedTop.redComponent > 0,
               "actual component pixels show restrained and reduced artwork atmosphere")
        expect(plainTop.redComponent == 0 && plainTop.greenComponent == 0 && plainTop.blueComponent == 0,
               "actual increased-contrast component pixels are pure OLED black")
        expect(normal.colorAt(x: 20, y: 800)!.usingColorSpace(.deviceRGB)!.redComponent == 0,
               "actual canvas leaves lower rails OLED black rather than a full-page color wash")
        expect(normal.colorAt(x: 20, y: 560)!.usingColorSpace(.deviceRGB)!.redComponent > 0,
               "actual canvas carries faint hero colour through the first-rail transition")
        expect(profileFallback.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!.redComponent > 0,
               "actual cold-art fallback is a quiet profile-accent wash")

        let heroSource = try source("app/SourcesiOS/FeaturedHeroView.swift", root: root)
        let rootSource = try source("app/SourcesiOS/iOSRootView.swift", root: root)
        let themeSource = try source("app/SourcesShared/Theme.swift", root: root)
        let card = rootSource.components(separatedBy: "private struct CinemaPosterCardBody: View {")[1]
            .components(separatedBy: "/// Live card wrapper.")[0]
        expect(heroSource.components(separatedBy: "PosterImageLoader.averageColor(").count == 2,
               "hero keeps exactly its existing one average-color request site")
        expect(heroSource.contains(".task(id: heroTintKey)") && heroSource.contains("await MainActor.run { publishHeroTint"),
               "source task is keyed by exact title/artwork and publishes through MainActor")
        expect(rootSource.components(separatedBy: "onTintChange: acceptHomeHeroTint").count == 3,
               "only phone and wider Home heroes opt into canvas tint publication")
        expect(!EnvironmentValues().cinemaCardHasExternalLift,
               "plain detail/person consumers retain their original card lift by default")
        expect(card.contains(".black.opacity(hasExternalLift ? 0 : 0.28)")
            && card.contains("radius: hasExternalLift ? 0 : 10, y: hasExternalLift ? 0 : 5"),
               "actual card gates its inner lift only when its Button owns the resting shadow")
        expect(rootSource.components(separatedBy: ".environment(\\.cinemaCardHasExternalLift, true)").count == 3
            && rootSource.components(separatedBy: ".buttonStyle(CardFocusStyle(scale: 1.04))").count == 3,
               "both styled grid/rail owners opt out once while plain consumers remain unchanged")
        expect(themeSource.contains(".black.opacity(active ? 0.45 : 0.32)")
            && themeSource.contains("radius: active ? 16 : 12, x: 0, y: active ? 10 : 7"),
               "the existing single-owner resting/focus lift remains unchanged")
        expect(card.contains(".opacity(isWatched ? 0.55 : 1)") && card.contains("resumeTimecode(resumeSeconds)")
            && card.contains("PosterContextMenu") && card.contains("presentation.width"),
               "watched, resume, context-menu and user size features remain in the actual card")
        print("HomeCinemaCharacterTests: \(checks) checks passed; actual tint task/callback and inert canvas pixels")
    }
}
