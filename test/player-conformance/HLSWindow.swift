import Foundation

// Minimal verbatim mirror of the two Foundation-only value types consumed by
// DVPlaybackPolicy.swift. Compiling the full VortXRemuxBuffer.swift would pull
// app-only dependencies into this standalone harness.

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

struct VortXHLSWindow: Equatable, Sendable {
    let segments: [VortXHLSSegment]

    var mediaSequence: Int { segments.first?.id ?? 0 }

    func segment(id: Int) -> VortXHLSSegment? {
        segments.first { $0.id == id }
    }
}
