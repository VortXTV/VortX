//! # vortx-live
//!
//! The VortX native Live TV (IPTV / EPG) engine. Live TV is added to vortx-core by GENERALIZING the video
//! pipeline (parse -> dedup -> rank -> resolve -> finish), not by bolting on a silo, so it inherits
//! health-gating, maturity-gating, E2E sync, and hive federation. This crate is PURE: no network, no clock,
//! no RNG, and no float on any ordering / identity path. It parses the bytes the host fetched (M3U/M3U8
//! playlists, XMLTV EPG, Xtream JSON) and EMITS plans/decisions (channel identity, EPG windowed-query plans,
//! catchup URLs, failover switches); the host does all HTTP, byte transfer, and storage.
//!
//! LT1 (`m3u`): the M3U/M3U8 playlist parser. LT2 (`epg`): the XMLTV parser with the timezone -> UTC integer
//! fence. LT3 (`channel`): canonical channel identity + cross-provider dedup, with the `Secret` redaction
//! primitive (`secret`) and a stable FNV-1a hash (`hash`). LT4 (`guide`): pure EPG now/next + windowed grid
//! query views over the LT2 programme corpus.

mod channel;
mod epg;
mod guide;
mod hash;
mod m3u;
mod secret;

pub use channel::{build_channels, ChannelFeed, ChannelModel, ProviderPlaylist};
pub use epg::{parse_xmltv, parse_xmltv_time, Epg, EpgChannel, EpisodeNum, Program};
pub use guide::{grid, now_next, ChannelGrid, EpgWindow, GridProgram, NowNext};
pub use m3u::{parse_m3u, M3uEntry, Playlist};
pub use secret::Secret;
