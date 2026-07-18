//! RealDebrid behind the normalized store contract (`api.real-debrid.com/rest/1.0`, bearer auth).
//!
//! Cache-check reality, verified live 2026-07-18: RealDebrid REMOVED the public
//! `/torrents/instantAvailability` bulk cache probe (November 2023); there is no service-side
//! "is this hash cached" call anymore. `check_magnets` therefore answers from the strongest
//! signal the API still offers: the account's OWN torrent library (`GET /torrents`). A hash
//! already downloaded on the account IS instantly playable; every other hash is honestly
//! `Unknown`, and network-wide cache knowledge flows from the hive CacheFact vault, which is
//! exactly the flywheel the kernel's resolve planner is built around.
//!
//! Add flow: RealDebrid parks a fresh magnet in `waiting_files_selection`, so `add_magnet`
//! performs the canonical add -> info -> select-all sequence; without the selection the torrent
//! never starts.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::Deserialize;
use vortx_debrid::{
    AddedMagnet, DebridError, DebridService, DebridStore, DebridUser, MagnetFile, MagnetInfo,
    MagnetStatus,
};

use super::{
    error_for_status, iso8601_to_unix, normalize_hash, parse_json, status_rank, DebridTransport,
    HttpRequest, HttpResponse,
};

const BASE: &str = "https://api.real-debrid.com/rest/1.0";

/// One page of the library scan behind `check_magnets`. RealDebrid's list endpoint caps `limit`
/// well above this; one request keeps every 500-hash batch at one round trip. Hashes beyond the
/// newest `LIBRARY_SCAN_LIMIT` account torrents report `Unknown` (documented limitation).
const LIBRARY_SCAN_LIMIT: u32 = 1000;

/// The live RealDebrid store. Construct with a shared transport and the account's api token
/// (injected by the host; never read from the environment here, never logged).
pub struct RealDebridStore {
    http: Arc<dyn DebridTransport>,
    token: String,
}

impl RealDebridStore {
    pub fn new(http: Arc<dyn DebridTransport>, token: impl Into<String>) -> Self {
        Self {
            http,
            token: token.into(),
        }
    }

    /// Execute one authorized call; non-2xx maps through RealDebrid's `{error, error_code}` body.
    fn call(&self, op: &'static str, req: HttpRequest) -> Result<HttpResponse, DebridError> {
        let response = self.http.execute(&req.with_bearer(self.token.clone()))?;
        if response.is_success() {
            return Ok(response);
        }
        Err(map_rd_error(op, &response))
    }

    fn fetch_info(&self, id: &str) -> Result<RdTorrentInfo, DebridError> {
        let res = self.call(
            "get_magnet",
            HttpRequest::get(format!("{BASE}/torrents/info/{id}")),
        )?;
        parse_json("realdebrid", "get_magnet", &res.body)
    }
}

impl DebridStore for RealDebridStore {
    fn name(&self) -> DebridService {
        DebridService::RealDebrid
    }

    fn get_user(&self) -> Result<DebridUser, DebridError> {
        let res = self.call("get_user", HttpRequest::get(format!("{BASE}/user")))?;
        let user: RdUser = parse_json("realdebrid", "get_user", &res.body)?;
        let premium = user.kind.as_deref() == Some("premium") || user.premium > 0;
        Ok(DebridUser {
            id: user.id.to_string(),
            email: user.email,
            premium,
            expiration: user.expiration.as_deref().and_then(iso8601_to_unix),
        })
    }

    fn check_magnets(&self, hashes: &[String]) -> Result<Vec<(String, MagnetStatus)>, DebridError> {
        let res = self.call(
            "check_magnets",
            HttpRequest::get(format!("{BASE}/torrents?limit={LIBRARY_SCAN_LIMIT}")),
        )?;
        // An empty library answers 204 with an empty body.
        let library: Vec<RdTorrentSummary> = if res.body.trim().is_empty() {
            Vec::new()
        } else {
            parse_json("realdebrid", "check_magnets", &res.body)?
        };
        let mut best: BTreeMap<String, MagnetStatus> = BTreeMap::new();
        for torrent in library {
            let hash = normalize_hash(&torrent.hash);
            let status = map_rd_status(&torrent.status);
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
        let res = self.call(
            "add_magnet",
            HttpRequest::post(format!("{BASE}/torrents/addMagnet"))
                .with_form(vec![("magnet".to_string(), magnet.to_string())]),
        )?;
        let added: RdAdded = parse_json("realdebrid", "add_magnet", &res.body)?;
        let info = self.fetch_info(&added.id)?;
        if info.status == "waiting_files_selection" {
            self.call(
                "add_magnet",
                HttpRequest::post(format!("{BASE}/torrents/selectFiles/{}", added.id))
                    .with_form(vec![("files".to_string(), "all".to_string())]),
            )?;
        }
        Ok(AddedMagnet {
            id: added.id,
            infohash: normalize_hash(&info.hash),
        })
    }

    fn get_magnet(&self, id: &str) -> Result<MagnetInfo, DebridError> {
        let info = self.fetch_info(id)?;
        // `links` pairs with the SELECTED files, in file order.
        let mut selected_seen = 0usize;
        let files = info
            .files
            .iter()
            .map(|file| {
                let link = if file.selected == 1 {
                    let link = info.links.get(selected_seen).cloned();
                    selected_seen += 1;
                    link
                } else {
                    None
                };
                MagnetFile {
                    idx: u32::try_from(file.id).unwrap_or(0),
                    path: file.path.clone(),
                    size: u64::try_from(file.bytes).unwrap_or(0),
                    link,
                }
            })
            .collect();
        Ok(MagnetInfo {
            id: info.id,
            infohash: normalize_hash(&info.hash),
            status: map_rd_status(&info.status),
            files,
        })
    }

    fn remove_magnet(&self, id: &str) -> Result<(), DebridError> {
        self.call(
            "remove_magnet",
            HttpRequest::delete(format!("{BASE}/torrents/delete/{id}")),
        )?;
        Ok(())
    }

    fn generate_link(&self, restricted: &str) -> Result<String, DebridError> {
        let res = self.call(
            "generate_link",
            HttpRequest::post(format!("{BASE}/unrestrict/link"))
                .with_form(vec![("link".to_string(), restricted.to_string())]),
        )?;
        let unrestricted: RdUnrestricted = parse_json("realdebrid", "generate_link", &res.body)?;
        Ok(unrestricted.download)
    }
}

/// Map RealDebrid's `{error, error_code}` body (recorded live: `bad_token` is code 8) onto the
/// normalized error space, falling back to the HTTP status for unknown codes.
fn map_rd_error(op: &'static str, response: &HttpResponse) -> DebridError {
    #[derive(Deserialize)]
    struct RdError {
        #[serde(default)]
        error: String,
        #[serde(default)]
        error_code: i64,
    }
    if let Ok(err) = serde_json::from_str::<RdError>(&response.body) {
        return match err.error_code {
            // 8 bad_token, 9 permission_denied: both are credential problems.
            8 | 9 => DebridError::Unauthorized,
            // 5 slow_down, 34 too_many_requests.
            5 | 34 => DebridError::RateLimited,
            // 7 resource_not_found.
            7 => DebridError::NotFound,
            code => DebridError::Other(format!(
                "realdebrid {op}: {} (code {code}, http {})",
                err.error, response.status
            )),
        };
    }
    error_for_status("realdebrid", op, response.status)
}

/// RealDebrid torrent statuses onto the normalized enum.
fn map_rd_status(status: &str) -> MagnetStatus {
    match status {
        "downloaded" => MagnetStatus::Downloaded,
        "queued" | "waiting_files_selection" | "magnet_conversion" => MagnetStatus::Queued,
        "downloading" => MagnetStatus::Downloading,
        "compressing" => MagnetStatus::Processing,
        "uploading" => MagnetStatus::Uploading,
        "error" | "magnet_error" | "virus" | "dead" => MagnetStatus::Failed,
        _ => MagnetStatus::Unknown,
    }
}

#[derive(Deserialize)]
struct RdUser {
    id: i64,
    #[serde(default)]
    email: Option<String>,
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    premium: i64,
    #[serde(default)]
    expiration: Option<String>,
}

#[derive(Deserialize)]
struct RdTorrentSummary {
    #[serde(default)]
    hash: String,
    #[serde(default)]
    status: String,
}

#[derive(Deserialize)]
struct RdAdded {
    id: String,
}

#[derive(Deserialize)]
struct RdTorrentInfo {
    id: String,
    #[serde(default)]
    hash: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    files: Vec<RdFile>,
    #[serde(default)]
    links: Vec<String>,
}

#[derive(Deserialize)]
struct RdFile {
    id: i64,
    #[serde(default)]
    path: String,
    #[serde(default)]
    bytes: i64,
    #[serde(default)]
    selected: i64,
}

#[derive(Deserialize)]
struct RdUnrestricted {
    download: String,
}

#[cfg(test)]
mod tests {
    use super::super::testutil::{ReplayTransport, Route};
    use super::super::{HttpBody, HttpMethod};
    use super::*;

    const TOKEN: &str = "rd-test-token";
    const CACHED: &str = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c";
    const DOWNLOADING: &str = "aaaa5555ecdc7ca55fb0bbf81323d87062db1f6d";
    const ABSENT: &str = "bbbb5555ecdc7ca55fb0bbf81323d87062db1f6d";

    fn store(routes: Vec<Route>) -> (Arc<ReplayTransport>, RealDebridStore) {
        let transport = Arc::new(ReplayTransport::new(routes));
        let store = RealDebridStore::new(Arc::clone(&transport) as Arc<dyn DebridTransport>, TOKEN);
        (transport, store)
    }

    #[test]
    fn get_user_parses_premium_and_expiration_from_the_recorded_body() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/user",
            200,
            include_str!("../../fixtures/debrid/realdebrid/user.json"),
        )]);
        let user = store.get_user().expect("user");
        assert_eq!(user.id, "12345");
        assert_eq!(user.email.as_deref(), Some("tester@example.com"));
        assert!(user.premium);
        assert_eq!(user.expiration, Some(1_786_960_800));
        let calls = transport.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].bearer.as_deref(), Some(TOKEN));
    }

    #[test]
    fn check_magnets_classifies_ready_pending_and_unknown_in_input_order() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents?limit=",
            200,
            include_str!("../../fixtures/debrid/realdebrid/torrents.json"),
        )]);
        let out = store
            .check_magnets(&[
                ABSENT.to_string(),
                CACHED.to_uppercase(),
                DOWNLOADING.to_string(),
            ])
            .expect("check");
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], (ABSENT.to_string(), MagnetStatus::Unknown));
        // Input casing is echoed back; matching is case-insensitive.
        assert_eq!(out[1], (CACHED.to_uppercase(), MagnetStatus::Downloaded));
        assert!(out[1].1.is_ready());
        assert_eq!(out[2], (DOWNLOADING.to_string(), MagnetStatus::Downloading));
    }

    #[test]
    fn check_magnets_treats_the_empty_library_204_as_all_unknown() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents?limit=",
            204,
            "",
        )]);
        let out = store.check_magnets(&[CACHED.to_string()]).expect("check");
        assert_eq!(out, vec![(CACHED.to_string(), MagnetStatus::Unknown)]);
    }

    #[test]
    fn add_magnet_runs_add_info_select_and_returns_the_normalized_hash() {
        let (transport, store) = store(vec![
            Route::new(
                HttpMethod::Post,
                "/torrents/addMagnet",
                201,
                include_str!("../../fixtures/debrid/realdebrid/add_magnet.json"),
            ),
            Route::new(
                HttpMethod::Get,
                "/torrents/info/RDNEW0000001",
                200,
                include_str!("../../fixtures/debrid/realdebrid/torrent_info_waiting.json"),
            ),
            Route::new(
                HttpMethod::Post,
                "/torrents/selectFiles/RDNEW0000001",
                204,
                "",
            ),
        ]);
        let added = store
            .add_magnet(&format!("magnet:?xt=urn:btih:{CACHED}"))
            .expect("add");
        assert_eq!(added.id, "RDNEW0000001");
        // The fixture hash is uppercase on the wire; the store normalizes.
        assert_eq!(added.infohash, CACHED);
        let calls = transport.calls();
        assert_eq!(calls.len(), 3);
        // add (POST) -> info (GET) -> select-all (POST), in that order.
        assert_eq!(calls[0].method, HttpMethod::Post);
        assert_eq!(calls[1].method, HttpMethod::Get);
        assert_eq!(calls[2].method, HttpMethod::Post);
        assert!(matches!(
            &calls[2].body,
            HttpBody::Form(fields) if fields == &[("files".to_string(), "all".to_string())]
        ));
    }

    #[test]
    fn get_magnet_pairs_links_with_selected_files_only() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/torrents/info/RDLIB000001",
            200,
            include_str!("../../fixtures/debrid/realdebrid/torrent_info.json"),
        )]);
        let info = store.get_magnet("RDLIB000001").expect("info");
        assert_eq!(info.status, MagnetStatus::Downloaded);
        assert_eq!(info.infohash, CACHED);
        assert_eq!(info.files.len(), 3);
        assert_eq!(
            info.files[0].link.as_deref(),
            Some("https://real-debrid.com/d/RDRESTRICTED01")
        );
        assert_eq!(info.files[1].link, None);
        assert_eq!(
            info.files[2].link.as_deref(),
            Some("https://real-debrid.com/d/RDRESTRICTED03")
        );
        assert_eq!(info.files[0].idx, 1);
        assert_eq!(info.files[0].size, 4_831_838_208);
    }

    #[test]
    fn generate_link_unrestricts_to_the_direct_download() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/unrestrict/link",
            200,
            include_str!("../../fixtures/debrid/realdebrid/unrestrict.json"),
        )]);
        let direct = store
            .generate_link("https://real-debrid.com/d/RDRESTRICTED01")
            .expect("unrestrict");
        assert_eq!(
            direct,
            "https://sgp1-4.download.real-debrid.com/d/RDRESTRICTED01/Show.S01E01.2160p.WEB-DL.mkv"
        );
        let calls = transport.calls();
        assert!(matches!(
            &calls[0].body,
            HttpBody::Form(fields)
                if fields == &[(
                    "link".to_string(),
                    "https://real-debrid.com/d/RDRESTRICTED01".to_string()
                )]
        ));
    }

    #[test]
    fn remove_magnet_accepts_the_empty_204() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Delete,
            "/torrents/delete/RDLIB000001",
            204,
            "",
        )]);
        store.remove_magnet("RDLIB000001").expect("delete");
    }

    #[test]
    fn the_recorded_bad_token_body_maps_to_unauthorized() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/user",
            401,
            include_str!("../../fixtures/debrid/realdebrid/error_bad_token.json"),
        )]);
        assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    }
}
