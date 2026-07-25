import Foundation

// =============================================================================
// Standalone-compilation stubs, same shape as the sibling harness's
// test/dv-rendition-stall/Stubs.swift.
//
// WHY THIS FILE EXISTS AT ALL: the harness compiles the REAL product decision
// files (see the PRODUCT SYMBOL DEPENDENCIES block in README.md). Two of them -
// `DVPlaybackPolicy.swift` (for `mediaPlaylistLines` and the startup floor) and
// `VortXRemuxBuffer.swift` (for `VortXHLSWindow` / `VortXHLSSegment`, which
// DVPlaybackPolicy's own signatures now require) - reach for exactly two app-wide
// singletons. Stubbing only those two members is what keeps the harness compiling
// the shipping decision code instead of a copy of it.
//
// Only the exact members the compiled production files read are provided. If a
// product file starts reading something else, the harness FAILS TO COMPILE and the
// runner reports that as INFRA (exit 3) with the compiler error, never as a
// product RED.
// =============================================================================

struct RemoteConfig {
    struct Snapshot {
        /// Mirrors `RemoteConfigDefaults.dvRemuxWindowMiB` (SourcesShared/RemoteConfig.swift:48).
        let dvRemuxWindowMiB: Int
        func isFeatureOn(_ name: String, default def: Bool) -> Bool { def }
    }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) {}
}
