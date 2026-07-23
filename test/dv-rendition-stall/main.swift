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

// --- Scenario 1: fresh play, same-codec alternate + 2 text subs ---
let fresh = runScenario(name: "fresh-multiaudio", fixture: "fixture-multiaudio.mkv",
                        startAt: 0, consumeSeconds: 12)
check("startup window fits the 10s start watchdog (rendered <= 8s)",
      red: fresh.startupRenderedSeconds > 8.0,
      detail: "first media playlist rendered=\(String(format: "%.1f", fresh.startupRenderedSeconds))s (field: 36s cohort held the master 12-15s while the chrome watchdog is 10s)")
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

print("=== REPRO SUMMARY: \(redCount) RED ===")
exit(Int32(min(redCount, 125)))
