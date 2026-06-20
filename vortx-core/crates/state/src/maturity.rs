//! The parental-controls ENFORCEMENT primitive. [`ParentalFlags`] is data the UI and sync round-trip, but
//! until now nothing consulted `maturity_ceiling`, so a kids profile saw everything: defined, not
//! enforced. This module is the pure gate the pipelines call.
//!
//! Two design choices make it 10x over a typical "hide the kids section" toggle:
//!
//! 1. **Reconciliation.** Addons report maturity in incompatible schemes (MPAA `R`, US-TV `TV-MA`, BBFC
//!    `15`, or a bare `18`). [`parse_certification`] maps every scheme to ONE age-equivalent `u8`, so the
//!    ceiling comparison is total instead of a brittle string match that leaks unmatched ratings through.
//! 2. **Fail-closed for kids.** Unrated/unknown content is BLOCKED for a kids profile ([`allows`] returns
//!    false), so a kids profile never surfaces something we cannot prove is within its ceiling. A
//!    non-kids profile that merely set a ceiling is fail-open on unrated content (a softer preference).

use serde::{Deserialize, Serialize};

use crate::profile::ParentalFlags;

/// A content maturity rating reconciled to a single age-equivalent in years. `0` = suitable for all ages.
/// `Ord`, so `rating <= ceiling` is the whole comparison.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct MaturityRating(pub u8);

/// The age a kids profile is capped at when no explicit `maturity_ceiling` is set.
pub const DEFAULT_KIDS_CEILING: u8 = 12;

/// The largest age a bare-number certification is trusted to mean (guards a junk "99" rating).
const MAX_SANE_AGE: u8 = 21;

/// Reconcile a heterogeneous certification string (MPAA / US-TV / BBFC / a bare age) to an age-equivalent.
/// Returns `None` for unrated/unknown so the caller's policy (not a guess) decides what to do.
pub fn parse_certification(raw: &str) -> Option<MaturityRating> {
    let norm = raw
        .trim()
        .to_ascii_lowercase()
        .strip_prefix("rated ")
        .map(str::to_string)
        .unwrap_or_else(|| raw.trim().to_ascii_lowercase());
    let norm = norm.trim();

    // Explicit "no rating" markers: stay None (the gate, not the parser, decides the policy).
    let unrated = ["nr", "ur", "unrated", "not rated", "none", "n/a", "tbd", ""];
    if unrated.contains(&norm) {
        return None;
    }

    let age = match norm {
        // All ages.
        "g" | "tv-g" | "tv-y" | "u" | "e" | "ec" | "all" | "0+" | "0" | "ka" => 0,
        // Young children.
        "tv-y7" | "7" | "7+" => 7,
        // Parental guidance.
        "pg" | "tv-pg" | "6+" | "8" | "8+" => 8,
        "10" | "10+" | "pg-10" => 10,
        "12" | "12+" | "12a" => 12,
        "pg-13" | "13" | "13+" => 13,
        "tv-14" | "14" | "14+" => 14,
        "15" | "15+" | "ma15+" => 15,
        "16" | "16+" | "r16" => 16,
        // Mature.
        "r" | "tv-ma" | "17" | "17+" | "ma" | "r17" => 17,
        "nc-17" | "18" | "18+" | "x" | "r18" | "ao" | "adults only" => 18,
        // Otherwise try a bare integer like "13".
        other => return parse_bare_age(other),
    };
    Some(MaturityRating(age))
}

/// A bare numeric certification (e.g. an addon that just emits `"15"`), clamped to a sane range.
fn parse_bare_age(s: &str) -> Option<MaturityRating> {
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    digits
        .parse::<u16>()
        .ok()
        .map(|n| MaturityRating(n.min(MAX_SANE_AGE as u16) as u8))
}

/// The effective age ceiling for a profile: an explicit `maturity_ceiling` wins; otherwise a kids profile
/// gets [`DEFAULT_KIDS_CEILING`]; a normal profile is unrestricted (`None`).
pub fn effective_ceiling(flags: &ParentalFlags) -> Option<u8> {
    flags.maturity_ceiling.or({
        if flags.kids {
            Some(DEFAULT_KIDS_CEILING)
        } else {
            None
        }
    })
}

/// Whether a profile may see content with the given (already-parsed) rating. Fail-closed for kids on
/// unrated content.
pub fn allows(flags: &ParentalFlags, rating: Option<MaturityRating>) -> bool {
    match effective_ceiling(flags) {
        None => true,
        Some(ceiling) => match rating {
            Some(r) => r.0 <= ceiling,
            // Unrated: a kids profile blocks it (fail-closed); a ceilinged-but-non-kids profile allows it.
            None => !flags.kids,
        },
    }
}

/// Convenience: reconcile a raw certification string then apply the gate. A missing string is unrated.
pub fn allows_raw(flags: &ParentalFlags, raw_certification: Option<&str>) -> bool {
    allows(flags, raw_certification.and_then(parse_certification))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kids(ceiling: Option<u8>) -> ParentalFlags {
        ParentalFlags {
            kids: true,
            maturity_ceiling: ceiling,
            ..Default::default()
        }
    }

    #[test]
    fn schemes_reconcile_to_one_scale() {
        assert_eq!(parse_certification("G"), Some(MaturityRating(0)));
        assert_eq!(parse_certification("TV-MA"), parse_certification("R"));
        assert_eq!(parse_certification("NC-17"), parse_certification("18"));
        assert_eq!(parse_certification("PG-13"), Some(MaturityRating(13)));
        assert_eq!(parse_certification("Rated R"), Some(MaturityRating(17)));
        assert_eq!(parse_certification("Unrated"), None);
        assert_eq!(parse_certification("99"), Some(MaturityRating(MAX_SANE_AGE)));
    }

    #[test]
    fn kids_profile_fails_closed_on_unrated() {
        assert!(!allows(&kids(None), None)); // unrated blocked for kids
        assert!(allows(&kids(None), Some(MaturityRating(8)))); // PG within default ceiling 12
        assert!(!allows(&kids(None), Some(MaturityRating(17)))); // R over ceiling
    }

    #[test]
    fn non_kids_with_ceiling_is_fail_open_on_unrated() {
        let flags = ParentalFlags {
            kids: false,
            maturity_ceiling: Some(13),
            ..Default::default()
        };
        assert!(allows(&flags, None)); // unrated allowed for a non-kids ceiling
        assert!(allows(&flags, Some(MaturityRating(13))));
        assert!(!allows(&flags, Some(MaturityRating(17))));
    }

    #[test]
    fn unrestricted_profile_allows_everything() {
        let flags = ParentalFlags::default();
        assert!(allows(&flags, None));
        assert!(allows(&flags, Some(MaturityRating(18))));
    }
}
