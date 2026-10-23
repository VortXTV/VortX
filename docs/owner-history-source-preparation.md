# Stremio owner-history source preparation

The owner-history source components prepare and validate historical Stremio data.
They do **not** currently activate an import from the sign-in screen. The native
runtime, checkpoint, complete-account export and peer integration remain separate
requirements; this component alone does not resolve issue #267.

`VortxNativeOwnerHistorySource` captures the original acknowledged owner or shared
profile, revalidates the authenticated Stremio identity, and retains the exact
library response after ambiguity, size and credential-carrier checks.
`VortxNativeOwnerHistoryPreparation` adds the original add-on registry and required
episode metadata, then runs the existing row/time/watch converters. Missing or
ambiguous evidence stays pending rather than becoming a successful import.

The original response bytes and unknown fields remain available for cold replay.
No historical fact is rewritten as a new playback, watched or library action at
the current time. Removed or temporary source rows do not create new membership
tombstones. The owner is not relabelled as a secondary account to bypass native
binding checks. Source bytes, private URLs and credentials must never enter public
fixtures or diagnostic output.

## Focused verification

Run one stage at a time from the repository root on macOS:

```sh
bash scripts/test-native-migration-phase-a.sh owner-source
bash scripts/test-native-migration-phase-a.sh owner-prepare
bash scripts/test-native-migration-phase-a.sh watched
```

The first two stages compile the actual source, transport, identity and conversion
declarations with synthetic injected responses. The third checks the existing
watched-migration path after the shared metadata-worker changes. Each stage retains
its immutable inputs, compiler/runtime logs and supervised exit receipts under
`app/build/native-migration-<stage>.*`. The runner uses Swift 6 complete concurrency,
warnings as errors, one compiler job/thread and low process priority. It does not
build an app or SDK, fetch a real account, access system credentials, write a live
checkpoint or prove device/peer behavior. Stop on failure before starting another
stage, and preserve failed receipts.
