// Synthetic behavioral checks. Compile against the actual integrated
// common model, presentation policy and guarded artwork client in root's allocated serial lane.
import Foundation
import CoreGraphics
import ImageIO

enum CurationPresentationBehaviorTests {
    static func run() throws {
        func folder(_ id: String) -> CurationFolder { .init(id: id, name: id, sources: []) }
        func collection(_ id: String, pinned: Bool = false) -> CurationCollection {
            .init(id: id, name: id, home: true, pinned: pinned, folders: [folder("a"), folder("b")],
                  presentation: .init(layout: .tabs, tileShape: .square), artwork: .init())
        }
        let first = collection("first"), second = collection("second", pinned: true)
        let third = collection("third"), fourth = collection("fourth", pinned: true)
        precondition(CurationPresentationPolicy.ordered([first, second, third, fourth]).map(\.id)
                     == ["second", "fourth", "first", "third"], "Pins partition without changing focus order inside either group")
        precondition(CurationPresentationPolicy.visibleFolders(first, selectedID: nil).map(\.id) == ["a", "b"],
                     "All traverses each original folder exactly once in its saved order")
        precondition(CurationPresentationPolicy.visibleFolders(first, selectedID: "b").map(\.id) == ["b"],
                     "A selected tab never requests an unrelated folder")
        precondition(CurationPresentationPolicy.visibleFolders(first, selectedID: "removed").map(\.id) == ["a"],
                     "A removed selection has a stable first-folder fallback")
        var noAll = first
        noAll.presentation.showAll = false
        precondition(CurationPresentationPolicy.visibleFolders(noAll, selectedID: nil).map(\.id) == ["a"],
                     "Hiding All does not expose all folders via a nil selection")
        precondition(CurationPresentationPolicy.resolvedLayout(.followLayout, following: .rows) == .rows,
                     "Follow Layout uses the containing surface layout")
        precondition(CurationPresentationPolicy.resolvedLayout(.followLayout, following: .followLayout) == .grid,
                     "An unspecified inherited layout terminates at a deterministic grid")
        precondition(CurationPresentationPolicy.resolvedLayout(.tabs, following: .rows) == .tabs,
                     "An explicit collection layout wins over surface layout")
        precondition(CurationPresentationPolicy.aspectRatio(.poster) == CGFloat(2.0 / 3.0))
        precondition(CurationPresentationPolicy.aspectRatio(.square) == 1)
        precondition(CurationPresentationPolicy.aspectRatio(.landscape) == CGFloat(16.0 / 9.0))

        let png = try squarePNG(dimension: 1_024)
        let small = try XperienceArtworkClient.decode(png, thumbnailDimension: 128)
        precondition(small.width <= 128 && small.height <= 128, "A tile requests a small actual ImageIO decode")
        let floor = try XperienceArtworkClient.decode(png, thumbnailDimension: Int.min)
        precondition(floor.width <= 64 && floor.height <= 64, "A negative request cannot bypass the floor")
        let ceiling = try XperienceArtworkClient.decode(png, thumbnailDimension: Int.max)
        precondition(ceiling.width <= XperienceArtworkClient.maximumThumbnailDimension
                     && ceiling.height <= XperienceArtworkClient.maximumThumbnailDimension,
                     "A large requested dimension cannot raise the guarded decoder's maximum")
        do {
            _ = try XperienceArtworkClient.decode(Data("<svg/>".utf8), thumbnailDimension: 128)
            preconditionFailure("Unsupported media must not fall back to a platform decoder")
        } catch XperienceArtworkClient.Failure.unsupportedImage {}
    }

    private static func squarePNG(dimension: Int) throws -> Data {
        enum Failure: Error { case fixture }
        guard let context = CGContext(data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { throw Failure.fixture }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure.fixture }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.fixture }
        return data as Data
    }
}
