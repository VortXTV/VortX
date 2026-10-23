import TVServices
import os

/// The `VortXTopShelf` extension's principal class: renders VortX's Continue Watching onto the tvOS
/// Home screen's Top Shelf when VortX is the focused app.
///
/// This runs in its OWN process, on the system's schedule, usually while VortX itself is not running.
/// It therefore does exactly one thing: read the JSON snapshot the app left in the shared App Group
/// container (`TopShelfSnapshot`) and turn it into `TVTopShelfSectionedContent`. It boots no engine,
/// opens no socket, and reads no `UserDefaults.standard` (all of which belong to the app's container,
/// not ours). The system falls back to the static Top Shelf image if we are slow or return nothing.
/// Snapshot I/O and JSON decoding are synchronous; this path can still block and must finish promptly.
///
/// This target compiles exactly two files: this one and `SourcesShared/TopShelfSnapshot.swift`.
final class ContentProvider: TVTopShelfContentProvider {
    private static let log = Logger(subsystem: "com.stremiox.app", category: "topshelf-provider")

    /// Implement the SDK's original completion-handler entry point.
    ///
    /// The content protocol is not Sendable, so do not return it across an async isolation boundary.
    /// Build the content and invoke the supplied callback in this call, without a task or queue hop.
    /// The SDK permits the callback on any queue and requires it promptly; we neither store nor
    /// capture it. The completion-handler form does not make the snapshot read or decoding nonblocking.
    /// Both normal paths invoke the callback exactly once.
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        let result = TopShelfSnapshot.readResult()
        let items = result.items
        let output = items.isEmpty ? "static" : "dynamic"
        // One bounded line per invocation; only closed enums and an already-bounded row count.
        // Unified-log evidence is separate from the host app's exported diagnostic file.
        Self.log.info("read=\(result.status.rawValue, privacy: .public) rows=\(items.count, privacy: .public) output=\(output, privacy: .public)")

        // No snapshot, no App Group container (an unsigned / sideloaded build whose profile carries no
        // group), or the user turned the row off: deliver nil, which is the system's documented cue to
        // show the app's static Top Shelf image. This is the degrade path, and it must never be a
        // crash or an empty row.
        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }

        let shelfItems = items.map(sectionedItem)
        let collection = TVTopShelfItemCollection(items: shelfItems)
        // Names the row on the Home screen, above the posters.
        collection.title = String(localized: "Continue Watching")
        completionHandler(TVTopShelfSectionedContent(sections: [collection]))
    }

    /// One Continue Watching entry as a Top Shelf tile.
    private func sectionedItem(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        // Home's identity is (type, provider id), not provider id alone. In particular a movie
        // and series from different catalogs may share an id without sharing a shelf identifier.
        let shelf = TVTopShelfSectionedItem(identifier: item.shelfIdentifier)
        shelf.title = item.title
        shelf.imageShape = .poster   // 2:3, matching the portrait art the snapshot carries
        shelf.playbackProgress = item.progress   // draws the resume stripe the rail shows in-app

        if let poster = item.poster, let url = URL(string: poster) {
            // The system picks the variant per screen scale. We publish ONE art URL: the source is a
            // single fixed-size poster, so pointing both traits at it is honest, and claiming a
            // distinct 2x asset we do not have would gain nothing.
            shelf.setImageURL(url, for: .screenScale1x)
            shelf.setImageURL(url, for: .screenScale2x)
        }

        // Both actions open the title's detail page, where the primary button already reads
        // "Resume <time>" and runs the app's real resume (exact stored source, fresh debrid link,
        // episode-moved handling). Routing the play button straight into playback would mean a SECOND
        // copy of that resume logic living out here, drifting from the one on the rail; sending both
        // to the one screen that already owns it keeps a single implementation. See the note in
        // StremioTVApp's link handler.
        let open = TopShelfSnapshot.openURL(type: item.type, id: item.id).map(TVTopShelfAction.init)
        shelf.displayAction = open   // item selected
        shelf.playAction = open      // play/pause pressed while focused
        return shelf
    }
}
