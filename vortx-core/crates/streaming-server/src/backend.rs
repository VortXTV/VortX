//! The torrent-engine seam. The HTTP layer talks ONLY to this trait, so the
//! conformance tests run against the hermetic stub while the bin runs rqbit.

use crate::contract::EngineStats;
use tokio::io::{AsyncRead, AsyncSeek};

/// A reader over one file inside a torrent. Reads BLOCK until the underlying
/// pieces are downloaded (the file-endpoint "blocks until first bytes ready"
/// contract); seeking re-prioritizes the swarm around the new position.
pub trait AsyncReadSeek: AsyncRead + AsyncSeek + Send + Unpin {}
impl<T: AsyncRead + AsyncSeek + Send + Unpin> AsyncReadSeek for T {}

/// An opened torrent file ready for range streaming.
pub struct OpenFile {
    pub file_name: String,
    pub len: u64,
    pub reader: Box<dyn AsyncReadSeek>,
}

#[derive(Debug, thiserror::Error)]
pub enum BackendError {
    #[error("unknown torrent")]
    UnknownTorrent,
    #[error("file index out of range")]
    BadFileIndex,
    #[error("torrent metadata was not resolved in time")]
    MetadataTimeout,
    #[error(transparent)]
    Engine(#[from] anyhow::Error),
}

#[async_trait::async_trait]
pub trait TorrentBackend: Send + Sync + 'static {
    /// Idempotent create: opens the engine for `info_hash` (40-hex lowercase)
    /// with the given peerSearch `sources` (entries `dht:<hash>` /
    /// `tracker:<url>`), BLOCKS until torrent metadata is known, and returns
    /// the engine status. A second create on a live engine returns its current
    /// status and ignores the new sources (the first create's sources stick).
    async fn create(&self, info_hash: &str, sources: &[String]) -> Result<EngineStats, BackendError>;

    /// Engine status, or None when the hash has no engine (the HTTP layer
    /// serializes None as the captured `null` body).
    async fn stats(&self, info_hash: &str) -> Option<EngineStats>;

    /// Destroy the engine (peers/sockets); the disk cache may remain. Returns
    /// whether an engine existed.
    async fn remove(&self, info_hash: &str) -> bool;

    /// Open a file for streaming, auto-creating the engine when it is not
    /// running (the Continue-Watching resume path hits the file endpoint with
    /// no prior create; `extra_sources` carries any `?tr=` query trackers).
    async fn open_file(
        &self,
        info_hash: &str,
        file_idx: usize,
        extra_sources: &[String],
    ) -> Result<OpenFile, BackendError>;
}

/// True for a well-formed 40-hex info hash (the app lowercases before calling).
pub fn valid_info_hash(hash: &str) -> bool {
    hash.len() == 40 && hash.bytes().all(|b| b.is_ascii_hexdigit())
}
