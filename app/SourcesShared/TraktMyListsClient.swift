import Foundation

/// "My Trakt lists": read the connected user's OWN lists (including private ones) and the lists they have
/// liked, and let each be surfaced as a native Home row.
///
/// Endpoints (https://trakt.docs.apiary.io), all READ-only and all new to the app:
///   - GET /users/me/lists      -> the lists you made (personal, including private / friends-only)
///   - GET /users/likes/lists   -> the lists you liked (someone else's, so always at least friends-visible)
///   - GET /users/settings      -> read for ONE field, your own user slug, which personal lists omit
/// Items come from the list-items endpoint `TraktListImportClient` already speaks, called with
/// `authorized: true` so a private list actually resolves.
///
/// AUTHORITY (the point of the design). This is a VIEW of Trakt, never a second owner of anything:
///   - Strictly read-only against Trakt. There is no create/update/delete-list call here and no
///     /users/me/lists POST. Editing a list stays on Trakt, where the user made it.
///   - The result is registered with `ImportedCatalogs`, whose standing invariant is that it writes ONLY
///     this app's own preferences and never an engine `libraryItem` or account document. So a Trakt list
///     paints as a browse row and touches nothing the VortX account owns.
///   - Therefore VortX's library and Trakt's lists never both claim the same record: they are not the same
///     record. Nothing here can disagree with the VortX account, because nothing here writes to it. That is
///     why this rail needs no merge, no conflict rule, and no last-writer-wins tiebreak.
///
/// Fail-soft everywhere: an outage, an expired token, or a list that will not resolve yields an empty list
/// or a typed `ImportedListError`, never a crash and never a half-written row.
enum TraktMyListsClient {

    // MARK: - Model

    /// Where a list came from, which is also how it is grouped in the UI. Hashable because the picker keys
    /// its section `ForEach` on the kind itself.
    enum Kind: String, Sendable, Equatable, Hashable {
        case personal   // GET /users/me/lists
        case liked      // GET /users/likes/lists
    }

    /// One of the connected user's lists, flattened to what the picker and the import need.
    struct MyList: Identifiable, Sendable, Equatable {
        /// The `imported:trakt:<owner>:<slug>` row id, built through `ListImport.stableID` so this list and
        /// the same list pasted as a URL are ONE row, not two.
        let id: String
        let name: String
        let owner: String        // list owner's user slug
        let slug: String         // list slug (or the numeric trakt id when the list has no slug)
        let itemCount: Int
        let privacy: String      // "private" | "friends" | "public"
        let kind: Kind

        /// Anything not explicitly public was readable only because we were signed in, so the row it produces
        /// is scoped to this connection and gets dropped on disconnect.
        var requiresConnection: Bool { privacy.lowercased() != "public" }

        /// Human label for the privacy chip.
        var privacyLabel: String {
            switch privacy.lowercased() {
            case "private": return "Private"
            case "friends": return "Friends"
            default:        return "Public"
            }
        }

        var canonicalURL: String { "https://trakt.tv/users/\(owner)/lists/\(slug)" }
    }

    // MARK: - Reads

    /// The user's own lists (`GET /users/me/lists`), private ones included. Empty when not connected.
    ///
    /// `/users/me/lists` describes lists that are already implicitly yours, so it does not have to name their
    /// owner, and in practice it does not: the `user` object rides along on the endpoints that return OTHER
    /// people's lists. We still need the owner's real slug, both to fetch items and to build the row id, so
    /// it is resolved once from `/users/settings` and used wherever a list does not name one. When a list DOES
    /// carry a user we prefer that, so this stays correct if Trakt returns one.
    static func personalLists() async -> [MyList] {
        guard let dtos: [ListDTO] = await getArray("/users/me/lists") else { return [] }
        let owner = await authenticatedUserSlug()
        return dtos.compactMap { myList(from: $0, kind: .personal, fallbackOwner: owner) }
    }

    /// The lists the user liked (`GET /users/likes/lists`). Each element wraps the list under a `list` key.
    /// These belong to other people, so each one names its own owner and needs no fallback.
    ///
    /// `limit` is explicit because this endpoint is PAGINATED and its default page is only 10 lists, so
    /// asking for it plainly would silently show a user with 30 liked lists just the first 10, with no error
    /// and nothing on screen to suggest the rest exist. That is the worst kind of bug in a read-only feature:
    /// it looks like it worked. One page of `maxLikedLists` covers any realistic account and keeps this a
    /// single request; the sibling `/users/me/lists` is not paginated and needs no such parameter.
    static func likedLists() async -> [MyList] {
        guard let dtos: [LikedListDTO] = await getArray("/users/likes/lists?limit=\(maxLikedLists)") else { return [] }
        return dtos.compactMap { $0.list }.compactMap { myList(from: $0, kind: .liked, fallbackOwner: nil) }
    }

    /// Ceiling on liked lists read in one page. Comfortably above any real account, and well above the 50-row
    /// `ImportedCatalogsStore.maxCatalogs` ceiling a user could ever surface from it.
    private static let maxLikedLists = 100

    /// The connected user's own slug (`GET /users/settings` -> `user.ids.slug`), or nil.
    ///
    /// This is the identity every personal row is keyed on, so it is never guessed: with no slug we drop the
    /// personal lists rather than key rows on a placeholder like "me". A placeholder would key the SAME list
    /// as `imported:trakt:me:<slug>` on one load and `imported:trakt:<you>:<slug>` on the next, and the user
    /// would end up with the list painted on Home twice.
    static func authenticatedUserSlug() async -> String? {
        guard let data = await getData("/users/settings"),
              let settings = try? JSONDecoder().decode(SettingsDTO.self, from: data),
              let slug = settings.user?.ids?.slug?.trimmingCharacters(in: .whitespacesAndNewlines),
              !slug.isEmpty else { return nil }
        return slug
    }

    /// Personal then liked, de-duplicated by row id (a user can like their own list; it should appear once,
    /// and the personal entry wins because that is the more accurate description of it). Both legs run
    /// concurrently; a failing leg contributes nothing rather than failing the whole screen.
    static func allLists() async -> [MyList] {
        guard TraktAuth.isConfigured, await TraktAuth.shared.isSignedIn else { return [] }
        async let personal = personalLists()
        async let liked = likedLists()
        let ordered = await personal + (await liked)
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Import (list -> Home row)

    /// Fetch + resolve one list into an un-persisted `ImportedListCatalog`, reusing the exact fetch/resolve
    /// path the public paste-URL import uses (`TraktListImportClient` -> `ListImport.resolve`), so a My-Lists
    /// row and a pasted-URL row are the same kind of object built the same way. The caller registers it.
    static func importList(_ list: MyList) async -> Result<ImportedListCatalog, ImportedListError> {
        guard TraktAuth.isConfigured else { return .failure(.notConfigured(.trakt)) }
        guard await TraktAuth.shared.isSignedIn else { return .failure(.network) }

        let raw = await TraktListImportClient.fetchRawList(user: list.owner, slug: list.slug, authorized: true)
        guard !raw.entries.isEmpty else { return .failure(.empty) }
        let items = await ListImport.resolve(Array(raw.entries.prefix(ListImport.maxItems)))
        guard !items.isEmpty else { return .failure(.empty) }

        let catalog = ImportedListCatalog(
            id: list.id,
            title: list.name,
            provider: .trakt,
            sourceURL: list.canonicalURL,
            items: items,
            addedAt: Date(),
            requiresConnection: list.requiresConnection
        )
        DiagnosticsLog.log("trakt-my-lists", "\(list.kind.rawValue) '\(list.name)' -> \(items.count) titles")
        return .success(catalog)
    }

    // MARK: - HTTP

    /// Authenticated GET returning the raw body, or nil on any failure (no token, non-200, transport).
    private static func getData(_ path: String) async -> Data? {
        guard let token = try? await TraktAuth.shared.validToken(),
              let url = URL(string: TraktAuth.apiBase + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Authenticated GET decoding a JSON array, or nil on any failure (including a bad shape).
    private static func getArray<T: Decodable>(_ path: String) async -> [T]? {
        guard let data = await getData(path),
              let decoded = try? JSONDecoder().decode([T].self, from: data) else { return nil }
        return decoded
    }

    /// Flatten a list DTO, dropping anything we could not address: a list with no slug AND no numeric id, or
    /// no owner slug, cannot have its items fetched, so it is not offered rather than offered and broken.
    private static func myList(from dto: ListDTO, kind: Kind, fallbackOwner: String?) -> MyList? {
        let name = (dto.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Prefer the slug; fall back to the numeric trakt id, which the items endpoint also accepts.
        let slug = dto.ids?.slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSlug = (slug?.isEmpty == false ? slug! : dto.ids?.trakt.map(String.init)) ?? ""
        // The list's own owner when it names one, else the connected user (personal lists do not name one).
        let owner = (dto.user?.ids?.slug ?? fallbackOwner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedSlug.isEmpty, !owner.isEmpty else { return nil }

        return MyList(
            id: ListImport.stableID(provider: .trakt, user: owner, slug: resolvedSlug),
            name: name,
            owner: owner,
            slug: resolvedSlug,
            itemCount: dto.itemCount ?? 0,
            privacy: dto.privacy ?? "private",   // absent privacy is treated as the SAFE end, not the open end
            kind: kind
        )
    }

    // MARK: - Wire shapes

    /// A Trakt list object as returned by /users/me/lists and nested in /users/likes/lists.
    private struct ListDTO: Decodable {
        let name: String?
        let privacy: String?
        let itemCount: Int?
        let ids: IDs?
        let user: User?

        struct IDs: Decodable {
            let trakt: Int?
            let slug: String?
        }
        struct User: Decodable {
            let ids: UserIDs?
            struct UserIDs: Decodable { let slug: String? }
        }

        enum CodingKeys: String, CodingKey {
            case name, privacy, ids, user
            case itemCount = "item_count"
        }
    }

    /// /users/likes/lists wraps each list in a like record.
    private struct LikedListDTO: Decodable {
        let list: ListDTO?
    }

    /// /users/settings, read for exactly one field: the connected user's own slug. Everything else the
    /// endpoint returns (account, connections, sharing text) is deliberately not modelled and not stored.
    private struct SettingsDTO: Decodable {
        let user: ListDTO.User?
    }
}
