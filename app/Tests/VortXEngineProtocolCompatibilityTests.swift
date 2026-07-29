import Foundation

/// The immediately preceding client shape. Decoding a current row through it proves the additive output-channel
/// field remains forward-compatible: synthesized Decodable must ignore that unknown key.
private struct PreviousAudioTrack: Decodable {
    let sourceIndex: Int
    let codec: String
    let outputCodec: String?
    let channels: Int
    let language: String
    let title: String
    let isAtmosJOC: Bool
    let delivery: VortXEngineProtocol.AudioDelivery?
}

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
                .init(sourceIndex: 4, codec: "truehd", channels: 8,
                      language: "eng", title: "Main", isAtmosJOC: false,
                      delivery: .transcode, outputCodec: "eac3", outputChannels: 6),
                .init(sourceIndex: 5, codec: "ac3", channels: 6,
                      language: "eng", title: "Compatibility", isAtmosJOC: false,
                      delivery: .streamCopy, outputCodec: "ac3", outputChannels: 6)
            ],
            selectedAudioStreamIndex: 4,
            subtitleTracks: [
                .init(sourceIndex: 7, codec: "subrip", language: "eng",
                      title: "English SDH", isForced: false, delivery: .webVTT,
                      renditionIndex: 0, unavailableReason: nil,
                      unavailableKind: nil),
                .init(sourceIndex: 8, codec: "hdmv_pgs_subtitle", language: "eng",
                      title: "English PGS", isForced: false, delivery: .bitmapUnavailable,
                      renditionIndex: nil,
                      unavailableReason: "Image subtitle is not available in AVPlayer",
                      unavailableKind: .bitmap),
                .init(sourceIndex: 9, codec: "realtext", language: "eng",
                      title: "Legacy text", isForced: false, delivery: .bitmapUnavailable,
                      renditionIndex: nil,
                      unavailableReason: "REALTEXT subtitle is not supported in AVPlayer",
                      unavailableKind: .unsupported)
            ],
            producedEdgeSeconds: 12)
        let roundTrip = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: JSONEncoder().encode(current))
        precondition(roundTrip == current)
        precondition(roundTrip.audioTracks?[0].codec == "truehd")
        precondition(roundTrip.audioTracks?[0].activeCodec == "eac3")
        precondition(roundTrip.audioTracks?[0].channels == 8)
        precondition(roundTrip.audioTracks?[0].outputChannels == 6)
        precondition(roundTrip.audioTracks?[0].activeChannels == 6)
        precondition(roundTrip.audioTracks?[1].codec == "ac3")
        precondition(roundTrip.audioTracks?[1].activeCodec == "ac3")
        precondition(roundTrip.subtitleTracks?[0].resolvedUnavailableKind == nil)
        precondition(roundTrip.subtitleTracks?[1].unavailableKind == .bitmap)
        precondition(roundTrip.subtitleTracks?[1].resolvedUnavailableKind == .bitmap)
        precondition(roundTrip.subtitleTracks?[2].unavailableKind == .unsupported)
        precondition(roundTrip.subtitleTracks?[2].resolvedUnavailableKind == .unsupported)

        let modernUnavailableTracks = Array(current.subtitleTracks!.dropFirst())
        for (expectedKind, track) in zip(
            [VortXEngineProtocol.SubtitleUnavailableKind.bitmap, .unsupported],
            modernUnavailableTracks
        ) {
            let encoded = try JSONEncoder().encode(track)
            let decoded = try JSONDecoder().decode(
                VortXEngineProtocol.SubtitleTrack.self,
                from: encoded)
            precondition(decoded.unavailableKind == expectedKind)
            precondition(decoded.resolvedUnavailableKind == expectedKind)

            var legacyObject = try JSONSerialization.jsonObject(
                with: encoded) as! [String: Any]
            legacyObject.removeValue(forKey: "unavailableKind")
            precondition(legacyObject["delivery"] as? String == "bitmapUnavailable")
            let decodedLegacyTrack = try JSONDecoder().decode(
                VortXEngineProtocol.SubtitleTrack.self,
                from: JSONSerialization.data(withJSONObject: legacyObject))
            precondition(decodedLegacyTrack.unavailableKind == nil)
            precondition(decodedLegacyTrack.resolvedUnavailableKind == .bitmap)
        }
        precondition(roundTrip.audioTracks?[1].channels == 6)
        precondition(roundTrip.audioTracks?[1].activeChannels == 6)
        let previousClientRow = try JSONDecoder().decode(
            PreviousAudioTrack.self,
            from: JSONEncoder().encode(current.audioTracks![0]))
        precondition(previousClientRow.sourceIndex == 4)
        precondition(previousClientRow.codec == "truehd")
        precondition(previousClientRow.outputCodec == "eac3")
        precondition(previousClientRow.channels == 8)
        precondition(previousClientRow.language == "eng")
        precondition(previousClientRow.title == "Main")
        precondition(previousClientRow.isAtmosJOC == false)
        precondition(previousClientRow.delivery == .transcode)

        // A host from the immediately preceding protocol revision can identify a transcode and its output codec
        // without knowing the produced channel count. Falling back to the 7.1 source count would be a false active
        // claim, so the new client leaves that one fact unknown until a current host supplies it.
        var priorTranscodeObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)) as! [String: Any]
        if var audio = priorTranscodeObject["audioTracks"] as? [[String: Any]] {
            audio[0].removeValue(forKey: "outputChannels")
            priorTranscodeObject["audioTracks"] = audio
        }
        let decodedPriorTranscode = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: JSONSerialization.data(withJSONObject: priorTranscodeObject))
        precondition(decodedPriorTranscode.audioTracks?.first?.delivery == .transcode)
        precondition(decodedPriorTranscode.audioTracks?.first?.outputCodec == "eac3")
        precondition(decodedPriorTranscode.audioTracks?.first?.outputChannels == nil)
        precondition(decodedPriorTranscode.audioTracks?.first?.activeChannels == nil)

        var legacyStatusObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)) as! [String: Any]
        legacyStatusObject.removeValue(forKey: "subtitleTracks")
        if var audio = legacyStatusObject["audioTracks"] as? [[String: Any]] {
            for index in audio.indices {
                audio[index].removeValue(forKey: "delivery")
                audio[index].removeValue(forKey: "outputCodec")
                audio[index].removeValue(forKey: "outputChannels")
            }
            legacyStatusObject["audioTracks"] = audio
        }
        let decodedLegacyStatus = try JSONDecoder().decode(
            VortXEngineProtocol.SessionStatus.self,
            from: JSONSerialization.data(withJSONObject: legacyStatusObject))
        precondition(decodedLegacyStatus.subtitleTracks == nil)
        precondition(decodedLegacyStatus.audioTracks?.first?.delivery == nil)
        precondition(decodedLegacyStatus.audioTracks?.first?.outputCodec == nil)
        precondition(decodedLegacyStatus.audioTracks?.first?.activeCodec == "truehd")
        precondition(decodedLegacyStatus.audioTracks?.first?.outputChannels == nil)
        precondition(decodedLegacyStatus.audioTracks?.first?.activeChannels == 8)

        print("VortXEngineProtocolCompatibilityTests: ALL PASS")
    }
}
