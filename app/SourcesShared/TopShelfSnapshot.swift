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

    /// App Group the project provisions for the tvOS app and its Top Shelf extension (`project.yml`).
    ///
    /// VortX Lite deliberately does NOT declare the group (it ships no Top Shelf extension in v1), so
    /// on Lite `containerURL` is nil, every write is a silent no-op, and nothing else changes. That is
    /// also exactly what happens in an UNSIGNED / CODE_SIGNING_ALLOWED=NO build, where the entitlement
    /// is not provisioned: the whole feature degrades to "no snapshot, static Top Shelf image", never
    /// to a crash. Every entry point here is nil-tolerant for that reason.
    static let canonicalAppGroupID = "group.com.stremiox.tv"

    /// The App Group this signed copy actually shares with its Top Shelf extension.
    ///
    /// A sideload signer re-signs under its own team, which cannot hold `canonicalAppGroupID`, so it grants
    /// the app and the extension a group of its own instead (a FlareStore log shows `group.<hex>.1`). Asking
    /// only for the canonical ID then found no container in either process, so the shelf stayed the static
    /// image under re-signing. Both processes choose from the same extension bundle metadata, then
    /// each verifies access to that one container. Profile hints alone do not establish access.
    ///
    /// A signer's group can be shared by every app that service signs for the viewer, so it is used only by
    /// a bundle that ships or is the Top Shelf extension; Lite never writes there. What it carries is the
    /// Continue Watching row the Home screen already shows. Nil means the feature is off, never an error.
    private static let appGroupResolution = resolveAppGroup(bundle: .main)
    static let appGroupID: String? = appGroupResolution.id

    /// Closed, identifier-free diagnostic reason. Never expose App Group ids, paths, teams, or entitlement bytes.
    static var appGroupResolutionSource: String { appGroupResolution.source.rawValue }
    static var appGroupResolutionDecision: String { appGroupResolution.decision.rawValue }

    /// `dedicated` is a signer's copy of VortX's own group; `signer` is a signer group other apps can share.
    enum AppGroupSource: String, Sendable { case canonical, dedicated, signer, none }

    /// Which kind of group this copy uses; the identifier itself is not logged. Trakt and SIMKL rows go only
    /// to a group no other app shares (`TopShelfSnapshotWriter.publishCurrent`).
    static var appGroupSource: AppGroupSource {
        guard let appGroupID else { return .none }
        if appGroupID == canonicalAppGroupID { return .canonical }
        return isDedicatedSignerGroup(appGroupID, bundle: .main) ? .dedicated : .signer
    }

    static func isDedicatedSignerGroup(_ id: String, bundle: Bundle) -> Bool {
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        return isDedicatedSignerGroup(id,
            recordedGroups: bundle.infoDictionary?["ALTAppGroups"] as? [String] ?? [],
            teamIdentifiers: profile.map(provisionedTeamIdentifiers) ?? [])
    }

    /// AltStore and SideStore give each app its own copy of every group it declares, named after it and the
    /// signing team (`group.com.stremiox.tv.<team>`), and record it in the bundle's `ALTAppGroups`. Such a copy
    /// is VortX's only when all of that holds for this signed bundle: the group is recorded there, and its suffix
    /// is exactly this copy's team identifier (ASCII letters and digits). Anything else, including a signing
    /// service's generic group (a FlareStore log shows `group.<hex>.1`) that other apps it signs can share,
    /// stays a shared signer group.
    static func isDedicatedSignerGroup(_ id: String, recordedGroups: [String], teamIdentifiers: [String]) -> Bool {
        let prefix = canonicalAppGroupID + "."
        guard id.hasPrefix(prefix), recordedGroups.contains(id) else { return false }
        let suffix = String(id.dropFirst(prefix.count))
        let isTeamIdentifier = !suffix.isEmpty && suffix.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
        return isTeamIdentifier && teamIdentifiers.contains(suffix)
    }

    private enum AppGroupResolutionSource: String, Sendable {
        case missingProvider, metadata, signedXML, signedEmpty, signedMalformed
        case metadataDERUnsupported, metadataLayoutUnsupported
    }

    private enum AppGroupResolutionDecision: String, Sendable {
        case selected, noCandidate, containerDenied
    }

    private struct AppGroupResolution: Sendable {
        let id: String?
        let source: AppGroupResolutionSource
        let decision: AppGroupResolutionDecision
    }

    /// A valid XML claim is authoritative. An uninspected representation retains the exact original
    /// provider-metadata route, while a malformed signature or a confirmed empty claim stops resolution.
    enum SignedAppGroupState: Equatable, Sendable {
        case absent, xml([String]), emptyXML, malformed, derUnsupported, layoutUnsupported
    }

    static func resolveAppGroupID(
        bundle: Bundle,
        hasContainer: (String) -> Bool = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    ) -> String? {
        resolveAppGroup(bundle: bundle, hasContainer: hasContainer).id
    }

    private static func resolveAppGroup(
        bundle: Bundle,
        hasContainer: (String) -> Bool = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    ) -> AppGroupResolution {
        guard let provider = topShelfBundle(for: bundle) else {
            return .init(id: nil, source: .missingProvider, decision: .noCandidate)
        }
        let signed: [String]?
        let source: AppGroupResolutionSource
        switch signedAppGroups(executable: provider.executableURL) {
        case let .xml(groups): signed = groups; source = .signedXML
        case .absent: signed = nil; source = .metadata
        case .derUnsupported: signed = nil; source = .metadataDERUnsupported
        case .layoutUnsupported: signed = nil; source = .metadataLayoutUnsupported
        case .emptyXML: return .init(id: nil, source: .signedEmpty, decision: .noCandidate)
        case .malformed: return .init(id: nil, source: .signedMalformed, decision: .noCandidate)
        }
        let profile = provider.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        let recorded = provider.infoDictionary?["ALTAppGroups"] as? [String] ?? []
        let provisioned = profile.map(provisionedAppGroups) ?? []
        let teams = profile.map(provisionedTeamIdentifiers) ?? []
        var checkedContainer = false
        let id = selectAppGroup(recordedGroups: recorded, profileGroups: provisioned,
                                signedGroups: signed, teamIdentifiers: teams) { candidate in
            checkedContainer = true
            return hasContainer(candidate)
        }
        let decision: AppGroupResolutionDecision = id != nil ? .selected : (checkedContainer ? .containerDenied : .noCandidate)
        return .init(id: id, source: source, decision: decision)
    }

    /// Choose before checking access. A signed executable group set is authoritative; it is never unioned with
    /// mutable Info/profile hints. The final FileManager probe remains the operating system's authority.
    static func selectAppGroup(
        recordedGroups: [String],
        profileGroups: [String],
        signedGroups: [String]? = nil,
        teamIdentifiers: [String] = [],
        hasContainer: (String) -> Bool
    ) -> String? {
        func identifiers(_ groups: [String]) -> Set<String> {
            Set(groups.filter { $0.hasPrefix("group.") && $0.count > "group.".count && !$0.contains("*") })
        }
        let recorded = identifiers(recordedGroups)
        let provisioned = identifiers(profileGroups)
        let candidates: Set<String>
        if let signedGroups {
            candidates = identifiers(signedGroups)
        } else if recorded.isEmpty && provisioned.isEmpty {
            candidates = [canonicalAppGroupID]
        } else if recorded.isEmpty || provisioned.isEmpty {
            candidates = recorded.union(provisioned)
        } else {
            candidates = recorded.intersection(provisioned)
        }
        let candidate: String
        if candidates.contains(canonicalAppGroupID) {
            candidate = canonicalAppGroupID
        } else if candidates.count == 1, let only = candidates.first {
            candidate = only
        } else {
            let dedicated = candidates.filter {
                isDedicatedSignerGroup($0, recordedGroups: recordedGroups, teamIdentifiers: teamIdentifiers)
            }
            guard dedicated.count == 1, let only = dedicated.first else { return nil }
            candidate = only
        }
        return hasContainer(candidate) ? candidate : nil
    }

    // Apple Mach-O loader.h: mach_header_64 / LC_CODE_SIGNATURE / linkedit_data_command.
    // Apple Code Signing Services: CSMAGIC_EMBEDDED_SIGNATURE, CSMAGIC_EMBEDDED_ENTITLEMENTS and slots 5/7.
    private static let machHeader64Size = 32, maxLoadCommands = 4_096, maxLoadCommandBytes = 1_048_576
    private static let maxSignatureBytes = 4_194_304, maxEntitlementXMLBytes = 262_144, maxSuperBlobEntries = 256
    private static let mhMagic64: UInt32 = 0xfeedfacf, cpuTypeArm64: UInt32 = 0x0100000c, lcCodeSignature: UInt32 = 0x1d
    private static let csMagicEmbeddedSignature: UInt32 = 0xfade0cc0, csMagicEmbeddedEntitlements: UInt32 = 0xfade7171
    private static let csSlotEntitlements: UInt32 = 5, csSlotDEREntitlements: UInt32 = 7

    static func signedAppGroups(executable: URL?) -> SignedAppGroupState {
        guard let executable else { return .absent }
        guard let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= machHeader64Size else { return .malformed }
        do {
            let handle = try FileHandle(forReadingFrom: executable); defer { try? handle.close() }
            guard let header = try handle.read(upToCount: machHeader64Size), header.count == machHeader64Size
            else { return .malformed }
            // A universal executable needs an architecture-table reader. Keep it on the original
            // metadata route rather than sampling a slice or treating an unsupported layout as corrupt.
            switch bigEndian32(header, 0) {
            case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca: return .layoutUnsupported
            default: break
            }
            guard littleEndian32(header, 0) == mhMagic64 else { return .malformed }
            guard littleEndian32(header, 4) == cpuTypeArm64 else { return .layoutUnsupported }
            guard let count = littleEndian32(header, 16), let byteCount = littleEndian32(header, 20),
                  count <= maxLoadCommands, byteCount <= maxLoadCommandBytes,
                  machHeader64Size + Int(byteCount) <= fileSize,
                  let commands = try handle.read(upToCount: Int(byteCount)), commands.count == Int(byteCount)
            else { return .malformed }
            let location = codeSignatureLocation(commands, count: Int(count), fileSize: fileSize,
                                                 minimumOffset: machHeader64Size + Int(byteCount))
            let signature: (offset: Int, size: Int)
            switch location {
            case .absent: return .absent
            case .malformed: return .malformed
            case let .range(range): signature = range
            }
            guard signature.size <= maxSignatureBytes else { return .malformed }
            try handle.seek(toOffset: UInt64(signature.offset))
            guard let blob = try handle.read(upToCount: signature.size), blob.count == signature.size else { return .malformed }
            return signedAppGroups(signature: blob)
        } catch { return .malformed }
    }

    private enum CodeSignatureLocation {
        case absent, malformed, range((offset: Int, size: Int))
    }

    private static func codeSignatureLocation(_ commands: Data, count: Int, fileSize: Int,
                                              minimumOffset: Int) -> CodeSignatureLocation {
        var cursor = 0; var result: (offset: Int, size: Int)?
        for _ in 0..<count {
            guard let command = littleEndian32(commands, cursor), let size = littleEndian32(commands, cursor + 4),
                  size >= 8, Int(size) <= commands.count - cursor else { return .malformed }
            if command == lcCodeSignature {
                guard size == 16, result == nil, let offset = littleEndian32(commands, cursor + 8),
                      let length = littleEndian32(commands, cursor + 12), length > 0,
                      Int(offset) >= minimumOffset, Int(offset) <= fileSize, Int(length) <= fileSize - Int(offset) else { return .malformed }
                result = (Int(offset), Int(length))
            }
            cursor += Int(size)
        }
        guard cursor == commands.count else { return .malformed }
        return result.map(CodeSignatureLocation.range) ?? .absent
    }

    private static func signedAppGroups(signature: Data) -> SignedAppGroupState {
        guard bigEndian32(signature, 0) == csMagicEmbeddedSignature, let totalLength = bigEndian32(signature, 4),
              Int(totalLength) <= signature.count, let count = bigEndian32(signature, 8), count <= maxSuperBlobEntries,
              12 + Int(count) * 8 <= Int(totalLength) else { return .malformed }
        let indexEnd = 12 + Int(count) * 8
        var xml: Range<Int>?
        var hasDER = false
        var ranges: [Range<Int>] = []
        for index in 0..<Int(count) {
            let cursor = 12 + index * 8
            guard let slot = bigEndian32(signature, cursor), let offset = bigEndian32(signature, cursor + 4),
                  Int(offset) >= indexEnd, Int(offset) <= Int(totalLength) - 8,
                  let length = bigEndian32(signature, Int(offset) + 4),
                  length >= 8, Int(length) <= Int(totalLength) - Int(offset) else { return .malformed }
            let range = Int(offset)..<(Int(offset) + Int(length))
            ranges.append(range)
            switch slot {
            case csSlotEntitlements:
                guard xml == nil, bigEndian32(signature, range.lowerBound) == csMagicEmbeddedEntitlements,
                      range.count <= maxEntitlementXMLBytes + 8 else { return .malformed }
                xml = range
            case csSlotDEREntitlements:
                guard !hasDER, bigEndian32(signature, range.lowerBound) == 0xfade7172 else { return .malformed }
                hasDER = true
            default:
                break
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        guard zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { return .malformed }
        guard let xml else { return hasDER ? .derUnsupported : .absent }
        let body = signature.subdata(in: (xml.lowerBound + 8)..<xml.upperBound)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: &format) as? [String: Any],
              format == .xml
        else { return .malformed }
        guard let value = plist["com.apple.security.application-groups"] else { return .emptyXML }
        guard let groups = value as? [String] else { return .malformed }
        return groups.isEmpty ? .emptyXML : .xml(groups)
    }

    private static func littleEndian32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
    private static func bigEndian32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    /// The application groups in a provisioning profile, a signed envelope around an XML property list.
    static func provisionedAppGroups(profile: Data) -> [String] {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// The signing team of a provisioning profile, from its `TeamIdentifier` list and its entitlements.
    static func provisionedTeamIdentifiers(profile: Data) -> [String] {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return [] }
        var teams = plist["TeamIdentifier"] as? [String] ?? []
        if let team = (plist["Entitlements"] as? [String: Any])?["com.apple.developer.team-identifier"] as? String {
            teams.append(team)
        }
        return teams
    }

    /// Use the same signed provider bundle from both processes. The app can read its own nested
    /// bundle, and the provider can use its own metadata without opening its containing app.
    static func topShelfBundle(for bundle: Bundle) -> Bundle? {
        let extensionName = "VortXTopShelf.appex"
        if bundle.bundleURL.lastPathComponent == extensionName {
            return isTopShelfExtension(bundle.infoDictionary) ? bundle : nil
        }
        guard let plugins = bundle.builtInPlugInsURL,
              let provider = Bundle(url: plugins.appendingPathComponent(extensionName, isDirectory: true)),
              isTopShelfExtension(provider.infoDictionary)
        else { return nil }
        return provider
    }

    static func isTopShelfExtension(_ info: [String: Any]?) -> Bool {
        (info?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.tv-top-shelf"
    }

    /// Snapshot filename inside the group container.
    private static let filename = "top-shelf.json"

    /// Most items the Top Shelf row carries. The Top Shelf is a glance surface, not a browse surface:
    /// it is the resume queue's head, and the system only ever shows a handful before the row scrolls
    /// out of reach. The item cap bounds constructed rows; the separate byte ceiling below bounds
    /// the file passed to the extension's decoder.
    static let maxItems = 8

    /// Ceiling for the complete UTF-8 JSON cache, including metadata and all eight items. A 256 KiB
    /// budget allows roughly 32 KiB per row for existing titles/URLs without admitting an unbounded file into
    /// the extension. This is a conservative cache policy, not a measured system memory allowance.
    /// The producer also enforces this limit. An oversized publication becomes a compact display-only
    /// projection, never a reason to retain the previous owner's visible cache.
    static let maxSnapshotBytes = 256 * 1024

    /// Overflow-only title allowance. Unicode scalars bound encoded bytes even for a pathological
    /// single grapheme with thousands of combining marks; ordinary publications are not truncated.
    static let maxOverflowTitleScalars = 512

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

        /// Home distinguishes a movie and series with the same provider id. The system shelf
        /// needs that same distinction, while actions must keep the original provider id.
        /// Length-prefix the type so even delimiter-bearing future types cannot collide.
        var shelfIdentifier: String { "\(type.utf8.count):\(type):\(id)" }
    }

    struct Payload: Codable, Equatable, Sendable {
        let version: Int
        /// Wall-clock write time. Diagnostics only; the extension does not expire on it, because a
        /// stale resume row is still a useful row and the app rewrites on every Home refresh anyway.
        let writtenAt: Date
        let items: [Item]

        private enum CodingKeys: String, CodingKey { case version, writtenAt, items }

        init(version: Int, writtenAt: Date, items: [Item]) {
            self.version = version
            self.writtenAt = writtenAt
            self.items = items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            writtenAt = try container.decode(Date.self, forKey: .writtenAt)
            var rows = try container.nestedUnkeyedContainer(forKey: .items)
            if let count = rows.count, count > TopShelfSnapshot.maxItems {
                throw DecodingError.dataCorruptedError(in: rows, debugDescription: "Too many Top Shelf items")
            }
            var decoded: [Item] = []
            decoded.reserveCapacity(TopShelfSnapshot.maxItems)
            while !rows.isAtEnd {
                guard decoded.count < TopShelfSnapshot.maxItems else {
                    throw DecodingError.dataCorruptedError(in: rows, debugDescription: "Too many Top Shelf items")
                }
                decoded.append(try rows.decode(Item.self))
            }
            items = decoded
        }
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
        guard let appGroupID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
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
        return localArtworkURL(for: sourceURL, in: directory)
    }

    /// Pure path calculation also used by disposable source-unit fixtures; it never resolves an App Group.
    static func localArtworkURL(for sourceURL: String, in directory: URL) -> URL? {
        guard !sourceURL.isEmpty else { return nil }
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
        readResult().items
    }

    /// Fixed diagnostic vocabulary only: no paths, payload values or underlying error text.
    enum ReadStatus: String, Sendable {
        case noContainer, invalidFile, unavailableFile, oversized, rejectedBytes
        case invalidPayload, unsupportedVersion, empty, ready
    }

    struct ReadResult: Sendable {
        let status: ReadStatus
        let items: [Item]
    }

    /// The same single bounded read used by read(); not an additional diagnostic probe.
    static func readResult() -> ReadResult {
        readResult(from: fileURL)
    }

    /// nil models an unavailable group without probing any real container in fixtures.
    static func readResult(from url: URL?) -> ReadResult {
        guard let url else { return .init(status: .noContainer, items: []) }
        let result = inspectPayload(from: url)
        let directory = url.deletingLastPathComponent().appendingPathComponent(artworkDirectoryName, isDirectory: true)
        return .init(status: result.status,
                     items: (result.payload?.items ?? []).compactMap { displayable($0, artworkDirectory: directory) })
    }

    /// An explicit file seam keeps fixtures out of the real App Group. Invalid input is read-only:
    /// return no content without deleting, rewriting, normalizing or pruning any cache/history.
    static func read(from url: URL) -> [Item] {
        readResult(from: url).items
    }

    /// The snapshot file is untrusted input: under a signing service's shared group another app could have
    /// written it. A row is shown only when its action round-trips through the app's own link parser, and
    /// its progress satisfies TVServices' 0...1 contract, and its poster is https or a file inside
    /// the managed artwork folder. Reject malformed rows without repairing the shared cache.
    static func displayable(_ item: Item, artworkDirectory: URL?) -> Item? {
        guard hasValidAction(type: item.type, id: item.id),
              item.progress.isFinite, (0...1).contains(item.progress) else { return nil }
        guard let poster = item.poster else { return item }
        let accepted: Bool
        if let url = URL(string: poster), url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            accepted = true
        } else if let url = URL(string: poster), url.isFileURL, let directory = artworkDirectory {
            let base = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            accepted = url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base)
        } else {
            accepted = false
        }
        return accepted ? item : Item(id: item.id, type: item.type, title: item.title, poster: nil, progress: item.progress)
    }

    private static func readPayload(from url: URL) -> Payload? {
        inspectPayload(from: url).payload
    }

    private static func inspectPayload(from url: URL) -> (payload: Payload?, status: ReadStatus) {
        guard url.isFileURL else { return (nil, .invalidFile) }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return (nil, .invalidFile) }
            if let size = values.fileSize, size > maxSnapshotBytes { return (nil, .oversized) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // The existing collector deliberately conflates empty/I-O/sentinel failures. Report
            // that bounded rejection honestly; do not retry or perform a second filesystem read.
            guard let data = boundedSnapshotData(readChunk: { try handle.read(upToCount: $0) }) else {
                return (nil, .rejectedBytes)
            }
            guard let payload = try? decoder.decode(Payload.self, from: data) else {
                return (nil, .invalidPayload)
            }
            guard payload.version == currentVersion else { return (nil, .unsupportedVersion) }
            return (payload, payload.items.isEmpty ? .empty : .ready)
        } catch {
            // Includes missing files, denied metadata/open and other filesystem errors.
            return (nil, .unavailableFile)
        }
    }

    /// FileHandle may return a short chunk before EOF. Keep reading within a single byte budget;
    /// one extra byte distinguishes an exact-limit file from an oversized file or stale size hint.
    /// JSONDecoder sees at most maxSnapshotBytes; only the byte reader may retain the sentinel byte.
    static func boundedSnapshotData(readChunk: (Int) throws -> Data?) -> Data? {
        var data = Data()
        do {
            while data.count <= maxSnapshotBytes {
                let requested = min(16 * 1024, maxSnapshotBytes + 1 - data.count)
                guard let chunk = try readChunk(requested), !chunk.isEmpty else { break }
                guard chunk.count <= requested else { return nil }
                data.append(chunk)
            }
            guard !data.isEmpty, data.count <= maxSnapshotBytes else { return nil }
            return data
        } catch {
            return nil
        }
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
        writeResult(items) == .written
    }

    enum WriteResult: String, Hashable, Sendable {
        case written, unchanged, noContainer, invalidDestination, encodingFailed, writeFailed
    }

    struct ContentNotification {
        private var didNotify = false

        mutating func shouldNotify(after result: WriteResult) -> Bool {
            // On the first usable publication, tvOS may still hold a display from before app launch
            // or an update, even when the retained snapshot already matches the current profile.
            guard result == .written || (result == .unchanged && !didNotify) else { return false }
            didNotify = true
            return true
        }
    }

    /// Outcomes come from the actual operation. The compatibility Bool remains true ONLY for
    /// a changed successful write; unchanged content is not diagnosed as a failure.
    static func writeResult(_ items: [Item]) -> WriteResult {
        guard let url = fileURL else { return .noContainer }
        return writeResult(items, to: url)
    }

    /// Explicit destination is for the same cache contract and disposable fixtures, not account data.
    @discardableResult
    static func write(_ items: [Item], to url: URL) -> Bool {
        writeResult(items, to: url) == .written
    }

    static func writeResult(_ items: [Item], to url: URL) -> WriteResult {
        guard url.isFileURL else { return .invalidDestination }
        var capped = Array(items.prefix(maxItems))
        // Compare CONTENT, not the encoded bytes: `writtenAt` changes on every call, so comparing
        // payloads would always report a change and defeat the point of the check.
        // A failed read is not evidence of an already-empty file: an explicit [] must still clear
        // a malformed/oversized prior publication on sign-out, profile change or feature-off.
        let previous = readPayload(from: url)
        if let previous, capped == previous.items { return .unchanged }
        let writtenAt = Date()
        var payload = Payload(version: currentVersion, writtenAt: writtenAt, items: capped)
        guard var data = try? encoder.encode(payload) else { return .encodingFailed }
        if data.count > maxSnapshotBytes {
            // This file is only the system's display cache, never saved history. Keep current titles
            // actionable where possible instead of writing bytes the extension must reject. Drop art
            // and bound titles only on overflow; raw action identities and progress are never changed.
            var compact: [Item] = []
            for item in capped {
                let candidate = Item(id: item.id, type: item.type,
                    title: String(String.UnicodeScalarView(item.title.unicodeScalars.prefix(maxOverflowTitleScalars))),
                    poster: nil, progress: item.progress)
                let trial = Payload(version: currentVersion, writtenAt: writtenAt, items: compact + [candidate])
                guard let bytes = try? encoder.encode(trial) else { return .encodingFailed }
                guard bytes.count <= maxSnapshotBytes else { continue }
                compact.append(candidate)
            }
            capped = compact
            if let previous, capped == previous.items { return .unchanged }
            payload = Payload(version: currentVersion, writtenAt: writtenAt, items: capped)
            guard let bounded = try? encoder.encode(payload), bounded.count <= maxSnapshotBytes else {
                return .encodingFailed
            }
            data = bounded
        }
        // Atomic: the extension can be reading this file in another process at any moment, and a
        // torn read would decode to nothing (harmless, but it would blank the shelf for a cycle).
        do { try data.write(to: url, options: .atomic) } catch { return .writeFailed }
        return .written
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

    /// The app writer and extension reader require the same exact, routable title identity.
    static func hasValidAction(type: String, id: String) -> Bool {
        guard let link = openURL(type: type, id: id) else { return false }
        return parse(link) == .open(type: type, id: id)
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
