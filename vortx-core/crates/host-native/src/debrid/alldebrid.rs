//! AllDebrid behind the normalized store contract (`api.alldebrid.com`, bearer auth plus the
//! conventional `agent` identifier). Envelope discipline: AllDebrid answers HTTP 200 for almost
//! everything and signals failure inside `{"status":"error","error":{code,message}}` (verified
//! live 2026-07-18), so every response goes through the envelope before any status fallback.
//!
//! Cache-check reality, verified live 2026-07-18: `/v4/magnet/instant` is GONE (the API answers
//! `404 Endpoint doesn't exist`). Like RealDebrid, the strongest signal left is the account's own
//! magnet list (`/v4.1/magnet/status`): a hash already Ready on the account is instantly
//! playable, everything else is honestly `Unknown` and network-wide knowledge comes from the hive
//! vault. The v4.1 status endpoint is used because v4 answers `"deprecated": true` (also
//! recorded live); upload / files / unlock / delete remain v4.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde::Deserialize;
use vortx_debrid::{
    AddedMagnet, DebridError, DebridService, DebridStore, DebridUser, MagnetFile, MagnetInfo,
    MagnetStatus,
};

use super::{
    error_for_status, normalize_hash, shape_error, status_rank, urlencode, DebridTransport,
    HttpRequest,
};

const BASE_V4: &str = "https://api.alldebrid.com/v4";
const BASE_V41: &str = "https://api.alldebrid.com/v4.1";
/// The application identifier AllDebrid asks clients to send.
const AGENT: &str = "vortx";
/// Bail-out for pathological folder nesting in `magnet/files` trees.
const MAX_FILE_TREE_DEPTH: usize = 8;

/// The live AllDebrid store. Construct with a shared transport and the account's api key
/// (injected by the host; never read from the environment here, never logged).
pub struct AllDebridStore {
    http: Arc<dyn DebridTransport>,
    token: String,
}

impl AllDebridStore {
    pub fn new(http: Arc<dyn DebridTransport>, token: impl Into<String>) -> Self {
        Self {
            http,
            token: token.into(),
        }
    }

    /// Execute one authorized call and unwrap AllDebrid's `{status, data, error}` envelope.
    fn call<T: DeserializeOwned>(
        &self,
        op: &'static str,
        req: HttpRequest,
    ) -> Result<T, DebridError> {
        let response = self.http.execute(&req.with_bearer(self.token.clone()))?;
        match serde_json::from_str::<AdEnvelope<T>>(&response.body) {
            Ok(env) if env.status == "success" => env
                .data
                .ok_or_else(|| shape_error("alldebrid", op, "success without data")),
            Ok(env) => Err(map_ad_error(op, env.error)),
            Err(parse) => {
                if response.is_success() {
                    Err(DebridError::Other(format!(
                        "alldebrid {op}: malformed response: {parse}"
                    )))
                } else {
                    Err(error_for_status("alldebrid", op, response.status))
                }
            }
        }
    }

    fn fetch_status(&self, id: &str) -> Result<AdMagnet, DebridError> {
        let url = format!(
            "{BASE_V41}/magnet/status?agent={AGENT}&id={}",
            urlencode(id)
        );
        let data: AdMagnetsWrap<OneOrMany<AdMagnet>> =
            self.call("get_magnet", HttpRequest::get(url))?;
        match data.magnets {
            OneOrMany::One(magnet) => Ok(magnet),
            OneOrMany::Many(list) => list.into_iter().next().ok_or(DebridError::NotFound),
        }
    }

    fn fetch_files(&self, id: &str) -> Result<Vec<MagnetFile>, DebridError> {
        let url = format!(
            "{BASE_V4}/magnet/files?agent={AGENT}&id[]={}",
            urlencode(id)
        );
        let data: AdMagnetsWrap<Vec<AdMagnetFiles>> =
            self.call("get_magnet", HttpRequest::get(url))?;
        let nodes = data
            .magnets
            .into_iter()
            .next()
            .map(|m| m.files)
            .unwrap_or_default();
        let mut files = Vec::new();
        flatten_file_tree(&nodes, "", 0, &mut files);
        Ok(files)
    }
}

impl DebridStore for AllDebridStore {
    fn name(&self) -> DebridService {
        DebridService::AllDebrid
    }

    fn get_user(&self) -> Result<DebridUser, DebridError> {
        let data: AdUserWrap = self.call(
            "get_user",
            HttpRequest::get(format!("{BASE_V4}/user?agent={AGENT}")),
        )?;
        let user = data.user;
        Ok(DebridUser {
            id: user.username,
            email: user.email,
            premium: user.is_premium,
            expiration: u64::try_from(user.premium_until).ok().filter(|t| *t > 0),
        })
    }

    fn check_magnets(&self, hashes: &[String]) -> Result<Vec<(String, MagnetStatus)>, DebridError> {
        let data: AdMagnetsWrap<Vec<AdMagnet>> = self.call(
            "check_magnets",
            HttpRequest::get(format!("{BASE_V41}/magnet/status?agent={AGENT}")),
        )?;
        let mut best: BTreeMap<String, MagnetStatus> = BTreeMap::new();
        for magnet in data.magnets {
            let hash = normalize_hash(&magnet.hash);
            let status = map_ad_status(magnet.status_code, &magnet.status);
            match best.get(&hash) {
                Some(current) if status_rank(*current) >= status_rank(status) => {}
                _ => {
                    best.insert(hash, status);
                }
            }
        }
        Ok(hashes
            .iter()
            .map(|hash| {
                let status = best
                    .get(&normalize_hash(hash))
                    .copied()
                    .unwrap_or(MagnetStatus::Unknown);
                (hash.clone(), status)
            })
            .collect())
    }

    fn add_magnet(&self, magnet: &str) -> Result<AddedMagnet, DebridError> {
        let data: AdMagnetsWrap<Vec<AdUploaded>> = self.call(
            "add_magnet",
            HttpRequest::post(format!("{BASE_V4}/magnet/upload?agent={AGENT}"))
                .with_form(vec![("magnets[]".to_string(), magnet.to_string())]),
        )?;
        let uploaded = data
            .magnets
            .into_iter()
            .next()
            .ok_or_else(|| shape_error("alldebrid", "add_magnet", "empty magnets array"))?;
        if let Some(err) = uploaded.error {
            return Err(map_ad_error("add_magnet", Some(err)));
        }
        Ok(AddedMagnet {
            id: uploaded.id.to_string(),
            infohash: normalize_hash(&uploaded.hash),
        })
    }

    fn get_magnet(&self, id: &str) -> Result<MagnetInfo, DebridError> {
        let magnet = self.fetch_status(id)?;
        let status = map_ad_status(magnet.status_code, &magnet.status);
        let files = if status.is_ready() {
            self.fetch_files(id)?
        } else {
            Vec::new()
        };
        Ok(MagnetInfo {
            id: magnet.id.to_string(),
            infohash: normalize_hash(&magnet.hash),
            status,
            files,
        })
    }

    fn remove_magnet(&self, id: &str) -> Result<(), DebridError> {
        let _data: AdMessage = self.call(
            "remove_magnet",
            HttpRequest::get(format!(
                "{BASE_V4}/magnet/delete?agent={AGENT}&id={}",
                urlencode(id)
            )),
        )?;
        Ok(())
    }

    fn generate_link(&self, restricted: &str) -> Result<String, DebridError> {
        let data: AdUnlocked = self.call(
            "generate_link",
            HttpRequest::get(format!(
                "{BASE_V4}/link/unlock?agent={AGENT}&link={}",
                urlencode(restricted)
            )),
        )?;
        if data.link.is_empty() {
            return Err(shape_error(
                "alldebrid",
                "generate_link",
                "empty link (delayed generation is not supported for magnet links)",
            ));
        }
        Ok(data.link)
    }
}

/// Map an AllDebrid error envelope onto the normalized error space. The AUTH_* family (recorded
/// live: `AUTH_BAD_APIKEY` rides HTTP 200) is a credential problem; premium-wall codes are
/// surfaced as unauthorized too, since the fix is the same: the account, not the request.
fn map_ad_error(op: &'static str, error: Option<AdError>) -> DebridError {
    let Some(error) = error else {
        return DebridError::Other(format!("alldebrid {op}: error status without error body"));
    };
    match error.code.as_str() {
        code if code.starts_with("AUTH_") => DebridError::Unauthorized,
        "MAGNET_MUST_BE_PREMIUM" | "MUST_BE_PREMIUM" | "FREE_TRIAL_LIMIT_REACHED" => {
            DebridError::Unauthorized
        }
        "MAGNET_INVALID_ID" => DebridError::NotFound,
        "MAGNET_TOO_MANY_ACTIVE" | "MAGNET_PROCESSING" => DebridError::RateLimited,
        code => DebridError::Other(format!("alldebrid {op}: {code}: {}", error.message)),
    }
}

/// AllDebrid status codes onto the normalized enum: 0 queue, 1 download, 2 compress/move,
/// 3 upload, 4 ready, 5..=11 the documented failure family. The string is the fallback for
/// entries missing the code.
fn map_ad_status(code: Option<i64>, status: &str) -> MagnetStatus {
    match code {
        Some(0) => MagnetStatus::Queued,
        Some(1) => MagnetStatus::Downloading,
        Some(2) => MagnetStatus::Processing,
        Some(3) => MagnetStatus::Uploading,
        Some(4) => MagnetStatus::Downloaded,
        Some(5..=11) => MagnetStatus::Failed,
        Some(_) => MagnetStatus::Unknown,
        None => match status {
            "Ready" => MagnetStatus::Downloaded,
            "Downloading" => MagnetStatus::Downloading,
            "In Queue" => MagnetStatus::Queued,
            "Uploading" => MagnetStatus::Uploading,
            _ => MagnetStatus::Unknown,
        },
    }
}

/// Flatten AllDebrid's nested `{n, s, l, e}` file tree into normalized files, joining folder
/// names into a `/`-separated path. `idx` is the flattened enumeration order (AllDebrid has no
/// per-file index; links are per-file, so the order only needs to be stable, and this walk is).
fn flatten_file_tree(nodes: &[AdNode], prefix: &str, depth: usize, out: &mut Vec<MagnetFile>) {
    if depth > MAX_FILE_TREE_DEPTH {
        return;
    }
    for node in nodes {
        let path = if prefix.is_empty() {
            node.name.clone()
        } else {
            format!("{prefix}/{}", node.name)
        };
        if let Some(link) = &node.link {
            let idx = u32::try_from(out.len()).unwrap_or(u32::MAX);
            out.push(MagnetFile {
                idx,
                path,
                size: node.size,
                link: Some(link.clone()),
            });
        } else if let Some(entries) = &node.entries {
            flatten_file_tree(entries, &path, depth + 1, out);
        }
    }
}

#[derive(Deserialize)]
struct AdEnvelope<T> {
    status: String,
    data: Option<T>,
    #[serde(default)]
    error: Option<AdError>,
}

#[derive(Deserialize)]
struct AdError {
    #[serde(default)]
    code: String,
    #[serde(default)]
    message: String,
}

#[derive(Deserialize)]
struct AdUserWrap {
    user: AdUser,
}

#[derive(Deserialize)]
struct AdUser {
    username: String,
    #[serde(default)]
    email: Option<String>,
    #[serde(default, rename = "isPremium")]
    is_premium: bool,
    #[serde(default, rename = "premiumUntil")]
    premium_until: i64,
}

#[derive(Deserialize)]
struct AdMagnetsWrap<T> {
    magnets: T,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum OneOrMany<T> {
    One(T),
    Many(Vec<T>),
}

#[derive(Deserialize)]
struct AdMagnet {
    id: i64,
    #[serde(default)]
    hash: String,
    #[serde(default)]
    status: String,
    #[serde(default, rename = "statusCode")]
    status_code: Option<i64>,
}

#[derive(Deserialize)]
struct AdUploaded {
    #[serde(default)]
    id: i64,
    #[serde(default)]
    hash: String,
    #[serde(default)]
    error: Option<AdError>,
}

#[derive(Deserialize)]
struct AdMagnetFiles {
    #[serde(default)]
    files: Vec<AdNode>,
}

#[derive(Deserialize)]
struct AdNode {
    #[serde(rename = "n")]
    name: String,
    #[serde(default, rename = "s")]
    size: u64,
    #[serde(default, rename = "l")]
    link: Option<String>,
    #[serde(default, rename = "e")]
    entries: Option<Vec<AdNode>>,
}

#[derive(Deserialize)]
struct AdMessage {
    #[serde(default)]
    #[allow(dead_code)]
    message: String,
}

#[derive(Deserialize)]
struct AdUnlocked {
    #[serde(default)]
    link: String,
}

#[cfg(test)]
mod tests {
    use super::super::testutil::{ReplayTransport, Route};
    use super::super::{HttpBody, HttpMethod};
    use super::*;

    const TOKEN: &str = "ad-test-key";
    const READY: &str = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c";
    const DOWNLOADING: &str = "aaaa5555ecdc7ca55fb0bbf81323d87062db1f6d";
    const ABSENT: &str = "bbbb5555ecdc7ca55fb0bbf81323d87062db1f6d";

    fn store(routes: Vec<Route>) -> (Arc<ReplayTransport>, AllDebridStore) {
        let transport = Arc::new(ReplayTransport::new(routes));
        let store = AllDebridStore::new(Arc::clone(&transport) as Arc<dyn DebridTransport>, TOKEN);
        (transport, store)
    }

    #[test]
    fn get_user_reads_the_unix_premium_until_directly() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/v4/user",
            200,
            include_str!("../../fixtures/debrid/alldebrid/user.json"),
        )]);
        let user = store.get_user().expect("user");
        assert_eq!(user.id, "vortxtester");
        assert!(user.premium);
        assert_eq!(user.expiration, Some(1_788_220_800));
        let calls = transport.calls();
        assert_eq!(calls[0].bearer.as_deref(), Some(TOKEN));
        assert!(calls[0].url.contains("agent=vortx"));
    }

    #[test]
    fn check_magnets_classifies_from_the_account_magnet_list() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/v4.1/magnet/status",
            200,
            include_str!("../../fixtures/debrid/alldebrid/magnet_status_all.json"),
        )]);
        let out = store
            .check_magnets(&[
                READY.to_string(),
                ABSENT.to_string(),
                DOWNLOADING.to_string(),
            ])
            .expect("check");
        assert_eq!(out[0], (READY.to_string(), MagnetStatus::Downloaded));
        assert!(out[0].1.is_ready());
        assert_eq!(out[1], (ABSENT.to_string(), MagnetStatus::Unknown));
        assert_eq!(out[2], (DOWNLOADING.to_string(), MagnetStatus::Downloading));
        // The status list is the v4.1 endpoint (v4 is deprecated on the wire).
        let calls = transport.calls();
        assert!(calls[0].url.starts_with("https://api.alldebrid.com/v4.1/"));
    }

    #[test]
    fn add_magnet_uploads_and_returns_the_reported_hash() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/v4/magnet/upload",
            200,
            include_str!("../../fixtures/debrid/alldebrid/magnet_upload.json"),
        )]);
        let magnet = format!("magnet:?xt=urn:btih:{READY}");
        let added = store.add_magnet(&magnet).expect("add");
        assert_eq!(added.id, "186112901");
        assert_eq!(added.infohash, READY);
        let calls = transport.calls();
        assert!(matches!(
            &calls[0].body,
            HttpBody::Form(fields) if fields == &[("magnets[]".to_string(), magnet.clone())]
        ));
    }

    #[test]
    fn get_magnet_flattens_the_nested_file_tree_for_a_ready_magnet() {
        let (_, store) = store(vec![
            Route::new(
                HttpMethod::Get,
                "/v4.1/magnet/status",
                200,
                include_str!("../../fixtures/debrid/alldebrid/magnet_status_one.json"),
            ),
            Route::new(
                HttpMethod::Get,
                "/v4/magnet/files",
                200,
                include_str!("../../fixtures/debrid/alldebrid/magnet_files.json"),
            ),
        ]);
        let info = store.get_magnet("186112901").expect("magnet");
        assert_eq!(info.id, "186112901");
        // The wire hash is uppercase in this recording; the store normalizes.
        assert_eq!(info.infohash, READY);
        assert_eq!(info.status, MagnetStatus::Downloaded);
        assert_eq!(info.files.len(), 2);
        assert_eq!(info.files[0].path, "Show.S01E01.2160p.WEB-DL.mkv");
        assert_eq!(
            info.files[0].link.as_deref(),
            Some("https://uptobox.example/dl/ADRESTRICTED01")
        );
        assert_eq!(info.files[1].path, "Subs/eng.srt");
        assert_eq!(info.files[1].idx, 1);
        assert_eq!(info.files[1].size, 65_536);
    }

    #[test]
    fn generate_link_unlocks_to_the_direct_url() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/v4/link/unlock",
            200,
            include_str!("../../fixtures/debrid/alldebrid/link_unlock.json"),
        )]);
        let direct = store
            .generate_link("https://uptobox.example/dl/ADRESTRICTED01")
            .expect("unlock");
        assert_eq!(
            direct,
            "https://tb27.alldebrid.example/dl/ad9f2c/Show.S01E01.2160p.WEB-DL.mkv"
        );
        // The restricted link is percent-encoded into the query.
        let calls = transport.calls();
        assert!(calls[0]
            .url
            .contains("link=https%3A%2F%2Fuptobox%2Eexample%2Fdl%2FADRESTRICTED01"));
    }

    #[test]
    fn remove_magnet_accepts_the_delete_message() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/v4/magnet/delete",
            200,
            include_str!("../../fixtures/debrid/alldebrid/magnet_delete.json"),
        )]);
        store.remove_magnet("186112901").expect("delete");
    }

    #[test]
    fn the_recorded_bad_apikey_envelope_on_http_200_maps_to_unauthorized() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/v4/user",
            200,
            include_str!("../../fixtures/debrid/alldebrid/error_bad_apikey.json"),
        )]);
        assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    }
}
