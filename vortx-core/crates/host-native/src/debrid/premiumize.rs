//! Premiumize behind the normalized store contract (`www.premiumize.me/api`). Premiumize keys on
//! `apikey`, which its API takes as a request parameter; it rides the query-secret channel so it
//! is appended at send time and no error path can echo it. Errors ride HTTP 200 inside
//! `{"status":"error","message","code"}` (recorded live 2026-07-18: `authentication_failed`).
//!
//! Premiumize still offers a REAL bulk cache probe (`/cache/check`), answering one boolean per
//! queried hash, so `check_magnets` is authoritative here. Finished transfers expose their files
//! through the cloud folder tree (`/folder/list`, walked recursively) or a single `file_id`
//! (`/item/details`); the links those answers carry are ALREADY direct, so `generate_link` is a
//! validating passthrough (the same restricted -> unrestrict contract, degenerate case).

use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde::Deserialize;
use vortx_debrid::{
    AddedMagnet, DebridError, DebridService, DebridStore, DebridUser, MagnetFile, MagnetInfo,
    MagnetStatus,
};

use super::{
    error_for_status, magnet_infohash, normalize_hash, parse_json, shape_error, urlencode,
    DebridTransport, HttpRequest,
};

const BASE: &str = "https://www.premiumize.me/api";
/// Bail-out for pathological folder nesting when walking a finished transfer's tree.
const MAX_FOLDER_DEPTH: usize = 5;

/// The live Premiumize store. Construct with a shared transport and the account's api key
/// (injected by the host; never read from the environment here, never logged).
pub struct PremiumizeStore {
    http: Arc<dyn DebridTransport>,
    key: String,
}

impl PremiumizeStore {
    pub fn new(http: Arc<dyn DebridTransport>, key: impl Into<String>) -> Self {
        Self {
            http,
            key: key.into(),
        }
    }

    /// Execute one keyed call: check the `{status}` envelope first, then parse the payload out of
    /// the same body (Premiumize answers flat objects, not a nested `data`).
    fn call<T: DeserializeOwned>(
        &self,
        op: &'static str,
        req: HttpRequest,
    ) -> Result<T, DebridError> {
        let response = self
            .http
            .execute(&req.with_query_secret("apikey", self.key.clone()))?;
        if !response.is_success() {
            return Err(error_for_status("premiumize", op, response.status));
        }
        let envelope: PmStatus = parse_json("premiumize", op, &response.body)?;
        if envelope.status != "success" {
            return Err(map_pm_error(op, &envelope));
        }
        parse_json("premiumize", op, &response.body)
    }

    /// Walk a cloud folder into normalized files, depth-capped, `/`-joining subfolder names.
    fn walk_folder(
        &self,
        folder_id: &str,
        prefix: &str,
        depth: usize,
        out: &mut Vec<MagnetFile>,
    ) -> Result<(), DebridError> {
        if depth > MAX_FOLDER_DEPTH {
            return Ok(());
        }
        let listing: PmFolder = self.call(
            "get_magnet",
            HttpRequest::get(format!("{BASE}/folder/list?id={}", urlencode(folder_id))),
        )?;
        for item in listing.content {
            let path = if prefix.is_empty() {
                item.name.clone()
            } else {
                format!("{prefix}/{}", item.name)
            };
            match item.kind.as_str() {
                "file" => {
                    let idx = u32::try_from(out.len()).unwrap_or(u32::MAX);
                    out.push(MagnetFile {
                        idx,
                        path,
                        size: item.size,
                        link: item.link.clone(),
                    });
                }
                "folder" => self.walk_folder(&item.id, &path, depth + 1, out)?,
                _ => {}
            }
        }
        Ok(())
    }
}

impl DebridStore for PremiumizeStore {
    fn name(&self) -> DebridService {
        DebridService::Premiumize
    }

    fn get_user(&self) -> Result<DebridUser, DebridError> {
        let info: PmAccount =
            self.call("get_user", HttpRequest::get(format!("{BASE}/account/info")))?;
        let expiration = info.premium_until.filter(|t| *t > 0);
        Ok(DebridUser {
            id: info.customer_id_string(),
            email: None,
            premium: expiration.is_some(),
            expiration,
        })
    }

    fn check_magnets(&self, hashes: &[String]) -> Result<Vec<(String, MagnetStatus)>, DebridError> {
        if hashes.is_empty() {
            return Ok(Vec::new());
        }
        let fields = hashes
            .iter()
            .map(|hash| ("items[]".to_string(), normalize_hash(hash)))
            .collect();
        let checked: PmCacheCheck = self.call(
            "check_magnets",
            HttpRequest::post(format!("{BASE}/cache/check")).with_form(fields),
        )?;
        if checked.response.len() != hashes.len() {
            return Err(shape_error(
                "premiumize",
                "check_magnets",
                "cache/check answered a different count than asked",
            ));
        }
        Ok(hashes
            .iter()
            .zip(checked.response)
            .map(|(hash, cached)| {
                let status = if cached {
                    MagnetStatus::Cached
                } else {
                    MagnetStatus::Unknown
                };
                (hash.clone(), status)
            })
            .collect())
    }

    fn add_magnet(&self, magnet: &str) -> Result<AddedMagnet, DebridError> {
        let infohash = magnet_infohash(magnet).ok_or_else(|| {
            shape_error(
                "premiumize",
                "add_magnet",
                "magnet carries no parseable btih infohash",
            )
        })?;
        let created: PmCreated = self.call(
            "add_magnet",
            HttpRequest::post(format!("{BASE}/transfer/create"))
                .with_form(vec![("src".to_string(), magnet.to_string())]),
        )?;
        if created.id.is_empty() {
            return Err(shape_error("premiumize", "add_magnet", "empty transfer id"));
        }
        Ok(AddedMagnet {
            id: created.id,
            infohash,
        })
    }

    fn get_magnet(&self, id: &str) -> Result<MagnetInfo, DebridError> {
        let listing: PmTransferList = self.call(
            "get_magnet",
            HttpRequest::get(format!("{BASE}/transfer/list")),
        )?;
        let transfer = listing
            .transfers
            .into_iter()
            .find(|t| t.id == id)
            .ok_or(DebridError::NotFound)?;
        let status = map_pm_status(&transfer.status);
        let mut files = Vec::new();
        if status.is_ready() {
            if let Some(folder_id) = transfer.folder_id.as_deref().filter(|f| !f.is_empty()) {
                self.walk_folder(folder_id, "", 0, &mut files)?;
            } else if let Some(file_id) = transfer.file_id.as_deref().filter(|f| !f.is_empty()) {
                let item: PmItem = self.call(
                    "get_magnet",
                    HttpRequest::get(format!("{BASE}/item/details?id={}", urlencode(file_id))),
                )?;
                files.push(MagnetFile {
                    idx: 0,
                    path: item.name,
                    size: item.size,
                    link: item.link,
                });
            }
        }
        let infohash = transfer
            .src
            .as_deref()
            .and_then(magnet_infohash)
            .unwrap_or_default();
        Ok(MagnetInfo {
            id: transfer.id,
            infohash,
            status,
            files,
        })
    }

    fn remove_magnet(&self, id: &str) -> Result<(), DebridError> {
        let _status: PmStatus = self.call(
            "remove_magnet",
            HttpRequest::post(format!("{BASE}/transfer/delete"))
                .with_form(vec![("id".to_string(), id.to_string())]),
        )?;
        Ok(())
    }

    fn generate_link(&self, restricted: &str) -> Result<String, DebridError> {
        // Premiumize folder links are already direct; validate and pass through.
        if restricted.starts_with("https://") || restricted.starts_with("http://") {
            return Ok(restricted.to_string());
        }
        Err(shape_error(
            "premiumize",
            "generate_link",
            "expected an already-direct premiumize link",
        ))
    }
}

/// Map a Premiumize error envelope (recorded live: `authentication_failed` rides HTTP 200).
fn map_pm_error(op: &'static str, envelope: &PmStatus) -> DebridError {
    let code = envelope.code.as_deref().unwrap_or_default();
    let message = envelope.message.as_deref().unwrap_or_default();
    match code {
        "authentication_failed" => DebridError::Unauthorized,
        "rate_limit_exceeded" => DebridError::RateLimited,
        "not_found" => DebridError::NotFound,
        _ => DebridError::Other(format!("premiumize {op}: {code}: {message}")),
    }
}

/// Premiumize transfer statuses onto the normalized enum.
fn map_pm_status(status: &str) -> MagnetStatus {
    match status {
        "finished" | "seeding" => MagnetStatus::Downloaded,
        "running" => MagnetStatus::Downloading,
        "waiting" | "queued" => MagnetStatus::Queued,
        "deleted" | "banned" | "error" | "timeout" => MagnetStatus::Failed,
        _ => MagnetStatus::Unknown,
    }
}

#[derive(Deserialize)]
struct PmStatus {
    status: String,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    code: Option<String>,
}

#[derive(Deserialize)]
struct PmAccount {
    #[serde(default)]
    customer_id: serde_json::Value,
    #[serde(default)]
    premium_until: Option<u64>,
}

impl PmAccount {
    /// Premiumize documents `customer_id` as a number; tolerate a string on the wire too.
    fn customer_id_string(&self) -> String {
        match &self.customer_id {
            serde_json::Value::String(s) => s.clone(),
            serde_json::Value::Number(n) => n.to_string(),
            _ => String::new(),
        }
    }
}

#[derive(Deserialize)]
struct PmCacheCheck {
    #[serde(default)]
    response: Vec<bool>,
}

#[derive(Deserialize)]
struct PmCreated {
    #[serde(default)]
    id: String,
}

#[derive(Deserialize)]
struct PmTransferList {
    #[serde(default)]
    transfers: Vec<PmTransfer>,
}

#[derive(Deserialize)]
struct PmTransfer {
    id: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    folder_id: Option<String>,
    #[serde(default)]
    file_id: Option<String>,
    #[serde(default)]
    src: Option<String>,
}

#[derive(Deserialize)]
struct PmFolder {
    #[serde(default)]
    content: Vec<PmItem>,
}

#[derive(Deserialize)]
struct PmItem {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default, rename = "type")]
    kind: String,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    link: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::super::testutil::{ReplayTransport, Route};
    use super::super::{HttpBody, HttpMethod};
    use super::*;

    const KEY: &str = "pm-test-key";
    const CACHED: &str = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c";
    const ABSENT: &str = "bbbb5555ecdc7ca55fb0bbf81323d87062db1f6d";

    fn store(routes: Vec<Route>) -> (Arc<ReplayTransport>, PremiumizeStore) {
        let transport = Arc::new(ReplayTransport::new(routes));
        let store = PremiumizeStore::new(Arc::clone(&transport) as Arc<dyn DebridTransport>, KEY);
        (transport, store)
    }

    #[test]
    fn get_user_reads_premium_until_and_keys_via_the_query_secret() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/account/info",
            200,
            include_str!("../../fixtures/debrid/premiumize/account_info.json"),
        )]);
        let user = store.get_user().expect("user");
        assert_eq!(user.id, "123456789");
        assert!(user.premium);
        assert_eq!(user.expiration, Some(1_788_220_800));
        let calls = transport.calls();
        // The key rides the query-secret channel, never the URL itself.
        assert!(!calls[0].url.contains(KEY));
        assert_eq!(
            calls[0].query_secret,
            Some(("apikey".to_string(), KEY.to_string()))
        );
    }

    #[test]
    fn check_magnets_zips_the_boolean_answers_in_input_order() {
        let (transport, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/cache/check",
            200,
            include_str!("../../fixtures/debrid/premiumize/cache_check.json"),
        )]);
        let out = store
            .check_magnets(&[CACHED.to_string(), ABSENT.to_string()])
            .expect("check");
        assert_eq!(out[0], (CACHED.to_string(), MagnetStatus::Cached));
        assert!(out[0].1.is_ready());
        assert_eq!(out[1], (ABSENT.to_string(), MagnetStatus::Unknown));
        let calls = transport.calls();
        assert!(matches!(
            &calls[0].body,
            HttpBody::Form(fields)
                if fields
                    == &[
                        ("items[]".to_string(), CACHED.to_string()),
                        ("items[]".to_string(), ABSENT.to_string()),
                    ]
        ));
    }

    #[test]
    fn check_magnets_rejects_a_count_mismatch_instead_of_misclassifying() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/cache/check",
            200,
            include_str!("../../fixtures/debrid/premiumize/cache_check.json"),
        )]);
        // Three asked, the recording answers two: refuse to guess.
        let result = store.check_magnets(&[
            CACHED.to_string(),
            ABSENT.to_string(),
            "cccc5555ecdc7ca55fb0bbf81323d87062db1f6d".to_string(),
        ]);
        assert!(matches!(result, Err(DebridError::Other(_))));
    }

    #[test]
    fn add_magnet_creates_a_transfer_and_parses_the_infohash_from_the_magnet() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/transfer/create",
            200,
            include_str!("../../fixtures/debrid/premiumize/transfer_create.json"),
        )]);
        let added = store
            .add_magnet(&format!("magnet:?xt=urn:btih:{CACHED}&dn=Show"))
            .expect("add");
        assert_eq!(added.id, "pmtransfer01");
        assert_eq!(added.infohash, CACHED);
    }

    #[test]
    fn add_magnet_without_a_btih_is_refused_up_front() {
        let (transport, store) = store(Vec::new());
        assert!(matches!(
            store.add_magnet("magnet:?dn=NoHashHere"),
            Err(DebridError::Other(_))
        ));
        // Refused before any wire call.
        assert!(transport.calls().is_empty());
    }

    #[test]
    fn get_magnet_walks_the_folder_tree_into_direct_links() {
        let (_, store) = store(vec![
            Route::new(
                HttpMethod::Get,
                "/transfer/list",
                200,
                include_str!("../../fixtures/debrid/premiumize/transfer_list.json"),
            ),
            Route::new(
                HttpMethod::Get,
                "/folder/list?id=pmfolder01",
                200,
                include_str!("../../fixtures/debrid/premiumize/folder_list.json"),
            ),
            Route::new(
                HttpMethod::Get,
                "/folder/list?id=pmsub01",
                200,
                include_str!("../../fixtures/debrid/premiumize/folder_list_subs.json"),
            ),
        ]);
        let info = store.get_magnet("pmtransfer01").expect("magnet");
        assert_eq!(info.status, MagnetStatus::Downloaded);
        assert_eq!(info.infohash, CACHED);
        assert_eq!(info.files.len(), 2);
        assert_eq!(info.files[0].path, "Show.S01E01.2160p.WEB-DL.mkv");
        assert_eq!(
            info.files[0].link.as_deref(),
            Some("https://blizzard.pm-cdn.example/dl/pmfile01/Show.S01E01.2160p.WEB-DL.mkv")
        );
        assert_eq!(info.files[1].path, "Subs/eng.srt");
        assert_eq!(info.files[1].idx, 1);
    }

    #[test]
    fn get_magnet_reports_a_running_transfer_without_files() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/transfer/list",
            200,
            include_str!("../../fixtures/debrid/premiumize/transfer_list.json"),
        )]);
        let info = store.get_magnet("pmtransfer02").expect("magnet");
        assert_eq!(info.status, MagnetStatus::Downloading);
        assert!(info.files.is_empty());
        assert_eq!(info.infohash, "aaaa5555ecdc7ca55fb0bbf81323d87062db1f6d");
    }

    #[test]
    fn get_magnet_for_an_unknown_id_is_not_found() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/transfer/list",
            200,
            include_str!("../../fixtures/debrid/premiumize/transfer_list.json"),
        )]);
        assert_eq!(store.get_magnet("nosuch"), Err(DebridError::NotFound));
    }

    #[test]
    fn generate_link_passes_direct_links_through_and_rejects_the_rest() {
        let (_, store) = store(Vec::new());
        assert_eq!(
            store
                .generate_link("https://blizzard.pm-cdn.example/dl/pmfile01/x.mkv")
                .expect("direct"),
            "https://blizzard.pm-cdn.example/dl/pmfile01/x.mkv"
        );
        assert!(matches!(
            store.generate_link("pmfile01"),
            Err(DebridError::Other(_))
        ));
    }

    #[test]
    fn remove_magnet_accepts_the_bare_success_envelope() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Post,
            "/transfer/delete",
            200,
            include_str!("../../fixtures/debrid/premiumize/transfer_delete.json"),
        )]);
        store.remove_magnet("pmtransfer01").expect("delete");
    }

    #[test]
    fn the_recorded_auth_error_on_http_200_maps_to_unauthorized() {
        let (_, store) = store(vec![Route::new(
            HttpMethod::Get,
            "/account/info",
            200,
            include_str!("../../fixtures/debrid/premiumize/error_auth.json"),
        )]);
        assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    }
}
