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
//!
//! The kernel invariant this crate protects: zero `tokio`/`reqwest`/`hyper`/`axum` in the pure
//! crates. Everything async or effectful lives here, host-side, behind the kernel's own traits. No
//! kernel API changed to build this crate.

mod body;
mod env;
mod fetch;
mod storage;

pub use body::{body_to_items, infer_kind, BodyKind};
pub use env::SystemEnv;
pub use fetch::{BreakerTransition, FanoutReport, FetchInitError, NativeFetcher};
pub use storage::{FileStorage, Storage, StorageError};
