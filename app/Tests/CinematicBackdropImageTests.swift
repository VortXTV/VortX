// Focused executable proof for the iOS/macOS cinematic backdrop loader.
//
//   scripts/test-cinematic-backdrop.sh
//
// The source contracts keep this test independent of the full app dependency graph. The functional part
// compiles the production PosterImageLoader and serves one oversized ImageIO fixture over a local HTTP server,
// proving the 2048 px ceiling and decoded-cache repeat without claiming a device profile result.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

enum VortXEdgeAuth {
    static func sign(_ request: inout URLRequest) {}
}

enum VXProbe {
    static func log(_ channel: String, _ message: String) {}
}

private final class LocalCinematicFixtureServer {
    private static let script = #"""
        import http.server, os, socketserver, sys
        os.chdir(sys.argv[1])
        count_path = sys.argv[2]
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, format, *args):
                pass
            def do_GET(self):
                with open(count_path, "a") as stream:
                    stream.write("1\\n")
                super().do_GET()
        with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
            print(server.server_address[1], flush=True)
            server.serve_forever()
        """#

    private let process = Process()
    private let output = Pipe()
    private let directory: URL
    private let countURL: URL

    init(fixture: Data) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-cinematic-backdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        countURL = base.appendingPathComponent("requests.txt")
        try fixture.write(to: base.appendingPathComponent("oversized.png"), options: .atomic)
    }

    func start() throws -> URL {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, directory.path, countURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        var bytes: [UInt8] = []
        while true {
            let data = output.fileHandleForReading.readData(ofLength: 1)
            guard let byte = data.first else { throw CocoaError(.fileReadUnknown) }
            if byte == 10 { break }
            bytes.append(byte)
        }
        guard let port = Int(String(decoding: bytes, as: UTF8.self)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return URL(string: "http://127.0.0.1:\(port)/oversized.png")!
    }

    var requestCount: Int {
        guard let data = try? Data(contentsOf: countURL), !data.isEmpty else { return 0 }
        return data.split(separator: 10).count
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        stop()
    }
}

private func oversizedFixture() -> Data {
    let width = 4_096
    let height = 3_072
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create oversized fixture image")
    }
    context.setFillColor(CGColor(red: 0.18, green: 0.34, blue: 0.62, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("could not snapshot oversized fixture image")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not create oversized fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not finalize oversized fixture")
    }
    return data as Data
}

private func decodedPixelSize(_ image: VXPosterImage) -> (width: Int, height: Int)? {
    #if canImport(UIKit)
    guard let cg = image.cgImage else { return nil }
    #else
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    #endif
    return (cg.width, cg.height)
}

@MainActor
private func check(_ name: String, _ condition: Bool, failures: inout Int) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
private enum CinematicBackdropImageTests {
    static func main() async {
        var failures = 0
        guard let detail = try? String(
            contentsOfFile: "app/SourcesiOS/iOSDetailView.swift",
            encoding: .utf8
        ) else {
            print("FAIL  source gate can read iOSDetailView.swift")
            exit(1)
        }

        guard let backdrop = detail.range(of: "private func backdrop(height: CGFloat) -> some View {"),
              let trailer = detail.range(of: "/// H3 / #44", range: backdrop.upperBound..<detail.endIndex) else {
            print("FAIL  source gate can isolate the detail backdrop")
            exit(1)
        }
        let backdropSource = String(detail[backdrop.lowerBound..<trailer.lowerBound])
        check("detail backdrop no longer uses unbounded AsyncImage", !backdropSource.contains("AsyncImage"), failures: &failures)
        check("backdrop child uses the decoded-memory cache", backdropSource.contains("PosterImageLoader.cached"), failures: &failures)
        check("backdrop child uses the bounded loader", backdropSource.contains("PosterImageLoader.load(request.url"), failures: &failures)
        check("backdrop task is keyed by URL and pixel budget", backdropSource.contains(".task(id: request)"), failures: &failures)
        check("late completion is rejected for an obsolete request", backdropSource.contains("imageRequest == request"), failures: &failures)
        check("backdrop budget has a 2048 px ceiling", backdropSource.contains("maximumBackdropPixel = 2_048"), failures: &failures)
        check("series poster fallback keeps fit semantics", backdropSource.contains("? .fit : .fill"), failures: &failures)

        guard let fixtureServer = try? LocalCinematicFixtureServer(fixture: oversizedFixture()),
              let rawURL = try? fixtureServer.start() else {
            check("local oversized ImageIO fixture server starts", false, failures: &failures)
            print("\(failures) FAILED")
            exit(1)
        }
        guard let image = await PosterImageLoader.load(rawURL.absoluteString, maxPixel: 2_048),
              let size = decodedPixelSize(image) else {
            check("oversized ImageIO fixture decodes through PosterImageLoader", false, failures: &failures)
            fixtureServer.stop()
            print("\(failures) FAILED")
            exit(1)
        }
        check(
            "oversized fixture is downsampled to the bounded long edge",
            max(size.width, size.height) <= 2_048,
            failures: &failures
        )
        _ = await PosterImageLoader.load(rawURL.absoluteString, maxPixel: 2_048)
        let requests = fixtureServer.requestCount
        check("decoded cache serves a repeated bounded backdrop request", requests == 1, failures: &failures)
        fixtureServer.stop()

        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
