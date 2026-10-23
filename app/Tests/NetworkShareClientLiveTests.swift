// Network share client against the local fixture server (test/fixtures/network-share-server.py).
// Run: scripts/test-network-shares.sh  (starts and stops the server itself)

import Foundation

private var failures = 0
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
enum NetworkShareClientLiveTests {
    static func main() async {
        guard let port = CommandLine.arguments.dropFirst().first else { print("usage: <port>"); exit(2) }
        let good = NetworkShareClient.Login(username: "me", password: "pw")
        let bad = NetworkShareClient.Login(username: "me", password: "nope")
        let dav = NetworkSharePolicy.rootURL("127.0.0.1:\(port)/dav")!
        let web = NetworkSharePolicy.rootURL("127.0.0.1:\(port)/web")!

        let davKind = try? await NetworkShareClient.detect(root: dav, login: good)
        check("a WebDAV share is detected", davKind == .webdav)
        let webKind = try? await NetworkShareClient.detect(root: web, login: good)
        check("a web folder is detected", webKind == .http)
        do { _ = try await NetworkShareClient.detect(root: dav, login: bad); check("a wrong password is refused", false) }
        catch { check("a wrong password is refused", error as? NetworkShareError == .unauthorized) }
        do { _ = try await NetworkShareClient.detect(root: NetworkSharePolicy.rootURL("127.0.0.1:1/x")!, login: good); check("a dead address is unreachable", false) }
        catch { check("a dead address is unreachable", error as? NetworkShareError == .unreachable) }

        let davRoot = try? await NetworkShareClient.list(dav, kind: .webdav, root: dav, login: good)
        check("WebDAV root lists its folder and video, not the image",
              davRoot?.map(\.name) == ["Films", "Arrival (2016).mkv"] && davRoot?.first?.isFolder == true)
        if let films = davRoot?.first {
            let inside = try? await NetworkShareClient.list(films.url, kind: .webdav, root: dav, login: good)
            check("a WebDAV subfolder opens", inside?.map(\.name) == ["Dune Part Two.mkv"])
        }
        let webRoot = try? await NetworkShareClient.list(web, kind: .http, root: web, login: good)
        check("web folder root lists folder and video", webRoot?.map(\.name) == ["Shows", "The Matrix (1999).mp4"])
        let hop = try? await NetworkShareClient.list(URL(string: "\(web.absoluteString)hop/")!, kind: .http, root: web, login: good)
        check("a redirect inside the share is followed with the login", hop?.map(\.name) == ["S01E01.mkv"])
        do {
            _ = try await NetworkShareClient.list(URL(string: "\(dav.absoluteString)away/")!, kind: .webdav, root: dav, login: good)
            check("a redirect off the share is refused", false)
        } catch { check("a redirect off the share is refused", error as? NetworkShareError == .notAShare) }

        let matrix = URL(string: "\(web.absoluteString)The%20Matrix%20(1999).mp4")!
        let direct = try? await NetworkShareClient.resolveForPlayback(matrix, root: web, login: good)
        check("a file inside the share resolves to itself", direct == matrix)
        let moved = try? await NetworkShareClient.resolveForPlayback(URL(string: "\(web.absoluteString)moved.mkv")!, root: web, login: good)
        check("a redirect within the share resolves to its target", moved == matrix)
        do {
            _ = try await NetworkShareClient.resolveForPlayback(URL(string: "\(web.absoluteString)go-away.mkv")!, root: web, login: good)
            check("a file redirected off the share is refused", false)
        } catch { check("a file redirected off the share is refused", error as? NetworkShareError == .redirectedAway) }
        let arrival = URL(string: "\(dav.absoluteString)Arrival%20(2016).mkv")!
        let ranged = try? await NetworkShareClient.resolveForPlayback(arrival, root: dav, login: good)
        check("a server refusing HEAD is probed with a one-byte GET", ranged == arrival)
        do {
            _ = try await NetworkShareClient.resolveForPlayback(matrix, root: web, login: bad)
            check("playback with a wrong password is refused", false)
        } catch { check("playback with a wrong password is refused", error as? NetworkShareError == .unauthorized) }

        if failures > 0 { print("\n\(failures) check(s) failed"); exit(1) }
        print("\nAll live network share checks passed")
    }
}
