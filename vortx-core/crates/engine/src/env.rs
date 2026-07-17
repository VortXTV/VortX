//! The engine's view of the outside world. Keeping side effects behind an [`Env`] trait keeps `dispatch`
//! a pure function of `(state, action, env)`: tests pin a fixed clock, and the platform layer later
//! supplies the real one. The first chunk needs only the wall clock (for tombstone timestamps); storage
//! and networking join here in later phases.

/// The ambient capabilities the engine reads. Pure dispatch never calls the OS directly; it goes through
/// this so a test can pin time.
pub trait Env {
    /// Unix seconds. Used for delete tombstones and LWW timestamps.
    fn now(&self) -> u64;
}

/// A fixed-clock environment for tests and offline planning.
#[derive(Debug, Clone, Copy)]
pub struct InMemoryEnv {
    now: u64,
}

impl InMemoryEnv {
    pub fn new(now: u64) -> Self {
        Self { now }
    }
}

impl Env for InMemoryEnv {
    fn now(&self) -> u64 {
        self.now
    }
}
