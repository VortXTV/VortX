//! The real-clock [`Env`]: the host-side counterpart of the kernel's test-only `InMemoryEnv`. The
//! kernel reads time ONLY through the [`Env`] trait (tombstones, LWW timestamps, breaker cooldowns),
//! so this is the single point where wall-clock time enters a native host process.

use std::time::{SystemTime, UNIX_EPOCH};

use vortx_engine::Env;

/// The system-clock environment: `now()` is the current Unix time in seconds. Stateless and `Copy`,
/// so hosts can create it at any call site without plumbing a handle around.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemEnv;

impl SystemEnv {
    pub fn new() -> Self {
        Self
    }

    /// Current Unix seconds, saturating to 0 on a pre-epoch system clock (a misconfigured clock must
    /// never panic the engine; 0 simply makes every cooldown/tombstone comparison conservative).
    pub fn unix_now() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
}

impl Env for SystemEnv {
    fn now(&self) -> u64 {
        Self::unix_now()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_env_reports_a_present_day_unix_time() {
        // 2024-01-01 as a floor: proves we read the real clock in seconds, not millis or zero.
        let now = SystemEnv::new().now();
        assert!(
            now > 1_704_067_200,
            "now() = {now} is not a plausible current Unix time"
        );
        // Sanity ceiling: year ~2100 in seconds. A millisecond reading would blow past this.
        assert!(
            now < 4_102_444_800,
            "now() = {now} looks like milliseconds, not seconds"
        );
    }
}
