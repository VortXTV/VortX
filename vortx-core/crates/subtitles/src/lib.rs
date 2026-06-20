//! # vortx-subtitles
//!
//! The engine-owned subtitle layer. Its first capability is the thing every player gets wrong and users
//! fight with constantly: picking the RIGHT subtitle track automatically. Given the available tracks and
//! the profile's [`SubtitlePrefs`] (ranked languages, forced / hearing-impaired intent, format and source
//! preferences), [`select`] deterministically chooses the best track and explains why.
//!
//! Selection is a ranked-preference problem encoded as a single `Ord` sort key, so it is pure, total, and
//! order-independent (the same tracks in any order yield the same pick). No clock, no RNG, no floats, so
//! the choice is byte-reproducible across Rust / Swift / Kotlin / TS and pinned by conformance vectors.
//!
//! Fetching tracks from providers (OpenSubtitles / SubDL / addons), auto-sync, and whisper generation are
//! later phases that feed tracks into this selector; the selector itself stays pure.

mod model;
mod select;

pub use model::{SubtitleFormat, SubtitlePrefs, SubtitleSourceTier, SubtitleTrack};
pub use select::{select, Reason, SubtitleSelection};
