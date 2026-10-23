// PRIVATE — tiny source-unit entry proposal. UNCOMPILED / UNRUN.
import Foundation

@main
struct ProfileMigrationFixtureEntry {
    @MainActor static func main() async throws {
        if CommandLine.arguments.dropFirst().contains("--pure-stale-cleanup-negative-control") {
            try PureStaleCleanupControl.run(useUnconditionalCleanup: true)
            return
        }
        if CommandLine.arguments.dropFirst().contains("--pure-stale-cleanup-corrected-control") {
            try PureStaleCleanupControl.run(useUnconditionalCleanup: false)
            return
        }
        try await G3ProfileMigrationFixture.run()
        print("G3 source fixture completed")
    }
}
