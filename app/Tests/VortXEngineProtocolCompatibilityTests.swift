import Foundation

@main
enum VortXEngineProtocolCompatibilityTests {
    static func main() throws {
        let legacy = Data(
            """
            {
              "healthy": true,
              "durationSeconds": 3600,
              "timelineOriginSeconds": 0,
              "frameRate": 23.976,
              "chapters": [],
              "producedSegments": 2,
              "producedBytes": 1024,
              "ended": false,
              "signalingPublished": true,
              "dolbyVision": true,
              "width": 3840,
              "height": 2160,
              "producedEdgeSeconds": 12
            }
            """.utf8)

        let decodedLegacy = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: legacy)
        precondition(decodedLegacy.bandwidth == nil)
        precondition(decodedLegacy.videoRange == nil)
        precondition(decodedLegacy.supportsHDRFallback == nil)

        let current = VortXEngineProtocol.SessionStatus(
            healthy: true,
            durationSeconds: 3600,
            timelineOriginSeconds: 0,
            frameRate: 23.976,
            chapters: [],
            producedSegments: 2,
            producedBytes: 1024,
            ended: false,
            signalingPublished: true,
            dolbyVision: true,
            width: 3840,
            height: 2160,
            bandwidth: 48_000_000,
            videoRange: "PQ",
            supportsHDRFallback: true,
            producedEdgeSeconds: 12)
        let roundTrip = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: JSONEncoder().encode(current))
        precondition(roundTrip == current)

        print("VortXEngineProtocolCompatibilityTests: ALL PASS")
    }
}
