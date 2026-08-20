import Foundation
@preconcurrency import JavaScriptCore

/// The on-device runtime that executes a community JavaScript stream provider inside JavaScriptCore.
///
/// WHY ON-DEVICE (the whole reason this is JSC and not a worker): a provider's `fetch` calls egress the
/// USER'S OWN device IP through `URLSession`. The sites these providers scrape are geo-locked and
/// Cloudflare-gated, so a shared server egress IP would be blocked fleet-wide and the returned stream URLs
/// (often IP-pinned by the CDN) would then refuse to play from the user's device. Executing here keeps VortX
/// a neutral runtime that makes no scraping requests from its own infrastructure.
///
/// HOSTILE-CODE SANDBOX. Provider code is untrusted third-party JS and is treated as hostile:
///  - a FRESH `JSVirtualMachine` + `JSContext` per call, disposed at the end, holding nothing from the host
///    bridge except the injected primitives (no filesystem, no native modules, no VortX secrets/keychain);
///  - a hard per-call timeout. The async fetch chain is abandoned and every in-flight request cancelled when
///    it fires. A purely CPU-bound infinite loop in synchronous provider code cannot be preempted by a public
///    `JSContext`, so the timeout completes the app caller from an independent queue. Any wedged execution is
///    isolated to this call's disposable VM and never blocks later source work;
///  - ALL work runs OFF the main thread on a dedicated serial queue (JSContext is not thread-safe, so every
///    JS touch, including `fetch` completions and timer fires, is serialized onto that one queue);
///  - the outbound URL policy (`JSProviderURLPolicy`) and header defaults are enforced HERE, natively, so a
///    provider cannot reach `localhost`, the embedded streaming server, or private network ranges, and cannot
///    disable the policy from JS.
///
/// The host-API surface (fetch/axios/require-gate/console/timers/URL/atob/TextEncoder/... ) is assembled by
/// the bundled `runtime-preamble.js`, on top of the small `__vortx_native_*` primitives injected below, so an
/// unmodified community provider loads. The two libraries the require-gate yields (cheerio + crypto-js) are
/// bundled single-file resources evaluated into the context.
final class JSProviderRuntime: @unchecked Sendable {

    static let shared = JSProviderRuntime()
    private init() {}

    /// One provider run request. `mediaType` is the community contract's `"movie"` / `"tv"`; `tmdbId` is the
    /// numeric TMDB id the provider is handed (VortX resolves imdb -> tmdb before building this).
    struct Invocation {
        let providerID: String
        let code: String
        let tmdbId: String
        let mediaType: String
        let season: Int?
        let episode: Int?
        let settingsJSON: String
        let tmdbKey: String
    }

    enum RunError: Error, Equatable {
        case timedOut
        case providerError(String)
        case bootstrapFailed(String)
        case noResult
    }

    /// Execute `getStreams(tmdbId, mediaType, season, episode)` and return the raw provider stream dicts
    /// (mapped to `CoreStream` by `JSProviderStreamMapping`). Fail-soft: any bootstrap/provider error or a
    /// timeout returns `.failure`, never throws into the caller's pipeline.
    func getStreams(
        _ invocation: Invocation,
        timeout: TimeInterval = 25,
        urlPolicy: JSProviderURLPolicy = .default
    ) async -> Result<[[String: Any]], RunError> {
        guard let bootstrap = Self.bootstrap else {
            return .failure(.bootstrapFailed("bundled runtime resources missing"))
        }
        let run = Run(invocation: invocation, bootstrap: bootstrap, timeoutSeconds: timeout, urlPolicy: urlPolicy)
        return await run.execute()
    }

    // MARK: Bundled runtime resources (loaded once)

    /// The three bundled JS resources: the two libraries the require-gate yields and the shim preamble. Read
    /// once from `Bundle.main` (folder-referenced under `jsproviders/`); nil if any is missing, which makes
    /// the whole feature a fail-soft no-op rather than a crash.
    struct Bootstrap {
        let cryptoJS: String
        let cheerio: String
        let preamble: String
    }

    static let bootstrap: Bootstrap? = {
        func load(_ name: String) -> String? {
            let bundle = Bundle.main
            let candidates: [URL?] = [
                bundle.url(forResource: name, withExtension: "js", subdirectory: "jsproviders"),
                bundle.url(forResource: name, withExtension: "js"),
            ]
            for case let url? in candidates {
                if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
            }
            return nil
        }
        guard let crypto = load("crypto-js.min"),
              let cheerio = load("cheerio.bundle"),
              let preamble = load("runtime-preamble") else { return nil }
        return Bootstrap(cryptoJS: crypto, cheerio: cheerio, preamble: preamble)
    }()
}

// MARK: - One isolated call

/// A single provider run: owns its own VM, context, serial queue, URLSession, timer registry, and the
/// caller's continuation. Everything JS-facing happens on `queue`. Instances are one-shot.
private final class JSProviderRun: @unchecked Sendable {
    private let invocation: JSProviderRuntime.Invocation
    private let bootstrap: JSProviderRuntime.Bootstrap
    private let timeoutSeconds: TimeInterval
    private let urlPolicy: JSProviderURLPolicy

    /// A dedicated serial queue: JSContext is not thread-safe, so the context creation, evaluation, every
    /// `fetch` completion, and every timer fire are all funnelled here, one at a time, off the main thread.
    private let queue: DispatchQueue
    private var vm: JSVirtualMachine?
    private var context: JSContext?
    private let session: URLSession
    private let sessionDelegate: NoRedirectDelegate
    private var inFlight: [Task<Void, Never>] = []
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimerID = 1
    private let completion = RunCompletion()

    /// Cap a single response body so a hostile provider cannot exhaust memory by fetching an enormous file.
    private static let maxResponseBytes = 8 * 1024 * 1024
    /// Cap total fetches per call so a provider cannot fan out unboundedly.
    private static let maxRequests = 60
    private var requestCount = 0

    init(invocation: JSProviderRuntime.Invocation, bootstrap: JSProviderRuntime.Bootstrap,
         timeoutSeconds: TimeInterval, urlPolicy: JSProviderURLPolicy) {
        self.invocation = invocation
        self.bootstrap = bootstrap
        self.timeoutSeconds = timeoutSeconds
        self.urlPolicy = urlPolicy
        self.queue = DispatchQueue(label: "com.vortx.jsprovider.\(invocation.providerID)", qos: .userInitiated)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.httpCookieStorage = HTTPCookieStorage()   // per-call cookie jar, never the shared store
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = NoRedirectDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    func execute() async -> Result<[[String: Any]], JSProviderRuntime.RunError> {
        let result: RunResultBox = await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: RunResultBox(.failure(.bootstrapFailed("runtime released"))))
                    return
                }
                self.completion.install(cont)
                self.startTimeout()
                self.boot()
            }
        }
        return result.value
    }

    // MARK: Boot + provider invocation (on `queue`)

    private func boot() {
        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else {
            finish(.failure(.bootstrapFailed("JSContext init failed"))); return
        }
        self.vm = vm
        self.context = context

        // Any uncaught JS exception during bootstrap or provider load fails this call fast and legibly.
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown JS exception"
            self?.finish(.failure(.providerError(message)))
        }

        installNativePrimitives(into: context)

        // Deterministic library capture (independent of the UMD branch a bare context would take): wrap each
        // library so `typeof exports === 'object'` holds and `module.exports` is returned, then stash it as a
        // global the preamble's require-gate hands back.
        func capture(_ source: String, as global: String) -> Bool {
            let wrapped = "(function(){ var m={exports:{}}; (function(module,exports){\n\(source)\n})(m, m.exports); return m.exports; })()"
            guard let value = context.evaluateScript(wrapped), !value.isUndefined, !value.isNull else { return false }
            context.setObject(value, forKeyedSubscript: global as NSString)
            return true
        }
        guard !completion.isFinished else { return }
        guard capture(bootstrap.cryptoJS, as: "__vortx_cryptojs") else {
            finish(.failure(.bootstrapFailed("crypto-js load failed"))); return
        }
        guard !completion.isFinished else { return }
        guard capture(bootstrap.cheerio, as: "__vortx_cheerio") else {
            finish(.failure(.bootstrapFailed("cheerio load failed"))); return
        }
        guard !completion.isFinished else { return }

        // Injected constants the preamble/provider read.
        context.setObject(invocation.tmdbKey as NSString, forKeyedSubscript: "TMDB_API_KEY" as NSString)
        context.setObject("" as NSString, forKeyedSubscript: "PRIMARY_KEY" as NSString)
        context.setObject(NSNumber(value: urlPolicy.validationEnabled), forKeyedSubscript: "URL_VALIDATION_ENABLED" as NSString)

        context.evaluateScript(bootstrap.preamble)
        guard !completion.isFinished else { return }

        // Kick the provider. The preamble's __vortx_run resolves through __vortx_native_complete / _fail.
        guard let runner = context.objectForKeyedSubscript("__vortx_run"), runner.isObject else {
            finish(.failure(.bootstrapFailed("preamble did not define __vortx_run"))); return
        }
        let params: [String: Any] = [
            "tmdbId": invocation.tmdbId,
            "mediaType": invocation.mediaType,
            "season": invocation.season as Any,
            "episode": invocation.episode as Any,
        ]
        let paramsJSON = Self.jsonString(params)
        runner.call(withArguments: [
            invocation.code, paramsJSON, invocation.settingsJSON, invocation.providerID, invocation.tmdbKey,
        ])
    }

    // MARK: Native primitives (the small surface the preamble builds on)

    private func installNativePrimitives(into context: JSContext) {
        // console -> native logger (rate-limited).
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log(level: level, message: message)
        }
        context.setObject(log, forKeyedSubscript: "__vortx_native_log" as NSString)

        // fetch -> URLSession on the user's IP, with the outbound URL policy + header defaults enforced here.
        let fetch: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] urlString, optionsJSON, resolve, reject in
            self?.nativeFetch(urlString: urlString, optionsJSON: optionsJSON, resolve: resolve, reject: reject)
        }
        context.setObject(fetch, forKeyedSubscript: "__vortx_native_fetch" as NSString)

        // setTimeout / clearTimeout scheduled on `queue`, cancellable at teardown.
        let setTimeout: @convention(block) (JSValue, Double) -> NSNumber = { [weak self] fn, ms in
            guard let self else { return 0 }
            return NSNumber(value: self.scheduleTimer(fn: fn, ms: ms))
        }
        context.setObject(setTimeout, forKeyedSubscript: "__vortx_native_set_timeout" as NSString)
        let clearTimeout: @convention(block) (NSNumber) -> Void = { [weak self] id in
            self?.cancelTimer(id: id.intValue)
        }
        context.setObject(clearTimeout, forKeyedSubscript: "__vortx_native_clear_timeout" as NSString)

        // completion primitives.
        let complete: @convention(block) (String) -> Void = { [weak self] json in
            self?.handleComplete(json: json)
        }
        context.setObject(complete, forKeyedSubscript: "__vortx_native_complete" as NSString)
        let fail: @convention(block) (String) -> Void = { [weak self] message in
            self?.finish(.failure(.providerError(message)))
        }
        context.setObject(fail, forKeyedSubscript: "__vortx_native_fail" as NSString)
    }

    // MARK: fetch (on `queue`, completions hop back to `queue`)

    private func nativeFetch(urlString: String, optionsJSON: String, resolve: JSValue, reject: JSValue) {
        guard !completion.isFinished else { return }
        requestCount += 1
        guard requestCount <= Self.maxRequests else {
            reject.call(withArguments: ["request budget exceeded"]); return
        }
        guard let url = URL(string: urlString), urlPolicy.isAllowed(url) else {
            reject.call(withArguments: ["blocked or invalid URL"]); return
        }
        let options = Self.decodeJSONObject(optionsJSON)
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String)?.uppercased() ?? "GET"
        if let headers = options["headers"] as? [String: Any] {
            for (k, v) in headers { request.setValue(String(describing: v), forHTTPHeaderField: k) }
        }
        // Force a desktop-browser User-Agent by default (community host does the same) unless the provider set
        // one, so hotlink/bot checks that reject a non-browser UA pass.
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(JSProviderURLPolicy.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if let body = options["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        } else if let body = options["body"], !(body is NSNull) {
            request.httpBody = Self.jsonString(body).data(using: .utf8)
        }

        let resolveBox = JSValueBox(resolve)
        let rejectBox = JSValueBox(reject)
        let outboundRequest = request
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.urlPolicy.isAllowedResolved(url)
            self.queue.async {
                guard !self.completion.isFinished else { return }
                guard allowed else {
                    rejectBox.value.call(withArguments: ["blocked or invalid URL"])
                    return
                }
                self.startNetworkFetch(request: outboundRequest, url: url, resolve: resolveBox, reject: rejectBox)
            }
        }
    }

    private func startNetworkFetch(request: URLRequest, url: URL, resolve: JSValueBox, reject: JSValueBox) {
        // `JSValue` is context-confined and deliberately never touched off `queue`. The unchecked box only
        // transports that opaque handle through Swift concurrency back to its owning serial queue.
        let fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await self.session.bytes(for: request)
                var bodyData = Data()
                for try await byte in bytes {
                    guard bodyData.count < Self.maxResponseBytes else { throw ResponseTooLarge() }
                    bodyData.append(byte)
                }
                let completedData = bodyData
                self.queue.async {
                    self.deliverFetch(bodyData: completedData, response: response, fallbackURL: url,
                                      resolve: resolve.value, reject: reject.value)
                }
            } catch {
                self.queue.async {
                    guard !self.completion.isFinished else { return }
                    reject.value.call(withArguments: [error is ResponseTooLarge ? "response size limit exceeded" : error.localizedDescription])
                }
            }
        }
        inFlight.append(fetchTask)
    }

    // MARK: timers (on `queue`)

    private func scheduleTimer(fn: JSValue, ms: Double) -> Int {
        guard !completion.isFinished else { return 0 }
        let id = nextTimerID
        nextTimerID += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.completion.isFinished else { return }
            self.timers.removeValue(forKey: id)
            fn.call(withArguments: [])
        }
        timers[id] = work
        queue.asyncAfter(deadline: .now() + max(0, ms) / 1000.0, execute: work)
        return id
    }

    private func cancelTimer(id: Int) {
        timers.removeValue(forKey: id)?.cancel()
    }

    private func deliverFetch(bodyData: Data, response: URLResponse, fallbackURL: URL, resolve: JSValue, reject: JSValue) {
        guard !completion.isFinished else { return }
        let http = response as? HTTPURLResponse
        var headerDict: [String: String] = [:]
        for (k, v) in (http?.allHeaderFields ?? [:]) {
            headerDict[String(describing: k)] = String(describing: v)
        }
        let bodyString = String(data: bodyData, encoding: .utf8)
            ?? String(data: bodyData, encoding: .isoLatin1) ?? ""
        let raw: [String: Any] = [
            "status": http?.statusCode ?? 0,
            "statusText": Self.statusText(http?.statusCode ?? 0),
            "url": (http?.url?.absoluteString ?? fallbackURL.absoluteString),
            "headers": headerDict,
            "body": bodyString,
        ]
        guard let context, let payload = JSValue(object: raw, in: context) else {
            reject.call(withArguments: ["response marshalling failed"]); return
        }
        resolve.call(withArguments: [payload])
    }

    // MARK: completion + teardown

    private func handleComplete(json: String) {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            finish(.failure(.noResult)); return
        }
        finish(.success(arr))
    }

    private func startTimeout() {
        // This cannot run on the JS queue. `evaluateScript` is synchronous and a hostile infinite loop would
        // otherwise prevent the timeout work item from ever executing.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            self?.timeoutExpired()
        }
    }

    private func timeoutExpired() {
        guard completion.complete(RunResultBox(.failure(.timedOut))) else { return }
        // URLSession cancellation is thread-safe and prevents outstanding native I/O even if JavaScript is
        // currently holding the owning queue in a non-cooperative synchronous loop.
        session.invalidateAndCancel()
        queue.async { [weak self] in
            self?.tearDownOnQueue()
        }
    }

    /// Resume the caller exactly once, cancel in-flight requests + timers, and drop the VM/context. Idempotent.
    private func finish(_ result: Result<[[String: Any]], JSProviderRuntime.RunError>) {
        // Always on `queue`.
        guard completion.complete(RunResultBox(result)) else { return }
        tearDownOnQueue()
    }

    private func tearDownOnQueue() {
        for task in inFlight { task.cancel() }
        inFlight.removeAll()
        for (_, work) in timers { work.cancel() }
        timers.removeAll()
        session.invalidateAndCancel()
        context?.exceptionHandler = nil
        context = nil
        vm = nil
    }

    private func log(level: String, message: String) {
        // Bounded: providers can be chatty. One truncated line per message, tagged with the provider id.
        let clipped = message.count > 500 ? String(message.prefix(500)) + "..." : message
        VXProbe.log("jsplugin", "[\(invocation.providerID)] \(level): \(clipped)")
    }

    // MARK: JSON helpers

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) { return s }
        // A bare value (string/number/bool/null) is not a valid top-level JSON object for JSONSerialization;
        // fall back to a manual encode for the common cases.
        switch value {
        case let s as String: return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        case let n as NSNumber: return n.stringValue
        case is NSNull: return "null"
        default: return "{}"
        }
    }

    private static func decodeJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return code == 0 ? "" : "HTTP \(code)"
        }
    }
}

private struct ResponseTooLarge: Error {}

private final class JSValueBox: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

private final class RunResultBox: @unchecked Sendable {
    let value: Result<[[String: Any]], JSProviderRuntime.RunError>
    init(_ value: Result<[[String: Any]], JSProviderRuntime.RunError>) { self.value = value }
}

/// Continuations are completed from the JavaScript queue for normal outcomes and from a separate queue for a
/// timeout. The lock makes that race explicit while keeping JavaScriptCore objects confined to the JS queue.
private final class RunCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunResultBox, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<RunResultBox, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    @discardableResult
    func complete(_ result: RunResultBox) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }
}

/// A provider is never allowed to follow a redirect into a different host or address class. Refusing all
/// redirects is the smallest auditable policy: providers can request their final HTTPS URL explicitly, while a
/// malicious manifest cannot turn a permitted public URL into a private-network request after validation.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Keep the private run type name stable for readers of the runtime facade.
private typealias Run = JSProviderRun
