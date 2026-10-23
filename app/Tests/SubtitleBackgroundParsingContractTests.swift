import Foundation

// Host runner inserts the production addExternalSubtitle method at the marker below, replacing
// only its parser symbol with ControlledSubtitleParser so scheduling and stale ownership are observable.
// Compile with the actual SubtitleCueRenderer parser section; no player/network objects are created.
private final class ParserControl: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var onMain = false
    var starts: Int { lock.lock(); defer { lock.unlock() }; return count }
    var parsedOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func begin() {
        lock.lock(); count += 1; onMain = onMain || Thread.isMainThread; lock.unlock()
        _ = release.wait(timeout: .now() + 2)
    }
    func proceed() { release.signal() }
}
private enum ControlledSubtitleParser {
    static let control = ParserControl()
    nonisolated static func parse(data: Data) -> [SubtitleCue] {
        control.begin()
        return SubtitleCueRenderer.parse(data: data)
    }
}
private final class FetchControl: @unchecked Sendable {
    typealias Callback = @Sendable (Data?) -> Void
    private let lock = NSLock()
    private var callback: Callback?
    func set(_ value: @escaping Callback) { lock.lock(); callback = value; lock.unlock() }
    func deliver(_ data: Data?) {
        lock.lock(); let current = callback; callback = nil; lock.unlock()
        current?(data)
    }
}
private enum SubtitleFileFetcher {
    static let control = FetchControl()
    static func fetch(_ url: URL, timeout: TimeInterval, done: @escaping @Sendable (Data?) -> Void) {
        control.set(done)
    }
}
private final class FixtureItem: @unchecked Sendable {}
@MainActor private final class FixtureRenderer {
    var loads: [[SubtitleCue]] = []
    func load(cues: [SubtitleCue]) { loads.append(cues) }
}
private struct FixtureSelectionIntent { mutating func selectExternalSubtitle() {} }
@MainActor private final class FixtureEngine {
    var externalSubtitleRequestRevision: UInt64 = 0
    var activeLoadToken: Int? = 1
    var item: FixtureItem? = FixtureItem()
    var externalSubLabel: (title: String, lang: String)?
    var subtitleRenderer = FixtureRenderer()
    var results: [Bool] = []
    var nativeDeselections = 0
    func owns(_ candidate: FixtureItem, loadToken: Int) -> Bool {
        candidate === item && loadToken == activeLoadToken
    }
    func updatePendingSelectionIntent(_ update: (inout FixtureSelectionIntent) -> Void) {
        var intent = FixtureSelectionIntent(); update(&intent)
    }
    func selectNativeSubtitle(_ index: Int?, activatingExternalAfterSettlement: Bool) {
        nativeDeselections += 1
    }
    func request() {
        addExternalSubtitle(url: "https://example.invalid/captions.srt", title: "Fixture", lang: "en", timeout: 1) {
            self.results.append($0)
        }
    }
    // __PRODUCTION_ADD_EXTERNAL_SUBTITLE__
}
@main @MainActor private enum SubtitleBackgroundParsingContractTests {
    static func awaitCondition(_ label: String, _ predicate: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Timed out: \(label)")
    }
    static func check(_ label: String, _ condition: Bool) {
        precondition(condition, label)
        print("PASS \(label)")
    }
    static func main() async {
        let fixture = Data("1\n00:00:01,000 --> 00:00:02,000\nOwned cue\n\n".utf8)
        let engine = FixtureEngine()
        engine.request()
        engine.externalSubtitleRequestRevision += 1
        SubtitleFileFetcher.control.deliver(fixture)
        await awaitCondition("stale fetch rejected") { engine.results.count == 1 }
        check("superseded fetch does not start parser work", !engine.results[0] && ControlledSubtitleParser.control.starts == 0)

        engine.request()
        SubtitleFileFetcher.control.deliver(fixture)
        await awaitCondition("background parser started") { ControlledSubtitleParser.control.starts == 1 }
        check("main actor remains responsive while parser is blocked", !ControlledSubtitleParser.control.parsedOnMain)
        engine.item = FixtureItem()
        ControlledSubtitleParser.control.proceed()
        await awaitCondition("old item rejected after parsing") { engine.results.count == 2 }
        check("item replacement during parse cannot publish stale cues", !engine.results[1] && engine.subtitleRenderer.loads.isEmpty)

        engine.request()
        SubtitleFileFetcher.control.deliver(fixture)
        await awaitCondition("owned parser started") { ControlledSubtitleParser.control.starts == 2 }
        ControlledSubtitleParser.control.proceed()
        await awaitCondition("owned captions published") { engine.results.count == 3 }
        check("owned completion publishes exact production cues once", engine.results[2] && engine.subtitleRenderer.loads.count == 1
              && engine.subtitleRenderer.loads[0].first?.text == "Owned cue" && engine.nativeDeselections == 1)

        engine.request()
        SubtitleFileFetcher.control.deliver(fixture)
        await awaitCondition("selection parser started") { ControlledSubtitleParser.control.starts == 3 }
        engine.externalSubtitleRequestRevision += 1
        ControlledSubtitleParser.control.proceed()
        await awaitCondition("changed selection rejected after parsing") { engine.results.count == 4 }
        check("selection change during parse preserves working captions", !engine.results[3] && engine.subtitleRenderer.loads.count == 1
              && engine.nativeDeselections == 1)

        engine.request()
        SubtitleFileFetcher.control.deliver(nil)
        await awaitCondition("failed fetch completed") { engine.results.count == 5 }
        check("failed fetch preserves captions and does not parse", !engine.results[4] && engine.subtitleRenderer.loads.count == 1
              && ControlledSubtitleParser.control.starts == 3)
        check("8 MiB byte and scalar ceilings match fetch budget", SubtitleCueRenderer.maximumInputBytes == 8 * 1024 * 1024
              && SubtitleCueRenderer.maximumInputScalars == SubtitleCueRenderer.maximumInputBytes)
        let longBody = String(repeating: "x", count: 1_000)
        let largeText = (0..<3_000).map { index in
            "\(index + 1)\n00:00:01,000 --> 00:00:02,000\n\(longBody)\n\n"
        }.joined()
        check("valid subtitle above 2 MiB parses", largeText.utf8.count > 2 * 1024 * 1024
              && !SubtitleCueRenderer.parse(data: Data(largeText.utf8)).isEmpty)
        check("bytes above 8 MiB reject before decode", SubtitleCueRenderer.parse(data: Data(count: 8 * 1024 * 1024 + 1)).isEmpty)
        check("decoded text above scalar ceiling rejects", SubtitleCueRenderer.parse(text: String(repeating: "x", count: 8 * 1024 * 1024 + 1)).isEmpty)
        check("cue count and cue text bounds remain", SubtitleCueRenderer.maximumCueCount == 12_000 && SubtitleCueRenderer.maximumCueTextScalars == 4_096)
        print("SUBTITLE_BACKGROUND_PARSING_GREEN")
    }
}
