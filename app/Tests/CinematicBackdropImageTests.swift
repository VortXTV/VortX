// Focused executable proof for the iOS/macOS cinematic backdrop loader.
//
//   scripts/test-cinematic-backdrop.sh
//
// The source contracts keep this test independent of the full app dependency graph. The functional part
// compiles the production PosterImageLoader and serves deterministic ImageIO fixtures over a local HTTP
// server, proving bounded decode/cache behavior and cancellation without claiming a device profile result.

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
        import http.server, os, socketserver, sys, time
        os.chdir(sys.argv[1])
        count_path = sys.argv[2]
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, format, *args):
                pass
            def do_GET(self):
                path = self.path.split("?", 1)[0]
                with open(count_path, "a") as stream:
                    stream.write(path + "\n")
                if path.startswith("/slow-"):
                    time.sleep(0.35)
                super().do_GET()
        with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
            print(server.server_address[1], flush=True)
            server.serve_forever()
        """#

    private let process = Process()
    private let output = Pipe()
    private let directory: URL
    private let countURL: URL
    private var serverURL: URL?

    init(fixture: Data, fixtureNames: [String]) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-cinematic-backdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        countURL = base.appendingPathComponent("requests.txt")
        for name in fixtureNames {
            try fixture.write(to: base.appendingPathComponent(name), options: .atomic)
        }
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
        let url = URL(string: "http://127.0.0.1:\(port)")!
        serverURL = url
        return url
    }

    func url(_ path: String) -> URL {
        guard let serverURL else { fatalError("fixture server has not started") }
        return serverURL.appendingPathComponent(path)
    }

    func requestCount(for path: String) -> Int {
        guard let data = try? Data(contentsOf: countURL), !data.isEmpty else { return 0 }
        let expected = "/\(path)"
        return data.split(separator: 10).filter {
            String(decoding: $0, as: UTF8.self) == expected
        }.count
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

/// Mirrors the production KenBurnsLoader order while exercising the real shared loader. A missing/slow
/// backdrop must not prevent a usable poster fallback, and every request remains bounded/cached by production.
private func productionStyleBestArt(
    backdrop: URL,
    poster: URL,
    maxPixel: CGFloat
) async -> VXPosterImage? {
    if let image = await PosterImageLoader.load(backdrop.absoluteString, maxPixel: maxPixel) {
        return image
    }
    return await PosterImageLoader.load(poster.absoluteString, maxPixel: maxPixel)
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

        guard let featured = try? String(
            contentsOfFile: "app/SourcesiOS/FeaturedHeroView.swift",
            encoding: .utf8
        ) else {
            print("FAIL  source gate can read FeaturedHeroView.swift")
            exit(1)
        }
        guard let heroStart = featured.range(of: "private var backdrop: some View {"),
              let heroEnd = featured.range(of: "// MARK: Overlay", range: heroStart.upperBound..<featured.endIndex) else {
            print("FAIL  source gate can isolate the featured hero backdrop")
            exit(1)
        }
        let heroBackdropSource = String(featured[heroStart.lowerBound..<heroEnd.lowerBound])
        let posterPosition = heroBackdropSource.range(of: "posterFallback")?.lowerBound
        let layerPosition = heroBackdropSource.range(of: "KenBurnsLayerHost")?.lowerBound
        check("featured hero has no raw image request in its backdrop path",
              !heroBackdropSource.contains("AsyncImage"), failures: &failures)
        check("featured hero fallback is decoded-cache-only",
              heroBackdropSource.contains("PosterImageLoader.cached(url"), failures: &failures)
        check("featured hero cache fallback has a bounded warm budget",
              featured.contains("posterFallbackMaxPixel = CGFloat(HeroArtworkQualityPolicy.mobileLongEdge)"),
              failures: &failures)
        check("featured hero keeps poster below progressive backdrop priority",
              posterPosition.map { poster in layerPosition.map { poster < $0 } ?? false } ?? false,
              failures: &failures)
        check("featured hero owns one bounded progressive loader",
              featured.contains("private static func bestArt")
                  && featured.contains("await PosterImageLoader.load(backdrop,"),
              failures: &failures)
        check("featured hero rejects an obsolete completion before layer paint",
              featured.contains("self?.requestID == requestID")
                  && featured.contains("task?.cancel()"),
              failures: &failures)
        check("featured hero keeps Reduce Motion and title action surfaces",
              featured.contains("reduceMotion")
                  && featured.contains("actionRow(hero)")
                  && featured.contains("content(hero)"),
              failures: &failures)

        let fixtureNames = [
            "oversized.png",
            "warm-poster.png",
            "slow-backdrop.png",
            "fast-poster.png",
            "slow-stale.png",
        ] + (0..<5).map { "rotation-poster-\($0).png" }
        guard let fixtureServer = try? LocalCinematicFixtureServer(
            fixture: oversizedFixture(),
            fixtureNames: fixtureNames
        ), (try? fixtureServer.start()) != nil else {
            check("local oversized ImageIO fixture server starts", false, failures: &failures)
            print("\(failures) FAILED")
            exit(1)
        }
        let rawURL = fixtureServer.url("oversized.png")
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
        check(
            "decoded cache serves a repeated bounded backdrop request",
            fixtureServer.requestCount(for: "oversized.png") == 1,
            failures: &failures
        )

        let boundedPixel: CGFloat = 1_280
        let warmPosterURL = fixtureServer.url("warm-poster.png")
        let warmPoster = await PosterImageLoader.load(warmPosterURL.absoluteString, maxPixel: boundedPixel)
        check("warm poster decodes through the shared bounded loader", warmPoster != nil, failures: &failures)
        check(
            "cache-only fallback can paint a warm poster before backdrop completion",
            PosterImageLoader.cached(warmPosterURL, maxPixel: boundedPixel) != nil,
            failures: &failures
        )
        let slowBackdropURL = fixtureServer.url("slow-backdrop.png")
        let slowBackdropTask = Task {
            await PosterImageLoader.load(slowBackdropURL.absoluteString, maxPixel: boundedPixel)
        }
        try? await Task.sleep(for: .milliseconds(50))
        check(
            "warm poster remains available while a backdrop request is slow",
            PosterImageLoader.cached(warmPosterURL, maxPixel: boundedPixel) != nil,
            failures: &failures
        )
        check(
            "slow backdrop eventually decodes through the bounded loader",
            await slowBackdropTask.value != nil,
            failures: &failures
        )
        check(
            "cache-only warm fallback adds no duplicate poster request",
            fixtureServer.requestCount(for: "warm-poster.png") == 1,
            failures: &failures
        )

        let failedBackdropURL = fixtureServer.url("missing-backdrop.png")
        let fastPosterURL = fixtureServer.url("fast-poster.png")
        let fallbackImage = await productionStyleBestArt(
            backdrop: failedBackdropURL,
            poster: fastPosterURL,
            maxPixel: boundedPixel
        )
        check("failed backdrop falls through to the fast poster", fallbackImage != nil, failures: &failures)
        check(
            "failed backdrop has one bounded request",
            fixtureServer.requestCount(for: "missing-backdrop.png") == 1,
            failures: &failures
        )
        check(
            "fast poster fallback has one bounded request",
            fixtureServer.requestCount(for: "fast-poster.png") == 1,
            failures: &failures
        )
        _ = await productionStyleBestArt(
            backdrop: failedBackdropURL,
            poster: fastPosterURL,
            maxPixel: boundedPixel
        )
        check(
            "warm fallback repeat does not re-request the poster",
            fixtureServer.requestCount(for: "fast-poster.png") == 1,
            failures: &failures
        )

        for index in 0..<5 {
            let rotationBackdropURL = fixtureServer.url("missing-rotation-backdrop-\(index).png")
            let rotationPosterURL = fixtureServer.url("rotation-poster-\(index).png")
            let rotationImage = await productionStyleBestArt(
                backdrop: rotationBackdropURL,
                poster: rotationPosterURL,
                maxPixel: boundedPixel
            )
            check("rotation \(index + 1) paints its poster fallback", rotationImage != nil, failures: &failures)
            check(
                "rotation \(index + 1) backdrop key is requested once",
                fixtureServer.requestCount(for: "missing-rotation-backdrop-\(index).png") == 1,
                failures: &failures
            )
            check(
                "rotation \(index + 1) poster key is requested once",
                fixtureServer.requestCount(for: "rotation-poster-\(index).png") == 1,
                failures: &failures
            )
        }

        let staleURL = fixtureServer.url("slow-stale.png")
        let staleTask = Task {
            await PosterImageLoader.load(staleURL.absoluteString, maxPixel: boundedPixel)
        }
        try? await Task.sleep(for: .milliseconds(50))
        staleTask.cancel()
        _ = await staleTask.value
        check(
            "cancelled old-title completion does not enter decoded cache",
            PosterImageLoader.cached(staleURL, maxPixel: boundedPixel) == nil,
            failures: &failures
        )
        check(
            "cancelled old-title request was attempted once",
            fixtureServer.requestCount(for: "slow-stale.png") == 1,
            failures: &failures
        )
        fixtureServer.stop()

        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
