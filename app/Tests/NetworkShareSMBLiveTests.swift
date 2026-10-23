// SMB client against a real Samba server: the fixture from test/fixtures/smb-share.sh, reached at
// VORTX_SMB_LIVE_SERVER (host:port). Run by scripts/test-network-shares.sh only when that is set.

import Foundation
@main enum SMBLive {
    static func check(_ condition: Bool, _ message: String) {
        if condition { print("PASS  " + message) } else { print("FAIL  " + message); exit(1) }
    }
    static func expect(_ expected: NetworkShareError, _ message: String, _ body: () async throws -> Void) async {
        do { try await body(); check(false, message + " (no error)") }
        catch let error as NetworkShareError { check(error == expected, message + " (\(error))") }
        catch { check(false, message + " (\(error))") }
    }

    static func main() async {
        guard let server = ProcessInfo.processInfo.environment["VORTX_SMB_LIVE_SERVER"] else { print("SKIP  no live SMB server"); return }
        let login = NetworkShareClient.Login(username: "tester", password: "s3cret")
        let movies = NetworkSharePolicy.smbRootURL("smb://\(server)/Movies")!
        do {
            let root = try await NetworkShareSMBClient.list(movies, root: movies, login: login)
            check(root.map(\.name) == ["Season 1", "Test Movie (2024).mkv"], "a share lists folders first, then videos, hidden and non-video files left out: \(root.map(\.name))")
            check(root[0].isFolder && root[0].url.absoluteString == "smb://\(server)/Movies/Season%201/", "a folder entry addresses its own folder")
            let season = try await NetworkShareSMBClient.list(root[0].url, root: movies, login: login)
            check(season.map(\.name) == ["S01E01.mp4"], "a subfolder lists its own videos")
            let play = NetworkSharePolicy.smbPlaybackURL(root[1].url, root: movies, username: login.username, password: login.password)
            check(play?.absoluteString == "smb://tester:s3cret@\(server)/Movies/Test%20Movie%20(2024).mkv", "the playback address carries the login for FFmpeg")
            let public_ = NetworkSharePolicy.smbRootURL("smb://\(server)/Public")!
            let guest = try await NetworkShareSMBClient.list(public_, root: public_, login: .init(username: "", password: ""))
            check(guest.map(\.name) == ["Season 1", "Test Movie (2024).mkv"], "a guest share lists without a login")
            let server_ = NetworkSharePolicy.smbRootURL("smb://\(server)")!
            let shares = try await NetworkShareSMBClient.list(server_, root: server_, login: login)
            check(shares.map(\.name) == ["Movies", "Public"] && shares.allSatisfy(\.isFolder), "a server root lists its shares, IPC$ hidden: \(shares.map(\.name))")
        } catch { check(false, "live listing failed: \(error)") }
        await expect(.unauthorized, "a wrong password is refused, never retried as guest") {
            _ = try await NetworkShareSMBClient.list(movies, root: movies, login: .init(username: "tester", password: "wrong"))
        }
        let missing = NetworkSharePolicy.smbRootURL("smb://\(server)/NoSuchShare")!
        await expect(.notAShare, "a share that does not exist is reported as not a share") {
            _ = try await NetworkShareSMBClient.list(missing, root: missing, login: login)
        }
        print("All live SMB checks passed")
    }
}
