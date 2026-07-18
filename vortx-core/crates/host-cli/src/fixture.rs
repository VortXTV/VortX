//! The record-or-replay fixture: the mechanism that makes the byte-stability proof hermetic. A
//! fixture directory is a RECORDED fan-out round:
//!
//! ```text
//! <dir>/registry.json          the source snapshot (Vec<SourceEntry>) the plan ran over
//! <dir>/run.json               { "now": <unix-secs>, "budgetMs": <ms>, "services": [wire...] }
//! <dir>/bodies/<addon-id>.json the raw HTTP body each planned source answered with
//! ```
//!
//! Replay classifies each recorded body through host-native's PUBLIC `body_to_items`, the SAME
//! validation the live NativeFetcher applies to a real 2xx body, so a replayed round exercises the
//! identical host classification path with the network held constant. A planned source with no
//! recorded body settles as `Timeout` through the kernel's partial-result contract, exactly like a
//! live source that missed its budget.
//!
//! An EMBEDDED copy of the recorded `tt0468569` round is compiled in, so the bare
//! `vortx-host-cli resolve --meta tt0468569` is deterministic with zero setup and zero network.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use vortx_source::SourceEntry;

use crate::CliError;

/// The recorded run parameters: the FIXED clock, the budget, and the debrid services that were
/// active when the round was captured. Injecting `now` from here is what makes two replays of the
/// same fixture byte-identical.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunSpec {
    /// The fixed clock for the round, Unix seconds.
    pub now: u64,
    #[serde(rename = "budgetMs")]
    pub budget_ms: u64,
    /// Debrid service wire strings active for the round (drives cacheStatus + the resolve plan).
    #[serde(default)]
    pub services: Vec<String>,
}

/// A loaded fixture: the source snapshot, the recorded bodies keyed by addon id, and the run spec.
#[derive(Debug, Clone)]
pub struct Fixture {
    pub registry: Vec<SourceEntry>,
    pub bodies: BTreeMap<String, String>,
    pub run: RunSpec,
}

/// The embedded recorded round for `tt0468569` (compiled in; the zero-setup default).
pub fn embedded() -> Fixture {
    let registry = serde_json::from_str(include_str!("../fixtures/tt0468569/registry.json"))
        .expect("embedded registry.json is valid by construction");
    let run = serde_json::from_str(include_str!("../fixtures/tt0468569/run.json"))
        .expect("embedded run.json is valid by construction");
    let bodies = BTreeMap::from([
        (
            "fixture-direct".to_string(),
            include_str!("../fixtures/tt0468569/bodies/fixture-direct.json").to_string(),
        ),
        (
            "fixture-hive".to_string(),
            include_str!("../fixtures/tt0468569/bodies/fixture-hive.json").to_string(),
        ),
    ]);
    Fixture {
        registry,
        bodies,
        run,
    }
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, CliError> {
    let text = fs::read_to_string(path)
        .map_err(|e| CliError::Fixture(format!("cannot read {}: {e}", path.display())))?;
    serde_json::from_str(&text)
        .map_err(|e| CliError::Fixture(format!("cannot parse {}: {e}", path.display())))
}

/// Load a recorded fixture directory (see the module doc for the layout).
pub fn load(dir: &Path) -> Result<Fixture, CliError> {
    let registry: Vec<SourceEntry> = read_json(&dir.join("registry.json"))?;
    let run: RunSpec = read_json(&dir.join("run.json"))?;
    let bodies_dir = dir.join("bodies");
    let mut bodies = BTreeMap::new();
    let entries = fs::read_dir(&bodies_dir)
        .map_err(|e| CliError::Fixture(format!("cannot read {}: {e}", bodies_dir.display())))?;
    for entry in entries {
        let entry = entry.map_err(|e| CliError::Fixture(format!("cannot list bodies dir: {e}")))?;
        let path = entry.path();
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let body = fs::read_to_string(&path)
            .map_err(|e| CliError::Fixture(format!("cannot read {}: {e}", path.display())))?;
        bodies.insert(stem.to_string(), body);
    }
    Ok(Fixture {
        registry,
        bodies,
        run,
    })
}

/// Write a captured round as a fixture directory so it replays byte-identically.
pub fn record(dir: &Path, fixture: &Fixture) -> Result<(), CliError> {
    let bodies_dir = dir.join("bodies");
    fs::create_dir_all(&bodies_dir)
        .map_err(|e| CliError::Fixture(format!("cannot create {}: {e}", bodies_dir.display())))?;
    let write = |path: &Path, text: &str| -> Result<(), CliError> {
        fs::write(path, text)
            .map_err(|e| CliError::Fixture(format!("cannot write {}: {e}", path.display())))
    };
    let registry = serde_json::to_string_pretty(&fixture.registry)
        .map_err(|e| CliError::Fixture(format!("serialize registry: {e}")))?;
    write(&dir.join("registry.json"), &registry)?;
    let run = serde_json::to_string_pretty(&fixture.run)
        .map_err(|e| CliError::Fixture(format!("serialize run spec: {e}")))?;
    write(&dir.join("run.json"), &run)?;
    for (addon_id, body) in &fixture.bodies {
        write(&bodies_dir.join(format!("{addon_id}.json")), body)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_fixture_parses_and_covers_both_sources() {
        let f = embedded();
        assert_eq!(f.registry.len(), 2);
        assert!(f.bodies.contains_key("fixture-hive"));
        assert!(f.bodies.contains_key("fixture-direct"));
        assert_eq!(f.run.now, 1_752_600_000);
        assert_eq!(f.run.services, vec!["realdebrid"]);
    }

    #[test]
    fn record_then_load_round_trips_the_fixture() {
        let dir = std::env::temp_dir().join(format!(
            "vortx-host-cli-fixture-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        ));
        let original = embedded();
        record(&dir, &original).expect("record");
        let loaded = load(&dir).expect("load");
        assert_eq!(loaded.bodies, original.bodies);
        assert_eq!(loaded.run.now, original.run.now);
        assert_eq!(loaded.registry, original.registry);
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }
}
