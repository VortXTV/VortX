// Network shares: address rules, credential scoping, WebDAV and web-folder listings.
// Run: scripts/test-network-shares.sh

import Foundation

private var failures = 0
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
enum NetworkSharesTests {
    static func main() {
        addresses()
        smb()
        scoping()
        webDAV()
        webFolders()
        if failures > 0 { print("\n\(failures) check(s) failed"); exit(1) }
        print("\nAll network share checks passed")
    }

    static func addresses() {
        check("a bare host gets http and a trailing slash",
              NetworkSharePolicy.rootURL("nas.local:5005/video")?.absoluteString == "http://nas.local:5005/video/")
        check("https and an existing slash are kept",
              NetworkSharePolicy.rootURL(" https://NAS.local/dav/ ")?.absoluteString == "https://NAS.local/dav/")
        check("a host alone becomes its root folder", NetworkSharePolicy.rootURL("192.168.1.20")?.absoluteString == "http://192.168.1.20/")
        check("a login in the address is refused", NetworkSharePolicy.rootURL("http://me:secret@nas.local/") == nil)
        check("other schemes are refused", NetworkSharePolicy.rootURL("smb://nas.local/video") == nil
              && NetworkSharePolicy.rootURL("ftp://nas.local/") == nil && NetworkSharePolicy.rootURL("file:///etc/") == nil)
        check("queries and empty input are refused", NetworkSharePolicy.rootURL("http://nas.local/?a=1") == nil
              && NetworkSharePolicy.rootURL("   ") == nil)
    }

    static func smb() {
        check("smb addresses keep their share and gain a slash",
              NetworkSharePolicy.smbRootURL(" smb://NAS.local/Movies ")?.absoluteString == "smb://NAS.local/Movies/")
        check("Windows paths become smb addresses",
              NetworkSharePolicy.smbRootURL(#"\\192.168.1.20\Movies\Kids"#)?.absoluteString == "smb://192.168.1.20/Movies/Kids/")
        check("spaces are escaped", NetworkSharePolicy.smbRootURL("smb://nas/My Videos")?.absoluteString == "smb://nas/My%20Videos/")
        check("a bare server is a root that lists its shares", NetworkSharePolicy.smbRootURL("smb://nas")?.absoluteString == "smb://nas/")
        check("logins in the address and non-smb text are refused",
              NetworkSharePolicy.smbRootURL("smb://me:pw@nas/Movies") == nil && NetworkSharePolicy.smbRootURL("http://nas/") == nil
                  && NetworkSharePolicy.smbRootURL("nas/Movies") == nil)

        let server = URL(string: "smb://nas/")!
        let shares = NetworkSharePolicy.smbEntries([("Movies", 3), ("IPC$", 6), ("ADMIN$", 3), ("Printer", 4), ("WORKGROUP", 1), (".", 7)],
                                                   directory: server)
        check("a server root lists its shares as folders, without admin or printer shares",
              shares.map(\.name) == ["Movies"] && shares[0].isFolder && shares[0].url.absoluteString == "smb://nas/Movies/")
        let folder = URL(string: "smb://nas/Movies/")!
        let inside = NetworkSharePolicy.visible(NetworkSharePolicy.smbEntries(
            [(".", 7), ("..", 7), ("Season 1", 7), ("Arrival (2016).mkv", 8), ("notes.txt", 8), ("Stray share", 3), ("a/b.mkv", 8)],
            directory: folder))
        check("inside a share: folders and videos, dots and odd names dropped",
              inside.map(\.name) == ["Season 1", "Arrival (2016).mkv"]
                  && inside[1].url.absoluteString == "smb://nas/Movies/Arrival%20(2016).mkv"
                  && inside[0].url.absoluteString == "smb://nas/Movies/Season%201/")
        let file = URL(string: "smb://nas/Movies/Arrival%20(2016).mkv")!
        check("the player gets the login inside the address, escaped",
              NetworkSharePolicy.smbPlaybackURL(file, root: folder, username: "me@home", password: "p:w/d")?.absoluteString
                  == "smb://me%40home:p%3Aw%2Fd@nas/Movies/Arrival%20(2016).mkv")
        check("no login, no credentials", NetworkSharePolicy.smbPlaybackURL(file, root: folder, username: "", password: "")?.absoluteString
              == "smb://nas/Movies/Arrival%20(2016).mkv")
        check("never for a file outside the share",
              NetworkSharePolicy.smbPlaybackURL(URL(string: "smb://other/Movies/x.mkv")!, root: folder, username: "me", password: "pw") == nil
                  && NetworkSharePolicy.smbPlaybackURL(URL(string: "smb://nas/Private/x.mkv")!, root: folder, username: "me", password: "pw") == nil)
    }

    static func scoping() {
        let root = URL(string: "https://nas.local:5006/video/")!
        check("the login goes to files inside the share",
              NetworkSharePolicy.headers(for: URL(string: "https://nas.local:5006/video/Films/a.mkv")!, root: root,
                                         username: "me", password: "pw") == ["Authorization": "Basic bWU6cHc="])
        check("never to another host, port, scheme or folder",
              NetworkSharePolicy.headers(for: URL(string: "https://evil.example/video/a.mkv")!, root: root, username: "me", password: "pw").isEmpty
                  && NetworkSharePolicy.headers(for: URL(string: "https://nas.local:5001/video/a.mkv")!, root: root, username: "me", password: "pw").isEmpty
                  && NetworkSharePolicy.headers(for: URL(string: "http://nas.local:5006/video/a.mkv")!, root: root, username: "me", password: "pw").isEmpty
                  && NetworkSharePolicy.headers(for: URL(string: "https://nas.local:5006/videos/a.mkv")!, root: root, username: "me", password: "pw").isEmpty)
        check("not past the root with ..", !NetworkSharePolicy.isInside(URL(string: "https://nas.local:5006/video/../photos/x.jpg")!, root: root))
        check("a share without a login sends nothing",
              NetworkSharePolicy.headers(for: URL(string: "https://nas.local:5006/video/a.mkv")!, root: root, username: "", password: "").isEmpty)
        check("default ports match their schemes",
              NetworkSharePolicy.isInside(URL(string: "http://nas.local:80/v/a.mkv")!, root: URL(string: "http://nas.local/v/")!))
    }

    static func webDAV() {
        let root = URL(string: "https://nas.local:5006/video/")!
        let directory = URL(string: "https://nas.local:5006/video/Films/")!
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/video/Films/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
          <D:response><D:href>/video/Films/Dune%20Part%20Two%20(2024)/</D:href><D:propstat><D:prop><D:displayname>Dune Part Two (2024)</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
          <D:response><D:href>https://nas.local:5006/video/Films/Arrival.2016.1080p.mkv</D:href><D:propstat><D:prop><D:getcontentlength>8123456789</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
          <D:response><D:href>/video/Films/poster.jpg</D:href><D:propstat><D:prop><D:getcontentlength>2048</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
          <D:response><D:href>/video/Films/.DS_Store</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
          <D:response><D:href>/video/Films/Raw Name [1080p].mp4</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
          <D:response><D:href>https://evil.example/video/Films/x.mkv</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
          <D:response><D:href>/photos/private.mkv</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
          <D:response><D:href>/video/Films/Deep/Nested/x.mkv</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
        </D:multistatus>
        """
        guard let parsed = NetworkSharePolicy.parseWebDAV(Data(body.utf8), directory: directory, root: root) else {
            check("a multistatus body parses", false); return
        }
        let shown = NetworkSharePolicy.visible(parsed)
        check("the folder itself, other hosts, other folders and grandchildren are dropped", parsed.count == 5)
        check("folders first, then videos; images and hidden files hidden",
              shown.map(\.name) == ["Dune Part Two (2024)", "Arrival.2016.1080p.mkv", "Raw Name [1080p].mp4"])
        check("display names and sizes come through", shown.first?.isFolder == true && shown[1].size == 8_123_456_789)
        check("a raw-space href still resolves inside the share",
              shown[2].url.absoluteString == "https://nas.local:5006/video/Films/Raw%20Name%20%5B1080p%5D.mp4")
        check("a non-WebDAV body is not a listing", NetworkSharePolicy.parseWebDAV(Data("<html><body>Login</body></html>".utf8), directory: directory, root: root) == nil)
        let lowercase = """
        <multistatus xmlns="DAV:"><response><href>/video/Films/a.mkv</href><propstat><prop><resourcetype/></prop></propstat></response></multistatus>
        """
        let entityBomb = """
        <?xml version="1.0"?><!DOCTYPE m [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;">]><multistatus xmlns="DAV:"><response><href>&b;</href></response></multistatus>
        """
        check("a body with a DOCTYPE or entities is refused before parsing",
              NetworkSharePolicy.parseWebDAV(Data(entityBomb.utf8), directory: directory, root: root) == nil)
        let utf16 = entityBomb.data(using: .utf16LittleEndian)!
        check("a UTF-16 body cannot slip a DOCTYPE past the scan",
              NetworkSharePolicy.parseWebDAV(utf16, directory: directory, root: root) == nil
                  && NetworkSharePolicy.parseWebDAV(Data([0xFF, 0xFE]) + utf16, directory: directory, root: root) == nil)
        check("unprefixed DAV namespaces parse too",
              NetworkSharePolicy.parseWebDAV(Data(lowercase.utf8), directory: directory, root: root)?.map(\.name) == ["a.mkv"])
    }

    static func webFolders() {
        let root = URL(string: "http://192.168.1.20:8080/media/")!
        let directory = root
        let nginx = """
        <html><head><title>Index of /media/</title></head><body><h1>Index of /media/</h1><hr><pre><a href="../">../</a>
        <a href="Shows/">Shows/</a>                                              12-Oct-2026 10:00       -
        <a href="The%20Matrix%20(1999).mkv">The Matrix (1999).mkv</a>              12-Oct-2026 10:00  4.2G
        <a href="notes.txt">notes.txt</a>
        </pre><hr></body></html>
        """
        check("nginx autoindex", NetworkSharePolicy.visible(NetworkSharePolicy.parseHTMLIndex(nginx, directory: directory, root: root)).map(\.name)
              == ["Shows", "The Matrix (1999).mkv"])
        let apache = """
        <table><tr><th><a href="?C=N;O=D">Name</a></th></tr>
        <tr><td><a href="/">Parent Directory</a></td></tr>
        <tr><td><a href="Movies/">Movies/</a></td></tr>
        <tr><td><a href="/media/clip.MP4">clip.MP4</a></td></tr>
        <tr><td><a href="http://other.example/media/x.mkv">x.mkv</a></td></tr>
        <tr><td><a href="Movies/inner.mkv">inner.mkv</a></td></tr></table>
        """
        check("Apache index: sort links, parent, other hosts and grandchildren are dropped",
              NetworkSharePolicy.visible(NetworkSharePolicy.parseHTMLIndex(apache, directory: directory, root: root)).map(\.name) == ["Movies", "clip.MP4"])
        let python = """
        <ul><li><a href="Season%201/">Season 1/</a></li><li><a href='E01.mkv'>E01.mkv</a></li><li><a href="E01.mkv">dup</a></li></ul>
        """
        let entries = NetworkSharePolicy.parseHTMLIndex(python, directory: directory, root: root)
        check("python http.server listing, single quotes, duplicates once",
              entries.map(\.name) == ["Season 1", "E01.mkv"] && entries[0].isFolder && entries[0].url.absoluteString.hasSuffix("/media/Season%201/"))
    }
}
