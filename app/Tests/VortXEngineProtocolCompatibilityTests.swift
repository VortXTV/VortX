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
        precondition(decodedLegacy.initPublished == nil)
        precondition(decodedLegacy.failed == nil)
        precondition(decodedLegacy.audioTracks == nil)
        precondition(decodedLegacy.selectedAudioStreamIndex == nil)
        precondition(decodedLegacy.subtitleTracks == nil)

        let legacyRequest = Data(
            """
            {
              "input": "https://media.invalid/title.mkv",
              "mode": "plain",
              "startAtSeconds": 42,
              "requestFullTimeline": true
            }
            """.utf8)
        let decodedLegacyRequest = try JSONDecoder().decode(
            VortXEngineProtocol.SessionRequest.self,
            from: legacyRequest)
        precondition(decodedLegacyRequest.selectedAudioStreamIndex == nil)

        let legacyPreInit = Data(
            """
            {
              "healthy": false,
              "durationSeconds": 0,
              "timelineOriginSeconds": 0,
              "frameRate": 0,
              "chapters": [],
              "producedSegments": 0,
              "producedBytes": 0,
              "ended": false,
              "signalingPublished": false,
              "dolbyVision": false,
              "width": 0,
              "height": 0,
              "producedEdgeSeconds": 0
            }
            """.utf8)
        let decodedLegacyPreInit = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: legacyPreInit)
        precondition(decodedLegacyPreInit.healthy == false)
        precondition(decodedLegacyPreInit.initPublished == nil)
        precondition(decodedLegacyPreInit.failed == nil)

        let current = VortXEngineProtocol.SessionStatus(
            healthy: true,
            durationSeconds: 3600,
            timelineOriginSeconds: 0,
            frameRate: 23.976,
            chapters: [],
            producedSegments: 2,
            producedBytes: 1024,
            ended: false,
            initPublished: true,
            failed: false,
            signalingPublished: true,
            dolbyVision: true,
            width: 3840,
            height: 2160,
            bandwidth: 48_000_000,
            videoRange: "PQ",
            supportsHDRFallback: true,
            audioTracks: [
                .init(sourceIndex: 4, codec: "eac3", channels: 6,
                      language: "eng", title: "Main", isAtmosJOC: true)
            ],
            selectedAudioStreamIndex: 4,
            subtitleTracks: [
                .init(sourceIndex: 7, codec: "subrip", language: "eng",
                      title: "English SDH", isForced: false, delivery: .webVTT,
                      renditionIndex: 0, unavailableReason: nil),
                .init(sourceIndex: 8, codec: "hdmv_pgs_subtitle", language: "eng",
                      title: "English PGS", isForced: false, delivery: .bitmapUnavailable,
                      renditionIndex: nil,
                      unavailableReason: "Image subtitle is not available in AVPlayer")
            ],
            producedEdgeSeconds: 12)
        let roundTrip = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: JSONEncoder().encode(current))
        precondition(roundTrip == current)

        var legacyStatusObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)) as! [String: Any]
        legacyStatusObject.removeValue(forKey: "subtitleTracks")
        if var audio = legacyStatusObject["audioTracks"] as? [[String: Any]] {
            for index in audio.indices { audio[index].removeValue(forKey: "delivery") }
            legacyStatusObject["audioTracks"] = audio
        }
        let decodedLegacyStatus = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: JSONSerialization.data(withJSONObject: legacyStatusObject))
        precondition(decodedLegacyStatus.subtitleTracks == nil)
        precondition(decodedLegacyStatus.audioTracks?.first?.delivery == nil)

        print("VortXEngineProtocolCompatibilityTests: ALL PASS")
    }
}
