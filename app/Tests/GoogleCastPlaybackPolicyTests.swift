import Foundation

@main enum GoogleCastPlaybackPolicyTests {
    private final class ReconnectEndpoint {}
    static func main() {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if !condition() { failures += 1; print("FAIL: \(name)") }
        }
        let server = URL(string: "http://192.168.1.20:11470")!
        let hash = String(repeating: "a", count: 40)
        let torrent = server.appendingPathComponent("\(hash)/3")
        check("public HTTPS", ReceiverURLPolicy.permits(URL(string: "https://cdn.example/video.mp4")!))
        check("LAN requires choice", !ReceiverURLPolicy.permits(torrent))
        check("chosen LAN torrent", SourcePlayerChoicePolicy.canHandOffExternally(url: torrent, isTorrent: true,
              isUsenet: false, requestHeaders: nil, selectedServerURL: server))
        for address in ["192.168.1.42", "10.1.2.3", "172.20.1.2", "100.89.1.2", "nas.local", "nas.tailnet.ts.net"] {
            let ordinary = URL(string: "http://\(address):8096/Movies/Private/video.mp4")!
            check("ordinary external source keeps LAN/NAS/Tailscale compatibility without chosen server: \(address)",
                  SourcePlayerChoicePolicy.canHandOffExternally(url: ordinary, isTorrent: false,
                    isUsenet: false, requestHeaders: nil))
            check("ordinary header-dependent source still rejected: \(address)",
                  !SourcePlayerChoicePolicy.canHandOffExternally(url: ordinary, isTorrent: false,
                    isUsenet: false, requestHeaders: ["Authorization": "synthetic-test-value"]))
        }
        let tailServer = URL(string: "http://100.89.1.2:11470")!
        let tailTorrent = tailServer.appendingPathComponent("\(hash)/3")
        check("CGNAT is LAN scope", ReceiverURLPolicy.scope("100.89.1.2") == .lan)
        check("explicit selected Tailscale torrent admitted", SourcePlayerChoicePolicy.canHandOffExternally(
              url: tailTorrent, isTorrent: true, isUsenet: false, requestHeaders: nil, selectedServerURL: tailServer))
        check("unselected Tailscale torrent denied", !SourcePlayerChoicePolicy.canHandOffExternally(
              url: tailTorrent, isTorrent: true, isUsenet: false, requestHeaders: nil))
        check("wrong selected Tailscale origin denied", !SourcePlayerChoicePolicy.canHandOffExternally(
              url: tailTorrent, isTorrent: true, isUsenet: false, requestHeaders: nil,
              selectedServerURL: URL(string: "http://100.89.1.3:11470")))
        let publicServer = URL(string: "https://stream.example")!
        let publicTorrent = publicServer.appendingPathComponent("\(hash)/0")
        check("public torrent still requires selected server proof", !SourcePlayerChoicePolicy.canHandOffExternally(
              url: publicTorrent, isTorrent: true, isUsenet: false, requestHeaders: nil))
        check("explicit selected public torrent admitted", SourcePlayerChoicePolicy.canHandOffExternally(
              url: publicTorrent, isTorrent: true, isUsenet: false, requestHeaders: nil, selectedServerURL: publicServer))
        check("external compatibility does not authorize private Cast", !ReceiverURLPolicy.permits(
              URL(string: "http://100.89.1.2:8096/Movies/Private/video.mp4")!))
        check("selected Tailscale origin passes Cast endpoint gate", ReceiverURLPolicy.permits(tailTorrent, selectedServer: tailServer))
        check("ordinary external URL userinfo retains its original channel", SourcePlayerChoicePolicy.canHandOffExternally(
              url: URL(string: "http://viewer:synthetic@192.168.1.42/movie.mp4#part1"), isTorrent: false,
              isUsenet: false, requestHeaders: nil))
        check("choice pins exact origin", !ReceiverURLPolicy.permitsTorrent(torrent,
              selectedServer: URL(string: "http://192.168.1.21:11470")))
        check("server control is not a torrent media path", !ReceiverURLPolicy.permitsTorrent(
              server.appendingPathComponent("settings"), selectedServer: server))
        check("header restriction survives", !SourcePlayerChoicePolicy.canHandOffExternally(url: torrent,
              isTorrent: true, isUsenet: false, requestHeaders: ["Referer":"https://private.example"], selectedServerURL: server))
        check("Usenet restriction survives", !SourcePlayerChoicePolicy.canHandOffExternally(url: torrent,
              isTorrent: false, isUsenet: true, requestHeaders: nil, selectedServerURL: server))
        for host in ["127.0.0.1", "127.2.3.4", "127.1", "2130706433", "0x7f000001", "0177.0.0.1", "0.0.0.0",
                     "localhost", "foo.localhost", "169.254.169.254", "[::1]", "[::]", "[fe80::1]", "[::ffff:127.0.0.1]",
                     "metadata.google.internal", "[fd00:ec2::254]", "168.63.129.16", "100.100.100.200"] {
            let url = URL(string: "http://\(host)/\(hash)/0")!
            check("forbidden even when selected: \(host)", !ReceiverURLPolicy.permits(url, selectedServer: url))
            check("forbidden ordinary external endpoint: \(host)", !SourcePlayerChoicePolicy.canHandOffExternally(
                  url: url, isTorrent: false, isUsenet: false, requestHeaders: nil))
        }
        check("credentials cannot leave as URL userinfo", !ReceiverURLPolicy.permits(URL(string:"https://user:secret@cdn.example/a.mp4")!))
        check("Matroska MIME beats misleading extension", GoogleCastFormatPolicy.contentType(responseType:"video/x-matroska", url:URL(string:"https://cdn.example/movie.mp4")!) == nil)
        check("HLS MIME accepted", GoogleCastFormatPolicy.contentType(responseType:"application/vnd.apple.mpegurl", url:URL(string:"https://cdn.example/stream")!) != nil)
        var state = GoogleCastPlaybackPolicy()
        let owner = UUID(), other = UUID()
        state.begin(owner: owner, position: 50, duration: 600)
        check("current bound receiver load permits commands", state.permitsReceiverCommand(
              echoedOwner: owner.uuidString, onCurrentSession: true, onBoundClient: true))
        check("another sender's current load denies commands despite old owned UI", !state.permitsReceiverCommand(
              echoedOwner: other.uuidString, onCurrentSession: true, onBoundClient: true))
        check("missing receiver receipt denies commands", !state.permitsReceiverCommand(
              echoedOwner: nil, onCurrentSession: true, onBoundClient: true))
        check("old session cannot command even with the same load receipt", !state.permitsReceiverCommand(
              echoedOwner: owner.uuidString, onCurrentSession: false, onBoundClient: true))
        check("replaced client cannot command even with the same load receipt", !state.permitsReceiverCommand(
              echoedOwner: owner.uuidString, onCurrentSession: true, onBoundClient: false))
        check("unrelated session cannot publish", !state.sample(owner: other, position: 100, duration: 600))
        check("owned position observed", state.sample(owner: owner, position: 52, duration: 600))
        check("explicit seek accepted", state.seek(200))
        check("stale pre-seek sample ignored", !state.sample(owner: owner, position: 53, duration: 600))
        check("disconnect preserves requested seek", state.resumePosition == 200 && state.confirmedPosition == 52)
        check("seek acknowledgment settles", state.sample(owner: owner, position: 201, duration: 600) && state.pendingSeek == nil)
        let pauseRequest = state.requestPaused(true)
        let playRequest = state.requestPaused(false)
        state.observePaused(false)
        check("cached playing sample cannot clear rapid Pause then Play", state.pendingPaused == false)
        check("old Pause acknowledgment cannot settle latest Play", !state.acknowledgePause(generation: pauseRequest))
        state.observePaused(true, freshAfterAcknowledgement: true)
        check("disconnect preserves latest Play before its acknowledgment", state.pendingPaused == false)
        check("latest Play acknowledgment admitted", state.acknowledgePause(generation: playRequest))
        state.observePaused(false)
        check("cached sample after acknowledgment is insufficient", state.pendingPaused == false)
        state.observePaused(false, freshAfterAcknowledgement: true)
        check("fresh matching acknowledged Play settles intent", state.pendingPaused == nil)
        state.suspend()
        check("suspended receiver load denies commands", !state.permitsReceiverCommand(
              echoedOwner: owner.uuidString, onCurrentSession: true, onBoundClient: true))
        check("suspended sample cannot fabricate progress", !state.sample(owner: owner, position: 0, duration: 0))
        state.resume()
        check("matching resumed receiver permits commands", state.permitsReceiverCommand(
              echoedOwner: owner.uuidString, onCurrentSession: true, onBoundClient: true))
        check("huge values rejected", !state.sample(owner: owner, position: 1e300, duration: 1e300))
        state.retire()
        check("retired load denies commands", !state.permitsReceiverCommand(
              echoedOwner: owner.uuidString, onCurrentSession: true, onBoundClient: true))
        check("retired callback ignored", !state.sample(owner: owner, position: 250, duration: 600))
        // Actual reconnect policy with synthetic SDK identities and a deterministic monotonic clock.
        // These cases do not import GoogleCast or establish adapter/receiver callback delivery.
        var reconnect = GoogleCastPlaybackPolicy()
        let firstSession = ReconnectEndpoint(), firstClient = ReconnectEndpoint()
        let nextSession = ReconnectEndpoint(), nextClient = ReconnectEndpoint()
        reconnect.begin(owner: owner, position: 52, duration: 600)
        _ = reconnect.seek(200)
        _ = reconnect.requestPaused(true)
        reconnect.suspend(at: 100)
        check("real suspension starts finite reconnect without willResume", reconnect.reconnectDeadline == 115)
        check("suspension-only reconnect expires", reconnect.reconnectExpired(at: 115))
        reconnect.suspend(at: 104)
        check("repeated suspension or willResume cannot extend original attempt", reconnect.reconnectDeadline == 115)
        check("matching receipt before didResume cannot grant reconnect", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 105))
        reconnect.didResume(session: firstSession, client: nil, at: 106)
        check("didResume without a client grants no ready pair", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 106))
        reconnect.didResume(session: firstSession, client: firstClient, at: 107)
        check("same bound object with missing receipt cannot clear reconnect", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: nil,
              onCurrentSession: true, onCurrentClient: true, at: 108) && reconnect.reconnectDeadline == 115)
        check("same bound object with foreign receipt cannot clear reconnect", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: other.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 108) && reconnect.reconnectDeadline == 115)
        check("didResume exact current pair with matching receipt is ready", reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 108))
        check("ready session still must be current", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: false, onCurrentClient: true, at: 108))
        check("ready client still must be current", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: false, at: 108))
        check("replacement session requires its own didResume", !reconnect.permitsReconnect(
              session: nextSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 108))
        check("replacement client requires its own didResume", !reconnect.permitsReconnect(
              session: firstSession, client: nextClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 108))
        reconnect.didResume(session: nextSession, client: nextClient, at: 110)
        check("replacement readiness keeps earliest deadline", reconnect.reconnectDeadline == 115)
        check("replacement pair can confirm before original expiry", reconnect.permitsReconnect(
              session: nextSession, client: nextClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 114))
        check("old ready pair cannot authorize replacement generation", !reconnect.permitsReconnect(
              session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 114))
        check("expiry wins over matching same-tick receipt", !reconnect.permitsReconnect(
              session: nextSession, client: nextClient, echoedOwner: owner.uuidString,
              onCurrentSession: true, onCurrentClient: true, at: 115))
        reconnect.didResume(session: firstSession, client: firstClient, at: 116)
        check("late didResume cannot reset expired original bound", reconnect.reconnectDeadline == 115 &&
              !reconnect.permitsReconnect(session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
                onCurrentSession: true, onCurrentClient: true, at: 116))
        reconnect.resume()
        check("successful bind clears attempt but preserves seek pause and confirmed point",
              reconnect.reconnectDeadline == nil && !reconnect.suspended &&
              reconnect.pendingSeek == 200 && reconnect.pendingPaused == true && reconnect.confirmedPosition == 52)
        reconnect.didResume(session: firstSession, client: firstClient, at: 200)
        check("first resume without suspension starts its own finite bound", reconnect.reconnectDeadline == 215)
        reconnect.suspend(at: 205)
        check("a later willResume retires prior readiness without extending bound",
              reconnect.reconnectDeadline == 215 &&
              !reconnect.permitsReconnect(session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
                onCurrentSession: true, onCurrentClient: true, at: 206))
        weak var vanishedCandidate: ReconnectEndpoint?
        do {
            let candidate = ReconnectEndpoint()
            vanishedCandidate = candidate
            reconnect.suspend(at: 207)
        }
        check("weak candidate disappearance does not erase timeout", vanishedCandidate == nil &&
              reconnect.reconnectDeadline == 215 && reconnect.reconnectExpired(at: 215))
        reconnect.retire()
        check("retire clears attempt and denies stale ready proof", reconnect.reconnectDeadline == nil &&
              !reconnect.permitsReconnect(session: firstSession, client: firstClient, echoedOwner: owner.uuidString,
                onCurrentSession: true, onCurrentClient: true, at: 208))
        reconnect.begin(owner: other, position: 5, duration: 60)
        check("fresh explicit load has no previous reconnect attempt", reconnect.reconnectDeadline == nil && !reconnect.suspended)
        let native = URL(string:"http://127.0.0.1:53144")!
        let source = native.appendingPathComponent("\(hash)/0")
        check("relay pins actual native port", CastTorrentRelayPolicy.sourceIsPinned(source, nativeBase:native))
        check("relay rejects another listener", !CastTorrentRelayPolicy.sourceIsPinned(source, nativeBase:URL(string:"http://127.0.0.1:53145")!))
        check("relay never exposes settings", !CastTorrentRelayPolicy.sourceIsPinned(native.appendingPathComponent("settings"), nativeBase:native))
        let token = String(repeating:"b",count:64)
        let request = "GET /cast/\(token)/media.mp4 HTTP/1.1\r\nHost: 192.168.1.2:4321\r\nRange: bytes=10-19\r\n\r\n"
        check("token and range admitted", CastTorrentRelayPolicy.request(request,token:token) == .init(method:"GET",range:"bytes=10-19"))
        check("wrong token denied", CastTorrentRelayPolicy.request(request,token:String(repeating:"c",count:64)) == nil)
        check("query cannot select another upstream", CastTorrentRelayPolicy.request(request.replacingOccurrences(of:"media.mp4",with:"media.mp4?url=http://169.254.169.254"),token:token) == nil)
        check("encoded token path denied", CastTorrentRelayPolicy.request(request.replacingOccurrences(of:"/cast/",with:"/%63ast/"),token:token) == nil)
        check("request bodies denied", CastTorrentRelayPolicy.request(request.replacingOccurrences(of:"Range: bytes=10-19",with:"Content-Length: 1"),token:token) == nil)
        check("duplicate ranges denied", CastTorrentRelayPolicy.request(request.replacingOccurrences(of:"Range: bytes=10-19",with:"Range: bytes=10-19\r\nRange: bytes=20-29"),token:token) == nil)
        check("multi-range denied", CastTorrentRelayPolicy.request(request.replacingOccurrences(of:"bytes=10-19",with:"bytes=10-19,30-39"),token:token) == nil)
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("Google Cast owner, endpoint and relay policy checks passed")
    }
}
