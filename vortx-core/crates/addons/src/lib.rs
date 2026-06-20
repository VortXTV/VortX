//! # vortx-addons
//!
//! The installed-add-on COLLECTION and the capability ROUTER that sit on top of [`vortx-protocol`].
//!
//! Given the user's installed add-ons, the router answers "which add-ons can serve this request?"
//! by reusing each manifest's [`vortx_protocol::Manifest::supports`] check, in install (priority)
//! order. This is the routing the web client does today (resourceNames / supportsResource /
//! fetchStreams) lifted into pure, testable Rust that every VortX surface can share.
//!
//! Because routing is just the protocol capability check, ANY Stremio-protocol add-on plugs in
//! unchanged (Cinemeta, Torrentio, AIOStreams, Comet, MediaFusion, ...). Non-protocol sources
//! (Nuvio JS scrapers, Eclipse music) are normalised onto the same manifest shape by the adapters
//! crate (a later chunk), so they install into this same collection and route the same way.

mod collection;
mod router;

pub use collection::{AddonCollection, AddonFlags, InstalledAddon};
pub use router::CatalogRef;
