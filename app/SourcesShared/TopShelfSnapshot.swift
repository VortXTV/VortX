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
    struct Item: Codable, Equatable {
        /// The engine library id (an imdb `tt…` id for most titles), used as the item's stable
        /// Top Shelf identifier and as the deep link's `id`.
        let id: String
        /// "movie" or "series".
        let type: String
        let title: String
        /// Poster art URL. See `TopShelfSnapshotWriter` for why this is the RAW add-on/metahub poster
        /// and deliberately not a signed `poster.vortx.tv` URL.
        let poster: String?
        /// 0…1 watch progress, matching `TVTopShelfSectionedItem.playbackProgress`'s required range.
        let progress: Double
    }

    struct Payload: Codable, Equatable {
        let version: Int
        /// Wall-clock write time. Diagnostics only; the extension does not expire on it, because a
        /// stale resume row is still a useful row and the app rewrites on every Home refresh anyway.
        let writtenAt: Date
        let items: [Item]
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
