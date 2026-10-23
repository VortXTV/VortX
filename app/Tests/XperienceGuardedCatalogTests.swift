import Foundation
import CoreGraphics
import ImageIO

// Production-component checks. Compile with the actual parser, binder,
// AddonURLGuard, CoreModels, the actual lexical admission helper and their production dependencies.
// No response model or duplicate-member scanner is replaced by a stub.
@main
@MainActor
enum XperienceGuardedCatalogTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name)
        checks += 1
    }

    private static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(name) }
        catch XperienceCatalogClient.Failure.invalidResponse { checks += 1 }
        catch { preconditionFailure("Unexpected failure in " + name) }
    }

    private static func imageRejected(_ name: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(name) }
        catch XperienceArtworkClient.Failure.unsupportedImage { checks += 1 }
        catch { preconditionFailure("Unexpected failure in " + name) }
    }

    private static func png() throws -> Data {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return result as Data
    }

    static func main() async throws {
        let data = Data(#"{"metas":[{"id":"tt0000001","type":"movie","name":"Catalog title","poster":"https://images.example/poster.png","posterShape":"poster","background":"https://images.example/background.png","logo":"https://images.example/logo.png","description":"Description","releaseInfo":"2026","imdbRating":"8.1","genres":["Drama","None"]}]}"#.utf8)
        let items = try XperienceCatalogClient.decode(data)
        expect(items.count == 1 && items[0].id == "tt0000001" && items[0].type == "movie", "real CoreMeta identity decodes")
        expect(items[0].name == "Catalog title" && items[0].releaseInfo == "2026", "real CoreMeta presentation decodes")
        expect(items[0].poster == "https://images.example/poster.png", "art URL remains data for guarded art only")
        expect(items[0].imdbRating == "8.1" && items[0].genres == ["Drama", "None"], "raw Stremio fields project into CoreMeta links")
        let linked = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"id","type":"series","name":"Linked title","imdbRating":"1.0","genres":["Drama","Comedy","Comedy"],"links":[{"category":"imdb","name":"9.2"},{"category":"Genres","name":"Drama"}]}]}"#.utf8))[0]
        expect(linked.imdbRating == "9.2" && linked.genres == ["Drama", "Comedy"], "provider links survive without repeated projected genres")
        let empty = try XperienceCatalogClient.decode(Data(#"{"metas":[]}"#.utf8))
        expect(empty.isEmpty, "empty ready catalog remains empty")
        rejects("HTML is never catalog JSON") { _ = try XperienceCatalogClient.decode(Data("<html></html>".utf8)) }
        rejects("missing metas fails") { _ = try XperienceCatalogClient.decode(Data(#"{"meta":[]}"#.utf8)) }
        rejects("duplicate envelope members fail from original bytes") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[],"metas":[{"id":"id","type":"movie","name":"Title"}]}"#.utf8))
        }
        rejects("duplicate item id members fail before DTO decoding") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"first","id":"second","type":"movie","name":"Title"}]}"#.utf8))
        }
        rejects("duplicate item type members fail before DTO decoding") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"id","type":"movie","type":"series","name":"Title"}]}"#.utf8))
        }
        rejects("duplicate item poster members fail before DTO decoding") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"id","type":"movie","name":"Title","poster":"https://images.example/first.png","poster":"https://images.example/second.png"}]}"#.utf8))
        }
        rejects("escaped envelope member collision fails") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[],"\u006detas":[]}"#.utf8))
        }
        rejects("escaped unknown members are inspected too") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[],"future":{"key":1,"\u006bey":2}}"#.utf8))
        }
        rejects("escaped unknown item members are inspected too") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"id","type":"movie","name":"Title","future":{"key":1,"\u006bey":2}}]}"#.utf8))
        }
        let escapedUnknown = try XperienceCatalogClient.decode(Data(#"{"metas":[],"future":{"\u006bey":1,"other":[true,null,"complete"]}}"#.utf8))
        expect(escapedUnknown.isEmpty, "valid escaped unknown members retain normal value decoding")
        rejects("complete value decoding still rejects malformed ignored fields") {
            _ = try XperienceCatalogClient.decode(Data(#"{"metas":[],"future":tru}"#.utf8))
        }
        rejects("malformed item fails the response") { _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"id","type":"movie"}]}"#.utf8)) }
        rejects("duplicate identities fail the response") { _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":"id","type":"movie","name":"One"},{"id":"id","type":"movie","name":"Two"}]}"#.utf8)) }
        rejects("empty identities fail") { _ = try XperienceCatalogClient.decode(Data(#"{"metas":[{"id":" ","type":"movie","name":"One"}]}"#.utf8)) }
        let oversized = Data(repeating: 32, count: AddonURLGuard.ResponseContext.xperienceCatalog.maximumBytes + 1)
        rejects("catalog byte cap is checked before JSON decode") { _ = try XperienceCatalogClient.decode(oversized) }
        let exactLimit = (0..<XperienceCatalogClient.maximumItems).map {
            "{\"id\":\"unique-\($0)\",\"type\":\"movie\",\"name\":\"Title \($0)\"}"
        }.joined(separator: ",")
        let exactItems = try XperienceCatalogClient.decode(Data(("{\"metas\":[" + exactLimit + "]}").utf8))
        expect(exactItems.count == 2_000 && Set(exactItems.map(\.id)).count == 2_000,
               "exactly 2000 distinct valid items are admitted")
        let tooMany = (0...XperienceCatalogClient.maximumItems).map {
            "{\"id\":\"unique-\($0)\",\"type\":\"movie\",\"name\":\"Title \($0)\"}"
        }.joined(separator: ",")
        rejects("item count cap is terminal") { _ = try XperienceCatalogClient.decode(Data(("{\"metas\":[" + tooMany + "]}").utf8)) }

        let source = XperienceCollections.Source(raw: .object([:]), provider: "addon", addonID: "example.catalogs",
                                                type: "movie", catalogID: "genre.example", genre: "None")
        let candidate = try XperienceAddonBinding.Candidate(manifestID: "example.catalogs",
            transport: "https://addon.example/first/manifest.json?tenant=one&mode=full",
            catalogs: [.init(type: "movie", id: "genre.example", acceptsGenre: true, requiresGenre: false, supportsSkip: true)])
        let request = try XperienceAddonBinding.catalogURL(source: source, candidate: candidate, skip: 20)
        let components = URLComponents(url: request, resolvingAgainstBaseURL: false)!
        expect(components.percentEncodedPath == "/first/catalog/movie/genre.example/genre=None&skip=20.json", "exact source extras and genre None survive")
        expect(components.percentEncodedQuery == "tenant=one&mode=full", "configured query survives")
        let contexts: [AddonURLGuard.ResponseContext] = [.manifest, .xperienceCatalog, .xperienceArtwork]
        for context in contexts {
            let limit = context.maximumBytes
            expect(AddonURLGuard.canAcceptBody(currentBytes: limit - 1, incomingBytes: 1, context: context), "last byte accepted")
            expect(!AddonURLGuard.canAcceptBody(currentBytes: limit, incomingBytes: 1, context: context), "overflowing byte refused")
            expect(!AddonURLGuard.canAcceptBody(currentBytes: 0, incomingBytes: Int.max, context: context), "integer overflow refused")
            expect(!AddonURLGuard.canAcceptBody(currentBytes: -1, incomingBytes: 1, context: context), "negative size refused")
        }
        let redirected = AddonURLGuard.redirectTarget(from: URL(string: "https://addon.example/image.png")!,
                                                      location: "http://127.0.0.1/private.png")!
        let rejection = await AddonURLGuard.validate(redirected)
        if case .privateAddress? = rejection { checks += 1 } else { preconditionFailure("private redirect target must fail before transport") }

        let image = try XperienceArtworkClient.decode(png())
        expect(image.width == 2 && image.height == 1, "bounded static PNG decodes")
        imageRejected("SVG has no decoder path") { _ = try XperienceArtworkClient.decode(Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)) }
        imageRejected("GIF is retained as metadata only") { _ = try XperienceArtworkClient.decode(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!) }
        imageRejected("art byte cap is checked before decode") { _ = try XperienceArtworkClient.decode(Data(repeating: 0, count: AddonURLGuard.ResponseContext.xperienceArtwork.maximumBytes + 1)) }
        expect(XperienceArtworkClient.sourceDimensionsAreAllowed(width: 8192, height: 2048), "source pixel edge accepted")
        expect(!XperienceArtworkClient.sourceDimensionsAreAllowed(width: 8192, height: 2049), "source pixel overflow refused")
        expect(!XperienceArtworkClient.sourceDimensionsAreAllowed(width: Int.max, height: 1), "source dimension overflow refused")
        expect(!XperienceArtworkClient.sourceDimensionsAreAllowed(width: 1, height: 0), "zero image dimension refused")
        expect(XperienceArtworkClient.decodedDimensionsAreAllowed(width: 2048, height: 2048, bytesPerRow: 8192), "decoded 4M pixel edge accepted")
        expect(!XperienceArtworkClient.decodedDimensionsAreAllowed(width: 2048, height: 2048, bytesPerRow: Int.max), "decoded byte overflow refused")

        // Last: cancellation is set before any service call, so these paths cannot issue network I/O.
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try await XperienceCatalogClient.load(source: source, candidate: candidate); preconditionFailure("catalog cancellation must propagate") }
        catch is CancellationError { checks += 1 }
        do { _ = try await XperienceArtworkClient.load("https://images.example/poster.png"); preconditionFailure("art cancellation must propagate") }
        catch is CancellationError { checks += 1 }
        print("Xperience guarded catalog component checks passed: \(checks)")
    }
}
