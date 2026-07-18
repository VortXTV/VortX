//! vortx-streaming-server: the native Rust replacement for the bundled
//! Stremio server.js (nodejs-mobile), speaking the exact HTTP contract the
//! VortX app + libmpv depend on. The captured contract lives in
//! contract/GOLDEN.md; the golden field names in contract/stats-fields.json.
//!
//! Torrent playback is this server's ONLY job (direct/debrid/HLS streams play
//! client-side): /settings, /{hash}/create, /{hash}/{fileIdx},
//! /{hash}/stats.json, /{hash}/remove, and the /proxy HLS rewriter.

pub mod backend;
pub mod contract;
pub mod hls;
pub mod http;
pub mod range;
pub mod rqbit;
pub mod settings;
pub mod stub;

use std::path::Path;

pub use http::{build_proxy_client, build_router, AppState, ProxyState};

/// Write the bare port number to the port file the app's `NodeServer`
/// discovery reads (`stremio-server.port`, contents just the integer).
pub fn write_port_file(path: &Path, port: u16) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, port.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn port_file_holds_the_bare_number() {
        let dir = std::env::temp_dir().join(format!("vortx-ss-portfile-{}", std::process::id()));
        let path = dir.join("stremio-server.port");
        write_port_file(&path, 11470).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "11470");
        std::fs::remove_dir_all(&dir).ok();
    }
}
