// =============================================================================
// ReproHarness - drives the REAL VortXMKVRemuxStream + VortXRemuxHLSServer end to
// end on macOS against synthesized multi-audio / multi-subtitle MKVs, playing the
// AVPlayer role over loopback HTTP. Repro for the Beta 7 (build 189) field
// regression: master held past the 10s start watchdog, audio renditions absent /
// unlabeled, silent remux death on resume, mid-play spool exhaustion.
//
// Each CHECK prints REPRO-RED (bug present) or REPRO-GREEN (fixed behavior).
// Exit code = number of REPRO-RED checks, so the same binary proves red-before /
// green-after.
// =============================================================================

import Foundation
import AVFoundation

let fixtureDir = "/tmp/dd-dvstall/fixtures"

@discardableResult
func fetch(_ base: String, _ path: String, timeout: TimeInterval = 45)
    -> (status: Int, body: Data, latency: Double) {
    let url = URL(string: base + path)!
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status = -1
    nonisolated(unsafe) var body = Data()
    let began = Date()
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? -1
        body = data ?? Data()
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 5)
    return (status, body, Date().timeIntervalSince(began))
}

func extinfSum(_ playlist: String) -> Double {
    playlist.split(separator: "\n")
        .filter { $0.hasPrefix("#EXTINF:") }
        .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",")[0]) }
        .reduce(0, +)
}

func segmentURIs(_ playlist: String) -> [String] {
    playlist.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
}

var redCount = 0
func check(_ name: String, red: Bool, detail: String) {
    print("\(red ? "REPRO-RED " : "REPRO-GREEN") \(name) :: \(detail)")
    if red { redCount += 1 }
}

struct ScenarioResult {
    var masterStatus = -1
    var masterLatency = 0.0
    var masterBody = ""
    var mediaBody = ""
    var startupRenderedSeconds = 0.0
    var audioMediaTags = 0
    var subtitleMediaTags = 0
    var nonEmptyVTTs = 0
    var totalVTTs = 0
    var remuxFailedDuringRun = false
    var producedAtEnd = 0
    var segmentsAtEnd = 0
    var producerFrozeWhileHealthy = false
}

func runScenario(name: String, fixture: String, startAt: Double,
                 consumeSeconds: Double) -> ScenarioResult {
    print("=== SCENARIO \(name) fixture=\(fixture) startAt=\(Int(startAt))s ===")
    var result = ScenarioResult()
    let input = URL(fileURLWithPath: "\(fixtureDir)/\(fixture)")
    guard FileManager.default.fileExists(atPath: input.path) else {
        print("FATAL fixture missing: \(input.path)")
        exit(2)
    }
    guard let (server, playlistURL) = VortXRemuxHLSServer.make(
        input: input, headers: nil, mode: .plain, startAtSeconds: startAt) else {
        print("FATAL server did not bind")
        exit(2)
    }
    let base = "http://127.0.0.1:\(server.port)"
    server.start()

    // AVPlayer role: one long-poll master fetch.
    let master = fetch(base, "/master.m3u8")
    result.masterStatus = master.status
    result.masterLatency = master.latency
    result.masterBody = String(decoding: master.body, as: UTF8.self)
    print("master status=\(master.status) latency=\(String(format: "%.1f", master.latency))s bytes=\(master.body.count)")
    print(result.masterBody)
    result.audioMediaTags = result.masterBody.split(separator: "\n")
        .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }.count
    result.subtitleMediaTags = result.masterBody.split(separator: "\n")
        .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }.count

    if master.status == 200 {
        let media = fetch(base, "/media.m3u8")
        result.mediaBody = String(decoding: media.body, as: UTF8.self)
        result.startupRenderedSeconds = extinfSum(result.mediaBody)
        let segs = segmentURIs(result.mediaBody)
        print("media status=\(media.status) segs=\(segs.count) rendered=\(String(format: "%.1f", result.startupRenderedSeconds))s")

        _ = fetch(base, "/init.mp4")
        for uri in segs.prefix(3) { _ = fetch(base, "/" + uri) }
        server.markEngineReady()

        // Audio rendition routes.
        for line in result.masterBody.split(separator: "\n")
            where line.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") && line.contains("URI=") {
            if let uri = line.split(separator: "\"").last(where: { $0.hasSuffix(".m3u8") }) {
                let ap = fetch(base, "/" + uri, timeout: 10)
                let apBody = String(decoding: ap.body, as: UTF8.self)
                let auris = segmentURIs(apBody)
                print("audio playlist \(uri) status=\(ap.status) segs=\(auris.count)")
                if let initURI = apBody.split(separator: "\n")
                    .first(where: { $0.hasPrefix("#EXT-X-MAP:") })?
                    .split(separator: "\"").dropFirst().first {
                    let ai = fetch(base, "/" + initURI, timeout: 10)
                    print("audio init \(initURI) status=\(ai.status) bytes=\(ai.body.count)")
                }
                for auri in auris.prefix(2) {
                    let aseg = fetch(base, "/" + auri, timeout: 10)
                    print("audio seg \(auri) status=\(aseg.status) bytes=\(aseg.body.count)")
                }
            }
        }

        // Subtitle rendition routes: fetch EVERY startup VTT of rendition 0 and count cue-bearing docs.
        for line in result.masterBody.split(separator: "\n")
            where line.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") {
            guard let uri = line.split(separator: "\"").last(where: { $0.hasSuffix(".m3u8") }) else { continue }
            let sp = fetch(base, "/" + uri, timeout: 10)
            let spBody = String(decoding: sp.body, as: UTF8.self)
            let suris = segmentURIs(spBody)
            print("subs playlist \(uri) status=\(sp.status) segs=\(suris.count)")
            for suri in suris {
                let vtt = fetch(base, "/" + suri, timeout: 10)
                let text = String(decoding: vtt.body, as: UTF8.self)
                result.totalVTTs += 1
                if text.contains("-->") { result.nonEmptyVTTs += 1 }
            }
            break   // rendition 0 is enough for the cue-presence check
        }

        // Steady-state consumption: poll + consume like a playing AVPlayer for `consumeSeconds`.
        var lastProduced = -1
        var lastProducedChange = Date()
        var served = Set<String>()
        let consumeEnd = Date().addingTimeInterval(consumeSeconds)
        while Date() < consumeEnd {
            let progress = server.mountProgress
            if progress.failed {
                result.remuxFailedDuringRun = true
                print("REMUX FAILED during steady state (produced=\(progress.producedBytes) segs=\(progress.segmentCount))")
                break
            }
            if progress.ended { break }
            if progress.producedBytes != lastProduced {
                lastProduced = progress.producedBytes
                lastProducedChange = Date()
            } else if Date().timeIntervalSince(lastProducedChange) > 8 {
                result.producerFrozeWhileHealthy = true
                print("PRODUCER FROZE >8s at produced=\(progress.producedBytes) segs=\(progress.segmentCount)")
                break
            }
            let refresh = fetch(base, "/media.m3u8", timeout: 10)
            if refresh.status != 200 {
                result.remuxFailedDuringRun = true
                print("media.m3u8 -> \(refresh.status) during steady state")
                break
            }
            for uri in segmentURIs(String(decoding: refresh.body, as: UTF8.self)).prefix(6)
                where !served.contains(uri) {
                served.insert(uri)
                _ = fetch(base, "/" + uri, timeout: 10)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        let final = server.mountProgress
        result.producedAtEnd = final.producedBytes
        result.segmentsAtEnd = final.segmentCount
        if final.failed { result.remuxFailedDuringRun = true }
        print("steady-state end produced=\(final.producedBytes) segs=\(final.segmentCount) failed=\(final.failed) ended=\(final.ended)")
    } else {
        let progress = server.mountProgress
        print("master DID NOT SERVE (status=\(master.status)); progress produced=\(progress.producedBytes) segs=\(progress.segmentCount) init=\(progress.initPublished) failed=\(progress.failed)")
        if progress.failed { result.remuxFailedDuringRun = true }
    }

    server.invalidate()
    Thread.sleep(forTimeInterval: 0.5)
    return result
}

// MARK: - REAL-CONSUMER gate: an actual AVPlayer plays the served stream continuously.
//
// The production-side scenarios below drive the server the way a well-behaved client would, but they cannot
// observe CONSUMPTION dynamics - the build 190 field regression (media window sliding at production speed,
// AVPlayer skip/stall/demote) passed all of them. This scenario is the gate that catches that class: a real
// AVFoundation HLS client plays for a minute and its clock must advance continuously with no seek-jumps.

struct ConsumerResult {
    var reachedSeconds = 0.0
    var wallSeconds = 0.0
    var maxForwardJump = 0.0
    var maxBackwardJump = 0.0
    var longestStall = 0.0
    var itemError: String?
    var remuxFailed = false
}

/// Serve the fixture over the conformance range server at a PACED byte rate, so the producer and the player
/// race the way they do against a real debrid link. Unpaced local input makes production instant, the live
/// playlist covers the whole file before AVPlayer's first fetch, and the client starts at the live edge -
/// a shape the field never produces and one that would let a windowing bug through this gate.
func startPacedSource(fixture: String, bytesPerSecond: Int) -> (process: Process, url: URL) {
    let portFile = "/tmp/dd-dvpin/paced-port-\(UUID().uuidString.prefix(8))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "test/player-conformance/range-server.py",
                         "\(fixtureDir)/\(fixture)", portFile, "127.0.0.1",
                         String(bytesPerSecond)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let deadline = Date().addingTimeInterval(10)
    var port = 0
    while Date() < deadline, port == 0 {
        if let text = try? String(contentsOfFile: portFile, encoding: .utf8),
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            port = value
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    guard port != 0 else { print("FATAL paced source did not start"); exit(2) }
    return (process, URL(string: "http://127.0.0.1:\(port)/\(fixture)")!)
}

func consumerScenario(name: String, fixture: String, startAt: Double,
                      playSeconds: Double, pacedBytesPerSecond: Int) -> ConsumerResult {
    print("=== CONSUMER \(name) fixture=\(fixture) startAt=\(Int(startAt))s play=\(Int(playSeconds))s paced=\(pacedBytesPerSecond)B/s ===")
    var result = ConsumerResult()
    let source = startPacedSource(fixture: fixture, bytesPerSecond: pacedBytesPerSecond)
    defer { source.process.terminate() }
    guard let (server, playlistURL) = VortXRemuxHLSServer.make(
        input: source.url, headers: nil, mode: .plain, startAtSeconds: startAt) else {
        print("FATAL consumer server did not bind"); exit(2)
    }
    server.start()
    let item = AVPlayerItem(url: playlistURL)
    let player = AVPlayer(playerItem: item)
    player.play()

    let wallStart = Date()
    var engineReadySent = false
    var lastTime = -1.0
    var hasAdvanced = false   // startup buffering before first motion is latency, not a mid-play stall
    var stallStart: Date?
    let deadline = wallStart.addingTimeInterval(playSeconds + 30)   // startup allowance beyond play window
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if item.status == .failed {
            result.itemError = item.error.map(String.init(describing:)) ?? "failed"
            break
        }
        if item.status == .readyToPlay, !engineReadySent {
            engineReadySent = true
            server.markEngineReady()   // mirror AVPlayerEngine's readyToPlay hook
            player.play()
        }
        let progress = server.mountProgress
        if progress.failed { result.remuxFailed = true; break }
        let now = item.currentTime().seconds
        guard now.isFinite else { continue }
        if lastTime >= 0 {
            let delta = now - lastTime
            if delta > 0.05 {
                if let began = stallStart {
                    result.longestStall = max(result.longestStall, Date().timeIntervalSince(began))
                    stallStart = nil
                }
                let expected = 0.6   // one 0.5s sample at rate 1.0 plus jitter
                if hasAdvanced, delta > expected {
                    result.maxForwardJump = max(result.maxForwardJump, delta)
                }
                hasAdvanced = true
            } else if delta < -0.5 {
                result.maxBackwardJump = min(result.maxBackwardJump, delta)
            } else if hasAdvanced {
                if stallStart == nil { stallStart = Date() }
            }
        }
        lastTime = max(lastTime, now)
        result.reachedSeconds = max(result.reachedSeconds, now)
        if result.reachedSeconds >= playSeconds { break }
    }
    if let began = stallStart {
        result.longestStall = max(result.longestStall, Date().timeIntervalSince(began))
    }
    result.wallSeconds = Date().timeIntervalSince(wallStart)
    print(String(format: "consumer end reached=%.1fs wall=%.1fs maxFwdJump=%.2fs maxBackJump=%.2fs longestStall=%.1fs itemError=%@ remuxFailed=%@",
                 result.reachedSeconds, result.wallSeconds, result.maxForwardJump,
                 result.maxBackwardJump, result.longestStall,
                 result.itemError ?? "none", String(result.remuxFailed)))
    player.pause()
    server.invalidate()
    Thread.sleep(forTimeInterval: 0.5)
    return result
}

// --- Scenario 1: fresh play, same-codec alternate + 2 text subs ---
let fresh = runScenario(name: "fresh-multiaudio", fixture: "fixture-multiaudio.mkv",
                        startAt: 0, consumeSeconds: 12)
// The first media playlist must start PINNED at sequence zero (the growing EVENT tail is by-design; the
// build 190 regression was the sequence racing ahead of the client at production speed). Master latency
// stays covered by the paced consumer gate below; against this unpaced local file the tail legitimately
// covers however much was already produced.
check("first media playlist starts pinned at sequence zero",
      red: !fresh.mediaBody.contains("#EXT-X-MEDIA-SEQUENCE:0"),
      detail: "first media playlist rendered=\(String(format: "%.1f", fresh.startupRenderedSeconds))s, seq0=\(fresh.mediaBody.contains("#EXT-X-MEDIA-SEQUENCE:0"))")
check("master served at all (fresh)", red: fresh.masterStatus != 200,
      detail: "status=\(fresh.masterStatus)")
check("same-codec alternate audio advertised with labels",
      red: fresh.audioMediaTags < 2,
      detail: "audio EXT-X-MEDIA tags=\(fresh.audioMediaTags) (need primary+alternate for eng/fre E-AC-3 pair)")
check("subtitle renditions advertised", red: fresh.subtitleMediaTags < 2,
      detail: "subtitle EXT-X-MEDIA tags=\(fresh.subtitleMediaTags)")
check("startup VTTs carry cues (fresh)", red: fresh.totalVTTs > 0 && fresh.nonEmptyVTTs == 0,
      detail: "nonEmpty=\(fresh.nonEmptyVTTs)/\(fresh.totalVTTs)")
check("remux alive through steady state (fresh)", red: fresh.remuxFailedDuringRun,
      detail: "failed=\(fresh.remuxFailedDuringRun) froze=\(fresh.producerFrozeWhileHealthy)")

// --- Scenario 2: RESUME play (the diag 8 field shape: every mount died) ---
let resume = runScenario(name: "resume-multiaudio", fixture: "fixture-multiaudio.mkv",
                         startAt: 60, consumeSeconds: 12)
check("master served on resume", red: resume.masterStatus != 200,
      detail: "status=\(resume.masterStatus) latency=\(String(format: "%.1f", resume.masterLatency))s (field: instant 404 -> item .failed -> HDR10 demote)")
check("remux alive on resume", red: resume.remuxFailedDuringRun,
      detail: "failed=\(resume.remuxFailedDuringRun)")
check("resume VTTs carry cues (timeline rebase)",
      red: resume.totalVTTs > 0 && resume.nonEmptyVTTs == 0,
      detail: "nonEmpty=\(resume.nonEmptyVTTs)/\(resume.totalVTTs) (field: unbroken 51B empty docs on the resume play)")

// --- Scenario 3: mixed-codec audio (the CEO's 4-language file shape) ---
let mixed = runScenario(name: "fresh-mixedcodec", fixture: "fixture-mixedcodec.mkv",
                        startAt: 0, consumeSeconds: 6)
check("primary audio labeled even without a qualifying alternate",
      red: mixed.audioMediaTags < 1,
      detail: "audio EXT-X-MEDIA tags=\(mixed.audioMediaTags) (field: audio=0 master -> AVPlayer shows one Unknown entry)")
check("master served (mixed)", red: mixed.masterStatus != 200,
      detail: "status=\(mixed.masterStatus)")

// --- REAL-CONSUMER gate: 60+ seconds of continuous AVPlayer playback, fresh AND resume ---
func judgeConsumer(_ label: String, _ run: ConsumerResult, playSeconds: Double) {
    check("consumer \(label): played \(Int(playSeconds))s continuously",
          red: run.reachedSeconds < playSeconds - 1,
          detail: String(format: "reached=%.1fs of %.0fs (wall=%.1fs)",
                         run.reachedSeconds, playSeconds, run.wallSeconds))
    check("consumer \(label): no seek-jumps",
          red: run.maxForwardJump > 3.0 || run.maxBackwardJump < -1.0,
          detail: String(format: "maxFwdJump=%.2fs maxBackJump=%.2fs (field: skips of ~15s every few seconds)",
                         run.maxForwardJump, run.maxBackwardJump))
    check("consumer \(label): no stall or failure",
          red: run.longestStall > 5.0 || run.itemError != nil || run.remuxFailed,
          detail: String(format: "longestStall=%.1fs itemError=%@ remuxFailed=%@",
                         run.longestStall, run.itemError ?? "none", String(run.remuxFailed)))
}

// ~2.6x the fixture's real-time byte rate: the producer leads the player modestly, the field shape.
let pacedRate = 400_000
let consumerFresh = consumerScenario(
    name: "fresh", fixture: "fixture-multiaudio.mkv", startAt: 0, playSeconds: 65,
    pacedBytesPerSecond: pacedRate)
judgeConsumer("fresh", consumerFresh, playSeconds: 65)
let consumerResume = consumerScenario(
    name: "resume", fixture: "fixture-multiaudio.mkv", startAt: 60, playSeconds: 65,
    pacedBytesPerSecond: pacedRate)
judgeConsumer("resume", consumerResume, playSeconds: 65)

print("=== REPRO SUMMARY: \(redCount) RED ===")
exit(Int32(min(redCount, 125)))
