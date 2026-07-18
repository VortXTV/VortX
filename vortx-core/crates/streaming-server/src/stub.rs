//! A hermetic, in-memory torrent backend for the conformance tests: known
//! bytes, a controllable "pieces ready" gate (so blocks-until-ready is
//! testable), no network. Lives in the lib (not cfg(test)) because the
//! integration tests in tests/ link the crate as a dependency.

use std::collections::HashMap;
use std::io::SeekFrom;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use futures::future::BoxFuture;
use futures::FutureExt;
use tokio::io::{AsyncRead, AsyncSeek, ReadBuf};
use tokio::sync::watch;

use crate::backend::{BackendError, OpenFile, TorrentBackend};
use crate::contract::{source_entries, EngineStats, FileEntry};

pub struct StubFile {
    pub name: String,
    pub bytes: Arc<Vec<u8>>,
}

struct StubEntry {
    name: String,
    files: Vec<StubFile>,
    ready_rx: watch::Receiver<bool>,
    /// Engine running (created)? `remove` flips this off; stats then serve `null`.
    engine_on: bool,
    sources: Vec<String>,
}

#[derive(Default)]
pub struct StubBackend {
    torrents: Mutex<HashMap<String, StubEntry>>,
}

impl StubBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a torrent the stub can serve. `ready` gates file READS (not
    /// metadata): a false start means byte delivery blocks until the returned
    /// sender flips it true, mirroring pieces arriving from the swarm.
    pub fn insert_torrent(
        &self,
        info_hash: &str,
        name: &str,
        files: Vec<(String, Vec<u8>)>,
        ready: bool,
    ) -> watch::Sender<bool> {
        let (tx, rx) = watch::channel(ready);
        self.torrents.lock().unwrap().insert(
            info_hash.to_ascii_lowercase(),
            StubEntry {
                name: name.to_string(),
                files: files
                    .into_iter()
                    .map(|(n, b)| StubFile { name: n, bytes: Arc::new(b) })
                    .collect(),
                ready_rx: rx,
                engine_on: false,
                sources: Vec::new(),
            },
        );
        tx
    }

    fn stats_of(entry: &StubEntry, hash: &str) -> EngineStats {
        let ready = *entry.ready_rx.borrow();
        let total: u64 = entry.files.iter().map(|f| f.bytes.len() as u64).sum();
        let mut offset = 0u64;
        let files = entry
            .files
            .iter()
            .map(|f| {
                let e = FileEntry {
                    path: format!("{}/{}", entry.name, f.name),
                    name: f.name.clone(),
                    length: f.bytes.len() as u64,
                    offset,
                };
                offset += f.bytes.len() as u64;
                e
            })
            .collect();
        EngineStats {
            info_hash: hash.to_string(),
            name: entry.name.clone(),
            peers: 3,
            unchoked: 1,
            queued: 0,
            unique: 5,
            connection_tries: 10,
            swarm_paused: false,
            swarm_connections: 4,
            swarm_size: 5,
            selections: vec![],
            wires: vec![],
            files,
            downloaded: if ready { total } else { 0 },
            uploaded: 0,
            download_speed: 0.0,
            upload_speed: 0.0,
            sources: source_entries(&entry.sources),
            peer_search_running: true,
            opts: serde_json::json!({
                "peerSearch": { "sources": entry.sources, "min": 40, "max": 150 },
                "torrent": { "infoHash": hash },
            }),
        }
    }
}

#[async_trait::async_trait]
impl TorrentBackend for StubBackend {
    async fn create(&self, info_hash: &str, sources: &[String]) -> Result<EngineStats, BackendError> {
        let mut map = self.torrents.lock().unwrap();
        let entry = map.get_mut(info_hash).ok_or(BackendError::UnknownTorrent)?;
        // Idempotent: the FIRST create's sources stick (server.js parity).
        if !entry.engine_on {
            entry.engine_on = true;
            entry.sources = sources.to_vec();
        }
        Ok(Self::stats_of(entry, info_hash))
    }

    async fn stats(&self, info_hash: &str) -> Option<EngineStats> {
        let map = self.torrents.lock().unwrap();
        let entry = map.get(info_hash)?;
        if !entry.engine_on {
            return None;
        }
        Some(Self::stats_of(entry, info_hash))
    }

    async fn remove(&self, info_hash: &str) -> bool {
        let mut map = self.torrents.lock().unwrap();
        match map.get_mut(info_hash) {
            Some(e) if e.engine_on => {
                e.engine_on = false;
                true
            }
            _ => false,
        }
    }

    async fn open_file(
        &self,
        info_hash: &str,
        file_idx: usize,
        extra_sources: &[String],
    ) -> Result<OpenFile, BackendError> {
        let (bytes, name, rx) = {
            let mut map = self.torrents.lock().unwrap();
            let entry = map.get_mut(info_hash).ok_or(BackendError::UnknownTorrent)?;
            // Auto-create on a bare file GET (the CW-resume path).
            if !entry.engine_on {
                entry.engine_on = true;
                entry.sources = extra_sources.to_vec();
            }
            let f = entry.files.get(file_idx).ok_or(BackendError::BadFileIndex)?;
            (f.bytes.clone(), f.name.clone(), entry.ready_rx.clone())
        };
        let len = bytes.len() as u64;
        Ok(OpenFile {
            file_name: name,
            len,
            reader: Box::new(GatedReader::new(bytes, rx)),
        })
    }
}

/// A Cursor whose reads wait for the ready gate first: the hermetic stand-in
/// for "the swarm hasn't delivered these pieces yet".
struct GatedReader {
    gate: Option<BoxFuture<'static, ()>>,
    inner: std::io::Cursor<GateBytes>,
}

/// Arc<Vec<u8>> wrapper so Cursor can read it without copying.
struct GateBytes(Arc<Vec<u8>>);
impl AsRef<[u8]> for GateBytes {
    fn as_ref(&self) -> &[u8] {
        self.0.as_slice()
    }
}

impl GatedReader {
    fn new(bytes: Arc<Vec<u8>>, mut rx: watch::Receiver<bool>) -> Self {
        let gate = async move {
            while !*rx.borrow() {
                if rx.changed().await.is_err() {
                    break; // sender dropped: open the gate rather than hang forever
                }
            }
        }
        .boxed();
        Self { gate: Some(gate), inner: std::io::Cursor::new(GateBytes(bytes)) }
    }
}

impl AsyncRead for GatedReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if let Some(gate) = self.gate.as_mut() {
            match gate.as_mut().poll(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(()) => self.gate = None,
            }
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncSeek for GatedReader {
    fn start_seek(mut self: Pin<&mut Self>, position: SeekFrom) -> std::io::Result<()> {
        Pin::new(&mut self.inner).start_seek(position)
    }
    fn poll_complete(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<u64>> {
        Pin::new(&mut self.inner).poll_complete(cx)
    }
}
