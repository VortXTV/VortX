/// Native evidence required before cache maintenance can disturb the active decoder.
/// Source and command identity are checked by the controller under its admission lock.
enum MPVCacheReanchorPolicy {
    struct Sample {
        let position: Double?
        let seeking: Bool?
        let eof: Bool?
        let paused: Bool?
        let lowLevelSeeks: Int?
    }
    struct Admission {
        let target: Double
        let paused: Bool
        let lowLevelSeeks: Int
    }

    static func admit(_ sample: Sample, seekable: Bool?, transportSettled: Bool) -> Admission? {
        guard seekable == true, transportSettled, sample.seeking == false, sample.eof == false,
              let position = sample.position, position.isFinite, position > 0,
              let paused = sample.paused,
              let seeks = sample.lowLevelSeeks, seeks >= 0 else { return nil }
        return Admission(target: position, paused: paused, lowLevelSeeks: seeks)
    }

    /// This gate applies to completion AND the one permitted cached-seek reissue. A raw
    /// optimistic target, missing counter, EOF or changed pause intent cannot authorize either.
    static func canSettle(_ sample: Sample, target: Double, pausedIntent: Bool,
                          transportSettled: Bool) -> Bool {
        guard transportSettled, sample.seeking == false, sample.eof == false,
              sample.paused == pausedIntent, target.isFinite, target > 0,
              let position = sample.position, position.isFinite, position >= 0,
              abs(position - target) <= 2,
              let seeks = sample.lowLevelSeeks, seeks >= 0 else { return false }
        return true
    }
}
