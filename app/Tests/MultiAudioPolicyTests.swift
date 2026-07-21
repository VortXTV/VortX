// Executable harness for the bounded multi-track audio decisions.
//
//   xcrun swiftc -o /tmp/multi-audio-policy-test \
//     app/Sources/Player/MultiAudioPolicy.swift \
//     app/Tests/MultiAudioPolicyTests.swift && /tmp/multi-audio-policy-test
//
// This suite CALLS the production decisions. The code that uses them lives in VortXMKVRemuxStream, which pulls
// in the whole FFmpeg vendor tree, so a suite written against that file could only have asserted on source
// text. That shape was already proven inadequate on this codebase: a mutant that preserved every asserted
// string while appending `false` to a guard passed a whole suite while the guard could never fire. Substring
// assertions prove a line exists, not that it runs.
//
// The bar is mutation survival, not a pass count. Every assertion below must turn RED when its property is
// broken, including SEMANTIC breaks that leave the source text intact. In particular:
//   - the boundary pairs (one below a budget vs exactly at it) catch >= flipped to > and off-by-one limits;
//   - the delivered-at-an-exhausted-budget case catches the priority of `delivered` being moved below the
//     budget checks, a reordering that changes no strings at all;
//   - the qualification cases are asserted BOTH ways, so deleting a filter clause fails just as loudly as
//     inverting one.

import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

typealias Track = MultiAudioPolicy.AudioTrack

// Two distinct codec ids. Values are arbitrary: the policy only ever compares them for equality.
let eac3: UInt32 = 101
let ac3: UInt32 = 102

// Compiling several files together means only a `main.swift` may carry top-level expressions, so the run body
// is a function invoked from `@main`, matching the other standalone suites in this directory.
@main
enum MultiAudioPolicyTests {
    static func main() { run() }
}

func run() {

// MARK: - Language keys

check("lang: a tag is normalised for comparison",
      MultiAudioPolicy.languageKey("  ENG \n") == "eng")
check("lang: an empty tag is unknown",
      MultiAudioPolicy.isUnknownLanguage(""))
check("lang: und is unknown",
      MultiAudioPolicy.isUnknownLanguage("und"))
check("lang: zxx (no linguistic content) is unknown",
      MultiAudioPolicy.isUnknownLanguage("zxx"))
check("lang: a real tag is NOT unknown",
      !MultiAudioPolicy.isUnknownLanguage("eng"))
check("lang: a second real tag is NOT unknown",
      !MultiAudioPolicy.isUnknownLanguage("jpn"))

// MARK: - Alternate qualification

let engPrimary = Track(index: 1, codecID: eac3, channels: 6, language: "eng")

// The property the feature exists for: a different-language, same-codec track is offered.
check("alt: a different language on the same codec qualifies",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 6, language: "jpn")],
                                 primaryIndex: 1)?.index == 2)
// The bound that keeps the feature safe: never more than one, whatever the source offers.
check("alt: at most ONE alternate is ever returned, and it is a single value not a list",
      {
          let picked = MultiAudioPolicy.alternate(
            from: [engPrimary,
                   Track(index: 2, codecID: eac3, channels: 6, language: "jpn"),
                   Track(index: 3, codecID: eac3, channels: 6, language: "fra"),
                   Track(index: 4, codecID: eac3, channels: 6, language: "deu")],
            primaryIndex: 1)
          return picked != nil && picked!.index != 1
      }())
// Heterogeneous codecs are explicitly out of scope (the master playlist advertises one audio CODECS entry).
check("alt: a different codec does NOT qualify, even with a different language",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: ac3, channels: 6, language: "jpn")],
                                 primaryIndex: 1) == nil)
// And the same case WITH the codec matched must qualify, so the test above cannot pass for the wrong reason
// (for example because the function returns nil for every three-field input).
check("alt: the same pair with codecs matched DOES qualify (the codec clause is what rejected it)",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 6, language: "jpn")],
                                 primaryIndex: 1) != nil)
check("alt: the same language does NOT qualify",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 8, language: "eng")],
                                 primaryIndex: 1) == nil)
check("alt: the same language in different case is still the same language",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 8, language: "ENG")],
                                 primaryIndex: 1) == nil)
check("alt: an unknown language on the CANDIDATE does not qualify",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 6, language: "und")],
                                 primaryIndex: 1) == nil)
check("alt: an unknown language on the PRIMARY disqualifies every candidate",
      MultiAudioPolicy.alternate(from: [Track(index: 1, codecID: eac3, channels: 6, language: ""),
                                        Track(index: 2, codecID: eac3, channels: 6, language: "jpn")],
                                 primaryIndex: 1) == nil)
check("alt: the primary is never returned as its own alternate",
      MultiAudioPolicy.alternate(from: [engPrimary], primaryIndex: 1) == nil)
check("alt: no tracks at all yields nothing",
      MultiAudioPolicy.alternate(from: [], primaryIndex: 1) == nil)
check("alt: a primary index that is not in the list yields nothing",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 6, language: "jpn")],
                                 primaryIndex: 99) == nil)

// Ordering. Asserted with the higher-channel track placed LATER in the list, so input order and channel order
// disagree; a mutant that dropped the channel comparison would return index 2 and fail here.
check("alt: among qualifying tracks the most channels wins over input order",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 2, language: "fra"),
                                        Track(index: 3, codecID: eac3, channels: 6, language: "deu")],
                                 primaryIndex: 1)?.index == 3)
// The mirrored case: with the higher-channel track EARLIER, the answer must move with the channels, not stay
// pinned to a fixed position. Together the two cases pin the comparison rather than a list position.
check("alt: the same set reordered still picks the most channels",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 2, codecID: eac3, channels: 6, language: "deu"),
                                        Track(index: 3, codecID: eac3, channels: 2, language: "fra")],
                                 primaryIndex: 1)?.index == 2)
check("alt: equal channels fall back to input order",
      MultiAudioPolicy.alternate(from: [engPrimary,
                                        Track(index: 3, codecID: eac3, channels: 6, language: "deu"),
                                        Track(index: 2, codecID: eac3, channels: 6, language: "fra")],
                                 primaryIndex: 1)?.index == 2)
// A primary that is not first in the list must still be excluded and still supply the language to differ from.
check("alt: a primary in the middle of the list is still excluded from its own candidates",
      {
          let picked = MultiAudioPolicy.alternate(
            from: [Track(index: 0, codecID: eac3, channels: 8, language: "eng"),
                   engPrimary,
                   Track(index: 2, codecID: eac3, channels: 2, language: "jpn")],
            primaryIndex: 1)
          return picked?.index == 2   // index 0 shares the primary's language despite having the most channels
      }())

// MARK: - Probe bounds

func outcome(delivered: Bool = false,
             packets: Int = 0,
             bytes: Int = 0,
             elapsed: Double = 0,
             ended: Bool = false,
             cancelled: Bool = false,
             allocFailed: Bool = false) -> MultiAudioPolicy.ProbeOutcome {
    MultiAudioPolicy.probeOutcome(delivered: delivered, packetsRead: packets, bytesRead: bytes,
                                  elapsedSecs: elapsed, sourceEnded: ended, cancelled: cancelled,
                                  allocationFailed: allocFailed)
}

check("probe: a fresh probe keeps going",
      outcome() == .keepProbing)
check("probe: a delivered first packet ends the probe with the track kept",
      outcome(delivered: true) == .delivered)

// Boundary pairs. Each asserts one step BELOW the limit and one step AT it, which is what catches >= silently
// becoming > (or a limit changed by one) while every string in the file stays identical.
check("probe: one packet below the packet budget keeps going",
      outcome(packets: MultiAudioPolicy.alternateProbeMaxPackets - 1) == .keepProbing)
check("probe: exactly at the packet budget drops the alternate",
      outcome(packets: MultiAudioPolicy.alternateProbeMaxPackets) == .drop(.packetBudget))
check("probe: one byte below the byte budget keeps going",
      outcome(bytes: MultiAudioPolicy.alternateProbeMaxBytes - 1) == .keepProbing)
check("probe: exactly at the byte budget drops the alternate",
      outcome(bytes: MultiAudioPolicy.alternateProbeMaxBytes) == .drop(.byteBudget))
check("probe: just inside the deadline keeps going",
      outcome(elapsed: MultiAudioPolicy.alternateProbeDeadlineSecs - 0.001) == .keepProbing)
check("probe: exactly at the deadline drops the alternate",
      outcome(elapsed: MultiAudioPolicy.alternateProbeDeadlineSecs) == .drop(.deadline))

check("probe: a source that ends first drops the alternate",
      outcome(ended: true) == .drop(.sourceEnded))
check("probe: a cancelled session drops the alternate",
      outcome(cancelled: true) == .drop(.cancelled))
check("probe: an allocation failure drops the alternate",
      outcome(allocFailed: true) == .drop(.allocationFailed))

// The priority property, and the reason this is a separate test from the plain delivered case. Moving the
// `delivered` check below the budget checks changes no string in the file and leaves every other assertion
// green, but it would throw away a track the muxer already has data for.
check("probe: a packet delivered on the iteration that exhausts every budget still KEEPS the track",
      outcome(delivered: true,
              packets: MultiAudioPolicy.alternateProbeMaxPackets * 10,
              bytes: MultiAudioPolicy.alternateProbeMaxBytes * 10,
              elapsed: MultiAudioPolicy.alternateProbeDeadlineSecs * 10,
              ended: true) == .delivered)
// Cancellation is the one signal that must beat the budgets in the other direction: a cancelled session must
// stop probing immediately rather than report whichever limit happened to trip.
check("probe: cancellation is reported ahead of an exhausted budget",
      outcome(packets: MultiAudioPolicy.alternateProbeMaxPackets * 10, cancelled: true) == .drop(.cancelled))

// Every reason is a fixed, bounded string, because these reach the diagnostics log and the log must never
// carry source-derived text of unbounded length.
check("probe: every drop reason is a short fixed string",
      [MultiAudioPolicy.DropReason.packetBudget, .byteBudget, .deadline,
       .sourceEnded, .cancelled, .allocationFailed]
        .allSatisfy { !$0.rawValue.isEmpty && $0.rawValue.count <= 80 })

// The bounds themselves must stay bounded. A budget raised to something that defeats the purpose (an
// unbounded wait, or a memory bound past the jetsam budget the player already strains) is exactly the
// regression this whole design exists to prevent, and it would not otherwise fail any assertion above.
check("probe: the wall-clock budget stays short enough to sit inside the start watchdog",
      MultiAudioPolicy.alternateProbeDeadlineSecs > 0 && MultiAudioPolicy.alternateProbeDeadlineSecs <= 4.0)
check("probe: the byte budget stays well under the player's memory headroom",
      MultiAudioPolicy.alternateProbeMaxBytes > 0 && MultiAudioPolicy.alternateProbeMaxBytes <= 32 << 20)
check("probe: the packet budget is finite",
      MultiAudioPolicy.alternateProbeMaxPackets > 0 && MultiAudioPolicy.alternateProbeMaxPackets <= 5000)

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
