import Foundation

// =============================================================================
// Minimal mirror of the two Foundation-only value types the shipped
// `DVPlaybackPolicy` depends on: `VortXHLSSegment` and `VortXHLSWindow`, both
// declared in `app/Sources/Player/VortXRemuxBuffer.swift`.
//
// That source file also carries the ~3800-line remux buffer / spool machinery
// which pulls in app-only types (e.g. `RemoteConfig`), so it cannot be compiled
// into this standalone harness. These two structs are pure value types with no
// such dependency, so the harness mirrors them verbatim. That keeps
// `DVPlaybackPolicy.swift` (which the harness DOES compile) buildable against the
// real playlist API, `mediaPlaylistLines(window:ended:targetDuration:mapURI:)`,
// with no change to the shipped policy.
//
// Keep in sync with VortXRemuxBuffer.swift if either type's shape changes.
// =============================================================================

/// Mirror of `VortXHLSSegment` (VortXRemuxBuffer.swift). One published fMP4 media
/// segment; `id` is absolute for the session. Only `id` and `duration` reach the
/// playlist text the harness renders, but the full initializer is mirrored so
/// construction matches the shipped type exactly.
struct VortXHLSSegment: Equatable, Sendable {
    let id: Int
    let byteOffset: Int
    let byteLength: Int
    let start: Double
    let duration: Double

    init(id: Int, byteOffset: Int, byteLength: Int, start: Double = 0, duration: Double) {
        self.id = id
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.start = start
        self.duration = duration
    }

    var end: Double { start + duration }
}

/// Mirror of `VortXHLSWindow` (VortXRemuxBuffer.swift). One immutable view of the
/// media bytes the server can advertise; `mediaSequence` is the first resident
/// segment's absolute id.
struct VortXHLSWindow: Equatable, Sendable {
    let segments: [VortXHLSSegment]

    var mediaSequence: Int { segments.first?.id ?? 0 }

    func segment(id: Int) -> VortXHLSSegment? {
        segments.first { $0.id == id }
    }
}
