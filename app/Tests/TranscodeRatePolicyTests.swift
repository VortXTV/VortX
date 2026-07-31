// Executable harness for the #148 audio-transcode encoder-rate decision.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/transcode-rate-policy-test \
//     app/Sources/Player/AudioTranscodePolicy.swift \
//     app/Tests/TranscodeRatePolicyTests.swift && /tmp/transcode-rate-policy-test
//
// This suite CALLS the production decision (the DVPlaybackContractTests pattern). The property under test is the
// #148 root cause: FFmpeg's AAC encoder rejects any sample rate outside the 13-entry MPEG-4 table (proven against
// the shipped libavcodec 62.12.102: avcodec_open2 rc=-22 at 192 kHz, rc=0 at every table rate), so every rate this
// policy returns MUST be a table rate, and hi-res lossless sources (192/176.4 kHz TrueHD, DTS-HD MA) must snap to
// a supported rate instead of killing the transcoder init (the "TrueHD reverts to HDR" field report).

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@MainActor @main
enum TranscodeRatePolicyTests {
    static func main() { run() }
}

@MainActor func run() {

typealias P = VortXAudioTranscodePolicy

// MARK: - The #148 hole: hi-res lossless rates must open, not demote

check("aac: 192 kHz TrueHD snaps to 96 kHz (integer 2:1 resample)",
      P.encoderSampleRate(source: 192_000, isEAC3: false) == 96_000)
check("aac: 176.4 kHz snaps to 88.2 kHz (stays in the 44.1 k family, not 96 k)",
      P.encoderSampleRate(source: 176_400, isEAC3: false) == 88_200)

// MARK: - Table rates pass through untouched (the pre-fix behavior for every source that already worked)

for rate in P.aacSupportedRates {
    check("aac: table rate \(rate) passes through",
          P.encoderSampleRate(source: rate, isEAC3: false) == rate)
}

// MARK: - Every returned rate is a table rate (the encoder-open invariant)

let probes: [Int32] = [1, 7_350, 8_000, 22_050, 44_100, 46_875, 48_000, 64_000,
                       88_200, 96_000, 176_400, 192_000, 384_000, 2_822_400]
for source in probes {
    check("aac: source \(source) resolves to an encoder-supported rate",
          P.aacSupportedRates.contains(P.encoderSampleRate(source: source, isEAC3: false)))
}

// MARK: - Snap direction

check("aac: an unsupported mid rate snaps DOWN (46875 -> 44100)",
      P.encoderSampleRate(source: 46_875, isEAC3: false) == 44_100)
check("aac: below the whole table snaps UP to the floor (4000 -> 7350)",
      P.encoderSampleRate(source: 4_000, isEAC3: false) == 7_350)
check("aac: non-positive source takes the 48 kHz default",
      P.encoderSampleRate(source: 0, isEAC3: false) == 48_000
          && P.encoderSampleRate(source: -1, isEAC3: false) == 48_000)

// MARK: - EAC3 lane (dormant until an eac3 encoder ships; must keep the shipped 48 kHz cap shape)

check("eac3: hi-res caps at 48 kHz (192k -> 48k, the shipped min() behavior)",
      P.encoderSampleRate(source: 192_000, isEAC3: true) == 48_000)
check("eac3: 44.1 kHz passes through",
      P.encoderSampleRate(source: 44_100, isEAC3: true) == 44_100)
for source in probes {
    check("eac3: source \(source) resolves to an encoder-supported rate",
          P.eac3SupportedRates.contains(P.encoderSampleRate(source: source, isEAC3: true)))
}

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
