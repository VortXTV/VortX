# tvOS re-base on `stremio-core`, design & progress

**Goal:** replace the hand-rolled tvOS data layer (addon HTTP client, library, Continue-Watching,
meta resolution) with the **real Stremio engine** (`stremio-core`, Rust), the same engine the
official app uses, so catalogs / library / Continue-Watching / addon handling / metadata are
correct **by construction** instead of reverse-engineered. Keep our libmpv player + nodejs-mobile server.

## Why
The recurring tvOS bugs (incomplete catalogs / "big blank gap then 2 rows", Continue-Watching that
doesn't match the official app, "couldn't load details", addon edge cases) all come from
re-implementing Stremio's addon/library protocol by hand. The official app embeds `stremio-core` and
doesn't have them. User confirmed (2026-06-05) the rebase is the right call.

## Architecture, DECIDED: serde-JSON over a C ABI (NOT protobuf)

stremio-core has two official bindings: `stremio-core-kotlin` (protobuf over JNI) and
`stremio-core-web` (serde→JS over wasm). For a Swift app, **serde-JSON over the C ABI** wins: Swift
`Codable` is native, no `.proto`/swift-protobuf codegen, JSON is debuggable. Verified across the
engine source:
- Every model-state struct derives `serde::Serialize` → state out as JSON (`serde_json::to_string`).
- `Action` (+ all sub-actions) derive `Deserialize` → actions in as JSON.
- `RuntimeEvent` derives `Serialize` → events out as JSON (`{"name":"NewState","args":["board",…]}`).
- `RuntimeAction` is **Debug-only** (not serde) → we deserialize a DTO `{field, action}` and assemble.

### The two user-facing bugs map to exact engine mechanisms
- **Continue Watching** = `ContinueWatchingPreview`, which **auto-derives from `Ctx.library` +
  notifications with NO load action**. Once buckets hydrate from storage it is correct. (The official
  ordering/filtering is `is_in_continue_watching() || has_notification`, newest first, cap 100.)
- **Home board** = `ActionLoad::CatalogsWithExtra { type: None, extra: [] }` then
  `ActionCatalogsWithExtra::LoadRange(0..N)` → enumerates **every catalog of every installed addon**.

## Step 2, the Rust FFI bridge  (DONE, host-compiles; tvOS cross-compile in progress)
Crate `core/` (`crate-type=["staticlib"]`). Files:
- **`core/Cargo.toml`**, `stremio-core { features=["derive","env-future-send"] }` (env-future-send is
  REQUIRED so `EnvFuture=Send BoxFuture` for the multi-thread host; wasm-incompatible). Plus
  serde/serde_json/serde_path_to_error, tokio(rt,rt-multi-thread,time), reqwest(rustls-tls), http,
  futures, once_cell, chrono. NO protobuf/prost/jni/analytics.
- **`core/src/env.rs`**, `TvosEnv: Env`. fetch = reqwest+rustls (ported from kotlin fetch.rs);
  storage = JSON file per key under host dir (`{dir}/{key}.json`, temp+rename); two tokio runtimes
  (concurrent 8 / sequential 1); `now`=Utc::now; analytics stubbed; `block_on` helper for init.
- **`core/src/model.rs`**, `#[derive(Model)] #[model(TvosEnv)] TvosModel` with fields: `ctx`,
  `continue_watching_preview`, `board`, `discover`, `library`, `continue_watching`, `meta_details`,
  `streaming_server`, `player`. `get_state_json(field)` = `serde_json::to_string` per field. The
  derive generates `TvosModelField` (snake_case Serialize/Deserialize).
- **`core/src/lib.rs`**, C ABI (all wrapped in `catch_unwind`):
  - `stremiox_core_init(storage_dir, cache_dir, ctx, on_event) -> bool`, migrate schema, hydrate 8
    buckets (profile/library_recent/library/streams/streaming_server_urls/notifications/
    search_history/dismissed_events), build `TvosModel::new`, `Runtime::new(model, effects, 1000)`,
    spawn `rx.for_each` → `serde_json::to_vec(event)` → Swift callback.
  - `stremiox_core_dispatch(action_json)`, `{ "field": <field|null>, "action": <Action> }`.
  - `stremiox_core_get_state(field_json) -> *char` (malloc'd JSON; free with …_string_free).
  - `stremiox_core_string_free(ptr)`, `stremiox_core_schema_version()`.
- **`core/include/stremiox_core.h`**, matching C header.
- `Ctx::new` on `development` takes **7 args** (incl. `ServerUrlsBucket` at #4), gotcha vs the older
  pinned web version (6 args).

xcframework build: `scripts/build-core-xcframework.sh` → `app/Vendor/StremioXCore.xcframework`
(device `aarch64-apple-tvos` + sim `aarch64-apple-tvos-sim`, via `-Z build-std=std,panic_abort`).
**RISK being tested now:** reqwest→rustls→ring/aws-lc cross-compiling to tier-3 tvOS. If it fails,
fallback = route `Env::fetch` through a Swift `URLSession` C callback (no native crypto).

## Step 3, Swift integration + per-screen migration  (NOT STARTED)
1. Add `StremioXCore.xcframework` to `app/project.yml` (link like NodeMobile).
2. `CoreBridge.swift`, call the C ABI; register the `on_event` C callback (decode `RuntimeEvent`
   JSON on a bg thread → hop to main → re-pull changed fields); expose `@Published` per-screen state.
3. Codable structs for the JSON shapes (LibraryItem+state, MetaItemPreview, ResourceLoadable,
   Catalog pages, MetaDetails, Stream, …). Watch units: core uses **ms** for time_offset/duration.
4. Migrate screens to read CoreBridge instead of StremioAccount/AddonClient, in priority order:
   **Continue Watching + Board first** (the reported bugs), then Discover, Detail, Streams, Library.
5. Login + storage migration: existing app stores its own authKey (UserDefaults). stremio-core wants
   a persisted `Profile` (auth + addons) under storage key `profile`. Plan: on login dispatch
   `ActionCtx::Authenticate(AuthRequest)`; for users already signed into the old app, seed/auth once
   then `SyncLibraryWithAPI` + `PullAddonsFromAPI` (needs profile.auth_key Some).
6. Keep the hand-rolled path until each screen is migrated + verified, no big-bang switch.

## Gotchas (from the 3 binding studies)
- Panics across the C ABI = UB → every entrypoint wrapped in `catch_unwind` (done).
- `env-future-send` mandatory; all Env futures must be `Send`; don't hold a lock guard across `.await`.
- Two lock layers (outer `RwLock<Option<Runtime>>` + Runtime's inner `RwLock<Model>`); std RwLock
  poisons on panic, catch_unwind mitigates; consider parking_lot later.
- `RuntimeAction` not serde → DTO shim (done). `ActionLoad` is tagged `"model"` not `"action"`.
- Event callback fires on a tokio worker thread; Swift must copy bytes synchronously + hop to main.
- `get_state` serializes on the caller's thread → call off the main thread in Swift for big lists.

## Status / next
- ✅ Step 1 (engine cross-compiles to tvOS), proven; staticlibs exist.
- ✅ Step 2 bridge written; **host `cargo check` green**; tvOS cross-compile running.
- ⏭ Verify xcframework builds (both slices) → Step 3 Swift `CoreBridge` + migrate Continue Watching
  + Board first → verify against the user's real account → then the rest → publish.

> Branch `stremio-core-rebase` (now merged with latest `improve-official-1.3.6` UI). The shippable
> hand-rolled build remains on `improve-official-1.3.6` until screens are migrated + verified.
