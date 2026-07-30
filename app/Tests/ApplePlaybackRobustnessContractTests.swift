// Focused executable contract for the three Apple playback robustness boundaries.
//
// Extract the dependency-free duration policy, then compile it with this harness:
//
//   sed -n '/^enum MPVDurationProbePolicy {/,/^\\/\\/ warning: metal API validation/p' \
//     app/Sources/Player/MPVMetalViewController.swift | sed '$d' \
//     > /tmp/apple-playback-robustness-policy.swift && \
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     /tmp/apple-playback-robustness-policy.swift \
//     app/Tests/ApplePlaybackRobustnessContractTests.swift \
//     -o /tmp/apple-playback-robustness-tests && \
//   /tmp/apple-playback-robustness-tests

import Foundation

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func section(in source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func ordered(_ needles: [String], in source: String) -> Bool {
    var lower = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: lower..<source.endIndex) else {
            return false
        }
        lower = range.upperBound
    }
    return true
}

private func compact(_ source: String) -> String {
    source.filter { !$0.isWhitespace }
}

@main
private enum ApplePlaybackRobustnessContractTests {
    @MainActor
    static func main() {
        check("duration: finite fractional seconds retain truncation semantics",
              MPVDurationProbePolicy.integerSeconds(123.9) == 123)
        check("duration: NaN is rejected", MPVDurationProbePolicy.integerSeconds(.nan) == nil)
        check("duration: infinity is rejected",
              MPVDurationProbePolicy.integerSeconds(.infinity) == nil)
        check("duration: huge finite input is rejected without trapping",
              MPVDurationProbePolicy.integerSeconds(.greatestFiniteMagnitude) == nil)
        check("duration: rounded Int.max overflow edge is rejected",
              MPVDurationProbePolicy.integerSeconds(Double(Int.max)) == nil)

        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "mpv": appRoot.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"),
            "episode": appRoot.appendingPathComponent("SourcesTV/TVEpisodePanel.swift"),
            "player": appRoot.appendingPathComponent("SourcesTV/TVPlayerView.swift"),
        ]
        let sources = paths.mapValues { try? String(contentsOf: $0, encoding: .utf8) }
        check("wiring: all governed sources are readable",
              sources.values.allSatisfy { $0 != nil })
        guard let mpv = sources["mpv"] ?? nil,
              let episode = sources["episode"] ?? nil,
              let player = sources["player"] ?? nil else {
            exit(1)
        }

        let duration = section(
            in: mpv,
            from: "case MPVProperty.duration:",
            to: "case MPVProperty.seekable:"
        ) ?? ""
        check("duration wiring: checked policy owns narrowing",
              duration.contains("MPVDurationProbePolicy.integerSeconds(value)"))
        check("duration wiring: raw Int(value) conversion is absent",
              !duration.contains("Int(value)"))

        let settle = section(
            in: episode,
            from: "for _ in 0 ..< 80 {",
            to: "let pin = SourcePinStore.shared.effectivePin"
        ) ?? ""
        check("episode settle: cancellation is checked before engine queries",
              ordered(
                [
                    "guard !Task.isCancelled else { return nil }",
                    "groups = core.streamGroups(forStreamId: v.id)",
                ],
                in: settle
              ))
        check("episode settle: cancelled sleep exits instead of spinning",
              compact(settle).contains(
                compact(
                    """
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return nil
                    }
                    """
                )
              ))
        check("episode settle: swallowed cancellation sleep is absent",
              !settle.contains("try? await Task.sleep"))
        check("episode settle: cancellation is rechecked before candidate resolution",
              settle.components(
                separatedBy: "guard !Task.isCancelled else { return nil }"
              ).count - 1 == 2)

        let recovery = section(
            in: player,
            from: "private func recoverFromStall()",
            to: "private func presentTerminalLoadFailure()"
        ) ?? ""
        check("stall reload: startup state resets before the reload",
              ordered(
                [
                    "hasStartedPlaying = false",
                    "loadIntoPlayer(curURL ?? url",
                ],
                in: recovery
              ))
        check("stall reload: bounded start watchdog arms after the reload",
              ordered(
                [
                    "loadIntoPlayer(curURL ?? url",
                    "startLoadTimeout()",
                ],
                in: recovery
              ))

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
