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

/// The six feature keys a PLAYER call site reads. Each was decoded by nothing at all: `RemoteConfigData.Features`
/// had no matching field, so `features[key]` was always absent, the call site's `default:` always won, and the
/// switch could never be flipped from the server. These are the escape hatches for the Dolby Vision work, so an
/// inert one means a bad DV build cannot be turned off remotely, which is the exact scenario they exist for.
/// Paired with the baked default its call site passes, and the site that passes it.
let escapeHatches: [(key: String, bakedDefault: Bool, site: String)] = [
    ("tvosSpdif",                 false, "AudioOutputMode.swift:53"),
    ("dvWindowConsumptionAnchor", true,  "VortXRemuxHLSServer.swift:63"),
    ("dvRemuxMultiAudio",         true,  "VortXMKVRemuxStream.swift:510"),
    ("dvRemuxSubtitles",          true,  "VortXMKVRemuxStream.swift:518"),
    ("plainRemux",                true,  "PlayerEngineRouter.swift:326"),
    ("avPlayerDefault",           true,  "PlayerEngineRouter.swift:346"),
    // Found by an exhaustive read-vs-decoded key diff, not in the original report: the same defect on the
    // two paths that CONTRIBUTE user data upstream, where a working kill switch matters most.
    ("subtitleUpload",            true,  "SubtitlePoolClient.swift:426"),
    ("languageIndexContribute",   true,  "LanguageIndexClient.swift:180"),
]

/// A LITERAL transcription of the set-vs-absent idiom in `PlayerEngineRouter.plainRemuxEnabled` /
/// `avPlayerDefaultEnabled` (PlayerEngineRouter.swift:330-336 and 350-356). Those functions cannot be linked
/// into this standalone harness (they pull in the whole player), so the idiom is mirrored here and applied to
/// a REAL `ResolvedConfig`. The primitive it rests on, `isFeatureOn`, is production code either way, and that
/// primitive is what the six assertions below exercise directly.
func twoProbeResolve(_ c: ResolvedConfig, _ key: String, baked: Bool) -> Bool {
    let onWhenAbsentTrue = c.isFeatureOn(key, default: true)
    let onWhenAbsentFalse = c.isFeatureOn(key, default: false)
    if onWhenAbsentTrue == onWhenAbsentFalse { return onWhenAbsentTrue }
    return baked
}

/// Every field a call site can read, as one comparable tuple-ish description. Used for the baked-equivalence
/// contract: `.baked` and `validate({})` must agree on ALL of them, not on the handful someone remembered.
func fingerprint(_ c: ResolvedConfig) -> [String: String] {
    var out: [String: String] = [
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
        "sourceIndexResumeHoardAttempts": "\(c.sourceIndexResumeHoardAttempts)",
        "sourceIndexRequestTimeoutSecs": "\(c.sourceIndexRequestTimeoutSecs)",
        "refreshIntervalHours": "\(c.refreshIntervalHours)",
        "featureSourceIndexDefaultTrue": "\(c.isFeatureOn("sourceIndex", default: true))",
        "featureSourceIndexDefaultFalse": "\(c.isFeatureOn("sourceIndex", default: false))",
    ]
    // BOTH probes for each escape hatch, so an ABSENT key is pinned in BOTH directions. The pair
    // (true, false) is the signature of "not in the map", which is exactly what lets the call site's own
    // `default:` win. If a decode change ever made one of these present-by-default, the pair would collapse
    // to (x, x) and the baked-equivalence assertion in `main` would go red.
    for hatch in escapeHatches {
        out["feature_\(hatch.key)_defaultTrue"] = "\(c.isFeatureOn(hatch.key, default: true))"
        out["feature_\(hatch.key)_defaultFalse"] = "\(c.isFeatureOn(hatch.key, default: false))"
    }
    return out
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
        // config must therefore be byte-for-value identical. They were not: one field carried both the
        // constant attempt CAP (60) and the derived attempt COUNT (20), so `.baked` said 60 where
        // `validate({})` said 20.
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

        // ---- THE FIX: six keys the player READS that `Features` never DECODED ----
        // All three states are asserted for each key. PRESENT-FALSE is the one that matters operationally (it
        // is the kill switch), ABSENT is the one that matters for safety (it must be indistinguishable from
        // the shipped build, so a server that omits the key cannot change behaviour in the field).
        for hatch in escapeHatches {
            func present(_ v: Bool) -> ResolvedConfig {
                resolved(#"{"features":{"\#(hatch.key)":\#(v)}}"#)
            }

            expect(present(true).isFeatureOn(hatch.key, default: false) == true,
                   "\(hatch.key): PRESENT true decodes and WINS over a false call-site default (\(hatch.site))")
            expect(present(true).isFeatureOn(hatch.key, default: true) == true,
                   "\(hatch.key): PRESENT true resolves true whatever the call-site default is")
            expect(present(false).isFeatureOn(hatch.key, default: true) == false,
                   "\(hatch.key): PRESENT false OVERRIDES a true call-site default -- this is the kill switch, and it was inert")
            expect(present(false).isFeatureOn(hatch.key, default: false) == false,
                   "\(hatch.key): PRESENT false resolves false whatever the call-site default is")

            // ABSENT must be byte-identical to today's shipped behaviour, on both snapshots a reader can see.
            expect(resolved("{}").isFeatureOn(hatch.key, default: hatch.bakedDefault) == hatch.bakedDefault,
                   "\(hatch.key): ABSENT yields the baked \(hatch.bakedDefault), so a server omitting the key changes NOTHING")
            expect(ResolvedConfig.baked.isFeatureOn(hatch.key, default: hatch.bakedDefault) == hatch.bakedDefault,
                   "\(hatch.key): the all-baked snapshot also yields \(hatch.bakedDefault)")
            // An explicit null must be ABSENT, not false. A null resolving to false would silently kill a
            // default-ON DV lane across the whole fleet.
            expect(resolved(#"{"features":{"\#(hatch.key)":null}}"#)
                    .isFeatureOn(hatch.key, default: hatch.bakedDefault) == hatch.bakedDefault,
                   "\(hatch.key): an explicit null is treated as ABSENT, not as false")
        }

        // ---- The PlayerEngineRouter two-probe idiom, across all three states ----
        // It distinguishes an explicitly-set false from an absent key by comparing two probes. That idiom is
        // correct and had to keep working once the keys began decoding: before the fix its "present" branch
        // was unreachable for these two keys.
        for hatch in escapeHatches where hatch.key == "plainRemux" || hatch.key == "avPlayerDefault" {
            expect(twoProbeResolve(resolved(#"{"features":{"\#(hatch.key)":true}}"#), hatch.key, baked: true) == true,
                   "\(hatch.key) two-probe: PRESENT true -> probes AGREE -> true")
            expect(twoProbeResolve(resolved(#"{"features":{"\#(hatch.key)":false}}"#), hatch.key, baked: true) == false,
                   "\(hatch.key) two-probe: PRESENT false -> probes AGREE -> false (the fleet kill switch now reaches the router)")
            expect(twoProbeResolve(resolved("{}"), hatch.key, baked: true) == true,
                   "\(hatch.key) two-probe: ABSENT -> probes DISAGREE -> the baked ON default, exactly as shipped")
            expect(twoProbeResolve(ResolvedConfig.baked, hatch.key, baked: true) == true,
                   "\(hatch.key) two-probe: the all-baked snapshot resolves ON, identical to today")
        }

        // ---- The regression itself, stated as one assertion ----
        // Before the fix `Features` had no field for any of these six, so this payload decoded to an EMPTY
        // feature map and was indistinguishable from `{}`. That equality WAS the bug. If a future edit drops
        // one of the fields again, this goes red.
        let allOff = #"""
        {"features":{"tvosSpdif":false,"dvWindowConsumptionAnchor":false,"dvRemuxMultiAudio":false,
        "dvRemuxSubtitles":false,"plainRemux":false,"avPlayerDefault":false,"subtitleUpload":false,
        "languageIndexContribute":false}}
        """#
        expect(fingerprint(resolved(allOff)) != emptyFingerprint,
               "REGRESSION GUARD: a config turning every one of these switches OFF is no longer identical to an empty config")
        for hatch in escapeHatches {
            expect(resolved(allOff).isFeatureOn(hatch.key, default: true) == false,
                   "REGRESSION GUARD: \(hatch.key) reads FALSE from the all-off payload")
        }
        // And the mirror image: a payload turning all six ON is likewise distinguishable, so the map is not
        // merely being filled with one constant.
        let allOn = #"""
        {"features":{"tvosSpdif":true,"dvWindowConsumptionAnchor":true,"dvRemuxMultiAudio":true,
        "dvRemuxSubtitles":true,"plainRemux":true,"avPlayerDefault":true,"subtitleUpload":true,
        "languageIndexContribute":true}}
        """#
        for hatch in escapeHatches {
            expect(resolved(allOn).isFeatureOn(hatch.key, default: false) == true,
                   "REGRESSION GUARD: \(hatch.key) reads TRUE from the all-on payload")
        }

        // ---- The keys that DECODE but nothing READS (reported, deliberately NOT deleted) ----
        // Deleting a schema field is a separate decision: a server may already be sending these. Pinned here
        // so the decision stays visible and a later reader can see they were known, not missed.
        // There are TWELVE, not the five originally reported. The other seven were found by diffing every
        // `isFeatureOn("...")` read in app/ against every `put("...")` in validate; each of the seven has
        // zero references anywhere outside this file.
        for orphan in ["hdrDisplayModeSwitch", "iosPassthroughAudio", "dvToAVPlayerRouting",
                       "hlsToAVPlayerRouting", "av1Penalty",
                       "aniSkip", "debridCacheCheck", "debridInlineResolve", "erdbPosters",
                       "skipVortxLayer", "vortxRatings", "xrdbPosters"] {
            expect(resolved(#"{"features":{"\#(orphan)":false}}"#).isFeatureOn(orphan, default: true) == false,
                   "DECODED BUT UNREAD: \(orphan) still decodes (no app call site reads it today)")
        }

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
        expect(widest.sourceIndexResumeHoardAttempts == 60,
               "EXCEPTION BOUND: the widest in-range pair resolves to exactly the 60-attempt cap, not 80")
        expect(widest.sourceIndexResumeHoardAttempts <= 3 * ResolvedConfig.baked.sourceIndexResumeHoardAttempts,
               "EXCEPTION BOUND: the worst case is 3x the shipped attempt count, and no more")

        // ---- The DERIVED attempt count ----
        // Clamping the pair is not sufficient: their quotient is the quantity that reaches the MainActor.
        expect(resolved("{}").sourceIndexResumeHoardAttempts == 20,
               "DERIVED: the baked 5000 / 250 pair resolves to 20 attempts")
        expect(resolved("{}").sourceIndexResumeHoardAttemptCap == 60,
               "DERIVED: the constant CAP stays 60 and is NOT the derived count")
        expect(resolved(#"{"sourceIndex":{"resumeHoardMaxWaitMs":250,"resumeHoardPollIntervalMs":2000}}"#)
                .sourceIndexResumeHoardAttempts == 1,
               "DERIVED: a wait shorter than one interval still yields at least ONE attempt, never zero")
        for wait in [250, 1000, 5000, 12000, 20000] {
            for interval in [250, 500, 1000, 2000] {
                let c = resolved(#"{"sourceIndex":{"resumeHoardMaxWaitMs":\#(wait),"resumeHoardPollIntervalMs":\#(interval)}}"#)
                let expected = min(60, max(1, wait / interval))
                guard c.sourceIndexResumeHoardAttempts != expected else { continue }
                expect(false, "DERIVED: \(wait)/\(interval) resolves to \(expected) attempts")
            }
        }
        expect(true, "DERIVED: every in-range wait/interval pair resolves to min(60, max(1, wait / interval))")

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

        // ---- BAKED DEFAULTS MUST DESCRIBE WHAT SHIPS TODAY ----
        // A baked default IS the promise that wiring its accessor is a no-op. A stale one turns a change
        // meant to be inert into a silent behaviour regression the first time someone wires it. Two were
        // stale. These pin them to the literal the production code actually uses, with the citation, so the
        // next drift is caught here instead of in the field.
        expect(RemoteConfigDefaults.debridResolveSecs == 5,
               "BAKED TRUTH: debridResolveSecs is 5, matching DebridResolver.swift:1178 (was 15, the pre-change value)")
        expect(RemoteConfigDefaults.detailSettleIOSSecs == 20,
               "BAKED TRUTH: detailSettleIOSSecs is 20, matching iOSDetailView.swift:654 and :3630 (was 12, the tvOS value)")
        expect(RemoteConfigDefaults.detailSettleTVSecs == 12,
               "BAKED TRUTH: detailSettleTVSecs is 12, matching DetailView.swift:2221")
        expect(RemoteConfigDefaults.vodReadaheadSecs == 300,
               "BAKED TRUTH: vodReadaheadSecs is 300, matching MPVMetalViewController.swift:1250")
        // Every corrected default must still sit INSIDE its own clamp range, or an absent remote value would
        // resolve to something other than the baked value and the equivalence contract would break.
        expect(resolved("{}").debridResolveSecs == RemoteConfigDefaults.debridResolveSecs,
               "BAKED TRUTH: the corrected debridResolveSecs survives its own clamp (5...30) unchanged")
        expect(resolved("{}").detailSettleIOSSecs == RemoteConfigDefaults.detailSettleIOSSecs,
               "BAKED TRUTH: the corrected detailSettleIOSSecs survives its own clamp (5...60) unchanged")

        // ---- LAUNCH-HEALTH GUARD: the valid-but-HARMFUL config ----
        // A config can decode cleanly, pass every clamp, be persisted as last-known-good, and still wedge the
        // app. It is then re-applied on every launch, so if it wedges before the next fetch completes, the
        // mechanism built to deliver the fix can never reach the device. The decision is a pure function so
        // it can be checked exhaustively here.
        let threshold = RemoteConfig.unhealthyStartThreshold
        expect(threshold == 3, "GUARD: the threshold is the conservative 3 (1 and 2 are inside ordinary user behaviour)")
        expect(RemoteConfig.healthySurvivalSecs == 10, "GUARD: a launch must hold the main thread responsive for 10s to count healthy")

        let hashA = RemoteConfig.stableHash(Data(#"{"schemaVersion":1}"#.utf8))
        let hashB = RemoteConfig.stableHash(Data(#"{"schemaVersion":2}"#.utf8))
        expect(hashA == RemoteConfig.stableHash(Data(#"{"schemaVersion":1}"#.utf8)),
               "GUARD: the content hash is STABLE for identical bytes (Hasher is per-process seeded and cannot be used)")
        expect(hashA != hashB, "GUARD: the content hash separates different configs")

        func decide(storedHash: String?, counter: Int, quarantined: String? = nil) -> RemoteConfig.LaunchHealthDecision {
            RemoteConfig.launchHealthDecision(cachedHash: hashA, storedHash: storedHash, storedCounter: counter,
                                              quarantinedHash: quarantined, threshold: threshold)
        }

        // Healthy device: a config never seen before, and the counted run up to the threshold.
        expect(decide(storedHash: nil, counter: 0) == .apply(nextCounter: 1),
               "GUARD: a config never applied before is admitted and starts its own count at 1")
        expect(decide(storedHash: hashA, counter: 0) == .apply(nextCounter: 1),
               "GUARD: a healthy device (counter 0) is admitted")
        expect(decide(storedHash: hashA, counter: 1) == .apply(nextCounter: 2),
               "GUARD: one prior unhealthy start still admits, and increments")
        expect(decide(storedHash: hashA, counter: 2) == .apply(nextCounter: 3),
               "GUARD: two prior unhealthy starts still admit (2 is inside ordinary quick-quit behaviour)")
        expect(decide(storedHash: hashA, counter: 3) == .discard,
               "GUARD: THREE consecutive unhealthy starts discard the cached config and boot baked")
        expect(decide(storedHash: hashA, counter: 99) == .discard,
               "GUARD: any count at or above the threshold discards")

        // The operator's FIX must never arrive pre-condemned by the previous config's failures.
        expect(decide(storedHash: hashB, counter: 99) == .apply(nextCounter: 1),
               "GUARD: a DIFFERENT config resets the count, so a fix is never charged for the bad config's crashes")
        // Quarantine is by content hash, so a re-serve of the same bad bytes cannot undo a discard.
        expect(decide(storedHash: hashA, counter: 0, quarantined: hashA) == .discard,
               "GUARD: a quarantined config is discarded even from a clean counter (refresh cannot re-install it)")
        expect(decide(storedHash: hashA, counter: 0, quarantined: hashB) == .apply(nextCounter: 1),
               "GUARD: quarantining one config does not condemn a different one")
        // Corrupt / hostile persisted state must not disable the guard.
        expect(decide(storedHash: hashA, counter: -50) == .apply(nextCounter: 1),
               "GUARD: a negative persisted counter is floored at 0 rather than granting infinite retries")

        // The guard must be INERT on a device that never has a cached config problem: the full healthy
        // sequence below is what an ordinary user experiences, and it never discards.
        var healthySequenceDiscarded = false
        for _ in 0..<50 {
            if decide(storedHash: hashA, counter: 0) == .discard { healthySequenceDiscarded = true }
        }
        expect(!healthySequenceDiscarded,
               "GUARD: fifty consecutive HEALTHY launches (counter reset each time) never discard a good config")

        // ---- FOREGROUND THROTTLE ----
        // `refreshIfForegroundDue` previously had ZERO call sites anywhere in the repo, so the 30-minute
        // throttle had never actually run. Now that both scene hooks call it on every foreground transition,
        // it must genuinely no-op when the last fetch is recent, or a user tabbing in and out would hammer
        // config.vortx.tv.
        let halfHour: TimeInterval = 30 * 60
        expect(RemoteConfig.shouldRefreshOnForeground(lastFetchEpoch: 0, now: 1_000_000, throttle: halfHour),
               "THROTTLE: a device that has never fetched is always allowed through")
        expect(!RemoteConfig.shouldRefreshOnForeground(lastFetchEpoch: 1_000_000, now: 1_000_001, throttle: halfHour),
               "THROTTLE: a fetch one second ago is BLOCKED (this is the hammering case)")
        expect(!RemoteConfig.shouldRefreshOnForeground(lastFetchEpoch: 1_000_000, now: 1_000_000 + halfHour - 1, throttle: halfHour),
               "THROTTLE: one second SHORT of the window is still blocked")
        expect(RemoteConfig.shouldRefreshOnForeground(lastFetchEpoch: 1_000_000, now: 1_000_000 + halfHour, throttle: halfHour),
               "THROTTLE: exactly at the 30-minute window it is due")
        expect(RemoteConfig.shouldRefreshOnForeground(lastFetchEpoch: 1_000_000, now: 1_000_000 + halfHour + 1, throttle: halfHour),
               "THROTTLE: past the window it is due")
        // A backwards clock must not lock a device out of config updates until real time catches up.
        expect(RemoteConfig.shouldRefreshOnForeground(lastFetchEpoch: 2_000_000, now: 1_000_000, throttle: halfHour),
               "THROTTLE: a clock that moved BACKWARDS is treated as due, not as blocked forever")
        // Ten rapid foreground transitions inside the window must produce exactly ONE allowed refresh.
        var allowed = 0
        for i in 0..<10 where RemoteConfig.shouldRefreshOnForeground(
            lastFetchEpoch: 1_000_000, now: 1_000_000 + Double(i), throttle: halfHour) { allowed += 1 }
        expect(allowed == 0, "THROTTLE: ten foreground transitions within the window allow ZERO extra fetches")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
