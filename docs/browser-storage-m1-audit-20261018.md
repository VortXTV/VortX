# Browser storage M1 — source-unit milestone, 18 October 2026

Preparation only. The new module has no application caller. It does not initialize,
adopt, migrate, export, compact or delete existing browser data. Its constructor and
first reads perform no writes; absent authority is an explicit uninitialized result.
Only explicitly seeded synthetic-M1 state is supported at this milestone.

## Storage and ownership contract

Cooperating writers use the fixed origin-exclusive `vortx.web.storage.writer` Web
Lock. One authoritative descriptor binds the operation, parent, checkpoint, batch
head, generation and context epochs in the distinct `vortx.web.storage.m1.v3.`
namespace. Logical read/modify/write occurs inside the lock. A synchronous draft is
revoked when its callback ends; exceptions and returned thenables cannot publish.

Reads fully validate canonical records and lineage, then recheck raw source bytes.
Staging a record does not prove publication. Ambiguous outcomes retain the original
attempt without replaying its callback or overwriting an acknowledged successor.
Definite noncommit requires the complete exact prior source; current effect permission
requires the exact acknowledged batch, operation, payload, identity and descriptor.
Already queued resolutions preserve a cached terminal result after owner retirement.

Owner/session/native binding is captured and rechecked, never retargeted. Authentication
itself is not atomic with this data lock. A storage acknowledgement is not cloud sync
acceptance or authority for a retired UI surface. Old/raw/v2 writers do not participate
in this protocol and are not silently adopted or made transactional by its lock.

## Finite preparation limits

| Material or work | Ceiling |
| --- | --- |
| Logical key / projected slots | 4,096 UTF-16 units / 4,096 slots |
| Authority / checkpoint and materialized projection | 16 KiB / 4 MiB |
| Changed slots / serialized batch | 128 / 512 KiB |
| Active batches / serialized chain | 128 / 2 MiB |
| Retained namespace records / physical key and value bytes | 512 / 8 MiB, including authority and staged/orphan records |
| Queued jobs / captured payload | 32 per tab / 2 MiB |
| Unfinished recovery evidence across retained contexts | 2 MiB, including the complete prior source |
| Coherent read attempts / pre-entry wait | Two / 10 seconds |
| Whole-origin key-name enumeration | 4,096 slots; unrelated old values are not loaded |

Serialized byte accounting uses twice the UTF-16 string length, including envelope
and key overhead. Quota can fail earlier. No eviction, lease stealing or unlocked
durable fallback is provided. A readable source may exceed the recovery budget for
a new edit; that edit fails before staging without narrowing its proof or deleting data.

These are not process-memory or sustained-playback guarantees. Externally held snapshot,
commit and attempt tokens, and escaped but revoked drafts, can retain historical data.
Their caller-controlled lifetime, peak allocations and GC timing remain unmeasured.
The 128-batch ceiling requires a separately reviewed retention/checkpoint policy before
application use; it is not a long-session solution by itself.

## Verification and remaining gates

All 65 actual-module synthetic test cases pass. They cover logical RMW interleavings,
ordered removals, multi-key epochs, owner retirement, quota/readback failures, ambiguous
publication, orphan non-proof, exact-source restoration, byte/record/work boundaries,
proof tampering, terminal duplicate resolution and unchanged old/raw/v2 bytes. The
unchanged tests against the original module fail seven cases, including each of the
three proof/terminalization regressions. These are executed source counterexamples,
not observed customer incidents or memory measurements.

The targeted no-emit TypeScript check passes with the project's ES2021/ESNext/bundler,
DOM, strict and no-unused options. Verification used recorded Node 26.7.0 and TypeScript
5.9.3, serial low-priority jobs and retained source/input/tool fences. This does not
establish an exact Node 22 CI run, a full application typecheck, build or browser test.

Real-browser Web Locks/storage behavior, private-mode/quota behavior, caller lifetimes,
initialization/adoption/migration, complete exports, intent journals, hydration/cloud
acknowledgements, owner-bound DOM retirement and all application caller ports remain
open. No installed app, real account, live checkpoint, production migration, deployment,
package build or release was exercised by this milestone.
