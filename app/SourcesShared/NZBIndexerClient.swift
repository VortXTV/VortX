import Foundation

/// The small, deliberately independent Newznab RSS client.  It never returns a credential-bearing
/// request URL: callers receive only parsed release metadata and the short-lived enclosure URL.
enum NZBIndexerClient {
    static let maxResponseBytes = 1_500_000
    static let maxResults = 50
    static let timeout: TimeInterval = 15

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
        guard case .success = NZBIndexerEndpointPolicy.validate(endpoint), !apiKey.isEmpty,
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

    static func search(config: NZBIndexerConfig, apiKey: String, search: Search) async throws -> [Release] {
        guard case .success(let endpoint) = NZBIndexerEndpointPolicy.validate(config.endpoint),
              let url = requestURL(endpoint: endpoint, apiKey: apiKey, search: search) else { throw Failure.invalidRequest }
        let deadline = Date().addingTimeInterval(timeout)
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        let delegate = SameOriginRedirectDelegate(origin: endpoint)
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data = try await fetch(session: session, request: request, delegate: delegate, deadline: deadline)
        let releases: [Release]
        do { releases = try parse(data: data) }
        catch Failure.api(203) { releases = [] } // Newznab: requested function unavailable.
        // Some compatible endpoints do not implement movie/tvsearch. An EMPTY, successful specific
        // response may fall back to the mandatory generic `t=search`; API errors remain visible to the
        // caller and are never disguised as an empty result.
        guard releases.isEmpty, let fallbackURL = requestURL(endpoint: endpoint, apiKey: apiKey, search: search, fallback: true) else { return releases }
        guard Date() < deadline else { throw Failure.transport }
        var fallback = URLRequest(url: fallbackURL); fallback.timeoutInterval = max(1, deadline.timeIntervalSinceNow)
        let fallbackData = try await fetch(session: session, request: fallback, delegate: delegate, deadline: deadline)
        let fallbackReleases = try parse(data: fallbackData)
        guard search.isSeries, let season = search.season, let episode = search.episode else { return fallbackReleases }
        let token = String(format: "(?i)s%02de%02d(?![0-9])", season, episode)
        return fallbackReleases.filter { $0.title.range(of: token, options: .regularExpression) != nil }
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

    static func parse(data: Data) throws -> [Release] {
        guard data.count <= maxResponseBytes else { throw Failure.tooLarge }
        // Internal entities can expand far beyond the received byte cap. RSS/Newznab does not need
        // document type declarations; reject them, including UTF-16 encodings, before XML parsing.
        guard let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw Failure.malformed }
        let parser = NewznabXMLParser(); guard parser.parse(data) else { throw Failure.malformed }
        if let code = parser.errorCode { throw Failure.api(code: code) }
        return Array(parser.releases.prefix(maxResults))
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let scheme: String?; let host: String?; let port: Int?
    private let lock = NSLock()
    private var rejected = false
    var rejectedRedirect: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    init(origin: URL) { scheme = origin.scheme?.lowercased(); host = origin.host?.lowercased(); port = origin.port ?? (scheme == "https" ? 443 : 80) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let next = request.url; let nextPort = next?.port ?? (next?.scheme?.lowercased() == "https" ? 443 : 80)
        guard next?.scheme?.lowercased() == scheme, next?.host?.lowercased() == host, nextPort == port,
              next?.user == nil, next?.password == nil else {
            lock.lock(); rejected = true; lock.unlock(); completionHandler(nil); return
        }
        completionHandler(request)
    }
}

private final class NewznabXMLParser: NSObject, XMLParserDelegate {
    private(set) var releases: [NZBIndexerClient.Release] = []
    private(set) var errorCode: Int?
    private var itemTitle: String?; private var itemURL: URL?; private var itemSize: Int64?; private var readingTitle = false
    private var inItem = false
    private var validRoot = false
    private var sawRoot = false
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        return parser.parse() && validRoot
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        let n = name.lowercased()
        if !sawRoot { sawRoot = true; validRoot = n == "rss" || n == "error" }
        if n == "item" { inItem = true; itemTitle = nil; itemURL = nil; itemSize = nil; readingTitle = false }
        if n == "item" { itemTitle = attributes["title"] }
        if inItem, n == "title", itemTitle == nil { itemTitle = ""; readingTitle = true }
        if inItem, n == "enclosure", let raw = attributes["url"], raw.utf8.count <= 8192,
           let url = URL(string: raw), url.scheme?.lowercased() == "https",
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil {
            itemURL = url
            if let length = Int64(attributes["length"] ?? ""), length >= 0 { itemSize = length }
        }
        if n == "error", let raw = attributes["code"], let code = Int(raw) { errorCode = code }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard readingTitle, var title = itemTitle, title.utf8.count < 8_192 else { return }
        title.append(contentsOf: string.prefix(8_192 - title.utf8.count)); itemTitle = title
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name.lowercased() == "title" { readingTitle = false }
        guard name.lowercased() == "item" else { return }
        inItem = false
        guard let title = itemTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, let url = itemURL,
              releases.count < NZBIndexerClient.maxResults else { return }
        releases.append(.init(title: title, enclosureURL: url, size: itemSize))
    }
}
