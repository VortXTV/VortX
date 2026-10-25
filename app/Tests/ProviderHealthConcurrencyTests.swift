import Foundation

// The shared fixture provides the intended MainActor/RAM collaborators while this executable
// exercises the whole actual SeriesSourceSticky.swift's nonisolated ProviderHealth API only.

@main enum ProviderHealthConcurrencyTests {
    static func main() async {
        let health = ProviderHealth.Store()
        var clockCalls = 0
        health.noteFailure(addonName: "", uptime: { clockCalls += 1; return 100 })
        precondition(!health.penaltyActive(addonName: nil, uptime: { clockCalls += 1; return 100 }))
        precondition(!health.penaltyActive(addonName: "", uptime: { clockCalls += 1; return 100 }))
        precondition(!health.penaltyActive(addonName: "missing", uptime: { clockCalls += 1; return 100 }))
        precondition(clockCalls == 0 && health.rememberedAddonCount == 0,
                     "invalid or missing names do not sample the clock or create state")

        health.noteFailure(addonName: "Mixed CASE", uptime: { 100 })
        precondition(health.penaltyActive(addonName: "mixed case", uptime: { 100 }))
        precondition(health.penaltyActive(addonName: "MIXED CASE", uptime: { 699.999 }))
        precondition(!health.penaltyActive(addonName: "mixed case", uptime: { 700 }),
                     "the 600-second cutoff remains strict, not inclusive")
        precondition(!health.penaltyActive(addonName: "mixed case", uptime: { 701 }))
        precondition(!health.penaltyActive(addonName: " mixed case ", uptime: { 100 }),
                     "key normalization is lowercase only, not trimming or URL rewriting")
        health.noteFailure(addonName: "MIXED CASE", uptime: { 200 })
        precondition(health.rememberedAddonCount == 1)
        precondition(health.penaltyActive(addonName: "mixed case", uptime: { 799.999 }))
        precondition(!health.penaltyActive(addonName: "mixed case", uptime: { 800 }),
                     "a later failure refreshes the same provider's timestamp")
        health.noteFailure(addonName: " ", uptime: { 200 })
        precondition(health.penaltyActive(addonName: " ", uptime: { 200 }),
                     "retain the existing nonempty-name rule, including whitespace")

        let pruning = ProviderHealth.Store()
        for index in 0..<64 { pruning.noteFailure(addonName: "expired-\(index)", uptime: { 0 }) }
        precondition(pruning.rememberedAddonCount == 64)
        precondition(!pruning.penaltyActive(addonName: "expired-0", uptime: { 600 }))
        precondition(pruning.rememberedAddonCount == 64, "reads do not prune the dictionary")
        pruning.noteFailure(addonName: "fresh", uptime: { 600 })
        precondition(pruning.rememberedAddonCount == 1,
                     "crossing 64 prunes entries at the exact expiry boundary")
        precondition(pruning.penaltyActive(addonName: "fresh", uptime: { 600 }))
        precondition(!pruning.penaltyActive(addonName: "expired-63", uptime: { 600 }))

        let crowded = ProviderHealth.Store()
        for index in 0..<96 { crowded.noteFailure(addonName: "live-\(index)", uptime: { 100 }) }
        precondition(crowded.rememberedAddonCount == 96,
                     "the legacy threshold prunes expired entries; it must not evict live failures")
        for index in 0..<96 {
            precondition(crowded.penaltyActive(addonName: "live-\(index)", uptime: { 699.999 }))
        }
        crowded.noteFailure(addonName: "replacement", uptime: { 700 })
        precondition(crowded.rememberedAddonCount == 1)

        // The writer samples its clock before locking; the reader samples after lookup/unlock.
        // Reentrant access would deadlock if either callback moved under the nonrecursive lock.
        health.noteFailure(addonName: "outer-write", uptime: {
            health.noteFailure(addonName: "inner-write", uptime: { 300 })
            return 300
        })
        precondition(health.penaltyActive(addonName: "outer-write", uptime: {
            health.noteFailure(addonName: "reader-clock-write", uptime: { 300 })
            precondition(health.penaltyActive(addonName: "inner-write", uptime: { 300 }))
            return 300
        }))
        precondition(health.penaltyActive(addonName: "reader-clock-write", uptime: { 300 }))

        let sampled = ProviderHealth.Store()
        sampled.noteFailure(addonName: "same-provider", uptime: {
            sampled.noteFailure(addonName: "same-provider", uptime: { 900 })
            return 100
        })
        precondition(!sampled.penaltyActive(addonName: "same-provider", uptime: { 700 }),
                     "preserve sampled writer order; do not silently merge by maximum timestamp")

        // A bounded correctness regression, not a throughput benchmark. Every reader follows its own
        // completed write, while other tasks also write/read both distinct keys and one contended key.
        let concurrent = ProviderHealth.Store()
        let copy = concurrent
        let allCurrent = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for iteration in 0..<32 {
                        let name = "worker-\(worker)-\(iteration)"
                        concurrent.noteFailure(addonName: name, uptime: { 1_000 })
                        copy.noteFailure(addonName: "SHARED", uptime: { 1_000 })
                        guard copy.penaltyActive(addonName: name.uppercased(), uptime: { 1_001 }),
                              concurrent.penaltyActive(addonName: "shared", uptime: { 1_001 }) else { return false }
                    }
                    return true
                }
            }
            var accepted = true
            for await value in group { accepted = accepted && value }
            return accepted
        }
        precondition(allCurrent && concurrent.rememberedAddonCount == 257,
                     "checked Sendable copies share one coherent dictionary without dropping live keys")
        precondition(!copy.penaltyActive(addonName: "shared", uptime: { 1_600 }))
        copy.noteFailure(addonName: "after-expiry", uptime: { 1_600 })
        precondition(concurrent.rememberedAddonCount == 1)

        // Exercise the unchanged production wrappers from a detached worker as well.
        let publicName = "fixture-\(UUID().uuidString)"
        let publicResult = await Task.detached {
            ProviderHealth.noteFailure(addonName: publicName)
            return ProviderHealth.penaltyActive(addonName: publicName.uppercased())
        }.value
        precondition(publicResult)
        print("PASS ProviderHealth checked ownership, worker wrappers, key/expiry/pruning semantics, reentrant clocks, bounded concurrent reads/writes")
    }
}
