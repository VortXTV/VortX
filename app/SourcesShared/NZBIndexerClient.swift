import Foundation
import os

/// The small, deliberately independent Newznab RSS client.  It never returns a credential-bearing
/// request URL: callers receive only parsed release metadata and the short-lived enclosure URL.
enum NZBIndexerClient {
    static let maxResponseBytes = 1_500_000
    static let maxResults = 50
    /// Covers the specific search plus its generic fallback; some indexers take well over 10 s to answer.
    static let timeout: TimeInterval = 25

    struct Search: Sendable, Equatable {
        let title: String
        let imdbID: String?
        let season: Int?
        let episode: Int?
        let isSeries: Bool
    }

    struct Release: Sendable, Equatable {
        let title: String
        let enclosureURL: URL
        let size: Int64?
    }

    enum Failure: Error, Equatable { case invalidRequest, transport, tooLarge, malformed, api(code: Int) }

    static func requestURL(endpoint: URL, apiKey: String, search: Search, fallback: Bool = false) -> URL? {
        guard case .success(let endpoint) = NZBIndexerEndpointPolicy.validate(endpoint), !apiKey.isEmpty,
              !search.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              search.title.utf8.count <= 512 else { return nil }
        if search.isSeries {
            guard let season = search.season, let episode = search.episode,
                  (0...10_000).contains(season), (1...100_000).contains(episode) else { return nil }
        }
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var q = (c?.queryItems ?? []).filter { !["t", "o", "apikey", "q", "season", "ep", "imdbid", "limit", "offset"].contains($0.name.lowercased()) }
        q.append(URLQueryItem(name: "limit", value: String(maxResults)))
        q.append(URLQueryItem(name: "o", value: "xml"))
        q.append(URLQueryItem(name: "apikey", value: apiKey))
        if fallback {
            var title = search.title
            if search.isSeries, let season = search.season, let episode = search.episode {
                title += String(format: " S%02dE%02d", season, episode)
            }
            q.append(URLQueryItem(name: "t", value: "search")); q.append(URLQueryItem(name: "q", value: title))
        } else if search.isSeries, let season = search.season, let episode = search.episode {
            q.append(URLQueryItem(name: "t", value: "tvsearch"))
            q.append(URLQueryItem(name: "q", value: search.title))
            q.append(URLQueryItem(name: "season", value: String(season)))
            q.append(URLQueryItem(name: "ep", value: String(episode)))
        } else {
            q.append(URLQueryItem(name: "t", value: "movie"))
            if let imdb = search.imdbID {
                let digits = imdb.lowercased().hasPrefix("tt") ? String(imdb.dropFirst(2)) : imdb
                if !digits.isEmpty, digits.allSatisfy(\.isNumber) { q.append(URLQueryItem(name: "imdbid", value: digits)) }
            }
            q.append(URLQueryItem(name: "q", value: search.title))
        }
        c?.queryItems = q
        return c?.url
    }

    /// One search with its diagnostics line: the indexer host (never the URL, which carries the API key),
    /// how many releases came back, how many items had no usable NZB link, and any failure.
    static func search(config: NZBIndexerConfig, apiKey: String, search: Search) async throws -> [Release] {
        let host = URL(string: config.endpoint)?.host?.lowercased() ?? "invalid"
        let kind = search.isSeries ? "tv" : "movie"
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            let outcome = try await performSearch(config: config, apiKey: apiKey, search: search)
            DiagnosticsLog.log("usenet", "indexer host=\(host) search=\(kind) result=ok releases=\(outcome.releases.count) "
                + "unlinked=\(outcome.unlinked) fallback=\(outcome.usedFallback) elapsed=\(elapsed())ms")
            return outcome.releases
        } catch {
            let reason: String
            switch error as? Failure {
            case .api(let code): reason = "api_\(code)"
            case .some(let failure): reason = "\(failure)"
            case nil: reason = (error as? URLError).map { "url_\($0.code.rawValue)" } ?? "transport"
            }
            DiagnosticsLog.log("usenet", "indexer host=\(host) search=\(kind) result=failed reason=\(reason) elapsed=\(elapsed())ms")
            throw error
        }
    }

    private static func performSearch(config: NZBIndexerConfig, apiKey: String, search: Search) async throws
        -> (releases: [Release], unlinked: Int, usedFallback: Bool) {
        guard case .success(let endpoint) = NZBIndexerEndpointPolicy.validate(config.endpoint),
              let url = requestURL(endpoint: endpoint, apiKey: apiKey, search: search) else { throw Failure.invalidRequest }
        let deadline = Date().addingTimeInterval(timeout)
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        let delegate = SameOriginRedirectDelegate(origin: endpoint)
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data = try await fetch(session: session, request: request, delegate: delegate, deadline: deadline)
        var releases: [Release]
        var unlinked = 0
        do { (releases, unlinked) = try parseCounting(data: data, indexerHost: endpoint.host) }
        catch Failure.api(203) { releases = [] } // Newznab: requested function unavailable.
        // Some compatible endpoints do not implement movie/tvsearch. An EMPTY, successful specific
        // response may fall back to the mandatory generic `t=search`; API errors remain visible to the
        // caller and are never disguised as an empty result.
        guard releases.isEmpty, let fallbackURL = requestURL(endpoint: endpoint, apiKey: apiKey, search: search, fallback: true) else {
            return (releases, unlinked, false)
        }
        guard Date() < deadline else { throw Failure.transport }
        var fallback = URLRequest(url: fallbackURL); fallback.timeoutInterval = max(1, deadline.timeIntervalSinceNow)
        let fallbackData = try await fetch(session: session, request: fallback, delegate: delegate, deadline: deadline)
        let (fallbackReleases, fallbackUnlinked) = try parseCounting(data: fallbackData, indexerHost: endpoint.host)
        guard search.isSeries, let season = search.season, let episode = search.episode else {
            return (fallbackReleases, unlinked + fallbackUnlinked, true)
        }
        let token = String(format: "(?i)s%02de%02d(?![0-9])", season, episode)
        return (fallbackReleases.filter { $0.title.range(of: token, options: .regularExpression) != nil }, unlinked + fallbackUnlinked, true)
    }

    private static func fetch(session: URLSession, request: URLRequest, delegate: SameOriginRedirectDelegate, deadline: Date) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard !delegate.rejectedRedirect, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.transport }
        var data = Data(); data.reserveCapacity(min(maxResponseBytes, 64 * 1024))
        for try await byte in bytes {
            guard Date() < deadline else { throw Failure.transport }
            guard data.count < maxResponseBytes else { throw Failure.tooLarge }
            data.append(byte)
        }
        return data
    }

    static func parse(data: Data) throws -> [Release] { try parseCounting(data: data, indexerHost: nil).releases }

    /// `indexerHost` lets an item's plain-http NZB link on the indexer's own host be upgraded to https (the
    /// link carries the API key, so it is never fetched in clear). `unlinked` counts items with no usable link.
    static func parseCounting(data: Data, indexerHost: String?) throws -> (releases: [Release], unlinked: Int) {
        guard data.count <= maxResponseBytes else { throw Failure.tooLarge }
        // Internal entities can expand far beyond the received byte cap. RSS/Newznab does not need
        // document type declarations; reject them before XML parsing. UTF-16/32 documents (which hide the
        // declaration from this text check) always carry NUL bytes and are refused outright; the parser
        // also aborts on any declaration it meets. Older Newznab servers answer in ISO-8859-1, which the
        // XML parser reads from its declaration.
        guard !data.contains(0),
              let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw Failure.malformed }
        let parser = NewznabXMLParser(indexerHost: indexerHost); guard parser.parse(data) else { throw Failure.malformed }
        if let code = parser.errorCode { throw Failure.api(code: code) }
        return (Array(parser.releases.prefix(maxResults)), parser.unlinked)
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let scheme: String?; let host: String?; let port: Int?
    private let rejected = OSAllocatedUnfairLock(initialState: false)
    var rejectedRedirect: Bool { rejected.withLock { $0 } }
    init(origin: URL) { scheme = origin.scheme?.lowercased(); host = origin.host?.lowercased(); port = origin.port ?? (scheme == "https" ? 443 : 80) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let next = request.url; let nextPort = next?.port ?? (next?.scheme?.lowercased() == "https" ? 443 : 80)
        guard next?.scheme?.lowercased() == scheme, next?.host?.lowercased() == host, nextPort == port,
              next?.user == nil, next?.password == nil else {
            rejected.withLock { $0 = true }
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

private final class NewznabXMLParser: NSObject, XMLParserDelegate {
    private(set) var releases: [NZBIndexerClient.Release] = []
    private(set) var errorCode: Int?
    private(set) var unlinked = 0
    private let indexerHost: String?
    private var itemTitle: String?; private var itemURL: URL?; private var itemSize: Int64?; private var readingTitle = false
    private var itemLink: String?; private var readingLink = false
    init(indexerHost: String?) { self.indexerHost = indexerHost?.lowercased() }

    /// An https NZB link, or the indexer's own plain-http link upgraded to https. Anything else is unusable.
    private func usableLink(_ raw: String) -> URL? {
        guard raw.utf8.count <= 8192, var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http" where host == indexerHost: components.scheme = "https"; components.port = nil
        default: return nil
        }
        return components.url
    }
    private var inItem = false
    private var validRoot = false
    private var sawRoot = false
    private var sawDeclaration = false
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        return parser.parse() && validRoot && !sawDeclaration
    }
    /// A Newznab response never declares a DTD; stop at the first declaration, before any entity expands.
    private func refuseDeclaration(_ parser: XMLParser) { sawDeclaration = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuseDeclaration(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { refuseDeclaration(parser) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { refuseDeclaration(parser) }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                type: String?, defaultValue: String?) { refuseDeclaration(parser) }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        let n = name.lowercased()
        if !sawRoot { sawRoot = true; validRoot = n == "rss" || n == "error" }
        if n == "item" { inItem = true; itemTitle = nil; itemURL = nil; itemSize = nil; readingTitle = false; itemLink = nil; readingLink = false }
        if n == "item" { itemTitle = attributes["title"] }
        if inItem, n == "title", itemTitle == nil { itemTitle = ""; readingTitle = true }
        if inItem, n == "link", itemLink == nil { itemLink = ""; readingLink = true }
        if inItem, n == "enclosure", let raw = attributes["url"], let url = usableLink(raw) {
            itemURL = url
            if let length = Int64(attributes["length"] ?? ""), length >= 0 { itemSize = length }
        }
        if n == "error", let raw = attributes["code"], let code = Int(raw) { errorCode = code }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingLink, var link = itemLink, link.utf8.count < 8_192 {
            link.append(contentsOf: string.prefix(8_192 - link.utf8.count)); itemLink = link
        }
        guard readingTitle, var title = itemTitle, title.utf8.count < 8_192 else { return }
        title.append(contentsOf: string.prefix(8_192 - title.utf8.count)); itemTitle = title
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name.lowercased() == "title" { readingTitle = false }
        if name.lowercased() == "link" { readingLink = false }
        guard name.lowercased() == "item" else { return }
        inItem = false
        // Some Newznab servers carry the NZB only in <link>; it is used when no enclosure gave one.
        let url = itemURL ?? itemLink.flatMap(usableLink)
        guard let title = itemTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
        guard let url else { unlinked += 1; return }
        guard releases.count < NZBIndexerClient.maxResults else { return }
        releases.append(.init(title: title, enclosureURL: url, size: itemSize))
    }
}
