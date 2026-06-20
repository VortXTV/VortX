//! The profile entity: a viewer persona with its own settings and account binding. The account is just
//! one attribute, NOT the profile's identity (the break from stremio-core where a profile is an account).

use serde::{Deserialize, Serialize};

use crate::ids::ProfileId;

/// How a profile relates to a streaming account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum AccountBinding {
    /// This profile owns its own Stremio account (and still account-syncs for Stremio-app interop).
    Own(String),
    /// This profile shares another profile's account credential but keeps its OWN library. The
    /// family-on-one-account case stremio-core cannot express.
    Shared(ProfileId),
    /// No streaming account; pure VortX-synced.
    LocalOnly,
}

/// Where a profile's installed add-ons come from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AddonBinding {
    /// This profile has its own add-on collection.
    Own,
    /// This profile shares the primary profile's add-ons.
    #[default]
    SharePrimary,
}

/// Parental controls. The PIN gates switching INTO this profile; these flags shape what it can see/do.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ParentalFlags {
    /// A kids profile: a restricted look plus a maturity ceiling and source filtering.
    #[serde(default)]
    pub kids: bool,
    /// May the family head edit this profile from the web dashboard WITHOUT its PIN? (Edit only, never
    /// an in-app switch bypass.)
    #[serde(default, rename = "familyEdit")]
    pub family_edit: bool,
    /// Maturity ceiling the board/aggregation layer enforces (e.g. a rating code).
    #[serde(
        default,
        rename = "maturityCeiling",
        skip_serializing_if = "Option::is_none"
    )]
    pub maturity_ceiling: Option<u8>,
}

/// Per-profile settings. Theme/chrome stay app-side; ranking + add-on visibility are engine-scoped (a
/// later chunk threads `RankingPrefs` from here into the ranker).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent: Option<String>,
    #[serde(default)]
    pub oled: bool,
    #[serde(default = "default_text_scale", rename = "textScale")]
    pub text_scale: f32,
    #[serde(default)]
    pub languages: Vec<String>,
    /// Add-on transport URLs disabled for this profile (kids-safe filtering, per-profile sources).
    #[serde(default, rename = "disabledAddons")]
    pub disabled_addons: Vec<String>,
}

fn default_text_scale() -> f32 {
    1.0
}

impl Default for ProfileSettings {
    fn default() -> Self {
        Self {
            accent: None,
            oled: false,
            text_scale: default_text_scale(),
            languages: Vec::new(),
            disabled_addons: Vec::new(),
        }
    }
}

/// A viewer persona. `rev` is the monotonic edit clock used for last-writer-wins merges; `deleted` is a
/// tombstone (kept so a delete propagates and can be revived, never a silent drop).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    pub id: ProfileId,
    pub name: String,
    /// The owner profile cannot be deleted and never carries a stray "uses own account" misconfig.
    #[serde(default)]
    pub owner: bool,
    pub account: AccountBinding,
    /// Salted-SHA-256 PIN hash (see `pin`); `None` = no parental gate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<String>,
    #[serde(default)]
    pub parental: ParentalFlags,
    #[serde(default)]
    pub addons: AddonBinding,
    #[serde(default)]
    pub settings: ProfileSettings,
    /// Tombstone flag.
    #[serde(default)]
    pub deleted: bool,
    /// Monotonic edit counter; the LWW merge clock.
    #[serde(default)]
    pub rev: u64,
    /// Unix seconds of the last edit (advisory; `rev` is authoritative for merges).
    #[serde(default, rename = "updatedAt")]
    pub updated_at: u64,
}

impl Profile {
    /// A new local-only persona with default settings.
    pub fn new(id: ProfileId, name: impl Into<String>) -> Self {
        Self {
            id,
            name: name.into(),
            owner: false,
            account: AccountBinding::LocalOnly,
            pin: None,
            parental: ParentalFlags::default(),
            addons: AddonBinding::SharePrimary,
            settings: ProfileSettings::default(),
            deleted: false,
            rev: 0,
            updated_at: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_serde_round_trip() {
        let mut p = Profile::new(ProfileId::new("p1"), "Alice");
        p.owner = true;
        p.account = AccountBinding::Own("uid-123".into());
        p.parental.kids = false;
        let json = serde_json::to_string(&p).unwrap();
        let back: Profile = serde_json::from_str(&json).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn account_binding_variants_serialize_tagged() {
        let own = serde_json::to_string(&AccountBinding::Own("u".into())).unwrap();
        assert!(own.contains("\"kind\":\"own\"") && own.contains("\"value\":\"u\""));
        let shared = serde_json::to_string(&AccountBinding::Shared(ProfileId::new("p2"))).unwrap();
        assert!(shared.contains("\"kind\":\"shared\""));
        let local = serde_json::to_string(&AccountBinding::LocalOnly).unwrap();
        assert_eq!(local, "{\"kind\":\"local_only\"}");
    }

    #[test]
    fn shared_profile_is_expressible() {
        // The case stremio-core cannot model: a persona that shares an account but is its own profile.
        let p = Profile::new(ProfileId::new("kid"), "Kid");
        let shared = Profile {
            account: AccountBinding::Shared(ProfileId::new("owner")),
            ..p
        };
        assert!(matches!(shared.account, AccountBinding::Shared(_)));
    }
}
