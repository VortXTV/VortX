//! The normalized debrid store: one trait every service implements, plus the normalized status/file/user
//! types. Modelled on StremThru's 7-method contract so nothing downstream knows which store resolved.

use serde::{Deserialize, Serialize};
use vortx_hive::DebridService;

use crate::DebridError;

/// A debrid account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DebridUser {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    pub premium: bool,
    /// Unix seconds the subscription expires, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expiration: Option<u64>,
}

/// Normalized magnet status across all stores. `cached` is the instant-play signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MagnetStatus {
    Cached,
    Queued,
    Downloading,
    Processing,
    Downloaded,
    Uploading,
    Failed,
    Invalid,
    Unknown,
}

impl MagnetStatus {
    /// Ready to play right now (cached, or already downloaded to the account).
    pub fn is_ready(self) -> bool {
        matches!(self, MagnetStatus::Cached | MagnetStatus::Downloaded)
    }

    /// Still working (will become ready if we wait).
    pub fn is_pending(self) -> bool {
        matches!(
            self,
            MagnetStatus::Queued
                | MagnetStatus::Downloading
                | MagnetStatus::Processing
                | MagnetStatus::Uploading
        )
    }
}

/// One file inside an added magnet.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MagnetFile {
    pub idx: u32,
    pub path: String,
    pub size: u64,
    /// A restricted link to unrestrict via [`DebridStore::generate_link`], if available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

/// A magnet's state on the account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MagnetInfo {
    pub id: String,
    pub infohash: String,
    pub status: MagnetStatus,
    #[serde(default)]
    pub files: Vec<MagnetFile>,
}

/// The result of adding a magnet.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddedMagnet {
    pub id: String,
    pub infohash: String,
}

/// One debrid service behind a normalized interface. Implementations are added later (HTTP clients); this
/// crate defines the shape and a planner that uses it.
pub trait DebridStore {
    fn name(&self) -> DebridService;
    fn get_user(&self) -> Result<DebridUser, DebridError>;
    /// Batch cache-check (callers should chunk via [`check_magnets_batched`]). Returns `(hash, status)`.
    fn check_magnets(&self, hashes: &[String]) -> Result<Vec<(String, MagnetStatus)>, DebridError>;
    fn add_magnet(&self, magnet: &str) -> Result<AddedMagnet, DebridError>;
    fn get_magnet(&self, id: &str) -> Result<MagnetInfo, DebridError>;
    fn remove_magnet(&self, id: &str) -> Result<(), DebridError>;
    /// Unrestrict a restricted link into a direct, playable URL.
    fn generate_link(&self, restricted: &str) -> Result<String, DebridError>;
}

/// Max hashes per cache-check request (the RD/AD batch limit).
pub const CHECK_BATCH_SIZE: usize = 500;

/// Check many hashes by chunking into [`CHECK_BATCH_SIZE`] batches, preserving input order.
pub fn check_magnets_batched(
    store: &dyn DebridStore,
    hashes: &[String],
) -> Result<Vec<(String, MagnetStatus)>, DebridError> {
    let mut out = Vec::with_capacity(hashes.len());
    for chunk in hashes.chunks(CHECK_BATCH_SIZE) {
        out.extend(store.check_magnets(chunk)?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    struct MockStore {
        cached: HashSet<String>,
    }

    impl DebridStore for MockStore {
        fn name(&self) -> DebridService {
            DebridService::RealDebrid
        }
        fn get_user(&self) -> Result<DebridUser, DebridError> {
            Ok(DebridUser {
                id: "u1".into(),
                email: None,
                premium: true,
                expiration: None,
            })
        }
        fn check_magnets(
            &self,
            hashes: &[String],
        ) -> Result<Vec<(String, MagnetStatus)>, DebridError> {
            Ok(hashes
                .iter()
                .map(|h| {
                    let status = if self.cached.contains(h) {
                        MagnetStatus::Cached
                    } else {
                        MagnetStatus::Unknown
                    };
                    (h.clone(), status)
                })
                .collect())
        }
        fn add_magnet(&self, _magnet: &str) -> Result<AddedMagnet, DebridError> {
            Ok(AddedMagnet {
                id: "m1".into(),
                infohash: "abc".into(),
            })
        }
        fn get_magnet(&self, _id: &str) -> Result<MagnetInfo, DebridError> {
            Ok(MagnetInfo {
                id: "m1".into(),
                infohash: "abc".into(),
                status: MagnetStatus::Downloaded,
                files: vec![],
            })
        }
        fn remove_magnet(&self, _id: &str) -> Result<(), DebridError> {
            Ok(())
        }
        fn generate_link(&self, restricted: &str) -> Result<String, DebridError> {
            Ok(format!("https://dl.example/{restricted}"))
        }
    }

    #[test]
    fn batched_check_covers_every_hash_across_chunks() {
        let store = MockStore {
            cached: ["h7".to_string()].into_iter().collect(),
        };
        let hashes: Vec<String> = (0..1200).map(|i| format!("h{i}")).collect();
        let res = check_magnets_batched(&store, &hashes).unwrap();
        assert_eq!(res.len(), 1200); // 500 + 500 + 200, all returned in order
        assert_eq!(res[7], ("h7".to_string(), MagnetStatus::Cached));
    }

    #[test]
    fn status_readiness_classification() {
        assert!(MagnetStatus::Cached.is_ready());
        assert!(MagnetStatus::Downloaded.is_ready());
        assert!(!MagnetStatus::Queued.is_ready());
        assert!(MagnetStatus::Downloading.is_pending());
        assert!(!MagnetStatus::Cached.is_pending());
    }

    #[test]
    fn store_basic_ops() {
        let store = MockStore {
            cached: ["a".to_string()].into_iter().collect(),
        };
        assert!(store.get_user().unwrap().premium);
        let checked = store
            .check_magnets(&["a".to_string(), "b".to_string()])
            .unwrap();
        assert_eq!(checked[0].1, MagnetStatus::Cached);
        assert_eq!(checked[1].1, MagnetStatus::Unknown);
        assert!(store.generate_link("xyz").unwrap().starts_with("https://"));
        assert_eq!(store.name(), DebridService::RealDebrid);
    }
}
