//! Property-based invariants for the release parser: totality (never panics on adversarial input),
//! determinism, idempotent re-parse of the title, and bounded/sane extracted fields.

use proptest::prelude::*;
use vortx_ranking::parse_release;

proptest! {
    #[test]
    fn never_panics_and_is_deterministic(s in ".*") {
        let a = parse_release(&s);
        let b = parse_release(&s);
        prop_assert_eq!(a, b);
    }

    #[test]
    fn year_is_none_or_plausible(s in ".*") {
        if let Some(y) = parse_release(&s).year {
            prop_assert!((1900..=2099).contains(&y));
        }
    }

    #[test]
    fn title_carries_no_resolution_marker(s in ".*") {
        // The title is the tokens before the first marker, so it can never contain a resolution tag.
        let title = parse_release(&s).title.to_ascii_lowercase();
        for marker in ["2160p", "1080p", "720p", "480p"] {
            prop_assert!(!title.contains(marker), "title `{}` contained `{}`", title, marker);
        }
    }

    #[test]
    fn group_is_bounded_and_alphanumeric(s in ".*") {
        if let Some(g) = parse_release(&s).group {
            prop_assert!(!g.is_empty() && g.len() <= 20);
            prop_assert!(g.chars().all(|c| c.is_ascii_alphanumeric()));
        }
    }

    #[test]
    fn title_is_a_reparse_fixpoint(
        words in prop::collection::vec("[A-Za-z]{1,8}", 1..5),
    ) {
        // A clean title (plain words, no markers) parses to itself: a stable fixpoint.
        let title = words.join(" ");
        let reparsed = parse_release(&title).title;
        prop_assert_eq!(title, reparsed);
    }
}
