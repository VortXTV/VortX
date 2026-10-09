import Foundation

@main
@MainActor
struct ContinueWatchingServiceTests {
    static var checks = 0
    static var failures: [String] = []
    static let profileA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let profileB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let session = SIMKLSessionID(rawValue: "inert-simkl-A")
    static let watching = #"{"shows":[{"status":"watching","last_watched_at":"2026-10-08T12:00:00Z","next_to_watch":"S02E04","show":{"title":"Fixture show","ids":{"simkl":10,"imdb":"tt100","tmdb":42}}}]}"#
    static let paused = #"[{"progress":42.5,"paused_at":"2026-10-09T12:00:00Z","episode":{"season":2,"number":3},"show":{"title":"Fixture show","ids":{"simkl":10,"imdb":"tt100","tmdb":42}}}]"#
    static func require(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1; if !value() { failures.append(label) }
    }
    static func configure(source: String = "simkl", window: String = "20", eligible: Bool = true) {
        UserDefaults.standard.reset()
        UserDefaults.standard.set(source, forKey: ContinueWatchingPreferences.sourceKey)
        UserDefaults.standard.set(window, forKey: ContinueWatchingPreferences.windowKey)
        ProfileStore.shared.activeID = profileA; ProfileStore.shared.activeUsesEngineHistory = eligible
        ProfileStore.shared.active = UserProfile(id: profileA, usesEngineHistory: eligible,
            discovery: .init(continueWatchingSource: source, continueWatchingWindow: window))
        let credential = CredentialScopeRegistry.Capture(namespace: "inert-account", generation: 1)
        CoreBridge.shared.nativeBinding = .init(profileID: profileA, credential: credential,
            sessionGeneration: UUID(), accountGeneration: UUID())
        CoreBridge.shared.usesNativeProfileState = true
        CoreBridge.shared.continueWatching = [.init(id: "local", type: "movie", name: "Local",
            poster: nil, state: .init(timeOffset: 10_000, duration: 100_000, videoId: nil))]
        SIMKLAuth.storedSessionID = session; SIMKLAuth.isConfigured = true
    }
    static func responses(stamp: String = "2026-10-09T12:00:00Z", shows: String? = nil,
                          playback: String? = nil, removed: String? = nil) -> [String: String] {
        let removedField = removed.map { ",\"removed_from_list\":\"\($0)\"" } ?? ""
        return ["/sync/activities": "{\"all\":\"\(stamp)\",\"tv_shows\":{\"all\":\"\(stamp)\",\"playback\":\"\(stamp)\"\(removedField)}}",
                "/sync/all-items/movies": "", "/sync/all-items/shows": shows ?? watching,
                "/sync/all-items/anime": "", "/sync/playback": playback ?? paused]
    }
    static func main() async throws {
        configure()
        #if CW_SERVICE_BASELINE
        let old = BaselineServiceSelection.current(core: .shared, profiles: .shared)
        require(old.selection.source.rawValue == "simkl", "actual parent selector supports selected SIMKL")
        #else
        try portablePreferencesAndWindows()
        try foldSemantics()
        await readerTransactions()
        try await httpReadAuthority()
        await selectorAndEpochs()
        await sourceOnlyCardsAndAdmission()
        pickerBindingEpochsAndWiring()
        traktPublicationEpochs()
        await nativeMigration()
        legacySourceMethodWindow()
        #endif
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: \(checks) inert production CW service/window/fold/reader/migration checks")
    }
    static func portablePreferencesAndWindows() throws {
        let defaults = UserDefaults()
        defaults.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        ProfileDiscoveryPreferencesStore.apply(nil, resetUnset: true, to: defaults)
        require(ContinueWatchingPreferences.current(defaults) == .init(source: .local, window: .twenty), "new profile defaults Local20")
        require(!defaults.bool(forKey: ExternalSyncToggle.traktContinueWatching), "real switch clears legacy mirror")
        let a = ProfileDiscoveryPreferences(continueWatchingSource: "simkl", continueWatchingWindow: "last90Days")
        ProfileDiscoveryPreferencesStore.apply(a, resetUnset: true, to: defaults)
        let captured = ProfileDiscoveryPreferencesStore.capture(from: defaults)
        let decoded = try JSONDecoder().decode(ProfileDiscoveryPreferences.self, from: JSONEncoder().encode(captured))
        require(decoded == captured && decoded.continueWatchingSource == "simkl", "actual portable DTO round-trips source and window")
        ProfileDiscoveryPreferencesStore.apply(nil, resetUnset: true, to: defaults)
        ProfileDiscoveryPreferencesStore.apply(decoded, resetUnset: true, to: defaults)
        require(ContinueWatchingPreferences.current(defaults) == .init(source: .simkl, window: .last90Days), "A-B-A restores each actual captured choice")
        ProfileDiscoveryPreferencesStore.apply(.init(continueWatchingSource: "invalid", continueWatchingWindow: "999"), resetUnset: true, to: defaults)
        require(!ContinueWatchingPreferences.current(defaults).isSupported, "unknown portable source fails unavailable, not disguised Local")
        require(ProfileDiscoveryPreferencesStore.activeProjectionKeys.contains(ContinueWatchingPreferences.sourceKey)
            && ProfileDiscoveryPreferencesStore.activeProjectionKeys.contains(ContinueWatchingPreferences.windowKey), "native/sync allowlist owns both active projection keys")
        let now = ContinueWatchingPreferences.activity("2026-10-09T00:00:00Z")!
        let rows: [(String, String?)] = [("unknown", nil), ("old", "2026-07-10T23:59:59Z"),
            ("boundary", "2026-07-11T00:00:00Z"), ("new", "2026-10-09T00:00:00Z"), ("future", "2026-10-10T00:00:00Z")]
        let dated = ContinueWatchingPreferences.bounded(rows, window: .last90Days, now: now, activity: { $0.1 }, identity: { $0.0 })
        require(dated.map { $0.0 } == ["new", "boundary"], "inclusive actual 90-day boundary excludes unknown/future activity")
        for window in ContinueWatchingWindow.allCases where window.cap != nil {
            let result = ContinueWatchingPreferences.bounded(Array(0..<120), window: window, now: now, activity: { _ in nil }, identity: { String(format: "%03d", $0) })
            require(result.count == window.cap && result.first == 0, "deterministic actual \(window.rawValue)-item cap")
        }
    }
    static func foldSemantics() throws {
        let entries = Array(try SIMKLContinueWatchingFold.entries(Data(watching.utf8)).values.compactMap { $0.seed })
        require(entries.first?.videoID == "tt100:2:4" && entries.first?.progress == nil, "up-next retains actual coordinates without fake progress")
        let pauses = try SIMKLContinueWatchingFold.playback(Data(paused.utf8))
        require(pauses.first?.progress == 0.425 && pauses.first?.videoID == "tt100:2:3", "paused wire percentage and episode number decode exactly")
        let merged = SIMKLContinueWatchingFold.merge(watching: entries, playback: pauses)
        require(merged.count == 1 && merged.first?.caption?.hasPrefix("Paused") == true, "paused wins over up-next exact aliases")
        let anime = #"{"anime":[{"status":"watching","next_to_watch":"14","show":{"title":"Anime","ids":{"imdb":"tt300"}}}]}"#
        let next = try SIMKLContinueWatchingFold.entries(Data(anime.utf8)).values.compactMap { $0.seed }.first
        require(next?.videoID == nil && next?.progress == nil, "absolute anime does not invent season or offset")
        let mappedAnime = #"[{"type":"anime","progress":31,"episode":{"season":1,"number":47,"tvdb_season":3,"tvdb_number":8},"anime":{"title":"Mapped anime","ids":{"imdb":"tt301","simkl":301}}}]"#
        let mapped = try SIMKLContinueWatchingFold.playback(Data(mappedAnime.utf8)).first
        require(mapped?.videoID == "tt301:3:8", "paused anime uses its complete actual TVDB map, not AniDB coordinates")
        let partialAnime = #"[{"type":"anime","progress":31,"episode":{"season":1,"number":47,"tvdb_season":3},"anime":{"title":"Unmapped anime","ids":{"imdb":"tt302","simkl":302}}}]"#
        let partial = try SIMKLContinueWatchingFold.playback(Data(partialAnime.utf8)).first
        require(partial?.videoID == nil && partial?.progress == 0.31, "partial TVDB mapping keeps truthful activity without mixing numbering domains")
        let markerAnime = #"{"anime":[{"status":"watching","next_to_watch":"S03E08","show":{"title":"Mapped next","ids":{"simkl":303}}}]}"#
        let explicit = try SIMKLContinueWatchingFold.entries(Data(markerAnime.utf8)).values.compactMap { $0.seed }.first
        require(explicit?.id == "simkl:series:303" && explicit?.videoID == nil, "anime marker-only next activity stays visible without guessing an engine season")
        let contradictory = #"{"shows":[{"status":"watching","next_to_watch":"S02E04","next_to_watch_info":{"season":2,"episode":5},"show":{"ids":{"imdb":"tt304","simkl":304}}}]}"#
        let conflict = try SIMKLContinueWatchingFold.entries(Data(contradictory.utf8)).values.compactMap { $0.seed }.first
        require(conflict?.videoID == nil, "contradictory TV next marker and complete metadata cannot admit a guessed episode")
        let booleanIDs = #"{"shows":[{"status":"watching","next_to_watch":"S02E04","show":{"ids":{"tmdb":true,"simkl":true}}}]}"#
        let booleanIdentityChanges = try SIMKLContinueWatchingFold.entries(Data(booleanIDs.utf8))
        require(booleanIdentityChanges.isEmpty, "JSON booleans cannot manufacture canonical or SIMKL numeric identities")
        let mixedIDs = #"{"shows":[{"status":"watching","next_to_watch":"S02E04","show":{"ids":{"tmdb":true,"simkl":305}}}]}"#
        let mixed = try SIMKLContinueWatchingFold.entries(Data(mixedIDs.utf8)).values.compactMap { $0.seed }.first
        require(mixed?.id == "simkl:series:305", "invalid canonical boolean leaves only the genuine source-only identity")
        let booleanEpisode = #"[{"progress":20,"episode":{"season":true,"number":3},"show":{"ids":{"imdb":"tt306"}}}]"#
        let booleanCoordinates = try SIMKLContinueWatchingFold.playback(Data(booleanEpisode.utf8)).first
        require(booleanCoordinates?.videoID == nil && booleanCoordinates?.progress == 0.2, "boolean episode coordinates cannot manufacture a playable season")
        let negativeEpisode = #"[{"progress":20,"episode":{"season":"-1","number":"3"},"show":{"ids":{"imdb":"tt307"}}}]"#
        let negativeCoordinates = try SIMKLContinueWatchingFold.playback(Data(negativeEpisode.utf8)).first
        require(negativeCoordinates?.videoID == nil, "negative numeric season string obeys the same nonnegative coordinate rule")
        let booleanProgress = #"[{"progress":true,"movie":{"ids":{"imdb":"tt308"}}}]"#
        let booleanPercent = try SIMKLContinueWatchingFold.playback(Data(booleanProgress.utf8))
        require(booleanPercent.isEmpty, "JSON boolean is not a genuine playback percentage")
        let legitimateNumbers = #"[{"progress":20.5,"episode":{"season":"2","number":"3"},"show":{"ids":{"tmdb":"309","simkl":309}}}]"#
        let legitimate = try SIMKLContinueWatchingFold.playback(Data(legitimateNumbers.utf8)).first
        require(legitimate?.id == "tmdb:tv:309" && legitimate?.videoID == "tmdb:tv:309:2:3" && legitimate?.progress == 0.205, "legitimate numeric IDs and coordinates remain accepted after strict boolean/range checks")
        let completed = #"{"shows":[{"status":"completed","show":{"ids":{"simkl":10,"imdb":"tt100"}}}]}"#
        let changes = try SIMKLContinueWatchingFold.entries(Data(completed.utf8))
        require(changes.keys.contains("shows|simkl:10") && changes["shows|simkl:10"]?.seed == nil
            && changes["shows|simkl:10"]?.identities.contains("tt100") == true, "delta status transition retains exact removal identities")
        do { _ = try SIMKLContinueWatchingFold.entries(Data(#"{"shows":"bad"}"#.utf8)); require(false, "malformed leg rejected") }
        catch { require(true, "malformed leg rejected") }
        let animeMovie = #"{"anime":[{"status":"watching","anime_type":"movie","next_to_watch":"1","show":{"ids":{"imdb":"tt400"}}}]}"#
        let movieEntries = try SIMKLContinueWatchingFold.entries(Data(animeMovie.utf8))
        require(movieEntries.values.compactMap { $0.seed }.isEmpty, "row-level anime movie cannot invent an up-next episode")
        let empty = try SIMKLContinueWatchingFold.playback(Data())
        require(empty.isEmpty, "successful empty paused leg is truthful")
        let saturated = Data(("[" + Array(repeating: "{}", count: 10_000).joined(separator: ",") + "]").utf8)
        do { _ = try SIMKLContinueWatchingFold.playback(saturated); require(false, "possibly truncated paused leg rejected") }
        catch { require(true, "possibly truncated full-limit paused leg rejected") }
    }
    static func readerTransactions() async {
        let reader = SIMKLContinueWatchingReader(), transport = SIMKLService()
        let emptyReader = SIMKLContinueWatchingReader()
        var nullResponses = responses(shows: "", playback: "")
        nullResponses["/sync/activities"] = #"{"all":null}"#
        await transport.configure(nullResponses)
        let nullEmpty = await emptyReader.refresh(session: session, transport: transport)
        require(nullEmpty.hasSnapshot && !nullEmpty.failed && nullEmpty.items.isEmpty, "explicit null activities supports connected truthful empty snapshot")
        var malformed = nullResponses; malformed["/sync/activities"] = "{}"
        await transport.configure(malformed)
        let missing = await emptyReader.refresh(session: session, transport: transport)
        require(missing.failed && missing.hasSnapshot, "missing activity field is not the explicit-null success case")
        await transport.configure(responses())
        let first = await reader.refresh(session: session, transport: transport)
        let initialRequests = await transport.requests
        require(first.hasSnapshot && first.items.count == 1, "complete actual reader snapshot committed")
        require(initialRequests.map(\.path) == ["/sync/activities", "/sync/all-items/movies", "/sync/all-items/shows", "/sync/all-items/anime", "/sync/playback"], "activities-first complete sequential transport legs")
        require(initialRequests[2].query["next_watch_info"] == "yes", "reader asks for real next episode metadata")
        await transport.configure(responses(playback: ""))
        let expired = await reader.refresh(session: session, transport: transport)
        let unchanged = await transport.requests
        require(unchanged.map(\.path) == ["/sync/activities", "/sync/playback"], "unchanged activities still reconcile paused expiry without repeating list legs")
        require(expired.items.first?.progress == nil, "expired pause disappears even without changed activity stamp")
        let newer = "2026-10-09T13:00:00Z"
        await transport.configure(responses(stamp: newer), failure: "/sync/all-items/anime")
        let failed = await reader.refresh(session: session, transport: transport)
        require(failed.failed && failed.items == expired.items && failed.hasSnapshot, "failed type leg retains complete snapshot")
        await transport.configure(responses(stamp: newer, shows: "", playback: ""))
        let empty = await reader.refresh(session: session, transport: transport)
        let retry = await transport.requests
        require(retry[2].query["date_from"] == "2026-10-09T12:00:00Z", "failed legs do not advance activity cursor")
        // Empty delta has no removals, so the old up-next row remains, but paused playback is replaced.
        require(empty.hasSnapshot && empty.items.first?.progress == nil, "complete paused empty replaces paused truth without fabricating progress")
        let completedAlias = #"{"shows":[{"status":"completed","show":{"ids":{"tmdb":42}}}]}"#
        await transport.configure(responses(stamp: "2026-10-09T13:30:00Z", shows: completedAlias, playback: ""))
        let aliasRemoval = await reader.refresh(session: session, transport: transport)
        require(aliasRemoval.items.isEmpty, "actual delta tombstone reconciles canonical-id subset through retained typed aliases")
        await transport.configure(responses(stamp: "2026-10-09T14:00:00Z", shows: "", playback: "", removed: newer))
        let removed = await reader.refresh(session: session, transport: transport)
        let removedRequests = await transport.requests
        require(removed.hasSnapshot && removed.items.isEmpty && removedRequests[2].query["date_from"] == nil, "removed activity triggers full reconciliation and truthful empty")
        SIMKLAuth.storedSessionID = SIMKLSessionID(rawValue: "inert-simkl-B")
        let retired = await reader.refresh(session: session, transport: transport)
        require(!retired.hasSnapshot && retired.items.isEmpty, "retired exact session cannot publish reader bytes")
        SIMKLAuth.storedSessionID = session
    }
    static func httpReadAuthority() async throws {
        let client = FixtureSIMKLHTTPClient()
        _ = try await client.continueWatchingRead(path: "/sync/all-items/shows",
            query: ["date_from": "2026-10-09T00:00:00Z", "next_watch_info": "yes"], session: session)
        let requests = await client.requests
        let request = requests[0]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        require(request.httpMethod == "GET" && request.httpBody == nil, "actual SIMKL transport constructs read-only GET without body")
        require(query.contains(.init(name: "extended", value: "full")) && query.contains(.init(name: "next_watch_info", value: "yes"))
            && query.contains(.init(name: "date_from", value: "2026-10-09T00:00:00Z")), "actual GET preserves required and delta/episode query parameters")
        require(request.cachePolicy == .reloadIgnoringLocalCacheData, "actual private SIMKL GET bypasses URL cache")
        do { _ = try await client.continueWatchingRead(path: "/sync/history/remove", query: [:], session: session); require(false, "write path excluded") }
        catch { require(true, "read-only CW allowlist excludes provider write endpoint") }
        await client.setRetirement()
        do { _ = try await client.continueWatchingRead(path: "/sync/playback", query: [:], session: session); require(false, "retired transport rejected") }
        catch { require(true, "actual transport rejects account retirement after suspended response") }
        SIMKLAuth.storedSessionID = session
    }
    static func selectorAndEpochs() async {
        configure(); SIMKLContinueWatchingShadow.shared.clear()
        await SIMKLService.shared.configure(responses())
        let before = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        await SIMKLContinueWatchingShadow.shared.refresh(context: before.context)?.value
        let selected = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        require(selected.selection.source == .simkl && selected.selection.items.count == 1, "actual SIMKL shadow projects through production primary selector")
        require(selected.selection.items.first?.state.duration == 0 && selected.selection.items.first?.resumeSeconds == 0, "SIMKL never manufactures duration or resume seconds")
        require(selected.selection.displayProgress["tt100"] == 0.425, "production projection carries separate truthful display progress")
        require(selected.intent.isCurrent(), "captured rendered SIMKL intent is current")
        let shelf = FixtureTopShelfMapper.items(from: selected.selection.items, source: .simkl, displayProgress: selected.selection.displayProgress)
        require(shelf.first?.progress == 0.425 && shelf.first?.poster == nil, "actual Top Shelf mapper displays real SIMKL percent without private hotlinks")
        await SIMKLService.shared.configure(responses(playback: ""))
        require(SIMKLContinueWatchingShadow.shared.refresh(context: selected.context) == nil, "actual Home re-entry reader remains throttled inside five minutes")
        await SIMKLContinueWatchingShadow.shared.refresh(context: selected.context, now: Date().addingTimeInterval(301))?.value
        let focused = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        let focusRequests = await SIMKLService.shared.requests
        require(focusRequests.map(\.path) == ["/sync/activities", "/sync/playback"] && focused.selection.displayProgress["tt100"] == nil && focused.selection.items.first?.state.videoId == "tt100:2:4", "actual throttled focus refresh reconciles expired pause under unchanged activities without fake progress")
        UserDefaults.standard.set("local", forKey: ContinueWatchingPreferences.sourceKey)
        ContinueWatchingPreferences.retireSelection()
        require(!selected.intent.isCurrent(), "source edit immediately retires rendered tap and shelf intent")
        let queued = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        require(queued.selection.items.isEmpty && queued.selection.status != nil, "unacknowledged native preference edit is unavailable")
        ProfileStore.shared.active?.discovery?.continueWatchingSource = "local"
        require(HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).selection.items.first?.id == "local", "acknowledged Local remains exact native history")
        UserDefaults.standard.set("simkl", forKey: ContinueWatchingPreferences.sourceKey)
        ContinueWatchingPreferences.retireSelection()
        ProfileStore.shared.active?.discovery?.continueWatchingSource = "simkl"
        require(!selected.intent.isCurrent(), "same-account source ABA never revives a captured service intent")
        SIMKLAuth.storedSessionID = nil
        require(!selected.intent.isCurrent(), "SIMKL account retirement denies old captured taps")
        let disconnected = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).selection
        require(disconnected.items.isEmpty && disconnected.status?.contains("Connect SIMKL") == true, "disconnected selected service is explicit")
        SIMKLAuth.isConfigured = false
        require(HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).selection.status?.contains("unavailable") == true, "unprovisioned selected service is explicit")
        configure(eligible: false)
        let shared = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        require(shared.selection.source == .local && shared.selection.items.first?.id == "local", "shared profile does not borrow service history")
        configure(); let current = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).context
        CoreBridge.shared.nativeBinding = nil
        require(!current.isCurrent(core: .shared, profiles: .shared), "unknown native authority retires service selection")
        configure(); let captured = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).context
        let binding = CoreBridge.shared.nativeBinding!
        CoreBridge.shared.nativeBinding = .init(profileID: profileA, credential: binding.credential, sessionGeneration: UUID(), accountGeneration: binding.accountGeneration)
        require(!captured.isCurrent(core: .shared, profiles: .shared), "native A-B-A/reopen generation retires captured intent")
    }
    static func sourceOnlyCardsAndAdmission() async {
        configure(); SIMKLContinueWatchingShadow.shared.clear()
        let sourceOnly = #"{"shows":[{"status":"watching","last_watched_at":"2026-10-08T12:00:00Z","next_to_watch":"S02E05","next_to_watch_info":{"season":2,"episode":5,"title":"Provided episode"},"show":{"title":"Provided SIMKL-only show","ids":{"simkl":810}}}]}"#
        let pauses = #"[{"progress":53,"paused_at":"2026-10-09T12:00:00Z","movie":{"title":"Provided SIMKL-only movie","ids":{"simkl":811}}},{"type":"anime","progress":37,"paused_at":"2026-10-09T11:00:00Z","episode":{"season":1,"number":47,"tvdb_season":3},"anime":{"title":"Provided unmapped anime","ids":{"imdb":"tt812","simkl":812}}},{"progress":25,"paused_at":"2026-10-09T10:00:00Z","movie":{"title":"Provided playable movie","ids":{"imdb":"tt813","simkl":813}}}]"#
        await SIMKLService.shared.configure(responses(stamp: "2026-10-10T12:00:00Z", shows: sourceOnly, playback: pauses,
                                                     removed: "2026-10-10T12:00:00Z"))
        let before = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        await SIMKLContinueWatchingShadow.shared.refresh(context: before.context)?.value
        let selected = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        let show = selected.selection.items.first { $0.id == "simkl:series:810" }
        let movie = selected.selection.items.first { $0.id == "simkl:movie:811" }
        require(selected.selection.items.count == 4 && show?.name == "Provided SIMKL-only show" && movie?.name == "Provided SIMKL-only movie", "actual official source-only rows remain visible with genuine typed SIMKL identities and titles")
        require(show?.state.videoId == "simkl:series:810:2:5" && show?.state.lastWatched == "2026-10-08T12:00:00Z", "source-only next card retains only supplied episode and activity facts")
        require(movie?.state.duration == 0 && movie?.resumeSeconds == 0 && selected.selection.displayProgress["simkl:movie:811"] == 0.53, "source-only paused card shows real percent without runtime or offset")
        require(selected.selection.captions["simkl:series:810"]?.contains("Playback unavailable") == true && selected.selection.captions["tt812"]?.contains("Playback unavailable") == true, "source-only and unmapped anime cards explicitly advertise unavailable playback")
        var lookupCount = 0
        for item in selected.selection.items {
            if selected.intent.permitsDetails(id: item.id, type: item.type, videoID: item.state.videoId) { lookupCount += 1 }
        }
        require(lookupCount == 1 && selected.intent.permitsDetails(id: "tt813", type: "movie", videoID: nil), "actual shared tap admission preserves canonical playable route and prevents all unsupported Details/stream lookups")
        require(selected.intent.unavailableReason(id: "simkl:series:810", type: "series", videoID: show?.state.videoId)?.contains("IMDB or TMDB") == true, "unsupported identity tap has an explicit read-only explanation")
        let shelf = FixtureTopShelfMapper.items(from: selected.selection.items, source: .simkl, displayProgress: selected.selection.displayProgress)
        require(shelf.map(\.id) == ["tt813"], "actual actionable Top Shelf omits unsupported identities and unmapped anime instead of emitting broken lookup links")
        let waiting = (try? SIMKLContinueWatchingFold.entries(Data(sourceOnly.utf8)))?.values.compactMap { $0.seed } ?? []
        let joined = #"[{"progress":40,"episode":{"season":2,"number":5},"show":{"title":"Provided mapped show","ids":{"simkl":810,"imdb":"tt810"}}}]"#
        let mapped = (try? SIMKLContinueWatchingFold.playback(Data(joined.utf8))) ?? []
        let merged = SIMKLContinueWatchingFold.merge(watching: waiting, playback: mapped)
        require(merged.count == 1 && merged.first?.id == "tt810" && merged.first?.aliases.contains("simkl:series:810") == true, "canonical paused mapping joins and retains its real source-only alias")
        SIMKLAuth.storedSessionID = SIMKLSessionID(rawValue: "inert-simkl-replacement")
        require(!selected.intent.permitsDetails(id: "tt813", type: "movie", videoID: nil) && HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).selection.items.isEmpty, "session supersession retires source-only presentation and playable admission together")
        SIMKLAuth.storedSessionID = session
    }
    static func pickerBindingEpochsAndWiring() {
        configure(source: "local")
        let old = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).intent
        let initial = ContinueWatchingPreferences.selectionEpoch
        var writes = 0; var retiredBeforeWrite = true
        func edit(_ value: String, key: String) {
            ContinueWatchingPreferences.writeUserChoice(value, forKey: key) {
                retiredBeforeWrite = retiredBeforeWrite && ContinueWatchingPreferences.selectionEpoch > initial
                writes += 1; UserDefaults.standard.set(value, forKey: key)
            }
        }
        edit("local", key: ContinueWatchingPreferences.sourceKey)
        require(writes == 0 && ContinueWatchingPreferences.selectionEpoch == initial, "actual Picker same-value setter neither writes nor retires its selection")
        edit("trakt", key: ContinueWatchingPreferences.sourceKey); edit("local", key: ContinueWatchingPreferences.sourceKey)
        require(writes == 2 && retiredBeforeWrite && ContinueWatchingPreferences.selectionEpoch == initial + 2 && !old.isCurrent(), "actual synchronous Picker source ABA retires intent before each one projection write")
        let window = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared).intent
        edit("40", key: ContinueWatchingPreferences.windowKey); edit("20", key: ContinueWatchingPreferences.windowKey)
        require(writes == 4 && !window.isCurrent(), "actual synchronous Picker range ABA cannot revive delayed tap/artwork intent")
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func read(_ path: String) -> String { (try? String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        let settings = read("SourcesShared/ContinueWatchingSettingsView.swift")
        require(settings.components(separatedBy: "ContinueWatchingPreferences.writeUserChoice").count == 3 && !settings.contains(".onChange(of: source)") && !settings.contains(".onChange(of: window)"), "both actual settings Picker bindings use synchronous production setter rather than coalesced callbacks")
        let tv = read("SourcesTV/HomeView.swift"), ios = read("SourcesiOS/iOSRootView.swift")
        require(tv.contains("if let reason = intent?.unavailableReason(id: item.id") && tv.contains("$0.intent?.permitsDetails(id:") && ios.contains("if let reason = provenance.intent.unavailableReason(id: item.id") && ios.contains("target.intent.permitsDetails(id:"), "actual TV/iOS unavailable tap and deferred destination consume tested admission fences")
        require(read("SourcesTV/RootTabView.swift").contains("HomeView(isActive: selection == 0)") && tv.contains(".onChange(of: scenePhase)") && tv.contains("if active, scenePhase == .active") && ios.contains(".onChange(of: scenePhase)") && ios.contains("if scenePhase == .active { HomeContinueWatchingSelection.refreshCurrent"), "actual Home visibility and foreground re-entry trigger only selected-source throttled refresh")
        var focusLookups = 0
        for source in [ContinueWatchingService.trakt, .simkl] {
            if FixtureContinueWatchingFocus.permitsHeroEnrichment(source: source, traktSessionID: nil) { focusLookups += 1 }
        }
        require(focusLookups == 0, "actual TV focus predicate denies Trakt and source-only SIMKL metadata/art-cache enrichment while cards remain focusable")
        require(FixtureContinueWatchingFocus.permitsHeroEnrichment(source: .local, traktSessionID: nil)
            && !FixtureContinueWatchingFocus.permitsHeroEnrichment(source: nil, traktSessionID: TraktSessionID(rawValue: "inert-focus-private")), "actual TV focus predicate preserves ordinary Local focus and guards legacy Trakt-session callers")
        require(tv.contains("onFocus: Self.permitsHeroEnrichment(source: intent?.source, traktSessionID: traktSessionID)")
            && tv.contains("} : nil,\n                                   directPlay: directResume(item)"), "actual private PosterCard FocusReporter gets no enrichment callback, rather than relying on its caller or artwork flag")
        CoreBridge.shared.continueWatching = [CoreCWItem(id: "tt900", type: "series", name: "Explicit rewind",
            poster: nil, state: CoreLibState(timeOffset: 0, duration: 100_000, videoId: "tt900:2:7", lastWatched: "2026-10-09T12:00:00Z"))]
        let zero = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        require(zero.selection.items.first?.state.timeOffset == 0 && zero.selection.items.first?.state.videoId == "tt900:2:7" && zero.intent.permitsDetails(id: "tt900", type: "series", videoID: "tt900:2:7"), "actual native Local selection preserves clocked zero-position rewind and exact episode without inventing progress")
    }
    static func traktPublicationEpochs() {
        configure(source: "trakt")
        let trakt = TraktSessionID(rawValue: "inert-trakt-A")
        TraktAuth.storedSessionID = trakt
        let shadow = TraktPlaybackShadow()
        let captured = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared, shadow: shadow)
        let seed = TraktContinueWatchingSeed(id: "tt500", type: "movie", name: "Inert Trakt", progress: 40,
            pausedAt: "2026-10-09T00:00:00Z", runtimeMinutes: 100, videoID: nil, poster: nil, aliases: [])
        require(shadow.commitFixture(progress: ["tt500": 40], items: [seed], sessionID: trakt, context: captured.context), "actual Trakt cache/presentation commit admits current captured context")
        UserDefaults.standard.set("local", forKey: ContinueWatchingPreferences.sourceKey)
        ContinueWatchingPreferences.retireSelection()
        UserDefaults.standard.set("trakt", forKey: ContinueWatchingPreferences.sourceKey)
        ContinueWatchingPreferences.retireSelection()
        require(!captured.intent.isCurrent(), "Trakt source ABA retires prior rendered tap")
        require(!shadow.commitFixture(progress: [:], items: [], sessionID: trakt, context: captured.context), "late actual Trakt transport commit is rejected across source ABA")
        let current = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared, shadow: shadow)
        UserDefaults.standard.set("40", forKey: ContinueWatchingPreferences.windowKey)
        ContinueWatchingPreferences.retireSelection()
        UserDefaults.standard.set("20", forKey: ContinueWatchingPreferences.windowKey)
        ContinueWatchingPreferences.retireSelection()
        require(!current.intent.isCurrent(), "same-account window ABA retires captured tap")
        require(!HomeContinueWatchingSelection.permitsPrivateArtworkCommit(context: current.context, sessionID: trakt, core: .shared, profiles: .shared), "window ABA rejects private artwork storage and final publication")
        CoreBridge.shared.usesNativeProfileState = false
        let legacy = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared, shadow: shadow)
        CredentialScopeRegistry.shared.generation &+= 1
        require(!legacy.intent.isCurrent(), "legacy same-profile account generation retires service authority")
    }
    static func nativeMigration() async {
        configure(source: "local")
        UserDefaults.standard.removeObject(forKey: ContinueWatchingPreferences.sourceKey)
        UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        TraktAuth.storedSessionID = TraktSessionID(rawValue: "inert-trakt-A")
        let profile = UserProfile(id: profileA)
        let store = MigrationFixtureProfileStore(profiles: [profile], activeID: profileA)
        store.failSave = true
        store.applyNativeProfiles([profile], activeID: profileA)
        await store.drain()
        require(store.saveCount == 1 && ContinueWatchingPreferences.current().source == .local, "startup qualifying legacy toggle remains Local on durable save failure")
        store.failSave = false
        store.applyNativeProfiles([profile], activeID: profileA)
        await store.drain()
        require(store.saveCount == 2 && store.active?.discovery?.continueWatchingSource == "trakt", "same-authority retry persists qualified witness through actual activation hook")
        require(ContinueWatchingPreferences.current().source == .trakt, "only acknowledged profile projection publishes migrated Trakt")
        configure(source: "local"); UserDefaults.standard.reset()
        UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        let edited = MigrationFixtureProfileStore(profiles: [profile], activeID: profileA)
        edited.failSave = true; edited.applyNativeProfiles([profile], activeID: profileA); await edited.drain()
        UserDefaults.standard.set(["viewer-edit"], forKey: ProfileDiscoveryPreferencesStore.Key.catalogOrder)
        edited.failSave = false; edited.captureDiscovery(); await edited.drain()
        require(edited.active?.discovery?.catalogOrder == ["viewer-edit"] && edited.active?.discovery?.continueWatchingSource == "trakt"
            && ContinueWatchingPreferences.current().source == .trakt, "unrelated queued discovery edit retains viewer fields and only acknowledged migrated source")
        let b = UserProfile(id: profileB, usesEngineHistory: false)
        store.applyNativeProfiles([store.active!, b], activeID: profileB)
        require(ContinueWatchingPreferences.current().source == .local && !UserDefaults.standard.bool(forKey: ExternalSyncToggle.traktContinueWatching), "real shared/child switch clears mirror and defaults Local20")
        UserDefaults.standard.reset(); UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        let unknown = MigrationFixtureProfileStore(profiles: [], activeID: nil)
        unknown.applyNativeProfiles([profile], activeID: profileA); await unknown.drain()
        require(unknown.saveCount == 0 && ContinueWatchingPreferences.current().source == .local, "unknown startup profile cannot inherit global legacy bool")
        UserDefaults.standard.reset(); UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        CoreBridge.shared.nativeBinding = nil
        let unbound = MigrationFixtureProfileStore(profiles: [profile], activeID: profileA)
        unbound.applyNativeProfiles([profile], activeID: profileA); await unbound.drain()
        require(unbound.saveCount == 0, "nil native/account binding never qualifies legacy migration")
        configure(source: "local")
        UserDefaults.standard.reset()
        let replaced = MigrationFixtureProfileStore(profiles: [profile], activeID: profileA)
        replaced.applyNativeProfiles([profile], activeID: profileA)
        UserDefaults.standard.removeObject(forKey: ContinueWatchingPreferences.sourceKey)
        UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        CoreBridge.shared.nativeBinding = .init(profileID: profileA, credential: CredentialScopeRegistry.shared.capture(),
            sessionGeneration: UUID(), accountGeneration: UUID())
        replaced.applyNativeProfiles([profile], activeID: profileA); await replaced.drain()
        require(replaced.saveCount == 0 && ContinueWatchingPreferences.current().source == .local, "same UUID replacement account cannot mint first witness from cached outgoing toggle")
        configure(source: "local"); UserDefaults.standard.reset()
        UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        let pending = MigrationFixtureProfileStore(profiles: [profile], activeID: profileA)
        pending.suspendSave = true
        pending.applyNativeProfiles([profile], activeID: profileA); await pending.drain()
        require(pending.saving != nil, "actual migration reaches inert suspended durable-write seam")
        CoreBridge.shared.nativeBinding = .init(profileID: profileA, credential: CredentialScopeRegistry.shared.capture(),
            sessionGeneration: UUID(), accountGeneration: UUID())
        pending.applyNativeProfiles([profile], activeID: profileA)
        pending.saving?.resume(); pending.saving = nil; await pending.drain()
        require(pending.active?.discovery?.continueWatchingSource == nil && ContinueWatchingPreferences.current().source == .local,
            "account retirement during pending save cannot publish migrated Trakt")
        configure(source: "local"); UserDefaults.standard.reset()
        UserDefaults.standard.set(true, forKey: ExternalSyncToggle.traktContinueWatching)
        CredentialScopeRegistry.shared.eligible = false
        let unauthenticated = MigrationFixtureProfileStore(profiles: [profile], activeID: profileA)
        unauthenticated.applyNativeProfiles([profile], activeID: profileA); await unauthenticated.drain()
        require(unauthenticated.saveCount == 0, "unacknowledged original account cannot qualify startup legacy witness")
        CredentialScopeRegistry.shared.eligible = true
    }
    static func legacySourceMethodWindow() {
        configure(source: "local", window: "100", eligible: false)
        let store = MigrationFixtureProfileStore(profiles: [UserProfile(id: profileA, usesEngineHistory: false)], activeID: profileA)
        let now = ContinueWatchingPreferences.activity("2026-10-09T00:00:00Z")!
        let formatter = ISO8601DateFormatter()
        for index in 0..<125 {
            let id = "tt\(1000 + index)"
            store.watch[id] = WatchEntry(videoId: id, timeOffsetMs: 20_000, durationMs: 100_000,
                lastWatched: formatter.string(from: now.addingTimeInterval(-Double(index) * 86_400)), name: id, type: "movie", poster: nil)
        }
        store.watch["imdb:tt1000"] = store.watch["tt1000"] // actual identity fold must retain one title
        store.watch["tt2000"] = WatchEntry(videoId: "tt2000", timeOffsetMs: 99_000, durationMs: 100_000,
            lastWatched: formatter.string(from: now), name: "Finished", type: "movie", poster: nil)
        store.watch["tt2001"] = WatchEntry(videoId: "tt2001", timeOffsetMs: 0, durationMs: 100_000,
            lastWatched: formatter.string(from: now), name: "Marked", type: "movie", poster: nil, watchedVideoIds: ["tt2001"])
        store.watch["tt3000"] = WatchEntry(videoId: "tt3000:1:1", timeOffsetMs: 0, durationMs: 0,
            lastWatched: formatter.string(from: now), name: "Series next", type: "series", poster: nil, watchedVideoIds: ["tt3000:1:1"])
        store.watch["tt9999"] = WatchEntry(videoId: "tt9999", timeOffsetMs: 20_000, durationMs: 100_000,
            lastWatched: "", name: "Unknown date", type: "movie", poster: nil)
        let items = store.cwItems
        require(items.count == 127, "actual legacy CW method retains100+ entries without premature30 cap and exact dedupe")
        require(!items.contains { $0.id == "tt2000" || $0.id == "tt2001" } && items.contains { $0.id == "tt3000" }, "actual legacy completed-movie exclusions and series continuation remain unchanged")
        require(items.filter { $0.id == "tt1000" || $0.id == "imdb:tt1000" }.count == 1, "actual legacy production dedupe unchanged")
        CoreBridge.shared.usesNativeProfileState = false
        ProfileStore.shared.cwItems = items
        let selected = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        require(selected.selection.items.count == 100 && selected.selection.source == .local, "production selector applies requested100 cap to actual legacy rows")
        let dated = ContinueWatchingPreferences.bounded(items, window: .last90Days, now: now,
            activity: { $0.state.lastWatched }, identity: { $0.type + "|" + $0.id })
        require(dated.count == 92 && !dated.contains { $0.id == "tt9999" }, "actual legacy timestamp projection supports inclusive90day window and excludes unknown date")
    }
}
