//! # vortx-host-native
//!
//! The native HOST substrate for the vortx-core kernel: the real-world implementations of the three
//! I/O seams the pure kernel deliberately does not own (Phase 1 of the cutover plan).
//!
//! - **Fetch** ([`NativeFetcher`]): tokio + reqwest(rustls) behind the kernel's synchronous
//!   [`vortx_source::Fetch`] boundary. Realizes the kernel's `FetchRequest` plans, in parallel with
//!   per-request time budgets on the [`NativeFetcher::realize_plan`] path, classifies outcomes per
//!   the kernel contract (Ok / Malformed / Timeout / Error), and surfaces circuit-breaker
//!   transitions through [`FanoutReport`].
//! - **Env** ([`SystemEnv`]): the real wall clock behind [`vortx_engine::Env`].
//! - **Storage** ([`Storage`] / [`FileStorage`]): the persistence seam for the JSON buckets the
//!   kernel emits through `get_state_delta_json`, shaped like stremio-core's persisted buckets and
//!   round-tripping byte-equal.
//! - **Debrid** ([`debrid`]): Phase 2 of the cutover, the live HTTP implementations of the
//!   kernel's [`vortx_debrid::DebridStore`] contract (RealDebrid / AllDebrid / TorBox /
//!   Premiumize), behind the same one-runtime `block_on` bridge as `NativeFetcher` and a
//!   record-or-replay transport seam for hermetic tests.
//! - **Exec** ([`QuickJsExec`]): the JS-execution seam. The kernel plans `ExecRequest`s
//!   (`vortx-exec`, pure) and this QuickJS sandbox realizes them, enforcing the budget, memory
//!   cap, and manifest-derived net allowlist; outcomes settle through the same kernel machinery
//!   (and the same circuit breakers) as HTTP fetches. Every byte of JS runs HERE, never kernel-side.
//!
//! The kernel invariant this crate protects: zero `tokio`/`reqwest`/`hyper`/`axum` (and zero JS
//! runtime) in the pure crates. Everything async or effectful lives here, host-side, behind the
//! kernel's own traits. No kernel API changed to build this crate.

mod body;
pub mod debrid;
mod env;
mod exec;
mod fetch;
mod storage;

pub use body::{body_to_items, infer_kind, BodyKind};
pub use env::SystemEnv;
// The exec transports (ExecNet / RecordedNet / HttpNet) are always available: a JavaScriptCore host
// implements the pure `vortx_exec::JsExec` trait itself and drives these to fetch on the script's
// behalf. Only the bundled QuickJS executor is gated behind the `quickjs` feature.
pub use exec::{ExecNet, HttpNet, NetError, NetResponse, RecordedNet};
#[cfg(feature = "quickjs")]
pub use exec::{QuickJsExec, DEFAULT_MEMORY_LIMIT_BYTES};
pub use fetch::{BreakerTransition, FanoutReport, FetchInitError, NativeFetcher};
pub use storage::{FileStorage, Storage, StorageError};
