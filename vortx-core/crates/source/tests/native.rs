//! Cross-language conformance + property tests for the NativeVortx first-class source: registry routing
//! (supports) and the host fetch plan (plan URL) over a vortx-source/1 manifest. The conformance suite pins
//! the gating decisions + the exact fetch URLs so a native source resolves identically across platforms.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_source::{NativeVortxSource, ResourceKind, ResourceRequest, Source, VortxAddonManifest};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    manifest: VortxAddonManifest,
    requests: Vec<Req>,
}

#[derive(Deserialize)]
struct Req {
    kind: ResourceKind,
    #[serde(rename = "type")]
    type_: String,
    id: String,
    supports: bool,
    #[serde(default)]
    url: Option<String>,
}

const SUITE: &str = include_str!("../conformance/native_vectors.json");

#[test]
fn native_source_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse native suite");
    assert!(suite.cases.len() >= 2);
    for case in &suite.cases {
        let source = NativeVortxSource::new(case.manifest.clone());
        for r in &case.requests {
            let req = ResourceRequest::new(r.kind, r.type_.clone(), r.id.clone());
            assert_eq!(
                source.supports(&req),
                r.supports,
                "supports drifted for {} / {} {} {}",
                case.name,
                r.type_,
                r.id,
                r.supports
            );
            let plan = source.plan(&req, 5000);
            match &r.url {
                Some(url) => {
                    let plan = plan.expect("a supported request must plan a fetch");
                    assert_eq!(&plan.url, url, "plan url drifted for {}", case.name);
                }
                None => assert!(plan.is_none(), "an unsupported request must not plan ({})", case.name),
            }
        }
    }
}

proptest! {
    // plan() is deterministic and supports() never panics on an arbitrary request; an unsupported request
    // never yields a plan (the orchestrator only fans out to sources that can answer).
    #[test]
    fn native_plan_is_deterministic_and_gated(
        type_ in "[a-z]{1,6}",
        id in "[a-z0-9:]{1,10}",
    ) {
        let mut m = VortxAddonManifest::native(
            "tv.vortx.native.prop",
            "1.0.0",
            "Prop",
            vortx_source::VortxTransport::StremioHttp {
                manifest_url: "https://prop.vortx.tv/manifest.vortx.json".into(),
            },
        );
        m.capabilities = vec![ResourceKind::Stream];
        m.types = vec!["movie".into()];
        m.id_prefixes = vec!["tt".into()];
        let source = NativeVortxSource::new(m);
        let req = ResourceRequest::new(ResourceKind::Stream, type_, id);

        let supported = source.supports(&req);
        let a = source.plan(&req, 5000);
        let b = source.plan(&req, 5000);
        prop_assert_eq!(&a, &b); // deterministic
        prop_assert_eq!(a.is_some(), supported); // a plan exists iff the request is supported
    }
}
