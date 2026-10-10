// Executable source/lifecycle contract proof for the Apple featured hero repairs.
//
//   scripts/test-featured-hero-lifecycle.sh
//
// The lifecycle cases below mechanically extract the production seed/lease/publication members into a
// standalone harness. Only the network fetch and rotation timer are inert collaborators; the actual production
// `seed`, `enrichIfNeeded`, `stop`, cancellation, token, publication, and same-pool retry bodies are compiled and
// executed. The bounded-image proof is run by the companion local ImageIO test.

import Foundation

private func require(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("FAIL: \(message)") }
}

private func readSource(_ root: URL, _ relativePath: String) -> String {
    let path = root.appendingPathComponent(relativePath).path
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError("FAIL: could not read \(relativePath)")
    }
    return value
}

/// Extract one real Swift declaration with a brace matcher that ignores strings and comments. A missing or
/// unterminated declaration is a hard failure: a renamed/moved production member must update this gate rather
/// than silently replacing the test with a handwritten projection.
private func extractMember(signature: String, from text: String) -> String? {
    guard let signatureRange = text.range(of: signature) else { return nil }
    let lineStart = text[..<signatureRange.lowerBound].lastIndex(of: "\n").map(text.index(after:))
        ?? text.startIndex

    enum State { case code, lineComment, blockComment, string }
    var state = State.code
    var escaped = false
    var braceStart: String.Index?
    var depth = 0
    var index = signatureRange.lowerBound

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        switch state {
        case .code:
            if character == "/", next < text.endIndex {
                let following = text[next]
                if following == "/" {
                    state = .lineComment
                    index = text.index(after: next)
                    continue
                }
                if following == "*" {
                    state = .blockComment
                    index = text.index(after: next)
                    continue
                }
            }
            if character == "\"" {
                state = .string
                index = next
                continue
            }
            if character == "{" {
                if braceStart == nil { braceStart = index }
                depth += 1
            } else if character == "}", braceStart != nil {
                depth -= 1
                if depth == 0, braceStart != nil {
                    return String(text[lineStart...index])
                }
            }
        case .lineComment:
            if character == "\n" { state = .code }
        case .blockComment:
            if character == "*", next < text.endIndex, text[next] == "/" {
                state = .code
                index = text.index(after: next)
                continue
            }
        case .string:
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                state = .code
            }
        }
        index = next
    }
    return nil
}

private func runProcess(_ executable: String, arguments: [String], cwd: URL) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (-1, "could not run \(executable): \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func makeProductionHarness(root: URL, buildDirectory: URL) -> URL {
    let modelSource = readSource(root, "app/SourcesiOS/FeaturedHeroModel.swift")
    let signatures = [
        "    func seed(_ candidates: [FeaturedHeroItem], reduceMotion: Bool)",
        "    private func applySeed(_ capped: [FeaturedHeroItem])",
        "    func stop()",
        "    private func cancelObsoleteEnrichments(keeping ids: Set<String>)",
        "    private func cancelAllEnrichments()",
        "    private func show(_ item: FeaturedHeroItem, animated: Bool)",
        "    func feature(_ item: FeaturedHeroItem)",
        "    private func enrichIfNeeded(_ item: FeaturedHeroItem)",
        "    private func publishEnrichment(",
        "    private func isCurrentEnrichment(id: String, token: UInt64)",
        "    private func finishEnrichment(id: String, token: UInt64)",
        "    private static func cacheEnrichment(_ item: FeaturedHeroItem, for id: String)",
        "    private static func metaURLs(for item: FeaturedHeroItem)",
        "    func enriched(with meta: FeaturedHeroMetaTransfer)",
    ]
    var members: [String] = []
    for signature in signatures {
        guard let member = extractMember(signature: signature, from: modelSource) else {
            fatalError("FAIL: production member not extractable: \(signature)")
        }
        members.append(member)
    }
    guard let transfer = extractMember(signature: "struct FeaturedHeroMetaTransfer: Sendable", from: modelSource),
          let extractedResult = extractMember(signature: "private struct EnrichmentResult: Sendable", from: modelSource) else {
        fatalError("FAIL: production transfer/result declarations not extractable")
    }
    let result = extractedResult.replacingOccurrences(of: "private struct EnrichmentResult", with: "struct EnrichmentResult")

    let seed = members[0]
    let applySeed = members[1]
    let stop = members[2]
    let cancelObsolete = members[3]
    let cancelAll = members[4]
    let show = members[5]
    let feature = members[6]
    let enrich = members[7]
    let publish = members[8]
    let isCurrent = members[9]
    let finish = members[10]
    let cache = members[11]
    let metaURLs = members[12]
    let enriched = members[13]

    var harness = #"""
import Foundation

@inline(__always)
func require(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("FAIL: \(message)") }
}

"""#
    harness += transfer + "\n\n" + result + #"""

actor FeaturedHeroHeldFetchGate {
    private var pending: [String: [CheckedContinuation<EnrichmentResult?, Never>]] = [:]
    private var startsByID: [String: Int] = [:]
    private var cancellationObservations: [String: [Bool]] = [:]

    func hold(id: String) async -> EnrichmentResult? {
        startsByID[id, default: 0] += 1
        return await withCheckedContinuation { continuation in
            pending[id, default: []].append(continuation)
        }
    }

    func release(id: String, result: EnrichmentResult?) {
        guard var continuations = pending[id], !continuations.isEmpty else {
            fatalError("no held response for \(id)")
        }
        let continuation = continuations.removeFirst()
        pending[id] = continuations.isEmpty ? nil : continuations
        continuation.resume(returning: result)
    }

    func starts(id: String) -> Int { startsByID[id, default: 0] }

    func observeCancellation(id: String, cancelled: Bool) {
        cancellationObservations[id, default: []].append(cancelled)
    }

    func observedCancellation(id: String) -> Bool {
        cancellationObservations[id, default: []].contains(true)
    }
}

private let featuredHeroHeldFetchGate = FeaturedHeroHeldFetchGate()

struct FeaturedHeroItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let backdrop: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let runtime: String?
    let imdbRating: String?
    let genres: [String]
    let trailerYouTubeID: String?
    let defaultVideoId: String?

"""#
    harness += enriched + #"""
}

struct Animation {}
extension Animation {
    static func easeOut(duration: Double) -> Animation { Animation() }
}
@discardableResult
func withAnimation<T>(_ animation: Animation, _ body: () -> T) -> T { body() }

@MainActor
final class FeaturedHeroProductionHarness {
    static var enrichmentCache: [String: FeaturedHeroItem] = [:]
    static var enrichmentOrder: [String] = []
    static let enrichmentCacheCap = 300
    static var metaSourceBases = ["https://fixture.example/"]
    static let heroPoolCap = 5
    static let heroCrossfade = 0.45
    static let seedDebounce: Duration = .milliseconds(20)

    private(set) var hero: FeaturedHeroItem?
    private(set) var pageCount = 0
    private(set) var page = 0
    private var pool: [FeaturedHeroItem] = []
    private var rotationIndex = 0
    private var rotationTask: Task<Void, Never>?
    private var seededIds: [String] = []
    private var pendingSeed: [FeaturedHeroItem]?
    private var pendingSeedTask: Task<Void, Never>?
    private var interactionHeld = false
    private var resumeTask: Task<Void, Never>?
    private var motionEnabled = true
    private var enrichmentTasks: [String: Task<Void, Never>] = [:]
    private var enrichmentTokens: [String: UInt64] = [:]
    private var nextEnrichmentToken: UInt64 = 0

    var activeEnrichmentCount: Int { enrichmentTasks.count }
    var cachedItems: [String: FeaturedHeroItem] { Self.enrichmentCache }

    func start(_ candidates: [FeaturedHeroItem]) { seed(candidates, reduceMotion: true) }

    func removeAllEnrichmentForTest() {
        cancelObsoleteEnrichments(keeping: [])
    }

    private func startRotation() {
        // Timer ownership is production code's responsibility; this inert collaborator keeps this test focused
        // on the extracted seed/lease methods and never waits twelve seconds.
        rotationTask = nil
    }

    private func applyPendingSeed() async {}

    private static func fetchEnrichment(candidates: [URL]) async -> EnrichmentResult? {
        guard let url = candidates.first else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        let response = await featuredHeroHeldFetchGate.hold(id: id)
        await featuredHeroHeldFetchGate.observeCancellation(id: id, cancelled: Task.isCancelled)
        return response
    }

"""#
    harness += seed + "\n\n" + applySeed + "\n\n" + stop + "\n\n" + cancelObsolete + "\n\n" + cancelAll
    harness += "\n\n" + show + "\n\n" + feature + "\n\n" + enrich + "\n\n" + publish + "\n\n" + isCurrent + "\n\n" + finish
    harness += "\n\n" + cache + "\n\n" + metaURLs
    harness += #"""
}

private func item(_ id: String) -> FeaturedHeroItem {
    FeaturedHeroItem(
        id: id, type: "movie", name: id, poster: nil, backdrop: nil, logo: nil,
        description: nil, releaseInfo: nil, runtime: nil, imdbRating: nil, genres: [],
        trailerYouTubeID: nil, defaultVideoId: nil)
}

private func result(_ description: String) -> EnrichmentResult {
    EnrichmentResult(
        meta: FeaturedHeroMetaTransfer(
            description: description, imdbRating: nil, releaseInfo: nil, background: nil,
            runtime: nil, genres: nil, logo: nil, trailerYouTubeID: nil, defaultVideoId: nil),
        host: "fixture")
}

@main
@MainActor
private enum FeaturedHeroProductionLifecycleCases {
    static func waitForStarts(_ ids: [String], each count: Int) async -> Bool {
        for _ in 0..<500 {
            var ready = true
            for id in ids {
                if await featuredHeroHeldFetchGate.starts(id: id) < count { ready = false; break }
            }
            if ready { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    static func waitForCache(_ model: FeaturedHeroProductionHarness, id: String, description: String) async -> Bool {
        for _ in 0..<500 {
            if model.cachedItems[id]?.description == description { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    static func main() async {
        FeaturedHeroProductionHarness.enrichmentCache.removeAll()
        FeaturedHeroProductionHarness.enrichmentOrder.removeAll()

        // Five real production enrichIfNeeded leases are held, then stop() cancels all five. Late responses
        // are released after cancellation and must fail the production cancellation/token fences.
        let heldModel = FeaturedHeroProductionHarness()
        let heldIDs = (0..<5).map { "held-\($0)" }
        heldModel.start(heldIDs.map(item))
        require(await waitForStarts(heldIDs, each: 1), "production seed starts all five held enrichments")
        heldModel.stop()
        require(heldModel.activeEnrichmentCount == 0, "production stop retires all five owned leases")
        for id in heldIDs { await featuredHeroHeldFetchGate.release(id: id, result: result("late-\(id)")) }
        try? await Task.sleep(for: .milliseconds(30))
        for id in heldIDs {
            require(await featuredHeroHeldFetchGate.observedCancellation(id: id),
                    "production stop calls Task.cancel for \(id)")
        }
        require(heldModel.cachedItems.isEmpty, "late canceled production responses do not enter cache")
        require(heldModel.hero?.description == nil, "late canceled production responses do not publish hero state")

        // The exact obsolete-pool cancellation member is exercised directly through a narrow test hook. This
        // keeps the held response alive long enough to observe Task.cancel rather than only token invalidation.
        let obsoleteModel = FeaturedHeroProductionHarness()
        let obsoleteItem = item("obsolete-id")
        obsoleteModel.start([obsoleteItem])
        require(await waitForStarts([obsoleteItem.id], each: 1), "obsolete production lease starts")
        obsoleteModel.removeAllEnrichmentForTest()
        require(obsoleteModel.activeEnrichmentCount == 0, "obsolete production lease is retired")
        await featuredHeroHeldFetchGate.release(id: obsoleteItem.id, result: result("late-obsolete"))
        try? await Task.sleep(for: .milliseconds(20))
        require(await featuredHeroHeldFetchGate.observedCancellation(id: obsoleteItem.id),
                "obsolete production lease calls Task.cancel")
        require(obsoleteModel.cachedItems[obsoleteItem.id] == nil,
                "obsolete production response cannot enter cache")

        // Same-ID hide/reseed runs the actual seed early-return plus the new re-arm loop. Releasing the old
        // response first must not retire the successor task or poison its eventual fresh cache/publication.
        let successorModel = FeaturedHeroProductionHarness()
        let successorItem = item("same-id")
        successorModel.start([successorItem])
        require(await waitForStarts([successorItem.id], each: 1), "production seed starts successor predecessor")
        successorModel.stop()
        successorModel.start([successorItem])
        require(await waitForStarts([successorItem.id], each: 2), "same-pool production seed immediately retries canceled work")
        await featuredHeroHeldFetchGate.release(id: successorItem.id, result: result("stale"))
        try? await Task.sleep(for: .milliseconds(20))
        require(successorModel.activeEnrichmentCount == 1, "stale production completion keeps successor lease")
        require(successorModel.cachedItems[successorItem.id] == nil, "stale production completion cannot poison cache")
        await featuredHeroHeldFetchGate.release(id: successorItem.id, result: result("fresh"))
        require(await waitForCache(successorModel, id: successorItem.id, description: "fresh"),
                "current successor production completion publishes fresh cache")
        require(successorModel.hero?.description == "fresh", "current successor production completion updates hero")
        successorModel.start([successorItem])
        try? await Task.sleep(for: .milliseconds(20))
        require(await featuredHeroHeldFetchGate.starts(id: successorItem.id) == 2,
                "cached production pool suppresses duplicate enrichment")

        // A keyboard-featured title may be outside the ambient pool. The actual same-pool seed must re-arm its
        // unfinished lease too, while preserving the pool cache and duplicate-work guards.
        let featuredModel = FeaturedHeroProductionHarness()
        let poolItem = item("ambient-pool")
        let featuredItem = item("keyboard-featured")
        featuredModel.start([poolItem])
        require(await waitForStarts([poolItem.id], each: 1), "ambient pool production lease starts")
        await featuredHeroHeldFetchGate.release(id: poolItem.id, result: result("pool"))
        require(await waitForCache(featuredModel, id: poolItem.id, description: "pool"),
                "ambient pool production lease warms its cache")
        featuredModel.feature(featuredItem)
        require(await waitForStarts([featuredItem.id], each: 1), "keyboard-featured production lease starts")
        featuredModel.stop()
        featuredModel.start([poolItem])
        require(await waitForStarts([featuredItem.id], each: 2),
                "same-pool production seed re-arms an unfinished out-of-pool hero")
        await featuredHeroHeldFetchGate.release(id: featuredItem.id, result: result("stale-featured"))
        try? await Task.sleep(for: .milliseconds(20))
        require(await featuredHeroHeldFetchGate.observedCancellation(id: featuredItem.id),
                "stop cancels the out-of-pool featured request")
        await featuredHeroHeldFetchGate.release(id: featuredItem.id, result: result("fresh-featured"))
        require(await waitForCache(featuredModel, id: featuredItem.id, description: "fresh-featured"),
                "re-armed out-of-pool featured request publishes fresh cache")

        // A real failed production response retires its lease; same-pool seed can retry, and a successful retry
        // warms the real static cache so subsequent same-pool emits remain quiet.
        let retryModel = FeaturedHeroProductionHarness()
        let retryItem = item("retry-id")
        retryModel.start([retryItem])
        require(await waitForStarts([retryItem.id], each: 1), "production retry case starts initial lease")
        await featuredHeroHeldFetchGate.release(id: retryItem.id, result: nil)
        for _ in 0..<500 where retryModel.activeEnrichmentCount != 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        retryModel.start([retryItem])
        require(await waitForStarts([retryItem.id], each: 2), "failed production lease can be retried")
        await featuredHeroHeldFetchGate.release(id: retryItem.id, result: result("cached"))
        require(await waitForCache(retryModel, id: retryItem.id, description: "cached"),
                "successful production retry warms cache")

        print("ok: extracted production hero leases, stop/reseed retry, stale-token, and cache contracts passed")
    }
}
"""#

    let harnessPath = buildDirectory.appendingPathComponent("FeaturedHeroProductionLifecycle.swift")
    do {
        try harness.write(to: harnessPath, atomically: true, encoding: .utf8)
    } catch {
        fatalError("FAIL: could not write extracted production harness: \(error)")
    }
    print("extracted production hero members: \(members.count), harness: \(harnessPath.path)")
    return harnessPath
}

private func runSourceContracts(root: URL) {
    let model = readSource(root, "app/SourcesiOS/FeaturedHeroModel.swift")
    let logo = readSource(root, "app/SourcesShared/ERDBConfig.swift")

    require(model.contains("private var enrichmentTasks: [String: Task<Void, Never>]"),
            "enrichment tasks are explicitly owned per item")
    require(model.contains("private var enrichmentTokens: [String: UInt64]"),
            "enrichment tasks carry a per-request token")
    require(model.contains("cancelAllEnrichments()") && model.contains("for task in enrichmentTasks.values { task.cancel() }"),
            "stop/deinit cancellation fence is present")
    require(model.contains("cancelObsoleteEnrichments(keeping: Set(pool.map(\\.id)))"),
            "reseed removes work for obsolete candidates")
    require(model.contains("for item in pool { enrichIfNeeded(item) }"),
            "same-pool seed re-arms unfinished work")
    require(model.contains("defer { self?.finishEnrichment(id: item.id, token: token) }"),
            "completion retires only its own lease")
    require(model.contains("guard isCurrentEnrichment(id: item.id, token: token), !Task.isCancelled"),
            "publication is fenced by cancellation and token")
    require(model.contains("Task.detached(priority: .utility)"),
            "meta decoding is scheduled off the MainActor")
    require(model.contains("struct FeaturedHeroMetaTransfer: Sendable"),
            "only the narrow decoded value transfer is Sendable")
    require(model.components(separatedBy: "JSONDecoder().decode").count == 2,
            "JSON decoding remains in one detached helper")

    require(!logo.contains("AsyncImage"), "resolved logos do not use raw AsyncImage")
    require(logo.contains("private static var logoMaxPixel: CGFloat { 960 }"),
            "resolved logos have an explicit small pixel budget")
    require(logo.contains("let signedURL = VortXEdgeAuth.signedURL(rawURL)"),
            "resolved logo signed URL memo path is retained")
    require(logo.contains("PosterImageLoader.load(signedURL.absoluteString, maxPixel: Self.logoMaxPixel)"),
            "resolved logos use the bounded shared loader")
    require(logo.contains("guard !Task.isCancelled else { return }\n        logoImage = nil"),
            "canceled logo task cannot clear a successor image")
    require(logo.contains("LogoLoadKey(id: id, type: type, fallbackLogo: fallbackLogo)"),
            "logo task restarts when same-id enrichment changes its fallback")
    require(logo.contains(".aspectRatio(contentMode: .fit)")
                && logo.contains(".shadow(color: .black.opacity(shadowOpacity)"),
            "logo fit and shadow framing are retained")
}

@main
struct FeaturedHeroLifecycleContractTests {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                       ?? FileManager.default.currentDirectoryPath)
        let buildDirectory = root.appendingPathComponent("app/build/featured-hero-lifecycle", isDirectory: true)
        do { try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true) }
        catch { fatalError("FAIL: could not create retained build directory: \(error)") }

        runSourceContracts(root: root)
        let harness = makeProductionHarness(root: root, buildDirectory: buildDirectory)
        let binary = buildDirectory.appendingPathComponent("featured-hero-production-tests")
        let compile = runProcess(
            "/usr/bin/xcrun",
            arguments: ["swiftc", "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
             "-warnings-as-errors", harness.path, "-o", binary.path],
            cwd: root)
        guard compile.0 == 0 else {
            print(compile.1)
            fatalError("FAIL: extracted production lifecycle harness did not compile")
        }
        let run = runProcess(binary.path, arguments: [], cwd: root)
        print(run.1)
        guard run.0 == 0 else { fatalError("FAIL: extracted production lifecycle harness failed") }
        print("ok: production lifecycle extraction and source contracts passed")
    }
}
