// Focused source contract for produced-vs-source audio channel truth.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/AudioChannelTruthContractTests.swift -o /tmp/audio-channel-truth-contract \
//     && /tmp/audio-channel-truth-contract

import Foundation

@main
enum AudioChannelTruthContractTests {
    static func main() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let app = tests.deletingLastPathComponent()
        let player = app.appendingPathComponent("Sources/Player")

        let protocolSource = try source(app.appendingPathComponent("SourcesShared/VortXEngineProtocol.swift"))
        let remux = try source(player.appendingPathComponent("VortXMKVRemuxStream.swift"))
        let engine = try source(player.appendingPathComponent("AVPlayerEngine.swift"))
        let mpvEngine = try source(player.appendingPathComponent("MPVMetalViewController.swift"))
        let engineContract = try source(player.appendingPathComponent("PlayerEngine.swift"))
        let playerScreen = try source(app.appendingPathComponent("Sources/PlayerScreen.swift"))
        let tvPlayer = try source(app.appendingPathComponent("SourcesTV/TVPlayerView.swift"))

        require(
            protocolSource,
            containsInOrder: [
                "let channels: Int",
                "let outputChannels: Int?",
                "delivery: AudioDelivery? = nil, outputCodec: String? = nil,",
                "outputChannels: Int? = nil)",
                "self.channels = channels",
                "self.outputChannels = outputChannels",
                "var activeChannels: Int?",
                "if let outputChannels, outputChannels > 0",
                "guard delivery != .transcode, channels > 0 else { return nil }",
            ],
            message: "wire model must preserve source channels and expose safe optional produced-channel truth")

        let publication = section(
            remux,
            from: "private func publishSelectedAudioOutputCodec(",
            to: "// Optional rendition state.")
        require(
            publication,
            containsInOrder: [
                "sourceIndex == _selectedSourceAudioIndex",
                "let track = _sourceAudioTracks[selected]",
                "channels: track.channels",
                "outputCodec: Self.codecName(outputCodecID)",
                "outputChannels: outputChannels > 0 ? outputChannels : nil",
            ],
            message: "selected output publication must retain source inventory and publish produced channels")

        let transcodeSetup = section(
            remux,
            from: "if transcodeActive, i == transcodeAudioIn {",
            to: "let cp = avcodec_parameters_copy(outStream.pointee.codecpar, par)")
        require(
            transcodeSetup,
            containsInOrder: [
                "let outputParameters = outStream.pointee.codecpar.pointee",
                "publishSelectedAudioOutputCodec(",
                "outputCodecID: outputParameters.codec_id",
                "outputChannels: Int(outputParameters.ch_layout.nb_channels)",
            ],
            message: "transcode publication must use the produced codecpar channel count")

        let initReceipt = section(
            remux,
            from: "if let selectedSourceAudioIndex = _selectedSourceAudioIndex,",
            to: "hlsLock.unlock()")
        require(
            initReceipt,
            containsInOrder: [
                "usesDec3: track.activeCodec.lowercased() == \"eac3\"",
                "delivery: track.delivery",
                "outputCodec: track.outputCodec",
                "outputChannels: track.outputChannels",
            ],
            message: "JOC receipt reconstruction must preserve produced channel truth")

        let picker = section(
            engine,
            from: "private func sourceAudioMPVTracks()",
            to: "private func mountCurrentAudioReplacement(reason:")
        require(
            picker,
            containsInOrder: [
                "let codec = source.codec.uppercased()",
                "source.outputCodec.map { \" -> \\($0.uppercased())\" } ?? \" -> E-AC3/AAC\"",
                "source.outputChannels.flatMap { $0 > 0 ? \" \\($0)ch\" : nil } ?? \"\"",
                "let shape = \"\\(codec) \\(source.channels)ch",
            ],
            message: "picker must render source channels on the left and produced channels on the transcode output")

        let activeSummary = section(
            engine,
            from: "func mediaSummary()",
            to: "/// Load asset chapter markers")
        require(
            activeSummary,
            containsInOrder: [
                "audioChannels: selectedAudioChannels()",
                "return source.activeCodec.lowercased()",
                "return source.activeChannels ?? 0",
            ],
            message: "active AVPlayer metadata must use produced codec and produced channels")

        require(
            engineContract,
            containsInOrder: [
                "func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int)",
            ],
            message: "engine metadata contract must carry an explicit channel count")
        let mpvSummary = section(
            mpvEngine,
            from: "func mediaSummary()",
            to: "/// Persisted video-size mode")
        require(
            mpvSummary,
            containsInOrder: [
                "func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int)",
                "guard mpv != nil else { return (0, 0, \"\", 0) }",
                "getString(\"audio-codec-name\") ?? \"\", 0",
            ],
            message: "libmpv must keep produced output-channel truth unknown")

        let surfaces = [
            (
                name: "PlayerScreen",
                source: playerScreen,
                switchEnd: "/// AVPlayer-only START watchdog",
                sourceResetEnd: "/// Target-only latches move",
                episodeResetEnd: "/// Switch the playing source in place"
            ),
            (
                name: "TVPlayerView",
                source: tvPlayer,
                switchEnd: "/// Show a brief player toast",
                sourceResetEnd: "@discardableResult",
                episodeResetEnd: "/// Device-local resume"
            ),
        ]
        for surface in surfaces {
            require(
                surface.source,
                containsInOrder: [
                    "@State private var audioChannels = 0",
                    "audioChannels = summary?.audioChannels ?? 0",
                    "audioChannels > 0 ? \" \\(audioChannels)ch\" : \"\"",
                ],
                message: "both Apple player surfaces must render the active produced channel count")
            require(
                surface.source,
                containsInOrder: [
                    "private func clearCachedAudioOutputTruth()",
                    "audioCodec = \"\"",
                    "audioChannels = 0",
                    "metadataLine = computeMetadataLine()",
                ],
                message: "\(surface.name) must synchronously remove prior produced audio truth")

            let loadBoundary = section(
                surface.source,
                from: "private func loadIntoPlayer(",
                to: "private func startLoadTimeout()")
            require(
                loadBoundary,
                containsInOrder: [
                    "guard let player = coordinator.player else { return nil }",
                    "clearCachedAudioOutputTruth()",
                    "player.loadFile(",
                ],
                message: "\(surface.name) must clear cached audio truth before every admitted physical load")

            let demotion = section(
                surface.source,
                from: "private func demoteAVPlayerToMPV",
                to: "private func switchPlayerEngine")
            require(
                demotion,
                containsInOrder: [
                    "coordinator.player?.stop()",
                    "clearCachedAudioOutputTruth()",
                    "avEngineFailed = true",
                ],
                message: "\(surface.name) must clear AVPlayer output truth before demoting to libmpv")

            let manualSwitch = section(
                surface.source,
                from: "private func switchPlayerEngine",
                to: surface.switchEnd)
            require(
                manualSwitch,
                containsInOrder: [
                    "coordinator.player?.stop()",
                    "clearCachedAudioOutputTruth()",
                    "manualEngineAVPlayer = toAVPlayer",
                ],
                message: "\(surface.name) must clear prior output truth before a manual engine swap")

            let sourceReset = section(
                surface.source,
                from: "private func resetRuntimeForIssuedSourceSwitch",
                to: surface.sourceResetEnd)
            require(
                sourceReset,
                containsInOrder: [
                    "clearCachedAudioOutputTruth()",
                ],
                message: "\(surface.name) source replacement reset must clear prior output truth")

            let episodeReset = section(
                surface.source,
                from: "private func resetRuntimeForIssuedEpisode",
                to: surface.episodeResetEnd)
            require(
                episodeReset,
                containsInOrder: [
                    "clearCachedAudioOutputTruth()",
                ],
                message: "\(surface.name) episode replacement reset must clear prior output truth")

            requireMutationSensitive(
                sourceReset,
                deleting: "clearCachedAudioOutputTruth()",
                message: "\(surface.name) source-reset clear")
            requireMutationSensitive(
                episodeReset,
                deleting: "clearCachedAudioOutputTruth()",
                message: "\(surface.name) episode-reset clear")
        }

        print("AudioChannelTruthContractTests: ALL PASS")
    }

    private static func source(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func section(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            fatalError("missing source anchors: \(start) ... \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func require(
        _ source: String,
        containsInOrder needles: [String],
        message: String
    ) {
        var cursor = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
                fatalError("\(message): missing `\(needle)`")
            }
            cursor = range.upperBound
        }
    }

    private static func requireMutationSensitive(
        _ source: String,
        deleting needle: String,
        message: String
    ) {
        guard let range = source.range(of: needle) else {
            fatalError("\(message): live source is missing `\(needle)`")
        }
        var mutant = source
        mutant.removeSubrange(range)
        if mutant.contains(needle) {
            fatalError("\(message): deleting the intended seam still leaves a false-green match")
        }
    }
}
