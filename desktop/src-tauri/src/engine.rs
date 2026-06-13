//! `DesktopEnv`, `stremio_core::runtime::Env` for the Windows/Linux/macOS Tauri shell.
//!
//! A faithful port of the Apple core's `TvosEnv` (core/src/env.rs), which was itself ported from
//! `stremio-core-kotlin`'s `AndroidEnv`. The implementation is platform-agnostic already:
//!   - `fetch`   : reqwest (native-tls) + serde body/response.
//!   - storage   : a JSON file per key under a host-provided directory.
//!   - executors : two tokio multi-thread runtimes (concurrent + sequential).
//!   - analytics : stubbed (built without the `analytics` feature).
//!
//! Built behind the Tauri backend (Rust↔Rust), so the engine embeds directly with no FFI. The
//! Runtime that drives this Env lives in lib.rs (the Tauri entry), like the Apple core's lib.rs.

use std::convert::TryFrom;
use std::future::Future;
use std::path::PathBuf;
use std::sync::RwLock;
use std::time::Duration;

use chrono::{DateTime, Utc};
use futures::future;
use http::{Method, Request};
use once_cell::sync::Lazy;
use reqwest::{Body, Client};
use serde::{Deserialize, Serialize};
use serde_json::Deserializer;

use stremio_core::models::ctx::Ctx;
use stremio_core::models::streaming_server::StreamingServer;
use stremio_core::runtime::{Env, EnvError, EnvFuture, EnvFutureExt, TryEnvFuture};

/// Host-provided root for persisted buckets (`{dir}/{key}.json`). Set once at engine init.
static STORAGE_DIR: Lazy<RwLock<Option<PathBuf>>> = Lazy::new(Default::default);

/// Effects that may run in parallel (catalog fetches, addon calls, …).
static CONCURRENT_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(8)
        .thread_name("stremiox-concurrent")
        .enable_all()
        .build()
        .expect("concurrent runtime")
});
/// Effects that must not race (storage writes, library sync) run serialized here.
static SEQUENTIAL_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("stremiox-sequential")
        .enable_all()
        .build()
        .expect("sequential runtime")
});

/// Shared HTTP client (native-tls). Built once; connects lazily.
static CLIENT: Lazy<Client> = Lazy::new(|| {
    Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .build()
        .unwrap_or_default()
});

pub fn set_storage_dir(dir: String) {
    *STORAGE_DIR.write().expect("storage dir write") = Some(PathBuf::from(dir));
}

/// Drive a future to completion synchronously, only safe from a non-runtime thread (i.e. init).
pub fn block_on<F: Future>(future: F) -> F::Output {
    SEQUENTIAL_RUNTIME.block_on(future)
}

fn storage_path(key: &str) -> Option<PathBuf> {
    STORAGE_DIR
        .read()
        .ok()?
        .as_ref()
        .map(|dir| dir.join(format!("{key}.json")))
}

/// Uninhabited type, `Env` is implemented on the type, never instantiated.
pub enum DesktopEnv {}

impl Env for DesktopEnv {
    fn fetch<IN: Serialize + Send + 'static, OUT: for<'de> Deserialize<'de> + Send + 'static>(
        request: Request<IN>,
    ) -> TryEnvFuture<OUT> {
        let (parts, body) = request.into_parts();
        let body = match serde_json::to_string(&body) {
            Ok(body) if body != "null" && parts.method != Method::GET => Body::from(body),
            Ok(_) => Body::from(vec![]),
            Err(error) => return future::err(EnvError::Serde(error.to_string())).boxed_env(),
        };
        let request = Request::from_parts(parts, body);
        let request = match reqwest::Request::try_from(request) {
            Ok(request) => request,
            Err(error) => return future::err(EnvError::Fetch(error.to_string())).boxed_env(),
        };
        async move {
            let resp = CLIENT
                .execute(request)
                .await
                .map_err(|error| EnvError::Fetch(error.to_string()))?;
            if !resp.status().is_success() {
                return Err(EnvError::Fetch(format!(
                    "Unexpected HTTP status code {}",
                    resp.status().as_u16()
                )));
            }
            let bytes = resp
                .bytes()
                .await
                .map_err(|error| EnvError::Fetch(error.to_string()))?;
            let mut deserializer = Deserializer::from_slice(bytes.as_ref());
            serde_path_to_error::deserialize::<_, OUT>(&mut deserializer)
                .map_err(|error| EnvError::Serde(error.to_string()))
        }
        .boxed_env()
    }

    fn get_storage<T: for<'de> Deserialize<'de> + Send + 'static>(
        key: &str,
    ) -> TryEnvFuture<Option<T>> {
        let path = storage_path(key);
        future::lazy(move |_| {
            let path = path.ok_or(EnvError::StorageUnavailable)?;
            match std::fs::read(&path) {
                Ok(bytes) => serde_json::from_slice::<T>(&bytes)
                    .map(Some)
                    .map_err(|error| EnvError::Serde(error.to_string())),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(EnvError::StorageReadError(error.to_string())),
            }
        })
        .boxed_env()
    }

    fn set_storage<T: Serialize>(key: &str, value: Option<&T>) -> TryEnvFuture<()> {
        let path = storage_path(key);
        let serialized = match value {
            Some(value) => match serde_json::to_vec(value) {
                Ok(bytes) => Some(bytes),
                Err(error) => return future::err(EnvError::Serde(error.to_string())).boxed_env(),
            },
            None => None,
        };
        future::lazy(move |_| {
            let path = path.ok_or(EnvError::StorageUnavailable)?;
            match serialized {
                Some(bytes) => {
                    if let Some(parent) = path.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    // temp-then-rename so a crash mid-write can't corrupt the bucket.
                    let tmp = path.with_extension("json.tmp");
                    std::fs::write(&tmp, &bytes)
                        .map_err(|error| EnvError::StorageWriteError(error.to_string()))?;
                    std::fs::rename(&tmp, &path)
                        .map_err(|error| EnvError::StorageWriteError(error.to_string()))
                }
                None => match std::fs::remove_file(&path) {
                    Ok(()) => Ok(()),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                    Err(error) => Err(EnvError::StorageWriteError(error.to_string())),
                },
            }
        })
        .boxed_env()
    }

    fn exec_concurrent<F: Future<Output = ()> + Send + 'static>(future: F) {
        CONCURRENT_RUNTIME.spawn(future);
    }

    fn exec_sequential<F: Future<Output = ()> + Send + 'static>(future: F) {
        SEQUENTIAL_RUNTIME.spawn(future);
    }

    fn now() -> DateTime<Utc> {
        Utc::now()
    }

    fn flush_analytics() -> EnvFuture<'static, ()> {
        future::ready(()).boxed_env()
    }

    fn analytics_context(
        _ctx: &Ctx,
        _streaming_server: &StreamingServer,
        _path: &str,
    ) -> serde_json::Value {
        serde_json::json!({})
    }

    #[cfg(debug_assertions)]
    fn log(message: String) {
        println!("[stremiox-core] {message}");
    }
}
