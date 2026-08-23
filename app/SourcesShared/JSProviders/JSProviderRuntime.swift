import Foundation

/// Executes untrusted community JavaScript add-ons in one disposable, bounded native interpreter per call.
/// The interpreter has a native interrupt handler, heap limit, stack limit, and bounded pending-job drain.
/// Provider code receives only title metadata and its own settings. It never receives app credentials.
final class JSProviderRuntime: @unchecked Sendable {
    static let shared = JSProviderRuntime()
    private init() {}

    struct Invocation {
        let providerID: String
        let code: String
        let tmdbId: String
        let mediaType: String
        let season: Int?
        let episode: Int?
        let settingsJSON: String
    }

    enum RunError: Error, Equatable {
        case timedOut
        case cancelled
        case providerFailed
        case bootstrapFailed
        case invalidResult
    }

    struct Bootstrap { let cryptoJS: String; let cheerio: String; let preamble: String }

    static let bootstrap: Bootstrap? = {
        func load(_ name: String) -> String? {
            let bundle = Bundle.main
            for case let url? in [bundle.url(forResource: name, withExtension: "js", subdirectory: "jsproviders"),
                                  bundle.url(forResource: name, withExtension: "js")] {
                if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
            }
            return nil
        }
        guard let crypto = load("crypto-js.min"), let cheerio = load("cheerio.bundle"),
              let preamble = load("runtime-preamble") else { return nil }
        return Bootstrap(cryptoJS: crypto, cheerio: cheerio, preamble: preamble)
    }()

    /// `bootstrapOverride` is an offline test seam. Production always loads the pinned resources from the app.
    func getStreams(_ invocation: Invocation, timeout: TimeInterval = 25,
                    urlPolicy: JSProviderURLPolicy = .default,
                    bootstrapOverride: Bootstrap? = nil) async -> Result<[[String: Any]], RunError> {
        guard let bootstrap = bootstrapOverride ?? Self.bootstrap else { return .failure(.bootstrapFailed) }
        let control = QuickJSCancellationControl()
        let host = QuickJSHost(policy: urlPolicy, control: control, deadline: Date().addingTimeInterval(timeout))
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.execute(invocation, bootstrap: bootstrap, host: host,
                                                               control: control, timeout: timeout))
                }
            }
        }, onCancel: { control.cancel() })
    }

    private static func execute(_ invocation: Invocation, bootstrap: Bootstrap, host: QuickJSHost,
                                control: QuickJSCancellationControl, timeout: TimeInterval) -> Result<[[String: Any]], RunError> {
        let params: [String: Any] = ["tmdbId": invocation.tmdbId, "mediaType": invocation.mediaType,
                                     "season": invocation.season as Any, "episode": invocation.episode as Any]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
              let paramsJSON = String(data: paramsData, encoding: .utf8) else { return .failure(.invalidResult) }
        let opaque = Unmanaged.passUnretained(host).toOpaque()
        var status: Int32 = 3
        let deadline = Int64(max(1, timeout * 1000)) + monotonicMilliseconds()
        let result: UnsafeMutablePointer<CChar>? = bootstrap.cryptoJS.withCString { crypto in
            bootstrap.cheerio.withCString { cheerio in bootstrap.preamble.withCString { preamble in
                invocation.code.withCString { code in paramsJSON.withCString { params in
                    invocation.settingsJSON.withCString { settings in invocation.providerID.withCString { provider in
                        VortXQuickJSRun(crypto, cheerio, preamble, code, params, settings, provider,
                                        opaque, control.pointer, deadline, &status)
                    } }
                } }
            } }
        }
        defer { if let result { VortXQuickJSFree(result) } }
        if control.isCancelled { return .failure(.cancelled) }
        guard status == 0, let result else { return .failure(status == 1 ? .timedOut : .providerFailed) }
        guard let data = String(cString: result).data(using: .utf8),
              let streams = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              streams.count <= JSProviderStreamMapping.maximumStreamsPerProvider else { return .failure(.invalidResult) }
        return .success(streams)
    }
}

private func monotonicMilliseconds() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

private final class QuickJSCancellationControl: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    init() { storage.initialize(to: 0) }
    deinit { storage.deinitialize(count: 1); storage.deallocate() }
    var pointer: UnsafeMutablePointer<Int32> { storage }
    var isCancelled: Bool { storage.pointee != 0 }
    func cancel() { storage.pointee = 1 }
}

/// Native fetch runs on the interpreter worker. JavaScript sees a Promise, while URL, method, header, body,
/// redirect, request-count, and aggregate-byte policy stays outside provider control.
private final class QuickJSHost: @unchecked Sendable {
    private let policy: JSProviderURLPolicy; private let control: QuickJSCancellationControl; private let deadline: Date
    private let lock = NSLock(); private var requestCount = 0; private var aggregateBytes = 0
    private static let maxRequests = 24, maxAggregateBytes = 12 * 1024 * 1024, maxResponseBytes = 2 * 1024 * 1024, maxRequestBodyBytes = 256 * 1024

    init(policy: JSProviderURLPolicy, control: QuickJSCancellationControl, deadline: Date) {
        self.policy = policy; self.control = control; self.deadline = deadline
    }

    func fetch(urlString: String, optionsJSON: String) -> String? {
        guard !control.isCancelled, Date() < deadline, urlString.utf8.count <= 16 * 1024,
              optionsJSON.utf8.count <= 32 * 1024, let url = URL(string: urlString), policy.isAllowed(url), reserveRequest(),
              let optionsData = optionsJSON.data(using: .utf8),
              let options = (try? JSONSerialization.jsonObject(with: optionsData)) as? [String: Any],
              let request = safeRequest(url: url, options: options), awaitResolvedPolicy(for: url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(15, max(1, deadline.timeIntervalSinceNow))
        configuration.timeoutIntervalForResource = min(20, max(1, deadline.timeIntervalSinceNow))
        let session = URLSession(configuration: configuration, delegate: QuickJSNoRedirectDelegate(), delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        let output = QuickJSSyncBox<Result<(Data, HTTPURLResponse), Error>>(.failure(URLError(.unknown)))
        Task {
            defer { semaphore.signal() }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < Self.maxResponseBytes, reserveBytes(1), !control.isCancelled else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                output.set(.success((data, http)))
            } catch { output.set(.failure(error)) }
        }
        guard semaphore.wait(timeout: .now() + max(1, deadline.timeIntervalSinceNow)) == .success,
              !control.isCancelled, case let .success((data, response)) = output.get() else { session.invalidateAndCancel(); return nil }
        let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        let payload: [String: Any] = ["status": response.statusCode, "statusText": "HTTP \(response.statusCode)",
                                      "url": response.url?.absoluteString ?? url.absoluteString, "headers": headers, "body": body]
        return (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func reserveRequest() -> Bool { lock.lock(); defer { lock.unlock() }; requestCount += 1; return requestCount <= Self.maxRequests }
    private func reserveBytes(_ count: Int) -> Bool { lock.lock(); defer { lock.unlock() }; aggregateBytes += count; return aggregateBytes <= Self.maxAggregateBytes }
    private func awaitResolvedPolicy(for url: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0); let allowed = QuickJSSyncBox(false)
        Task { allowed.set(await policy.isAllowedResolved(url)); semaphore.signal() }
        return semaphore.wait(timeout: .now() + max(1, deadline.timeIntervalSinceNow)) == .success && allowed.get()
    }
    private func safeRequest(url: URL, options: [String: Any]) -> URLRequest? {
        let method = ((options["method"] as? String) ?? "GET").uppercased(); guard ["GET", "HEAD", "POST"].contains(method) else { return nil }
        var request = URLRequest(url: url); request.httpMethod = method
        if let headers = options["headers"] as? [String: Any] {
            guard headers.count <= 24 else { return nil }; var total = 0
            for (name, value) in headers { let text = String(describing: value); guard Self.validHeader(name, value: text) else { return nil }; total += name.utf8.count + text.utf8.count; guard total <= 16 * 1024 else { return nil }; request.setValue(text, forHTTPHeaderField: name) }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil { request.setValue(JSProviderURLPolicy.defaultUserAgent, forHTTPHeaderField: "User-Agent") }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) } else if let body = options["body"] { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return (request.httpBody?.count ?? 0) <= Self.maxRequestBodyBytes ? request : nil
    }
    private static func validHeader(_ name: String, value: String) -> Bool {
        let denied: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "upgrade", "proxy-connection", "keep-alive", "te", "trailer"]
        let token = name.unicodeScalars.allSatisfy { ($0.value >= 33 && $0.value <= 126) && !"()<>@,;:\\\"/[]?={} \t".unicodeScalars.contains($0) }
        return token && !denied.contains(name.lowercased()) && name.utf8.count <= 128 && value.utf8.count <= 8192 && !value.contains("\r") && !value.contains("\n")
    }
}

private final class QuickJSNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class QuickJSSyncBox<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

@_cdecl("VortXQuickJSFetch")
func VortXQuickJSFetch(_ opaque: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>?, _ options: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let opaque, let url, let options else { return nil }
    guard let response = Unmanaged<QuickJSHost>.fromOpaque(opaque).takeUnretainedValue().fetch(
        urlString: String(cString: url), optionsJSON: String(cString: options)
    ) else { return nil }
    return response.withCString { strdup($0) }
}
