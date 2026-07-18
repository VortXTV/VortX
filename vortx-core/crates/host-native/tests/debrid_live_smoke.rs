//! LIVE wire-shape smoke for the debrid stores: hit each real API with a throwaway invalid token
//! and assert the recorded auth-error contract holds (a 401/403/error-envelope mapping to
//! `Unauthorized` proves the request reached the right endpoint in the right shape).
//!
//! All `#[ignore]`: CI stays hermetic on the fixture replays; run explicitly with
//! `cargo test --test debrid_live_smoke -- --ignored` from a network-connected dev box.

use std::sync::Arc;

use vortx_debrid::{DebridError, DebridStore};
use vortx_host_native::debrid::{
    AllDebridStore, DebridHttp, DebridTransport, PremiumizeStore, RealDebridStore, TorBoxStore,
};

/// Deliberately invalid: proves the wire shape, never authenticates.
const SMOKE_TOKEN: &str = "vortx-invalid-live-smoke-token";

fn transport() -> Arc<dyn DebridTransport> {
    Arc::new(DebridHttp::new().expect("live transport"))
}

#[test]
#[ignore = "network: live wire-shape smoke against api.real-debrid.com"]
fn realdebrid_rejects_the_invalid_token_in_the_recorded_shape() {
    let store = RealDebridStore::new(transport(), SMOKE_TOKEN);
    assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    assert_eq!(
        store.check_magnets(&["dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c".to_string()]),
        Err(DebridError::Unauthorized)
    );
}

#[test]
#[ignore = "network: live wire-shape smoke against api.alldebrid.com"]
fn alldebrid_rejects_the_invalid_token_in_the_recorded_shape() {
    let store = AllDebridStore::new(transport(), SMOKE_TOKEN);
    // AllDebrid answers HTTP 200 with the AUTH_BAD_APIKEY envelope; the mapping must still land
    // on Unauthorized (the recorded contract).
    assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    assert_eq!(
        store.check_magnets(&["dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c".to_string()]),
        Err(DebridError::Unauthorized)
    );
}

#[test]
#[ignore = "network: live wire-shape smoke against api.torbox.app"]
fn torbox_rejects_the_invalid_token_in_the_recorded_shape() {
    let store = TorBoxStore::new(transport(), SMOKE_TOKEN);
    // TorBox answers 403 BAD_TOKEN for a present-but-invalid bearer.
    assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    assert_eq!(
        store.check_magnets(&["dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c".to_string()]),
        Err(DebridError::Unauthorized)
    );
    // requestdl carries the token as a query secret; an invalid token must map the same way.
    assert_eq!(
        store.generate_link("torbox://1/0"),
        Err(DebridError::Unauthorized)
    );
}

#[test]
#[ignore = "network: live wire-shape smoke against www.premiumize.me"]
fn premiumize_rejects_the_invalid_key_in_the_recorded_shape() {
    let store = PremiumizeStore::new(transport(), SMOKE_TOKEN);
    // Premiumize answers HTTP 200 with the authentication_failed envelope.
    assert_eq!(store.get_user(), Err(DebridError::Unauthorized));
    assert_eq!(
        store.check_magnets(&["dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c".to_string()]),
        Err(DebridError::Unauthorized)
    );
}
