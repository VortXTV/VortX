//! The live torrent backend over librqbit (the rqbit engine): magnet adds by
//! infoHash with injected HTTP/HTTPS trackers, streaming file reads that
//! block until pieces arrive, and a self-bounded on-disk piece cache.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent, Session, SessionOptions};
use tokio::sync::{Mutex, OnceCell};

use crate::backend::{valid_info_hash, BackendError, OpenFile, TorrentBackend};
use crate::contract::{source_entries, EngineStats, FileEntry};
use crate::settings::SettingsStore;

/// The swarm-reaching TCP/TLS trackers injected into EVERY create, mirroring
/// the app's TorrentTrackers list: UDP/DHT are dead in the tvOS sandbox, so
/// HTTP(S) trackers are what let a torrent find peers at all.
pub const DEFAULT_TRACKERS: &[&str] = &[
    "https://tracker.alaskantf.com:443/announce",
    "https://tracker.bt4g.com:443/announce",
    "https://tracker.moeblog.cn:443/announce",
    "https://tracker.pmman.tech:443/announce",
    "https://tracker.zhuqiy.com:443/announce",
    "http://open.tracker.cl:1337/announce",
    "http://tracker.opentrackr.org:1337/announce",
    "http://tracker.files.fm:6969/announce",
];

/// How long an auto-create (bare file GET) may wait for metadata; explicit
/// creates are bounded by the HTTP handler's own 70 s timeout.
const AUTO_CREATE_TIMEOUT: Duration = Duration::from_secs(70);

/// librqbit's handle alias (not re-exported at the crate root in v8).
type ManagedTorrentHandle = Arc<ManagedTorrent>;

struct Entry {
    cell: Arc<OnceCell<ManagedTorrentHandle>>,
    /// The FIRST create's peerSearch sources (they stick; server.js parity).
    sources: Vec<String>,
}

pub struct RqbitBackend {
    session: Arc<Session>,
    cache_root: PathBuf,
    entries: Mutex<HashMap<String, Entry>>,
    settings: Arc<SettingsStore>,
}

impl RqbitBackend {
    pub async fn new(cache_root: PathBuf, settings: Arc<SettingsStore>) -> anyhow::Result<Arc<Self>> {
        std::fs::create_dir_all(&cache_root).context("create cache root")?;
        let session = Session::new_with_opts(
            cache_root.clone(),
            SessionOptions {
                disable_dht: false,
                disable_dht_persistence: true, // our own home dir carries no DHT state file
                enable_upnp_port_forwarding: false,
                ..Default::default()
            },
        )
        .await
        .context("rqbit session")?;
        let backend = Arc::new(Self {
            session,
            cache_root,
            entries: Mutex::new(HashMap::new()),
            settings,
        });
        backend.clone().spawn_cache_janitor();
        Ok(backend)
    }

    /// `tracker:` sources -> tracker URLs, merged with the injected defaults,
    /// de-duped preserving order. `dht:` entries are dropped (DHT is built in).
    fn tracker_list(sources: &[String]) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        sources
            .iter()
            .filter_map(|s| s.strip_prefix("tracker:"))
            .chain(DEFAULT_TRACKERS.iter().copied())
            .filter(|t| seen.insert(t.to_string()))
            .map(str::to_string)
            .collect()
    }

    /// Idempotent engine-open: concurrent callers share one add via OnceCell.
    async fn ensure(&self, hash: &str, sources: &[String]) -> Result<ManagedTorrentHandle, BackendError> {
        if !valid_info_hash(hash) {
            return Err(BackendError::UnknownTorrent);
        }
        let cell = {
            let mut map = self.entries.lock().await;
            map.entry(hash.to_string())
                .or_insert_with(|| Entry {
                    cell: Arc::new(OnceCell::new()),
                    sources: sources.to_vec(),
                })
                .cell
                .clone()
        };
        let handle = cell
            .get_or_try_init(|| async {
                let magnet = format!("magnet:?xt=urn:btih:{hash}");
                let opts = AddTorrentOptions {
                    overwrite: true,
                    output_folder: Some(self.cache_root.join(hash).to_string_lossy().into_owned()),
                    trackers: Some(Self::tracker_list(sources)),
                    ..Default::default()
                };
                let resp = self
                    .session
                    .add_torrent(AddTorrent::from_url(&magnet), Some(opts))
                    .await
                    .context("add_torrent")?;
                let handle = resp.into_handle().context("torrent handle")?;
                handle.wait_until_initialized().await.context("initialize")?;
                Ok::<_, anyhow::Error>(handle)
            })
            .await
            .map_err(BackendError::Engine)?;
        Ok(handle.clone())
    }

    fn build_stats(&self, hash: &str, handle: &ManagedTorrentHandle, sources: &[String]) -> EngineStats {
        let st = handle.stats();
        let (live_peers, connecting, queued, seen, dead) = st
            .live
            .as_ref()
            .map(|l| {
                let p = &l.snapshot.peer_stats;
                (p.live as u64, p.connecting as u64, p.queued as u64, p.seen as u64, p.dead as u64)
            })
            .unwrap_or_default();
        // rqbit Speed.mbps is MiB/s; the contract's downloadSpeed is bytes/sec.
        let (down_bps, up_bps) = st
            .live
            .as_ref()
            .map(|l| {
                (
                    l.download_speed.mbps * 1_048_576.0,
                    l.upload_speed.mbps * 1_048_576.0,
                )
            })
            .unwrap_or_default();
        let files = handle
            .metadata
            .load()
            .as_ref()
            .map(|m| {
                m.file_infos
                    .iter()
                    .map(|f| {
                        let rel = f.relative_filename.to_string_lossy().replace('\\', "/");
                        let name = rel.rsplit('/').next().unwrap_or(&rel).to_string();
                        FileEntry {
                            path: rel.clone(),
                            name,
                            length: f.len,
                            offset: f.offset_in_torrent,
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();
        let name = handle.name().unwrap_or_else(|| hash.to_string());
        EngineStats {
            info_hash: hash.to_string(),
            name,
            peers: live_peers,
            unchoked: live_peers, // rqbit has no aggregate choke counter; best-effort
            queued,
            unique: seen,
            connection_tries: connecting + dead + live_peers,
            swarm_paused: false,
            swarm_connections: live_peers + connecting,
            swarm_size: seen,
            selections: vec![],
            wires: vec![], // per-peer wire dump: no app call site reads it
            files,
            downloaded: st.progress_bytes,
            uploaded: st.uploaded_bytes,
            download_speed: down_bps,
            upload_speed: up_bps,
            sources: source_entries(sources),
            peer_search_running: st.live.is_some() && !st.finished,
            opts: serde_json::json!({
                "peerSearch": { "sources": sources, "min": 40, "max": 150 },
                "torrent": { "infoHash": hash },
                "path": self.cache_root.join(hash).to_string_lossy(),
            }),
        }
    }

    /// Self-bound the on-disk piece cache: every 2 minutes, if the cache root
    /// exceeds the settings cacheSize (the app posts a device-scaled cap),
    /// evict per-torrent dirs that have NO running engine, oldest first.
    /// Active engines are never evicted mid-stream.
    fn spawn_cache_janitor(self: Arc<Self>) {
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(120)).await;
                let Some(cap) = self.settings.cache_size() else { continue };
                let active: std::collections::HashSet<String> = {
                    let map = self.entries.lock().await;
                    map.keys().cloned().collect()
                };
                let root = self.cache_root.clone();
                let result = tokio::task::spawn_blocking(move || evict_over_cap(&root, cap, &active)).await;
                match result {
                    Ok(Ok(freed)) if freed > 0 => {
                        tracing::info!("cache janitor freed {freed} bytes");
                    }
                    Ok(Err(e)) => tracing::warn!("cache janitor: {e:#}"),
                    _ => {}
                }
            }
        });
    }
}

fn dir_size(path: &std::path::Path) -> u64 {
    let mut total = 0;
    if let Ok(rd) = std::fs::read_dir(path) {
        for entry in rd.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_dir() {
                    total += dir_size(&entry.path());
                } else {
                    total += meta.len();
                }
            }
        }
    }
    total
}

fn evict_over_cap(
    root: &std::path::Path,
    cap: u64,
    active: &std::collections::HashSet<String>,
) -> anyhow::Result<u64> {
    let mut dirs: Vec<(PathBuf, u64, std::time::SystemTime)> = Vec::new();
    let mut total = 0u64;
    for entry in std::fs::read_dir(root)?.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let size = dir_size(&path);
        total += size;
        let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if !active.contains(&name) {
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            dirs.push((path, size, mtime));
        }
    }
    if total <= cap {
        return Ok(0);
    }
    dirs.sort_by_key(|(_, _, mtime)| *mtime);
    let mut freed = 0u64;
    for (path, size, _) in dirs {
        if total.saturating_sub(freed) <= cap {
            break;
        }
        if std::fs::remove_dir_all(&path).is_ok() {
            freed += size;
        }
    }
    Ok(freed)
}

#[async_trait::async_trait]
impl TorrentBackend for RqbitBackend {
    async fn create(&self, info_hash: &str, sources: &[String]) -> Result<EngineStats, BackendError> {
        let handle = self.ensure(info_hash, sources).await?;
        let sources = {
            let map = self.entries.lock().await;
            map.get(info_hash).map(|e| e.sources.clone()).unwrap_or_default()
        };
        Ok(self.build_stats(info_hash, &handle, &sources))
    }

    async fn stats(&self, info_hash: &str) -> Option<EngineStats> {
        let (cell, sources) = {
            let map = self.entries.lock().await;
            let e = map.get(info_hash)?;
            (e.cell.clone(), e.sources.clone())
        };
        let handle = cell.get()?.clone();
        Some(self.build_stats(info_hash, &handle, &sources))
    }

    async fn remove(&self, info_hash: &str) -> bool {
        let existed = self.entries.lock().await.remove(info_hash).is_some();
        if existed {
            if let Ok(id) = librqbit::api::TorrentIdOrHash::parse(info_hash) {
                // Engine down, disk cache kept (server.js parity: a follow-up
                // file GET auto-creates and reuses cached pieces).
                if let Err(e) = self.session.delete(id, false).await {
                    tracing::warn!("delete {info_hash}: {e:#}");
                }
            }
        }
        existed
    }

    async fn open_file(
        &self,
        info_hash: &str,
        file_idx: usize,
        extra_sources: &[String],
    ) -> Result<OpenFile, BackendError> {
        let handle = tokio::time::timeout(
            AUTO_CREATE_TIMEOUT,
            self.ensure(info_hash, extra_sources),
        )
        .await
        .map_err(|_| BackendError::MetadataTimeout)??;
        let (file_name, len) = handle
            .metadata
            .load()
            .as_ref()
            .and_then(|m| {
                m.file_infos.get(file_idx).map(|f| {
                    let rel = f.relative_filename.to_string_lossy().replace('\\', "/");
                    let name = rel.rsplit('/').next().unwrap_or(&rel).to_string();
                    (name, f.len)
                })
            })
            .ok_or(BackendError::BadFileIndex)?;
        let stream = handle
            .clone()
            .stream(file_idx)
            .context("open stream")
            .map_err(BackendError::Engine)?;
        Ok(OpenFile { file_name, len, reader: Box::new(stream) })
    }
}
