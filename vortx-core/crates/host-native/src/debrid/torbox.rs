//! TorBox behind the normalized store contract (`api.torbox.app/v1/api`, bearer auth). TorBox is
//! the one live service that still offers a REAL bulk cache probe (`/torrents/checkcached`), so
//! this store answers `check_magnets` authoritatively.
//!
//! Wire facts verified live 2026-07-18: a bad token answers HTTP 403 with
//! `{"success":false,"error":"BAD_TOKEN",...}`; unauthenticated calls answer a bare FastAPI
//! `{"detail":"Not authenticated"}` with no envelope; and `/torrents/requestdl` REJECTS
//! header-only auth with a 422 demanding the `token` query parameter, so that one call carries
//! the key as a query secret appended at send time (and error paths never echo URLs).
//!
//! Per-file links: TorBox mints short-lived presigned URLs per (torrent, file) via `requestdl`,
//! so `get_magnet` publishes stable `torbox://<torrent_id>/<file_id>` claims as the restricted
//! links and `generate_link` redeems them into fresh direct URLs. Nothing downstream needs to
//! know (the same restricted -> unrestrict contract as every other store).

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde::Deserialize;
use vortx_debrid::{
    AddedMagnet, DebridError, DebridService, DebridStore, DebridUser, MagnetFile, MagnetInfo,
    MagnetStatus,
};

use super::{
    error_for_status, iso8601_to_unix, magnet_infohash, normalize_hash, shape_error,
    DebridTransport, HttpRequest,
};

const BASE: &str = "https://api.torbox.app/v1/api";

/// Hashes per `checkcached` request. The batch travels in the URL, so it is sub-chunked well
/// under common URL length limits (the kernel's 500-hash batches become 5 requests).
const CHECK_CHUNK: usize = 100;

/// The scheme for TorBox's per-file restricted links (see the module doc).
const CLAIM_PREFIX: &str = "torbox://";

/// The live TorBox store. Construct with a shared transport and the account's api token
/// (injected by the host; never read from the environment here, never logged).
pub struct TorBoxStore {
    http: Arc<dyn DebridTransport>,
    token: String,
}

impl TorBoxStore {
    pub fn new(http: Arc<dyn DebridTransport>, token: impl Into<String>) -> Self {
        Self {
            http,
            token: token.into(),
        }
    }

    /// Execute one authorized call and unwrap TorBox's `{success, error, detail, data}` envelope
    /// into the payload. Auth-family statuses win over envelope codes (the recorded 403
    /// BAD_TOKEN and the envelope-less 401 both land on `Unauthorized`).
    fn call<T: DeserializeOwned>(
        &self,
        op: &'static str,
        req: HttpRequest,
    ) -> Result<T, DebridError> {
        let envelope = self.call_envelope::<T>(op, req)?;
        envelope
            .data
            .ok_or_else(|| shape_error("torbox", op, "success without data"))
    }

    /// Like [`Self::call`] but tolerates `data: null` (control operations answer success with no
    /// payload, recorded in `control_delete.json`).
    fn call_unit(&self, op: &'static str, req: HttpRequest) -> Result<(), DebridError> {
        self.call_envelope::<serde_json::Value>(op, req)?;
        Ok(())
    }

    fn call_envelope<T: DeserializeOwned>(
        &self,
        op: &'static str,
        req: HttpRequest,
    ) -> Result<TbEnvelope<T>, DebridError> {
        let response = self.http.execute(&req.with_bearer(self.token.clone()))?;
        match serde_json::from_str::<TbEnvelope<T>>(&response.body) {
            Ok(env) if env.success => Ok(env),
            Ok(env) => Err(map_tb_error(op, response.status, env.error, env.detail)),
            Err(parse) => {
                if response.is_success() {
                    Err(DebridError::Other(format!(
                        "torbox {op}: malformed response: {parse}"
                    )))
                } else {
                    // The envelope-less FastAPI shapes (401 Not authenticated, 422 validation).
                    Err(error_for_status("torbox", op, response.status))
                }
            }
        }
    }
}

impl DebridStore for TorBoxStore {
    fn name(&self) -> DebridService {
        DebridService::TorBox
    }

    fn get_user(&self) -> Result<DebridUser, DebridError> {
        let user: TbUser = self.call("get_user", HttpRequest::get(format!("{BASE}/user/me")))?;
        Ok(DebridUser {
            id: user.id.to_string(),
            email: user.email,
            premium: user.plan > 0,
            expiration: user.premium_expires_at.as_deref().and_then(iso8601_to_unix),
        })
    }

    fn check_magnets(&self, hashes: &[String]) -> Result<Vec<(String, MagnetStatus)>, DebridError> {
        let mut cached: BTreeMap<String, ()> = BTreeMap::new();
        for chunk in hashes.chunks(CHECK_CHUNK) {
            let joined = chunk
                .iter()
                .map(|h| normalize_hash(h))
                .collect::<Vec<_>>()
                .join(",");
            let data: Option<TbCachedData> = self
                .call_envelope(
                    "check_magnets",
                    HttpRequest::get(format!(
                        "{BASE}/torrents/checkcached?format=object&list_files=false&hash={joined}"
                    )),
                )?
                .data;
            match data {
                Some(TbCachedData::Map(map)) => {
                    for key in map.keys() {
                        cached.insert(normalize_hash(key), ());
                    }
                }
                Some(TbCachedData::List(list)) => {
                    for entry in list {
                        cached.insert(normalize_hash(&entry.hash), ());
                    }
                }
                // A null / absent data payload means nothing in this chunk is cached.
                None => {}
            }
        }
        Ok(hashes
            .iter()
            .map(|hash| {
                let status = if cached.contains_key(&normalize_hash(hash)) {
                    MagnetStatus::Cached
                } else {
                    MagnetStatus::Unknown
                };
                (hash.clone(), status)
            })
            .collect())
    }

    fn add_magnet(&self, magnet: &str) -> Result<AddedMagnet, DebridError> {
        // The documented create shape is multipart/form-data.
        let created: TbCreated = self.call(
            "add_magnet",
            HttpRequest::post(format!("{BASE}/torrents/createtorrent"))
                .with_multipart(vec![("magnet".to_string(), magnet.to_string())]),
        )?;
        let id = if created.torrent_id != 0 {
            created.torrent_id
        } else {
            created.queued_id
        };
        if id == 0 {
            return Err(shape_error(
                "torbox",
                "add_magnet",
                "no torrent or queue id",
            ));
        }
        let infohash = if created.hash.is_empty() {
            magnet_infohash(magnet).unwrap_or_default()
        } else {
            normalize_hash(&created.hash)
        };
        Ok(AddedMagnet {
            id: id.to_string(),
            infohash,
        })
    }

    fn get_magnet(&self, id: &str) -> Result<MagnetInfo, DebridError> {
        let data: TbTorrentData = self.call(
            "get_magnet",
            HttpRequest::get(format!(
                "{BASE}/torrents/mylist?id={}&bypass_cache=true",
                tb_id(id)?
            )),
        )?;
        let torrent = match data {
            TbTorrentData::One(t) => *t,
            TbTorrentData::Many(list) => list.into_iter().next().ok_or(DebridError::NotFound)?,
        };
        let status = map_tb_status(&torrent);
        let ready = status.is_ready();
        let files = torrent
            .files
            .iter()
            .map(|file| MagnetFile {
                idx: u32::try_from(file.id).unwrap_or(0),
                path: file.name.clone(),
                size: file.size,
                link: ready.then(|| format!("{CLAIM_PREFIX}{}/{}", torrent.id, file.id)),
            })
            .collect();
        Ok(MagnetInfo {
            id: torrent.id.to_string(),
            infohash: normalize_hash(&torrent.hash),
            status,
            files,
        })
    }

    fn remove_magnet(&self, id: &str) -> Result<(), DebridError> {
        self.call_unit(
            "remove_magnet",
            HttpRequest::post(format!("{BASE}/torrents/controltorrent")).with_json(format!(
                "{{\"torrent_id\":{},\"operation\":\"delete\"}}",
                tb_id(id)?
            )),
        )
    }

    fn generate_link(&self, restricted: &str) -> Result<String, DebridError> {
        let claim = restricted.strip_prefix(CLAIM_PREFIX).ok_or_else(|| {
            shape_error(
                "torbox",
                "generate_link",
                "expected a torbox://<torrent_id>/<file_id> claim",
            )
        })?;
        let (torrent_id, file_id) = claim.split_once('/').ok_or_else(|| {
            shape_error(
                "torbox",
                "generate_link",
                "expected a torbox://<torrent_id>/<file_id> claim",
            )
        })?;
        let (torrent_id, file_id) = (tb_id(torrent_id)?, tb_id(file_id)?);
        // requestdl demands the token as a query parameter (verified live: header-only auth is a
        // 422); it rides as a query secret so no error path can echo it.
        let direct: String = self.call(
            "generate_link",
            HttpRequest::get(format!(
                "{BASE}/torrents/requestdl?torrent_id={torrent_id}&file_id={file_id}&redirect=false"
            ))
            .with_query_secret("token", self.token.clone()),
        )?;
        if direct.is_empty() {
            return Err(shape_error("torbox", "generate_link", "empty download url"));
        }
        Ok(direct)
    }
}

/// Parse a numeric TorBox id out of the store's string id space.
fn tb_id(id: &str) -> Result<i64, DebridError> {
    id.trim()
        .parse::<i64>()
        .map_err(|_| DebridError::Other(format!("torbox: non-numeric id: {id}")))
}

/// Map a failed TorBox envelope. Auth statuses first (recorded: 403 BAD_TOKEN), then the error
/// code families, then an honest passthrough of code + detail.
fn map_tb_error(
    op: &'static str,
    status: u16,
    error: Option<String>,
    detail: Option<String>,
) -> DebridError {
    match status {
        401 | 403 => return DebridError::Unauthorized,
        404 => return DebridError::NotFound,
        429 => return DebridError::RateLimited,
        _ => {}
    }
    let code = error.unwrap_or_default();
    match code.as_str() {
        "BAD_TOKEN" | "AUTH_ERROR" | "OAUTH_VERIFICATION_ERROR" | "PLAN_RESTRICTED_FEATURE" => {
            DebridError::Unauthorized
        }
        "NOT_FOUND" | "DATABASE_ERROR" if detail.as_deref().unwrap_or("").contains("not found") => {
            DebridError::NotFound
        }
        "ACTIVE_LIMIT" | "MONTHLY_LIMIT" | "COOLDOWN_LIMIT" => DebridError::RateLimited,
        _ => DebridError::Other(format!(
            "torbox {op}: {code}: {} (http {status})",
            detail.unwrap_or_default()
        )),
    }
}

/// TorBox exposes a state string plus finished/present booleans; the booleans are authoritative
/// for readiness, the string differentiates the pending family.
fn map_tb_status(torrent: &TbTorrent) -> MagnetStatus {
    if torrent.download_finished && torrent.download_present {
        return MagnetStatus::Downloaded;
    }
    match torrent.download_state.as_str() {
        "cached" | "completed" => MagnetStatus::Downloaded,
        "downloading" | "metaDL" | "checkingResumeData" | "stalled (no seeds)" | "stalledDL" => {
            MagnetStatus::Downloading
        }
        "uploading" | "uploading (no peers)" => MagnetStatus::Uploading,
        "queued" | "paused" => MagnetStatus::Queued,
        "processing" | "repairing" => MagnetStatus::Processing,
        "error" | "failed" | "missingFiles" => MagnetStatus::Failed,
        _ => MagnetStatus::Unknown,
    }
}

#[derive(Deserialize)]
struct TbEnvelope<T> {
    #[serde(default)]
    success: bool,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    detail: Option<String>,
    data: Option<T>,
}

#[derive(Deserialize)]
struct TbUser {
    id: i64,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    plan: i64,
    #[serde(default)]
    premium_expires_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum TbCachedData {
    Map(BTreeMap<String, TbCachedEntry>),
    List(Vec<TbCachedEntry>),
}

#[derive(Deserialize)]
struct TbCachedEntry {
    #[serde(default)]
    hash: String,
}

#[derive(Deserialize)]
struct TbCreated {
    #[serde(default)]
    torrent_id: i64,
    #[serde(default)]
    queued_id: i64,
    #[serde(default)]
    hash: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum TbTorrentData {
    One(Box<TbTorrent>),
    Many(Vec<TbTorrent>),
}

#[derive(Deserialize)]
struct TbTorrent {
    id: i64,
    #[serde(default)]
    hash: String,
    #[serde(default)]
    download_state: String,
    #[serde(default)]
    download_finished: bool,
    #[serde(default)]
    download_present: bool,
    #[serde(default)]
    files: Vec<TbFile>,
}

#[derive(Deserialize)]
struct TbFile {
    id: i64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    size: u64,
}

#[cfg(test)]
mod tests {
    use super::super::testutil::{ReplayTransport, Route};
    use super::super::{HttpBody, HttpMethod};
    use super::*;

    const TOKEN: &str = "tb-test-token";
    const CACHED: &str = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c";
    const ABSENT: &str = "bbbb5555ecdc7ca55fb0bbf81323d87062db1f6d";

    fn store(routes: Vec<Route>) -> (Arc<ReplayTransport>, TorBoxStore) {
        let transport = Arc::new(ReplayTransport::new(routes));
        let store = TorBoxStore::new(Arc::clone(&transport) as Arc<dyn DebridTransport>, TOKEN);
        (transport, store)
    }

    #[test]
    fn get_user_parses_plan_and_expiry() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/user/me",
            200,
            include_str!("../../fixtures/debrid/torbox/user_me.json"),
        )]);
        let user = store.get_user().expect("user");
        assert_eq!(user.id, "987654");
        assert!(user.premium);
        assert_eq!(user.expiration, Some(1_788_220_800));
        assert_eq!(transport.calls()[0].bearer.as_deref(), Some(TOKEN));
    }

    #[test]
    fn check_magnets_answers_cached_vs_unknown_from_the_object_map() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents/checkcached",
            200,
            include_str!("../../fixtures/debrid/torbox/checkcached.json"),
        )]);
        let out = store
            .check_magnets(&[ABSENT.to_string(), CACHED.to_uppercase()])
            .expect("check");
        assert_eq!(out[0], (ABSENT.to_string(), MagnetStatus::Unknown));
        assert_eq!(out[1], (CACHED.to_uppercase(), MagnetStatus::Cached));
        assert!(out[1].1.is_ready());
    }

    #[test]
    fn check_magnets_sub_chunks_the_url_borne_batch() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents/checkcached",
            200,
            include_str!("../../fixtures/debrid/torbox/checkcached.json"),
        )]);
        let hashes: Vec<String> = (0..150).map(|i| format!("{i:040x}")).collect();
        let out = store.check_magnets(&hashes).expect("check");
        assert_eq!(out.len(), 150);
        // 150 hashes with a 100-hash chunk = exactly 2 wire calls.
        assert_eq!(transport.calls().len(), 2);
    }

    #[test]
    fn add_magnet_posts_multipart_and_returns_the_ids() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/torrents/createtorrent",
            200,
            include_str!("../../fixtures/debrid/torbox/create.json"),
        )]);
        let magnet = format!("magnet:?xt=urn:btih:{CACHED}");
        let added = store.add_magnet(&magnet).expect("add");
        assert_eq!(added.id, "42421337");
        assert_eq!(added.infohash, CACHED);
        let calls = transport.calls();
        assert!(matches!(
            &calls[0].body,
            HttpBody::Multipart(fields) if fields == &[("magnet".to_string(), magnet.clone())]
        ));
    }

    #[test]
    fn get_magnet_mints_stable_claims_for_ready_files() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents/mylist",
            200,
            include_str!("../../fixtures/debrid/torbox/mylist.json"),
        )]);
        let info = store.get_magnet("42421337").expect("magnet");
        assert_eq!(info.status, MagnetStatus::Downloaded);
        assert_eq!(info.infohash, CACHED);
        assert_eq!(info.files.len(), 2);
        assert_eq!(info.files[0].link.as_deref(), Some("torbox://42421337/0"));
        assert_eq!(info.files[1].link.as_deref(), Some("torbox://42421337/1"));
        assert_eq!(info.files[1].idx, 1);
        assert_eq!(info.files[1].size, 65_536);
    }

    #[test]
    fn generate_link_redeems_a_claim_with_the_query_borne_token() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents/requestdl",
            200,
            include_str!("../../fixtures/debrid/torbox/requestdl.json"),
        )]);
        let direct = store.generate_link("torbox://42421337/0").expect("dl");
        assert!(direct.starts_with("https://store-031.wnam.tb-cdn.example/torrents/42421337/"));
        let calls = transport.calls();
        assert!(calls[0].url.contains("torrent_id=42421337&file_id=0"));
        // The token rides the query-secret channel, never the URL itself.
        assert!(!calls[0].url.contains(TOKEN));
        assert_eq!(
            calls[0].query_secret,
            Some(("token".to_string(), TOKEN.to_string()))
        );
    }

    #[test]
    fn generate_link_rejects_non_claim_input() {
        let (_, store) = store(Vec::new());
        assert!(matches!(
            store.generate_link("https://elsewhere.example/file"),
            Err(DebridError::Other(_))
        ));
    }

    #[test]
    fn remove_magnet_accepts_success_with_null_data() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/torrents/controltorrent",
            200,
            include_str!("../../fixtures/debrid/torbox/control_delete.json"),
        )]);
        store.remove_magnet("42421337").expect("delete");
        let calls = transport.calls();
        assert!(matches!(
            &calls[0].body,
            HttpBody::Json(json) if json == "{\"torrent_id\":42421337,\"operation\":\"delete\"}"
        ));
    }

    #[test]
    fn the_recorded_403_bad_token_maps_to_unauthorized() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/user/me",
            403,
            include_str!("../../fixtures/debrid/torbox/error_bad_token.json"),
        )]);
        assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    }

    #[test]
    fn the_envelope_less_401_maps_to_unauthorized() {
        // Recorded live: unauthenticated checkcached answers a bare FastAPI detail body.
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents/checkcached",
            401,
            r#"{"detail":"Not authenticated"}"#,
        )]);
        assert_eq!(
            store.check_magnets(&[CACHED.to_string()]),
            Err(DebridError::Unauthorized)
        );
    }
}
