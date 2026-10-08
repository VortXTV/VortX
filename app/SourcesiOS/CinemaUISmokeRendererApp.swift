#if CINEMA_UI_SMOKE_RENDERER && os(macOS)
import AppKit
import SwiftUI

/// Test-only macOS executable entry point. It hosts the actual `CinemaUISmokeFixtureRoot` hierarchy in
/// AppKit, writes deterministic PNGs, then exits. The renderer never builds `iOSRootView`, CoreBridge,
/// an account, a player, or an embedded server; its separate bundle identifier gives `UserDefaults.standard`
/// an isolated domain as well.
@main
@MainActor
enum CinemaUISmokeRendererApp {
    private static let viewports: [(name: String, width: CGFloat, height: CGFloat)] = [
        ("phone", 390, 844),
        ("tablet", 834, 1112),
        ("mac", 1280, 800),
    ]

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            let output = try outputDirectory()
            for surface in CinemaUISmokeSurface.allCases {
                for viewport in viewports {
                    try render(viewport, surface: surface, into: output)
                }
            }
        } catch {
            fputs("Cinema UI renderer failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func outputDirectory() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["CINEMA_UI_SMOKE_OUTPUT"],
              raw.hasPrefix("/") else {
            throw RendererError.missingOutputDirectory
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func render(
        _ viewport: (name: String, width: CGFloat, height: CGFloat),
        surface: CinemaUISmokeSurface,
        into output: URL
    ) throws {
        let size = NSSize(width: viewport.width, height: viewport.height)
        let root = CinemaUISmokeFixtureRoot(name: viewport.name.capitalized,
                                            width: viewport.width, height: viewport.height,
                                            surface: surface)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        drainMainRunLoop()
        host.layoutSubtreeIfNeeded()

        let capturedView: NSView
        if surface == .quickView {
            guard let sheet = window.attachedSheet, let sheetContent = sheet.contentView else {
                throw RendererError.missingQuickViewSheet
            }
            sheetContent.layoutSubtreeIfNeeded()
            capturedView = sheetContent
        } else {
            capturedView = host
        }

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(capturedView.bounds.width), pixelsHigh: Int(capturedView.bounds.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RendererError.bitmapAllocation
        }
        capturedView.cacheDisplay(in: capturedView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.pngEncoding
        }
        let file = output.appendingPathComponent("cinema-\(surface.artifactPrefix)\(viewport.name).png")
        try png.write(to: file, options: .atomic)
        print("rendered \(file.path) \(surface.title) \(Int(size.width))x\(Int(size.height))")
    }

    private static func drainMainRunLoop() {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private enum RendererError: LocalizedError {
        case missingOutputDirectory, bitmapAllocation, pngEncoding, missingQuickViewSheet
        var errorDescription: String? {
            switch self {
            case .missingOutputDirectory: return "CINEMA_UI_SMOKE_OUTPUT must be an absolute directory"
            case .bitmapAllocation: return "could not allocate an offscreen bitmap"
            case .pngEncoding: return "could not encode PNG output"
            case .missingQuickViewSheet: return "production CinemaQuickView sheet was not attached"
            }
        }
    }
}
#endif
