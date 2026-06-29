//! # vortx-ranking
//!
//! The single stream ranker, written ONCE so every VortX surface (and the player router) shares it
//! instead of the three Swift/Kotlin/TS copies the overlay approach would need. stremio-core ships no
//! ranking at all (it hands the UI an unordered list); Nuvio ranks quality-then-installed-addon-order.
//! This ranker:
//!
//! - parses release tokens from an add-on's stream label into [`ParsedData`] (resolution, source class,
//!   HDR/DV, audio, codec, season/episode, ...), the cross-language contract pinned by conformance vectors;
//! - ranks by a per-profile [`RankingPrefs`] weight contract where the USER's source preference is the
//!   TOP key, a debrid-cached stream gets a within-tier `+8000` bonus (it clears the within-tier spread
//!   but cannot jump the 15k resolution-tier step), and junk/fake sinks below the legit ceiling;
//! - emits [`RankedStream`] with `reasons` (explainable ranking) plus `is_dolby_vision`/`is_hdr`/`audio`
//!   so the player router routes DV/HDR/Atmos without re-parsing the label.

mod antifraud;
mod dedup;
mod episode;
mod parse;
mod prefs;
mod rank;
mod release;

pub use antifraud::{validate as validate_stream, AntiFraudInput, DropReason, Verdict};
pub use dedup::{dedup, DedupStream, MergedStream};
pub use episode::{
    absolute_from_seasonal, map_episode, EpisodeRequest, FileMatch, MatchKind, PackFile,
};
pub use parse::{parse, parse_typed, Audio, Hdr, ParsedData, Resolution, SourceClass};
pub use prefs::RankingPrefs;
pub use rank::{rank, RankedStream, Tier};
pub use release::{parse_release, ReleaseMeta};
