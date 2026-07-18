//! The /settings state: the captured server.js `values` object (names
//! byte-exact per contract/GOLDEN.md), a merge-on-POST (server.js
//! `userSettings.extend`), and JSON persistence in the server home dir.

use std::path::{Path, PathBuf};
use std::sync::RwLock;

use serde_json::{json, Map, Value};

pub struct SettingsStore {
    path: Option<PathBuf>,
    values: RwLock<Map<String, Value>>,
}

impl SettingsStore {
    /// Captured v4.21.0 defaults. appPath/cacheRoot point at OUR home; the
    /// transcode block is inert (this server does not transcode) but the keys
    /// stay for shape parity.
    pub fn default_values(app_path: &str) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("serverVersion".into(), json!(concat!(env!("CARGO_PKG_VERSION"), "-vortx-rs")));
        m.insert("appPath".into(), json!(app_path));
        m.insert("cacheRoot".into(), json!(app_path));
        m.insert("cacheSize".into(), json!(2_147_483_648u64));
        m.insert("btMaxConnections".into(), json!(55));
        m.insert("btHandshakeTimeout".into(), json!(20_000));
        m.insert("btRequestTimeout".into(), json!(4_000));
        m.insert("btDownloadSpeedSoftLimit".into(), json!(2_621_440));
        m.insert("btDownloadSpeedHardLimit".into(), json!(3_670_016));
        m.insert("btMinPeersForStable".into(), json!(5));
        m.insert("remoteHttps".into(), json!(""));
        m.insert("localAddonEnabled".into(), json!(false));
        m.insert("transcodeHorsepower".into(), json!(0.75));
        m.insert("transcodeMaxBitRate".into(), json!(0));
        m.insert("transcodeConcurrency".into(), json!(1));
        m.insert("transcodeTrackConcurrency".into(), json!(1));
        m.insert("transcodeHardwareAccel".into(), json!(false));
        m.insert("transcodeProfile".into(), Value::Null);
        m.insert("allTranscodeProfiles".into(), json!([] as [&str; 0]));
        m.insert("transcodeMaxWidth".into(), json!(1920));
        m.insert("proxyStreamsEnabled".into(), json!(false));
        m
    }

    /// In-memory only (tests).
    pub fn in_memory(app_path: &str) -> Self {
        Self { path: None, values: RwLock::new(Self::default_values(app_path)) }
    }

    /// Persistent: defaults overlaid with whatever `settings.json` carries.
    pub fn load(home: &Path) -> Self {
        let path = home.join("settings.json");
        let mut values = Self::default_values(&home.to_string_lossy());
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(Value::Object(saved)) = serde_json::from_str::<Value>(&text) {
                for (k, v) in saved {
                    values.insert(k, v);
                }
            }
        }
        Self { path: Some(path), values: RwLock::new(values) }
    }

    /// The GET /settings `values` object.
    pub fn values(&self) -> Map<String, Value> {
        self.values.read().unwrap().clone()
    }

    /// POST /settings: merge every posted key over the current values
    /// (server.js `userSettings.extend`) and persist best-effort.
    pub fn merge(&self, posted: Map<String, Value>) {
        let snapshot = {
            let mut values = self.values.write().unwrap();
            for (k, v) in posted {
                values.insert(k, v);
            }
            values.clone()
        };
        if let Some(path) = &self.path {
            if let Ok(text) = serde_json::to_string_pretty(&Value::Object(snapshot)) {
                if let Err(e) = std::fs::write(path, text) {
                    tracing::warn!("settings persist failed: {e}");
                }
            }
        }
    }

    /// The on-disk cache bound: Some(bytes) when capped, None when the value
    /// is null/absent (unlimited, the captured "∞" selection). 0 = no caching.
    pub fn cache_size(&self) -> Option<u64> {
        match self.values.read().unwrap().get("cacheSize") {
            Some(Value::Number(n)) => n.as_u64().or_else(|| n.as_f64().map(|f| f.max(0.0) as u64)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_overlays_and_cache_size_reads_back() {
        let s = SettingsStore::in_memory("/tmp/x");
        assert_eq!(s.cache_size(), Some(2_147_483_648));
        let posted: Map<String, Value> =
            serde_json::from_str(r#"{"cacheSize":536870912,"btMaxConnections":24}"#).unwrap();
        s.merge(posted);
        assert_eq!(s.cache_size(), Some(536_870_912));
        let v = s.values();
        assert_eq!(v["btMaxConnections"], json!(24));
        // every captured key survives the merge
        for key in SettingsStore::default_values("/tmp/x").keys() {
            assert!(v.contains_key(key), "lost key {key}");
        }
    }

    #[test]
    fn null_cache_size_means_unlimited() {
        let s = SettingsStore::in_memory("/tmp/x");
        let posted: Map<String, Value> = serde_json::from_str(r#"{"cacheSize":null}"#).unwrap();
        s.merge(posted);
        assert_eq!(s.cache_size(), None);
    }
}
