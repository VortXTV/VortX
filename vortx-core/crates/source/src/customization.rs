//! The customization capability: themes, layouts, and branding as first-class, signable, shareable addon
//! payloads. This is what lets a user make VortX unrecognizably their own (the Nuvio "make it your own"
//! outcome), as a signed addon rather than a fixed in-app enum.
//!
//! The schema is the structural mirror of the app's live `Theme.swift` token surface, so the Swift
//! decoder is a thin map and this wire form is the conformance oracle for the design system. Colors and
//! metrics are stored as INTEGERS (OKLCH lightness in permille, hue in deci-degrees, chroma in milli),
//! never floats: the wire form stays byte-deterministic cross-platform and the whole manifest keeps `Eq`.
//! The lossy float math (OKLCH to sRGB) happens only inside [`Color::to_srgb`], which clamps in-gamut.

use serde::{Deserialize, Serialize};

/// A color, either a perceptual OKLCH triple (the authoring intent) or a literal sRGB value. OKLCH
/// components are integers: `l` permille (0..=1000), `c` milli-chroma, `h` deci-degrees (0..=3600).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "space", rename_all = "snake_case")]
pub enum Color {
    Oklch {
        l: u16,
        c: u16,
        h: u16,
        #[serde(default = "full_alpha")]
        a: u8,
    },
    Srgb {
        r: u8,
        g: u8,
        b: u8,
        #[serde(default = "full_alpha")]
        a: u8,
    },
}

fn full_alpha() -> u8 {
    255
}

impl Color {
    /// Convert to an 8-bit sRGB tuple `(r, g, b, a)`, always in-gamut `[0,255]`. Pure; the only place
    /// floating-point appears, and it is clamped so the output is total.
    pub fn to_srgb(&self) -> (u8, u8, u8, u8) {
        match *self {
            Color::Srgb { r, g, b, a } => (r, g, b, a),
            Color::Oklch { l, c, h, a } => {
                let l = l as f64 / 1000.0;
                let chroma = c as f64 / 1000.0;
                let hue_rad = (h as f64 / 10.0).to_radians();
                let oa = chroma * hue_rad.cos();
                let ob = chroma * hue_rad.sin();

                // OKLab -> linear sRGB (Bjorn Ottosson's coefficients).
                let l_ = l + 0.396_337_777_4 * oa + 0.215_803_757_3 * ob;
                let m_ = l - 0.105_561_345_8 * oa - 0.063_854_172_8 * ob;
                let s_ = l - 0.089_484_177_5 * oa - 1.291_485_548_0 * ob;
                let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_);
                let r = 4.076_741_662_1 * l3 - 3.307_711_591_3 * m3 + 0.230_969_929_2 * s3;
                let g = -1.268_438_004_6 * l3 + 2.609_757_401_1 * m3 - 0.341_319_396_5 * s3;
                let b = -0.004_196_086_3 * l3 - 0.703_418_614_7 * m3 + 1.707_614_701_0 * s3;
                (encode_srgb(r), encode_srgb(g), encode_srgb(b), a)
            }
        }
    }

    /// Relative luminance (WCAG) in `[0,1]`, for contrast checks.
    pub fn relative_luminance(&self) -> f64 {
        let (r, g, b, _) = self.to_srgb();
        0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }
}

/// Linear-light value -> gamma-encoded sRGB byte, clamped in-gamut.
fn encode_srgb(x: f64) -> u8 {
    let c = if x <= 0.003_130_8 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    };
    (c.clamp(0.0, 1.0) * 255.0).round() as u8
}

/// sRGB byte -> linear-light value.
fn linearize(byte: u8) -> f64 {
    let c = byte as f64 / 255.0;
    if c <= 0.040_45 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

/// The required accent pair. Chrome (canvas, surfaces, hairline, onAccent) derives from it in the app, so
/// a theme that supplies only an accent still gets a full coherent dark chrome for free.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccentDef {
    pub base: Color,
    pub bright: Color,
}

/// Optional ink + semantic color overrides. Field names mirror `Theme.Palette` exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaletteOverride {
    #[serde(
        default,
        rename = "textPrimary",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_primary: Option<Color>,
    #[serde(
        default,
        rename = "textSecondary",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_secondary: Option<Color>,
    #[serde(
        default,
        rename = "textTertiary",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_tertiary: Option<Color>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub danger: Option<Color>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ok: Option<Color>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warn: Option<Color>,
}

/// Corner radii (points). Mirrors `Theme.Radius`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RadiusDef {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chip: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control: Option<u16>,
}

/// Motion tuning (spring response/damping in permille, state-change duration in ms). Mirrors `Theme.Motion`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MotionDef {
    #[serde(
        default,
        rename = "focusResponse",
        skip_serializing_if = "Option::is_none"
    )]
    pub focus_response: Option<u16>,
    #[serde(
        default,
        rename = "focusDamping",
        skip_serializing_if = "Option::is_none"
    )]
    pub focus_damping: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<u16>,
}

/// A complete theme. Only `accent` is required; everything else derives or defaults.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThemeDef {
    pub id: String,
    pub label: String,
    pub accent: AccentDef,
    /// AMOLED modifier: forces the canvas to true black. A modifier, not a separate theme.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub palette: Option<PaletteOverride>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub radius: Option<RadiusDef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion: Option<MotionDef>,
}

/// A home rail. `source` is a `base|type|id` catalog key or a built-in surface id.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RailDecl {
    pub id: String,
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style: Option<String>,
    #[serde(default = "default_true")]
    pub visible: bool,
}

fn default_true() -> bool {
    true
}

/// The home screen rail arrangement.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HomeLayout {
    #[serde(default)]
    pub rails: Vec<RailDecl>,
}

/// A tab show/hide/reorder declaration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabDecl {
    pub id: String,
    pub visible: bool,
    pub order: u32,
}

/// Hero rotation configuration.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HeroDecl {
    pub enabled: bool,
    #[serde(default)]
    pub surfaces: Vec<String>,
    #[serde(default, rename = "autoRotate")]
    pub auto_rotate: bool,
    #[serde(default, rename = "inlineTrailer")]
    pub inline_trailer: bool,
}

/// A home/tab/hero arrangement: the shareable, signable generalization of the per-device hide/reorder.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutDef {
    #[serde(default)]
    pub home: HomeLayout,
    #[serde(default)]
    pub tabs: Vec<TabDecl>,
    #[serde(default)]
    pub hero: HeroDecl,
}

/// A bundled asset reference: a path plus an optional sha256 digest (so a signed theme's art can't be
/// swapped post-signature).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssetRef {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
}

/// The wordmark: constrained text or a digest-signed image.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Wordmark {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<AssetRef>,
}

/// A splash payload (image or lottie) with a capped duration (ms).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Splash {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<AssetRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lottie: Option<AssetRef>,
    #[serde(rename = "durationMs")]
    pub duration_ms: u32,
}

/// Brand overrides: wordmark, splash, alternate icon, accent name. Highest trust tier.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrandingDef {
    pub wordmark: Wordmark,
    #[serde(default, rename = "appIcon", skip_serializing_if = "Option::is_none")]
    pub app_icon: Option<AssetRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub splash: Option<Splash>,
    #[serde(
        default,
        rename = "accentName",
        skip_serializing_if = "Option::is_none"
    )]
    pub accent_name: Option<String>,
}

/// Declares the source provides UI customization. Mirrors `DebridCapability`/`HiveCapability`: a cheap,
/// no-I/O declaration the registry routes on and the host gates a permission on. Inline `themes`/`layout`/
/// `branding` cover the 80% case with zero new I/O; the `Theme`/`Layout`/`Branding` `ResourceKind`s are
/// the growth path for addons that serve large/rotating packs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CustomizationCapability {
    #[serde(default, rename = "providesThemes")]
    pub provides_themes: bool,
    #[serde(default, rename = "providesBranding")]
    pub provides_branding: bool,
    #[serde(default, rename = "providesLayout")]
    pub provides_layout: bool,
    /// Application scope: `per-profile` | `global`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub themes: Vec<ThemeDef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<LayoutDef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branding: Option<BrandingDef>,
}

/// The closed set of theme token keys an addon may override. The TS `ThemeTokenKey` union is generated
/// from this, so a typo'd token cannot compile there and is rejected by `deny_unknown_fields` here. Pinned
/// by a conformance vector (the KEYS, never the colors).
pub fn token_keys() -> &'static [&'static str] {
    &[
        "accent.base",
        "accent.bright",
        "palette.textPrimary",
        "palette.textSecondary",
        "palette.textTertiary",
        "palette.danger",
        "palette.ok",
        "palette.warn",
        "radius.card",
        "radius.chip",
        "radius.control",
        "motion.focusResponse",
        "motion.focusDamping",
        "motion.state",
        "oled",
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn srgb_color_round_trips_exactly() {
        let c = Color::Srgb {
            r: 31,
            g: 111,
            b: 235,
            a: 255,
        };
        assert_eq!(c.to_srgb(), (31, 111, 235, 255));
    }

    #[test]
    fn oklch_white_and_black_map_to_expected_extremes() {
        // L=1.0, C=0, any hue -> white; L=0 -> black.
        let white = Color::Oklch {
            l: 1000,
            c: 0,
            h: 0,
            a: 255,
        };
        let black = Color::Oklch {
            l: 0,
            c: 0,
            h: 0,
            a: 255,
        };
        let (r, g, b, _) = white.to_srgb();
        assert!(
            r > 250 && g > 250 && b > 250,
            "L=1 should be near white, got {r},{g},{b}"
        );
        assert_eq!(black.to_srgb(), (0, 0, 0, 255));
    }

    #[test]
    fn oklch_is_always_in_gamut() {
        // Even an out-of-gamut request clamps to valid bytes (never panics, never overflows).
        let neon = Color::Oklch {
            l: 700,
            c: 400,
            h: 1450,
            a: 255,
        };
        let (r, g, b, a) = neon.to_srgb();
        let _ = (r, g, b, a); // u8 by construction; the point is no panic / no overflow
    }

    #[test]
    fn token_keys_are_namespaced_and_closed() {
        let keys = token_keys();
        assert!(keys.contains(&"accent.base"));
        assert!(keys.contains(&"oled"));
        assert_eq!(keys.len(), 15);
    }

    #[test]
    fn unknown_palette_key_is_rejected() {
        // deny_unknown_fields: a typo'd token must fail loud, not silently drop.
        let r: Result<PaletteOverride, _> =
            serde_json::from_str(r#"{ "canvas2": { "space": "srgb", "r": 0, "g": 0, "b": 0 } }"#);
        assert!(r.is_err());
    }
}
