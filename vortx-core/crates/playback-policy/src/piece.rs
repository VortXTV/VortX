//! The streaming torrent piece-selection policy. A vanilla BitTorrent client requests RAREST pieces first
//! to keep the swarm healthy; that is exactly wrong for playback, where you need pieces in roughly the
//! order you will watch them. This is the engine's pure ordering of which MISSING pieces to request next
//! for smooth streaming.
//!
//! The 10x over a naive sequential fetch is the priority shape that real streaming clients learned the
//! hard way:
//!
//! - **Header + footer first.** Piece 0 carries the container header; the LAST piece(s) often carry the
//!   MP4 `moov` atom a player needs before it can start or seek. Both are fetched at top priority even
//!   though the footer is far from the playhead, so playback can begin and seeking works immediately.
//! - **A critical window at the playhead** (deadline-now) ahead of a high-priority read-ahead window,
//!   ahead of the plain sequential tail, so a near-playhead stall is always the engine's top concern.
//! - **Deterministic + lossless**: the same `(have, playhead, cfg)` yields the same request order on every
//!   platform, and every returned piece is missing and listed once.

use serde::{Deserialize, Serialize};

/// Request urgency, most urgent first (declaration order is the sort order).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PiecePriority {
    /// Deadline now: header, footer, and the window at the playhead.
    Critical,
    /// Read-ahead just past the playhead.
    High,
    /// The sequential tail.
    Normal,
}

/// One piece to request, with its urgency.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PieceRequest {
    pub piece: u32,
    pub priority: PiecePriority,
}

/// How the streaming window is shaped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PiecePriorityConfig {
    /// Pieces from the playhead that are critical (must arrive before the playhead reaches them).
    pub critical_window: u32,
    /// Pieces after the critical window that are high priority read-ahead.
    pub readahead_window: u32,
    /// Trailing pieces to fetch up front (the MP4 moov / seekability footer).
    pub footer_pieces: u32,
}

impl Default for PiecePriorityConfig {
    fn default() -> Self {
        Self {
            critical_window: 4,
            readahead_window: 12,
            footer_pieces: 2,
        }
    }
}

/// Build the ordered list of MISSING pieces to request for forward streaming from `playhead`. `have[i]` is
/// true when piece `i` is already downloaded. The order is: header, footer, critical window, read-ahead,
/// then the sequential tail; each missing piece appears exactly once at its highest-priority slot.
pub fn piece_plan(have: &[bool], playhead: u32, cfg: &PiecePriorityConfig) -> Vec<PieceRequest> {
    let total = have.len() as u32;
    let mut seen = vec![false; have.len()];
    let mut out: Vec<PieceRequest> = Vec::new();

    // 1. Header (piece 0).
    try_push(&mut out, &mut seen, have, 0, PiecePriority::Critical);
    // 2. Footer (the last `footer_pieces` pieces) for the moov atom / seekability.
    for p in total.saturating_sub(cfg.footer_pieces)..total {
        try_push(&mut out, &mut seen, have, p, PiecePriority::Critical);
    }
    // 3. Critical window at the playhead.
    for p in playhead..playhead.saturating_add(cfg.critical_window) {
        try_push(&mut out, &mut seen, have, p, PiecePriority::Critical);
    }
    // 4. Read-ahead window.
    let ra_start = playhead.saturating_add(cfg.critical_window);
    for p in ra_start..ra_start.saturating_add(cfg.readahead_window) {
        try_push(&mut out, &mut seen, have, p, PiecePriority::High);
    }
    // 5. The sequential tail from the playhead onward.
    for p in playhead..total {
        try_push(&mut out, &mut seen, have, p, PiecePriority::Normal);
    }
    out
}

fn try_push(
    out: &mut Vec<PieceRequest>,
    seen: &mut [bool],
    have: &[bool],
    piece: u32,
    priority: PiecePriority,
) {
    let i = piece as usize;
    if i < have.len() && !have[i] && !seen[i] {
        seen[i] = true;
        out.push(PieceRequest { piece, priority });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_and_footer_lead_then_window_then_tail() {
        // 20 pieces, none downloaded, playhead at piece 8.
        let have = vec![false; 20];
        let plan = piece_plan(&have, 8, &PiecePriorityConfig::default());
        let order: Vec<u32> = plan.iter().map(|r| r.piece).collect();
        // Header 0, footer 18 & 19, then the critical window 8..12.
        assert_eq!(&order[..3], &[0, 18, 19]);
        assert_eq!(&order[3..7], &[8, 9, 10, 11]);
        // First three are Critical.
        assert!(plan[..3].iter().all(|r| r.priority == PiecePriority::Critical));
    }

    #[test]
    fn already_have_pieces_are_skipped() {
        let mut have = vec![false; 10];
        have[0] = true; // header already present
        have[5] = true;
        let plan = piece_plan(&have, 4, &PiecePriorityConfig::default());
        assert!(plan.iter().all(|r| r.piece != 0 && r.piece != 5));
    }

    #[test]
    fn no_piece_is_requested_twice() {
        let have = vec![false; 6];
        let plan = piece_plan(&have, 0, &PiecePriorityConfig::default());
        let mut pieces: Vec<u32> = plan.iter().map(|r| r.piece).collect();
        let len = pieces.len();
        pieces.sort_unstable();
        pieces.dedup();
        assert_eq!(pieces.len(), len);
    }
}
