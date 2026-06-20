//! The wire contract the platform bridges speak: a JSON [`Action`] in, a JSON [`DispatchResult`] (with
//! [`EngineEvent`]s) out. These tagged shapes are the FFI seam; their field names are the cross-language
//! contract, pinned by conformance vectors.

use serde::{Deserialize, Serialize};

/// An action the host dispatches into the engine. Tagged by `type` (snake_case).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    /// Re-point the active profile to an existing, live profile (instant, no re-auth).
    SwitchProfile { id: String },
    /// Add (or revive) a viewer profile in the roster.
    AddProfile { id: String, name: String },
    /// Tombstone-delete a profile (never the owner or the last live profile).
    DeleteProfile { id: String },
    /// Set a profile's parental controls: the kids flag and an optional maturity ceiling (age). Bumps the
    /// profile's LWW edit clock so the change wins on multi-device merge.
    SetParental {
        id: String,
        #[serde(default)]
        kids: bool,
        #[serde(default, rename = "maturityCeiling", skip_serializing_if = "Option::is_none")]
        maturity_ceiling: Option<u8>,
    },
    /// No state change; a way for the host to request a fresh state snapshot.
    GetState,
}

/// A thing that happened as a result of an action. Tagged by `event` (snake_case).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum EngineEvent {
    ProfileSwitched { id: String },
    ProfileAdded { id: String },
    ProfileDeleted { id: String },
    ParentalSet { id: String },
}

/// The result of a dispatch: success/failure, an optional error message, and the events produced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchResult {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub events: Vec<EngineEvent>,
}

impl DispatchResult {
    pub(crate) fn ok(events: Vec<EngineEvent>) -> Self {
        Self {
            ok: true,
            error: None,
            events,
        }
    }

    pub(crate) fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(message.into()),
            events: Vec::new(),
        }
    }
}
