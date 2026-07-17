import TVServices

/// The `VortXTopShelf` extension's principal class: renders VortX's Continue Watching onto the tvOS
/// Home screen's Top Shelf when VortX is the focused app.
///
/// This runs in its OWN process, on the system's schedule, usually while VortX itself is not running.
/// It therefore does exactly one thing: read the JSON snapshot the app left in the shared App Group
/// container (`TopShelfSnapshot`) and turn it into `TVTopShelfSectionedContent`. It boots no engine,
/// opens no socket, and reads no `UserDefaults.standard` (all of which belong to the app's container,
/// not ours). The system will fall back to the static Top Shelf image if we are slow or return
/// nothing, so the whole path is a file read with no work that can block.
///
/// This target compiles exactly two files: this one and `SourcesShared/TopShelfSnapshot.swift`.
final class ContentProvider: TVTopShelfContentProvider {

    /// The ASYNC override of `loadTopShelfContentWithCompletionHandler:`.
    ///
    /// Swift imports the ObjC completion-handler method as `async` and maps this override back onto
    /// the original selector, so the system's call site is unchanged. Overriding the async form (in
    /// place of the completion-handler form) keeps the whole body on one isolation domain and leaves
    /// no escaping closure to hop out of, which is what the completion-handler form would force us to
    /// reason about under stricter concurrency checking later.
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let items = TopShelfSnapshot.read()

        // No snapshot, no App Group container (an unsigned / sideloaded build whose profile carries no
        // group), or the user turned the row off: return nil, which is the system's documented cue to
        // show the app's static Top Shelf image. This is the degrade path, and it must never be a
        // crash or an empty row.
        guard !items.isEmpty else { return nil }

        let shelfItems = items.map(sectionedItem)
        let collection = TVTopShelfItemCollection(items: shelfItems)
        // Names the row on the Home screen, above the posters.
        collection.title = String(localized: "Continue Watching")
        return TVTopShelfSectionedContent(sections: [collection])
    }

    /// One Continue Watching entry as a Top Shelf tile.
    private func sectionedItem(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        // The engine library id is unique within the snapshot, which is exactly the uniqueness
        // TVTopShelfItem.identifier requires.
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
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
