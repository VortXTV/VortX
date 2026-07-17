//! Cached-availability check from the typed `behaviorHints.vortx.cachedServices` side-channel. The hive
//! cache plane federates a BOOLEAN ("this infohash is cached on service X"), never a token: the engine
//! treats a stream as instant-cached on the services the USER actually has, floats it to the top of its
//! resolution tier in ranking, and the user's OWN debrid re-confirms on play (facts, not tokens). This
//! builds the `cached` vector `vortx_ranking::rank` consumes.
//!
//! The cached-service tokens are wire strings byte-frozen to the [`DebridService`] enum, so the match is the
//! same on every platform (iOS, Android, the Cloudflare Worker), which is what keeps cached-aware ranking
//! byte-reproducible.

use vortx_hive::DebridService;
use vortx_protocol::Stream;

/// Whether a stream cached on `stream_cached_services` (wire strings from `behaviorHints.vortx`) is cached on
/// any service the user has enabled (`user_wire` = debrid wire strings). Case-insensitive; an empty list on
/// either side yields `false` (not cached).
pub fn cached_on(stream_cached_services: &[String], user_wire: &[&str]) -> bool {
    stream_cached_services
        .iter()
        .any(|svc| user_wire.iter().any(|u| svc.as_str().eq_ignore_ascii_case(u)))
}

/// The cached-availability flag for one stream against the user's enabled debrid services. Reads the typed
/// `vortx.cachedServices`; a plain stream (no vortx object) is never treated as cached (it must resolve live).
pub fn stream_is_cached(stream: &Stream, user_services: &[DebridService]) -> bool {
    let Some(cached) = stream
        .behavior_hints
        .as_ref()
        .and_then(|h| h.vortx.as_ref())
        .map(|v| v.cached_services.as_slice())
    else {
        return false;
    };
    let user_wire: Vec<&str> = user_services.iter().map(|s| s.as_wire()).collect();
    cached_on(cached, &user_wire)
}

/// The cached vector for a stream list against the user's services, in order. Feed this as
/// `vortx_ranking::rank`'s `cached` argument so a hive-cached stream floats to the top of its resolution
/// tier (facts, not tokens). Length-stable: one bool per input stream.
pub fn cached_vector(streams: &[Stream], user_services: &[DebridService]) -> Vec<bool> {
    streams
        .iter()
        .map(|s| stream_is_cached(s, user_services))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_protocol::{StreamBehaviorHints, VortxStreamHints};

    fn cached_stream(services: &[&str]) -> Stream {
        Stream {
            name: Some("x".to_string()),
            behavior_hints: Some(StreamBehaviorHints {
                vortx: Some(VortxStreamHints {
                    cached_services: services.iter().map(|s| s.to_string()).collect(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn matches_a_user_service_case_insensitively() {
        let user = [DebridService::RealDebrid, DebridService::TorBox];
        assert!(stream_is_cached(&cached_stream(&["realdebrid"]), &user));
        assert!(stream_is_cached(&cached_stream(&["RealDebrid"]), &user)); // case-insensitive
        assert!(stream_is_cached(&cached_stream(&["premiumize", "torbox"]), &user)); // any-match
        assert!(!stream_is_cached(&cached_stream(&["alldebrid"]), &user)); // not a user service
        assert!(!stream_is_cached(&cached_stream(&[]), &user)); // empty
    }

    #[test]
    fn a_plain_stream_is_never_cached() {
        let user = [DebridService::RealDebrid];
        let plain = Stream {
            name: Some("plain".into()),
            ..Default::default()
        };
        assert!(!stream_is_cached(&plain, &user));
    }

    #[test]
    fn no_user_services_means_never_cached() {
        assert!(!stream_is_cached(&cached_stream(&["realdebrid"]), &[]));
    }

    #[test]
    fn cached_vector_is_length_stable_and_ordered() {
        let user = [DebridService::TorBox];
        let streams = [
            cached_stream(&["torbox"]),
            cached_stream(&["realdebrid"]),
            Stream::default(),
        ];
        assert_eq!(cached_vector(&streams, &user), vec![true, false, false]);
    }
}
