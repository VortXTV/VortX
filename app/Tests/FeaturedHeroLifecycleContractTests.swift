// Inert source/lifecycle contract proof for the Apple featured hero repairs.
//
//   scripts/test-featured-hero-lifecycle.sh
//
// The held-response harness mirrors the production lease invariant without opening a network connection or
// constructing a SwiftUI model. Source gates then prove the real production files own/cancel the tasks,
// fence stale completions, decode through a detached value transfer, and use the bounded logo loader.

import Foundation

private final class HeldEnrichmentHarness {
    private var nextToken: UInt64 = 0
    private(set) var tasks: [String: UInt64] = [:]
    private(set) var cache: [String: String] = [:]
    var visibleID: String?
    private(set) var published: String?

    func start(_ id: String) -> UInt64? {
        guard cache[id] == nil, tasks[id] == nil else { return nil }
        nextToken &+= 1
        tasks[id] = nextToken
        return nextToken
    }

    func stop() {
        tasks.removeAll()
    }

    func finish(id: String, token: UInt64, value: String?) {
        guard tasks[id] == token else { return }
        tasks.removeValue(forKey: id)
        guard let value else { return }
        cache[id] = value
        if visibleID == id { published = value }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func source(_ root: String, _ relativePath: String) -> String {
    let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath).path
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError("FAIL: could not read \(relativePath)")
    }
    return value
}

private func runHeldResponseContracts() {
    let model = HeldEnrichmentHarness()
    let tokens = (0..<5).compactMap { model.start("held-\($0)") }
    require(tokens.count == 5, "five pool enrichments must be admitted")
    model.visibleID = "held-0"
    model.stop()
    for (index, token) in tokens.enumerated() {
        model.finish(id: "held-\(index)", token: token, value: "late-\(index)")
    }
    require(model.tasks.isEmpty, "stop must retire every owned held request")
    require(model.cache.isEmpty, "canceled held responses must not enter the enrichment cache")
    require(model.published == nil, "canceled held responses must not publish visible state")

    let successor = HeldEnrichmentHarness()
    let oldToken = successor.start("same-id")!
    successor.stop()
    let newToken = successor.start("same-id")!
    successor.visibleID = "same-id"
    successor.finish(id: "same-id", token: oldToken, value: "stale")
    require(successor.tasks["same-id"] == newToken, "stale completion must not remove a successor task")
    require(successor.cache.isEmpty && successor.published == nil,
            "stale completion must not poison a hidden/reseeded successor")
    successor.finish(id: "same-id", token: newToken, value: "fresh")
    require(successor.cache["same-id"] == "fresh" && successor.published == "fresh",
            "current successor completion must publish normally")

    let retry = HeldEnrichmentHarness()
    let firstAttempt = retry.start("retry")!
    retry.finish(id: "retry", token: firstAttempt, value: nil)
    let secondAttempt = retry.start("retry")!
    require(secondAttempt != firstAttempt, "a failed request must be retryable")
    retry.finish(id: "retry", token: secondAttempt, value: "cached")
    require(retry.start("retry") == nil && retry.cache["retry"] == "cached",
            "a successful retry must warm the cache and suppress duplicate work")
}

private func runSourceContracts(root: String) {
    let model = source(root, "app/SourcesiOS/FeaturedHeroModel.swift")
    let logo = source(root, "app/SourcesShared/ERDBConfig.swift")

    require(model.contains("private var enrichmentTasks: [String: Task<Void, Never>]"),
            "enrichment tasks are explicitly owned per item")
    require(model.contains("private var enrichmentTokens: [String: UInt64]"),
            "enrichment tasks carry a per-request token")
    require(model.contains("cancelAllEnrichments()") && model.contains("for task in enrichmentTasks.values { task.cancel() }"),
            "stop/deinit cancellation fence is present")
    require(model.contains("cancelObsoleteEnrichments(keeping: Set(pool.map(\\.id)))"),
            "reseed removes work for obsolete candidates")
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
    require(logo.contains(".aspectRatio(contentMode: .fit)")
                && logo.contains(".shadow(color: .black.opacity(shadowOpacity)"),
            "logo fit and shadow framing are retained")
}

@main
struct FeaturedHeroLifecycleContractTests {
    static func main() {
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        runHeldResponseContracts()
        runSourceContracts(root: root)
        print("ok: featured hero lifecycle, stale-token, decode-scheduling, and logo-budget contracts passed")
    }
}
