// Standalone executable for the REAL RemoteConfig validation matrix. VortX has no Xcode unit-test bundle, so
// this compiles the production RemoteConfig.swift with only the three surrounding app symbols stubbed:
//
//   xcrun swiftc -o /tmp/remote-config-validation-test \
//     app/SourcesShared/RemoteConfig.swift \
//     app/Tests/RemoteConfigValidationTests.swift && /tmp/remote-config-validation-test
//
// WHY IT EXISTS: nothing compiled RemoteConfig.swift or called `validate` at all, so every range, every
// relation, and the baked-equivalence contract could be mutated with the whole suite green. This closes that:
// each clamp bound below is asserted at its LOWER edge, its UPPER edge, and one step outside each, so moving
// a bound by one is RED.

import Foundation

// MARK: - Minimal app dependency stubs (the only three symbols RemoteConfig.swift reaches for)

enum VortXEdgeAuth { static func sign(_ request: inout URLRequest) {} }

struct SourceIndexLifecycleSnapshot: Hashable, Sendable {
    let sourceGeneration: UInt64
    let sessionGeneration: UInt64
    let consentGeneration: UInt64
}

struct SourceIndexLifecycleTransition: Sendable {
    let retired: SourceIndexLifecycleSnapshot
    let current: SourceIndexLifecycleSnapshot
    let retiredSession: Bool
    let retiredConsent: Bool
}

enum SourceIndexLifecycleClock {
    static func closeSource() -> SourceIndexLifecycleTransition {
        let zero = SourceIndexLifecycleSnapshot(sourceGeneration: 0, sessionGeneration: 0, consentGeneration: 0)
        return SourceIndexLifecycleTransition(retired: zero, current: zero,
                                              retiredSession: false, retiredConsent: false)
    }
}

// MARK: - Harness

nonisolated(unsafe) var failures = 0

func expect(_ condition: Bool, _ what: String) {
    if condition {
        print("PASS  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

func resolved(_ json: String) -> ResolvedConfig {
    let data = Data(json.utf8)
    guard let decoded = try? JSONDecoder().decode(RemoteConfigData.self, from: data) else {
        failures += 1
        print("FAIL  fixture did not decode: \(json)")
        return ResolvedConfig.baked
    }
    return RemoteConfig.validate(decoded)
}

/// Every field a call site can read, as one comparable tuple-ish description. Used for the baked-equivalence
/// contract: `.baked` and `validate({})` must agree on ALL of them, not on the handful someone remembered.
func fingerprint(_ c: ResolvedConfig) -> [String: String] {
    [
        "remoteConfigEnabled": "\(c.remoteConfigEnabled)",
        "rankingConfigEnabled": "\(c.rankingConfigEnabled)",
        "debridCeilingMiB": "\(c.debridCeilingMiB)",
        "reducedCeilingMiB": "\(c.reducedCeilingMiB)",
        "macCeilingMiB": "\(c.macCeilingMiB)",
        "offFloorMiB": "\(c.offFloorMiB)",
        "vodReadaheadSecs": "\(c.vodReadaheadSecsValue)",
        "dvRemuxWindowMiB": "\(c.dvRemuxWindowMiB)",
        "detailSettleIOSSecs": "\(c.detailSettleIOSSecs)",
        "detailSettleTVSecs": "\(c.detailSettleTVSecs)",
        "debridResolveSecs": "\(c.debridResolveSecs)",
        "captureIntervalSecs": "\(c.captureIntervalSecsValue)",
        "trickplayMinFrames": "\(c.trickplayMinFrames)",
        "trickplayMaxFrames": "\(c.trickplayMaxFrames)",
        "trickplayMaxTiles": "\(c.trickplayMaxTiles)",
        "trickplayEndpoint": c.trickplayEndpoint.absoluteString,
        "catalogsEndpoint": c.catalogsEndpoint.absoluteString,
        "subtitlesEndpoint": c.subtitlesEndpoint.absoluteString,
        "sourcesEndpoint": c.sourcesEndpoint.absoluteString,
        "subtitleDownloadTimeoutMs": "\(c.subtitleDownloadTimeoutMs)",
        "subtitleUploadMaxBytes": "\(c.subtitleUploadMaxBytes)",
        "subtitleOffsetBucketMs": "\(c.subtitleOffsetBucketMs)",
        "langIndexMinSeen": "\(c.langIndexMinSeen)",
        "sourceIndexInterBatchDelayMs": "\(c.sourceIndexInterBatchDelayMs)",
        "sourceIndexBatchSize": "\(c.sourceIndexBatchSize)",
        "sourceIndexMaxDescriptorsPerTitle": "\(c.sourceIndexMaxDescriptorsPerTitle)",
        "sourceIndexResumeHoardMaxWaitMs": "\(c.sourceIndexResumeHoardMaxWaitMs)",
        "sourceIndexResumeHoardPollIntervalMs": "\(c.sourceIndexResumeHoardPollIntervalMs)",
        "sourceIndexResumeHoardAttemptCap": "\(c.sourceIndexResumeHoardAttemptCap)",
        "sourceIndexRequestTimeoutSecs": "\(c.sourceIndexRequestTimeoutSecs)",
        "refreshIntervalHours": "\(c.refreshIntervalHours)",
        "featureSourceIndexDefaultTrue": "\(c.isFeatureOn("sourceIndex", default: true))",
        "featureSourceIndexDefaultFalse": "\(c.isFeatureOn("sourceIndex", default: false))",
    ]
}

/// One clamp bound, asserted at both edges and one step outside each. A range moved by one in either
/// direction fails at least two of the four assertions.
func assertRange(
    _ label: String,
    lo: Int,
    hi: Int,
    baked: Int,
    _ value: (ResolvedConfig) -> Int,
    _ fixture: (Int) -> String
) {
    expect(value(resolved(fixture(lo))) == lo, "\(label): lower edge \(lo) is accepted unchanged")
    expect(value(resolved(fixture(hi))) == hi, "\(label): upper edge \(hi) is accepted unchanged")
    expect(value(resolved(fixture(lo - 1))) == lo, "\(label): below-range \(lo - 1) clamps UP to \(lo), it does not revert to baked")
    expect(value(resolved(fixture(hi + 1))) == hi, "\(label): above-range \(hi + 1) clamps DOWN to \(hi)")
    expect(value(resolved("{}")) == baked, "\(label): an ABSENT value falls back to the baked \(baked)")
}

@main
struct RemoteConfigValidationTests {
    static func main() {
        // ---- The baked-equivalence contract, over EVERY readable field ----
        // The whole promise of this service is that deleting it changes nothing. `.baked` and an empty remote
        // config must therefore be byte-for-value identical.
        let bakedFingerprint = fingerprint(ResolvedConfig.baked)
        let emptyFingerprint = fingerprint(resolved("{}"))
        let disagreements = bakedFingerprint.keys.filter { bakedFingerprint[$0] != emptyFingerprint[$0] }.sorted()
        expect(disagreements.isEmpty,
               "BAKED EQUIVALENCE: .baked and validate({}) agree on every field (disagreements: \(disagreements))")

        // A config that omits the whole `sourceIndex` block, and one that carries an EMPTY block, are both the
        // baked shape. A missing block used to be the only case anyone checked by hand.
        expect(fingerprint(resolved(#"{"sourceIndex":{}}"#)) == emptyFingerprint,
               "MISSING BLOCK: an empty sourceIndex block resolves identically to no block at all")
        expect(fingerprint(resolved(#"{"master":{},"player":{},"trickplay":{},"endpoints":{}}"#)) == emptyFingerprint,
               "MISSING BLOCK: empty sibling blocks resolve identically to no blocks at all")

        // ---- The Singularity ranges, each at both edges and one step outside ----
        assertRange("interBatchDelayMs", lo: 1100, hi: 30000, baked: 1100,
                    { $0.sourceIndexInterBatchDelayMs },
                    { #"{"sourceIndex":{"interBatchDelayMs":\#($0)}}"# })
        assertRange("maxDescriptorsPerTitle", lo: 16, hi: 2000, baked: 2000,
                    { $0.sourceIndexMaxDescriptorsPerTitle },
                    { #"{"sourceIndex":{"maxDescriptorsPerTitle":\#($0)}}"# })
        assertRange("resumeHoardMaxWaitMs", lo: 250, hi: 20000, baked: 5000,
                    { $0.sourceIndexResumeHoardMaxWaitMs },
                    { #"{"sourceIndex":{"resumeHoardMaxWaitMs":\#($0)}}"# })
        assertRange("resumeHoardPollIntervalMs", lo: 250, hi: 2000, baked: 250,
                    { $0.sourceIndexResumeHoardPollIntervalMs },
                    { #"{"sourceIndex":{"resumeHoardPollIntervalMs":\#($0)}}"# })
        assertRange("requestTimeoutSecs", lo: 3, hi: 8, baked: 8,
                    { $0.sourceIndexRequestTimeoutSecs },
                    { #"{"sourceIndex":{"requestTimeoutSecs":\#($0)}}"# })

        // ---- The one-directional RELATIONS, asserted as relations rather than as literals ----
        // Each of these is the property the range exists for; a range widened on its risk side breaks the
        // relation even if the literal edges in the assertions above were updated to match.
        expect(resolved(#"{"sourceIndex":{"interBatchDelayMs":1}}"#).sourceIndexInterBatchDelayMs
               >= ResolvedConfig.baked.sourceIndexInterBatchDelayMs,
               "RELATION: the pacing delay is SLOW-ONLY; no remote value resolves below the shipped cadence")
        expect(resolved(#"{"sourceIndex":{"maxDescriptorsPerTitle":100000}}"#).sourceIndexMaxDescriptorsPerTitle
               <= ResolvedConfig.baked.sourceIndexMaxDescriptorsPerTitle,
               "RELATION: the per-title cap is DOWN-ONLY; no remote value buys more background POSTs")
        expect(resolved(#"{"sourceIndex":{"requestTimeoutSecs":600}}"#).sourceIndexRequestTimeoutSecs
               <= ResolvedConfig.baked.sourceIndexRequestTimeoutSecs,
               "RELATION: the request budget is SHORTEN-ONLY; attempts cannot stack against a slow worker")
        expect(resolved(#"{"sourceIndex":{"resumeHoardPollIntervalMs":1}}"#).sourceIndexResumeHoardPollIntervalMs
               >= ResolvedConfig.baked.sourceIndexResumeHoardPollIntervalMs,
               "RELATION: the resume poll interval is LENGTHEN-ONLY; MainActor polling cannot get denser")

        // The NAMED availability exception (F3): resumeHoardMaxWaitMs is the ONE knob allowed above shipping,
        // and the bound on that exception is what is asserted here, not merely its existence.
        let widest = resolved(#"{"sourceIndex":{"resumeHoardMaxWaitMs":20000,"resumeHoardPollIntervalMs":250}}"#)
        expect(widest.sourceIndexResumeHoardMaxWaitMs > ResolvedConfig.baked.sourceIndexResumeHoardMaxWaitMs,
               "EXCEPTION: resumeHoardMaxWaitMs is deliberately allowed ABOVE the shipped value")
        expect(widest.sourceIndexResumeHoardAttemptCap == 60,
               "EXCEPTION BOUND: the client-facing attempt cap stays pinned at 60")

        // ---- F1: batchSize is PINNED, not a dial ----
        // Lowering it raises both the POST count and the total D1 ops (3*sources+1 per request), so as an
        // emergency control it amplifies the incident it exists to contain. The key must now be inert.
        for attempt in [1, 4, 8, 15, 16, 17, 1000, -5] {
            let c = resolved(#"{"sourceIndex":{"batchSize":\#(attempt)}}"#)
            guard c.sourceIndexBatchSize != 16 else { continue }
            expect(false, "PINNED: batchSize:\(attempt) resolved to \(c.sourceIndexBatchSize), expected 16")
        }
        expect(resolved(#"{"sourceIndex":{"batchSize":1}}"#).sourceIndexBatchSize == 16,
               "PINNED (F1): a remote batchSize is IGNORED and the value stays pinned at 16")
        expect(fingerprint(resolved(#"{"sourceIndex":{"batchSize":8}}"#)) == emptyFingerprint,
               "PINNED (F1): a config carrying batchSize resolves identically to one that omits it, in every field")

        // ---- IGNORED INPUT: nothing that gates admission or validates a response is wired here ----
        // A config that tries to set a corroboration floor, a served-row cap, or a seeder bound must change
        // NOTHING. These are compile-time constants precisely because a remote value could only weaken them.
        let hostile = #"""
        {"sourceIndex":{"minimumServedCorroboration":0,"corroborationMin":0,"maxServedSources":100000,
        "maxSeeders":999999999,"maxSafeSizeBytes":1,"batchSize":1},
        "contract":{"minimumServedCorroboration":0}}
        """#
        expect(fingerprint(resolved(hostile)) == emptyFingerprint,
               "IGNORED INPUT: corroboration / served-row / seeder keys are not wired and change nothing at all")

        // ---- Out-of-range behaviour is CLAMP, not revert (F4) ----
        // The design contract used to claim out-of-range garbage reverts to baked. It clamps to the nearest
        // edge. The two coincide for every protective endpoint here only because each baked value sits ON the
        // protective edge, which is exactly why the wrong description survived review. This picks a knob whose
        // baked value is NOT on the tested edge, so the two readings genuinely differ.
        let clamped = resolved(#"{"sourceIndex":{"resumeHoardMaxWaitMs":999999}}"#)
        expect(clamped.sourceIndexResumeHoardMaxWaitMs == 20000,
               "F4: out-of-range clamps to the nearest EDGE (20000), it does NOT revert to the baked 5000")
        expect(clamped.sourceIndexResumeHoardMaxWaitMs != ResolvedConfig.baked.sourceIndexResumeHoardMaxWaitMs,
               "F4: and that resolved value is demonstrably different from the baked one, so the two readings are distinguishable")

        // ---- Master switches and malformed input ----
        expect(resolved(#"{"master":{"remoteConfigEnabled":false}}"#).remoteConfigEnabled == false,
               "MASTER: remoteConfigEnabled:false survives validation for the caller to act on")
        expect(fingerprint(resolved(#"{"sourceIndex":{"interBatchDelayMs":null}}"#)) == emptyFingerprint,
               "MALFORMED: an explicit null is treated as absent, exactly like a missing key")

        // ---- Endpoints: https + *.vortx.tv or the baked default ----
        expect(resolved(#"{"endpoints":{"sources":"http://sources.vortx.tv"}}"#).sourcesEndpoint.absoluteString
               == ResolvedConfig.baked.sourcesEndpoint.absoluteString,
               "ENDPOINT: a non-https sources endpoint falls back to the baked root")
        expect(resolved(#"{"endpoints":{"sources":"https://evil.example"}}"#).sourcesEndpoint.absoluteString
               == ResolvedConfig.baked.sourcesEndpoint.absoluteString,
               "ENDPOINT: an off-domain sources endpoint falls back to the baked root")
        expect(resolved(#"{"endpoints":{"sources":"https://alt.vortx.tv"}}"#).sourcesEndpoint.absoluteString
               == "https://alt.vortx.tv",
               "ENDPOINT: an https *.vortx.tv sources endpoint is accepted")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
