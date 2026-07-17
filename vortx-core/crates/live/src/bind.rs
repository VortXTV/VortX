//! LT-BIND: reconcile LT3 channel identity to the LT2 EPG corpus.
//!
//! An LT3 [`ChannelModel`] is keyed by `channel_id` = `t:<tvg-id>` | `c:<hash>` | `u:<hash>`, but LT2
//! [`Program`](crate::Program)s key off the RAW XMLTV channel id (e.g. `cnn.us`). To fetch a channel's
//! now/next + grid (LT4 [`crate::now_next`] / [`crate::grid`]) the two must be reconciled. [`bind_epg`]
//! resolves each channel to its EPG channel id with a fallback chain that NEVER mis-binds:
//!   1. tvg-id exact (the `t:<tvg-id>` recovered from the channel id, matched case-insensitively to an
//!      [`EpgChannel::id`]),
//!   2. else the channel's normalized display name matched to an EPG channel's normalized display name,
//!   3. else `None` (the channel simply has no EPG; never a wrong guess).
//!
//! Pure + deterministic + order-independent: it reuses the EXACT LT3 `norm_tvg` / `normalize_name`, so the
//! transform that produced `t:cnn.us` is the one used to match, and on duplicate EPG entries it picks the
//! lexicographically smallest id rather than input order.

use std::collections::BTreeMap;

use crate::channel::{norm_tvg, normalize_name};
use crate::epg::EpgChannel;
use crate::ChannelModel;

/// Recover the normalized tvg-id from a channel id, if it carries one (`t:<tvg-id>`); else `None`.
fn tvg_of(channel_id: &str) -> Option<&str> {
    channel_id.strip_prefix("t:")
}

/// The EPG channel id (raw XMLTV id, as [`crate::Program::channel_id`] uses) that `channel` binds to, via the
/// fallback chain in the module docs. Returns the matched [`EpgChannel::id`], or `None` when nothing matches.
pub fn epg_channel_id_for(channel: &ChannelModel, epg_channels: &[EpgChannel]) -> Option<String> {
    // 1. tvg-id exact: the channel id already carries the LT3-normalized tvg, so normalize each EPG id the
    //    same way and compare. Among matches pick the smallest raw id (order-independent on bad data).
    if let Some(tvg) = tvg_of(&channel.channel_id) {
        if let Some(id) = epg_channels
            .iter()
            .filter(|e| norm_tvg(Some(&e.id)).as_deref() == Some(tvg))
            .map(|e| e.id.clone())
            .min()
        {
            return Some(id);
        }
    }

    // 2. normalized display-name fallback: match the channel's display name against any EPG display name. An
    //    empty normalized name never matches (so blank / symbol-only names cannot collide).
    let want = normalize_name(&channel.display_name);
    if !want.is_empty() {
        if let Some(id) = epg_channels
            .iter()
            .filter(|e| e.display_names.iter().any(|d| normalize_name(d) == want))
            .map(|e| e.id.clone())
            .min()
        {
            return Some(id);
        }
    }

    // 3. no match: the channel has no EPG.
    None
}

/// Bind every channel that has an EPG match: a deterministic map from `ChannelModel.channel_id` to its EPG
/// channel id. Channels with no match are omitted (the host treats them as having no programmes).
pub fn bind_epg(
    channels: &[ChannelModel],
    epg_channels: &[EpgChannel],
) -> BTreeMap<String, String> {
    channels
        .iter()
        .filter_map(|c| {
            epg_channel_id_for(c, epg_channels).map(|epg_id| (c.channel_id.clone(), epg_id))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{build_channels, M3uEntry, ProviderPlaylist};

    fn epg(id: &str, names: &[&str]) -> EpgChannel {
        EpgChannel {
            id: id.to_string(),
            display_names: names.iter().map(|n| n.to_string()).collect(),
            icon: None,
        }
    }

    fn channel_with_tvg(tvg: &str, name: &str) -> ChannelModel {
        let p = ProviderPlaylist {
            provider: "a".into(),
            entries: vec![M3uEntry {
                url: "http://x".into(),
                duration_secs: -1,
                tvg_id: Some(tvg.to_string()),
                display_name: name.to_string(),
                ..Default::default()
            }],
        };
        build_channels(&[p]).pop().unwrap()
    }

    fn channel_name_only(name: &str) -> ChannelModel {
        let p = ProviderPlaylist {
            provider: "a".into(),
            entries: vec![M3uEntry {
                url: "http://x".into(),
                duration_secs: -1,
                display_name: name.to_string(),
                ..Default::default()
            }],
        };
        build_channels(&[p]).pop().unwrap()
    }

    #[test]
    fn tvg_id_binds_case_insensitively() {
        let ch = channel_with_tvg("CNN.us", "CNN HD"); // channel_id becomes t:cnn.us
        assert_eq!(ch.channel_id, "t:cnn.us");
        let epgs = [epg("CNN.us", &["CNN"]), epg("bbc.uk", &["BBC"])];
        assert_eq!(epg_channel_id_for(&ch, &epgs), Some("CNN.us".to_string())); // raw EPG id returned
    }

    #[test]
    fn name_only_channel_binds_by_normalized_display_name() {
        let ch = channel_name_only("CNN HD"); // no tvg -> c:<hash> id
        assert!(ch.channel_id.starts_with("c:"));
        let epgs = [epg("cnn.us", &["CNN HD"])];
        assert_eq!(epg_channel_id_for(&ch, &epgs), Some("cnn.us".to_string()));
    }

    #[test]
    fn a_tvg_channel_falls_back_to_name_when_the_tvg_has_no_epg() {
        let ch = channel_with_tvg("cnn.us", "CNN");
        let epgs = [epg("other.id", &["CNN"])]; // tvg cnn.us not present, but the name matches
        assert_eq!(epg_channel_id_for(&ch, &epgs), Some("other.id".to_string()));
    }

    #[test]
    fn no_match_is_none_never_a_wrong_binding() {
        let ch = channel_with_tvg("cnn.us", "CNN");
        let epgs = [epg("espn.us", &["ESPN"])];
        assert_eq!(epg_channel_id_for(&ch, &epgs), None);
    }

    #[test]
    fn an_empty_display_name_does_not_match() {
        let ch = channel_name_only("***"); // normalizes to empty
        let epgs = [epg("x", &["!!!"])]; // also normalizes to empty
        assert_eq!(epg_channel_id_for(&ch, &epgs), None);
    }

    #[test]
    fn bind_epg_maps_only_matched_channels() {
        let a = channel_with_tvg("cnn.us", "CNN");
        let b = channel_with_tvg("zzz.none", "Nope");
        let epgs = [epg("cnn.us", &["CNN"])];
        let map = bind_epg(&[a, b], &epgs);
        assert_eq!(map.len(), 1);
        assert_eq!(map.get("t:cnn.us"), Some(&"cnn.us".to_string()));
    }

    #[test]
    fn duplicate_epg_ids_bind_to_the_smallest_deterministically() {
        let ch = channel_with_tvg("cnn.us", "CNN");
        // Two EPG entries normalize to the same tvg; pick the lexicographically smallest raw id.
        let epgs = [epg("CNN.US", &["CNN"]), epg("cnn.us", &["CNN"])];
        assert_eq!(epg_channel_id_for(&ch, &epgs), Some("CNN.US".to_string())); // "CNN.US" < "cnn.us"
    }
}
