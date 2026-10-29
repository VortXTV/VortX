import Foundation

private func utf16LE(_ text: String) -> Data {
    Data([0xff, 0xfe] + Array(text.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
}

private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Bool) { lock.lock(); defer { lock.unlock() }; value = next }
}

private final class SubtitleFileFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        if url.lastPathComponent == "redirect-private.srt" {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://127.0.0.2/foreign.srt"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let name = url.lastPathComponent.lowercased()
        let (mime, bytes): (String, Data)
        switch name {
        case "empty.srt": (mime, bytes) = ("application/x-subrip", Data())
        case "binary.srt": (mime, bytes) = ("application/x-subrip", Data([0, 255, 1]))
        case "zip-as-srt.srt": (mime, bytes) = ("application/x-subrip", Data([0x50, 0x4b, 0x03, 0x04]))
        case "utf16.srt": (mime, bytes) = ("application/x-subrip", utf16LE("1\n00:00:01,000 --> 00:00:02,000\nCafé\n\n"))
        case "latin1.srt": (mime, bytes) = ("application/x-subrip", Data([0x31, 0x0a, 0x43, 0x61, 0x66, 0xe9, 0x0a]))
        case "opaque.php": (mime, bytes) = ("text/plain", Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nOpaque\n".utf8))
        case "opaque.json": (mime, bytes) = ("application/x-subrip", Data("1\n00:00:01,000 --> 00:00:02,000\nOpaque\n".utf8))
        case "good.vtt": (mime, bytes) = ("text/vtt", Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n".utf8))
        case "good.ass": (mime, bytes) = ("text/x-ass", Data("[Script Info]\nTitle: Fixture\n".utf8))
        case "styled.ass": (mime, bytes) = ("text/x-ass", Data("[Script Info]\nTitle: Fixture\n[Fonts]\nfontname: https://127.0.0.2/private.ttf\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\fnRemote}Hello\\Nworld\n".utf8))
        case "playlist.srt": (mime, bytes) = ("application/x-subrip", Data("#EXTM3U\n#EXTINF:2,Private\nhttps://127.0.0.2/private.ts\n".utf8))
        case "page.srt": (mime, bytes) = ("application/x-subrip", Data("<html><body>Unavailable<iframe src='https://127.0.0.2/private'></iframe></body></html>".utf8))
        case "good.zip": (mime, bytes) = ("application/zip", Data([0x50, 0x4b, 0x03, 0x04]))
        default: (mime, bytes) = ("application/x-subrip", Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8))
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum AddonSubtitleFileClientTests {
    static func main() async throws {
        let parserCap = SubtitleFileBudget.maximumBytes
        precondition(AddonURLGuard.ResponseContext.subtitleFile.maximumBytes == parserCap)
        precondition(AddonURLGuard.ResponseContext.subtitleFile.maximumURLBytes == 128 * 1024)
        precondition(AddonURLGuard.canAcceptBody(currentBytes: parserCap - 1, incomingBytes: 1, context: .subtitleFile))
        precondition(!AddonURLGuard.canAcceptBody(currentBytes: parserCap, incomingBytes: 1, context: .subtitleFile))
        let protocols = AddonURLGuard.TestURLProtocolClasses([SubtitleFileFixture.self])
        let origin = URL(string: "https://127.0.0.1/addon/manifest.json")!
        func row(_ path: String, origin: URL = URL(string: "https://127.0.0.1/addon/manifest.json")!) -> AddonSubtitle {
            var components = URLComponents()
            components.scheme = origin.scheme
            components.host = origin.host
            components.port = origin.port
            components.path = "/subtitles/\(path)"
            let requestURL = components.url!.absoluteString
            return AddonSubtitle(id: path, url: requestURL, lang: "en",
                                 addonName: "Fixture", installedBaseURL: origin)
        }

        // The installed source can exceed the QR import ceiling while remaining under the fixed file URL budget.
        let longOrigin = URL(string: "https://127.0.0.1/" + String(repeating: "a", count: 2_200))!
        let longOriginRow = row("opaque.php", origin: longOrigin)
        let longOriginFile = try await AddonSubtitleFileClient.fetch(longOriginRow,
            permit: .init(for: longOriginRow) { true }, testURLProtocolClasses: protocols)
        precondition(longOriginFile.format == .vtt)

        for (path, expected) in [("opaque.php", AddonSubtitleFileClient.Format.vtt), ("opaque.json", .srt)] {
            let item = row(path)
            let file = try await AddonSubtitleFileClient.fetch(item,
                permit: .init(for: item) { true }, testURLProtocolClasses: protocols)
            precondition(file.format == expected, "recognized response MIME/content may classify opaque provider paths")
        }
        for (path, expected) in [("good.vtt", AddonSubtitleFileClient.Format.vtt), ("good.ass", .ass)] {
            let item = row(path)
            let file = try await AddonSubtitleFileClient.fetch(item,
                permit: .init(for: item) { true }, testURLProtocolClasses: protocols)
            precondition(file.format == expected)
        }
        let httpOrigin = URL(string: "http://127.0.0.1/addon/manifest.json")!
        let httpRow = row("opaque.php", origin: httpOrigin)
        let httpFile = try await AddonSubtitleFileClient.fetch(httpRow,
            permit: .init(for: httpRow) { true }, testURLProtocolClasses: protocols)
        // Bridge tests compile the actual PlayerLocalSubtitleSource and bounded cue parser too.
        // A transport receipt, not a caller-supplied HTTP identity or community permit, creates the value.
        guard let httpSource = PlayerLocalSubtitleSource.installedAddon(httpFile),
              let httpPrepared = httpSource.preparedNativeSubtitle() else {
            preconditionFailure("original guarded HTTP receipt normalizes without another fetch")
        }
        precondition(httpSource.identityURL.absoluteString == httpRow.url)
        precondition(httpSource.identityURL.scheme == "http" && httpSource.permitsUse())
        precondition(httpPrepared.format == "srt" && SubtitleCueRenderer.parse(data: httpPrepared.data).count == 1)
        precondition(PlayerLocalSubtitleSource(data: httpSource.data, format: "srt",
            identityURL: httpSource.identityURL, permitsUse: { true }) == nil,
            "the original pool initializer still rejects caller-supplied HTTP")

        let styled = row("styled.ass")
        let styledFile = try await AddonSubtitleFileClient.fetch(styled,
            permit: .init(for: styled) { true }, testURLProtocolClasses: protocols)
        guard let styledSource = PlayerLocalSubtitleSource.installedAddon(styledFile),
              let styledPrepared = styledSource.preparedNativeSubtitle(),
              let styledText = String(data: styledPrepared.data, encoding: .utf8) else {
            preconditionFailure("actual ASS cue text normalizes to bounded plain SRT")
        }
        precondition(styledPrepared.format == "srt" && styledText.contains("Hello\nworld"))
        precondition(!styledText.contains("[Fonts]") && !styledText.contains("https://") && !styledText.contains("\\fn"))
        let originalASS = styledSource.data
        let pool = PlayerLocalSubtitleSource(data: originalASS, format: "ass",
            identityURL: URL(string: "https://example.invalid/pooled.ass")!, permitsUse: { true })!
        precondition(pool.preparedNativeSubtitle()?.data == originalASS && pool.preparedNativeSubtitle()?.format == "ass",
            "existing strict pool source keeps its raw fallback bytes and format")
        for path in ["playlist.srt", "page.srt"] {
            let item = row(path)
            let guarded = try await AddonSubtitleFileClient.fetch(item,
                permit: .init(for: item) { true }, testURLProtocolClasses: protocols)
            precondition(PlayerLocalSubtitleSource.installedAddon(guarded)?.preparedNativeSubtitle() == nil,
                "text transport acceptance cannot turn \(path) into native input")
        }
        precondition(httpFile.format == .vtt)

        let gated = row("good.srt")
        let gate = TestGate(true)
        let fetched = try await AddonSubtitleFileClient.fetch(gated,
            permit: .init(for: gated) { gate.read() }, testURLProtocolClasses: protocols)
        guard let snapshot = fetched.snapshotIfCurrent() else { preconditionFailure("current selection gets a byte snapshot") }
        let originalSource = PlayerLocalSubtitleSource.installedAddon(fetched)
        precondition(originalSource?.permitsUse() == true)
        precondition(snapshot.selectionIsCurrent && String(data: snapshot.bytes, encoding: .utf8)!.contains("Hello"))
        gate.set(false)
        precondition(originalSource?.permitsUse() == false && originalSource?.preparedNativeSubtitle() == nil,
            "retained guarded source rechecks the original pre-fetch selection, not current replacement state")
        precondition(PlayerLocalSubtitleSource.installedAddon(fetched) == nil)
        precondition(!snapshot.selectionIsCurrent, "snapshot exposes freshness state to the final consumer")
        precondition(!snapshot.bytes.isEmpty, "revocation does not erase bytes already copied into a value snapshot")
        precondition(fetched.snapshotIfCurrent().map { _ in false } ?? true, "no new snapshot after permit revocation")

        let stale = row("good.srt")
        do {
            _ = try await AddonSubtitleFileClient.fetch(stale, permit: .init(for: stale) { false }, testURLProtocolClasses: protocols)
            preconditionFailure("stale selection must fail before transport")
        } catch AddonSubtitleFileClient.Failure.staleSelection {}
        let archive = row("good.zip")
        do {
            _ = try await AddonSubtitleFileClient.fetch(archive, permit: .init(for: archive) { true }, testURLProtocolClasses: protocols)
            preconditionFailure("archive route is never extracted")
        } catch AddonSubtitleFileClient.Failure.invalidText {}
        for path in ["empty.srt", "binary.srt", "zip-as-srt.srt"] {
            let item = row(path)
            do {
                _ = try await AddonSubtitleFileClient.fetch(item, permit: .init(for: item) { true }, testURLProtocolClasses: protocols)
                preconditionFailure("empty, known-archive, and control-heavy payloads are rejected")
            } catch AddonSubtitleFileClient.Failure.invalidText {}
        }
        for (path, encoding, bytes) in [
            ("utf16.srt", AddonSubtitleFileClient.TextEncoding.utf16, utf16LE("1\n00:00:01,000 --> 00:00:02,000\nCafé\n\n")),
            ("latin1.srt", .isoLatin1, Data([0x31, 0x0a, 0x43, 0x61, 0x66, 0xe9, 0x0a])),
        ] {
            let item = row(path)
            let file = try await AddonSubtitleFileClient.fetch(item, permit: .init(for: item) { true }, testURLProtocolClasses: protocols)
            precondition(file.textEncoding == encoding)
            precondition(file.snapshotIfCurrent()?.bytes == bytes)
        }
        let foreign = AddonSubtitle(id: "foreign", url: "https://127.0.0.2/subtitles/good.srt", lang: "en",
                                    addonName: "Fixture", installedBaseURL: origin)
        do {
            _ = try await AddonSubtitleFileClient.fetch(foreign, permit: .init(for: foreign) { true }, testURLProtocolClasses: protocols)
            preconditionFailure("different private origin does not inherit selected addon authority")
        } catch {}
        let redirect = row("redirect-private.srt")
        do {
            _ = try await AddonSubtitleFileClient.fetch(redirect, permit: .init(for: redirect) { true }, testURLProtocolClasses: protocols)
            preconditionFailure("redirect to foreign private origin is refused")
        } catch {}
    }
}
