import AppKit
import SwiftUI

private struct PanelFramesPreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct PanelFrameProbe: View {
    let name: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PanelFramesPreference.self,
                value: [name: proxy.frame(in: .named("panel-fixture"))])
        }
    }
}

@MainActor
private final class PanelFrameReadout: ObservableObject {
    @Published var frames: [String: CGRect] = [:]
}

private struct PanelGeometryFixture: View {
    let width: CGFloat
    let maxContentWidth: CGFloat
    @ObservedObject var readout: PanelFrameReadout

    var body: some View {
        AddonPanelScrollContainer(maxContentWidth: maxContentWidth) {
            Rectangle().fill(Color.red).frame(maxWidth: .infinity, minHeight: 80)
                .background(PanelFrameProbe(name: "content"))
        }
        .background(PanelFrameProbe(name: "viewport"))
        .coordinateSpace(name: "panel-fixture")
        .onPreferenceChange(PanelFramesPreference.self) { readout.frames = $0 }
        .frame(width: width, height: 120)
    }
}

@main @MainActor
enum PanelPresentationTests {
    static var checks = 0
    static var artifactDirectory: URL?

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }

    static func render<V: View>(_ view: V, name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { preconditionFailure("panel component render unavailable") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let artifactDirectory,
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: artifactDirectory.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    static func measureProductionColumn(width: CGFloat, maxContentWidth: CGFloat) -> [String: CGRect] {
        let readout = PanelFrameReadout()
        let host = NSHostingView(rootView: PanelGeometryFixture(
            width: width, maxContentWidth: maxContentWidth, readout: readout))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI publish preferences after AppKit has completed the offscreen layout pass.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        let frames = readout.frames
        if let artifactDirectory {
            let receipt = frames.mapValues { frame in
                ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: artifactDirectory.appendingPathComponent("geometry-\(Int(width)).json"))
            }
        }
        return frames
    }

    static func productionAddonSurface() -> some View {
        Rectangle().fill(Color.clear)
            .frame(width: 240, height: 100)
            .modifier(AddonSurfaceModifier(wide: true))
            .background(Theme.Palette.canvas)
    }

    static func glyphHeight(_ image: NSBitmapImageRep, row: Range<Int>) -> Int {
        var ys: [Int] = []
        for y in row where y >= 0 && y < image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.72 && color.greenComponent > 0.72 && color.blueComponent > 0.72 {
                    ys.append(y)
                    break
                }
            }
        }
        guard let first = ys.first, let last = ys.last else { return 0 }
        return last - first + 1
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 {
            artifactDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        // These measurements lay out AddonPanelScrollContainer extracted verbatim from AddonsView.swift.
        // NSHostingView drives the actual native NSScrollView geometry offscreen; ImageRenderer cannot
        // rasterize that AppKit-backed scroll view and therefore is not used as its geometry oracle.
        for width in [CGFloat(320), 390, 768, 1024, 1440, 2000] {
            let frames = measureProductionColumn(width: width, maxContentWidth: 1120)
            guard let viewport = frames["viewport"], let content = frames["content"] else {
                preconditionFailure("Add-ons native scroll geometry was not published at \(Int(width))")
            }
            let expectedWidth = min(Int(width), 1120)
            expect(abs(viewport.width - width) <= 1,
                   "Add-ons native scroll viewport fills the proposed width \(Int(width))")
            expect(abs(content.width - CGFloat(expectedWidth)) <= 1,
                   "Add-ons content is full-width until the 1120pt cap at \(Int(width))")
            expect(abs(content.minX - (width - CGFloat(expectedWidth)) / 2) <= 1,
                   "Add-ons content column centers inside its actual viewport at \(Int(width))")
            expect(content.height >= 60,
                   "Add-ons content keeps its expected vertical extent at \(Int(width))")
        }
        for width in [CGFloat(320), 390, 768] {
            let frames = measureProductionColumn(width: width, maxContentWidth: .infinity)
            guard let viewport = frames["viewport"], let content = frames["content"] else {
                preconditionFailure("compact Add-ons native scroll geometry was not published at \(Int(width))")
            }
            expect(abs(viewport.width - width) <= 1 && abs(content.minX) <= 1
                && abs(content.width - width) <= 1 && content.height >= 60,
                   "compact Add-ons layout uses the full phone or iPad viewport at \(Int(width))")
        }

        let addonCard = try render(productionAddonSurface(), name: "addons-card-glass")
        expect(addonCard.pixelsWide == 240 && addonCard.pixelsHigh == 100,
               "the real Add-ons card surface keeps its supplied row geometry")
        guard let card = addonCard.colorAt(x: 120, y: 50)?.usingColorSpace(.deviceRGB),
              let canvas = try render(Theme.Palette.canvas.frame(width: 240, height: 100), name: "canvas-reference")
                .colorAt(x: 120, y: 50)?.usingColorSpace(.deviceRGB) else {
            preconditionFailure("Add-ons glass pixels were not available")
        }
        expect(card != canvas, "the real Add-ons surface paints its muted tinted-glass fill over the canvas")

        // Render the production Mac settings typography modifier around both inherited field text and
        // explicit semantic help text. This catches the case where a parent font alone leaves footnotes
        // and captions at the old, tiny Form defaults.
        let settings = try render(
            VStack(alignment: .leading, spacing: 14) {
                Text("Playback setting").foregroundStyle(.white)
                Text("This setting applies to new playbacks.").font(.footnote).foregroundStyle(.white)
            }
            .modifier(MacSettingsTypography())
            .frame(width: 560, height: 100, alignment: .center),
            name: "settings-typography"
        )
        let bodyHeight = glyphHeight(settings, row: 0..<52)
        let helpHeight = glyphHeight(settings, row: 52..<100)
        expect(bodyHeight >= 10 && helpHeight >= 8,
               "Mac Settings body and explicit footnote render above the native tiny-text floor")
        expect(bodyHeight > helpHeight,
               "Mac Settings keeps a visible primary/help hierarchy after raising the semantic floor")

        print("PanelPresentationTests: \(checks) production-component geometry and typography checks passed")
    }
}
