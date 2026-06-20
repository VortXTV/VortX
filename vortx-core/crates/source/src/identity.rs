//! Cross-namespace id reconciliation. A title appears across many catalog addons under different id
//! namespaces (IMDb `tt...`, TMDB, TVDB, AniList, Kitsu, MAL, Trakt). Each addon asserts an [`IdSet`] of
//! the ids it believes belong to ONE title. [`reconcile`] collapses sets that share an id into a single
//! [`CanonicalId`], so every downstream feature (reco, dedup, calendar, sync, ratings, parental) keys off
//! one identity instead of N.
//!
//! This is connected-components (union-find) over the id sets: two sets that share no id (directly or
//! transitively) land in different components by construction, so the engine can NEVER silently fuse two
//! distinct titles. A shared id with a conflicting value in another namespace is bad data: the merge keeps
//! the lexicographically smallest value and flags `conflicted`, rather than hiding the disagreement. The
//! result is order-independent (commutative + idempotent), pure, and deterministic.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// An external id namespace. Unknown namespaces round-trip through [`Namespace::Other`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Namespace {
    Imdb,
    Tmdb,
    Tvdb,
    AniList,
    Kitsu,
    Mal,
    Trakt,
    Simkl,
    Other(String),
}

impl Namespace {
    /// The canonical wire token (the key under which this namespace's value is stored).
    pub fn wire(&self) -> &str {
        match self {
            Namespace::Imdb => "imdb",
            Namespace::Tmdb => "tmdb",
            Namespace::Tvdb => "tvdb",
            Namespace::AniList => "anilist",
            Namespace::Kitsu => "kitsu",
            Namespace::Mal => "mal",
            Namespace::Trakt => "trakt",
            Namespace::Simkl => "simkl",
            Namespace::Other(s) => s,
        }
    }

    pub fn from_wire(s: &str) -> Namespace {
        match s.to_ascii_lowercase().as_str() {
            "imdb" => Namespace::Imdb,
            "tmdb" | "themoviedb" => Namespace::Tmdb,
            "tvdb" | "thetvdb" => Namespace::Tvdb,
            "anilist" => Namespace::AniList,
            "kitsu" => Namespace::Kitsu,
            "mal" | "myanimelist" => Namespace::Mal,
            "trakt" => Namespace::Trakt,
            "simkl" => Namespace::Simkl,
            other => Namespace::Other(other.to_string()),
        }
    }
}

/// A single namespaced id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalId {
    pub namespace: Namespace,
    pub value: String,
}

impl ExternalId {
    /// Parse a raw id token. `imdb:tt0111161` / `tmdb:278` use the prefix; a bare `tt0111161` is IMDb;
    /// anything else is an `Other` id. A `kitsu:1:2`-style id keeps the full remainder as the value.
    pub fn parse(raw: &str) -> ExternalId {
        let raw = raw.trim();
        if let Some((ns, val)) = raw.split_once(':') {
            return ExternalId {
                namespace: Namespace::from_wire(ns),
                value: val.to_string(),
            };
        }
        if raw.len() > 2 && raw.starts_with("tt") && raw[2..].bytes().all(|b| b.is_ascii_digit()) {
            return ExternalId {
                namespace: Namespace::Imdb,
                value: raw.to_string(),
            };
        }
        ExternalId {
            namespace: Namespace::Other("id".to_string()),
            value: raw.to_string(),
        }
    }

    fn key(&self) -> (String, String) {
        (self.namespace.wire().to_string(), self.value.clone())
    }
}

/// One addon's assertion that these ids all belong to a single title.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct IdSet {
    pub ids: Vec<ExternalId>,
}

impl IdSet {
    /// Build a set by parsing raw id tokens.
    pub fn parse(raws: &[&str]) -> IdSet {
        IdSet {
            ids: raws.iter().map(|r| ExternalId::parse(r)).collect(),
        }
    }
}

/// A reconciled title identity: one value per namespace, plus how many sets agreed and whether any
/// namespace disagreed.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct CanonicalId {
    /// Namespace wire token -> value. At most one value per namespace.
    pub ids: BTreeMap<String, String>,
    /// How many input sets merged into this identity.
    #[serde(default = "one")]
    pub support: usize,
    /// True if some namespace had two distinct values across the merged sets (bad data).
    #[serde(default)]
    pub conflicted: bool,
}

fn one() -> usize {
    1
}

/// Namespace preference order for the primary id.
const PRIMARY_ORDER: &[&str] = &[
    "imdb", "tmdb", "tvdb", "anilist", "kitsu", "mal", "trakt", "simkl",
];

impl CanonicalId {
    /// This identity's value in a namespace, if known.
    pub fn get(&self, namespace: &Namespace) -> Option<&str> {
        self.ids.get(namespace.wire()).map(String::as_str)
    }

    pub fn imdb(&self) -> Option<&str> {
        self.get(&Namespace::Imdb)
    }

    /// The preferred (namespace, value) for keying this title, by [`PRIMARY_ORDER`] then any.
    pub fn primary(&self) -> Option<(&str, &str)> {
        PRIMARY_ORDER
            .iter()
            .find_map(|ns| self.ids.get_key_value(*ns))
            .or_else(|| self.ids.iter().next())
            .map(|(k, v)| (k.as_str(), v.as_str()))
    }

    /// The identity's ids as an [`IdSet`] (for re-reconciliation / round-trips).
    pub fn external_ids(&self) -> Vec<ExternalId> {
        self.ids
            .iter()
            .map(|(ns, value)| ExternalId {
                namespace: Namespace::from_wire(ns),
                value: value.clone(),
            })
            .collect()
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
        // Attach to the smaller index so the root is deterministic.
        parent[ra.max(rb)] = ra.min(rb);
    }
}

/// Reconcile addon id sets into canonical title identities. Order-independent and deterministic.
pub fn reconcile(sets: &[IdSet]) -> Vec<CanonicalId> {
    let n = sets.len();
    let mut parent: Vec<usize> = (0..n).collect();

    // Link any two sets that share an (namespace, value).
    let mut first_seen: BTreeMap<(String, String), usize> = BTreeMap::new();
    for (i, set) in sets.iter().enumerate() {
        for id in &set.ids {
            match first_seen.get(&id.key()) {
                Some(&j) => uf_union(&mut parent, i, j),
                None => {
                    first_seen.insert(id.key(), i);
                }
            }
        }
    }

    // Group set indices by their component root.
    let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for i in 0..n {
        let root = uf_find(&mut parent, i);
        groups.entry(root).or_default().push(i);
    }

    // Build one CanonicalId per component.
    let mut out: Vec<CanonicalId> = groups
        .values()
        .map(|members| {
            let mut by_ns: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
            for &m in members {
                for id in &sets[m].ids {
                    by_ns
                        .entry(id.namespace.wire().to_string())
                        .or_default()
                        .insert(id.value.clone());
                }
            }
            let conflicted = by_ns.values().any(|vals| vals.len() > 1);
            // Deterministic value per namespace: the lexicographically smallest.
            let ids: BTreeMap<String, String> = by_ns
                .into_iter()
                .map(|(ns, vals)| (ns, vals.into_iter().next().unwrap_or_default()))
                .collect();
            CanonicalId {
                ids,
                support: members.len(),
                conflicted,
            }
        })
        .collect();

    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn five_variants_of_one_title_collapse() {
        let sets = vec![
            IdSet::parse(&["tt0111161", "tmdb:278"]),
            IdSet::parse(&["tmdb:278", "tvdb:111"]),
            IdSet::parse(&["tvdb:111"]),
            IdSet::parse(&["tt0111161", "trakt:1"]),
            IdSet::parse(&["imdb:tt0111161"]),
        ];
        let out = reconcile(&sets);
        assert_eq!(out.len(), 1);
        let c = &out[0];
        assert_eq!(c.imdb(), Some("tt0111161"));
        assert_eq!(c.get(&Namespace::Tmdb), Some("278"));
        assert_eq!(c.get(&Namespace::Tvdb), Some("111"));
        assert_eq!(c.support, 5);
        assert!(!c.conflicted);
    }

    #[test]
    fn distinct_titles_stay_separate() {
        let sets = vec![IdSet::parse(&["tt1"]), IdSet::parse(&["tt2"])];
        assert_eq!(reconcile(&sets).len(), 2);
    }

    #[test]
    fn shared_id_with_conflict_is_flagged() {
        // Both claim tt1 but disagree on tmdb: merged (they share tt1) but flagged.
        let sets = vec![
            IdSet::parse(&["tt1", "tmdb:5"]),
            IdSet::parse(&["tt1", "tmdb:9"]),
        ];
        let out = reconcile(&sets);
        assert_eq!(out.len(), 1);
        assert!(out[0].conflicted);
        assert_eq!(out[0].get(&Namespace::Tmdb), Some("5")); // smallest, deterministic
    }

    #[test]
    fn primary_prefers_imdb() {
        let out = reconcile(&[IdSet::parse(&["tmdb:5", "tt0111161"])]);
        assert_eq!(out[0].primary(), Some(("imdb", "tt0111161")));
    }
}
