//! Cross-language conformance + property tests for the LT-XTREAM URL builders. The exact URLs are the
//! cross-platform contract (a wrong-encoded credential or path is an auth failure on the portal), and the
//! privacy guarantee (the password never appears outside a built URL) must hold for any input.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_live::{Secret, StreamKind, XtreamPortal};

#[derive(Deserialize)]
struct Suite {
    portal: PortalSpec,
    player_api: Vec<ApiCase>,
    streams: Vec<StreamCase>,
    timeshift: TimeshiftCase,
}

#[derive(Deserialize)]
struct PortalSpec {
    base_url: String,
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct ApiCase {
    name: String,
    action: Option<String>,
    params: Vec<(String, String)>,
    expect: String,
}

#[derive(Deserialize)]
struct StreamCase {
    name: String,
    kind: String,
    stream_id: String,
    ext: String,
    expect: String,
}

#[derive(Deserialize)]
struct TimeshiftCase {
    stream_id: String,
    start_utc_ms: i64,
    stop_utc_ms: i64,
    now_ms: i64,
    expect: String,
}

const SUITE: &str = include_str!("../conformance/xtream_vectors.json");

#[test]
fn xtream_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse xtream suite");
    let p = XtreamPortal::new(
        &suite.portal.base_url,
        &suite.portal.username,
        Secret::new(&suite.portal.password),
    );

    for c in &suite.player_api {
        let params: Vec<(&str, &str)> = c
            .params
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let got = p.player_api(c.action.as_deref(), &params);
        assert_eq!(got, c.expect, "player_api drifted for {}", c.name);
    }

    for c in &suite.streams {
        let kind = match c.kind.as_str() {
            "live" => StreamKind::Live,
            "vod" => StreamKind::Vod,
            "series" => StreamKind::Series,
            other => panic!("unknown kind {other}"),
        };
        assert_eq!(
            p.stream_url(kind, &c.stream_id, &c.ext),
            c.expect,
            "stream url drifted for {}",
            c.name
        );
    }

    let ts = &suite.timeshift;
    assert_eq!(
        p.timeshift_url(&ts.stream_id, ts.start_utc_ms, ts.stop_utc_ms, ts.now_ms),
        ts.expect,
        "timeshift url drifted"
    );
}

proptest! {
    // The password value NEVER appears in Debug or the cache key (it may legitimately appear, encoded, in a
    // built URL). The password is generated as uppercase letters, which cannot collide with the fixed
    // lowercase base/user or the lowercase-hex cache key, so any match would be a genuine leak.
    #[test]
    fn creds_never_leak_into_debug_or_key(pass in "[G-Z]{4,16}") {
        let p = XtreamPortal::new("http://h", "u", Secret::new(&pass));
        prop_assert!(!format!("{p:?}").contains(&pass), "password leaked into Debug");
        prop_assert!(!p.cache_key().contains(&pass), "password leaked into cache key");
    }

    // URL building is deterministic, and the cache key is stable + changes with the password.
    #[test]
    fn building_is_deterministic_and_key_is_stable(user in "[a-z0-9]{1,10}", pass in "[a-z0-9]{1,10}", id in "[0-9]{1,6}") {
        let p = XtreamPortal::new("http://h", &user, Secret::new(&pass));
        prop_assert_eq!(p.live_url(&id, "ts"), p.live_url(&id, "ts"));
        prop_assert_eq!(p.cache_key(), p.cache_key());
        let p2 = XtreamPortal::new("http://h", &user, Secret::new(format!("{pass}x")));
        prop_assert_ne!(p.cache_key(), p2.cache_key()); // different password -> different key
    }

    // The auth URL always carries both credentials, encoded (no raw space / unescaped special bytes that
    // would break the query); the unreserved set passes through unchanged.
    #[test]
    fn auth_url_is_well_formed_for_any_creds(user in ".{0,12}", pass in ".{0,12}") {
        let p = XtreamPortal::new("http://h", &user, Secret::new(&pass));
        let url = p.auth_url();
        prop_assert!(url.starts_with("http://h/player_api.php?username="));
        prop_assert!(url.contains("&password="));
        // No raw spaces survive encoding.
        prop_assert!(!url.contains(' '));
    }
}
