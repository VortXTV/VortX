//! # vortx-nzb
//!
//! The VortX native Usenet engine: a pure NZB parser plus the retrieval/health POLICY. There is no
//! network here. The engine decides WHAT to fetch and in WHAT ORDER (content first, par2 deferred) and
//! reads completeness from the NZB itself; the host's NNTP client moves the bytes and does the yEnc/par2
//! decode. Because the policy is pure, the identical plan is reused by the app and the federation worker,
//! and it is pinned by cross-language conformance vectors.
//!
//! stremio-core has no Usenet concept; Usenet only ever arrived through a third-party add-on. VortX owns
//! it natively, beside torrents ([`vortx_ranking`]/the torrent policy) and debrid (`vortx-debrid`).

mod model;
mod parse;
mod plan;

pub use model::{Nzb, NzbFile, NzbSegment};
pub use parse::{parse_nzb, NzbError};
pub use plan::{health, retrieval_order, NzbHealth, RetrievalStep};
