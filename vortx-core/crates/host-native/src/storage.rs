//! The persistence seam the kernel has been missing (GT3): the kernel emits changed state through
//! `get_state_delta_json` and, until now, NOTHING host-side persisted it. [`Storage`] is that seam,
//! shaped like stremio-core's persisted buckets: named string keys holding opaque JSON documents,
//! `get`/`set` by key, `set(None)` deleting the bucket. The kernel never sees this trait; hosts
//! read deltas off the FFI boundary and write them into a `Storage`, and hydrate state back out of
//! it at startup.
//!
//! [`FileStorage`] is the native file-backed implementation: one file per bucket under a root
//! directory, written atomically (temp file + rename) so a crash mid-write can never tear a bucket.
//! Values round-trip BYTE-EQUAL: what a host writes is exactly what it reads back, which is the
//! property the byte-stable cutover proof (Phase 3) builds on.
//!
//! Keys pass through VERBATIM. In particular the three FROZEN datastore ids that mirror live
//! server-side user data (`stremioxProfiles`, `stremiox:profiles`, `stremiox:watch:<uuid>`) are
//! stored under exactly those names: this layer performs no key rewriting, migration, or
//! normalization, ever. Only the on-disk FILENAME is a percent-encoded form of the key (filesystems
//! cannot host arbitrary bytes), and that encoding is bijective, so the key set decodes back
//! exactly.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

/// Filename-safe alphabet for encoded keys: ASCII alphanumerics plus `_` and `-`; EVERYTHING else
/// (including `.`) is percent-encoded. Encoding `.` keeps `.` / `..` / hidden-file names and any
/// extension-like suffix impossible, so an encoded key can never traverse or collide with the
/// writer's `.tmp` staging files.
const FILE_UNSAFE: &AsciiSet = &NON_ALPHANUMERIC.remove(b'_').remove(b'-');

/// The suffix of in-flight atomic-write staging files. Encoded keys cannot contain `.`, so a
/// staging file can never be mistaken for (or collide with) a bucket.
const TMP_SUFFIX: &str = ".tmp";

/// Failures reading or writing persisted buckets.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("storage io on {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("stored bytes for key {key:?} are not valid UTF-8")]
    NotUtf8 { key: String },
}

/// The host persistence boundary, shaped like stremio-core's persisted buckets: opaque JSON string
/// documents under named keys. `set(key, Some(json))` upserts a bucket, `set(key, None)` deletes
/// it, `get` returns the exact stored bytes. Implementations MUST round-trip values byte-equal and
/// keys verbatim.
pub trait Storage {
    /// The exact stored document for `key`, or `None` when the bucket does not exist.
    fn get(&self, key: &str) -> Result<Option<String>, StorageError>;
    /// Upsert (`Some`) or delete (`None`) the bucket for `key`. Deleting a missing bucket is a no-op.
    fn set(&self, key: &str, value: Option<&str>) -> Result<(), StorageError>;
    /// Every existing bucket key, sorted, decoded verbatim.
    fn keys(&self) -> Result<Vec<String>, StorageError>;
}

/// File-backed [`Storage`]: one file per bucket under `root`, atomic writes, bijective
/// percent-encoded filenames. Single-writer by design (the host process owns its state directory),
/// matching the kernel's one-engine-per-process model.
#[derive(Debug, Clone)]
pub struct FileStorage {
    root: PathBuf,
}

impl FileStorage {
    /// Open (creating if needed) the bucket directory at `root`.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, StorageError> {
        let root = root.into();
        fs::create_dir_all(&root).map_err(|source| StorageError::Io {
            path: root.clone(),
            source,
        })?;
        Ok(Self { root })
    }

    /// The directory buckets live in.
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn bucket_path(&self, key: &str) -> PathBuf {
        self.root.join(encode_key(key))
    }
}

impl Storage for FileStorage {
    fn get(&self, key: &str) -> Result<Option<String>, StorageError> {
        let path = self.bucket_path(key);
        match fs::read(&path) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| StorageError::NotUtf8 {
                    key: key.to_string(),
                }),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(source) => Err(StorageError::Io { path, source }),
        }
    }

    fn set(&self, key: &str, value: Option<&str>) -> Result<(), StorageError> {
        let path = self.bucket_path(key);
        match value {
            Some(document) => write_atomic(&path, document.as_bytes()),
            None => match fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(source) => Err(StorageError::Io { path, source }),
            },
        }
    }

    fn keys(&self) -> Result<Vec<String>, StorageError> {
        let entries = fs::read_dir(&self.root).map_err(|source| StorageError::Io {
            path: self.root.clone(),
            source,
        })?;
        let mut keys = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|source| StorageError::Io {
                path: self.root.clone(),
                source,
            })?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue; // not one of ours: encoded names are pure ASCII
            };
            if name.ends_with(TMP_SUFFIX) {
                continue; // an in-flight staging file, never a bucket
            }
            if let Some(key) = decode_key(name) {
                keys.push(key);
            }
        }
        keys.sort();
        Ok(keys)
    }
}

/// Encode a bucket key into its on-disk filename (bijective; ASCII output only).
fn encode_key(key: &str) -> String {
    utf8_percent_encode(key, FILE_UNSAFE).to_string()
}

/// Decode an on-disk filename back into its bucket key. `None` for a filename this store did not
/// write (invalid percent sequences or non-UTF-8 decode).
fn decode_key(name: &str) -> Option<String> {
    percent_decode_str(name)
        .decode_utf8()
        .ok()
        .map(|cow| cow.into_owned())
}

/// Write `bytes` to `path` atomically: stage to a sibling temp file, flush, then rename over the
/// destination. A crash mid-write leaves either the old bucket or the new one, never a torn file.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), StorageError> {
    let io_err = |source| StorageError::Io {
        path: path.to_path_buf(),
        source,
    };
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(TMP_SUFFIX);
    let tmp = PathBuf::from(tmp);
    {
        let mut file = fs::File::create(&tmp).map_err(io_err)?;
        file.write_all(bytes).map_err(io_err)?;
        file.sync_all().map_err(io_err)?;
    }
    fs::rename(&tmp, path).map_err(io_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch_dir(tag: &str) -> PathBuf {
        let unique = format!(
            "vortx-host-native-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        );
        std::env::temp_dir().join(unique)
    }

    #[test]
    fn buckets_round_trip_byte_equal() {
        let root = scratch_dir("roundtrip");
        let store = FileStorage::open(&root).unwrap();
        let document = r#"{"profiles":{"kid":{"name":"Kid"}},"activeProfileId":"kid"}"#;
        store.set("vortx:state", Some(document)).unwrap();
        assert_eq!(store.get("vortx:state").unwrap().as_deref(), Some(document));
        // A fresh handle over the same root reads the same bytes: real persistence, not a cache.
        let reopened = FileStorage::open(&root).unwrap();
        assert_eq!(
            reopened.get("vortx:state").unwrap().as_deref(),
            Some(document)
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn frozen_datastore_ids_pass_through_verbatim() {
        // The three ids mirroring live server-side user data. This layer must store them under
        // EXACTLY these names: no rewriting, no migration, no normalization.
        let frozen = [
            "stremioxProfiles",
            "stremiox:profiles",
            "stremiox:watch:0f9d51c2-8f7e-4f21-9e6a-3f52b9a41c77",
        ];
        let root = scratch_dir("frozen");
        let store = FileStorage::open(&root).unwrap();
        for (i, key) in frozen.iter().enumerate() {
            store.set(key, Some(&format!("{{\"v\":{i}}}"))).unwrap();
        }
        // Every key decodes back verbatim, and each maps to its own bucket.
        assert_eq!(store.keys().unwrap(), {
            let mut sorted: Vec<String> = frozen.iter().map(|s| s.to_string()).collect();
            sorted.sort();
            sorted
        });
        for (i, key) in frozen.iter().enumerate() {
            assert_eq!(
                store.get(key).unwrap().as_deref(),
                Some(format!("{{\"v\":{i}}}").as_str())
            );
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn delete_removes_the_bucket_and_missing_delete_is_a_noop() {
        let root = scratch_dir("delete");
        let store = FileStorage::open(&root).unwrap();
        store.set("bucket", Some("{}")).unwrap();
        store.set("bucket", None).unwrap();
        assert_eq!(store.get("bucket").unwrap(), None);
        store.set("bucket", None).unwrap(); // idempotent
        assert!(store.keys().unwrap().is_empty());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn hostile_keys_cannot_escape_the_root() {
        let root = scratch_dir("hostile");
        let store = FileStorage::open(&root).unwrap();
        for key in ["../escape", "..", ".", "a/b", "a\\b", ".hidden", "x.tmp"] {
            store.set(key, Some("{}")).unwrap();
            let encoded = encode_key(key);
            assert!(
                !encoded.contains('/') && !encoded.contains('.') && !encoded.contains('\\'),
                "key {key:?} encoded to unsafe filename {encoded:?}"
            );
            assert_eq!(store.get(key).unwrap().as_deref(), Some("{}"));
        }
        // Everything landed INSIDE root, one flat file per key.
        assert_eq!(store.keys().unwrap().len(), 7);
        assert_eq!(fs::read_dir(&root).unwrap().count(), 7);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn unicode_keys_round_trip() {
        let root = scratch_dir("unicode");
        let store = FileStorage::open(&root).unwrap();
        let key = "profil:ünïcode:試験";
        store.set(key, Some(r#"{"ok":true}"#)).unwrap();
        assert_eq!(store.keys().unwrap(), vec![key.to_string()]);
        assert_eq!(store.get(key).unwrap().as_deref(), Some(r#"{"ok":true}"#));
        fs::remove_dir_all(&root).unwrap();
    }
}
