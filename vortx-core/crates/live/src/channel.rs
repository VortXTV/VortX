//! LT3: canonical channel identity + cross-provider dedup.
//!
//! An IPTV user typically loads several overlapping provider playlists. The same logical channel ("CNN")
//! then appears many times under slightly different names, numbers, and stream URLs, and worse, the same
//! channel is a DIFFERENT identity in each provider's id space, so favorites, EPG binding, and resume break
//! when a provider rotates a URL. [`build_channels`] collapses N provider feeds into one [`ChannelModel`]
//! with a DETERMINISTIC, cross-device-stable [`ChannelModel::channel_id`] and a ranked list of alternate
//! feeds (failover order). This mirrors the cross-namespace title reconciliation in the source crate
//! (`identity::reconcile`): each feed asserts a SET of identity signals, connected-components (union-find)
//! over shared signals fuses feeds that belong together, and the canonical id is the deterministic minimum
//! signal of the component, so a feed tagged with a `tvg-id` in one provider still merges with a feed that
//! carries only a matching name in another. Pure, order-independent, float-free, panic-free.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::hash::fnv1a64;
use crate::m3u::M3uEntry;

/// One provider's parsed playlist, labeled with the id the host knows it by (the source/playlist id). Feed
/// ranking is by the order providers appear here, so the host expresses its source priority by ordering.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderPlaylist {
    pub provider: String,
    pub entries: Vec<M3uEntry>,
}

/// One playable feed for a channel: which provider it came from, the stream URL, and the playback hints the
/// host needs (EXTINF duration, injected HTTP headers, inputstream/DRM props).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelFeed {
    pub provider: String,
    pub url: String,
    /// EXTINF duration in whole seconds; `-1` for a live channel.
    pub duration_secs: i64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub headers: Vec<(String, String)>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub props: Vec<(String, String)>,
}

/// A canonical channel: one identity across every provider that carries it, plus its ranked feeds.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelModel {
    /// Deterministic, cross-device-stable identity. `t:<tvg-id>` when a tvg-id is known (the strongest
    /// signal), else `c:<hash>` of the normalized name+number, else `u:<hash>` of the stream URL.
    pub channel_id: String,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_number: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logo_url: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub languages: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    /// Distinct providers carrying this channel, sorted, for federation/provenance.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub source_provenance: Vec<String>,
    /// The playable feeds, ranked best-first: feed `[0]` is the survivor played by default, the rest are
    /// failover alternates. Ranking here is the host's provider order; `LiveChannelRanking` refines it later.
    pub feeds: Vec<ChannelFeed>,
    /// Conservative, advisory-only maturity tag (`adult`) when the name/group carries an explicit marker.
    /// Live gating is advisory (see the state crate), so a tag never hard-blocks; it informs the host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maturity_tag: Option<String>,
}

/// An identity signal a feed asserts. Ordered strongest-first (`Tvg` < `NameNumber` < `Url`), so the
/// deterministic minimum signal of a merged component selects the best available canonical id.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum ChannelKey {
    Tvg(String),
    NameNumber(String, Option<i64>),
    Url(String),
}

impl ChannelKey {
    /// The stable id string for this signal. tvg ids stay human-readable; name/url ids are opaque FNV-1a
    /// hex (fixed length, no leak of a long or sensitive name into the id).
    fn channel_id(&self) -> String {
        match self {
            ChannelKey::Tvg(t) => format!("t:{t}"),
            ChannelKey::NameNumber(name, num) => {
                let mut buf = name.clone().into_bytes();
                buf.push(0);
                if let Some(n) = num {
                    buf.extend_from_slice(n.to_string().as_bytes());
                }
                format!("c:{:016x}", fnv1a64(&buf))
            }
            ChannelKey::Url(u) => format!("u:{:016x}", fnv1a64(u.as_bytes())),
        }
    }
}

/// Everything needed to dedup one feed and later materialize it, with a stable order key.
struct FeedCtx {
    provider: String,
    provider_idx: usize,
    local_idx: usize,
    url: String,
    name: String,
    channel_number: Option<i64>,
    group: Option<String>,
    logo: Option<String>,
    languages: Vec<String>,
    country: Option<String>,
    maturity: Option<String>,
    duration_secs: i64,
    headers: Vec<(String, String)>,
    props: Vec<(String, String)>,
    signals: Vec<ChannelKey>,
}

/// Collapse provider playlists into canonical channels. Order-independent and deterministic: the output and
/// every `channel_id` are identical regardless of the order of providers or entries within them.
pub fn build_channels(providers: &[ProviderPlaylist]) -> Vec<ChannelModel> {
    let feeds: Vec<FeedCtx> = providers
        .iter()
        .enumerate()
        .flat_map(|(pi, p)| {
            p.entries
                .iter()
                .enumerate()
                .map(move |(li, e)| FeedCtx::from_entry(&p.provider, pi, li, e))
        })
        .collect();

    let n = feeds.len();
    let mut parent: Vec<usize> = (0..n).collect();

    // Link any two feeds that share an identity signal (transitive: tvg <-> name bridges providers).
    let mut first_seen: BTreeMap<ChannelKey, usize> = BTreeMap::new();
    for (i, f) in feeds.iter().enumerate() {
        for sig in &f.signals {
            match first_seen.get(sig) {
                Some(&j) => uf_union(&mut parent, i, j),
                None => {
                    first_seen.insert(sig.clone(), i);
                }
            }
        }
    }

    // Group feed indices by component root.
    let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for i in 0..n {
        let root = uf_find(&mut parent, i);
        groups.entry(root).or_default().push(i);
    }

    let mut out: Vec<ChannelModel> = groups
        .values()
        .map(|members| build_model(&feeds, members))
        .collect();
    out.sort_by(|a, b| a.channel_id.cmp(&b.channel_id));
    out
}

fn build_model(feeds: &[FeedCtx], members: &[usize]) -> ChannelModel {
    // Rank feeds deterministically by (provider order, entry order). Feed [0] is the survivor.
    let mut ranked: Vec<&FeedCtx> = members.iter().map(|&i| &feeds[i]).collect();
    ranked.sort_by_key(|f| (f.provider_idx, f.local_idx));

    // Canonical id: the deterministic minimum identity signal across the whole component.
    let id_key = members
        .iter()
        .flat_map(|&i| feeds[i].signals.iter())
        .min()
        .cloned()
        .unwrap_or_else(|| ChannelKey::Url(ranked[0].url.clone()));
    let channel_id = id_key.channel_id();

    let survivor = ranked[0];
    let channel_number = ranked.iter().find_map(|f| f.channel_number);
    let group = ranked.iter().find_map(|f| f.group.clone());
    let logo_url = ranked.iter().find_map(|f| f.logo.clone());
    let country = ranked.iter().find_map(|f| f.country.clone());
    let maturity_tag = ranked.iter().find_map(|f| f.maturity.clone());

    let languages: Vec<String> = ranked
        .iter()
        .flat_map(|f| f.languages.iter().cloned())
        .collect::<BTreeSet<String>>()
        .into_iter()
        .collect();
    let source_provenance: Vec<String> = ranked
        .iter()
        .map(|f| f.provider.clone())
        .collect::<BTreeSet<String>>()
        .into_iter()
        .collect();

    let feeds_out: Vec<ChannelFeed> = ranked
        .iter()
        .map(|f| ChannelFeed {
            provider: f.provider.clone(),
            url: f.url.clone(),
            duration_secs: f.duration_secs,
            headers: f.headers.clone(),
            props: f.props.clone(),
        })
        .collect();

    ChannelModel {
        channel_id,
        display_name: survivor.name.clone(),
        channel_number,
        group,
        logo_url,
        languages,
        country,
        source_provenance,
        feeds: feeds_out,
        maturity_tag,
    }
}

impl FeedCtx {
    fn from_entry(provider: &str, provider_idx: usize, local_idx: usize, e: &M3uEntry) -> FeedCtx {
        let name = if e
            .tvg_name
            .as_deref()
            .map(str::trim)
            .is_some_and(|s| !s.is_empty())
        {
            e.tvg_name.clone().unwrap_or_default()
        } else {
            e.display_name.clone()
        };
        let channel_number = attr(e, "tvg-chno").and_then(parse_chno);
        let languages = attr(e, "tvg-language").map(split_list).unwrap_or_default();
        let country = attr(e, "tvg-country")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let maturity = detect_maturity(&name, e.group_title.as_deref());

        // Assemble identity signals, strongest first. A feed with neither a tvg-id nor a name falls back to
        // its URL so two distinct anonymous feeds never collide on one id, yet identical URLs still merge.
        let mut signals = Vec::new();
        if let Some(tvg) = norm_tvg(e.tvg_id.as_deref()) {
            signals.push(ChannelKey::Tvg(tvg));
        }
        let norm_name = normalize_name(&name);
        if !norm_name.is_empty() {
            signals.push(ChannelKey::NameNumber(norm_name, channel_number));
        }
        if signals.is_empty() {
            signals.push(ChannelKey::Url(e.url.clone()));
        }

        FeedCtx {
            provider: provider.to_string(),
            provider_idx,
            local_idx,
            url: e.url.clone(),
            name,
            channel_number,
            group: e.group_title.clone().filter(|s| !s.is_empty()),
            logo: e.tvg_logo.clone().filter(|s| !s.is_empty()),
            languages,
            country,
            maturity,
            duration_secs: e.duration_secs,
            headers: e.headers.clone(),
            props: e.props.clone(),
            signals,
        }
    }
}

/// Look up an EXTINF attribute case-insensitively.
fn attr<'a>(e: &'a M3uEntry, key: &str) -> Option<&'a str> {
    e.attributes
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v.as_str())
}

/// Parse a channel number (integer part only, float-free); `None` if absent or unparseable.
fn parse_chno(s: &str) -> Option<i64> {
    s.trim().split('.').next()?.parse::<i64>().ok()
}

/// Comma-split a list attribute (`tvg-language`), trimmed, empties dropped, in source order.
fn split_list(s: &str) -> Vec<String> {
    s.split(',')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

/// Normalize a tvg-id into a stable identity token (trim + ASCII lowercase, structure preserved); `None`
/// when empty so a blank `tvg-id=""` does not become a signal. `pub(crate)` so EPG binding (LT-BIND) reuses
/// the EXACT same tvg normalization that produced the `t:<tvg-id>` channel id.
pub(crate) fn norm_tvg(raw: Option<&str>) -> Option<String> {
    let t = raw?.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_ascii_lowercase())
    }
}

/// Normalize a display name to an identity key: ASCII alphanumerics only, lowercased (mirrors the source
/// crate's title dedup), so "CNN HD" / "cnn-hd" fold together but distinct names stay distinct. `pub(crate)`
/// so EPG binding (LT-BIND) matches display names with the EXACT same normalization used for channel identity.
pub(crate) fn normalize_name(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// Conservative, advisory-only maturity detection from explicit markers in the name/group. Deliberately
/// narrow (no bare "adult", which would mislabel "Adult Swim"); advisory gating means a miss is low-harm.
fn detect_maturity(name: &str, group: Option<&str>) -> Option<String> {
    let hay = format!("{} {}", name, group.unwrap_or("")).to_ascii_lowercase();
    const MARKERS: &[&str] = &["xxx", "porn", "18+", "+18", "(18)"];
    if MARKERS.iter().any(|m| hay.contains(m)) {
        Some("adult".to_string())
    } else {
        None
    }
}

fn uf_find(parent: &mut [usize], mut x: usize) -> usize {
    while parent[x] != x {
        parent[x] = parent[parent[x]]; // path halving
        x = parent[x];
    }
    x
}

fn uf_union(parent: &mut [usize], a: usize, b: usize) {
    let ra = uf_find(parent, a);
    let rb = uf_find(parent, b);
    if ra != rb {
        // Attach to the smaller index so the root (and thus output) is deterministic.
        parent[ra.max(rb)] = ra.min(rb);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(tvg_id: Option<&str>, name: &str, url: &str) -> M3uEntry {
        M3uEntry {
            url: url.to_string(),
            duration_secs: -1,
            tvg_id: tvg_id.map(String::from),
            display_name: name.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn channel_id_comes_from_tvg_id_when_present() {
        let p = ProviderPlaylist {
            provider: "a".into(),
            entries: vec![entry(Some("CNN.us"), "CNN HD", "http://a/cnn")],
        };
        let out = build_channels(&[p]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].channel_id, "t:cnn.us"); // normalized, deterministic
    }

    #[test]
    fn channel_id_falls_back_to_name_number_hash() {
        let mut e = entry(None, "Movies", "http://a/m");
        e.attributes.push(("tvg-chno".into(), "1".into()));
        let out = build_channels(&[ProviderPlaylist {
            provider: "a".into(),
            entries: vec![e],
        }]);
        assert_eq!(out[0].channel_id, "c:5a9f217db9f2b8b7");
        assert_eq!(out[0].channel_number, Some(1));
    }

    #[test]
    fn two_provider_feeds_of_one_channel_merge_with_ranked_alternates() {
        let a = ProviderPlaylist {
            provider: "provA".into(),
            entries: vec![entry(Some("cnn.us"), "CNN", "http://a/cnn")],
        };
        let b = ProviderPlaylist {
            provider: "provB".into(),
            entries: vec![entry(Some("cnn.us"), "CNN HD", "http://b/cnn")],
        };
        let out = build_channels(&[a, b]);
        assert_eq!(out.len(), 1);
        let c = &out[0];
        assert_eq!(c.channel_id, "t:cnn.us");
        assert_eq!(c.feeds.len(), 2);
        assert_eq!(c.feeds[0].url, "http://a/cnn"); // provA ranked first by provider order
        assert_eq!(c.feeds[1].url, "http://b/cnn");
        assert_eq!(c.source_provenance, vec!["provA", "provB"]);
    }

    #[test]
    fn a_tvg_feed_and_a_name_only_feed_for_one_channel_merge_transitively() {
        // provA: tvg-id cnn.us AND name CNN. provB: name CNN only. They share the name signal.
        let a = ProviderPlaylist {
            provider: "a".into(),
            entries: vec![entry(Some("cnn.us"), "CNN", "http://a/cnn")],
        };
        let b = ProviderPlaylist {
            provider: "b".into(),
            entries: vec![entry(None, "CNN", "http://b/cnn")],
        };
        let out = build_channels(&[a, b]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].channel_id, "t:cnn.us"); // Tvg signal wins as the canonical minimum
        assert_eq!(out[0].feeds.len(), 2);
    }

    #[test]
    fn distinct_channels_stay_separate() {
        let p = ProviderPlaylist {
            provider: "a".into(),
            entries: vec![
                entry(Some("cnn.us"), "CNN", "http://a/1"),
                entry(Some("bbc.uk"), "BBC", "http://a/2"),
            ],
        };
        assert_eq!(build_channels(&[p]).len(), 2);
    }

    #[test]
    fn anonymous_feeds_do_not_collide_but_identical_urls_merge() {
        let p = ProviderPlaylist {
            provider: "a".into(),
            entries: vec![
                entry(None, "", "http://a/1"),
                entry(None, "", "http://a/2"),
                entry(None, "", "http://a/1"),
            ],
        };
        let out = build_channels(&[p]);
        assert_eq!(out.len(), 2); // /1 (x2) merged, /2 separate
    }

    #[test]
    fn maturity_is_tagged_conservatively() {
        let adult = entry(Some("x"), "Hot XXX", "http://a/x");
        let swim = entry(Some("as"), "Adult Swim", "http://a/as");
        let out = build_channels(&[ProviderPlaylist {
            provider: "a".into(),
            entries: vec![adult, swim],
        }]);
        let by_id: BTreeMap<_, _> = out.iter().map(|c| (c.channel_id.as_str(), c)).collect();
        assert_eq!(by_id["t:x"].maturity_tag.as_deref(), Some("adult"));
        assert_eq!(by_id["t:as"].maturity_tag, None); // "Adult Swim" is not flagged
    }
}
