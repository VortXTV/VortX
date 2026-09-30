import Foundation

/// The Apple TV **Top Shelf** hand-off: the tiny, self-contained contract shared by the app (writer)
/// and the `VortXTopShelf` app extension (reader).
///
/// The Top Shelf extension is a SEPARATE process with its own container, and the system runs it when
/// VortX is focused on the tvOS Home screen, often while the app itself is not running at all. It
/// therefore cannot reach the engine, the account, or `UserDefaults.standard`: nothing of ours is
/// booted in that process, and booting stremio-core inside an extension (with its far smaller memory
/// ceiling and a "return content promptly or the system falls back to the static image" deadline)
/// is not viable. So the app publishes a plain JSON snapshot into the shared App Group container and
/// the extension does nothing but read and render it.
///
/// Deliberately Foundation-ONLY and free of every VortX type (no `CoreCWItem`, no `ProfileStore`,
/// no `Theme`). It is the ONE file the extension target compiles out of `SourcesShared`, mirroring
/// how `DiagnosticsLog` / `VXProbe` / `ServerDiagnostics` are pulled into the web-host target as
/// single self-contained files. Keeping the engine models out of here is what keeps the extension's
/// compile surface at one file instead of dragging in `CoreModels` and its transitive world.
///
/// The app-side mapping from the engine's Continue Watching (`CoreCWItem`) into these value types
/// lives in `SourcesTV/TopShelfSnapshotWriter.swift`, which the extension does NOT compile.
enum TopShelfSnapshot {

    /// App Group shared by the tvOS app and its Top Shelf extension. Both must carry this in their
    /// entitlements for the container to exist (generated from `project.yml`).
    ///
    /// VortX Lite deliberately does NOT declare the group (it ships no Top Shelf extension in v1), so
    /// on Lite `containerURL` is nil, every write is a silent no-op, and nothing else changes. That is
    /// also exactly what happens in an UNSIGNED / CODE_SIGNING_ALLOWED=NO build, where the entitlement
    /// is not provisioned: the whole feature degrades to "no snapshot, static Top Shelf image", never
    /// to a crash. Every entry point here is nil-tolerant for that reason.
    static let appGroupID = "group.com.stremiox.tv"

    /// Snapshot filename inside the group container.
    private static let filename = "top-shelf.json"

    /// Most items the Top Shelf row carries. The Top Shelf is a glance surface, not a browse surface:
    /// it is the resume queue's head, and the system only ever shows a handful before the row scrolls
    /// out of reach. Capping the write also bounds the payload the extension has to decode inside its
    /// response deadline.
    static let maxItems = 8

    /// Payload schema version. Bumped when the shape changes so an OLD extension paired with a NEW
    /// app (or the reverse, mid-update) rejects a payload it cannot read instead of mis-rendering it.
    /// A version mismatch reads as "no content", which shows the static image: the correct degrade.
    static let currentVersion = 1

    // MARK: Model

    /// One Continue Watching entry, flattened to exactly what the Top Shelf can render and what a
    /// tap needs to route back into the app.
    struct Item: Codable, Equatable, Sendable {
        /// The engine library id (an imdb `tt…` id for most titles), used as the item's stable
        /// Top Shelf identifier and as the deep link's `id`.
        let id: String
        /// "movie" or "series".
        let type: String
        let title: String
        /// Poster art URL. Local engine rows keep their existing raw add-on/metahub URL; private Trakt
        /// rows carry a `file://` URL into the managed App Group cache after the app warms the image.
        /// Neither path is a signed `poster.vortx.tv` URL.
        let poster: String?
        /// 0…1 watch progress, matching `TVTopShelfSectionedItem.playbackProgress`'s required range.
        let progress: Double
    }

    struct Payload: Codable, Equatable, Sendable {
        let version: Int
        /// Wall-clock write time. Diagnostics only; the extension does not expire on it, because a
        /// stale resume row is still a useful row and the app rewrites on every Home refresh anyway.
        let writtenAt: Date
        let items: [Item]
    }

    /// Pure state transitions used by the app-side private Trakt publisher. Keeping these rules in the
    /// Foundation-only contract lets the standalone tests exercise the privacy boundary without linking
    /// TVServices or the engine model, while the Top Shelf extension still compiles only this file.
    enum PrivatePublicationPolicy {
        /// The stable identity of one selected row. Playback progress is deliberately absent: a progress
        /// tick must update the JSON row but must not cancel an in-flight image warm or prune its cache.
        struct ArtworkInput: Equatable, Sendable {
            let id: String
            let type: String
            let poster: String?
        }

        private struct RowKey: Hashable {
            let id: String
            let type: String
        }

        /// Restart warming only when ownership or the selected row/artwork set changes. Titles and
        /// progress belong to the publication payload, not to the CDN/cache identity.
        static func requiresWarmRestart(
            previousSessionRaw: String?,
            currentSessionRaw: String?,
            previousArtworkInputs: [ArtworkInput]?,
            currentArtworkInputs: [ArtworkInput]
        ) -> Bool {
            previousSessionRaw != currentSessionRaw
                || previousArtworkInputs != currentArtworkInputs
        }

        /// Apply a fresh title/progress publication while retaining only previously generated managed
        /// `file://` posters. A remote URL can never be carried forward through this merge.
        static func mergingCurrentProgress(
            pending: [Item],
            previouslyPublished: [Item]
        ) -> [Item] {
            var managedPosters: [RowKey: String] = [:]
            for item in previouslyPublished {
                guard let poster = item.poster,
                      let url = URL(string: poster),
                      url.isFileURL else { continue }
                managedPosters[RowKey(id: item.id, type: item.type)] = poster
            }
            return pending.map { item in
                guard let poster = managedPosters[RowKey(id: item.id, type: item.type)] else {
                    return item
                }
                return Item(
                    id: item.id,
                    type: item.type,
                    title: item.title,
                    poster: poster,
                    progress: item.progress
                )
            }
        }

        /// An auth-boundary callback is relevant only while the emitted session is still the certified
        /// current session. A stale callback for an old account cannot clear a newer private publication;
        /// a current callback never clears a local overlay row.
        static func shouldClearObsoletePrivateOwner(
            emittedSessionRaw: String?,
            currentSessionRaw: String?,
            privateOwnerRaw: String?,
            publishedPrivateRows: Bool
        ) -> Bool {
            guard emittedSessionRaw == currentSessionRaw,
                  let privateOwnerRaw,
                  privateOwnerRaw != currentSessionRaw else { return false }
            return publishedPrivateRows
        }

        /// Validate response metadata before accepting a bounded byte stream. The writer supplies the
        /// strict first-party-final-URL result from `TraktArtworkPolicy`; this helper owns status/MIME/
        /// length accounting and is intentionally independent of URLSession.
        static func acceptsArtworkResponse(
            finalURLIsFirstParty: Bool,
            statusCode: Int,
            mimeType: String?,
            expectedContentLength: Int64?,
            accumulatedBytes: Int
        ) -> Bool {
            guard finalURLIsFirstParty,
                  (200..<300).contains(statusCode),
                  mimeType?.lowercased().hasPrefix("image/") == true,
                  accumulatedBytes > 0,
                  accumulatedBytes <= TopShelfSnapshot.maxArtworkBytes else { return false }
            if let expectedContentLength,
               expectedContentLength > Int64(TopShelfSnapshot.maxArtworkBytes) {
                return false
            }
            return true
        }
    }

    // MARK: Container

    /// The shared container, or nil when the App Group is not provisioned (unsigned build, Lite, or a
    /// profile without the capability). Callers MUST treat nil as "feature off", never as an error.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: Managed private artwork

    /// Exact App Group subdirectory owned by the app's Trakt Top Shelf warmer. The extension only
    /// reads the file URLs embedded in the JSON snapshot; it never enumerates or writes this folder.
    /// Keeping the path here (instead of deriving it at each call site) makes the cleanup boundary
    /// auditable: sign-out and account changes remove this directory and nothing above it.
    static let artworkDirectoryName = "top-shelf-artwork"

    /// Maximum bytes retained for one warmed poster. Trakt's normal 600x900 WebP/JPEG responses are
    /// far below this; the bound prevents a malformed first-party response from consuming unbounded
    /// shared-container storage before the image reaches the system shelf.
    static let maxArtworkBytes = 12 * 1024 * 1024

    private static var artworkDirectoryURL: URL? {
        containerURL?.appendingPathComponent(artworkDirectoryName, isDirectory: true)
    }

    /// Deterministic, path-safe filename for one exact source URL. A short FNV-1a key avoids putting
    /// query strings or title ids into a path while keeping the cache Foundation-only (the extension
    /// target deliberately does not link CryptoKit). The source URL is never logged or serialized.
    private static func artworkKey(_ sourceURL: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in sourceURL.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// The local file URL for an exact source URL. This only computes a path; it does not create the
    /// directory or touch disk. Callers must validate the source URL before requesting a path here.
    static func localArtworkURL(for sourceURL: String) -> URL? {
        guard !sourceURL.isEmpty, let directory = artworkDirectoryURL else { return nil }
        let sourceExtension = URL(string: sourceURL)?.pathExtension.lowercased()
        let allowedExtensions = Set(["jpg", "jpeg", "png", "webp", "heic", "avif", "gif"])
        let fileExtension = sourceExtension.flatMap { allowedExtensions.contains($0) ? $0 : nil } ?? "image"
        return directory.appendingPathComponent("\(artworkKey(sourceURL)).\(fileExtension)", isDirectory: false)
    }

    /// Persist one already-validated image response into the managed App Group cache. The write is
    /// atomic so the Top Shelf extension can never observe a partially-written image. Failure is
    /// intentionally silent: the row remains useful with title/progress and a missing poster.
    @discardableResult
    static func storeArtwork(_ data: Data, for sourceURL: String) -> URL? {
        guard !data.isEmpty, data.count <= maxArtworkBytes,
              let url = localArtworkURL(for: sourceURL),
              let directory = artworkDirectoryURL else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Remove only the managed Trakt artwork directory. This is cache cleanup, never account data;
    /// still keep the target exact so a broken path can never broaden into the rest of the App Group.
    static func clearArtworkCache() {
        guard let directory = artworkDirectoryURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Read (extension side)

    /// The current snapshot's items, or [] when there is nothing to show: no container, no file yet,
    /// unreadable bytes, or a version we do not understand. Never throws, never traps. The extension
    /// turns [] into nil content, which is the system's cue to show the static Top Shelf image.
    static func read() -> [Item] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == currentVersion
        else { return [] }
        return Array(payload.items.prefix(maxItems))
    }

    // MARK: Write (app side)

    /// Replace the snapshot with `items` (capped at `maxItems`).
    ///
    /// Pass [] to CLEAR the shelf. Clearing has to be an explicit write rather than "stop writing":
    /// the file outlives the app, so a user who turns the feature off, signs out, or switches to a
    /// profile with no history must have the old row actively erased, not merely left un-refreshed.
    ///
    /// Silent no-op when the container is unavailable. Returns true when the shelf's content actually
    /// changed on disk, so the caller knows whether it is worth telling the system to re-read (that
    /// notification wakes the extension, so firing it on every unchanged Home refresh would be waste).
    @discardableResult
    static func write(_ items: [Item]) -> Bool {
        guard let url = fileURL else { return false }
        let capped = Array(items.prefix(maxItems))
        // Compare CONTENT, not the encoded bytes: `writtenAt` changes on every call, so comparing
        // payloads would always report a change and defeat the point of the check.
        if capped == read() { return false }
        let payload = Payload(version: currentVersion, writtenAt: Date(), items: capped)
        guard let data = try? encoder.encode(payload) else { return false }
        // Atomic: the extension can be reading this file in another process at any moment, and a
        // torn read would decode to nothing (harmless, but it would blank the shelf for a cycle).
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return true
    }

    // MARK: Deep links

    /// The URL scheme the Top Shelf uses to hand a tap back to the app.
    ///
    /// Read from the bundle (Info.plist `VortXURLScheme`, substituted from the `VORTX_URL_SCHEME`
    /// build setting) rather than hardcoded, because VortX and VortX Lite are separate apps that can
    /// be installed side by side. Two apps registering the SAME scheme makes the OS's choice of
    /// handler undefined, so each target registers its own ("vortx" / "vortx-lite") and each reads
    /// back whatever it registered. The literal fallback keeps a target without the key working.
    static var urlScheme: String {
        let declared = Bundle.main.object(forInfoDictionaryKey: "VortXURLScheme") as? String
        let trimmed = (declared ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "vortx" : trimmed
    }

    /// A parsed inbound deep link.
    enum Link: Equatable {
        /// Open a title's detail page.
        case open(type: String, id: String)
    }

    /// `vortx://open?type=<movie|series>&id=<id>` for a title's detail page.
    static func openURL(type: String, id: String) -> URL? {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "id", value: id)]
        return c.url
    }

    /// Content types a link may address. A URL scheme is an OPEN door: any app on the device can send
    /// us one, so what arrives is untrusted input and is validated against what we actually emit
    /// rather than passed through. The shelf only ever carries Continue Watching, which is movies and
    /// series, so nothing else is accepted and no third party can drive arbitrary engine lookups
    /// through our front door. Widen this deliberately if a later link type needs it.
    private static let allowedTypes: Set<String> = ["movie", "series"]

    /// Upper bound on an accepted id. Real ids are short ("tt0111161", "tmdb:1396", "kitsu:1:2"); this
    /// only exists so a hostile caller cannot hand us an unbounded string to carry around.
    private static let maxIDLength = 256

    /// Parse an inbound URL, or nil when it is not one of ours or does not validate.
    ///
    /// Checks the scheme (so an unrelated URL handed to `onOpenURL` is ignored), the host, that both
    /// query values are present, that the type is one we serve, and that the id is a sane length.
    /// Anything failing those is dropped rather than routed, so a malformed or hostile link can never
    /// open a blank or unexpected page.
    static func parse(_ url: URL) -> Link? {
        guard url.scheme?.lowercased() == urlScheme.lowercased(),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: a caller can legally repeat a query
        // name, and the strict initializer TRAPS on a duplicate key. That would turn a hand-crafted
        // `vortx://open?id=a&id=b` into a crash, from an input any app on the device can send.
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch url.host?.lowercased() {
        case "open":
            let type = (q["type"] ?? "").lowercased()
            let id = (q["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedTypes.contains(type), !id.isEmpty, id.count <= maxIDLength else { return nil }
            return .open(type: type, id: id)
        default:
            return nil
        }
    }

    // MARK: Coding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
