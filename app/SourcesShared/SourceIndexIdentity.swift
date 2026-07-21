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
    struct PublicationTarget: Equatable, Hashable, Sendable {
        let titleID: String
        let contentID: String
        let season: Int?
        let episode: Int?

        /// Construction stays in this file so every target originates from the role resolver and tuple-exact
        /// content-key composer below. Module peers can inspect a target, but cannot forge unrelated fields.
        fileprivate init(titleID: String, contentID: String, season: Int?, episode: Int?) {
            self.titleID = titleID
            self.contentID = contentID
            self.season = season
            self.episode = episode
        }
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
