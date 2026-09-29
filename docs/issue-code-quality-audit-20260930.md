# Open-issue and source-quality audit — 30 September 2026

Baseline: main `df0a96e7a03d3b41ef2f583ad7ad316b6074536a`, after the published Apple Beta 16.
All 52 issues open at the start of this audit were checked against their bodies, relevant comments and
current source. A source-addressed report is **not** the same as a newly reproduced, device-verified fix.
Apple Beta 16 and Android Beta 14 are different artifact baselines; Android parity is not complete.

## Changes in this patch

- **#224:** exact-file subtitle requests carry the selected source's supplied filename, video hash and
  byte count. No torrent infohash is misrepresented as a subtitle hash. Source changes re-key requests;
  malformed individual entries do not discard valid siblings. Release names are visible in the picker.
- **#224:** optional prefer-add-on setting on Apple and Android, preserving Off/Forced policy and manual
  selections. Both subtitle preference booleans now round-trip through Android account settings.
- **Android playback:** adding a sidecar preserves Media3's current position and play/pause intent rather
  than restarting a paused session. Duplicate sidecar URLs do not rebuild the item again.
- **#142:** batch resolution detects another title taking the shared metadata slot. It reasserts the
  exact title/episode and starts a fresh settlement window only for lost ownership. Ordinary empty
  searches still terminate after 20 seconds; repeated navigation has a 60-second total bound.
- **Web playback:** consume the live SkipDB object-map/millisecond schema; retain separate intro, recap,
  credits and preview labels. Unknown or invalid spans are omitted, not mislabeled as intros.
- **Web sources:** render 40 rows per page, preserve original ranked group/index identities and add an
  explicit refresh action, including the no-source state. Duplicate refresh clicks share the active
  request. Superseded title/episode requests cannot repaint or start unintended playback.
- **Cleanup:** centralize duplicated preferred-subtitle selection, TMDB subtitle-ID rewriting and concise
  source labels across Apple player surfaces. Strict title-prefix matching also prevents `tmdb:45`
  rewriting an unrelated `tmdb:456` video. Platform-specific focus and player lifecycle remain separate.
- **Regression gates:** native policy/HTTP fixture runner and secretless source-contract CI; web tests
  execute real detail actions with fixture transport, not just string searches.
- **Android CI:** real packaging and security-analysis runs failed before compilation because the pinned
  SDK setup action defaults to the removed standalone `tools` package. All four SDK lanes now request
  supported platform/build tools explicitly; release contracts guard the action blocks against regression.

## Complete issue disposition

“Source-addressed” means a relevant implementation exists in current source. It remains open when
hardware, provider or cross-device confirmation is missing. “Partial/feature” identifies actual work
still absent, not something being described as merely awaiting testing.

### Apple and playback — 17 issues

| Issue | Area | Disposition |
| --- | --- | --- |
| #225 | iOS login dismissal | Source-addressed with a one-shot sign-in callback; iOS 27 reproduction still needed. |
| #224 | Exact-file add-on subtitles and preference | Implemented here; native HTTP, encoding, preference and remount tests. Provider/device rendering still needs confirmation. |
| #223 | Premature end / next episode | Earlier identity-fenced EOF fixes retained; current physical playback confirmation required. |
| #222 | iOS crash before playback | No actionable current crash stack; existing player initialization guards are not proof of a universal fix. |
| #221 | Episode focus jumps | Stable IDs and first-row focus boundary exist; Siri Remote confirmation required. |
| #217 | Infuse episode metadata | Handoff identifiers/filename implemented; external-player recognition still needs confirmation. |
| #214 | Unlimited cache starvation | Existing bounded RAM/cache policy retained. Unlimited disk is not unlimited RAM; sustained physical throughput remains open. |
| #213 | Source long-press player choices | Implemented in current source. |
| #206 | Source-list Up focus jump | First-row/filter-boundary policy present; physical focus confirmation required. |
| #195 | eARC audio | Route-aware audio policy present; TV/receiver matrix remains unverified. |
| #188 | Apple TV HD crash | Constrained-device limits and initialization guards exist; missing current crash evidence. |
| #182 | Older iPhone series hang | Source/episode ownership recovery present; current-device reproduction still needed. |
| #178 | macOS CPU usage | Bounded lists/hidden-player pause/capture admission mitigations exist; measured Instruments validation remains open. |
| #163 | Atmos | DD+ path present; TrueHD passthrough limitations must not be reported as fixed by the same change. |
| #147 | PiP | AVPlayer implemented; libmpv PiP after engine fallback remains a feature gap. |
| #146 | Scroll-to-top affordance | Existing implementation present. |
| #76 | DV / HDR behavior | Beta 16 routing/remux repairs retained; sustained DV pause/seek/overnight playback is not proven by source tests. |

### Sync, integrations and product work — 23 issues

| Issue | Area | Disposition |
| --- | --- | --- |
| #226 | Windows release | No current Windows release artifact; platform work remains. |
| #220 | Plex PIN/link flow | Current PIN/link fixes and contracts exist; live Plex confirmation remains. |
| #215 | Profile discovery isolation | Schema and contract implementation present. |
| #212 | Debrid cloud search | Apple and Android implementation present. |
| #205 | Add-on resurrection/order | Tombstones, ordered hydration and explicit-import handling exist; cross-device convergence still needs verification. |
| #204 | Audio language picker | Current Apple implementation and contracts present. |
| #203 | French phrase translation | Phrase-first matching and strings present; broader localization is not implied complete. |
| #198 | Waiting release approvals | Five obsolete runs cancelled after ancestor/artifact checks; protected engine approval gate unchanged. |
| #197 | Old approval alert | All five listed runs already cancelled; stale alert resolved. |
| #196 | IPTV | Current flows exist; report lacks a current provider/manifest/playback receipt. |
| #187 | Trakt multi-device token refresh | Recovery implementation exists; real multi-device provider behavior still needs confirmation. |
| #165 | Non-IMDb metadata | TMDB/TVDB/Kitsu fallback and bounded terminal retry present. |
| #164 | Trakt cache/artwork/scrobble | Current implementation/contracts present; not universal artwork proof. |
| #153 | QR / website auth | Query/hash/return-route/manual approval rescue implemented; full device-to-site flow still needs verification. |
| #152 | Source capability/index routing | Current HTTP/torrent/Usenet capability gates and hint propagation present. |
| #149 | CW provider selection | Trakt CW/artwork implementation present; Local/Trakt/SIMKL selector is still absent. |
| #142 | Batch-download shared metadata race | Target-aware bounded recovery implemented here; deterministic policy tests plus exact production ownership fences. |
| #139 | Library organization | Type/smart filters exist; genre grouping needs actual genre data on library entries. |
| #136 | Source/language feature bundle | Several filters exist; complete feature bundle is not claimed finished. |
| #132 | Background download -3000 | Bounded classifier/self-heal present; locked-device/background confirmation remains. |
| #131 | Broad modern-UI request | Partial product work, not a single closed defect. |
| #129 | SIMKL feature bundle | Auth/history/scrobble/upcoming implemented; full calendar/recommendations/trending/custom lists remain. |
| #137 | Removed add-ons returning | Current removal/import fences present; linked to #205 cross-device verification. |

### Android — 12 issues

| Issue | Area | Disposition |
| --- | --- | --- |
| #219 | Apple TV parity | Partial; current feature map is not full TV UI/interaction parity. |
| #186 | Add-on URL installation | Configure page is not the personalized manifest; valid-manifest transport is implemented. No confirmed new parser defect. |
| #174 | Multi-device downloads | Missing remote-job/ownership protocol; device-local downloads are not this feature. |
| #173 | Local download HDR/DV/Atmos | Metadata/capability/routing present; signed APK and physical decoder/output validation remain. |
| #172 | Similarity threshold | Missing reliable provider confidence input. Do not expose an inert threshold slider. |
| #171 | Ordered audio/subtitle priorities | Current editor/persistence implementation present; device confirmation remains. |
| #170 | Background download survival | Foreground worker/resume implementation present; process-death device test remains. |
| #169 | Royal theme | Theme/profile implementation and tests present; old artifact report needs current APK confirmation. |
| #168 | Broad UI parity | Partial product work. |
| #167 | Download reconnect/resume | Strong-ETag/range/retry policy present; socket-loss device confirmation remains. |
| #166 | Dubbed-label parsing | Partial language-specific parsing. Unspecified “dubbed” is not evidence of an English audio track. |
| #154 | Fire TV 32-bit ABI | ABI/packaging changes present; actual signed package/install verification remains. |

## Unfinished branch safety

No old player or engine branch was blindly merged into current main. The unfinished Android watched-download
reclamation work is not safe to port wholesale: its local-playback guard suppresses the completion it should
handle, a watch write can be non-durable, and failed index persistence cannot restore a file already deleted.
Finishing that feature requires exact immutable profile/content/episode ownership, durable watch evidence,
recoverable file/index transactions and executable failure-path tests. The current toggle remains unwired;
this audit does not call it complete.

## Competitor ideas adopted and deliberately not copied

- [NuvioTV 0.9.3 beta](https://github.com/NuvioMedia/NuvioTV/releases/tag/0.9.3-beta)
  documents stream-list pagination. VortX now uses bounded web source pages without changing add-on ranking.
- [NuvioMobile 0.5.4 beta](https://github.com/NuvioMedia/NuvioMobile/releases/tag/0.5.4-beta)
  emphasizes resume/player lifecycle work. VortX's concrete implementation here is pause-preserving Media3
  sidecar remounting and request-owned web navigation, not copied player internals.
- [Infuse release notes](https://firecore.com/releases) distinguish skip controls;
  [AIOStreams 2.35.3](https://github.com/Viren070/AIOStreams/releases/tag/v2.35.3) includes per-segment work.
  VortX web now preserves the four native segment categories and fixes its live response contract.
- [Harbor 0.9.21](https://github.com/harborstremio/harbor/releases/tag/V0.9.21) emphasizes recoverable source
  states. VortX now provides a concrete refresh action rather than leaving an inert no-source button.

The wider Brain competitor inventory was also checked. Undated changelogs, ambiguous product names and old
releases were not represented as fresh 2026 feature evidence. Ideas were implemented against VortX's own
contracts; no competitor source was copied.

## Verification boundary

Native HTTP fixtures exercise exact-file and legacy routes, reserved/Unicode characters, large byte counts,
partial malformed responses, both 404/405 fallbacks and non-retried server errors. Pure policy tests cover
subtitle priority/Off/Forced and late/early metadata preemption, empty deadlines and the repeated-preemption cap.
Web tests execute refresh deduplication, source-page click identity, filter reset, stale metadata and
superseded next-episode callbacks.

Local verification of the final source passed:

- iPhone and tvOS Release builds; native macOS arm64 Release build, all with signing disabled.
- Android Play: 1,227 unit tests; Full: 1,300 unit tests, with no failures, errors or skipped tests.
- Web type checking, 52 tests and production build, using the repository's npm 11.17.0 pin.
- Strict-concurrency Swift HTTP/policy fixtures for subtitles, metadata-slot recovery, source presentation
  and track selection. The new secretless CI lane repeats these fixtures and the web checks.

No fresh physical TV playback log was obtained in this audit: the device-container copy timed out. This patch
does not claim an overnight DV, receiver-audio or live-provider throughput pass. Local Mac universal linking
also requires an x86_64 engine slice not present in the local vendor cache; arm64 validation must be reported
separately from universal release validation. No new release or signing/feed change is part of this patch.
