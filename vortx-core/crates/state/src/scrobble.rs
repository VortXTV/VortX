//! The pure scrobble decision for external trackers (Trakt / Simkl / MAL). When the app reports a playback
//! lifecycle event plus the position, this decides what the host should send to the tracker, and crucially
//! WHETHER a stop counts as a watch (a pinned percent threshold). The host owns the OAuth HTTP; the engine
//! owns the decision, so a title flips watched IDENTICALLY on every platform.
//!
//! This is the engine-owned half of tracker sync (engine-needs #5 / the most universal competitor
//! feature): every rival marks-watched at a fuzzy or per-app percent that drifts; here the threshold is a
//! single integer pinned by a conformance vector.

use serde::{Deserialize, Serialize};

/// Tracker scrobble tuning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrobbleConfig {
    /// Stopping at or past this permille of the runtime counts as a WATCH. Trakt's long-standing default
    /// is 80% (= 800).
    pub watched_at_permille: u32,
}

impl Default for ScrobbleConfig {
    fn default() -> Self {
        Self {
            watched_at_permille: 800,
        }
    }
}

/// A playback lifecycle event the host reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackEvent {
    Start,
    Pause,
    Stop,
}

/// What the host should send to the external tracker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum ScrobbleAction {
    /// Nothing to send (e.g. an unknown / zero runtime).
    None,
    Start { progress_permille: u32 },
    Pause { progress_permille: u32 },
    /// Stopped; `watched` is the pinned cross-platform decision (progress >= the configured threshold).
    Stop {
        progress_permille: u32,
        watched: bool,
    },
}

/// Decide the scrobble action. Pure and integer: the `watched` flag on stop is `progress >= threshold`, so
/// the same playback flips watched identically on every device. Unknown / zero duration yields `None`.
pub fn scrobble(
    event: PlaybackEvent,
    position_ms: u64,
    duration_ms: u64,
    cfg: &ScrobbleConfig,
) -> ScrobbleAction {
    let Some(progress) = position_ms
        .saturating_mul(1000)
        .checked_div(duration_ms)
        .map(|p| p.min(1000) as u32)
    else {
        return ScrobbleAction::None;
    };
    match event {
        PlaybackEvent::Start => ScrobbleAction::Start {
            progress_permille: progress,
        },
        PlaybackEvent::Pause => ScrobbleAction::Pause {
            progress_permille: progress,
        },
        PlaybackEvent::Stop => ScrobbleAction::Stop {
            progress_permille: progress,
            watched: progress >= cfg.watched_at_permille,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stop_past_threshold_is_a_watch() {
        let cfg = ScrobbleConfig::default(); // 800
        assert_eq!(
            scrobble(PlaybackEvent::Stop, 540_000, 600_000, &cfg), // 90%
            ScrobbleAction::Stop { progress_permille: 900, watched: true }
        );
        assert_eq!(
            scrobble(PlaybackEvent::Stop, 300_000, 600_000, &cfg), // 50%
            ScrobbleAction::Stop { progress_permille: 500, watched: false }
        );
    }

    #[test]
    fn start_and_pause_carry_progress_but_never_watch() {
        let cfg = ScrobbleConfig::default();
        assert_eq!(
            scrobble(PlaybackEvent::Start, 0, 600_000, &cfg),
            ScrobbleAction::Start { progress_permille: 0 }
        );
        assert_eq!(
            scrobble(PlaybackEvent::Pause, 540_000, 600_000, &cfg),
            ScrobbleAction::Pause { progress_permille: 900 }
        );
    }

    #[test]
    fn zero_duration_is_none() {
        assert_eq!(
            scrobble(PlaybackEvent::Stop, 100, 0, &ScrobbleConfig::default()),
            ScrobbleAction::None
        );
    }
}
