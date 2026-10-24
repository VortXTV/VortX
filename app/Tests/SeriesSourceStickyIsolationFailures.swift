import Foundation

// Compiled, never executed. Each flag must independently fail at its actual live API boundary.
enum SeriesSourceStickyIsolationFailures {
    nonisolated static func illegalUse() {
        #if STICKY_FAIL_SNAPSHOT
        _ = SeriesSourceSticky.snapshot(for: "fixture")
        #elseif STICKY_FAIL_CURRENT
        _ = SeriesSourceSticky.currentSnapshot(for: "fixture")
        #elseif STICKY_FAIL_PREFERENCE
        _ = SeriesSourceSticky.preference(for: "fixture")
        #elseif STICKY_FAIL_RECORD
        SeriesSourceSticky.record(seriesKey: "fixture", addon: "fixture", bingeGroup: nil)
        #elseif STICKY_FAIL_AUDIO
        SeriesSourceSticky.recordAudio(seriesKey: "fixture", language: "eng")
        #elseif STICKY_FAIL_ADMISSION
        _ = SeriesSourceSticky.admits(nil)
        #else
        #error("An expected-failure flag is required")
        #endif
    }
}
