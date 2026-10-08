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
        do {
            guard app.setActivationPolicy(.accessory) else {
                throw RendererError.activationPolicy
            }
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
        var attachedSheet: NSWindow?
        defer {
            if let attachedSheet {
                window.endSheet(attachedSheet)
                attachedSheet.orderOut(nil)
            }
            window.orderOut(nil)
        }
        drainMainRunLoop()
        host.layoutSubtreeIfNeeded()

        let capturedView: NSView
        if surface == .quickView {
            guard let sheet = window.attachedSheet, let sheetContent = sheet.contentView else {
                throw RendererError.missingQuickViewSheet
            }
            attachedSheet = sheet
            sheetContent.layoutSubtreeIfNeeded()
            // `cacheDisplay` captures the AppKit view tree, not the WindowServer compositor. Keep a
            // renderer-only receipt of both layout and accessibility before interpreting a dark sheet
            // bitmap as a production presentation defect.
            logQuickViewDiagnostics(parent: window, sheet: sheet, content: sheetContent)
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

    private static func logQuickViewDiagnostics(parent: NSWindow, sheet: NSWindow, content: NSView) {
        print("quick-view bounds parent=\(parent.contentView?.bounds.debugDescription ?? "nil") sheet=\(sheet.frame.debugDescription) content=\(content.bounds.debugDescription)")
        logViewTree(content)
        let accessibility = collectAccessibility(from: content)
        print("quick-view accessibility labels=\(accessibility.joined(separator: " | "))")
    }

    private static func logViewTree(_ view: NSView, depth: Int = 0) {
        let indent = String(repeating: "  ", count: depth)
        print("quick-view view \(indent)\(String(describing: type(of: view))) frame=\(view.frame.debugDescription) hidden=\(view.isHidden)")
        for child in view.subviews {
            logViewTree(child, depth: depth + 1)
        }
    }

    private static func collectAccessibility(from view: NSView) -> [String] {
        var labels: [String] = []
        if let label = view.accessibilityLabel(), !label.isEmpty {
            labels.append(label)
        }
        for child in view.subviews {
            labels.append(contentsOf: collectAccessibility(from: child))
        }
        return labels
    }

    private enum RendererError: LocalizedError {
        case missingOutputDirectory, bitmapAllocation, pngEncoding, missingQuickViewSheet, activationPolicy
        var errorDescription: String? {
            switch self {
            case .missingOutputDirectory: return "CINEMA_UI_SMOKE_OUTPUT must be an absolute directory"
            case .bitmapAllocation: return "could not allocate an offscreen bitmap"
            case .pngEncoding: return "could not encode PNG output"
            case .missingQuickViewSheet: return "production CinemaQuickView sheet was not attached"
            case .activationPolicy: return "could not enter isolated accessory application policy"
            }
        }
    }
}
#endif
