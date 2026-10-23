# Browser data transactions — unwired first unit

This module is not imported by the app. It is a candidate implementation of the accepted production-storage P1–P4 contract (7634fdf3), not a migration, rollout, W1 closure, browser proof, or substitute for the existing M1 module.

## Authority and lifecycle

Importing the module does not open IndexedDB or create schema/context. The explicit native factory opens the fixed `vortx.web.data.transactions.v1` database, permits creation only with `allowCreate:true`, audits it, and returns an unwired plane. Existing unknown schema/corrupt rows are refused, never normalized/deleted. Version changes close cooperating connections. No DB deletion, fallback namespace or localStorage lookup exists.

`currentAdmission` supplies a canonical JSON string containing exact context tuple, epoch and generation. `createContext` and `advanceEpoch` are explicit lifecycle mutations; they neither discover an account nor transfer another owner's records. The latter accepts only a one-step same-context epoch advance. Caller integration must separately authorize these lifecycle decisions.

`admit(commandText)` creates a private one-shot operation handle and a cryptographic nonce. `prepare(handle)` allocates at most once and atomically reserves the full future attempt/data budget. `apply(handle)` re-reads and executes the stored explicit Library membership command once. `resolve` and same-owner `discover` never apply or recreate work. Request success is not commit: local terminal outcomes require transaction completion or a completed durable read.

Public result names are `admitted`, `prepared`, `committed`, `unchanged`, `rejected` (durable recoverable proposal), `prepare-aborted`, `pending`, `details-retired`, and `unavailable`, plus lifecycle/snapshot/discovery/observation results. `pending` never licenses replay. A new admission is a new user operation, not an automatic retry. A missing allocated row is not noncommit. A cached terminal outcome is historical and does not authorize current UI/cloud/export effects.

One deliberate same-owner `observe(authenticReceipt)` can retire observed committed/unchanged technical attempts if current membership/tombstone or a later membership revision covers the effect and there are zero outbox references. Rejected proposals never retire. Retirement changes only technical attempts, intervals and accounting; user records/history/tombstones remain. Suspended consumers receive their cached historical result or `details-retired`, never invented replay authority.

## Recovery admission: generation is not epoch

Generation guards a volatile callback/surface handle. An old G1 handle does not become current merely because owner and epoch still match: applying it after the provider changes to G2 preserves the proposal as a rejected recoverable attempt. The existing saved G1/G2 old-handle schedule remains.

A reload loses that handle. An explicitly admitted recovery consumer with current G2 may discover a prepared G1 operation for the EXACT same owner/profile/native binding and durable epoch. Discovery is readonly: it neither allocates another sequence nor applies the proposal. A separate explicit apply of that discovered reference uses the renewed consumer admission and the SAME stored sequence/nonce/command; it is not a payload-based retry or a new PREPARE.

A changed durable epoch is different. A G2 consumer can discover the older-epoch proposal for recovery, but explicit apply rejects execution and preserves the original proposal. Observation of the rejection never deletes it. Security/session retirement requiring old proposals to become ineligible MUST advance the epoch; changing only the ephemeral generation is not that policy. The real application's admission/session/epoch mapping is not implemented or approved here. Caller ports, current-effect guards, account transitions and rollout remain HOLD.

## Representation, budgets and conservation

Ingress is bounded canonical JSON text, not arbitrary structured-clone input. Keys use exact context and `(type,id)` tuples with explicit null encoding. Schema/index framing and repeated identity are charged. Existing entry JSON is preserved in place; supplied seeds are used only for new records. Removing absent membership creates a durable tombstone/revision. Matching membership is a true no-op for user data and data revision, but still consumes an operation sequence and persists its terminal attempt.

All frozen limits remain in `DATA_LIMITS`: 32 contexts; 4,096 user rows including tombstones; 64 KiB/row; 4 MiB live plus reserved context/data capacity; 32 retained attempts; 160 KiB/attempt; 2 MiB shared pending/global/attempt/outbox reservation; 128 KiB command; 4 KiB result; 33 retired intervals/context; safe integer sequence/revision/epoch; 32 realm admissions/jobs, 2 MiB capture and 10-second pre-entry wait. Bytes mean twice canonical UTF-16 string length, not native disk/heap bytes.

Prepare conservatively reserves 160 KiB attempt +64 KiB/one user slot, plus 128 KiB for the sealed inert fixture outbox only. Thus ordinary simultaneous prepares normally stop at twelve and fixture prepares at seven before the count limit. Near a full live budget even a small edit/no-op can refuse. No capacity is obtained by deleting unresolved material, user data, unknown values, or cycling databases.

Library creates no outbox. The fixture factory alone exposes the closed inert intent used to test atomic insertion; it has no sender, claim, ACK-clearing or arbitrary reducer. Recovery-store reads fail closed on any row in this first unit: there is no archive/import API, so the frozen recovery ceilings are not an activation of that feature.

The callback adapter fetches one native value at a time. Cross-row handoffs retain canonical strings, scalar counters and bounded numeric interval bookkeeping, not full decoded predecessor rows. Metadata rewrites parse one serialized row in a short helper frame; apply and observation use post-decode continuations. One-shot native request handlers are detached. Serialized writes remain separately bounded at 512 KiB/transaction. These are source-level retention bounds, not a guarantee about JavaScript GC/RSS or IndexedDB internal request clones.

Snapshots are one readonly transaction, <=4 MiB serialized output and <=4 MiB+16 KiB value-read work (the live-data/context budget plus one separately charged global metadata row); discovery is one readonly transaction, <=32 attempt values, <=2 MiB+32 KiB read work and <=256 KiB summaries, using one key cursor/value request at a time. Initial audit is <=4,321 value reads and 8 MiB, including any fixture-outbox source rereads. A single corrupt oversized native value can be cloned by IDB before JavaScript rejects it. No XSS isolation or malicious-writer allocation guarantee is claimed.

Private handle evidence is charged conservatively at admission and <=160 KiB; receipt evidence is <=24 KiB. No global completed-receipt list exists. Future callers must separately limit themselves to <=32 combined handles and one <=4 MiB current snapshot. External references can retain data; no GC claim follows from WeakMaps.

## Verification and activation gates

The deterministic tests import this actual module. Their synthetic port implements request scheduling, atomic commit/abort, lost delivery and expiring native-row leases—not a duplicate reducer/accounting engine. They cover identity/lost PREPARE, abort-after-request-success, stale consumers, quota, conservation, terminal caching, no-op semantics and technical retirement beyond 128 operations. Fourteen boundary groups add literal exact/first-representable-overage fixtures and closed-schema dominance checks; a structurally unreachable bound is not described as an executed positive boundary. Native-row lease checks are access-lifetime assertions, not heap measurements.

Root's retained serial source-unit verification on Node 22.23.2 passed all **59 core tests**, all **7 native-adapter callback schedules**, and scoped strict no-emit checking with the project's original options and installed TypeScript 5.9.3. No package build or browser database was opened. The native schedules exercise the actual adapter through a deterministic IDB shim, not a real browser.

The same final core fixture against the preceding source produced exactly one failure: B08's full-live snapshot returned `unavailable/read-work-limit` instead of `snapshot` (58/59 passing). After changing only snapshot value-read capacity to include its separately accounted global metadata row, the identical executed fixture passed 59/59. Copied execution inputs differ only in the production module; live data/output limits remain unchanged. All retained owner, execution-input and tool fences matched before and after each stage; Node executable/library, compiler inputs, expected counts, supervisor nonces and normal completion were checked. This is attributable local regression evidence, not a memory, latency, durability or installed-device result.

Real-browser transaction/reload/crash/multitab/upgrade/quota/private-mode evidence remains required. The limits and synchronous adapter checks do not prove physical storage behavior or native allocation peaks.

No caller, DOM, Account Watchlist, native Library, credential, journal, cloud sender, backup/export/restore or legacy adoption path is ported. Unmodified released localStorage writers are not fenced by this IDB design. Complete caller-family inventory, old-tab cutover, owner/privacy/conservation and original-byte preservation gates remain HOLD under the accepted contract.
