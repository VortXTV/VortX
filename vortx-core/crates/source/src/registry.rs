//! The source registry: the ordered, idempotent set of installed sources, and the routing that, given a
//! request, returns the heterogeneous sources that can answer it, in priority order. This is the fusion
//! pipeline's front door (query all matching, then dedup/rank/emit happen in the engine phase).

use crate::request::ResourceRequest;
use crate::source::{Source, SourceKind};

/// The installed sources. Install order is priority order.
#[derive(Default)]
pub struct SourceRegistry {
    sources: Vec<Box<dyn Source>>,
}

impl SourceRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Install a source. Idempotent by `id()`: re-installing replaces in place (keeping its priority
    /// position), mirroring `AddonCollection`.
    pub fn install(&mut self, source: Box<dyn Source>) {
        if let Some(slot) = self.sources.iter_mut().find(|s| s.id() == source.id()) {
            *slot = source;
        } else {
            self.sources.push(source);
        }
    }

    /// Remove a source by id. Returns true if one was removed.
    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.sources.len();
        self.sources.retain(|s| s.id() != id);
        self.sources.len() != before
    }

    /// The source with this id, if installed.
    pub fn get(&self, id: &str) -> Option<&dyn Source> {
        self.sources
            .iter()
            .find(|s| s.id() == id)
            .map(|s| s.as_ref())
    }

    /// All installed sources of a kind, in priority order.
    pub fn by_kind(&self, kind: SourceKind) -> Vec<&dyn Source> {
        self.sources
            .iter()
            .filter(|s| s.kind() == kind)
            .map(|s| s.as_ref())
            .collect()
    }

    /// The sources that can answer `req`: they declare the requested resource capability AND pass the
    /// cheap `supports()` id-space gate. Returned in install (priority) order.
    pub fn resolve(&self, req: &ResourceRequest) -> Vec<&dyn Source> {
        self.sources
            .iter()
            .filter(|s| s.capabilities().contains(&req.kind) && s.supports(req))
            .map(|s| s.as_ref())
            .collect()
    }

    pub fn len(&self) -> usize {
        self.sources.len()
    }

    pub fn is_empty(&self) -> bool {
        self.sources.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::{ResourceKind, ResourceRequest};
    use crate::SourceError;
    use vortx_protocol::Stream;

    struct StubSource {
        id: String,
        kind: SourceKind,
        caps: Vec<ResourceKind>,
        supports_all: bool,
        fail: bool,
    }

    impl Source for StubSource {
        fn id(&self) -> &str {
            &self.id
        }
        fn kind(&self) -> SourceKind {
            self.kind
        }
        fn capabilities(&self) -> &[ResourceKind] {
            &self.caps
        }
        fn supports(&self, _req: &ResourceRequest) -> bool {
            self.supports_all
        }
        fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
            if self.fail {
                Err(SourceError::Network("boom".into()))
            } else {
                Ok(vec![])
            }
        }
    }

    fn stub(
        id: &str,
        kind: SourceKind,
        caps: Vec<ResourceKind>,
        supports_all: bool,
    ) -> Box<dyn Source> {
        Box::new(StubSource {
            id: id.to_string(),
            kind,
            caps,
            supports_all,
            fail: false,
        })
    }

    #[test]
    fn install_is_idempotent_by_id() {
        let mut r = SourceRegistry::new();
        r.install(stub(
            "a",
            SourceKind::StremioAddon,
            vec![ResourceKind::Stream],
            true,
        ));
        r.install(stub(
            "a",
            SourceKind::StremioAddon,
            vec![ResourceKind::Stream],
            true,
        ));
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn resolve_filters_by_capability_and_supports_in_order() {
        let mut r = SourceRegistry::new();
        r.install(stub(
            "meta-only",
            SourceKind::StremioAddon,
            vec![ResourceKind::Meta],
            true,
        ));
        r.install(stub(
            "stream-no",
            SourceKind::NuvioProvider,
            vec![ResourceKind::Stream],
            false,
        ));
        r.install(stub(
            "stream-yes",
            SourceKind::StremioAddon,
            vec![ResourceKind::Stream],
            true,
        ));
        let req = ResourceRequest::new(ResourceKind::Stream, "movie", "tt1");
        let hits = r.resolve(&req);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id(), "stream-yes"); // meta-only lacks the cap; stream-no fails supports
    }

    #[test]
    fn by_kind_filters() {
        let mut r = SourceRegistry::new();
        r.install(stub("a", SourceKind::StremioAddon, vec![], true));
        r.install(stub("b", SourceKind::NuvioProvider, vec![], true));
        assert_eq!(r.by_kind(SourceKind::NuvioProvider).len(), 1);
        assert_eq!(r.by_kind(SourceKind::NuvioProvider)[0].id(), "b");
    }

    #[test]
    fn remove_and_get() {
        let mut r = SourceRegistry::new();
        r.install(stub("a", SourceKind::StremioAddon, vec![], true));
        assert!(r.get("a").is_some());
        assert!(r.remove("a"));
        assert!(!r.remove("a"));
        assert!(r.get("a").is_none());
    }

    #[test]
    fn a_failing_source_does_not_poison_the_sweep() {
        let mut r = SourceRegistry::new();
        r.install(Box::new(StubSource {
            id: "bad".into(),
            kind: SourceKind::Scraper,
            caps: vec![ResourceKind::Stream],
            supports_all: true,
            fail: true,
        }));
        r.install(stub(
            "good",
            SourceKind::StremioAddon,
            vec![ResourceKind::Stream],
            true,
        ));
        let req = ResourceRequest::new(ResourceKind::Stream, "movie", "tt1");
        // resolve() just lists the sources; calling resolve on each isolates failures.
        let hits = r.resolve(&req);
        assert_eq!(hits.len(), 2);
        let outcomes: Vec<_> = hits
            .iter()
            .map(|s| s.resolve(&req).unwrap_or_default())
            .collect();
        assert_eq!(outcomes.len(), 2); // the failing source yields [], never panics
    }
}
