import Foundation

/// The id fence for a SHARED, SINGLE-SLOT model value.
///
/// WHY IT IS ITS OWN TYPE rather than a line of code in each screen: `CoreBridge.metaDetails` is ONE published
/// slot on a singleton, so during A -> back -> B the previous title's meta is still resident while the new
/// page is on screen. Every screen that reads that slot has to prove the resident value belongs to it, and the
/// screens that forgot did not fail loudly: tvOS `DetailView` rendered whatever was resident, so it could PAINT
/// title A's hero, name, and synopsis under title B's route, and `movieStreamId` on both platforms read the
/// singleton around the residency guard and dispatched title A's default video id for title B.
///
/// Pure and generic on purpose: it takes the id out of the value, so the standalone gate suite can compile and
/// exercise the exact function the views call, without a SwiftUI or engine dependency.
enum ResidentMeta {

    /// The resident value, but ONLY when its own id equals the page id. Any other state (absent value, absent
    /// id, another title's id) is nil, which every caller already treats as "still loading".
    static func fenced<Meta>(_ meta: Meta?, pageID: String, id: (Meta) -> String?) -> Meta? {
        guard let meta, let residentID = id(meta), residentID == pageID else { return nil }
        return meta
    }
}

/// The ONE title-identity resolver, shared by the tvOS detail screen, the iOS/macOS detail screen, the TorBox
/// search index, the batch download coordinator, both direct-resume paths, and the Singularity source pool.
/// Pure Foundation on purpose: the standalone contract harness compiles this file, so the resolver that ships
/// is the resolver under test.
///
/// WHY THIS EXISTS AT ALL (the defect it closes): every screen used to resolve the title id INLINE, and each
/// accepted `behaviorHints.defaultVideoId` unchanged as long as it began with "tt". On a series that value is
/// routinely the EPISODE id ("tt0903747:1:1"), so the consumers then composed their own coordinates onto an id
/// that already carried some -- "tt0903747:1:1:3:5" -- which every canonical check rejects. The pool went dead
/// in BOTH directions for the title and the TorBox request path was handed an identity no IMDb-keyed index can
/// answer.
///
/// WHY THE INPUTS ARE NAMED ROLES rather than an ordered array: the previous signature was
/// `preferred(candidates: [String?])`, and the ARRAY ORDER silently chose a winner. That was unsafe:
/// `preferred(["tt0903747:1:1", "tt1375666"])` returned `tt0903747`, so an add-on-controlled episode-shaped
/// `defaultVideoId` could select a different title from the page the user opened. Roles decide which values
/// apply to each content kind, and disagreement between applicable valid IMDb heads is now an explicit mismatch.
enum SourceIndexIdentity {

    /// What the page is, which decides whether a CURRENT-VIDEO role exists at all.
    enum ContentKind: Equatable {
        case movie
        case series
        case live

        /// The engine/add-on type string, mapped conservatively: anything that is not a known series or live
        /// type is treated as a movie, which is the kind with the FEWEST identity sources (no episode video),
        /// so a mis-typed page cannot gain authority it should not have.
        static func from(type: String?, liveTypes: Set<String>) -> ContentKind {
            guard let type = type?.lowercased(), !type.isEmpty else { return .movie }
            if liveTypes.contains(type) { return .live }
            return type == "series" ? .series : .movie
        }
    }

    /// The identity inputs, by ROLE. Every field is add-on- or catalog-controlled text; none is trusted.
    struct Roles: Equatable {
        /// The id of the page/route/library row the user is actually on. It is compared with every other
        /// applicable valid IMDb head rather than silently winning a conflict.
        let catalogID: String?
        /// `meta.behaviorHints.defaultVideoId`. Add-on-controlled, frequently episode-shaped on a series.
        let defaultVideoID: String?
        /// The episode video actually selected on screen. Meaningful ONLY for `.series`.
        let currentVideoID: String?
        let kind: ContentKind

        init(catalogID: String?, defaultVideoID: String?, currentVideoID: String?, kind: ContentKind) {
            self.catalogID = catalogID
            self.defaultVideoID = defaultVideoID
            self.currentVideoID = currentVideoID
            self.kind = kind
        }

        /// The same title, re-stated for a DIFFERENT selected episode.
        ///
        /// It exists for the batch download coordinator, which holds one show-level role set and walks many
        /// episodes. That coordinator previously passed the show's `ratingsImdbID` for every episode, i.e. a
        /// default value in place of the selected current-video role, so a show whose IMDb identity lives only
        /// on its episode ids contributed under the wrong key (or under none).
        func selecting(currentVideoID: String?) -> Roles {
            Roles(catalogID: catalogID, defaultVideoID: defaultVideoID,
                  currentVideoID: currentVideoID, kind: kind)
        }
    }

    /// The resolved identity: one bare IMDb title id, no usable identity, or a conflict.
    ///
    /// It is one field, not two. It used to carry a separate `indexID` (pool) and `torBoxID` (IMDb search),
    /// because the pool accepted the tmdb namespace and the IMDb-keyed index did not. Decision REQ-260721-33
    /// made pool keys IMDb-only, so the two values are now the same value by construction. Keeping two fields
    /// that can never differ is how a caller eventually picks the wrong one.
    enum Resolved: Equatable, Sendable {
        case title(String)
        case absent
        case mismatch

        /// A canonical bare `tt...` title id, or nil when the roles are absent or disagree.
        var titleID: String? {
            guard case let .title(value) = self else { return nil }
            return value
        }
    }

    /// One exact target shared by auxiliary transport, publication, merge, rank, and download assembly.
    ///
    /// SEALED STORAGE, and WHY THIS EXACT SHAPE. The previous form kept the four fields as `internal` stored
    /// `let`s behind a `fileprivate init`, and asserted in a comment that module peers "cannot forge unrelated
    /// fields". That was FALSE: under SE-0189 an extension IN THE SAME MODULE (which is every file of the app
    /// target) may declare its own initializer that initializes the stored properties DIRECTLY, without ever
    /// touching the fileprivate init. A same-module fixture did exactly that and printed
    /// `FORGED pair: titleID=tt0000001 contentID=tt9999999:9:9` -- an identity pair that never passed the
    /// resolver. `internal` is not a boundary inside one module; only visibility of the STORED state is.
    ///
    /// The tools that actually hold, and the one chosen:
    ///   - `private` stored properties are FILE-scoped: visible to this type and its extensions in THIS file
    ///     only. An extension in any other file cannot assign them, so the SE-0189 direct-initialization route
    ///     dies at the declaration: there is no visible stored property left to initialize.
    ///   - The storage is additionally a NESTED `private struct Storage` behind ONE private stored property.
    ///     A cross-file extension then cannot even NAME the storage type, so the forge is a compile error in
    ///     both spellings: assigning the old field names hits get-only computed properties, and assigning
    ///     `self.storage` hits `'storage' is inaccessible due to 'private' protection level`.
    ///   - The explicit `fileprivate init` also suppresses the synthesized memberwise init, so there is no
    ///     third construction route to audit.
    /// The declaring FILE is therefore the entire trusted base for construction, which is exactly the reviewable
    /// surface the diagnostics closure in this file already relies on. The standalone lifecycle suite compiles
    /// the forging extension both ways and pins the literal rejection, and re-widens a COPY of this file to
    /// prove the fixture compiles again the moment `private` is dropped (a guard that cannot be shown to fail
    /// is not verified).
    struct PublicationTarget: Equatable, Hashable, Sendable {
        private struct Storage: Equatable, Hashable, Sendable {
            let titleID: String
            let contentID: String
            let season: Int?
            let episode: Int?
        }

        private let storage: Storage

        var titleID: String { storage.titleID }
        var contentID: String { storage.contentID }
        var season: Int? { storage.season }
        var episode: Int? { storage.episode }

        /// Construction stays in this file so every target originates from the role resolver and tuple-exact
        /// content-key composer below. Module peers can inspect a target, but cannot construct or forge one.
        fileprivate init(titleID: String, contentID: String, season: Int?, episode: Int?) {
            storage = Storage(titleID: titleID, contentID: contentID, season: season, episode: episode)
        }
    }

    /// A typed, validated permission to merge ONE auxiliary source's published rows into a page's source list.
    ///
    /// WHY THIS EXISTS: `SourceListModel` -- the main merge path every detail screen renders from -- used to
    /// gate the TorBox and Singularity merges on a hand-rolled comparison of two raw `String?` content ids and
    /// then call the identity-free static merges directly, outside the typed capability entirely. This value is
    /// the only way to open those merges now. It can only be built here, from a sealed `PublicationTarget` that
    /// the SOURCE published (itself constructible only from the role resolver), so no raw string can authorize
    /// a merge and no identifier can enter the merge path unvalidated.
    struct MergeAuthorization: Equatable, Sendable {
        private let storedTarget: PublicationTarget

        /// The published target the merge was authorized against, for consumers that need the coordinates.
        var target: PublicationTarget { storedTarget }

        /// Same sealing rationale as `PublicationTarget.storage`: `private` storage plus a `fileprivate` init
        /// keeps a same-module extension from synthesizing an authorization for a page the source never
        /// published (which would re-open the stale-episode merge this fence exists to stop).
        fileprivate init(target: PublicationTarget) {
            storedTarget = target
        }
    }

    /// The ONLY factory for `MergeAuthorization`. `published` is the sealed target the auxiliary source
    /// actually fetched and published for; `page` is the page's OWN typed resolution, the same value every
    /// screen computes via `publicationTarget(_:)`. Both sides re-validate through `validatedTarget` and the
    /// canonical content ids must match byte for byte; in every other case (absent, mismatch, stale, forged)
    /// there is no authorization and the merge is a pass-through.
    ///
    /// THE PAGE SIDE IS SEALED TOO, and that is the point of this signature. The previous factory took
    /// `pageContentID: String?`, and every view immediately FLATTENED its resolved `TargetResolution` to
    /// `.target?.contentID` just to feed it -- which kept one public raw-string route into the merge gate:
    /// any module peer holding a matching string could open a merge without ever running the role resolver.
    /// Requiring the resolution closes that route (a `.target` payload has no ordinary construction route
    /// outside this file; the memory-safety opt-outs noted on `MediaServerTarget` are the one exclusion),
    /// and the page still can only SELECT: the authorization carries the published target, never anything
    /// derived from the page beyond the byte comparison.
    static func mergeAuthorization(
        published: PublicationTarget?,
        page: TargetResolution
    ) -> MergeAuthorization? {
        guard let published,
              let validPublished = validatedTarget(.target(published)),
              let validPage = validatedTarget(page),
              validPublished.contentID == validPage.contentID else { return nil }
        return MergeAuthorization(target: validPublished)
    }

    /// The typed result of resolving a publication target. `mismatch` must remain distinguishable from an
    /// ordinary title with no IMDb identity so tests can pin the conflicting-head failure contract.
    enum TargetResolution: Equatable, Sendable {
        case target(PublicationTarget)
        case absent
        case mismatch

        var target: PublicationTarget? {
            guard case let .target(value) = self else { return nil }
            return value
        }
    }

    // MARK: Media-server identity (the deliberately non-IMDb lane)

    /// The sealed page identity for the media-server lane (Plex / Jellyfin / Emby direct play).
    ///
    /// WHY A SECOND SEALED TYPE rather than reusing `PublicationTarget`: media-server lookup also supports
    /// IMDb-LESS title/year matching, so its page identity is deliberately broader than the canonical IMDb
    /// contract `PublicationTarget` exists to enforce. Widening `PublicationTarget` to admit `meta:` tokens
    /// would break the one invariant every other consumer of it relies on. Instead the media lane gets its
    /// own sealed value whose token is either the canonical content id (IMDb pages, derived VERBATIM from a
    /// validated resolution) or a `meta:<id>` / `meta:<id>|video:<id>` fallback FORMATTED BY THIS FILE. The
    /// two namespaces cannot collide: a canonical content id always begins `tt`, never `meta:`.
    ///
    /// INJECTIVITY (distinct pages -> distinct tokens), stated at the grain that actually holds. The
    /// STRUCTURAL argument: the canonical form is `tt<digits>[:<s>:<e>]` -- no `|`, never `meta:`-prefixed
    /// -- and the fallback form always begins `meta:` with every part passed through
    /// `mediaServerFallbackPart`, which REJECTS the `|` separator. So the canonical and fallback namespaces
    /// are disjoint, a one-part fallback token contains no `|` while a two-part token contains exactly one,
    /// and within each form the parts recover uniquely. That argument survives Unicode normalization,
    /// because `|` (U+007C) has no canonical decomposition and no other scalar's canonical decomposition
    /// contains it (checked exhaustively against this toolchain's Unicode tables), so canonical equivalence
    /// can neither create nor consume a separator.
    ///
    /// THE GRAIN: the encoding is injective UP TO Swift `String` equality, which is Unicode CANONICAL
    /// EQUIVALENCE, not byte equality. `mediaServerTarget(metaID: "caf\u{00E9}")` (5 UTF-8 bytes) and
    /// `mediaServerTarget(metaID: "cafe\u{0301}")` (6 bytes) format tokens that compare `==`, and
    /// `mediaServerMergeAuthorization` between them authorizes. That is the correct grain rather than a
    /// leak: Swift `==` is the comparison every consumer of these tokens uses -- the merge gate below,
    /// `MediaServerSource`'s `shownKey`/`fetchKey` comparisons, and its `[String: ...]` session cache all
    /// fold canonically equivalent spellings the same way, so such spellings behave as ONE page end to end
    /// (one fetch, one cache entry, one merge identity), while two pages distinct under `==` compose
    /// fetchKeys that miss each other's cache. COMPATIBILITY equivalence does NOT fold ("\u{FB01}le" !=
    /// "file"), so no wider NFKC-style collapse hides behind this. Injectivity was overclaimed twice here:
    /// the encoding was not injective at all before the separator gate (sealing decides WHO can build a
    /// token; injectivity decides whether two DIFFERENT pages can build the SAME one, and the encoding
    /// previously guaranteed only the first), and a later revision then claimed distinct (metaID, videoID)
    /// statements could "never format the same token" -- byte-level injectivity, which Swift `String`
    /// comparison never offered.
    ///
    /// SEALED exactly like `PublicationTarget`, for the same reproduced reason (see that type's comment for
    /// the SE-0189 forge this shape kills): the token lives in a nested `private struct Storage` behind ONE
    /// private stored property, the public `token` is a get-only computed view, and the explicit
    /// `fileprivate init` suppresses the synthesized memberwise init. What that covers, precisely: every
    /// ORDINARY construction route outside this file is a compile error -- a same-module extension can
    /// neither assign `token` (get-only), nor name `Storage` (private is file-scoped), nor call the init,
    /// and there is no synthesized memberwise init left to call. What it does NOT cover: deliberate
    /// memory-safety opt-outs (`unsafeBitCast`, `withUnsafeMutableBytes` pointer writes) can still conjure
    /// the bit pattern of any Swift value type; that route is out of scope here exactly as it is for
    /// `PublicationTarget`, because code that has opted out of memory safety is outside any type-level
    /// boundary's threat model. The lifecycle suite compiles the forging extension in both spellings,
    /// pins the literal rejections, and re-widens a COPY of this file to prove each fixture compiles again
    /// (a guard that cannot be shown to fail is not verified).
    ///
    /// THE OUTER EDGE OF WHAT THE SEAL BUYS: it governs which token SHAPES can exist, not who may claim to
    /// BE a page. `publicationTarget(_:)` is internal and takes plain `Roles` (add-on/catalog-controlled
    /// text), so any module peer can state the roles of a page it merely names, derive that page's
    /// canonical `MediaServerTarget` (or `PublicationTarget`) through the ordinary factories, and two
    /// peer-minted equal tokens authorize each other through the merge factories below. That is by design,
    /// and consistent with the merge-authorization contract above (the page side can only SELECT what a
    /// source published; it cannot inject rows): the seal guarantees every token was FORMATTED OR DERIVED
    /// by this file from stated roles -- well-formed, bounded, separator-free -- not that the stating
    /// caller is the screen the user is looking at. The seal does not authenticate its caller.
    struct MediaServerTarget: Equatable, Hashable, Sendable {
        private struct Storage: Equatable, Hashable, Sendable {
            let token: String
        }

        private let storage: Storage

        /// The exact page token the media-server source keys and compares on.
        var token: String { storage.token }

        fileprivate init(token: String) {
            storage = Storage(token: token)
        }
    }

    /// The IMDb path: derive the media-server token from the page's own typed resolution, so an IMDb page's
    /// token is the canonical content id VERBATIM (re-validated through `validatedTarget`, like every other
    /// consumer of a resolution at an owner boundary). `.absent` and `.mismatch` yield nil.
    static func mediaServerTarget(page: TargetResolution) -> MediaServerTarget? {
        guard let target = validatedTarget(page) else { return nil }
        return MediaServerTarget(token: target.contentID)
    }

    /// The IMDb-less fallback: the caller states the raw PARTS (the page's meta id, plus the shown video id
    /// when the page is episode-scoped) and THIS FILE formats the token, so the shape of every fallback
    /// token is decided here, reviewably -- a caller can never hand over a pre-baked token string. The parts
    /// are add-on-controlled text, so every part passes `mediaServerFallbackPart` (ONE gate: the shared
    /// 128-byte identity cap AND rejection of the `|` token separator), and an unusable part fails the WHOLE
    /// target rather than being dropped: silently dropping a bad video part would widen an episode page's
    /// identity to the whole title.
    ///
    /// SCOPE EDGE (deliberate, and slightly wider than the collision fix): `boundedIdentityInput` also
    /// rejects the EMPTY string, so an IMDb-less page whose meta id is "" gets NO media-server target at
    /// all (an empty metaID fails before videoID is even considered) -- the owner's `refresh` then clears,
    /// darkening the media-server lane for that page entirely, title/year fallback included. The pre-lane
    /// code published such a page under a degenerate `"meta:"` token (the iOS movie page composed
    /// `sourceContentID ?? "meta:\(id)"`) and still fetched by title. Fail-closed and effectively
    /// unreachable, but it is a real feature delta that predates FIX-1's separator gate, not a
    /// consequence of it.
    static func mediaServerTarget(metaID: String?, videoID: String? = nil) -> MediaServerTarget? {
        guard let meta = mediaServerFallbackPart(metaID) else { return nil }
        guard let videoID else { return MediaServerTarget(token: "meta:\(meta)") }
        guard let video = mediaServerFallbackPart(videoID) else { return nil }
        return MediaServerTarget(token: "meta:\(meta)|video:\(video)")
    }

    /// The ONE gate every fallback part passes before it is formatted into a token: the same 128-byte cap
    /// every identity candidate gets, AND rejection of the `|` separator, together in one helper so a future
    /// third part cannot apply one and forget the other.
    ///
    /// `|` is REJECTED, not escaped, and the choice is load-bearing:
    ///  (a) INJECTIVITY BY CONSTRUCTION, not convention. Without this gate the encoding was not injective:
    ///      `mediaServerTarget(metaID: "kitsu:42|video:kitsu:42:7")` (a movie page, metaID only) and
    ///      `mediaServerTarget(metaID: "kitsu:42", videoID: "kitsu:42:7")` (an episode page) formatted the
    ///      byte-identical token, so `mediaServerMergeAuthorization` authorized merging one page's
    ///      direct-play rows into the other -- and meta ids are add-on/catalog-controlled text. With `|`
    ///      excluded from every part, a one-part token contains no `|` and a two-part token contains exactly
    ///      one, so `meta:A` can never equal `meta:A'|video:B'`, the two forms are provably distinguishable,
    ///      and each token recovers its parts uniquely.
    ///  (b) Rejecting is how this file already resolves ambiguity: `contentKey` REJECTS a partial coordinate
    ///      pair instead of silently widening it.
    ///  (c) A `|` inside a real meta/video id is pathological. Failing closed costs at most the media-server
    ///      lane on one degenerate page; failing open costs a cross-page merge of the user's own files.
    private static func mediaServerFallbackPart(_ raw: String?) -> String? {
        guard let part = boundedIdentityInput(raw), !part.contains("|") else { return nil }
        return part
    }

    /// What every detail screen actually wants, as ONE call: the typed page target when the page resolved
    /// one, else the formatted fallback parts (media-server lookup is the one lane that legitimately serves
    /// IMDb-less pages, so `.absent`/`.mismatch` fall through instead of killing the lane).
    static func mediaServerTarget(
        preferring page: TargetResolution,
        metaID: String?,
        videoID: String? = nil
    ) -> MediaServerTarget? {
        mediaServerTarget(page: page) ?? mediaServerTarget(metaID: metaID, videoID: videoID)
    }

    /// A typed, validated permission to merge the media-server source's published rows into a page's source
    /// list -- the media-lane analog of `MergeAuthorization`, closing the last raw-token comparison on the
    /// main merge path. Same sealing rationale as `MergeAuthorization`: `private` storage plus a
    /// `fileprivate` init keeps a same-module extension from synthesizing a permission for a page the source
    /// never published. `Sendable` because `SourceListModel` builds it in the main-actor snapshot and
    /// captures it into the detached assembly.
    struct MediaServerMergeAuthorization: Equatable, Sendable {
        private let storedTarget: MediaServerTarget

        /// The published target the merge was authorized against.
        var target: MediaServerTarget { storedTarget }

        fileprivate init(target: MediaServerTarget) {
            storedTarget = target
        }
    }

    /// The ONLY factory for `MediaServerMergeAuthorization`. Both sides are sealed values with no ordinary
    /// construction route outside this file's factories -- `published` built by the source when it resolved,
    /// `page` by the screen's computed var -- so the equality below is between two tokens this file
    /// formatted or derived. The comparison is Swift `String` equality (Unicode canonical equivalence, the
    /// same grain as every other consumer of these tokens; see the INJECTIVITY note on `MediaServerTarget`).
    /// Authorization exists exactly when the tokens compare equal, and it carries the PUBLISHED target only.
    static func mediaServerMergeAuthorization(
        published: MediaServerTarget?,
        page: MediaServerTarget?
    ) -> MediaServerMergeAuthorization? {
        guard let published, let page, published.token == page.token else { return nil }
        return MediaServerMergeAuthorization(target: published)
    }

    /// Identity inputs are add-on-controlled text. Cap BEFORE any parsing so a megabyte-long "id" cannot be
    /// regex-scanned, and so nothing unbounded can reach a diagnostic length count. Real ids are ~20 bytes.
    static let maxIdentityInputBytes = 128

    /// Resolve the title identity from named roles.
    ///
    /// ROLE ORDER is used only to select the representative when every valid IMDb head agrees: catalog, then
    /// default-video, then current-video. If any two valid heads differ, return `.mismatch`. Choosing a winner
    /// could attach auxiliary rows for one title to engine rows for another. `.movie` and `.live` have no
    /// episode, so `currentVideoID` is ignored entirely for them.
    ///
    /// PRESERVED FIELD CASE (do not "simplify" this away): a TMDB- or Kitsu-identified SERIES ("tmdb:94997")
    /// with no `defaultVideoId` carries its IMDb identity ONLY on the episode video id ("tt0460649:3:6"). The
    /// catalog role there yields no IMDb id, so the current-video role legitimately supplies the identity.
    static func resolve(_ roles: Roles) -> Resolved {
        let ordered: [String?] = roles.kind == .series
            ? [roles.catalogID, roles.defaultVideoID, roles.currentVideoID]
            : [roles.catalogID, roles.defaultVideoID]
        let titles = ordered.compactMap(imdbTitleID)
        guard let first = titles.first else { return .absent }
        guard titles.dropFirst().allSatisfy({ $0 == first }) else { return .mismatch }
        return .title(first)
    }

    /// Accept ONE already-resolved value at a module boundary and hand back a bare canonical IMDb title id.
    ///
    /// This is a VALIDATOR, not a resolver: it ranks nothing and cannot choose between roles. It exists so a
    /// shared consumer that is handed a single id (TorBox search, whose whole request shape is `imdb_id:<v>`)
    /// re-checks the value it was given instead of trusting a `hasPrefix("tt")` test, which admitted the
    /// episode-scoped form "tt0903747:1:1" and produced a key no IMDb index can answer.
    static func imdbTitleID(_ raw: String?) -> String? {
        guard let bounded = boundedIdentityInput(raw),
              let title = SourceIndexContract.canonicalTitleID(bounded),
              title.hasPrefix("tt") else { return nil }
        return title
    }

    /// The forced auxiliary entry point for a page or batch job.
    ///
    /// A producer states its roles and coordinates once and receives one typed target. Conflicts stay typed,
    /// while missing identity or invalid coordinates are unavailable. Every governed producer consumes this
    /// result directly, and merge boundaries compare the target with the owner's fetched publication token.
    static func publicationTarget(
        _ roles: Roles,
        season: Int? = nil,
        episode: Int? = nil
    ) -> TargetResolution {
        switch resolve(roles) {
        case let .title(titleID):
            guard let contentID = contentKey(titleID: titleID, season: season, episode: episode) else {
                return .absent
            }
            return .target(PublicationTarget(
                titleID: titleID,
                contentID: contentID,
                season: season,
                episode: episode
            ))
        case .absent:
            return .absent
        case .mismatch:
            return .mismatch
        }
    }

    /// Re-check every relationship inside an already-resolved target at an owner boundary. This is deliberately
    /// fail-soft: a malformed or forged value behaves exactly like an absent target, with no fetch or publish.
    static func validatedTarget(_ resolution: TargetResolution) -> PublicationTarget? {
        guard let target = resolution.target,
              imdbTitleID(target.titleID) == target.titleID,
              contentKey(titleID: target.titleID, season: target.season, episode: target.episode)
                == target.contentID else { return nil }
        return target
    }

    #if SOURCE_INDEX_IDENTITY_TESTING
    /// Test-only adversarial seam. Production cannot construct this shape; boundary suites use it to prove both
    /// owners still reject a relational mismatch if one is introduced inside the module in a future refactor.
    static func uncheckedTargetForTesting(
        titleID: String,
        contentID: String,
        season: Int?,
        episode: Int?
    ) -> TargetResolution {
        .target(PublicationTarget(
            titleID: titleID,
            contentID: contentID,
            season: season,
            episode: episode
        ))
    }
    #endif

    /// The pool key for a Continue-Watching DIRECT RESUME, which is the one path with TWO independent ids and
    /// no page to arbitrate between them.
    ///
    /// THE DEFECT THIS CLOSES: both direct-resume paths built the key from the Continue-Watching item id while
    /// polling assembled groups by the STORED entry's `videoId`, and their only guard compared episode NUMBERS.
    /// Worked example: item `tt1375666` (a movie) with a stored video `tt0903747:1:1` published Game-of-Thrones
    /// groups under `tt1375666:1:1`. Comparing canonical TITLE HEADS is the check that catches it; comparing
    /// coordinates never could, because the coordinates matched.
    ///
    /// Returns nil on ANY mismatch, which means "make no SourceIndex contribution". It must never be used to
    /// gate playback: the user's local resume runs on a head mismatch exactly as before.
    static func resumeKey(itemID: String?, videoID: String?, season: Int?, episode: Int?) -> String? {
        guard let boundedItem = boundedIdentityInput(itemID),
              let itemHead = SourceIndexContract.canonicalTitleID(boundedItem) else { return nil }
        // A resume with no stored video id (movies) has nothing to disagree with, so the item head stands alone.
        if let videoID, !videoID.isEmpty {
            guard let boundedVideo = boundedIdentityInput(videoID),
                  let videoHead = SourceIndexContract.canonicalTitleID(boundedVideo),
                  videoHead == itemHead else { return nil }
        }
        return contentKey(titleID: itemHead, season: season, episode: episode)
    }

    /// Length gate applied to every identity candidate before it is parsed or measured.
    static func boundedIdentityInput(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= maxIdentityInputBytes else { return nil }
        return raw
    }

    /// Compose the episode-scoped content key from an already-resolved title id. TUPLE-EXACT by contract.
    ///
    /// A PARTIAL coordinate pair is REJECTED, not silently widened. The previous rule returned the bare title
    /// whenever either coordinate was absent, so an episode context that had resolved a season but not yet an
    /// episode contributed its episode-specific sources under the SHOW-wide key and read show-wide sources
    /// back -- mixing every episode's sources into one bucket. A caller that genuinely wants the show-wide key
    /// passes neither coordinate, which is still valid and still returns the bare title.
    ///
    /// Season ZERO and episode ZERO are both VALID and distinct from absence (specials air as S00Exx, and an
    /// add-on may legitimately number a special E0), so this tests presence, never truthiness.
    ///
    /// EVERY branch returns through `canonicalContentID`, so the IMDb-only key rule holds even for the bare
    /// title case. Returning `title` directly there is what previously let a tmdb head out as a pool key.
    fileprivate static func contentKey(titleID: String, season: Int?, episode: Int?) -> String? {
        guard let title = SourceIndexContract.canonicalTitleID(titleID) else { return nil }
        switch (season, episode) {
        case (nil, nil):
            return SourceIndexContract.canonicalContentID(title)
        case let (season?, episode?):
            return SourceIndexContract.canonicalContentID("\(title):\(season):\(episode)")
        default:
            return nil
        }
    }

    #if SOURCE_INDEX_IDENTITY_TESTING
    static func contentKeyForTesting(titleID: String, season: Int?, episode: Int?) -> String? {
        contentKey(titleID: titleID, season: season, episode: episode)
    }
    #endif
}

/// Bounded, category-only diagnostics for the source-index client.
///
/// WHY (privacy, load-bearing): these lines land in the persistent diag log that the USER EXPORTS AND SHARES
/// PUBLICLY when reporting a problem. The previous lines interpolated raw catalog ids ("tt0903747:3:5" IS
/// viewing history), raw REJECTED identifiers straight out of add-on-controlled text (arbitrary length, may
/// embed URL tokens or newlines that forge extra log lines), and account/consent state. None of that survives
/// contact with a public paste.
///
/// The diagnostics still have to answer the question they were added for -- "why did contribution go silent?"
/// -- so nothing is dropped except the VALUES: every bail path keeps its own `Reason` case, and the counts
/// that made a line actionable stay as counts.
///
/// EVERY string that can reach a line comes from a CLOSED enum in this file: the event label (`Event`), the
/// bail reason (`Reason`), the pool outcome (`Outcome`), and each count's KEY (`Count`). Only the count VALUES
/// are caller-supplied, and they are `Int`.
///
/// That closure is the whole point, and it was previously OVERCLAIMED. The builder used to take
/// `event: String` and `[(String, Int)]`, and the comment on the client's `diag` wrapper asserted that a raw
/// identifier "cannot be interpolated back in without changing this type". It could: a call that appended a
/// raw identifier onto the event label compiled cleanly, and so did a count whose KEY was an interpolated
/// identifier. The claim is now TRUE by construction rather than by convention: no `String` parameter is left
/// on the builder, so a call site that wants to say something new has to add a case to an enum here, which is
/// a reviewable diff in the file that documents why a value must never ride along.
///
/// The one thing this closure does NOT constrain is a count VALUE, which is an `Int` by type. An `Int` derived
/// from an identifier still leaks a little (a length is a weak fingerprint), which is why `identityLength`
/// below is capped and sentinel-bucketed rather than a raw measurement.
enum SourceIndexDiag {

    /// The closed set of event labels. One case per emitting site (or per group of sites that genuinely
    /// describe the same moment), so `Event` doubles as the index of everything this client can say.
    enum Event: String {
        case contentIDSkip = "contentID SKIP"
        case contributeSkip = "contribute SKIP"
        case contributeBegin = "contribute BEGIN"
        case contributePost = "contribute POST"
        case contributePostResult = "contribute POST RESULT"
        case contributeStop = "contribute STOP"
        case fetchPooledSkip = "fetchPooled SKIP"
        case fetchPooledGate = "fetchPooled GATE"
        case fetchPooledGateClosed = "fetchPooled GATE CLOSED"
        case fetchPooledGet = "fetchPooled GET"
        case fetchPooledHTTP = "fetchPooled HTTP"
        case fetchPooledHTTPOK = "fetchPooled HTTP OK"
        case streamsReconstruct = "streams reconstruct"
        case refreshPublish = "refresh publish"
        case refreshPublishSkipped = "refresh publish SKIPPED"
    }

    /// The closed set of count KEYS. Values are counts and bounded lengths; a key can never be an interpolated
    /// identifier because it is not a `String` at the call site.
    enum Count: String {
        case rawLen
        case contentLen
        case hasSeason
        case hasEpisode
        case candidates
        case uploadable
        case batch
        case batches
        case descriptors
        case succeeded
        case edgeSigned
        case moatToken
        case status
        case corroboratedSources
        case code
        case pooled
        case playable
        case built
        case streams
    }

    /// One case per bail path. Distinctness is the requirement: two paths sharing a reason is the same
    /// diagnostic blindness the raw-id logging was added to cure.
    enum Reason: String {
        case notATitleID = "not-a-title-id"
        case nonCanonicalEpisodeKey = "non-canonical-episode-key"
        /// A direct resume whose library item id and stored video id name DIFFERENT titles. The pool
        /// contribution is skipped; the user's own local resume is unaffected. Distinct from
        /// `notATitleID` because the inputs here are each individually well-formed.
        case resumeIdentityMismatch = "resume-identity-mismatch"
        /// The RemoteConfig fleet kill switch is off. This is SERVER-SIDE CONFIG, not user data: it states
        /// what WE did to everyone, so it is safe to name and is usually the entire support answer.
        case fleetOff = "fleet-off"
        /// The other half of the old combined `gate-off`: the fleet flag is ON, so the user-level give-to-get
        /// gate is the one that is shut.
        ///
        /// STATED PLAINLY rather than left as an unnoticed side effect: because `fleetOff` is now carved out,
        /// this case is inferable as "this user opted out". That is accepted, for two reasons. The consent
        /// VALUE is still never printed, and this log is opt-in and exported BY the user, whose own Settings
        /// screen already states the same fact in plain words. The alternative (one reason covering both) is
        /// exactly what left a support reader unable to tell a fleet-wide disable from a personal opt-out.
        case gateOff = "gate-off"
        case nonCanonicalContentID = "non-canonical-content-id"
        case nothingUploadable = "nothing-uploadable"
        case alreadyClaimed = "already-claimed"
        case bodyEncodingFailed = "body-encoding-failed"
        case cancelled = "cancelled"
        case postFailed = "post-failed"
        case gateClosed = "gate-closed"
        case gateChangedOrNoMoat = "gate-changed-or-no-moat"
        case gateClosedBeforeTransport = "gate-closed-before-transport"
        case gateClosedAfterTransport = "gate-closed-after-transport"
        case httpNon2xx = "http-non-2xx"
        case httpError = "http-error"
        case staleOrCancelled = "stale-or-cancelled"
        case malformedServeURL = "malformed-serve-url"
    }

    /// The CLOSED client-side reading of the worker's `reason` field on a 200 response.
    ///
    /// WHY THIS EXISTS: the worker `reason` was dropped from the log entirely on privacy grounds, and the
    /// justification given for dropping it ("the row count already distinguishes an empty login_required read
    /// from a real empty pool") is provably false -- both bodies decode to zero rows, so both produced the
    /// byte-identical line `fetchPooled HTTP OK status=200 corroboratedSources=0`. SERVE is deliberately
    /// login-gated by owner decision, which makes `login_required` the single most common correct explanation
    /// for an empty pool, and it was the one thing the line could no longer say.
    ///
    /// The privacy concern behind the removal was real: `reason` is server-authored text, and echoing it puts
    /// free text from the network into an exported log. Mapping it through this enum keeps both properties.
    /// Only values spelled here can ever be printed; anything else, however long or hostile, prints `other`.
    enum Outcome: String {
        /// No `reason` key in the body at all.
        case absent = "absent"
        case ok = "ok"
        /// The documented empty read for a caller with no VortX session (see the SERVE login gate).
        case loginRequired = "login-required"
        /// Present, but not one of the spellings above.
        case other = "other"

        /// Map the wire value. Underscore and hyphen spellings fold together and case is ignored, so a purely
        /// cosmetic worker change degrades to `other` instead of silently landing on the wrong case.
        init(worker raw: String?) {
            guard let raw else { self = .absent; return }
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "ok": self = .ok
            case "login-required": self = .loginRequired
            default: self = .other
            }
        }
    }

    /// A random per-process token stamped on every line, so one exported log's lines can still be correlated
    /// with each other. It identifies a RUN, never a user or a title, and does not survive a relaunch.
    static let correlation: String = String(format: "%08x", UInt32.random(in: 0...UInt32.max))

    /// Build one bounded line. Every textual part is an enum raw value; `counts` carries counts and bounded
    /// LENGTHS only, never a value.
    static func line(
        _ event: Event,
        reason: Reason? = nil,
        outcome: Outcome? = nil,
        counts: [(Count, Int)] = []
    ) -> String {
        var parts = ["run=\(correlation)", event.rawValue]
        if let reason { parts.append("reason=\(reason.rawValue)") }
        if let outcome { parts.append("outcome=\(outcome.rawValue)") }
        for (key, value) in counts { parts.append("\(key.rawValue)=\(value)") }
        return parts.joined(separator: " ")
    }

    /// Sentinel for an identity that was nil.
    static let identityLengthAbsent = 0
    /// Sentinel for an identity that was present but EMPTY.
    static let identityLengthEmpty = -1
    /// Sentinel for an identity that exceeded `SourceIndexIdentity.maxIdentityInputBytes`.
    static let identityLengthOverCap = -2

    /// The permitted way to describe an identity in a log line: how long it was, never what it said. Applied
    /// AFTER the same input cap the parser uses, so a hostile unbounded value cannot even inflate a number:
    /// an over-cap input reports the fixed sentinel, never its own size.
    ///
    /// THREE conditions, THREE values. They used to be three conditions mapped onto two (nil -> 0, empty ->
    /// -1, over-cap -> -1), which threw away a real triage signal: "the add-on sent nothing" and "the add-on
    /// sent 105 KB" are completely different bugs and were indistinguishable in the exported log.
    static func identityLength(_ raw: String?) -> Int {
        guard let raw else { return identityLengthAbsent }
        if raw.isEmpty { return identityLengthEmpty }
        guard let bounded = SourceIndexIdentity.boundedIdentityInput(raw) else { return identityLengthOverCap }
        return bounded.utf8.count
    }
}
