import AppKit
import SwiftUI

// Renders the actual fallback offscreen with colored bands at both poster edges.
// Run with swiftc app/SourcesShared/LandscapePosterFallback.swift app/Tests/LandscapePosterFallbackTests.swift.
@main @MainActor
enum LandscapePosterFallbackTests {
    private static let width: CGFloat = 240
    private static let height: CGFloat = 135

    private static func fixture(width: Int, height: Int) -> Image {
        var pixels = Data()
        for y in 0..<height {
            let pixel: [UInt8]
            switch y {
            case ..<(height / 6): pixel = [255, 0, 0, 255]
            case (height * 5 / 6)...: pixel = [0, 0, 255, 255]
            default: pixel = [0, 255, 0, 255]
            }
            for _ in 0..<width { pixels.append(contentsOf: pixel) }
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        let bitmap = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return Image(decorative: bitmap, scale: 1)
    }

    private static func render(_ view: some View, name: String, output: URL?) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).clipped())
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
        precondition(bitmap.pixelsWide == Int(width) && bitmap.pixelsHigh == Int(height),
                     "\(name) keeps the card's 16:9 footprint")
        if let output {
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    private static func pixel(_ bitmap: NSBitmapImageRep, x: Int = 120, y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    private static func isRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.85 && color.greenComponent < 0.28 && color.blueComponent < 0.28
    }

    private static func isBlue(_ color: NSColor) -> Bool {
        color.blueComponent > 0.85 && color.redComponent < 0.28 && color.greenComponent < 0.28
    }

    static func main() throws {
        let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        let portrait = fixture(width: 80, height: 120)

        // The previous fill layer handed an oversized proposal to the sharp image overlay.
        let legacy = portrait.resizable().scaledToFill()
            .blur(radius: 18).opacity(0.55)
            .overlay(Color.black.opacity(0.35))
            .overlay(portrait.resizable().scaledToFit())
        let cropped = try render(legacy, name: "legacy-crop", output: output)
        precondition(!isRed(pixel(cropped, y: 5)) && !isBlue(pixel(cropped, y: 129)),
                     "negative control must reproduce clipped poster edges")

        let fitted = try render(LandscapePosterFallback(image: portrait, background: .black),
                                name: "portrait-fitted", output: output)
        precondition(isRed(pixel(fitted, y: 5)) && isBlue(pixel(fitted, y: 129)),
                     "blurred backdrop keeps both sharp portrait edges visible")
        let side = pixel(fitted, x: 12, y: 67)
        precondition(side.greenComponent > 0.05 && side.greenComponent < 0.8,
                     "the blurred backdrop fills the side outside the sharp poster")

        let plain = try render(LandscapePosterFallback(image: portrait, background: .black, blurRadius: nil),
                               name: "portrait-plain", output: output)
        precondition(isRed(pixel(plain, y: 5)) && isBlue(pixel(plain, y: 129)),
                     "disabling blur keeps both sharp poster edges visible")
        precondition(pixel(plain, x: 12, y: 67).greenComponent < 0.05,
                     "disabling blur leaves the solid card visible beside the poster")

        let inset = try render(LandscapePosterFallback(image: portrait, background: .black, posterInset: 6),
                               name: "portrait-inset", output: output)
        precondition(isRed(pixel(inset, y: 12)) && isBlue(pixel(inset, y: 122)),
                     "the inset preserves both sharp edges")
        precondition(!isRed(pixel(inset, y: 2)) && !isBlue(pixel(inset, y: 132)),
                     "the sharp poster respects the requested vertical inset")

        let wide = fixture(width: 160, height: 90)
        let landscape = try render(LandscapePosterFallback(image: wide, background: .black),
                                   name: "wide-fitted", output: output)
        precondition(isRed(pixel(landscape, x: 8, y: 5)) && isBlue(pixel(landscape, x: 232, y: 129)),
                     "a matching landscape image stays sharp across the full card")
        print("Landscape poster fallback passed 5 renders, including the legacy-crop negative control.")
    }
}
