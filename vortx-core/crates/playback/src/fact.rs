//! Signed playback-asset availability facts and their CRDT merge. An [`AssetFact`] is a node's signed
//! claim "the trickplay/skip/chapters asset for title X is (or is NOT) available, with content digest D".
//! A direct sibling of [`vortx_hive::CacheFact`]: it signs a fixed canonical byte string (never serialized
//! JSON) under its own domain prefix, merges by the same LWW+TTL total-order CRDT, and is gated by the
//! same [`vortx_hive::TrustStore`]. It carries only a public title key plus a content digest: no tokens,
//! no account ids, no library contents.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use vortx_hive::hive_constants::{ASSETFACT_PREFIX, MAX_CLOCK_SKEW_SECS, PUBLIC_TTL_CAP_SECS};
use vortx_hive::{verify, HiveError, NodeIdentity};

use crate::model::{AssetKind, MediaKey};
use crate::PlaybackError;

/// A signed claim that a `(MediaKey, AssetKind)` asset is (or is not) available, identified by `digest`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssetFact {
    #[serde(rename = "v")]
    pub version: u8,
    /// The [`MediaKey`], flattened for signing.
    pub media_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    pub kind: AssetKind,
    /// The claim. `false` is a signed negative ("I checked, no asset"), not a deletion.
    pub available: bool,
    /// Content hash of the asset payload (sprite sheet / marker set). May be empty for a negative.
    pub digest: String,
    pub verified_at: u64,
    pub ttl: u64,
    pub signer_pubkey: String,
    pub sig: String,
}

/// The merge key: a fact is about exactly one `(media_id, season, episode, kind)`. Absent season/episode
/// are `-1` sentinels so a series-episode claim never collides with a movie/whole-title claim.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AssetKey {
    pub media_id: String,
    pub season: i64,
    pub episode: i64,
    pub kind: AssetKind,
}

/// The merged hive asset map: the single latest fact per [`AssetKey`].
pub type HiveAssetMap = HashMap<AssetKey, AssetFact>;

/// Build the exact bytes an `AssetFact` signature covers:
///
/// ```text
/// b"vortx-assetfact-v1\n" + media_id|season(-1 if none)|episode(-1 if none)|kind|
///                           available(1/0)|digest|verified_at|ttl|signer_pubkey
/// ```
///
/// Integers are decimal with no padding; absent season/episode are `-1`. The cross-platform interop
/// anchor: any client building these bytes the same way produces the same signature.
#[allow(clippy::too_many_arguments)]
pub fn asset_signing_bytes_for(
    media_id: &str,
    season: Option<u32>,
    episode: Option<u32>,
    kind: AssetKind,
    available: bool,
    digest: &str,
    verified_at: u64,
    ttl: u64,
    signer_pubkey: &str,
) -> Vec<u8> {
    let canonical = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}",
        media_id,
        season
            .map(|x| x.to_string())
            .unwrap_or_else(|| "-1".to_string()),
        episode
            .map(|x| x.to_string())
            .unwrap_or_else(|| "-1".to_string()),
        kind.as_wire(),
        if available { "1" } else { "0" },
        digest,
        verified_at,
        ttl,
        signer_pubkey,
    );
    let mut out = Vec::with_capacity(ASSETFACT_PREFIX.len() + canonical.len());
    out.extend_from_slice(ASSETFACT_PREFIX);
    out.extend_from_slice(canonical.as_bytes());
    out
}

/// `media_id` rides the canonical signing payload, so it must be non-empty and free of `|`/control chars
/// (which would shift downstream fields and let two distinct facts collide on one signing string).
fn validate_media_id(media_id: &str) -> Result<(), PlaybackError> {
    if media_id.is_empty() || media_id.chars().any(|c| c == '|' || c.is_control()) {
        Err(PlaybackError::MalformedMediaId)
    } else {
        Ok(())
    }
}

/// `digest` also rides mid-payload, so the same delimiter/control ban applies; it is length-capped. Empty
/// is allowed (a negative fact need carry no digest).
fn validate_digest(digest: &str) -> Result<(), PlaybackError> {
    if digest.chars().count() > 128 || digest.chars().any(|c| c == '|' || c.is_control()) {
        Err(PlaybackError::MalformedDigest)
    } else {
        Ok(())
    }
}

impl AssetFact {
    /// Construct and sign a fact with `identity`. Validates the media id and digest; the signature covers
    /// the canonical bytes, never the serialized JSON.
    pub fn create(
        identity: &NodeIdentity,
        media_key: &MediaKey,
        kind: AssetKind,
        available: bool,
        digest: impl Into<String>,
        verified_at: u64,
        ttl: u64,
    ) -> Result<Self, PlaybackError> {
        validate_media_id(&media_key.meta_id)?;
        let digest = digest.into();
        validate_digest(&digest)?;
        let signer_pubkey = identity.public_b64url();
        let bytes = asset_signing_bytes_for(
            &media_key.meta_id,
            media_key.season,
            media_key.episode,
            kind,
            available,
            &digest,
            verified_at,
            ttl,
            &signer_pubkey,
        );
        let sig = identity.sign(&bytes);
        Ok(Self {
            version: 1,
            media_id: media_key.meta_id.clone(),
            season: media_key.season,
            episode: media_key.episode,
            kind,
            available,
            digest,
            verified_at,
            ttl,
            signer_pubkey,
            sig,
        })
    }

    /// The canonical bytes this fact's signature must cover.
    pub fn signing_bytes(&self) -> Vec<u8> {
        asset_signing_bytes_for(
            &self.media_id,
            self.season,
            self.episode,
            self.kind,
            self.available,
            &self.digest,
            self.verified_at,
            self.ttl,
            &self.signer_pubkey,
        )
    }

    /// Verify the fact's ed25519 signature against its own `signer_pubkey`.
    pub fn verify_signed(&self) -> Result<(), HiveError> {
        verify(&self.signer_pubkey, &self.signing_bytes(), &self.sig)
    }

    /// Whether the fact is past its effective expiry at `now`. The lifetime is capped at
    /// `PUBLIC_TTL_CAP_SECS`, so no signer can mint an immortal fact with a huge `ttl`; a live fact must be
    /// re-propagated within the cap, which ages out poisoned/stale claims.
    pub fn is_expired(&self, now: u64) -> bool {
        let effective_ttl = self.ttl.min(PUBLIC_TTL_CAP_SECS);
        self.verified_at.saturating_add(effective_ttl) < now
    }

    /// The merge key for this fact.
    pub fn key(&self) -> AssetKey {
        AssetKey {
            media_id: self.media_id.clone(),
            season: self.season.map(i64::from).unwrap_or(-1),
            episode: self.episode.map(i64::from).unwrap_or(-1),
            kind: self.kind,
        }
    }
}

/// Merge one incoming fact into the map (the state-based delta-CRDT step). Returns `true` if it updated
/// the map. Drops (no state change) a fact that fails signature verification, is dated beyond the
/// clock-skew guard, or has already expired. State rule: a strict total order on
/// `(verified_at, signer_pubkey, sig)`, newest wins, ties break deterministically. Because that is a TOTAL
/// order, the merge is commutative, associative, and idempotent, converging regardless of gossip order or
/// duplicates.
pub fn merge_asset_fact(map: &mut HiveAssetMap, incoming: AssetFact, now: u64) -> bool {
    if incoming.verify_signed().is_err() {
        return false;
    }
    if incoming.verified_at > now.saturating_add(MAX_CLOCK_SKEW_SECS) {
        return false;
    }
    if incoming.is_expired(now) {
        return false;
    }
    let key = incoming.key();
    match map.get(&key) {
        None => {
            map.insert(key, incoming);
            true
        }
        Some(cur) => {
            let wins = (
                incoming.verified_at,
                incoming.signer_pubkey.as_str(),
                incoming.sig.as_str(),
            ) > (
                cur.verified_at,
                cur.signer_pubkey.as_str(),
                cur.sig.as_str(),
            );
            if wins {
                map.insert(key, incoming);
                true
            } else {
                false
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> MediaKey {
        MediaKey::episode("tt0903747", 1, 1)
    }

    fn fact(id: &NodeIdentity, available: bool, verified_at: u64) -> AssetFact {
        AssetFact::create(
            id,
            &key(),
            AssetKind::SkipMarkers,
            available,
            "sha256-deadbeef",
            verified_at,
            86_400,
        )
        .unwrap()
    }

    #[test]
    fn asset_canonical_bytes_are_frozen() {
        let bytes = asset_signing_bytes_for(
            "tt0903747",
            Some(1),
            Some(1),
            AssetKind::SkipMarkers,
            true,
            "sha256-deadbeef",
            1_718_900_000,
            86_400,
            "PUBKEY",
        );
        let expected =
            b"vortx-assetfact-v1\ntt0903747|1|1|skip_markers|1|sha256-deadbeef|1718900000|86400|PUBKEY";
        assert_eq!(bytes, expected);
    }

    #[test]
    fn asset_canonical_bytes_use_sentinels_for_absent_season_episode() {
        let bytes = asset_signing_bytes_for(
            "tt1375666",
            None,
            None,
            AssetKind::Trickplay,
            false,
            "",
            10,
            20,
            "K",
        );
        let expected = b"vortx-assetfact-v1\ntt1375666|-1|-1|trickplay|0||10|20|K";
        assert_eq!(bytes, expected);
    }

    #[test]
    fn sign_then_verify_asset_fact() {
        let id = NodeIdentity::generate().unwrap();
        assert!(fact(&id, true, 1000).verify_signed().is_ok());
    }

    #[test]
    fn tampered_asset_fact_fails_verify() {
        let id = NodeIdentity::generate().unwrap();
        let mut f = fact(&id, true, 1000);
        f.available = false;
        assert!(f.verify_signed().is_err());
    }

    #[test]
    fn digest_with_delimiter_is_rejected() {
        let id = NodeIdentity::generate().unwrap();
        let r = AssetFact::create(
            &id,
            &key(),
            AssetKind::Trickplay,
            true,
            "good|evil",
            1000,
            100,
        );
        assert!(matches!(r, Err(PlaybackError::MalformedDigest)));
    }

    #[test]
    fn empty_media_id_is_rejected() {
        let id = NodeIdentity::generate().unwrap();
        let r = AssetFact::create(
            &id,
            &MediaKey::movie(""),
            AssetKind::Chapters,
            true,
            "d",
            1,
            1,
        );
        assert!(matches!(r, Err(PlaybackError::MalformedMediaId)));
    }

    #[test]
    fn expired_asset_fact_is_ignored_on_merge() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveAssetMap::new();
        assert!(!merge_asset_fact(&mut map, fact(&id, true, 1000), 200_000));
        assert!(map.is_empty());
    }

    #[test]
    fn future_fact_beyond_skew_is_dropped() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveAssetMap::new();
        assert!(!merge_asset_fact(
            &mut map,
            fact(&id, true, 1_000_000),
            1000
        ));
        assert!(map.is_empty());
    }

    #[test]
    fn negative_supersedes_stale_positive() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveAssetMap::new();
        let now = 5000;
        merge_asset_fact(&mut map, fact(&id, false, 3000), now);
        assert!(!merge_asset_fact(&mut map, fact(&id, true, 1000), now));
        assert!(!map.values().next().unwrap().available);
    }

    #[test]
    fn merge_is_idempotent() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveAssetMap::new();
        let f = fact(&id, true, 1000);
        assert!(merge_asset_fact(&mut map, f.clone(), 5000));
        assert!(!merge_asset_fact(&mut map, f, 5000));
        assert_eq!(map.len(), 1);
    }

    #[test]
    fn merge_is_commutative_for_same_key() {
        let id = NodeIdentity::generate().unwrap();
        let now = 5000;
        let older = fact(&id, true, 1000);
        let newer = fact(&id, false, 2000);

        let mut a = HiveAssetMap::new();
        merge_asset_fact(&mut a, older.clone(), now);
        merge_asset_fact(&mut a, newer.clone(), now);

        let mut b = HiveAssetMap::new();
        merge_asset_fact(&mut b, newer, now);
        merge_asset_fact(&mut b, older, now);

        assert_eq!(a, b);
    }

    #[test]
    fn kinds_do_not_collide_on_one_title() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveAssetMap::new();
        let now = 5000;
        let skip = AssetFact::create(&id, &key(), AssetKind::SkipMarkers, true, "a", 1000, 86_400)
            .unwrap();
        let chap =
            AssetFact::create(&id, &key(), AssetKind::Chapters, true, "b", 1000, 86_400).unwrap();
        assert!(merge_asset_fact(&mut map, skip, now));
        assert!(merge_asset_fact(&mut map, chap, now));
        assert_eq!(map.len(), 2);
    }

    #[test]
    fn huge_ttl_is_capped_not_immortal() {
        let id = NodeIdentity::generate().unwrap();
        let f = AssetFact::create(&id, &key(), AssetKind::Trickplay, true, "d", 1000, u64::MAX)
            .unwrap();
        assert!(f.is_expired(1000 + PUBLIC_TTL_CAP_SECS + 1));
    }
}
