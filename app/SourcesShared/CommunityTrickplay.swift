import Foundation
#if !TRICKPLAY_E2E_POLICY_TESTING
import CryptoKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#endif

/// One time-bounded sprite tile. This Foundation-only value is shared by upload generation, community
/// playback, and the focused standalone regression harness so all three exercise the same timeline rules.
struct TrickplayTimelineCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let tileIndex: Int

    func contains(_ time: Double) -> Bool {
        time.isFinite && time >= start && time < end
    }
}

/// Builds and consumes the time index for a community sprite. New sheets use the real capture timestamps.
/// Older metadata with no advertised VTT remains compatible through `cue`'s legacy interval path.
enum TrickplayTimeline {
    /// Robust ordinary cadence of a retained timeline. The lower median ignores sparse seek gaps while still
    /// reflecting deliberate whole-session decimation (for example, 1,201 ten-second captures retained as 600
    /// frames yield an ordinary cadence near 20 seconds).
    static func nominalCadence(
        captureTimes: [Double],
        fallbackInterval: Double
    ) -> Double {
        guard fallbackInterval.isFinite, fallbackInterval > 0 else { return 0 }
        let sorted = Array(
            Set(captureTimes.filter { $0.isFinite && $0 >= 0 })
        ).sorted()
        let deltas = zip(sorted, sorted.dropFirst())
            .map { $1 - $0 }
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        // A sparse seek-only timeline has no evidence of deliberate retention decimation. Keep the original
        // cadence unless enough adjacent samples agree that the retained timeline is genuinely coarser.
        guard deltas.count >= 8 else { return fallbackInterval }
        let lowerMedian = deltas[(deltas.count - 1) / 2]
        return max(fallbackInterval, lowerMedian)
    }

    /// Detects continuity-segment boundaries on the full retained timeline, before any additional sheet
    /// sampling. Each returned value belongs to the selected tile at the same position and, when non-nil, is the
    /// last pre-gap capture plus one retained cadence. This evidence remains valid regardless of sheet stride.
    static func selectedCueEndFences(
        retainedCaptureTimes: [Double],
        selectedIndices: [Int],
        retainedCadence: Double
    ) -> [Double?]? {
        guard retainedCadence.isFinite, retainedCadence > 0 else { return nil }
        for index in retainedCaptureTimes.indices {
            let time = retainedCaptureTimes[index]
            guard time.isFinite, time >= 0,
                  index == retainedCaptureTimes.startIndex
                    || time > retainedCaptureTimes[index - 1] else { return nil }
        }
        for index in selectedIndices.indices {
            let selected = selectedIndices[index]
            guard retainedCaptureTimes.indices.contains(selected),
                  index == selectedIndices.startIndex
                    || selected > selectedIndices[index - 1] else { return nil }
        }

        var fences = Array<Double?>(repeating: nil, count: selectedIndices.count)
        guard selectedIndices.count > 1 else { return fences }
        let discontinuityThreshold = retainedCadence * 2
        for selectedPosition in 0..<(selectedIndices.count - 1) {
            let startIndex = selectedIndices[selectedPosition]
            let endIndex = selectedIndices[selectedPosition + 1]
            for retainedIndex in startIndex..<endIndex {
                let delta = retainedCaptureTimes[retainedIndex + 1]
                    - retainedCaptureTimes[retainedIndex]
                if delta > discontinuityThreshold {
                    fences[selectedPosition] = retainedCaptureTimes[retainedIndex]
                        + retainedCadence
                    break
                }
            }
        }
        return fences
    }

    static func makeCues(
        captureTimes: [Double],
        nominalInterval: Double,
        gapFenceInterval: Double? = nil,
        cueEndFences: [Double?]? = nil,
        cols: Int,
        tileW: Int,
        tileH: Int
    ) -> [TrickplayTimelineCue]? {
        let gapFenceInterval = gapFenceInterval ?? nominalInterval
        guard !captureTimes.isEmpty, nominalInterval.isFinite, nominalInterval > 0,
              gapFenceInterval.isFinite, gapFenceInterval > 0,
              cols > 0, tileW > 0, tileH > 0 else { return nil }
        for index in captureTimes.indices {
            let time = captureTimes[index]
            guard time.isFinite, time >= 0,
                  index == captureTimes.startIndex || time > captureTimes[index - 1] else { return nil }
        }
        if let cueEndFences {
            guard cueEndFences.count == captureTimes.count else { return nil }
            for index in cueEndFences.indices {
                if let fence = cueEndFences[index] {
                    guard index + 1 < captureTimes.count,
                          fence.isFinite,
                          fence > captureTimes[index],
                          fence <= captureTimes[index + 1] else { return nil }
                }
            }
        }

        return captureTimes.indices.map { index in
            let start = captureTimes[index]
            let end: Double
            if index + 1 < captureTimes.count {
                let next = captureTimes[index + 1]
                if let cueEndFences {
                    end = cueEndFences[index].map { min($0, next) } ?? next
                } else {
                    let delta = next - start
                    let discontinuityThreshold = nominalInterval + gapFenceInterval
                    end = delta > discontinuityThreshold
                        ? min(start + gapFenceInterval, next)
                        : next
                }
            } else {
                end = start + (cueEndFences == nil ? nominalInterval : gapFenceInterval)
            }
            return TrickplayTimelineCue(
                start: start,
                end: end,
                x: (index % cols) * tileW,
                y: (index / cols) * tileH,
                width: tileW,
                height: tileH,
                tileIndex: index
            )
        }
    }

    static func makeVTT(
        captureTimes: [Double],
        nominalInterval: Double,
        gapFenceInterval: Double? = nil,
        cueEndFences: [Double?]? = nil,
        cols: Int,
        tileW: Int,
        tileH: Int
    ) -> String? {
        guard let cues = makeCues(
            captureTimes: captureTimes,
            nominalInterval: nominalInterval,
            gapFenceInterval: gapFenceInterval,
            cueEndFences: cueEndFences,
            cols: cols,
            tileW: tileW,
            tileH: tileH
        ) else { return nil }
        var lines = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(vttTime(cue.start)) --> \(vttTime(cue.end))")
            lines.append("sprite#xywh=\(cue.x),\(cue.y),\(cue.width),\(cue.height)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the subset of WEBVTT emitted by the trickplay worker. Invalid indexes return nil as a whole
    /// instead of exposing partial or mismatched coverage.
    static func parseVTT(
        _ raw: String,
        frameCount: Int,
        cols: Int,
        tileW: Int,
        tileH: Int
    ) -> [TrickplayTimelineCue]? {
        guard frameCount > 0, cols > 0, tileW > 0, tileH > 0 else { return nil }
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{feff}", with: ""),
              first.hasPrefix("WEBVTT") else { return nil }

        var parsed: [TrickplayTimelineCue] = []
        var lineIndex = 1
        while lineIndex < lines.count {
            let timing = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            lineIndex += 1
            guard let arrow = timing.range(of: "-->") else { continue }
            let startText = timing[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let endAndSettings = timing[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let endText = endAndSettings.split(whereSeparator: \.isWhitespace).first,
                  let start = parseVTTTime(String(startText)),
                  let end = parseVTTTime(String(endText)),
                  start >= 0, end > start else { return nil }

            var coordinates: (x: Int, y: Int, width: Int, height: Int)?
            while lineIndex < lines.count {
                let payload = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                if payload.isEmpty {
                    lineIndex += 1
                    break
                }
                if payload.contains("-->") { break }
                if coordinates == nil {
                    coordinates = parseCoordinates(payload)
                }
                lineIndex += 1
            }
            guard let coordinates,
                  coordinates.x >= 0, coordinates.y >= 0,
                  coordinates.width == tileW, coordinates.height == tileH,
                  coordinates.x % tileW == 0, coordinates.y % tileH == 0 else { return nil }
            let col = coordinates.x / tileW
            let row = coordinates.y / tileH
            guard col < cols else { return nil }
            let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: cols)
            guard !rowOverflow else { return nil }
            let (tileIndex, tileIndexOverflow) = rowOffset.addingReportingOverflow(col)
            guard !tileIndexOverflow, tileIndex < frameCount else { return nil }
            if let prior = parsed.last {
                guard start >= prior.end, tileIndex > prior.tileIndex else { return nil }
            }
            parsed.append(
                TrickplayTimelineCue(
                    start: start,
                    end: end,
                    x: coordinates.x,
                    y: coordinates.y,
                    width: coordinates.width,
                    height: coordinates.height,
                    tileIndex: tileIndex
                )
            )
        }
        guard parsed.count == frameCount else { return nil }
        return parsed
    }

    /// Finds genuine coverage only. With parsed VTT, gaps and both outer bounds return nil. With an older
    /// interval-only sheet, coverage is the finite half-open range [0, frameCount * interval).
    static func cue(
        at time: Double,
        parsedCues: [TrickplayTimelineCue]?,
        frameCount: Int,
        legacyInterval: Double,
        cols: Int,
        tileW: Int,
        tileH: Int
    ) -> TrickplayTimelineCue? {
        guard time.isFinite, time >= 0 else { return nil }
        if let parsedCues {
            var lower = 0
            var upper = parsedCues.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if parsedCues[middle].start <= time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return nil }
            let candidate = parsedCues[lower - 1]
            return candidate.contains(time) ? candidate : nil
        }

        guard frameCount > 0, cols > 0, tileW > 0, tileH > 0,
              legacyInterval.isFinite, legacyInterval > 0 else { return nil }
        let coverageEnd = Double(frameCount) * legacyInterval
        guard coverageEnd.isFinite, time < coverageEnd else { return nil }
        let tileIndex = Int((time / legacyInterval).rounded(.down))
        return TrickplayTimelineCue(
            start: Double(tileIndex) * legacyInterval,
            end: Double(tileIndex + 1) * legacyInterval,
            x: (tileIndex % cols) * tileW,
            y: (tileIndex / cols) * tileH,
            width: tileW,
            height: tileH,
            tileIndex: tileIndex
        )
    }

    /// Nearest tile to `time` for a fallback preview: the tile whose coverage is closest when no tile
    /// genuinely covers `time` (a gap, or an out-of-bounds scrub). Complements `cue(at:)`, which returns nil
    /// there. Returns nil only when the sheet describes no usable tiles.
    static func nearestCue(
        at time: Double,
        parsedCues: [TrickplayTimelineCue]?,
        frameCount: Int,
        legacyInterval: Double,
        cols: Int,
        tileW: Int,
        tileH: Int
    ) -> TrickplayTimelineCue? {
        let clamped = (time.isFinite && time >= 0) ? time : 0
        if let parsedCues {
            guard !parsedCues.isEmpty else { return nil }
            var best = parsedCues[0]
            var bestDistance = Double.greatestFiniteMagnitude
            for cue in parsedCues {
                let distance = clamped < cue.start ? cue.start - clamped
                    : (clamped >= cue.end ? clamped - cue.end : 0)
                if distance < bestDistance { bestDistance = distance; best = cue }
            }
            return best
        }
        guard frameCount > 0, cols > 0, tileW > 0, tileH > 0,
              legacyInterval.isFinite, legacyInterval > 0 else { return nil }
        let rawIndex = Int((clamped / legacyInterval).rounded(.down))
        let tileIndex = min(max(0, rawIndex), frameCount - 1)
        return TrickplayTimelineCue(
            start: Double(tileIndex) * legacyInterval,
            end: Double(tileIndex + 1) * legacyInterval,
            x: (tileIndex % cols) * tileW,
            y: (tileIndex / cols) * tileH,
            width: tileW,
            height: tileH,
            tileIndex: tileIndex
        )
    }

    private static func parseCoordinates(
        _ payload: String
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let marker = payload.range(of: "#xywh=") else { return nil }
        let values = payload[marker.upperBound...].split(separator: ",", omittingEmptySubsequences: false)
        guard values.count == 4,
              let x = Int(values[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(values[1].trimmingCharacters(in: .whitespaces)),
              let width = Int(values[2].trimmingCharacters(in: .whitespaces)),
              let height = Int(values[3].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (x, y, width, height)
    }

    private static func parseVTTTime(_ raw: String) -> Double? {
        let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let hours: Double
        let minutes: Double
        let seconds: Double
        if fields.count == 3 {
            guard let parsedHours = Double(fields[0]), let parsedMinutes = Double(fields[1]),
                  let parsedSeconds = Double(fields[2]) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
            seconds = parsedSeconds
        } else {
            guard let parsedMinutes = Double(fields[0]), let parsedSeconds = Double(fields[1]) else { return nil }
            hours = 0
            minutes = parsedMinutes
            seconds = parsedSeconds
        }
        guard hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }

    private static func vttTime(_ seconds: Double) -> String {
        let totalMilliseconds = Int64((seconds * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainder = totalSeconds % 60
        return String(
            format: "%02lld:%02lld:%02lld.%03lld",
            hours, minutes, remainder, milliseconds
        )
    }
}

/// Keeps a bounded, time-spanning sample while still admitting captures after the buffer fills. Each overflow
/// removes the most temporally redundant interior sample and always preserves both observed timeline endpoints.
enum TrickplaySessionFrameRetention {
    static func captureLimit(frameBoundsMax: Int) -> Int {
        max(2, frameBoundsMax)
    }

    static func retainedIndices(captureTimes: [Double], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        var retained: [(index: Int, time: Double)] = []
        for (index, time) in captureTimes.enumerated() where time.isFinite && time >= 0 {
            retained.append((index: index, time: time))
        }
        retained.sort {
            $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time
        }

        var deduplicated: [(index: Int, time: Double)] = []
        for candidate in retained {
            if deduplicated.last?.time == candidate.time {
                deduplicated[deduplicated.count - 1] = candidate
            } else {
                deduplicated.append(candidate)
            }
        }
        retained = deduplicated

        if limit == 1 {
            return retained.last.map { [$0.index] } ?? []
        }
        while retained.count > limit {
            var removal = 1
            var narrowestSpan = retained[2].time - retained[0].time
            if retained.count > 3 {
                for index in 2..<(retained.count - 1) {
                    let span = retained[index + 1].time - retained[index - 1].time
                    if span < narrowestSpan {
                        narrowestSpan = span
                        removal = index
                    }
                }
            }
            retained.remove(at: removal)
        }
        return retained.map { $0.index }
    }

    /// Row-major sheet sampling with both timeline endpoints and the requested count preserved.
    static func evenlySpacedIndices(count: Int, targetCount: Int) -> [Int] {
        guard count > 0, targetCount > 0 else { return [] }
        guard targetCount < count else { return Array(0..<count) }
        guard targetCount > 1 else { return [count - 1] }
        return (0..<targetCount).map { index in
            Int(
                (Double(index) * Double(count - 1) / Double(targetCount - 1)).rounded()
            )
        }
    }
}

/// Admission check for a decoded local thumbnail callback. Both request order and stable media identity must
/// still match, so an outgoing episode cannot publish after a true reconfigure even if its disk read finishes late.
enum TrickplayPreviewReadGate {
    static func accepts(
        requestToken: Int,
        requestMediaKey: String,
        currentToken: Int,
        currentMediaKey: String?
    ) -> Bool {
        requestToken == currentToken && requestMediaKey == currentMediaKey
    }
}

/// Admission check for one keyed community fetch. The epoch closes the A-to-B-to-A hole that a key-only
/// comparison cannot close when an old request returns after the same content key is selected again.
enum TrickplayFetchClaim {
    static func accepts(
        requestEpoch: UInt64,
        requestKey: String,
        currentEpoch: UInt64,
        currentKey: String?
    ) -> Bool {
        requestEpoch == currentEpoch && requestKey == currentKey
    }
}

#if !TRICKPLAY_E2E_POLICY_TESTING

/// Community trickplay: scrub-preview thumbnails SHARED across users, like Netflix / Plex storyboards.
///
/// Two halves, both 100% fail-soft (any miss / error / offline silently leaves the player on its existing
/// per-device local capture, today's behavior, so there is never a regression):
///
///   1. FETCH-FIRST (`fetch`): on opening a title, compute the content key and GET
///      `trickplay.vortx.tv/tp/{key}`. On a hit, download the sprite-sheet + WEBVTT index ONCE and serve
///      scrub previews by cropping the sprite sub-rect for the scrubbed time, so a title brand new to this
///      device shows previews immediately from the community, with no local generation.
///
///   2. UPLOAD-AFTER-GENERATE (`buildAndUpload`): after the device finishes generating its own local
///      trickplay set, pack the captured JPEG frames into one sprite-sheet, build a matching WEBVTT index,
///      and POST it (first-writer-wins; skipped when the fetch already returned a community set). Gated by a
///      setting and run off the main actor so it never blocks playback.
///
/// CONTENT KEY (computed identically by the Cloudflare Worker):
///   sha1("{imdb}:{season|0}:{episode|0}:{durationBucket}")  durationBucket = floor(duration/10)*10
/// Quality is deliberately NOT in the key (a 720p and 1080p of the same cut share previews); the duration
/// bucket keeps different cuts (theatrical vs extended, or a mismatched file) from colliding.
///
/// Privacy: uploads ONLY the generated sprite + vtt + the content key/metadata (imdb / season / episode /
/// duration-bucket). NEVER an account token, user id, or any PII; none is referenced here.
enum CommunityTrickplay {
    /// The trickplay edge base. Sourced from the RemoteConfig `endpoints.trickplay` dial (validated https +
    /// *.vortx.tv host, else the baked default), so the owner can repoint it with no app update. Baked default
    /// `https://trickplay.vortx.tv` == the shipping value; a null/invalid remote endpoint keeps that default.
    static var baseURL: String { RemoteConfig.snapshot.trickplayEndpoint.absoluteString }

    /// The setting gate (default on, like a normal feature). Mirrors the `stremiox.*` @AppStorage namespace
    /// the player already uses; the 0.4 rename seam (`stremiox.` -> `vortx.`) maps it via SettingsBackup.
    static let settingKey = "stremiox.communityTrickplay"

    static var isEnabled: Bool {
        // RemoteConfig fleet kill-switch `features.communityTrickplay`: a remote `false` force-disables the
        // community layer fleet-wide (fetch AND upload) if the worker is degraded. Baked default true =>
        // absent/null remote is identical to shipping; the user's own setting still governs.
        guard RemoteConfig.snapshot.isFeatureOn("communityTrickplay", default: true) else { return false }
        // Absent default = true. UserDefaults returns false for an unset bool, so check object presence.
        if UserDefaults.standard.object(forKey: settingKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: settingKey)
    }

    /// floor(duration/10)*10, matching the Worker's durationBucket.
    static func durationBucket(_ duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int(floor(duration / 10) * 10)
    }

    // MARK: - Coverage floor (mirrors the Worker, so a doomed upload is never POSTed)

    /// The Worker's serve floor (vortx-trickplay `decision.ts` MIN_SERVE_COVERAGE): a POST whose coverage is
    /// below this is answered `{stored:false, reason:"below_coverage_threshold"}` and discarded, so it is a
    /// wasted round-trip (and, on a shared household IP, eats the per-IP POST budget). Kept in sync with
    /// decision.ts; 0.02 == "play ~6 min of even a 3h film and it stores".
    static let minServeCoverage = 0.02

    /// Coverage of a would-be upload, computed identically to the Worker's `decision.ts` computeCoverage:
    /// clamp[0,1]( frame_count / max(1, round(durationBucket / interval_s)) ) for the GIVEN frame_count/interval.
    /// A prediction from the RETAINED ordinary cadence + session frame count is a conservative estimate, NOT exact
    /// match to what the Worker stores: when the session outgrows one sheet's tile budget, buildAndUpload
    /// decimates before POSTing, and decimation changes BOTH terms (fewer frames over a longer interval) with
    /// independent rounding, so the stored coverage can land either side of the raw estimate. uploadCanStore
    /// therefore does not rely on the raw number alone; it also evaluates the exact decimated frame_count/interval
    /// buildAndUpload will POST, so it never skips a sheet the Worker would keep. Guarded like the Worker (0 on any
    /// non-positive input).
    static func coverage(frameCount: Int, intervalS: Double, durationBucket: Int) -> Double {
        guard frameCount > 0, intervalS > 0, durationBucket > 0 else { return 0 }
        let expected = max(1, Int((Double(durationBucket) / intervalS).rounded()))
        return min(1, max(0, Double(frameCount) / Double(expected)))
    }

    /// Whether the client should spend a POST on this capture. Returns false ONLY when we can positively
    /// predict the Worker will reject it as below_coverage_threshold; when the duration/interval is unknown we
    /// CANNOT predict, so we fail-open (allow, today's behavior) and let the Worker decide. This never
    /// suppresses a legitimate upload (e.g. a debrid MKV whose bucket is provisional); it only skips the
    /// sub-floor uploads that were being fired ~every 60s and logged as a misleading "-> failed".
    static func uploadCanStore(frameCount: Int, intervalS: Double, durationBucket: Int) -> Bool {
        guard durationBucket > 0, intervalS > 0, frameCount > 0 else { return true }
        // Raw prediction: the sheet exactly as captured (no decimation).
        if coverage(frameCount: frameCount, intervalS: intervalS, durationBucket: durationBucket) >= minServeCoverage {
            return true
        }
        // Decimated prediction: when the session holds more frames than one sheet's tile budget, buildAndUpload
        // does NOT post the raw numbers; it strides the frames down and posts a smaller frame_count over a
        // proportionally larger interval. Because the coverage numerator rounds UP (ceil), the decimated sheet can
        // clear the floor the raw numbers miss, so predicting from the raw numbers alone would wrongly skip a
        // storable sheet. Mirror buildAndUpload's EXACT stride math (budget = min(count, maxTiles);
        // stride = ceil(count / budget); kept = ceil(count / stride); interval *= stride) reading the same live
        // `maxTiles` snapshot it reads, so the predicted sheet matches the POSTed one. Below this, both raw and
        // decimated are sub-floor => the Worker rejects either => skipping is correct.
        let maxTiles = max(1, RemoteConfig.snapshot.trickplayMaxTilesValue)
        guard frameCount > maxTiles else { return false }
        let budget = min(frameCount, maxTiles)
        let stride = Int(ceil(Double(frameCount) / Double(budget)))
        let decimatedCount = Int(ceil(Double(frameCount) / Double(stride)))
        let decimatedInterval = intervalS * Double(stride)
        return coverage(frameCount: decimatedCount, intervalS: decimatedInterval, durationBucket: durationBucket) >= minServeCoverage
    }

    /// sha1("{imdb}:{season|0}:{episode|0}:{durationBucket}") as lowercase hex. nil when the imdb id is not a
    /// real `tt…` id (ad-hoc paste-a-link plays have no shareable identity, so they never touch the service).
    static func contentKey(imdbId: String, season: Int?, episode: Int?, duration: Double) -> String? {
        guard imdbId.range(of: #"^tt\d{6,}$"#, options: .regularExpression) != nil else { return nil }
        let bucket = durationBucket(duration)
        guard bucket > 0 else { return nil }
        let raw = "\(imdbId):\(season ?? 0):\(episode ?? 0):\(bucket)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - TMDB-keyed plays -> IMDb identity

    /// The leading `tt…` id inside a raw id string ("tt15239678", "tt14452776:1:2"), or nil. Lets a meta's
    /// `behaviorHints.defaultVideoId` (often "tt…:s:e" on series) seed the shareable identity for free.
    static func ttPrefix(_ raw: String?) -> String? {
        guard let raw, let r = raw.range(of: #"^tt\d{6,}"#, options: .regularExpression) else { return nil }
        return String(raw[r])
    }

    /// tmdb->imdb map, persisted so each title resolves over the network at most ONCE per install. It is read
    /// from `cachedIMDbID` (any thread) and mutated from `resolveIMDbID` (detached tasks) concurrently, so
    /// every access goes through `tmdb2ttLock`. The UserDefaults write runs on a snapshot taken under the lock
    /// but is issued outside it, so a slow defaults write never holds off other readers.
    private static let tmdb2ttDefaultsKey = "stremiox.trickplay.tmdb2tt"
    private static let tmdb2ttLock = NSLock()
    private static var tmdb2ttCache: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: tmdb2ttDefaultsKey) as? [String: String]) ?? [:]
    }()

    /// Synchronous cache lookup: the tt id previously resolved for a raw `tmdb:…` library id, or nil.
    static func cachedIMDbID(for rawId: String) -> String? {
        let key = rawId.lowercased()
        tmdb2ttLock.lock(); defer { tmdb2ttLock.unlock() }
        return tmdb2ttCache[key]
    }

    /// Resolve a `tmdb:…` library id (the identity our hub/TMDB catalogs key plays with) to its `tt…` IMDb id,
    /// so those plays contribute + fetch community trickplay exactly like Cinemeta (`tt…`) plays. THE bug this
    /// kills: every play launched from the TMDB-backed catalogs was dropped by `contentKey`'s tt-guard, so an
    /// account browsing our own hub never fed the pool no matter the device.
    ///
    /// Resolution is our own keyless TMDB edge (`catalogs.vortx.tv/3/{movie|tv}/{id}/external_ids`, edge-signed,
    /// key injected server-side) with a direct-TMDB fallback when the user has a key. Tries the hinted media
    /// type first, then the other (a bare "tmdb:NNN" does not say movie-vs-tv). Cached persistently; fail-soft
    /// nil on an unparseable id / both lookups missing.
    static func resolveIMDbID(rawId: String, seriesHint: Bool) async -> String? {
        let cacheKey = rawId.lowercased()
        tmdb2ttLock.lock()
        let cached = tmdb2ttCache[cacheKey]
        tmdb2ttLock.unlock()
        if let cached { return cached }
        // "tmdb:693134" (canonical), tolerating "tmdb:movie:693134" / "tmdb:tv:693134".
        let parts = cacheKey.split(separator: ":").map(String.init)
        guard parts.first == "tmdb", let numeric = parts.dropFirst().first(where: { Int($0) != nil }) else { return nil }
        let explicit = parts.contains("tv") ? "tv" : (parts.contains("movie") ? "movie" : nil)
        let order = explicit.map { [$0] } ?? (seriesHint ? ["tv", "movie"] : ["movie", "tv"])
        for media in order {
            if let tt = await fetchExternalIMDbID(media: media, tmdbID: numeric) {
                tmdb2ttLock.lock()
                tmdb2ttCache[cacheKey] = tt
                let snapshot = tmdb2ttCache
                tmdb2ttLock.unlock()
                UserDefaults.standard.set(snapshot, forKey: tmdb2ttDefaultsKey)
                VXProbe.log("tp", "resolved \(VXProbeRedaction.identityToken(rawId)) -> \(VXProbeRedaction.identityToken(tt)) (\(media))")
                return tt
            }
        }
        return nil
    }

    /// One `external_ids` lookup: our keyless edge first (signed; worker holds the key), then TMDB direct with
    /// the user's own key when present. nil on any miss.
    private static func fetchExternalIMDbID(media: String, tmdbID: String) async -> String? {
        func read(_ url: URL?, sign: Bool) async -> String? {
            guard let url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 10)
            if sign { VortXEdgeAuth.sign(&req) }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return ttPrefix(obj["imdb_id"] as? String)
        }
        let edge = RemoteConfig.snapshot.catalogsEndpoint.absoluteString
        if let tt = await read(URL(string: "\(edge)/\(media)/\(tmdbID)/external_ids"), sign: true) { return tt }
        if let key = ApiKeys.tmdbKey() {
            // SECURITY: this URL carries the user's TMDB key as api_key=. Never log it verbatim (VXProbe / diag).
            return await read(URL(string: "https://api.themoviedb.org/3/\(media)/\(tmdbID)/external_ids?api_key=\(key)"), sign: false)
        }
        return nil
    }

    // MARK: - Fetch-first (L1 community layer)

    /// A community sprite-sheet ready to crop. `tiles` maps a frame index to its (x,y) origin in the sheet;
    /// `tileW`/`tileH` are the per-tile size; `intervalS` the seconds between tiles.
    struct Sheet {
        let image: ScrubImage
        let cgImage: CGImage
        let tileW: Int
        let tileH: Int
        let intervalS: Double
        let frameCount: Int
        let cols: Int
        /// nil means legacy metadata had no VTT; advertised VTT metadata is retained only after full validation.
        let cues: [TrickplayTimelineCue]?

        /// The cropped tile covering `time`, drawn from the sheet sub-rect. nil outside genuine VTT coverage.
        func crop(at time: Double) -> ScrubImage? {
            guard let cue = TrickplayTimeline.cue(
                at: time,
                parsedCues: cues,
                frameCount: frameCount,
                legacyInterval: intervalS,
                cols: cols,
                tileW: tileW,
                tileH: tileH
            ) else { return nil }
            let rect = CGRect(x: cue.x, y: cue.y, width: cue.width, height: cue.height)
            guard let sub = cgImage.cropping(to: rect) else { return nil }
            #if canImport(AppKit)
            return NSImage(cgImage: sub, size: NSSize(width: cue.width, height: cue.height))
            #else
            return UIImage(cgImage: sub)
            #endif
        }

        /// The exact tile covering `time`, or when `time` lands in a gap or outside both bounds, the nearest
        /// tile by time. Lets a scrub position always resolve to an approximate frame. nil only when the sheet
        /// has no usable tiles.
        func nearestCrop(at time: Double) -> ScrubImage? {
            if let exact = crop(at: time) { return exact }
            guard let cue = TrickplayTimeline.nearestCue(
                at: time,
                parsedCues: cues,
                frameCount: frameCount,
                legacyInterval: intervalS,
                cols: cols,
                tileW: tileW,
                tileH: tileH
            ) else { return nil }
            let rect = CGRect(x: cue.x, y: cue.y, width: cue.width, height: cue.height)
            guard let sub = cgImage.cropping(to: rect) else { return nil }
            #if canImport(AppKit)
            return NSImage(cgImage: sub, size: NSSize(width: cue.width, height: cue.height))
            #else
            return UIImage(cgImage: sub)
            #endif
        }
    }

    private struct FetchResponse: Decodable {
        let sprite: String
        let vtt: String?
        let tile_w: Int
        let tile_h: Int
        let interval_s: Double
        let frame_count: Int
        let cols: Int
    }

    enum FetchUnavailableReason { case metadataUnavailable, metadataInvalid, spriteUnavailable, advertisedIndexInvalid }

    enum FetchResult { case hit(Sheet), unavailable(FetchUnavailableReason), cancelled }

    private enum FetchStatus: Sendable {
        case response(data: Data, statusCode: Int); case unavailable, cancelled
        var isHTTP200: Bool { if case .response(_, 200) = self { return true }; return false }
    }

    private enum AssetEvent: Sendable { case sprite(FetchStatus), vtt(FetchStatus), deadline, cancelled }

    private enum AssetStageResult: Sendable {
        case ready(sprite: FetchStatus, vtt: FetchStatus?); case deadline(sprite: FetchStatus?, vtt: FetchStatus?); case cancelled
    }

    private static func remoteURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private static func request(_ request: URLRequest) async -> FetchStatus {
        guard !Task.isCancelled else { return .cancelled }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return Task.isCancelled ? .cancelled : .response(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return Task.isCancelled ? .cancelled : .unavailable
        }
    }

    private static func race(_ request: URLRequest, until deadline: ContinuousClock.Instant) async -> FetchStatus {
        await withTaskGroup(of: FetchStatus.self) { group in
            group.addTask { await self.request(request) }
            group.addTask { (try? await Task.sleep(until: deadline, clock: ContinuousClock())) == nil ? .cancelled : .unavailable }
            let result = await group.next() ?? .cancelled; group.cancelAll(); return result
        }
    }

    private static func fetchMetadata(at url: URL) async -> FetchStatus {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&request)
        return await race(request, until: deadline)
    }

    private static func fetchAssets(spriteURL: URL, vttURL: URL?) async -> AssetStageResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        return await withTaskGroup(of: AssetEvent.self) { group in
            var sprite: FetchStatus?
            var vtt: FetchStatus?
            group.addTask { .sprite(await request(URLRequest(url: spriteURL, timeoutInterval: 5))) }
            if let vttURL {
                group.addTask { .vtt(await request(URLRequest(url: vttURL, timeoutInterval: 5))) }
            }
            group.addTask { (try? await Task.sleep(until: deadline, clock: ContinuousClock())) == nil ? .cancelled : .deadline }
            while let event = await group.next() {
                switch event {
                case .sprite(let result):
                    sprite = result
                case .vtt(let result):
                    vtt = result
                case .deadline:
                    group.cancelAll(); return .deadline(sprite: sprite, vtt: vtt)
                case .cancelled:
                    group.cancelAll(); return .cancelled
                }
                if let sprite, vttURL == nil || vtt != nil {
                    group.cancelAll(); return .ready(sprite: sprite, vtt: vtt)
                }
            }
            return Task.isCancelled ? .cancelled : .deadline(sprite: sprite, vtt: vtt)
        }
    }

    /// GET the community set for `key` and, on a hit, download + decode the sprite and advertised index.
    /// Every failure is reduced to a finite redacted reason so callers never receive raw transport details.
    static func fetch(key: String) async -> FetchResult {
        guard !Task.isCancelled, let url = URL(string: "\(baseURL)/tp/\(key)") else {
            return Task.isCancelled ? .cancelled : .unavailable(.metadataUnavailable)
        }
        let metadata = await fetchMetadata(at: url)
        let data: Data
        switch metadata {
        case .cancelled: return .cancelled
        case .unavailable: return .unavailable(.metadataUnavailable)
        case .response(let body, 200):
            data = body
        case .response: return .unavailable(.metadataUnavailable)
        }
        guard !Task.isCancelled, let meta = try? JSONDecoder().decode(FetchResponse.self, from: data) else {
            return Task.isCancelled ? .cancelled : .unavailable(.metadataInvalid)
        }
        guard meta.frame_count > 0, meta.cols > 0, meta.tile_w > 0, meta.tile_h > 0, meta.interval_s.isFinite, meta.interval_s > 0, let spriteURL = remoteURL(meta.sprite) else {
            return .unavailable(.metadataInvalid)
        }
        let vttURL = meta.vtt.flatMap(remoteURL)
        guard meta.vtt == nil || vttURL != nil else { return .unavailable(.advertisedIndexInvalid) }

        let assets = await fetchAssets(spriteURL: spriteURL, vttURL: vttURL)
        let sprite: FetchStatus
        let advertisedVTT: FetchStatus?
        switch assets {
        case .cancelled: return .cancelled
        case .deadline(let partialSprite, let partialVTT):
            guard partialSprite?.isHTTP200 == true else { return .unavailable(.spriteUnavailable) }
            guard vttURL == nil || partialVTT?.isHTTP200 == true else { return .unavailable(.advertisedIndexInvalid) }
            return .unavailable(.spriteUnavailable)
        case .ready(let readySprite, let readyVTT):
            if case .cancelled = readySprite { return .cancelled }; if let readyVTT, case .cancelled = readyVTT { return .cancelled }
            sprite = readySprite
            advertisedVTT = readyVTT
        }
        guard case .response(let spriteData, 200) = sprite,
              let image = ScrubImage(data: spriteData), let cg = image.cgImageForCrop else {
            return .unavailable(.spriteUnavailable)
        }

        let cues: [TrickplayTimelineCue]?
        if vttURL != nil {
            guard let advertisedVTT, case .response(let vttData, 200) = advertisedVTT,
                  let raw = String(data: vttData, encoding: .utf8),
                  let parsed = TrickplayTimeline.parseVTT(
                      raw, frameCount: meta.frame_count, cols: meta.cols,
                      tileW: meta.tile_w, tileH: meta.tile_h
                  ), !parsed.isEmpty else {
                return .unavailable(.advertisedIndexInvalid)
            }
            cues = parsed
        } else {
            cues = nil
        }
        return .hit(Sheet(image: image, cgImage: cg, tileW: meta.tile_w, tileH: meta.tile_h,
                          intervalS: meta.interval_s, frameCount: meta.frame_count, cols: meta.cols,
                          cues: cues))
    }

    // MARK: - Upload-after-generate (sprite-sheet build + POST)

    /// One captured local frame: its JPEG bytes and the playback time it was grabbed at.
    struct CapturedFrame {
        let time: Double
        let jpeg: Data
    }

    /// The outcome of an upload attempt, so the caller can log honestly instead of collapsing everything that is
    /// not `stored` into "failed": `stored` (the Worker kept a NEW set), `rejected` (a 200 the Worker consciously
    /// declined, e.g. below_coverage_threshold or a keep-fuller race, carrying the Worker's reason), or `failed`
    /// (a real transport error, a non-200, or a local build failure that never POSTed).
    enum UploadOutcome {
        case stored
        case rejected(String)
        case failed
    }

    /// Build a sprite-sheet + WEBVTT index from the device's captured frames and POST it (first-writer-wins).
    /// Runs entirely off the main actor. Returns `.stored` only if the server stored a NEW set, `.rejected(reason)`
    /// for a 200 the Worker declined, and `.failed` for a transport/non-200 error or a local build failure that
    /// never POSTed. Never throws.
    ///
    /// `intervalS` is the caller's retained ordinary cadence (falling back to the capture dial). Frames are sorted
    /// and the cadence is re-derived from their timestamps before they are packed
    /// left-to-right / top-to-bottom into a grid, and each tile is downscaled to ~480x270 (16:9) so the
    /// sheet stays tiny. The WEBVTT maps each tile's time window to `sprite#xywh=x,y,w,h` (Jellyfin/Plex web
    /// convention); the app crops the sub-rect itself, so no native trickplay support is needed.
    static func buildAndUpload(
        key: String,
        imdbId: String,
        season: Int?,
        episode: Int?,
        durationBucket: Int,
        srcHeight: Int,
        intervalS: Double,
        frames: [CapturedFrame]
    ) async -> UploadOutcome {
        guard isEnabled,
              TrickplayOwnedWorkGate.permitsStage(
                  taskIsCancelled: Task.isCancelled
              ) else { return .failed }
        let retainedIndices = TrickplaySessionFrameRetention.retainedIndices(
            captureTimes: frames.map(\.time),
            limit: max(1, frames.count)
        )
        let sorted = retainedIndices.map { frames[$0] }
        let retainedInterval = TrickplayTimeline.nominalCadence(
            captureTimes: sorted.map(\.time),
            fallbackInterval: intervalS
        )
        // Store even a tiny capture (>=1 frame); the owner asked that even ~5s of coverage be kept + served.
        // Frame bounds come from the RemoteConfig `trickplay.minFrames`/`maxFrames` dials (clamped min 1..10,
        // max 30..600). Baked defaults (min 1, max 600) == the shipping literals, so a null/out-of-range
        // remote value is behaviorally identical to today.
        let frameBounds = RemoteConfig.snapshot.trickplayFrameBounds
        // The sheet builder below needs >= 2 tiles (`while budget >= 2`). Clamp the effective lower bound to 2 so a
        // 1-frame set is rejected up front with a clear reason instead of silently falling through the geometry loop
        // and failing at the floor with a misleading "compose/encode failure" log.
        let minFrames = max(2, frameBounds.min)
        guard sorted.count >= minFrames, sorted.count <= frameBounds.max else {
            VXProbe.log("tp", "buildAndUpload skipped: sorted=\(sorted.count) below buildable floor \(minFrames) (need >=2 tiles)")
            return .failed
        }

        // Bound one sheet to a 3 MB-safe tile budget. A long watch produces far more 480x270 tiles than fit
        // under the worker's 3 MB cap, so the full-session sheet blew the cap and the upload was dropped before
        // the POST ever fired (the "frames=401 -> failed" case). Instead of TRUNCATING to the first N tiles
        // (which would only ever preview the film's opening), DECIMATE evenly across the whole capture so the
        // sheet still spans the entire duration, just at a coarser scrub interval. A short watch (<= budget) keeps
        // stride 1 and advertises its retained ordinary cadence.
        let maxTiles = max(1, RemoteConfig.snapshot.trickplayMaxTilesValue)
        // Tile size: 16:9 at 320 wide. Smaller than the 480px local capture so a `maxTiles`-tile sheet stays a
        // fraction of the pixels of the old 480x270 sheet, keeping q0.7 under the 3 MB cap in the common case.
        let tileW = 320, tileH = 180
        let maxBytes = 3 * 1024 * 1024

        // UNCONDITIONAL byte-bound. A sheet must satisfy TWO server limits: <= 3 MB (MAX_UPLOAD_BYTES) and
        // >= 2 frames (the worker rejects frame_count < MIN_FRAME_COUNT=2). Start at the configured tile budget
        // and, on a 3 MB overflow OR a compose/encode failure, HALVE the budget and rebuild the WHOLE geometry
        // (stride, effective frames, effectiveInterval, cols, rows) together so the render, the vtt, and the meta
        // always describe ONE consistent grid. The floor is 2 tiles: a 2-tile 320x180 sheet (640x180) cannot
        // approach 3 MB, so a legitimate capture is never dropped for size, only ever for a true allocation or
        // encoder failure at the floor. Coverage is NOT invariant under decimation (the numerator ceils up and the
        // denominator re-rounds, so it can land either side of the raw value); uploadCanStore predicts the exact
        // decimated frame_count and interval this posts, so a sheet the worker would keep is never skipped.
        var budget = min(sorted.count, maxTiles)
        var picked: (
            jpeg: Data,
            frames: [CapturedFrame],
            cueEndFences: [Double?],
            cols: Int,
            interval: Double
        )?
        while budget >= 2 {
            guard TrickplayOwnedWorkGate.permitsStage(
                taskIsCancelled: Task.isCancelled
            ) else { return .failed }
            let stride = sorted.count > budget ? Int(ceil(Double(sorted.count) / Double(budget))) : 1
            let targetCount = Int(ceil(Double(sorted.count) / Double(stride)))
            let effectiveIndices = TrickplaySessionFrameRetention.evenlySpacedIndices(
                count: sorted.count,
                targetCount: targetCount
            )
            let effective = effectiveIndices.map { sorted[$0] }
            let effectiveInterval = retainedInterval * Double(stride)
            guard let cueEndFences = TrickplayTimeline.selectedCueEndFences(
                retainedCaptureTimes: sorted.map(\.time),
                selectedIndices: effectiveIndices,
                retainedCadence: retainedInterval
            ) else {
                VXProbe.log("tp", "buildAndUpload could not propagate retained timeline gaps -> dropped")
                return .failed
            }
            let cols = max(1, Int(ceil(sqrt(Double(effective.count)))))
            let rows = Int(ceil(Double(effective.count) / Double(cols)))

            guard let composed = renderSheetImage(frames: effective, tileW: tileW, tileH: tileH, cols: cols, rows: rows) else {
                VXProbe.log("tp", "buildAndUpload compose FAILED tiles=\(effective.count) cols=\(cols) rows=\(rows) budget=\(budget) -> re-decimate")
                if budget == 2 { break }
                budget = max(2, budget / 2)
                continue
            }
            var fit: Data?
            for q in [0.7, 0.5, 0.4] {
                guard TrickplayOwnedWorkGate.permitsStage(
                    taskIsCancelled: Task.isCancelled
                ) else { return .failed }
                if let d = composed.jpegData(quality: CGFloat(q)), d.count <= maxBytes { fit = d; break }
            }
            if let fit {
                picked = (fit, effective, cueEndFences, cols, effectiveInterval)
                break
            }
            VXProbe.log("tp", "buildAndUpload over 3MB at q0.4 tiles=\(effective.count) cols=\(cols) rows=\(rows) budget=\(budget) -> re-decimate")
            if budget == 2 { break }
            budget = max(2, budget / 2)
        }
        guard let picked else {
            VXProbe.log("tp", "buildAndUpload could not build a >=2-tile sheet under 3MB (compose/encode failure at floor, sorted=\(sorted.count)) -> dropped")
            return .failed
        }

        guard let vtt = TrickplayTimeline.makeVTT(
            captureTimes: picked.frames.map(\.time),
            nominalInterval: picked.interval,
            gapFenceInterval: retainedInterval,
            cueEndFences: picked.cueEndFences,
            cols: picked.cols,
            tileW: tileW,
            tileH: tileH
        ) else {
            VXProbe.log("tp", "buildAndUpload could not build a valid timestamp VTT -> dropped")
            return .failed
        }

        let meta: [String: Any] = [
            "imdb": imdbId,
            "season": season ?? 0,
            "episode": episode ?? 0,
            "durationBucket": durationBucket,
            "frame_count": picked.frames.count,
            "tile_w": tileW,
            "tile_h": tileH,
            "interval_s": picked.interval,
            "cols": picked.cols,
            "src_height": srcHeight,
        ]
        guard TrickplayOwnedWorkGate.permitsStage(
            taskIsCancelled: Task.isCancelled
        ) else { return .failed }
        return await post(key: key, sprite: picked.jpeg, vtt: vtt, meta: meta)
    }

    /// Compose the frames into one sheet bitmap and return the composed CGImage (the caller JPEG-encodes it,
    /// re-encoding at descending quality until it fits the upload cap). Each frame is drawn scaled-to-fill into
    /// its tile cell. Returns nil on any drawing failure.
    private static func renderSheetImage(frames: [CapturedFrame], tileW: Int, tileH: Int, cols: Int, rows: Int) -> CGImage? {
        let sheetW = cols * tileW, sheetH = rows * tileH
        guard sheetW > 0, sheetH > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        ctx.interpolationQuality = .medium

        for (i, frame) in frames.enumerated() {
            guard TrickplayOwnedWorkGate.permitsStage(
                taskIsCancelled: Task.isCancelled
            ) else { return nil }
            guard let src = ScrubImage(data: frame.jpeg)?.cgImageForCrop else { continue }
            let col = i % cols
            let row = i / cols
            // CGContext origin is bottom-left; lay tiles out top-to-bottom so the index order matches the vtt.
            let y = (rows - 1 - row) * tileH
            ctx.draw(src, in: CGRect(x: col * tileW, y: y, width: tileW, height: tileH))
        }
        return ctx.makeImage()
    }

    /// POST the multipart body. `.stored` only on `{ ok:true, stored:true }`; a 200 the Worker declined is
    /// `.rejected(reason)` (the Worker's `reason`, e.g. below_coverage_threshold or a keep-fuller race); a
    /// transport error, a non-200, or a body we cannot build is `.failed`. Never throws.
    private static func post(key: String, sprite: Data, vtt: String, meta: [String: Any]) async -> UploadOutcome {
        guard TrickplayOwnedWorkGate.permitsStage(
                  taskIsCancelled: Task.isCancelled
              ),
              let url = URL(string: "\(baseURL)/tp/\(key)"),
              let metaJSON = try? JSONSerialization.data(withJSONObject: meta),
              let metaString = String(data: metaJSON, encoding: .utf8) else { return .failed }

        let boundary = "vortx-tp-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        // sprite file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"sprite\"; filename=\"sprite.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(sprite)
        body.append("\r\n".data(using: .utf8)!)
        // vtt file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"vtt\"; filename=\"index.vtt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/vtt\r\n\r\n".data(using: .utf8)!)
        body.append(vtt.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        // meta field
        field("meta", metaString)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        req.httpBody = body
        VortXEdgeAuth.sign(&req)   // gated host (trickplay.vortx.tv /tp/<key> POST): stamp X-VX-Ts / X-VX-Sig
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let ok = (obj?["ok"] as? Bool) == true
            let stored = (obj?["stored"] as? Bool) == true
            // Probe the POST so a failed upload (edge-auth sig rejection, 4xx, worker error) is visible with its
            // reason in the terminal log, not just a silent false. Trim the body to the first 200 chars.
            //
            // The URL is logged as endpoint only (host + path). `absoluteString` carried the signed query and
            // the catalog id in the path components, and the endpoint is the entire triage value here: which
            // worker route answered, with what status. The body head still passes the sink scrubber.
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
            let bodyHead = String(bodyStr.prefix(200))
            VXProbe.log("tp", "POST \(Self.endpointLabel(url)) httpStatus=\(code) ok=\(ok ? "true" : "false") stored=\(stored ? "true" : "false") body=\(bodyHead)")
            guard code == 200 else { return .failed }
            if stored { return .stored }
            // 200 but not stored: the Worker accepted the request and consciously declined it. Surface its `reason`
            // (below_coverage_threshold, a keep-fuller race, a frameBounds drop) so the caller logs "rejected", not
            // "failed". Fall back to a generic label if the Worker omitted a machine reason.
            let reason = (obj?["reason"] as? String) ?? "declined"
            return .rejected(reason)
        } catch {
            let errHead = String(String(describing: error).prefix(200))
            VXProbe.log("tp", "POST \(Self.endpointLabel(url)) httpStatus=err ok=false stored=false body=\(errHead)")
            return .failed
        }
    }

    /// `scheme://host/path`: the query and fragment are DROPPED at the producer because they carry the
    /// signed edge auth, and no pattern rule should have to be the thing that notices. The path is kept
    /// because the route is the triage value ("which worker endpoint answered"); the catalog id inside it is
    /// an id SHAPE, which is the one case the sink scrubber is genuinely good at. Same spelling as
    /// `MPVMetalViewController.loadFile` uses for its own play URL.
    private static func endpointLabel(_ url: URL) -> String {
        "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)"
    }
}

// MARK: - Cross-platform image helpers

extension ScrubImage {
    /// A CGImage suitable for cropping/drawing, on both AppKit and UIKit.
    var cgImageForCrop: CGImage? {
        #if canImport(AppKit)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}

extension CGImage {
    /// JPEG-encode a CGImage at the given quality, on both platforms.
    func jpegData(quality: CGFloat) -> Data? {
        #if canImport(AppKit)
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return UIImage(cgImage: self).jpegData(compressionQuality: quality)
        #endif
    }
}
#endif
