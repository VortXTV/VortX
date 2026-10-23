// Infuse round trip: the play link VortX sends and the callback Infuse returns.
// Run: scripts/test-infuse-return.sh

import Foundation

struct PlaybackMeta: Hashable {
    let libraryId: String
    let videoId: String
    let type: String
    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?
}

private var failures = 0
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
enum InfuseReturnPolicyTests {
    static func main() {
        let token = "0123456789abcdef0123456789abcdef"
        let stream = URL(string: "https://cdn.example.test/media/Show.mkv?token=a&b=c%20d")!
        let episode = PlaybackMeta(libraryId: "tt3581920", videoId: "tt3581920:1:2", type: "series",
                                   name: "The Last of Us", poster: nil, season: 1, episode: 2)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let handoff = InfuseReturnPolicy.makeHandoff(token: token, stream: stream, meta: episode,
                                                     profileID: "8E6A3C1D-0000-4000-8000-000000000001",
                                                     durationSeconds: 3_000, now: now)

        // The play link.
        let success = InfuseReturnPolicy.callbackURL(scheme: "vortx", token: token, succeeded: true)!
        let failure = InfuseReturnPolicy.callbackURL(scheme: "vortx", token: token, succeeded: false)!
        check("callbacks carry the token in the path", success.absoluteString == "vortx://infuse-return/\(token)"
              && failure.absoluteString == "vortx://infuse-error/\(token)")
        let link = InfuseDeepLink.playURL(stream: stream, metadata: episode, startSeconds: 754.9, success: success, failure: failure)!
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        check("a stream URL with its own query survives intact", query["url"] == stream.absoluteString)
        check("start is whole seconds", query["position"] == "754")
        check("callbacks are passed through", query["x-success"] == success.absoluteString && query["x-error"] == failure.absoluteString)
        check("nested URLs never split the outer query", items.count == 5 && !(link.query ?? "").contains("&b="))
        check("no start under a second", InfuseDeepLink.playURL(stream: stream, metadata: episode, startSeconds: 0.4)
              .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.contains { $0.name == "position" } == false)
        check("garbage starts are dropped", InfuseReturnPolicy.startPosition(.nan) == nil
              && InfuseReturnPolicy.startPosition(-5) == nil && InfuseReturnPolicy.startPosition(1e12) == nil)
        check("handoff keeps the profile in canonical case", handoff.profileID == "8e6a3c1d-0000-4000-8000-000000000001")

        // The callback.
        func returned(_ position: String?, played: String? = stream.absoluteString, host: String = "infuse-return") -> URL {
            var c = URLComponents(); c.scheme = "vortx"; c.host = host; c.path = "/" + token
            var q: [URLQueryItem] = []
            if let played { q.append(URLQueryItem(name: "lastPlayedUrl", value: played)) }
            if let position { q.append(URLQueryItem(name: "position", value: position)) }
            c.queryItems = q.isEmpty ? nil : q
            return c.url!
        }
        let back = InfuseReturnPolicy.parse(returned("1834"), scheme: "vortx")
        check("Infuse's success callback parses", back == .init(token: token, succeeded: true,
                                                                lastPlayedURL: stream.absoluteString, positionSeconds: 1834))
        check("the stopping point is saved against the known runtime",
              InfuseReturnPolicy.progress(for: handoff, callback: back!).map { [$0.position, $0.duration] } == [1834, 3000])
        check("past the runtime counts as finished, never beyond it",
              InfuseReturnPolicy.progress(for: handoff, callback: InfuseReturnPolicy.parse(returned("3500"), scheme: "vortx")!)?.position == 3000)
        check("closing Infuse straight away saves nothing",
              InfuseReturnPolicy.progress(for: handoff, callback: InfuseReturnPolicy.parse(returned("3"), scheme: "vortx")!) == nil)
        check("a different file saves nothing",
              InfuseReturnPolicy.progress(for: handoff, callback: InfuseReturnPolicy.parse(returned("900", played: "https://other.test/x.mkv"), scheme: "vortx")!) == nil)
        check("a callback without lastPlayedUrl still saves",
              InfuseReturnPolicy.progress(for: handoff, callback: InfuseReturnPolicy.parse(returned("900", played: nil), scheme: "vortx")!)?.position == 900)
        check("an error callback saves nothing",
              InfuseReturnPolicy.progress(for: handoff, callback: InfuseReturnPolicy.parse(returned("900", host: "infuse-error"), scheme: "vortx")!) == nil)
        let unknownRuntime = InfuseReturnPolicy.makeHandoff(token: token, stream: stream, meta: episode, profileID: "p",
                                                            durationSeconds: .infinity, now: now)
        check("without a runtime nothing is invented", unknownRuntime.durationSeconds == nil
              && InfuseReturnPolicy.progress(for: unknownRuntime, callback: back!) == nil)
        check("garbage positions parse as missing", InfuseReturnPolicy.parse(returned("nan"), scheme: "vortx")?.positionSeconds == nil
              && InfuseReturnPolicy.parse(returned("-4"), scheme: "vortx")?.positionSeconds == nil
              && InfuseReturnPolicy.parse(returned("1e300"), scheme: "vortx")?.positionSeconds == nil)
        check("other links and other schemes are not Infuse callbacks",
              InfuseReturnPolicy.parse(URL(string: "vortx://open?type=movie&id=tt1")!, scheme: "vortx") == nil
              && InfuseReturnPolicy.parse(returned("10"), scheme: "vortx-lite") == nil
              && InfuseReturnPolicy.parse(URL(string: "vortx://infuse-return/../../etc")!, scheme: "vortx") == nil
              && InfuseReturnPolicy.parse(URL(string: "vortx://infuse-return/\(token.uppercased())")!, scheme: "vortx") == nil)
        check("the scheme match ignores case", InfuseReturnPolicy.parse(returned("10"), scheme: "VortX") != nil)

        // The pending list.
        func aged(_ seconds: TimeInterval) -> InfuseHandoff {
            InfuseReturnPolicy.makeHandoff(token: token, stream: stream, meta: episode, profileID: "p", durationSeconds: 60,
                                           now: now.addingTimeInterval(-seconds))
        }
        check("stale handoffs expire", InfuseReturnPolicy.pruned([aged(10), aged(InfuseReturnPolicy.lifetime + 1)], now: now).count == 1)
        check("future-dated handoffs are dropped", InfuseReturnPolicy.pruned([aged(-3600)], now: now).isEmpty)
        let many = (0..<20).map { aged(Double($0)) }
        let kept = InfuseReturnPolicy.pruned(many, now: now)
        check("only the newest few are kept", kept.count == InfuseReturnPolicy.maxPending && kept.first == many.first)

        if failures > 0 { print("\n\(failures) check(s) failed"); exit(1) }
        print("\nAll Infuse return checks passed")
    }
}
