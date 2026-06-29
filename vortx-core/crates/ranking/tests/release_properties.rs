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
        // Parsing is idempotent on its OWN output: whatever title parse_release extracts, re-parsing that
        // yields the same title. The raw input need not be marker-free (a random word like "DvD" is a real
        // Dolby-Vision marker the parser legitimately strips), so the fixpoint is on the PARSED title, not
        // the raw input. This is the determinism property that actually holds.
        let raw = words.join(" ");
        let once = parse_release(&raw).title;
        let twice = parse_release(&once).title;
        prop_assert_eq!(once, twice);
    }
}
