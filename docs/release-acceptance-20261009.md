# VortX 0.5 acceptance snapshot — 9 October 2026

Scope: all **49 currently open** `VortXTV/VortX` issues, fetched with `gh issue list --state open --limit 200`; source baseline **`530aaf43b0a608a97484142721e238d4465eef37`**. This is an issue-to-source acceptance matrix, not a shipped-release receipt. The integration checkout continues to evolve. Recheck changed source and the final artifact before closing an issue.

Focused checks executed against that canonical source, with binaries written only in the acceptance worktree: `Issue240PlaybackFailureTests` **PASS**, `TerminalLoadFailureContractTests` **PASS**, `DetailEpisodeTargetPolicyTests` **22 checks PASS**. The new independent `NewSeriesDefaultEpisodePolicyTests` also **22 checks PASS** against the Apple Cinema owner's pending source at `9b592fc79` plus the changed helper/callsites; helper SHA-256 `6b3e96de5b3bbf7a5c57dca64c65636b48bd9bee03af4281a5c96eacb534d025`. Its runner records all four dependency/callsite hashes and should run again after source integration. Other tests named below are existing regression coverage inspected for relevance; this lane has not run their entire suites. No installed app, playback, audio, provider account, or device test was performed.

## Concrete gaps routed to owners

1. **#244, fresh-show default selects specials.** With ordered inventory `[S0E1, S1E1]` and no watched/resume state, the baseline Apple hero and season defaults choose `S0E1`: `SourcesTV/DetailView.swift` first-unwatched fallback and `SourcesiOS/iOSDetailView.swift` `firstUnwatchedSeason`. Expected: default to ordinary episodes while preserving exact/manual/resumed specials. The Apple Cinema/detail owner supplied a shared helper and callsite fix; the independent fixture passed on that pending source. `NewSeriesDefaultEpisodePolicyTests.swift` tests the actual helper, exact CW special hints, watched progress, specials-only inventory, missing season metadata, and empty inventory. Its runner is `bash test/release-acceptance/test-new-series-default.sh <source-checkout>`; rerun it on the integrated revision. This does not establish Infuse watched-return behavior.
2. **Local Watchlist is not a proven account/profile list carrier; Apple native export can reject its dirty key.** `SourcesShared/LibraryAutoAdd.swift` writes `Data` under `vortx.watchlist.<profile UUID>`. Apple `SettingsBackup.isSyncable` permits that key, so portable backups and the legacy generic settings blob can carry it incidentally. In native mode, `VortXSyncManager.currentSyncableDomain` tracks the mutation, but `nativeGlobalEdits` rejects it because `VortxNativeHostPreferences.knownGlobals` has no Watchlist key. Native export/checkpoint gates then fail on that dirty edit. Repro at the source boundary: signed-in native profile toggles Watchlist, then an ordinary setting changes; the Watchlist dirty stamp remains and `nativeGlobalEdits` throws `invalidSnapshot`. Routed to native Apple integration and the root. Android `library/WatchlistStore.kt` is also a separate profile-local preferences ledger, without a dedicated account carrier. Remote Trakt/SIMKL watchlists and the engine's saved library are distinct data sets and do not prove this local list converges.

## Open-issue matrix

“Present” means relevant current implementation/coverage exists. It does not mean the reported symptom was reproduced or the fix shipped. “Unproven” means the available report needs the stated evidence. “Partial” means actual requested product work remains.

| Issue | Current source / focused coverage | Acceptance remaining |
| --- | --- | --- |
| #248 | All five issue-linked release runs still `waiting`; heads `dfa65f339`, `64264f0ff`, `f69fb8ff` are older than this baseline. | Release owner must build/review the chosen final revision; do not use an old waiting run as proof of the new integration. |
| #244 | Infuse metadata/handoff identity exists (`ExternalPlayerHandoffContractTests`); concrete default-selection gap above. | New selection fixture and callsites must pass; external-player watched/return-next behavior remains unproven. |
| #243 | Launch guards/native bootstrap work exists. Report only says beta.20 immediately crashes. | Current signed IPA, exact device/OS, crash stack, cold-launch reproduction. |
| #240 | Production router honors explicit DV-remux Off; retained failed-episode Retry and terminal engine retirement fixtures **PASS**. | Socket-drop playback, source availability, and DV decoding still need a current artifact/device receipt. |
| #229 | First-party Trakt artwork loads in `SourcesTV/SharedUI.swift`; Top Shelf uses Home's profile-aware selection (`TopShelfSnapshotTests`, `TraktArtworkPolicyTests`). | App Group provisioning plus physical TV poster/shelf publication after account/profile changes. |
| #226 | Cross-platform source exists, but this lane has no current Windows installer receipt. | Windows build/install/support is separate product work. |
| #225 | One-shot Stremio sign-in completion and native auth ownership work exists. | Current iOS sign-in dismissal; separate TorBox playback failure is not established as the same defect. |
| #223 | Load-owned completion/EOF guards and transactional episode identity exist (`PlaybackCompletionEvidenceTests`, `EOFTerminalAdvanceContractTests`). | Premature EOF must retain the requested episode on the current player/device. |
| #222 | MPV initialization and crash-marker guards exist (`MPVInitializationFailureTests`, `CrashMarkerLaunchSnapshotTests`). | Current pre-playback crash stack and exact source/player initialization reproduction. |
| #221 | Episode focus/row identity boundaries exist. | Siri Remote episode-list movement and list boundary behavior on tvOS. |
| #220 | Plex requests a short PIN with `strong=false` (`PlexPINLinkContractTests`). | Live Plex code/link completion with current artifact. |
| #219 | Android TV has native routes, sheets, playback controls and ongoing Cinema completion. | Broad Apple TV parity requires a retained-feature and D-pad acceptance pass; no blanket closure. |
| #214 | Disk/RAM/cache admission and telemetry policies exist; unlimited disk is not unlimited RAM. | Sustained physical stream throughput, cache/decoder telemetry, buffering and AV-sync behavior. |
| #213 | Apple source picker has per-source player menus (`ExternalPlayerHandoffContractTests`). | Current long-press menu and chosen-player handoff on each affected surface. |
| #206 | `TVDetailSourceColumnFocusContractTests` covers first-row/filter focus boundaries. | Physical Up moves one source row and crosses the top boundary correctly. |
| #205 | Add-on tombstones, explicit installation/import and ordered hydration exist (`AddonLocalMutationContractTests`, `AddonOwnerStorageTests`). | Exact same URL remove → explicit reinstall/import succeeds; passive sync does not resurrect it. |
| #204 | Apple session audio-language menus exist; actual tracks remain authoritative (`StreamRankingChipsTests`, binge-language fixtures). | Per-title French/English switching, unknown-language releases, and resulting opened audio track. |
| #203 | Phrase-first French catalog translation and `CollectionsHubFrenchLocalizationTests` exist. | Reported phrases and currently retained Cinema/Home/Discover labels in French. |
| #196 | IPTV/live identity and playback flows exist. | Current exact manifest/source and device reproduction; report lacks them. |
| #188 | Constrained-device admission and initialization policies exist. | Apple TV HD crash stack and current compatible signed build. |
| #187 | Trakt refresh/session fencing exists (`TraktSessionSecurityTests`, `Issue164TraktContractTests`). | Expiry/refresh and concurrent three-device provider sync over the reported time window. |
| #186 | Android add-on manifest/HTTP resource transport exists. The report supplies a configure page, not its selected manifest. | Personalized manifest, valid stream response, current APK reproduction. |
| #182 | Episode-resolution budget, target ownership and terminal recovery exist (`EpisodeResolutionBudgetTests`, exact-CW test **PASS**). | Current older-iPhone series start; bounded terminal UI and Retry on genuine failure. |
| #178 | Bounded source work, hidden-player pause and capture admission exist. | Current Instruments/CPU measurement with explicit scraping and playback scenarios. |
| #174 | Device-local downloads exist. | Remote download job, authentication and cross-device ownership/control remain **partial**. |
| #173 | Android offline identity/metadata/routing coverage exists (`OfflinePlaybackIdentityTest`, `DownloadPlaybackRoutingTest`). | Signed APK with real downloaded 4K/HDR/audio file; decoder/output compatibility. |
| #172 | Source ranking exists; reliable cross-provider similarity confidence is not established. | A meaningful supported confidence signal/threshold remains **partial**. |
| #171 | Ordered audio/subtitle priority editing and persistence exist. | More than two priorities survive profile changes and select actual available tracks. |
| #170 | Android foreground WorkManager download transport exists. | Download progress survives UI close, process death and device constraints in the current APK. |
| #169 | `VortXAccent.royal` and profile theme persistence exist. | Royal remains selected after gallery exit, profile switch and restart in current APK. |
| #168 | Cinema/UI and multi-capability add-on preference work exists. | Broad animation/UI/parity request remains **partial** until retained journeys pass. |
| #167 | Transfer retry/range/strong-ETag policies exist (`DownloadTransferPolicyTest`). | Socket-loss resume preserves verified file content; measured torrent throughput. |
| #166 | Community-provider and language/dubbed-label parsing work exists. | Requested provider compatibility and original-language inference remain **partial**; an unspecified dubbed label cannot prove a track language. |
| #165 | Bounded non-IMDb meta recovery/Retry exists (`MetaResolutionFallbackTests`). | TMDB/TVDB empty/error payloads leave the spinner and preserve exact title identity in current artifact. |
| #164 | Trakt artwork/history/scrobble implementation and wiring coverage exist. | Current auth/artwork/progress receipt; provider/device success not implied by static wiring. |
| #163 | Route-aware DD+ path exists (`MPVAudioRoutePolicyTests`, `AppleAudioOutputScopeContractTests`). | TV/receiver/codec output matrix; TrueHD/Atmos passthrough must be reported separately. |
| #154 | Android 32-bit Fire TV ABI/release packaging coverage exists. | Actual final signed APK ABI contents plus Fire TV installation. |
| #153 | QR join/return-route/manual rescue logic exists (`QRJoinerFlowTests`, Android `VortXQrJoinFlowTest`). | Full current website-to-TV sign-in and session installation. |
| #152 | Source capability/hint propagation and Usenet paths exist. | Current cached-provider classification and opened source receipt; torrents shown alone do not establish cache availability. |
| #149 | Trakt CW selection and local owner/overlay history exist. | User-selectable Local/Trakt/SIMKL CW source remains **partial**; local Watchlist gap above is separate. |
| #147 | AVPlayer PiP/remux path and `AVPlayerPiPContractTests` exist. | Current background/PiP behavior after engine selection/fallback; libmpv PiP is not established. |
| #146 | iOS detail scroll-to-top affordance exists. | Long-episode-list button and current scroll destination. |
| #139 | Library type/smart filtering exists. | Genre grouping requires real genre data; whole feature bundle remains **partial**. |
| #137 | Removal/import fences overlap #205 (`AddonTombstoneSyncTest`, Apple tombstone tests). | Restart/cross-device removal convergence; related settings/Discover requests are **partial**. |
| #136 | Source/language controls, profile scope and label parsing exist. | Entire requested filter/profile/rename bundle remains **partial**; preserve unknown/provider language semantics. |
| #132 | Apple download-save classifier/self-heal exists (`DownloadFailureClassifierTests`). | Current completed download persists/opens through locked/background conditions and real filesystem failure. |
| #131 | Modern Cinema presentation is ongoing product work. | Retained controls/actions and rendered current routes; visual redesign alone cannot close the feature bundle. |
| #129 | SIMKL auth/history/scrobble/upcoming/rating implementations exist. | Full calendar/recommendations/trending/custom-list request remains **partial**; live provider confirmation required. |
| #76 | DV routing/remux and artifact contracts exist. | Real DV/HDR10 sink output, pause/seek/resume and sustained playback on selected current build. |

## Release acceptance boundaries

The final source gate must cover exact episode/CW identity, resume at zero and user-seek authority, paused source/engine replacement, bounded next-episode preparation, language continuity, local NNTP admission/cancellation, owner/overlay watched migration, add-on/profile ownership, and the two concrete gaps above. The existing focused runners (`test-issue240-playback-failures.sh`, `test-source-continuity-and-seek-intent.sh`, `test-binge-language-continuity.sh`, `test-local-nntp-playback.sh`, native bridge/migration runners) provide source/policy fixtures, not physical playback proof.

Cinema acceptance must preserve Search, Library, Watchlist, Downloads, Settings, integration/pairing routes, detail actions, episode/source menus and player controls on iOS/macOS/Android touch/Android TV. Simulator screenshots and UI source contracts establish only their recorded surfaces. Root owns final integration builds, independent review, SDK/artifact content, signing, feed/deployment, installed-app/device evidence, and issue closure. No issue comments, closures, release approvals, publication, tags or pushes were performed by this lane.
