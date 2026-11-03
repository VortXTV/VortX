internal import AetherEngine
import AppKit
import Foundation

@MainActor final class Receipt<Value: Sendable> {
    var result: Value?
    var waiter: CheckedContinuation<Value,Never>?
    func record(_ value: Value) { result = value; waiter?.resume(returning: value); waiter = nil }
    func value() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
struct Sample: Sendable { let time: Double; let settled: Bool }
@main @MainActor enum AetherPlayerObservationTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL \(message)"); exit(1) }
        checks += 1; print("PASS \(message)")
    }
    static func watching(_ player: VortXAetherPlayer) -> Receipt<Sample> {
        let receipt = Receipt<Sample>()
        player.onTime = { value in receipt.record(Sample(time: value, settled: player.positionIsSettled)) }
        return receipt
    }
    static func send(_ engine: AetherEngine, _ id: UInt64, _ outcome: SeekEvent.Outcome,
                     origin: SeekEvent.Origin = .programmatic, target: Double = 120) {
        engine.send(.init(id: id, origin: origin, outcome: outcome, target: target))
    }
    static func main() async throws {
        let player = try VortXAetherPlayer(); let engine = AetherEngine.latest!
        do {
            let read = watching(player)
            engine.state = .playing; engine.hasFirstFrameReadyForDisplay = true; engine.clock.currentTime = 12
            let sample = await read.value()
            check(sample.time == 12 && sample.settled, "normal displayed playback publishes settled clock")
        }
        do {
            let read = watching(player)
            engine.clock.currentTime = 120 // Exact upstream deferred-seek ordering: target FIRST.
            check(read.result == nil, "willSet clock cannot synchronously claim an optimistic target")
            send(engine, 1, .began, origin: .deferred); engine.isSeeking = true
            let sample = await read.value()
            check(sample.time == 120 && !sample.settled, "deferred target remains unsettled after seek event catches up")
        }
        do {
            let read = watching(player)
            engine.isSeeking = false; send(engine, 1, .stalled, origin: .deferred)
            check(!(await read.value()).settled, "stalled false seek level never proves a physical landing")
        }
        do {
            let read = watching(player)
            send(engine, 99, .rejected(.liveWithoutDVR))
            check(!(await read.value()).settled, "unrelated rejection preserves outstanding stalled uncertainty")
        }
        do {
            let read = watching(player)
            engine.state = .paused
            send(engine, 1, .landed(renderedTime: 118), origin: .deferred)
            let sample = await read.value()
            check(sample.time == 118 && sample.settled, "late paused landing publishes measured seek-axis position without another clock tick")
        }
        do {
            let read = watching(player)
            send(engine, 2, .began); engine.clock.currentTime = 200
            send(engine, 2, .superseded)
            check(!(await read.value()).settled, "supersession without a landing stays unsettled")
        }
        do {
            let read = watching(player)
            send(engine, 100, .rejected(.sourceNotSeekable))
            check(!(await read.value()).settled, "generic superseded then rejected cannot launder the old target")
        }
        do {
            let read = watching(player)
            send(engine, 3, .began); engine.clock.currentTime = 300; engine.isSeeking = true
            _ = await read.value()
            let next = watching(player)
            send(engine, 2, .landed(renderedTime: 200))
            engine.clock.currentTime = 301
            check(!(await next.value()).settled, "late predecessor landing cannot settle a successor seek")
        }
        do {
            let read = watching(player)
            engine.isSeeking = false; send(engine, 3, .landed(renderedTime: 302))
            let sample = await read.value()
            check(sample.time == 302 && sample.settled, "current seek's own landing restores settlement")
        }
        do {
            let read = watching(player)
            engine.state = .loading; engine.hasFirstFrameReadyForDisplay = false; engine.clock.currentTime = 500
            engine.state = .playing
            check(!(await read.value()).settled, "same-token internal reload loses first-frame authority")
            let shown = watching(player); engine.hasFirstFrameReadyForDisplay = true
            check((await shown.value()).settled, "internal reload's actual new first frame restores ordinary clock")
        }
        do {
            let read = watching(player)
            send(engine, 4, .began, origin: .deferred); engine.clock.currentTime = 600
            send(engine, 4, .superseded, origin: .deferred)
            send(engine, 101, .rejected(.sourceNotSeekable))
            check(!(await read.value()).settled, "deferred rejection without restored clock still fails closed")
        }
        do {
            let read = watching(player)
            send(engine, 5, .began, origin: .deferred); engine.clock.currentTime = 700
            send(engine, 5, .superseded, origin: .deferred)
            engine.clock.currentTime = 501 // 7.53.0 restores nativeHost.currentTime/sourceTime here.
            send(engine, 102, .rejected(.sourceNotSeekable))
            let sample = await read.value()
            check(sample.time == 501 && sample.settled, "forward-only deferred refusal accepts only its explicitly restored physical clock")
        }
        do {
            let read = watching(player)
            send(engine, 6, .began, origin: .deferred); engine.clock.currentTime = 800
            send(engine, 6, .superseded, origin: .deferred)
            _ = await read.value()
            let later = watching(player)
            engine.clock.currentTime = 502; send(engine, 103, .rejected(.sourceNotSeekable))
            check(!(await later.value()).settled, "later unrelated clock and rejection cannot reuse expired deferred-restoration evidence")
        }
        do {
            let read = Receipt<[String]>()
            player.onTracksChanged = { read.record(player.audioTracks.map(\.title)) }
            engine.audioTracks = [TrackInfo(id: 1, name: "Current audio")]
            check(read.result == nil, "track inventory never reads inside willSet")
            check(await read.value() == ["Current audio"], "actual wrapper callback reads newly stored inventory")
        }
        do {
            let retired = Receipt<Bool>()
            player.onTime = { _ in retired.record(true) }
            player.onTracksChanged = { retired.record(true) }
            engine.clock.currentTime = 999
            engine.audioTracks = [TrackInfo(id: 9, name: "Retired audio")]
            player.stop()
            // Negative asynchronous check: let already-ready actor tasks drain.
            // There are no I/O jobs or engine timers in this test-only module.
            try await Task.sleep(for: .milliseconds(10))
            check(retired.result == nil, "queued predecessor clock and inventory do not publish after synchronous stop")
            try await player.load(url: URL(string: "https://example.invalid/new")!, headers: nil,
                                  live: false, startPosition: nil)
            let time = watching(player)
            let tracks = Receipt<[String]>()
            player.onTracksChanged = { tracks.record(player.audioTracks.map(\.title)) }
            engine.state = .playing; engine.hasFirstFrameReadyForDisplay = true
            engine.clock.currentTime = 42
            engine.audioTracks = [TrackInfo(id: 10, name: "Successor audio")]
            let next = await time.value()
            let nextTracks = await tracks.value()
            check(next.time == 42 && next.settled && nextTracks == ["Successor audio"],
                  "new session retains its own clock and inventory after predecessor retirement")
        }
        do {
            engine.subtitleTracks = [TrackInfo(id: 7, name: "Embedded English")]
            player.selectSubtitleTrack(id: 7)
            check(engine.activeSubtitleTrackIndex == 7 && player.activeSubtitleTrackID == 7,
                  "upstream TrackInfo stream id passes unchanged through embedded text selection")
            var text: String?
            player.onSubtitleText = { text = $0 }
            engine.clock.sourceTime = 3
            engine.subtitleCues = [SubtitleCue(id: 900, startTime: 2, endTime: 4, body: .text("Embedded text"))]
            check(text == "Embedded text", "actual wrapper publishes active embedded text cue")
            player.clearSubtitle()
            check(text == nil, "Off clears embedded text cue publication")
        }
        do {
            let canvas = player.view.subviews.compactMap { $0 as? VortXAetherSubtitleCanvas }.first!
            canvas.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = SubtitleImage(cgImage: context.makeImage()!,
                position: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.1),
                canvasSize: CGSize(width: 1920, height: 1080))
            engine.clock.sourceTime = 3
            engine.subtitleCues = [SubtitleCue(id: 901, startTime: 2, endTime: 4, body: .image(image))]
            check(canvas.imageLayers.count == 1 && canvas.imageLayers[0].contents != nil,
                  "active embedded bitmap reaches an actual image layer instead of being discarded")
            let frame = VortXAetherSubtitleCanvas.imageRect(position: image.position, canvas: image.canvasSize,
                video: CGSize(width: 1920, height: 1080), bounds: canvas.bounds, mode: "fit")
            check(abs(frame.minY - 640.625) < 0.001 && abs(frame.width - 500) < 0.001,
                  "bitmap geometry uses top-origin authored position within letterboxed video")
            check(abs(canvas.imageLayers[0].frame.minY - frame.minY) < 0.001
                    && abs(canvas.imageLayers[0].frame.width - frame.width) < 0.001,
                  "actual bitmap layer uses the admitted authored geometry")
            engine.subtitleCues = [SubtitleCue(id: 901, startTime: 2, endTime: 4,
                body: .image(SubtitleImage(cgImage: image.cgImage,
                    position: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1))))]
            check(canvas.imageLayers[0].frame != frame, "reused cue id cannot cache an earlier bitmap geometry")
            check(VortXAetherSubtitleCanvas.imageRect(position: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1),
                canvas: .zero, video: CGSize(width: 1920, height: 1080), bounds: canvas.bounds, mode: "fit") == .zero,
                  "nonfinite authored geometry is rejected before reaching CoreAnimation")
            let cue = CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.1)
            let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            func geometry(_ coded: CGSize, _ display: CGSize, _ mode: String,
                          authored: CGSize? = nil, measured: CGRect? = nil) -> CGRect {
                VortXAetherSubtitleCanvas.imageRect(position: cue, canvas: authored ?? coded,
                    video: coded, bounds: square, mode: mode, displayVideo: display, measuredVideoRect: measured)
            }
            let hd = CGSize(width: 1920, height: 1080), dvd = CGSize(width: 720, height: 576)
            let dvdDisplay = CGSize(width: 1024, height: 576)
            let stretched = geometry(hd, hd, "stretch")
            check(abs(stretched.minY - 750) < 0.001 && abs(stretched.height - 100) < 0.001,
                  "stretch independently maps authored subtitle Y and height with the stretched video")
            let fill = geometry(hd, hd, "fill")
            check(abs(fill.minY - 750) < 0.001 && abs(fill.height - 100) < 0.001
                    && abs(fill.minX - 55.5555556) < 0.001,
                  "fill follows the centered cropped picture rectangle rather than the fit rectangle")
            let dvdFit = geometry(dvd, dvdDisplay, "fit")
            check(abs(dvdFit.minY - 640.625) < 0.001 && abs(dvdFit.height - 56.25) < 0.001,
                  "anamorphic720x576 displays16x9 while authored subtitle coordinates remain coded-axis")
            let dvdStretch = geometry(dvd, dvdDisplay, "stretch")
            check(abs(dvdStretch.minY - 750) < 0.001 && abs(dvdStretch.height - 100) < 0.001,
                  "anamorphic DVD stretch uses independent display-axis scaling")
            let cropped = geometry(CGSize(width: 1920, height: 800), CGSize(width: 1920, height: 800),
                "fit", authored: hd)
            check(abs(cropped.minY - 640.625) < 0.001 && abs(cropped.height - 56.25) < 0.001,
                  "taller authored subtitle canvas retains captions in cropped-rip letterbox bars")
            let measured = geometry(dvd, hd, "fit", measured: CGRect(x: 40, y: 100, width: 800, height: 450))
            check(abs(measured.minY - 437.5) < 0.001 && abs(measured.height - 45) < 0.001,
                  "native measured picture rectangle outranks reconstructed display aspect")
            engine.sourceVideoWidth = 720; engine.sourceVideoHeight = 576
            engine.sourceVideoPixelAspectRatio = 64.0 / 45.0
            engine.softwareDisplaySize = dvdDisplay
            engine.subtitleCues = [SubtitleCue(id: 903, startTime: 2, endTime: 6,
                body: .image(SubtitleImage(cgImage: image.cgImage, position: cue, canvasSize: dvd)))]
            check(abs(canvas.imageLayers[0].frame.minY - 640.625) < 0.001,
                  "actual wrapper uses authoritative software display size for anamorphic bitmap presentation")
            engine.clock.sourceTime = 6
            check(canvas.imageLayers.isEmpty, "bitmap clears exactly at its exclusive cue end")
            engine.subtitleTracks = [TrackInfo(id: 11, name: "English"), TrackInfo(id: 12, name: "French")]
            engine.activeSubtitleTrackIndex = 11
            player.selectSecondarySubtitleTrack(id: 12)
            check(player.activeSecondarySubtitleTrackID == 12 && engine.isSecondarySubtitleActive,
                  "genuine secondary channel selects independently from the primary")
            player.selectSubtitleTrack(id: 12)
            check(player.activeSecondarySubtitleTrackID == nil && engine.activeSubtitleTrackIndex == 12,
                  "same track cannot remain primary and secondary simultaneously")
            engine.clock.sourceTime = 3
            engine.subtitleCues = [SubtitleCue(id: 902, startTime: 2, endTime: 6, body: .image(image))]
            check(canvas.imageLayers.count == 1, "bitmap is active immediately before explicit Off")
            player.clearSubtitle()
            check(canvas.imageLayers.isEmpty, "Off clears native bitmap presentation immediately")
        }
        player.stop()
        check(!player.positionIsSettled, "stop immediately retires stored settlement snapshot")
        print("\(checks) actual wrapper observation checks passed")
    }
}
