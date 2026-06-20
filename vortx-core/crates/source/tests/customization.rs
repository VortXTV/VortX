//! Conformance + property tests for the customization schema (themes / layouts / branding). The token
//! KEYS are pinned cross-language (never the colors, which are integer-encoded but still convert through
//! float math). The full theme manifest is the headline vector the TS SDK and the Swift decoder both
//! consume.

use proptest::prelude::*;
use vortx_source::{
    canonicalize, has_errors, token_keys, validate, AccentDef, Color, CustomizationCapability,
    ResourceKind, ThemeDef, VortxAddonManifest, VortxTransport,
};

const THEME_FULL: &str = include_str!("../conformance/theme_full.json");
const TOKEN_KEYS: &str = include_str!("../conformance/token_keys.json");

fn theme_manifest() -> VortxAddonManifest {
    let mut m = VortxAddonManifest::native(
        "tv.vortx.theme.midnight",
        "1.0.0",
        "Midnight",
        VortxTransport::Federated {
            endpoint: "vortx://local".into(),
        },
    );
    m.capabilities = vec![ResourceKind::Theme];
    m.customization = Some(CustomizationCapability {
        provides_themes: true,
        scope: Some("per-profile".into()),
        themes: vec![ThemeDef {
            id: "midnight".into(),
            label: "Midnight".into(),
            accent: AccentDef {
                base: Color::Oklch {
                    l: 550,
                    c: 150,
                    h: 2640,
                    a: 255,
                },
                bright: Color::Oklch {
                    l: 700,
                    c: 160,
                    h: 2640,
                    a: 255,
                },
            },
            oled: Some(true),
            palette: None,
            radius: None,
            motion: None,
        }],
        ..CustomizationCapability::default()
    });
    m
}

#[test]
fn token_keys_match_conformance_vector() {
    let expected: Vec<String> = serde_json::from_str(TOKEN_KEYS).expect("parse token keys");
    let got: Vec<String> = token_keys().iter().map(|s| s.to_string()).collect();
    assert_eq!(got, expected);
}

#[test]
fn theme_full_parses_round_trips_and_validates_clean() {
    let m: VortxAddonManifest = serde_json::from_str(THEME_FULL).expect("parse theme_full");
    assert!(m.customization.is_some());

    let json = serde_json::to_string(&m).unwrap();
    let back: VortxAddonManifest = serde_json::from_str(&json).unwrap();
    assert_eq!(m, back, "manifest must round-trip");

    let issues = validate(&m);
    assert!(
        !has_errors(&issues),
        "theme_full must validate clean: {issues:?}"
    );
}

#[test]
fn theme_full_canonicalizes_idempotently() {
    let m: VortxAddonManifest = serde_json::from_str(THEME_FULL).unwrap();
    let once = canonicalize(&m).unwrap();
    let back: VortxAddonManifest = serde_json::from_slice(&once).unwrap();
    let twice = canonicalize(&back).unwrap();
    assert_eq!(once, twice);
}

#[test]
fn mixed_archetype_is_rejected() {
    let mut m = theme_manifest();
    m.capabilities.push(ResourceKind::Stream);
    assert!(has_errors(&validate(&m)));
}

proptest! {
    #[test]
    fn oklch_to_srgb_is_total_and_in_gamut(
        l in 0u16..2000,
        c in 0u16..1000,
        h in 0u16..7200,
        a in 0u8..=255,
    ) {
        let color = Color::Oklch { l, c, h, a };
        let (_r, _g, _b, alpha) = color.to_srgb(); // u8 by construction: in-gamut, no panic
        prop_assert_eq!(alpha, a);
        let lum = color.relative_luminance();
        prop_assert!((0.0..=1.0).contains(&lum));
    }

    #[test]
    fn archetype_invariant_holds(add_content in any::<bool>()) {
        let mut m = theme_manifest();
        if add_content {
            m.capabilities.push(ResourceKind::Meta);
        }
        let issues = validate(&m);
        prop_assert_eq!(has_errors(&issues), add_content);
    }

    #[test]
    fn canonical_idempotent_for_random_accent(l in 0u16..1000, h in 0u16..3600) {
        let mut m = theme_manifest();
        if let Some(cust) = m.customization.as_mut() {
            cust.themes[0].accent.base = Color::Oklch { l, c: 150, h, a: 255 };
        }
        let once = canonicalize(&m).unwrap();
        let back: VortxAddonManifest = serde_json::from_slice(&once).unwrap();
        prop_assert_eq!(once, canonicalize(&back).unwrap());
    }
}
