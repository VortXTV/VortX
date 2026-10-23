# Ecosystem source audit status — 17 October 2026

This is a source audit and reviewed repair batch, not a release or a claim that
every line has been reviewed. The local private coverage ledger accounts for
18 repositories, including app/platform code, engines, sync/site, support
services, database schemas, infrastructure and historical/upstream trees.
Large runtime inventories received focused detailed review plus wider searches;
unread/sampled areas remain explicitly open in that ledger.

## App repairs integrated

- Android account-global edits now arm sync, restoration reports admission
  accurately, and failed native receives cannot be hidden by a later push.
  A valid comparison-mode no-op restore settles only after durable receive
  acknowledgement and a final account check.
- Android list imports validate each redirect and the connection's DNS results,
  constrain headers, enforce time/byte/hop limits, and preserve pooling. Import
  tests use loopback fixtures, not real providers/accounts.
- Apple recommendations and metadata can recover from failed loads without
  persistent cache poisoning. Artwork keys distinguish media types. Superseded
  scrub requests cancel queued disk work per player without affecting peers.
- Watched migration source pooling and lazy historical evidence reduce repeated
  data and bound replay work. See `watched-migration-audit-20261017.md` for the
  precise caps and remaining fresh-producer/resource limitations.
- Browser account/session ownership fences delayed hydration, queued writes,
  sockets and household adoption. Pending account journals remain durable.
  Locally accepted resets get key-bound floor namespaces; v2 reads keep writes
  v2. Other-device/origin reset recovery remains a separate protocol issue.
- Browser routing handles malformed encoded links; departed/replaced views and
  player sources cannot complete into the current view. Add-on admission rejects
  malformed envelopes without leaking configured URLs. Recent-search storage
  distinguishes native/account/binding scopes. CSP admits the expected sync socket.
- Source/release checks fail closed on API/scanner errors and validate actual
  artifact/platform presence. No package was built or release gate exercised live.

## Verification

| Area | Actual local result | Boundary |
| --- | --- | --- |
| Android selected source | 86 standalone JVM tests; 14 source-extracted decision cases; seven complete receive-method groups | Synthetic collaborators, not full Android/Compose compile or device proof |
| Apple UI/data helpers | ForYou 44 model + 18 rows; localized metadata 10; artwork six; scrub six | Host tests, not measured device smoothness |
| Apple watched migration | Archive/adversarial, existing producer/bootstrap and pinned boundary suites pass; independent final review | No new SDK/app build or physical-memory proof |
| Public browser | Pages contract; 177 passed, zero failed, one intentional site-only skip; TypeScript clean | No browser/device/rendered deployment acceptance |
| Release-feed logic | 63/63 | No new release or feed promotion |

The wider website suite separately passes 311/311. Supporting repositories have
their own source/test records and scoped review-branch commits.

## Dependency remediation

The public browser's six high npm audit entries were development-only: four
advisory-bearing leaves and two inherited parent entries. The reviewed update
pins Wrangler 4.149.0 with its supported Miniflare/sharp/undici dependency graph,
and refreshes nanoid/source-map-js patch versions. Production dependency records
and runtime dependencies are unchanged. A clean locked install with scripts
disabled, the full browser tests, TypeScript check and fresh complete npm audit
pass; the final npm audit reports zero vulnerabilities. This does not certify
all dependencies of other repositories or erase their separately recorded debt.

## Still open

Large Android watched evidence, fresh Apple migration output accumulation,
engine history-dependent serialization, full player scheduling/image/UI linkage,
legacy browser backup/account attribution, household key-delivery protocol,
desktop dependency provenance and selected service moderation/cache/retention
findings still need work. An inventory or passing targeted suite is not closure
of those findings. Historical and upstream trees were preserved, not auto-merged
or deleted.

No app build, launch, playback, installation, account reset, real-account write,
database cleanup/migration, deployment, tag or release was performed. Database
production checks were read-only and structural; they do not establish decrypted
content correctness or multi-device convergence.
