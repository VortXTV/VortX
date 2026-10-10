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
        root, count_path, ack_dir, gate_dir = sys.argv[1:5]
        os.chdir(root)

        def marker_name(path, suffix):
            return os.path.join(ack_dir, path.lstrip("/").replace("/", "_") + "." + suffix)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, format, *args):
                pass
            def do_GET(self):
                path = self.path.split("?", 1)[0]
                name = path.lstrip("/")
                with open(count_path, "a") as stream:
                    stream.write(path + "\n")
                open(marker_name(path, "started"), "a").close()
                gate_path = os.path.join(gate_dir, name.replace("/", "_"))
                while os.path.exists(gate_path):
                    time.sleep(0.002)
                # A canceled URLSession can close the socket before headers are accepted. A release marker
                # records that the explicit gate opened independently of whether response bytes were accepted.
                open(marker_name(path, "released"), "a").close()
                try:
                    file_path = os.path.join(root, name)
                    if os.path.isfile(file_path):
                        body = open(file_path, "rb").read()
                        self.send_response(200)
                        self.send_header("Content-Type", "image/png")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    else:
                        self.send_response(404)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                except OSError:
                    pass
                finally:
                    open(marker_name(path, "response"), "a").close()

        class ThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
            allow_reuse_address = True
            daemon_threads = True

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            print(server.server_address[1], flush=True)
            server.serve_forever()
        """#

    private let process = Process()
    private let output = Pipe()
    private let directory: URL
    private let countURL: URL
    private let acknowledgementDirectory: URL
    private let gateDirectory: URL
    private var serverURL: URL?

    init(fixtures: [String: Data]) throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("app/build/cinematic-backdrop-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        countURL = base.appendingPathComponent("requests.txt")
        acknowledgementDirectory = base.appendingPathComponent("ack", isDirectory: true)
        gateDirectory = base.appendingPathComponent("gates", isDirectory: true)
        try FileManager.default.createDirectory(at: acknowledgementDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: true)
        for (name, fixture) in fixtures {
            try fixture.write(to: base.appendingPathComponent(name), options: .atomic)
        }
        for name in ["slow-backdrop.png", "slow-stale.png", "slow-title-a-backdrop.png"] {
            FileManager.default.createFile(atPath: gateDirectory.appendingPathComponent(name).path, contents: nil)
        }
    }

    func start() throws -> URL {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-u", "-c", Self.script,
            directory.path, countURL.path, acknowledgementDirectory.path, gateDirectory.path
        ]
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

    func waitForRequest(_ path: String) async -> Bool {
        await waitForMarker(path, suffix: "started")
    }

    func release(_ path: String) {
        try? FileManager.default.removeItem(at: gateDirectory.appendingPathComponent(path))
    }

    func waitForResponse(_ path: String) async -> Bool {
        await waitForMarker(path, suffix: "response")
    }

    func waitForRelease(_ path: String) async -> Bool {
        await waitForMarker(path, suffix: "released")
    }

    private func waitForMarker(_ path: String, suffix: String) async -> Bool {
        let marker = acknowledgementDirectory.appendingPathComponent("\(path).\(suffix)")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    deinit { stop() }
}

private func imageFixture(
    width: Int,
    height: Int,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat
) -> Data {
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
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
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

private func oversizedFixture() -> Data {
    imageFixture(width: 4_096, height: 3_072, red: 0.18, green: 0.34, blue: 0.62)
}

/// A large transparent PNG like the clearlogos used by `ResolvedTitleLogo`. The opaque ellipse keeps the
/// fixture deterministic while the cleared canvas proves the ImageIO thumbnail path retains alpha.
private func transparentOversizedFixture() -> Data {
    guard let context = CGContext(
        data: nil,
        width: 4_096,
        height: 2_048,
        bitsPerComponent: 8,
        bytesPerRow: 4_096 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create transparent oversized fixture image")
    }
    context.clear(CGRect(x: 0, y: 0, width: 4_096, height: 2_048))
    context.setFillColor(CGColor(red: 0.95, green: 0.82, blue: 0.12, alpha: 0.62))
    context.fillEllipse(in: CGRect(x: 512, y: 256, width: 3_072, height: 1_536))
    guard let image = context.makeImage() else {
        fatalError("could not snapshot transparent oversized fixture image")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not create transparent fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not finalize transparent fixture")
    }
    return data as Data
}

private func kenBurnsBackdropFixture() -> Data {
    imageFixture(width: 4_096, height: 2_048, red: 0.75, green: 0.12, blue: 0.10)
}

private func kenBurnsReplacementFixture() -> Data {
    imageFixture(width: 3_000, height: 1_000, red: 0.10, green: 0.58, blue: 0.22)
}

private func kenBurnsPosterFixture() -> Data {
    imageFixture(width: 1_600, height: 900, red: 0.12, green: 0.22, blue: 0.76)
}

private func decodedPixelSize(_ image: VXPosterImage) -> (width: Int, height: Int)? {
    #if canImport(UIKit)
    guard let cg = image.cgImage else { return nil }
    #else
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    #endif
    return (cg.width, cg.height)
}

private func decodedImageHasTransparentPixel(_ image: VXPosterImage) -> Bool {
    #if canImport(UIKit)
    guard let cg = image.cgImage else { return false }
    #else
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    #endif
    let alphaOffset: Int
    switch cg.alphaInfo {
    case .first, .premultipliedFirst: alphaOffset = 0
    case .last, .premultipliedLast: alphaOffset = max(0, cg.bitsPerPixel / 8 - 1)
    default: return false
    }
    guard let provider = cg.dataProvider,
          let providerData = provider.data,
          let bytes = CFDataGetBytePtr(providerData) else { return false }
    let bytesPerPixel = cg.bitsPerPixel / 8
    guard bytesPerPixel > alphaOffset else { return false }
    for (x, y) in [(0, 0), (cg.width - 1, 0), (0, cg.height - 1), (cg.width - 1, cg.height - 1)] {
        let offset = y * cg.bytesPerRow + x * bytesPerPixel + alphaOffset
        if bytes[offset] < 255 { return true }
    }
    return false
}

private func layerImage(_ layer: CALayer) -> CGImage? {
    guard let contents = layer.contents else { return nil }
    let object = contents as AnyObject
    guard CFGetTypeID(object) == CGImage.typeID else { return nil }
    return unsafeBitCast(object, to: CGImage.self)
}

/// Wait for the real production KenBurnsLoader to paint a decoded image onto its CALayer.
@MainActor
private func waitForLayerContents(
    _ layer: CALayer,
    timeout: TimeInterval = 3,
    matching predicate: (CGImage) -> Bool
) async -> CGImage? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let image = layerImage(layer), predicate(image) {
            return image
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    guard let image = layerImage(layer), predicate(image) else { return nil }
    return image
}

/// Exercise the production coordinator rather than copying its backdrop→poster algorithm into the test.
@MainActor
private func loadHeroArt(
    backdrop: URL,
    poster: URL,
    maxPixel: CGFloat,
    expectedSize: (width: Int, height: Int)
) async -> CGImage? {
    let layer = CALayer()
    let loader = KenBurnsLoader()
    loader.load(
        backdrop: backdrop.absoluteString,
        poster: poster.absoluteString,
        maxPixel: Int(maxPixel),
        into: layer
    )
    let image = await waitForLayerContents(layer) {
        $0.width == expectedSize.width && $0.height == expectedSize.height
    }
    loader.cancel()
    return image
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
              featured.contains("self.requestID == requestID")
                  && featured.contains("task?.cancel()"),
              failures: &failures)
        check("featured hero isolates mutable coordinator state on MainActor",
              featured.contains("@MainActor\nfinal class KenBurnsLoader")
                  && featured.contains("task = Task.detached"),
              failures: &failures)
        check("featured hero keeps Reduce Motion and title action surfaces",
              featured.contains("reduceMotion")
                  && featured.contains("actionRow(hero)")
                  && featured.contains("content(hero)"),
              failures: &failures)

        var fixtures: [String: Data] = [
            "oversized.png": oversizedFixture(),
            "transparent-oversized.png": transparentOversizedFixture(),
            "warm-poster.png": oversizedFixture(),
            "slow-backdrop.png": oversizedFixture(),
            "fast-poster.png": oversizedFixture(),
            "slow-stale.png": oversizedFixture(),
            "slow-title-a-backdrop.png": kenBurnsBackdropFixture(),
            "title-b-backdrop.png": kenBurnsReplacementFixture(),
            "title-a-poster.png": kenBurnsPosterFixture(),
            "title-b-poster.png": kenBurnsPosterFixture(),
            "priority-poster.png": kenBurnsPosterFixture(),
        ]
        for index in 0..<5 {
            fixtures["rotation-poster-\(index).png"] = oversizedFixture()
        }
        guard let fixtureServer = try? LocalCinematicFixtureServer(
            fixtures: fixtures
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

        let transparentURL = fixtureServer.url("transparent-oversized.png")
        guard let transparent = await PosterImageLoader.load(transparentURL.absoluteString, maxPixel: 960),
              let transparentSize = decodedPixelSize(transparent) else {
            check("oversized transparent PNG decodes through PosterImageLoader", false, failures: &failures)
            fixtureServer.stop()
            print("\(failures) FAILED")
            exit(1)
        }
        check(
            "transparent logo fixture is downsampled to the 960 px logo budget",
            max(transparentSize.width, transparentSize.height) <= 960,
            failures: &failures
        )
        check(
            "transparent logo fixture retains transparent pixels through bounded decode",
            decodedImageHasTransparentPixel(transparent),
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
        check(
            "slow backdrop request starts before warm fallback observation",
            await fixtureServer.waitForRequest("slow-backdrop.png"),
            failures: &failures
        )
        check(
            "warm poster remains available while a backdrop request is slow",
            PosterImageLoader.cached(warmPosterURL, maxPixel: boundedPixel) != nil,
            failures: &failures
        )
        fixtureServer.release("slow-backdrop.png")
        check(
            "slow backdrop response is explicitly released",
            await fixtureServer.waitForResponse("slow-backdrop.png"),
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
        let fallbackImage = await loadHeroArt(
            backdrop: failedBackdropURL,
            poster: fastPosterURL,
            maxPixel: boundedPixel,
            expectedSize: (1_280, 960)
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
        _ = await loadHeroArt(
            backdrop: failedBackdropURL,
            poster: fastPosterURL,
            maxPixel: boundedPixel,
            expectedSize: (1_280, 960)
        )
        check(
            "warm fallback repeat does not re-request the poster",
            fixtureServer.requestCount(for: "fast-poster.png") == 1,
            failures: &failures
        )

        for index in 0..<5 {
            let rotationBackdropURL = fixtureServer.url("missing-rotation-backdrop-\(index).png")
            let rotationPosterURL = fixtureServer.url("rotation-poster-\(index).png")
            let rotationImage = await loadHeroArt(
                backdrop: rotationBackdropURL,
                poster: rotationPosterURL,
                maxPixel: boundedPixel,
                expectedSize: (1_280, 960)
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

        let priorityImage = await loadHeroArt(
            backdrop: fixtureServer.url("missing-priority-backdrop.png"),
            poster: fixtureServer.url("priority-poster.png"),
            maxPixel: boundedPixel,
            expectedSize: (1_280, 720)
        )
        check(
            "real KenBurnsLoader falls through a failed backdrop to its poster",
            priorityImage.map { max($0.width, $0.height) <= Int(boundedPixel) } ?? false,
            failures: &failures
        )
        check(
            "real KenBurnsLoader requests the failed backdrop once",
            fixtureServer.requestCount(for: "missing-priority-backdrop.png") == 1,
            failures: &failures
        )
        check(
            "real KenBurnsLoader requests the fallback poster once",
            fixtureServer.requestCount(for: "priority-poster.png") == 1,
            failures: &failures
        )

        let rotatingLayer = CALayer()
        let rotatingLoader = KenBurnsLoader()
        rotatingLoader.load(
            backdrop: fixtureServer.url("slow-title-a-backdrop.png").absoluteString,
            poster: fixtureServer.url("title-a-poster.png").absoluteString,
            maxPixel: Int(boundedPixel),
            into: rotatingLayer
        )
        check(
            "old title request starts before rotation",
            await fixtureServer.waitForRequest("slow-title-a-backdrop.png"),
            failures: &failures
        )
        rotatingLoader.load(
            backdrop: fixtureServer.url("title-b-backdrop.png").absoluteString,
            poster: fixtureServer.url("title-b-poster.png").absoluteString,
            maxPixel: Int(boundedPixel),
            into: rotatingLayer
        )
        check(
            "replacement title request starts after rotation",
            await fixtureServer.waitForRequest("title-b-backdrop.png"),
            failures: &failures
        )
        let replacementImage = await waitForLayerContents(rotatingLayer) {
            $0.width == 1_280 && $0.height == 427
        }
        check(
            "real KenBurnsLoader paints the replacement title after rotation",
            replacementImage?.width == 1_280 && replacementImage?.height == 427,
            failures: &failures
        )
        fixtureServer.release("slow-title-a-backdrop.png")
        check(
            "late old-title response release is explicitly acknowledged",
            await fixtureServer.waitForRelease("slow-title-a-backdrop.png"),
            failures: &failures
        )
        let finalImage = layerImage(rotatingLayer)
        check(
            "late old-title completion cannot overwrite the replacement layer",
            finalImage?.width == 1_280 && finalImage?.height == 427,
            failures: &failures
        )
        rotatingLoader.cancel()

        let staleURL = fixtureServer.url("slow-stale.png")
        let staleTask = Task {
            await PosterImageLoader.load(staleURL.absoluteString, maxPixel: boundedPixel)
        }
        check(
            "cancelled old-title request starts before cancellation",
            await fixtureServer.waitForRequest("slow-stale.png"),
            failures: &failures
        )
        staleTask.cancel()
        fixtureServer.release("slow-stale.png")
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
