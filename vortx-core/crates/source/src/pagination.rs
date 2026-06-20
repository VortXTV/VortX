//! Engine-level pagination across heterogeneous catalogs. The engine merges catalog rows from many
//! addons; each addon paginates independently via a Stremio `skip`. A naive merge re-shows or skips items
//! when you load more. [`CatalogCursor`] is a single cursor that spans all addons: a per-addon skip map
//! advances each source by what it returned, and a seen-set guarantees no id ever lands on two pages. The
//! result is that "load more" only ever APPENDS, never overwrites, and the whole thing is a pure function
//! of `(cursor, fetched pages)`, so re-requesting a page is idempotent.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// The pagination state: how far each addon has been consumed, and which item ids were already emitted.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogCursor {
    /// Per-addon consumed count (the `skip` to request next from each addon).
    #[serde(default)]
    pub skips: BTreeMap<String, u32>,
    /// Item ids already emitted across all pages, so none appears twice.
    #[serde(default)]
    pub seen: BTreeSet<String>,
}

/// One addon's freshly-fetched slice for the current page (its item ids in the addon's own order).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddonPage {
    pub addon_id: String,
    #[serde(default)]
    pub items: Vec<String>,
}

/// A built page: the new items to append, plus the advanced cursor for the next request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page {
    pub items: Vec<String>,
    pub cursor: CatalogCursor,
}

/// Build the next page from the current cursor and the freshly-fetched addon slices. Deterministic
/// (addons in sorted id order, each addon in its own item order), dedup-aware (no id twice, ever), and
/// append-only (the returned cursor advances every addon by what it returned).
pub fn next_page(cursor: &CatalogCursor, fetched: &[AddonPage]) -> Page {
    let mut skips = cursor.skips.clone();
    let mut seen = cursor.seen.clone();
    let mut items = Vec::new();

    let mut sorted: Vec<&AddonPage> = fetched.iter().collect();
    sorted.sort_by(|a, b| a.addon_id.cmp(&b.addon_id));

    for page in sorted {
        *skips.entry(page.addon_id.clone()).or_insert(0) += page.items.len() as u32;
        for id in &page.items {
            // `insert` returns true only when the id is new: that is both the within-page and the
            // cross-page dedup, in one step.
            if seen.insert(id.clone()) {
                items.push(id.clone());
            }
        }
    }

    Page {
        items,
        cursor: CatalogCursor { skips, seen },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addon(id: &str, items: &[&str]) -> AddonPage {
        AddonPage {
            addon_id: id.into(),
            items: items.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn page_two_appends_and_advances_skips() {
        let p1 = next_page(
            &CatalogCursor::default(),
            &[addon("a", &["x", "y"]), addon("b", &["z"])],
        );
        assert_eq!(p1.items, vec!["x", "y", "z"]); // addon a then b, each in order
        assert_eq!(p1.cursor.skips["a"], 2);
        assert_eq!(p1.cursor.skips["b"], 1);

        let p2 = next_page(&p1.cursor, &[addon("a", &["w"]), addon("b", &["v"])]);
        assert_eq!(p2.items, vec!["w", "v"]);
        assert_eq!(p2.cursor.skips["a"], 3);
        assert_eq!(p2.cursor.skips["b"], 2);
    }

    #[test]
    fn an_item_never_appears_on_two_pages() {
        let p1 = next_page(&CatalogCursor::default(), &[addon("a", &["x", "y"])]);
        // addon b returns y (a dup from page 1) plus a fresh z.
        let p2 = next_page(&p1.cursor, &[addon("b", &["y", "z"])]);
        assert_eq!(p2.items, vec!["z"]); // y is suppressed, already seen
    }

    #[test]
    fn within_page_duplicates_are_deduped() {
        let p = next_page(
            &CatalogCursor::default(),
            &[addon("a", &["same"]), addon("b", &["same"])],
        );
        assert_eq!(p.items, vec!["same"]);
    }

    #[test]
    fn re_requesting_a_page_is_idempotent() {
        let cursor = CatalogCursor::default();
        let pages = [addon("a", &["x", "y"])];
        assert_eq!(next_page(&cursor, &pages), next_page(&cursor, &pages));
    }
}
