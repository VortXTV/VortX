// Standalone production-wiring and mutation gate for the debrid credential security contract.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
//     -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/DebridCredentialCallerGateTests.swift \
//     -o /tmp/debrid-credential-callers && /tmp/debrid-credential-callers
//
// This gate reads the exact production sources. Every named fence also has a focused live-source mutant below;
// a protection is counted only when its mutant makes the associated rule red.

import Foundation

private struct SourceFile: Sendable {
    let path: String
    let text: String

    var code: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

private struct Rule: Sendable {
    let name: String
    let files: [String]
    let violations: @Sendable ([String: SourceFile]) -> [String]
}

private struct Mutation: Sendable {
    let name: String
    let rule: String
    let path: String
    let find: String
    let replacement: String
}

private struct PublicationBinding: Sendable {
    let scopeStart: String
    let scopeEnd: String?
    let revisionNeedle: String
    let mutationNeedle: String
}

private struct PublicationSite: Sendable {
    let label: String
    let path: String
    let callScopeStart: String
    let callScopeEnd: String?
    let versionedCall: String
    let plainCall: String
    let bindings: [PublicationBinding]
    let transportNeedles: [String]
}

private struct PublicationBodyMatch {
    let body: Range<String.Index>
    let guardEnd: String.Index
}

private func load(root: String, path: String) -> SourceFile? {
    let absolute = root + "/" + path
    guard let text = try? String(contentsOfFile: absolute, encoding: .utf8) else { return nil }
    return SourceFile(path: path, text: text)
}

private func require(_ file: SourceFile, _ needle: String, _ reason: String) -> [String] {
    file.code.contains(needle) ? [] : ["\(file.path): missing \(reason) (`\(needle)`)" ]
}

private func forbid(_ file: SourceFile, _ needle: String, _ reason: String) -> [String] {
    file.code.contains(needle) ? ["\(file.path): \(reason) (`\(needle)`)" ] : []
}

private func section(_ file: SourceFile, start: String, end: String) -> SourceFile? {
    guard let startRange = file.code.range(of: start),
          let endRange = file.code.range(of: end, range: startRange.upperBound..<file.code.endIndex) else {
        return nil
    }
    return SourceFile(path: file.path, text: String(file.code[startRange.lowerBound..<endRange.lowerBound]))
}

private func occurrenceCount(_ needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
}

private func scopedRange(in text: String, start: String, end: String?) -> Range<String.Index>? {
    guard let startRange = text.range(of: start) else { return nil }
    guard let end else { return startRange.lowerBound..<text.endIndex }
    guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
        return nil
    }
    return startRange.lowerBound..<endRange.lowerBound
}

private func matchingBrace(in text: String, opening: String.Index) -> String.Index? {
    enum LexicalState {
        case code
        case string
        case lineComment
        case blockComment(Int)
    }

    func following(_ index: String.Index) -> String.Index? {
        let next = text.index(after: index)
        return next < text.endIndex ? next : nil
    }

    var state = LexicalState.code
    var depth = 1
    var index = text.index(after: opening)
    while index < text.endIndex {
        let character = text[index]
        let nextIndex = following(index)
        let nextCharacter = nextIndex.map { text[$0] }

        switch state {
        case .code:
            if character == "\"" {
                state = .string
            } else if character == "/", nextCharacter == "/" {
                state = .lineComment
                index = nextIndex!
            } else if character == "/", nextCharacter == "*" {
                state = .blockComment(1)
                index = nextIndex!
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        case .string:
            if character == "\\", let nextIndex {
                index = nextIndex
            } else if character == "\"" {
                state = .code
            }
        case .lineComment:
            if character == "\n" { state = .code }
        case .blockComment(let nesting):
            if character == "/", nextCharacter == "*" {
                state = .blockComment(nesting + 1)
                index = nextIndex!
            } else if character == "*", nextCharacter == "/" {
                state = nesting == 1 ? .code : .blockComment(nesting - 1)
                index = nextIndex!
            }
        }
        index = text.index(after: index)
    }
    return nil
}

private func publicationBodyMatch(
    in text: String,
    binding: PublicationBinding
) -> PublicationBodyMatch? {
    guard let scope = scopedRange(in: text, start: binding.scopeStart, end: binding.scopeEnd) else {
        return nil
    }
    let callNeedles = [
        "DebridCredentialSnapshotStore.shared.compareAndPublish(",
        "credentialStore.compareAndPublish(",
    ]
    let mutationNeedle = "mutation: {"
    var cursor = scope.lowerBound
    while let call = callNeedles.compactMap({
        text.range(of: $0, range: cursor..<scope.upperBound)
    }).min(by: { $0.lowerBound < $1.lowerBound }) {
        guard let mutation = text.range(of: mutationNeedle, range: call.upperBound..<scope.upperBound) else {
            return nil
        }
        let header = text[call.lowerBound..<mutation.lowerBound]
        let opening = text.index(before: mutation.upperBound)
        guard let closing = matchingBrace(in: text, opening: opening) else { return nil }
        let body = text.index(after: opening)..<closing
        if header.contains(binding.revisionNeedle), text[body].contains(binding.mutationNeedle) {
            guard let closeParenthesis = text.range(
                of: ")",
                range: text.index(after: closing)..<scope.upperBound
            ), let elseRange = text.range(
                of: "else",
                range: closeParenthesis.upperBound..<scope.upperBound
            ), let elseOpening = text.range(
                of: "{",
                range: elseRange.upperBound..<scope.upperBound
            ), let elseClosing = matchingBrace(in: text, opening: elseOpening.lowerBound) else {
                return nil
            }
            return PublicationBodyMatch(body: body, guardEnd: text.index(after: elseClosing))
        }
        cursor = text.index(after: closing)
    }
    return nil
}

private func publicationSiteViolations(
    _ site: PublicationSite,
    files: [String: SourceFile]
) -> [String] {
    guard let file = files[site.path] else { return ["missing non-player caller \(site.path)"] }
    guard let callScope = scopedRange(
        in: file.text,
        start: site.callScopeStart,
        end: site.callScopeEnd
    ) else {
        return ["\(site.path): \(site.label) call scope is missing"]
    }
    let scopedCallText = String(file.text[callScope])
    var violations: [String] = []
    let versionedCount = occurrenceCount(site.versionedCall, in: scopedCallText)
    if versionedCount != 1 {
        violations.append(
            "\(site.path): \(site.label) expected one exact versioned call, found \(versionedCount)"
        )
    }
    if scopedCallText.contains(site.plainCall) {
        violations.append("\(site.path): \(site.label) regressed to its plain result wrapper")
    }
    for binding in site.bindings where publicationBodyMatch(in: file.text, binding: binding) == nil {
        violations.append(
            "\(site.path): \(site.label) does not bind `\(binding.mutationNeedle)` "
                + "to `\(binding.revisionNeedle)` inside one atomic mutation body"
        )
    }
    for needle in site.transportNeedles where !file.text.contains(needle) {
        violations.append("\(site.path): \(site.label) lost revision transport (`\(needle)`)")
    }
    return violations
}

private func stripPublicationRevision(_ site: PublicationSite, from file: SourceFile) -> SourceFile? {
    guard let scope = scopedRange(in: file.text, start: site.callScopeStart, end: site.callScopeEnd),
          let call = file.text.range(of: site.versionedCall, range: scope),
          file.text.range(of: site.versionedCall, range: call.upperBound..<scope.upperBound) == nil else {
        return nil
    }
    var text = file.text
    text.replaceSubrange(call, with: site.plainCall)
    return SourceFile(path: file.path, text: text)
}

private func movePublicationOutsideSeam(_ site: PublicationSite, from file: SourceFile) -> SourceFile? {
    guard let binding = site.bindings.first,
          let match = publicationBodyMatch(in: file.text, binding: binding) else { return nil }
    let body = String(file.text[match.body])
    let text = String(file.text[..<match.body.lowerBound])
        + String(file.text[match.body.upperBound..<match.guardEnd])
        + "\n"
        + body
        + "\n"
        + String(file.text[match.guardEnd...])
    return SourceFile(path: file.path, text: text)
}

private func requireCount(_ file: SourceFile, _ needle: String, _ expected: Int,
                          _ reason: String) -> [String] {
    let count = occurrenceCount(needle, in: file.code)
    return count == expected ? [] : ["\(file.path): \(reason), expected \(expected), found \(count)"]
}

private func requireOrdered(_ file: SourceFile, _ needles: [String], _ reason: String) -> [String] {
    var cursor = file.code.startIndex
    for needle in needles {
        guard let range = file.code.range(of: needle, range: cursor..<file.code.endIndex) else {
            return ["\(file.path): \(reason), missing or out of order (`\(needle)`)" ]
        }
        cursor = range.upperBound
    }
    return []
}

private let statePath = "app/SourcesShared/DebridCredentialState.swift"
private let keysPath = "app/SourcesShared/DebridKeys.swift"
private let resolverPath = "app/SourcesShared/DebridResolver.swift"
private let keychainPath = "app/SourcesShared/Keychain.swift"
private let coreModelsPath = "app/SourcesShared/CoreModels.swift"
private let syncPath = "app/SourcesShared/VortXSyncManager.swift"
private let torBoxSearchPath = "app/SourcesShared/TorBoxSearchSource.swift"
private let tvDetailPath = "app/SourcesTV/DetailView.swift"
private let tvHomePath = "app/SourcesTV/HomeView.swift"
private let tvEpisodePath = "app/SourcesTV/TVEpisodePanel.swift"
private let debridLibraryPath = "app/SourcesiOS/DebridLibraryView.swift"
private let downloadPickerPath = "app/SourcesiOS/DownloadQualityPickerView.swift"
private let batchDownloadPath = "app/SourcesiOS/iOSBatchDownloadCoordinator.swift"
private let iosDetailPath = "app/SourcesiOS/iOSDetailView.swift"
private let iosRootPath = "app/SourcesiOS/iOSRootView.swift"
private let playerScreenPath = "app/Sources/PlayerScreen.swift"
private let tvPlayerPath = "app/SourcesTV/TVPlayerView.swift"

private let publicationSites: [PublicationSite] = [
    PublicationSite(
        label: "TV detail download",
        path: tvDetailPath,
        callScopeStart: "let tvDownloadResult = await DebridCoordinator.shared",
        callScopeEnd: "/// The episode context for a debrid resolve",
        versionedCall: ".resolvedPlaybackURLVersioned(for: best, episode: hint)",
        plainCall: ".resolvedPlaybackURL(for: best, episode: hint)",
        bindings: [PublicationBinding(
            scopeStart: "let tvDownloadResult = await DebridCoordinator.shared",
            scopeEnd: "/// The episode context for a debrid resolve",
            revisionNeedle: "revision: tvDownloadResult.revision",
            mutationNeedle: "queueDownload(tvDownloadResult.value)"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "TV detail resume",
        path: tvDetailPath,
        callScopeStart: "tvResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
        callScopeEnd: "// Candidate order =",
        versionedCall: "CWResume.resolvedURLVersioned(for: entry)",
        plainCall: "CWResume.resolvedURL(for: entry)",
        bindings: [PublicationBinding(
            scopeStart: "tvResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
            scopeEnd: "// Candidate order =",
            revisionNeedle: "revision: tvResumeResult.revision",
            mutationNeedle: "presenter.request = PlaybackRequest("
        )],
        transportNeedles: [
            "let tvResumeResult: DebridVersionedResult<(url: URL, refreshed: Bool)>?",
            "mutation: {}",
        ]
    ),
    PublicationSite(
        label: "TV detail cached race",
        path: tvDetailPath,
        callScopeStart: "let tvRaceResult = await DebridCoordinator.shared.resolveFirstPlayableVersioned(",
        callScopeEnd: "// No parallel-cached winner:",
        versionedCall: "resolveFirstPlayableVersioned(",
        plainCall: "resolveFirstPlayable(",
        bindings: [PublicationBinding(
            scopeStart: "let tvRaceResult = await DebridCoordinator.shared.resolveFirstPlayableVersioned(",
            scopeEnd: "// No parallel-cached winner:",
            revisionNeedle: "revision: tvRaceResult.revision",
            mutationNeedle: "presenter.request = PlaybackRequest("
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "TV detail manual playback",
        path: tvDetailPath,
        callScopeStart: "let tvPlaybackResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
        callScopeEnd: "private func filterBar(",
        versionedCall: "resolvedPlaybackRefVersioned(",
        plainCall: "resolvedPlaybackRef(",
        bindings: [PublicationBinding(
            scopeStart: "let tvPlaybackResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
            scopeEnd: "private func filterBar(",
            revisionNeedle: "revision: tvPlaybackResult.revision",
            mutationNeedle: "presenter.request = PlaybackRequest("
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "TV home resume",
        path: tvHomePath,
        callScopeStart: "let homeResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
        callScopeEnd: "private func resumeSource(",
        versionedCall: "CWResume.resolvedURLVersioned(for: entry)",
        plainCall: "CWResume.resolvedURL(for: entry)",
        bindings: [
            PublicationBinding(
                scopeStart: "let homeResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
                scopeEnd: "if refreshed, let service = entry.debridService",
                revisionNeedle: "revision: homeResumeResult.revision",
                mutationNeedle: "bridge.loadMeta("
            ),
            PublicationBinding(
                scopeStart: "if refreshed, let service = entry.debridService",
                scopeEnd: "// No fresh link",
                revisionNeedle: "revision: homeResumeResult.revision",
                mutationNeedle: "presenter.request = PlaybackRequest("
            ),
            PublicationBinding(
                scopeStart: "NSLog(\"[cw-probe] tv directResume: svc=%@ hash=%@ fileIdx=%@ reresolve=NIL",
                scopeEnd: "private func resumeSource(",
                revisionNeedle: "revision: homeResumeResult.revision",
                mutationNeedle: "presenter.request = PlaybackRequest("
            ),
        ],
        transportNeedles: []
    ),
    PublicationSite(
        label: "TV episode selection",
        path: tvEpisodePath,
        callScopeStart: "let candidateResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
        callScopeEnd: "guard let selected else",
        versionedCall: "resolvedPlaybackRefVersioned(",
        plainCall: "resolvedPlaybackRef(",
        bindings: [
            PublicationBinding(
                scopeStart: "let candidateResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
                scopeEnd: "guard let selected else",
                revisionNeedle: "revision: candidateResult.revision",
                mutationNeedle: "selected = (candidate, url, candidateResult.value, candidateResult.revision)"
            ),
            PublicationBinding(
                scopeStart: "guard let revision = selected.revision",
                scopeEnd: "/// Tell the embedded server",
                revisionNeedle: "revision: revision",
                mutationNeedle: "request = makeRequest()"
            ),
        ],
        transportNeedles: [
            "var selected: (stream: CoreStream, url: URL, ref: DebridPlaybackRef?, revision: UInt64?)?",
            "guard let revision = selected.revision else { return makeRequest() }",
        ]
    ),
    PublicationSite(
        label: "cloud library browse",
        path: debridLibraryPath,
        callScopeStart: "loader: @escaping DebridLibraryLoadStateMachine<Library>.Loader = {",
        callScopeEnd: "    ) {",
        versionedCall: "cloudLibraryVersioned()",
        plainCall: "cloudLibrary()",
        bindings: [PublicationBinding(
            scopeStart: "let result = await loader()",
            scopeEnd: "private func beginAttempt(",
            revisionNeedle: "revision: result.revision",
            mutationNeedle: "phase = .loaded"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "download picker",
        path: downloadPickerPath,
        callScopeStart: "let pickerResult = await DebridCoordinator.shared",
        callScopeEnd: "// Nothing in the list could be queued.",
        versionedCall: ".resolvedPlaybackURLVersioned(for: head, episode: episode)",
        plainCall: ".resolvedPlaybackURL(for: head, episode: episode)",
        bindings: [PublicationBinding(
            scopeStart: "let pickerResult = await DebridCoordinator.shared",
            scopeEnd: "// Nothing in the list could be queued.",
            revisionNeedle: "revision: pickerResult.revision",
            mutationNeedle: "queued = queueResolved(pickerResult.value)"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "batch queue",
        path: batchDownloadPath,
        callScopeStart: "let batchJobResult = await DebridCoordinator.shared",
        callScopeEnd: "private func sameSource(",
        versionedCall: ".resolvedPlaybackURLVersioned(for: best, episode: ep)",
        plainCall: ".resolvedPlaybackURL(for: best, episode: ep)",
        bindings: [PublicationBinding(
            scopeStart: "let batchJobResult = await DebridCoordinator.shared",
            scopeEnd: "private func sameSource(",
            revisionNeedle: "revision: batchJobResult.revision",
            mutationNeedle: "outcome = queueResolved(batchJobResult.value)"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "batch retry",
        path: batchDownloadPath,
        callScopeStart: "let batchRetryResult = await DebridCoordinator.shared.resolvedPlaybackURLVersioned(",
        callScopeEnd: "private func queueRetrySwap(",
        versionedCall: "resolvedPlaybackURLVersioned(",
        plainCall: "resolvedPlaybackURL(",
        bindings: [PublicationBinding(
            scopeStart: "let batchRetryResult = await DebridCoordinator.shared.resolvedPlaybackURLVersioned(",
            scopeEnd: "private func queueRetrySwap(",
            revisionNeedle: "revision: batchRetryResult.revision",
            mutationNeedle: "queueRetrySwap(resolved: batchRetryResult.value"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS episode request",
        path: iosDetailPath,
        callScopeStart: "let episodeRequestResult: DebridVersionedResult<DebridPlaybackRef?>?",
        callScopeEnd: "let ref = episodeRequestResult?.value",
        versionedCall: "resolvedPlaybackRefVersioned(",
        plainCall: "resolvedPlaybackRef(",
        bindings: [PublicationBinding(
            scopeStart: "guard let episodeRequestResult else { return makeStream() }",
            scopeEnd: "/// A left-to-right layout",
            revisionNeedle: "revision: episodeRequestResult.revision",
            mutationNeedle: "output = makeStream()"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS movie resume",
        path: iosDetailPath,
        callScopeStart: "let movieResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
        callScopeEnd: "// CACHED DEBRID:",
        versionedCall: "CWResume.resolvedURLVersioned(for: entry)",
        plainCall: "CWResume.resolvedURL(for: entry)",
        bindings: [PublicationBinding(
            scopeStart: "let movieResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
            scopeEnd: "// CACHED DEBRID:",
            revisionNeedle: "revision: movieResumeResult.revision",
            mutationNeedle: "core.loadEnginePlayer(for: stream)"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS movie cached race",
        path: iosDetailPath,
        callScopeStart: "let movieRaceResult = await DebridCoordinator.shared.resolveFirstPlayableVersioned(",
        callScopeEnd: "// INSTANT FIRST-PLAY:",
        versionedCall: "resolveFirstPlayableVersioned(",
        plainCall: "resolveFirstPlayable(",
        bindings: [PublicationBinding(
            scopeStart: "let movieRaceResult = await DebridCoordinator.shared.resolveFirstPlayableVersioned(",
            scopeEnd: "// INSTANT FIRST-PLAY:",
            revisionNeedle: "revision: movieRaceResult.revision",
            mutationNeedle: "core.loadEnginePlayer(for: win.stream)"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS movie fallback",
        path: iosDetailPath,
        callScopeStart: "let moviePlaybackResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
        callScopeEnd: "/// #95: play a source-list TRAILER row",
        versionedCall: "resolvedPlaybackRefVersioned(",
        plainCall: "resolvedPlaybackRef(",
        bindings: [PublicationBinding(
            scopeStart: "let moviePlaybackResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
            scopeEnd: "/// #95: play a source-list TRAILER row",
            revisionNeedle: "revision: moviePlaybackResult.revision",
            mutationNeedle: "presentation = .player(PlayerLaunch("
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS movie manual playback",
        path: iosDetailPath,
        callScopeStart: "let manualMovieResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
        callScopeEnd: "#if !os(tvOS)",
        versionedCall: "resolvedPlaybackRefVersioned(",
        plainCall: "resolvedPlaybackRef(",
        bindings: [PublicationBinding(
            scopeStart: "let manualMovieResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
            scopeEnd: "#if !os(tvOS)",
            revisionNeedle: "revision: manualMovieResult.revision",
            mutationNeedle: "presentation = .player(PlayerLaunch("
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS movie download",
        path: iosDetailPath,
        callScopeStart: "let movieDownloadResult = await DebridCoordinator.shared.resolvedPlaybackURLVersioned(for: stream)",
        callScopeEnd: "/// Present the pre-download quality picker",
        versionedCall: "resolvedPlaybackURLVersioned(for: stream)",
        plainCall: "resolvedPlaybackURL(for: stream)",
        bindings: [PublicationBinding(
            scopeStart: "let movieDownloadResult = await DebridCoordinator.shared.resolvedPlaybackURLVersioned(for: stream)",
            scopeEnd: "/// Present the pre-download quality picker",
            revisionNeedle: "revision: movieDownloadResult.revision",
            mutationNeedle: "DownloadManager.shared.download("
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS episode cached race",
        path: iosDetailPath,
        callScopeStart: "let episodeRaceResult = await DebridCoordinator.shared.resolveFirstPlayableVersioned(",
        callScopeEnd: "preparing = false   // release before the fallback",
        versionedCall: "resolveFirstPlayableVersioned(",
        plainCall: "resolveFirstPlayable(",
        bindings: [PublicationBinding(
            scopeStart: "let episodeRaceResult = await DebridCoordinator.shared.resolveFirstPlayableVersioned(",
            scopeEnd: "preparing = false   // release before the fallback",
            revisionNeedle: "revision: episodeRaceResult.revision",
            mutationNeedle: "lastBinge = win.stream.behaviorHints?.bingeGroup"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS episode playback helper",
        path: iosDetailPath,
        callScopeStart: "let episodePlaybackResult = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(",
        callScopeEnd: "private func resume(",
        versionedCall: "resolvedPlaybackRefVersioned(",
        plainCall: "resolvedPlaybackRef(",
        bindings: [
            PublicationBinding(
                scopeStart: "let episodePlayResult = await playbackRef(for: stream, episode: ep)",
                scopeEnd: "private func playBest(",
                revisionNeedle: "revision: episodePlayResult.revision",
                mutationNeedle: "publishEpisodePlayback()"
            ),
            PublicationBinding(
                scopeStart: "let episodeDownloadResult = await playbackRef(",
                scopeEnd: "#else",
                revisionNeedle: "revision: episodeDownloadResult.revision",
                mutationNeedle: "publishEpisodeDownload()"
            ),
        ],
        transportNeedles: [
            "return episodePlaybackResult.map { ref in",
            "let episodePlayResult = await playbackRef(for: stream, episode: ep)",
            "let episodeDownloadResult = await playbackRef(",
        ]
    ),
    PublicationSite(
        label: "iOS next episode",
        path: iosDetailPath,
        callScopeStart: "let nextEpisodeResult: DebridVersionedResult<DebridPlaybackRef?>?",
        callScopeEnd: "let ref = nextEpisodeResult?.value",
        versionedCall: "resolvedPlaybackRefVersioned(for: best, episode: episodeHint)",
        plainCall: "resolvedPlaybackRef(for: best, episode: episodeHint)",
        bindings: [PublicationBinding(
            scopeStart: "guard let nextEpisodeResult else { return makeStream() }",
            scopeEnd: "/// F6 preload:",
            revisionNeedle: "revision: nextEpisodeResult.revision",
            mutationNeedle: "output = makeStream()"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS preload",
        path: iosDetailPath,
        callScopeStart: "let preloadResult: DebridVersionedResult<DebridPlaybackRef?>?",
        callScopeEnd: "let ref = preloadResult?.value",
        versionedCall: "resolvedPlaybackRefVersioned(for: best, episode: hint)",
        plainCall: "resolvedPlaybackRef(for: best, episode: hint)",
        bindings: [PublicationBinding(
            scopeStart: "await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in",
            scopeEnd: "// MARK: - iOS / macOS presentation helpers",
            revisionNeedle: "revision: preloadResult.revision",
            mutationNeedle: "task.resume()"
        )],
        transportNeedles: []
    ),
    PublicationSite(
        label: "iOS root resume",
        path: iosRootPath,
        callScopeStart: "let rootResumeResult = await CWResume.resolvedURLVersioned(for: entry)",
        callScopeEnd: "let (resolvedURL, refreshed) = rootResumeResult.value",
        versionedCall: "CWResume.resolvedURLVersioned(for: entry)",
        plainCall: "CWResume.resolvedURL(for: entry)",
        bindings: [
            PublicationBinding(
                scopeStart: "let resume: Double",
                scopeEnd: "// For a series, give the player",
                revisionNeedle: "revision: rootResumeResult.revision",
                mutationNeedle: "core.loadMeta("
            ),
            PublicationBinding(
                scopeStart: "var launch: iOSPlayerLaunch?",
                scopeEnd: "return launch",
                revisionNeedle: "revision: rootResumeResult.revision",
                mutationNeedle: "launch = iOSPlayerLaunch("
            ),
        ],
        transportNeedles: []
    ),
]

private let monotonicRule = "snapshot publication is monotonic and cold bootstrap is synchronous"
private let ownerRule = "canonical owners and envelope accounts stay disjoint"
private let envelopeRule = "one complete envelope is exact-read before its commit marker"
private let durableMutationRule = "durable mutation commits before replacing mutable state"
private let keysCommitRule = "DebridKeys publishes and syncs only a committed candidate"
private let remoteRule = "remote sync applies one durable envelope with no echo"
private let migrationRule = "global migration is durably claimed and delete-source-first"
private let keychainRule = "Keychain replacement rejects deletion failure and exact-readbacks"
private let coordinatorRule = "coordinator accepts only typed newer snapshots"
private let sendRule = "every authenticated provider request validates at the actual send"
private let resultRule = "coordinator result escape retains pre and post await fences"
private let callerRule = "in-lease cache publication uses the atomic caller mutation seam"
private let apiRule = "every credential-derived coordinator API exposes its exact revision"
private let detachedRule = "detached configured-service reads use the immutable store"
private let authRule = "restore and adopt validate canonical owners before mutation"
private let torBoxSearchRule = "TorBox search carries one revision through both sends and every mutation"
private let syncPayloadRule = "sync payload revision is fenced at actual task resume"
private let nonPlayerPublicationRule = "non-player callers publish versioned results only through the atomic seam"
private let libraryLivenessRule = "cloud library load state is revision and attempt fenced"
private let libraryRecoveryOwnershipRule =
    "cloud library recovery preserves newer same-revision attempt ownership"

private let rules: [Rule] = [
    Rule(name: monotonicRule, files: [statePath], violations: { files in
        guard let file = files[statePath] else { return ["missing credential state"] }
        return require(
            file,
            "initial: DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: Keychain.string)",
            "synchronous signed-out durable bootstrap"
        ) + require(
            file,
            "guard snapshot.revision > value.revision else {",
            "strictly newer snapshot publication"
        )
    }),
    Rule(name: ownerRule, files: [statePath], violations: { files in
        guard let file = files[statePath] else { return ["missing credential state"] }
        return require(
            file,
            "guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }",
            "exact lowercase UUID round-trip"
        ) + require(file, "case .signedOutDevice: return \"device.local\"", "device namespace")
            + require(
                file,
                "case .account(let uuid): return \"account.\" + uuid.uuidString.lowercased()",
                "account namespace"
            ) + require(file, "let base = \"vortx.debrid.v3.envelope.\" + owner.storageNamespace",
                        "owner-scoped envelope namespace")
    }),
    Rule(name: envelopeRule, files: [statePath], violations: { files in
        guard let file = files[statePath],
              let commit = section(file, start: "static func commit(owner:",
                                   end: "static func encodeCanonical") else {
            return ["missing credential envelope commit"]
        }
        return require(file, "let currentSelection = loadResult.selection",
                       "one load retains the winning slot and envelope")
            + require(file, "guard !normalized.isEmpty else { return .failed(.quarantinedCurrent) }",
                      "quarantine recovery requires positive authoritative credential evidence")
            + require(file, "let nextSlot = currentSelection?.slot.other ?? .a",
                      "inactive-slot selection from the retained winner")
            + forbid(commit, "candidate(owner: owner, slot:",
                     "commit re-reads slots to rediscover the active selection")
            + require(file, "guard winners.count == 1 else {",
                      "ambiguous-generation quarantine")
            + requireOrdered(commit, [
                "guard io.write(envelopeString, envelopeAccount)",
                "guard io.read(envelopeAccount) == envelopeString",
                "guard io.write(markerString, markerAccount)",
                "guard io.read(markerAccount) == markerString",
                "guard case .committed(let verified) = load(owner: owner, read: io.read)",
                "verified.envelope == next, verified.slot == nextSlot",
            ], "envelope payload/readback/marker/readback/final-validation order")
            + requireOrdered(file, [
                "let recoveryGuardReadOne = read(accounts.recoveryGuard)",
                "let recoveryGuardReadTwo = read(accounts.recoveryGuard)",
                "let recoveryGuardPresent = recoveryGuardReadOne != nil || recoveryGuardReadTwo != nil",
                "if recoveryGuardPresent {",
                "return .quarantined(DebridCredentialQuarantine(",
            ], "two independent reads keep a leftover recovery guard fail-closed")
            + require(file, "observations.contains(where:",
                      "staged pair structurally quarantines even when guard reads miss")
            + require(file, "marker.recoveryPhase == nil", "normal candidate rejects staging marker")
            + require(file, "envelope.recoveryPhase == nil", "normal candidate rejects staging envelope")
            + requireOrdered(file, [
                "io.write(guardRaw, accounts.recoveryGuard)",
                "io.read(accounts.recoveryGuard) == guardRaw",
                "io.delete(targetMarker)",
                "io.write(stagedEnvelopeRaw, targetEnvelope)",
                "io.read(targetEnvelope) == stagedEnvelopeRaw",
                "io.write(stagedMarkerRaw, targetMarker)",
                "io.read(targetMarker) == stagedMarkerRaw",
                "for slot in DebridCredentialEnvelopeSlot.allCases where slot != target",
                "io.write(envelopeRaw, targetEnvelope)",
                "io.delete(accounts.recoveryGuard)",
                "io.read(accounts.recoveryGuard) == nil",
                "io.write(markerRaw, targetMarker)",
                "io.read(targetMarker) == markerRaw",
                "case .committed(let verified) = load(owner: owner, read: io.read)",
                "verified.slot == target, verified.envelope == fresh",
            ], "guarded quarantine recovery proves fresh data before exact stale cleanup")
    }),
    Rule(name: durableMutationRule, files: [statePath], violations: { files in
        guard let file = files[statePath],
              let local = section(file, start: "static func setKey(", end: "static func applyRemoteKeys("),
              let remote = section(file, start: "static func applyRemoteKeys(",
                                   end: "struct DebridCredentialMigrationClaim") else {
            return ["missing durable mutation helpers"]
        }
        let order = [
            "var candidate = state",
            "guard let snapshot = candidate.",
            "guard persist(snapshot.keys) else { return .persistenceFailed }",
            "state = candidate",
            "return .committed(snapshot)",
        ]
        return requireOrdered(local, order, "local candidate durability order")
            + requireOrdered(remote, order, "remote candidate durability order")
    }),
    Rule(name: keysCommitRule, files: [keysPath], violations: { files in
        guard let file = files[keysPath],
              let local = section(file, start: "func setKey(", end: "func applyRemoteKeys("),
              let remote = section(file, start: "func applyRemoteKeys(", end: "private func publish") else {
            return ["missing DebridKeys mutation functions"]
        }
        return require(local, "DebridCredentialDurableMutation.setKey", "durable local helper")
            + require(local, "case .persistenceFailed:", "local persistence failure branch")
            + requireCount(local, "publish(", 1, "local publication count changed")
            + requireCount(local, "requestSyncSoon()", 1, "local sync scheduling count changed")
            + require(remote, "DebridCredentialDurableMutation.applyRemoteKeys", "durable remote helper")
            + require(remote, "case .persistenceFailed:", "remote persistence failure branch")
            + requireCount(remote, "publish(snapshot)", 1, "remote publication count changed")
            + requireCount(remote, "requestSyncSoon()", 0, "remote apply must not schedule sync")
    }),
    Rule(name: remoteRule, files: [keysPath, syncPath], violations: { files in
        guard let keys = files[keysPath], let sync = files[syncPath],
              let remote = section(keys, start: "func applyRemoteKeys(", end: "private func publish"),
              let syncDown = section(sync, start: "func syncDown(",
                                     end: "func hydrateEngineFromOwnedAddons()") else {
            return ["missing remote apply production files"]
        }
        return require(sync, "debrid.applyRemoteKeys(remoteDebrid)", "one remote envelope apply")
            + forbid(sync, "debrid.setKey(", "remote sync fans out through per-service setKey")
            + forbid(sync, "reload(keys:", "remote sync retains raw resolver reload")
            + require(remote, "DebridCredentialPersistence.commit(owner: currentOwner, keys: keys, io: io).succeeded",
                      "whole-owner envelope commit")
            + forbid(remote, "Keychain.set", "remote apply performs independent service writes")
            + requireOrdered(syncDown, [
                "var debridGenerationApplied = true",
                "guard debrid.applyRemoteKeys(remoteDebrid) else {",
                "debridGenerationApplied = false",
                "guard debridGenerationApplied else { return false }",
            ], "failed debrid envelope prevents remote version/application acknowledgment")
    }),
    Rule(name: migrationRule, files: [statePath, keysPath], violations: { files in
        guard let state = files[statePath], let keys = files[keysPath],
              let migration = section(state, start: "static func migrate(",
                                      end: "return .migrated") else {
            return ["missing migration implementation"]
        }
        return require(state, "vortx.debrid.v3.migration.global.", "durable global claim account")
            + require(migration, "guard read(claimAccount) == encoded else { return .claimReadbackMismatch }",
                      "claim exact readback")
            + requireOrdered(migration, [
                "guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }",
                "next[service] = source",
                "guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }",
                "guard targetKeys()[service] == source else { return .targetReadbackMismatch }",
            ], "delete-source-first target commit")
            + require(keys, "claimAccount: DebridCredentialMigration.globalClaimAccount(for: service)",
                      "global migration claim wiring")
            + forbid(keys, "hasConsideredGlobalLegacy", "process-local global migration ownership remains")
            + forbid(migration, "delete(claimAccount)", "durable owner claim is deleted")
    }),
    Rule(name: keychainRule, files: [keychainPath], violations: { files in
        guard let file = files[keychainPath] else { return ["missing Keychain"] }
        return require(file, "let deleteStatus = SecItemDelete(base as CFDictionary)",
                       "captured Keychain deletion result")
            + require(file, "guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {",
                      "failed replacement rejection")
            + require(file, "guard save(store) else { return false }", "macOS persistence failure rejection")
            + require(file, "return load()[account] == value", "macOS exact readback")
            + require(file, "return string(account) == value", "iOS and tvOS exact readback")
    }),
    Rule(name: coordinatorRule, files: [resolverPath], violations: { files in
        guard let file = files[resolverPath] else { return ["missing resolver"] }
        return require(file, "func reload(snapshot: DebridCredentialSnapshot)", "typed reload API")
            + require(file, "guard revisionFence.accept(snapshot) else { return false }",
                      "equal and older snapshot rejection")
            + require(file, "ensureCurrentSnapshot()", "operation-time snapshot catch-up")
            + forbid(file, "reload(keys:", "raw resolver reload remains")
            + forbid(file, "didWarm", "lazy warm retains a second authority flag")
    }),
    Rule(name: sendRule, files: [statePath, resolverPath], violations: { files in
        guard let state = files[statePath], let file = files[resolverPath],
              let issuance = section(state, start: "func authorizeAndIssue(revision:",
                                     end: "func compareAndPublish("),
              let helper = section(file, start: "enum DebridAuthenticatedHTTP",
                                   end: "enum DebridHTTP") else {
            return ["missing authenticated HTTP boundary"]
        }
        return requireOrdered(issuance, [
            "lock.lock()",
            "guard value.revision == revision else { return false }",
            "issue()",
        ], "snapshot lock held through request issuance")
            + requireOrdered(helper, [
                "let task = session.dataTask(with: request)",
                "guard taskBox.install(task) else",
                "guard credentialToken.authorizeAndIssue({ task.resume() }) else",
            ], "suspended task creation and lock-held resume")
            + requireCount(file, "session.data(for:", 0,
                           "async URLSession send bypasses the lock-held issuance seam")
            + requireCount(helper, "session.dataTask(with: request)", 1,
                           "authenticated helper must create exactly one suspended task")
            + requireCount(helper, "task.resume()", 1,
                           "authenticated helper must resume only inside authorization")
            + requireCount(file, "private let credentialToken: DebridCredentialRevisionToken", 5,
                           "every credential-bearing provider must retain one revision token")
            + requireCount(file, "init(apiKey: String, credentialToken: DebridCredentialRevisionToken)", 5,
                           "every credential-bearing provider initializer must require the token")
            + require(file, "DebridHTTP.decode(session, req, credentialToken: credentialToken)",
                      "shared decode path token propagation")
    }),
    Rule(name: resultRule, files: [resolverPath], violations: { files in
        guard let file = files[resolverPath],
              let wrapper = section(file, start: "private func withCurrentCredential",
                                    end: "var hasUsenetResolver: Bool") else {
            return ["missing result escape wrapper"]
        }
        return requireOrdered(wrapper, [
            "token: DebridCredentialRevisionToken",
            "guard token.isCurrent() else { throw DebridError.credentialsChanged }",
            "let result = try await operation()",
            "guard token.resultIsCurrent() else { throw DebridError.credentialsChanged }",
            "return result",
        ], "coordinator pre and post await result fencing")
    }),
    Rule(name: callerRule, files: [statePath, resolverPath], violations: { files in
        guard let state = files[statePath], let resolver = files[resolverPath],
              let seam = section(state, start: "func compareAndPublish(", end: "func isConfigured("),
              let cache = section(resolver, start: "final class DebridCacheAwareness",
                                  end: "extension TorBoxResolver") else {
            return ["missing in-lease caller publication seam"]
        }
        return require(state,
                       "@MainActor\n    @discardableResult\n    func publish(_ snapshot:",
                       "MainActor-isolated credential publication")
            + require(state,
                      "@MainActor\n    @discardableResult\n    func compareAndPublish(",
                      "MainActor-isolated caller mutation")
            + requireOrdered(seam, [
            "lock.lock()",
            "let matches = value.revision == revision",
            "lock.unlock()",
            "guard matches else { return false }",
            "mutation()",
        ], "unlock-before-callback MainActor comparison and synchronous mutation")
            + require(state,
                      "NotificationCenter.default.post(name: Self.didPublishNotification, object: self)",
                      "post-lock credential revision invalidation signal")
            + requireCount(cache, "compareAndPublish(revision:", 5,
                           "revision adoption plus torrent/usenet pre-send and completion mutations")
            + require(cache, "cacheCheckVersioned", "versioned torrent cache result")
            + require(cache, "usenetCacheCheckVersioned", "versioned usenet cache result")
            + require(cache, "DebridCredentialSnapshotStore.didPublishNotification",
                      "long-lived cache invalidation subscription")
            + requireOrdered(cache, [
                "queue: nil",
                "MainActor.assumeIsolated { self?.adoptCurrentCredentialRevision() }",
            ], "cache invalidation completes synchronously inside publication")
            + forbid(cache, "Task { @MainActor [weak self] in self?.adoptCurrentCredentialRevision() }",
                     "cache invalidation remains deferred behind an unstructured task")
            + require(cache, "pinning: snapshot.revision",
                      "torrent cache child call retains its A-derived input revision")
            + require(cache, "pinning: revision",
                      "usenet cache child call retains its A-derived input revision")
            + requireOrdered(cache, [
                "guard self.credentialRevision != revision else { return }",
                "self.lastQueried.removeAll()",
                "self.lastUsenetQueried.removeAll()",
                "self.cachedHashes.removeAll()",
                "self.cachedUsenetURLs.removeAll()",
            ], "revision change clears both dedupe and visible cache state")
    }),
    Rule(name: apiRule, files: [statePath, resolverPath, coreModelsPath], violations: { files in
        guard let state = files[statePath], let resolver = files[resolverPath],
              let core = files[coreModelsPath] else {
            return ["missing versioned coordinator API files"]
        }
        let coordinatorAPIs = [
            "func cacheCheckVersioned(",
            "func resolveVersioned(",
            "func resolveWithIdsVersioned(",
            "func reresolveVersioned(",
            "func resolveUsenetVersioned(",
            "func usenetCacheCheckVersioned(",
            "func resolvedPlaybackURLVersioned(",
            "func resolvedPlaybackRefVersioned(",
            "func resolveFirstPlayableVersioned(",
            "func cloudLibraryVersioned(",
            "func resolveLibraryItemVersioned(",
        ]
        var violations = coordinatorAPIs.flatMap {
            require(resolver, $0, "version-carrying coordinator result API")
        }
        violations += require(
            core,
            "static func resolvedURLVersioned(",
            "version-carrying continue-watching result API"
        )
        violations += require(
            core,
            "coordinator.reresolveVersioned(",
            "continue-watching revision propagation"
        )
        violations += require(core, "resolverGeneration(pinning: entryRevision)",
                              "continue-watching pins the entry resolver generation")
        violations += require(core, "generation: generation",
                              "continue-watching spends only its pinned resolver generation")
        violations += require(resolver, "struct DebridResolverGeneration: Sendable",
                              "immutable resolver generation value")
        violations += require(resolver, "func resolverGeneration(pinning revision: UInt64)",
                              "outer-operation revision pin API")
        violations += require(state, "struct DebridCredentialPinnedChildEntry: Sendable",
                              "production-used pinned child-entry seam")
        violations += require(state, "func enter() -> DebridVersionedResult<DebridCredentialRevisionToken?>",
                              "child-entry returns the exact A revision token")
        violations += require(state, "value: token.isCurrent() ? token : nil",
                              "child-entry rejects a stale revision before its child can run")
        violations += requireCount(resolver, ").enter()", 5,
                                   "all nested child implementations consume the shared entry seam")
        violations += requireCount(resolver, "withCurrentCredential(token: credentialToken)", 5,
                                   "all nested child implementations consume the seam's returned token")
        violations += requireCount(resolver, "generation: generation", 6,
                                   "torrent, usenet, singleton race, fanout race, and pinned cache propagation")
        violations += require(
            resolver,
            "DebridCoordinator.shared.resolveUsenetVersioned(",
            "usenet high-level revision propagation"
        )
        violations += require(
            resolver,
            "DebridCoordinator.shared.resolveWithIdsVersioned(",
            "torrent high-level revision propagation"
        )
        return violations
    }),
    Rule(name: libraryLivenessRule, files: [debridLibraryPath], violations: { files in
        guard let file = files[debridLibraryPath] else {
            return ["missing DebridLibrary model"]
        }
        let model = file
        var violations: [String] = []
        violations += require(file, ".task(id: debrid.revision) {", "revision-keyed view task")
        violations += requireCount(
            file, "let snapshot = debrid.snapshot", 3,
            "task, pull-to-refresh, and refresh button must each capture one coherent snapshot"
        )
        violations += requireCount(
            file, "await model.loadIfNeeded(snapshot: snapshot)", 1,
            "initial task must pass its captured snapshot"
        )
        violations += requireCount(
            file, "await model.reload(snapshot: snapshot)", 2,
            "both manual refresh paths must pass their captured snapshot"
        )
        violations += forbid(model, "private var didLoad", "one-shot Boolean load state remains")
        violations += require(model, "private(set) var loadedRevision: UInt64?", "loaded revision state")
        violations += requireOrdered(model, [
            "private(set) var nextAttemptID: UInt64 = 0",
            "private(set) var activeAttemptID: UInt64?",
            "precondition(nextAttemptID < UInt64.max",
            "nextAttemptID += 1",
            "let attemptID = nextAttemptID",
        ], "strictly monotonic load-attempt token")
        violations += requireCount(
            model, "self.credentialStore.load() == snapshot", 3,
            "attempt activation, guarded mutation, and success publication need the exact current snapshot"
        )
        violations += require(
            model,
            "guard result.revision == snapshot.revision else {",
            "returned library revision must equal the captured snapshot"
        )
        violations += require(
            model,
            "guard self.activeAttemptID == attemptID,\n                      self.credentialStore.load() == snapshot,\n                      !Task.isCancelled else { return }",
            "success publication must retain exact active-attempt ownership"
        )
        violations += require(
            model,
            "guard mutateIfActive(attemptID: attemptID, snapshot: snapshot, mutation: {\n            phase = .loading\n        }) else { return }",
            "loading state mutation through the active-attempt seam"
        )
        violations += requireOrdered(model, [
            "guard !Task.isCancelled else {",
            "recoverAfterInterruptedAttempt(attemptID: attemptID, snapshot: snapshot)",
            "guard result.revision == snapshot.revision else {",
            "recoverAfterInterruptedAttempt(attemptID: attemptID, snapshot: snapshot)",
        ], "cancellation and mismatched-result recovery")
        violations += requireOrdered(model, [
            "private func recoverAfterInterruptedAttempt(",
            "mutateIfActive(attemptID: attemptID, snapshot: snapshot, mutation: {",
            "activeAttemptID = nil",
            "phase = loadedRevision == snapshot.revision ? .loaded : .idle",
        ], "interrupted initial and manual refresh recovery")
        violations += require(
            model,
            "credentialStore: DebridCredentialSnapshotStore = .shared",
            "production model defaults to the shared credential store"
        )
        violations += require(
            model,
            "await DebridCoordinator.shared.cloudLibraryVersioned()",
            "production model defaults to the versioned shared library loader"
        )
        violations += require(
            model,
            "await loadState.reload(snapshot: snapshot)",
            "production model delegates refresh to the production-tested state machine"
        )
        return violations
    }),
    Rule(name: libraryRecoveryOwnershipRule, files: [debridLibraryPath], violations: { files in
        guard let file = files[debridLibraryPath] else {
            return ["missing DebridLibrary model"]
        }
        guard let mutationSeam = section(
            file,
            start: "private func mutateIfActive(",
            end: "private func recoverAfterInterruptedAttempt("
        ) else {
            return ["DebridLibrary mutateIfActive seam is missing"]
        }
        return require(
            mutationSeam,
            "guard self.activeAttemptID == attemptID,\n                      self.credentialStore.load() == snapshot else { return }",
            "recovery mutation must retain exact active-attempt ownership"
        )
    }),
    Rule(
        name: nonPlayerPublicationRule,
        files: [
            tvDetailPath, tvHomePath, tvEpisodePath, debridLibraryPath, downloadPickerPath,
            batchDownloadPath, iosDetailPath, iosRootPath, playerScreenPath, tvPlayerPath,
        ],
        violations: { files in
            let expectedVersionedCalls: [String: [(String, Int)]] = [
                tvDetailPath: [
                    ("CWResume.resolvedURLVersioned(", 1),
                    (".resolveFirstPlayableVersioned(", 1),
                    (".resolvedPlaybackRefVersioned(", 1),
                    (".resolvedPlaybackURLVersioned(", 1),
                ],
                tvHomePath: [("CWResume.resolvedURLVersioned(", 1)],
                tvEpisodePath: [(".resolvedPlaybackRefVersioned(", 1)],
                debridLibraryPath: [(".cloudLibraryVersioned(", 1)],
                downloadPickerPath: [(".resolvedPlaybackURLVersioned(", 1)],
                batchDownloadPath: [(".resolvedPlaybackURLVersioned(", 2)],
                iosDetailPath: [
                    ("CWResume.resolvedURLVersioned(", 1),
                    (".resolveFirstPlayableVersioned(", 2),
                    (".resolvedPlaybackRefVersioned(", 6),
                    (".resolvedPlaybackURLVersioned(", 1),
                ],
                iosRootPath: [("CWResume.resolvedURLVersioned(", 1)],
            ]
            let forbiddenPlainCalls = [
                "CWResume.resolvedURL(",
                ".resolveFirstPlayable(",
                ".resolvedPlaybackRef(",
                ".resolvedPlaybackURL(",
                ".cloudLibrary(",
            ]
            var violations: [String] = []
            if publicationSites.count != 21 || Set(publicationSites.map(\.label)).count != 21 {
                violations.append("the non-player inventory must contain 21 distinct labeled sites")
            }
            for site in publicationSites {
                violations += publicationSiteViolations(site, files: files)
            }
            for (path, expectedCalls) in expectedVersionedCalls {
                guard let file = files[path] else {
                    violations.append("missing non-player caller \(path)")
                    continue
                }
                for (needle, expected) in expectedCalls {
                    violations += requireCount(
                        file, needle, expected,
                        "versioned caller count changed for \(needle)"
                    )
                }
                for needle in forbiddenPlainCalls {
                    violations += forbid(file, needle, "plain credential-derived result escaped")
                }
                violations += forbid(
                    file,
                    "DebridCredentialSnapshotStore.shared.isCurrent(revision:",
                    "caller split its check from the later publication"
                )
            }
            if let library = files[debridLibraryPath] {
                violations += requireCount(
                    library,
                    ".resolveLibraryItem(",
                    1,
                    "the provenance-blocked library-item resolve must remain explicitly parked"
                )
                violations += requireCount(
                    library,
                    ".resolveLibraryItemVersioned(",
                    0,
                    "library-item resolution cannot claim a current revision without item provenance"
                )
            }
            if let player = files[playerScreenPath] {
                violations += requireCount(
                    player, ".reresolve(", 1,
                    "the deferred PlayerScreen caller inventory changed"
                )
                violations += requireCount(
                    player, "Versioned(", 0,
                    "PlayerScreen was changed in the non-player lane"
                )
            }
            if let player = files[tvPlayerPath] {
                violations += requireCount(
                    player, ".reresolve(", 1,
                    "the deferred TVPlayer reresolve inventory changed"
                )
                violations += requireCount(
                    player, ".cacheCheck(", 1,
                    "the deferred TVPlayer cache inventory changed"
                )
                violations += requireCount(
                    player, ".resolvedPlaybackRef(", 3,
                    "the deferred TVPlayer playback inventory changed"
                )
                violations += requireCount(
                    player, "Versioned(", 0,
                    "TVPlayer was changed in the non-player lane"
                )
            }
            return violations
        }
    ),
    Rule(name: detachedRule, files: [coreModelsPath], violations: { files in
        guard let file = files[coreModelsPath] else { return ["missing CoreModels"] }
        return require(file, "DebridCredentialSnapshotStore.shared.isConfigured(.torBox)",
                       "immutable configured-service query")
            + forbid(file, "DebridKeys.shared.isConfigured(.torBox)",
                     "detached code reads the main-actor mutable owner")
    }),
    Rule(name: authRule, files: [syncPath], violations: { files in
        guard let file = files[syncPath] else { return ["missing sync manager"] }
        guard let restore = section(file, start: "private func restore()", end: "func signOut()"),
              let adopt = section(file, start: "private func adopt(", end: "enum AuthResult") else {
            return ["missing restore or adopt function"]
        }
        return requireOrdered(restore, [
            "DebridOwnerScope.canonicalAccount(p.account.id)",
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
        ], "restore owner validation before mutation")
            + requireOrdered(adopt, [
                "DebridOwnerScope.canonicalAccount(accountID)",
                "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            ], "adopt owner validation before mutation")
            + forbid(file, "DebridKeys.shared.bind(owner: p.account.id)", "raw restore owner bind remains")
    }),
    Rule(name: torBoxSearchRule, files: [torBoxSearchPath], violations: { files in
        guard let file = files[torBoxSearchPath],
              let search = section(file, start: "static func streams(",
                                   end: "private static func fetch("),
              let fetch = section(file, start: "private static func fetch(",
                                  end: "private static func stream("),
              let source = section(file, start: "final class TorBoxSearchSource",
                                   end: "nonisolated static func merge(") else {
            return ["missing TorBox search sections"]
        }
        return require(search, "snapshot: DebridCredentialSnapshot", "captured complete credential snapshot")
            + require(search, "async -> DebridVersionedResult<SearchResult>", "versioned combined result")
            + require(search, "revision: snapshot.revision, store: credentialStore", "revision token construction")
            + requireCount(search, "credentialToken: credentialToken", 2,
                           "usenet and torrent legs must each receive the revision token")
            + require(fetch, "DebridAuthenticatedHTTP.data(", "lock-held actual task issuance")
            + forbid(fetch, "session.data(for:", "TorBox search bypasses guarded task resume")
            + forbid(file, "DebridKeys.shared", "TorBox search captures mutable MainActor credentials")
            + require(source, "private var credentialRevision: UInt64?", "revision-scoped contributor state")
            + require(source, "private var inFlightRevision: UInt64?", "revision-scoped in-flight state")
            + requireOrdered(source, [
                "init(credentialStore: DebridCredentialSnapshotStore = .shared)",
                "forName: DebridCredentialSnapshotStore.didPublishNotification",
                "object: credentialStore",
                "queue: nil",
                "MainActor.assumeIsolated { self?.adoptCurrentCredentialRevision() }",
            ], "live revision publication invalidates the injected store's contributor state")
            + forbid(source, "Task { @MainActor [weak self] in self?.adoptCurrentCredentialRevision() }",
                     "TorBox invalidation remains deferred behind an unstructured task")
            + require(source, "credentialStore: requestCredentialStore",
                      "injected credential store reaches both guarded search legs")
            + requireCount(source, "compareAndPublish(revision:", 4,
                           "pre-send, completion, revision adoption, and clear mutations must all use the seam")
            + requireOrdered(source, [
                "let snapshot = credentialStore.load()",
                "guard adoptCredentialRevision(snapshot.revision) else { return }",
                "guard let key = snapshot.keys[.torBox], !key.isEmpty else",
                "credentialStore.compareAndPublish(revision: snapshot.revision)",
            ], "snapshot adoption and pre-send mutation ordering")
            + requireOrdered(source, [
                "guard self.credentialRevision != revision else { return }",
                "self.inFlightKey = nil",
                "self.inFlightRevision = nil",
                "self.cache.removeAll()",
                "self.cooldownUntil = nil",
                "self.shownKey = nil",
                "self.publishedContentID = nil",
                "self.streams = []",
            ], "revision change retires every old contributor-state class")
    }),
    Rule(name: syncPayloadRule, files: [syncPath], violations: { files in
        guard let file = files[syncPath],
              let request = section(file, start: "private func request(",
                                    end: "private func adopt("),
              let push = section(file, start: "private func pushSyncDocAt(",
                                 end: "private func pushDerivedDoc("),
              let derivedPush = section(file, start: "private func pushDerivedDoc(",
                                        end: "private func vortxSummary("),
              let merge = section(file, start: "private func mergeLocalIntoDoc(",
                                  end: "static func currentAddonOrder()") else {
            return ["missing sync payload sections"]
        }
        return require(request, "debridCredentialToken: DebridCredentialRevisionToken? = nil",
                       "optional credential issuance token")
            + requireOrdered(request, [
                "if let debridCredentialToken",
                "DebridAuthenticatedHTTP.data(",
                "credentialToken: debridCredentialToken",
            ], "credential-bearing PUT uses the lock-held task-resume helper")
            + requireOrdered(push, [
                "debridRevision: UInt64",
                "guard DebridCredentialSnapshotStore.shared.isCurrent(revision: debridRevision) else",
                "JSONSerialization.data(withJSONObject: obj)",
                "DebridCredentialRevisionToken(",
                "revision: debridRevision, store: DebridCredentialSnapshotStore.shared",
                "debridCredentialToken: credentialToken",
            ], "derived payload is rejected before crypto and fenced again at actual request issuance")
            + forbid(file, "func pushSyncDoc(_ obj:",
                     "blind sync helper blesses a payload without derivation provenance")
            + require(derivedPush,
                      "doc.object, version: version, debridRevision: doc.debridRevision",
                      "optimistic retries retain each rebuilt payload's exact revision")
            + requireOrdered(merge, [
                "let debridSnapshot = DebridCredentialSnapshotStore.shared.load()",
                "debridSnapshot.keys[.realDebrid]",
                "debridSnapshot.keys[.allDebrid]",
                "debridSnapshot.keys[.premiumize]",
                "debridSnapshot.keys[.torBox]",
                "DerivedSyncDocument(object: doc, debridRevision: debridSnapshot.revision)",
            ], "one snapshot supplies all four encrypted payload keys and its revision")
            + forbid(merge, "DebridKeys.shared", "sync payload captures mutable keys outside its snapshot")
    }),
]

private let mutations: [Mutation] = [
    Mutation(name: "M01 allow equal snapshot publication", rule: monotonicRule, path: statePath,
             find: "guard snapshot.revision > value.revision else {",
             replacement: "guard snapshot.revision >= value.revision else {"),
    Mutation(name: "M02 restore empty cold bootstrap", rule: monotonicRule, path: statePath,
             find: "initial: DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: Keychain.string)",
             replacement: "initial: DebridCredentialSnapshot(owner: .signedOutDevice, revision: 1, keys: [:])"),
    Mutation(name: "M03 map account storage onto the device namespace", rule: ownerRule, path: statePath,
             find: "case .account(let uuid): return \"account.\" + uuid.uuidString.lowercased()",
             replacement: "case .account: return \"device.local\""),
    Mutation(name: "M04 accept noncanonical account spelling", rule: ownerRule, path: statePath,
             find: "guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }",
             replacement: "guard let uuid = UUID(uuidString: raw) else { return nil }"),
    Mutation(name: "M05 overwrite the active envelope slot", rule: envelopeRule, path: statePath,
             find: "let nextSlot = currentSelection?.slot.other ?? .a",
             replacement: "let nextSlot = currentSelection?.slot ?? .a"),
    Mutation(name: "M06 remove envelope exact readback", rule: envelopeRule, path: statePath,
             find: "guard io.read(envelopeAccount) == envelopeString else { return .failed(.envelopeReadbackMismatch) }",
             replacement: "_ = io.read(envelopeAccount)"),
    Mutation(name: "M07 remove commit marker exact readback", rule: envelopeRule, path: statePath,
             find: "guard io.read(markerAccount) == markerString else { return .failed(.markerReadbackMismatch) }",
             replacement: "_ = io.read(markerAccount)"),
    Mutation(name: "M08 publish local candidate before persistence", rule: durableMutationRule, path: statePath,
             find: "guard let snapshot = candidate.setKey(value, for: service) else { return .unchanged }\n        guard persist(snapshot.keys) else { return .persistenceFailed }\n        state = candidate",
             replacement: "guard let snapshot = candidate.setKey(value, for: service) else { return .unchanged }\n        state = candidate\n        guard persist(snapshot.keys) else { return .persistenceFailed }"),
    Mutation(name: "M09 publish remote candidate before persistence", rule: durableMutationRule, path: statePath,
             find: "guard let snapshot = candidate.applyRemoteKeys(remote) else { return .unchanged }\n        guard persist(snapshot.keys) else { return .persistenceFailed }\n        state = candidate",
             replacement: "guard let snapshot = candidate.applyRemoteKeys(remote) else { return .unchanged }\n        state = candidate\n        guard persist(snapshot.keys) else { return .persistenceFailed }"),
    Mutation(name: "M10 publish after failed local persistence", rule: keysCommitRule, path: keysPath,
             find: "case .persistenceFailed:\n            persistenceError = \"Could not save debrid credentials. Your previous saved keys are still active.\"\n            return false",
             replacement: "case .persistenceFailed:\n            publish(state.snapshot)\n            return false"),
    Mutation(name: "M11 let remote apply echo a sync", rule: keysCommitRule, path: keysPath,
             find: "case .committed(let snapshot):\n            persistenceError = nil\n            publish(snapshot)\n            return true\n        }\n    }\n\n    private func publish",
             replacement: "case .committed(let snapshot):\n            persistenceError = nil\n            publish(snapshot)\n            Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }\n            return true\n        }\n    }\n\n    private func publish"),
    Mutation(name: "M12 restore remote per-service setKey fanout", rule: remoteRule, path: syncPath,
             find: "debrid.applyRemoteKeys(remoteDebrid)",
             replacement: "for (service, value) in remoteDebrid { debrid.setKey(value, for: service) }"),
    Mutation(name: "M13 remove durable global claim wiring", rule: migrationRule, path: keysPath,
             find: "claimAccount: DebridCredentialMigration.globalClaimAccount(for: service)",
             replacement: "claimAccount: nil"),
    Mutation(name: "M14 write migration target before deleting source", rule: migrationRule, path: statePath,
             find: "guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }\n\n        var next = current\n        next[service] = source\n        guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }",
             replacement: "var next = current\n        next[service] = source\n        guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }\n        guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }"),
    Mutation(name: "M15 remove migration claim exact readback", rule: migrationRule, path: statePath,
             find: "guard read(claimAccount) == encoded else { return .claimReadbackMismatch }",
             replacement: "_ = read(claimAccount)"),
    Mutation(name: "M16 ignore Keychain deletion failure", rule: keychainRule, path: keychainPath,
             find: "guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {\n            return false\n        }",
             replacement: "_ = deleteStatus"),
    Mutation(name: "M17 report macOS persistence success without readback", rule: keychainRule, path: keychainPath,
             find: "guard save(store) else { return false }\n            return load()[account] == value",
             replacement: "_ = save(store)\n            return true"),
    Mutation(name: "M18 release publication lock before request issuance", rule: sendRule, path: statePath,
             find: "guard value.revision == revision else { return false }\n        issue()\n        return true\n    }\n\n    /// The required caller-publication seam",
             replacement: "guard value.revision == revision else { return false }\n        return true\n    }\n\n    /// The required caller-publication seam"),
    Mutation(name: "M19 restore a detached pre-send predicate", rule: sendRule, path: resolverPath,
             find: "guard credentialToken.authorizeAndIssue({ task.resume() }) else {\n                    task.cancel()",
             replacement: "guard credentialToken.revision > 0 else {\n                    task.cancel()\n                    resumeGate.run { continuation.resume(throwing: DebridError.credentialsChanged) }\n                    return\n                }\n                task.resume()\n                if false {\n                    task.cancel()"),
    Mutation(name: "M20 bypass guarded send for one provider", rule: sendRule, path: resolverPath,
             find: "static func decode<T: Decodable>(\n        _ session: URLSession,\n        _ req: URLRequest,\n        credentialToken: DebridCredentialRevisionToken\n    ) async throws -> T {\n        let (data, response) = try await DebridAuthenticatedHTTP.data(\n            session, for: req, credentialToken: credentialToken\n        )",
             replacement: "static func decode<T: Decodable>(\n        _ session: URLSession,\n        _ req: URLRequest,\n        credentialToken: DebridCredentialRevisionToken\n    ) async throws -> T {\n        let (data, response) = try await session.data(for: req)"),
    Mutation(name: "M21 remove one provider's durable revision token", rule: sendRule, path: resolverPath,
             find: "actor RealDebridResolver: DebridResolving {\n    nonisolated let service: DebridService = .realDebrid\n    private let apiKey: String\n    private let credentialToken: DebridCredentialRevisionToken",
             replacement: "actor RealDebridResolver: DebridResolving {\n    nonisolated let service: DebridService = .realDebrid\n    private let apiKey: String"),
    Mutation(name: "M22 remove coordinator post-await result fence", rule: resultRule, path: resolverPath,
             find: "guard token.resultIsCurrent() else { throw DebridError.credentialsChanged }",
             replacement: "_ = token"),
    Mutation(name: "M23 separate cache check from caller mutation", rule: callerRule, path: resolverPath,
             find: "_ = self.credentialStore.compareAndPublish(revision: result.revision) {",
             replacement: "if DebridCredentialSnapshotStore.shared.isCurrent(revision: result.revision) {"),
    Mutation(name: "M24 remove atomic caller revision comparison", rule: callerRule, path: statePath,
             find: "let matches = value.revision == revision\n        lock.unlock()\n        guard matches else { return false }\n        mutation()",
             replacement: "_ = revision\n        lock.unlock()\n        mutation()"),
    Mutation(name: "M25 allow equal coordinator reload", rule: coordinatorRule, path: resolverPath,
             find: "guard revisionFence.accept(snapshot) else { return false }",
             replacement: "_ = revisionFence.accept(snapshot)"),
    Mutation(name: "M26 restore detached mutable-owner read", rule: detachedRule, path: coreModelsPath,
             find: "DebridCredentialSnapshotStore.shared.isConfigured(.torBox)",
             replacement: "DebridKeys.shared.isConfigured(.torBox)"),
    Mutation(name: "M27 bind restore through a raw owner", rule: authRule, path: syncPath,
             find: "let dk = Data(base64Encoded: p.dataKey),\n              let debridOwner = DebridOwnerScope.canonicalAccount(p.account.id) else { return }",
             replacement: "let dk = Data(base64Encoded: p.dataKey) else { return }\n        let debridOwner = DebridOwnerScope.signedOutDevice"),
    Mutation(name: "M28 strip revision from library item resolution", rule: apiRule, path: resolverPath,
             find: "func resolveLibraryItemVersioned(_ item: DebridLibraryItem)",
             replacement: "func resolveLibraryItemUnchecked(_ item: DebridLibraryItem)"),
    Mutation(name: "M29 strip revision from continue-watching reresolve", rule: apiRule, path: coreModelsPath,
             find: "coordinator.reresolveVersioned(",
             replacement: "coordinator.reresolve("),
    Mutation(name: "M30 acknowledge sync after failed remote envelope", rule: remoteRule, path: syncPath,
             find: "guard debrid.applyRemoteKeys(remoteDebrid) else {\n                debridGenerationApplied = false\n                return\n            }",
             replacement: "_ = debrid.applyRemoteKeys(remoteDebrid)"),
    Mutation(name: "M31 hold snapshot lock across observable callback", rule: callerRule, path: statePath,
             find: "lock.lock()\n        let matches = value.revision == revision\n        lock.unlock()\n        guard matches else { return false }\n        mutation()",
             replacement: "lock.lock()\n        defer { lock.unlock() }\n        guard value.revision == revision else { return false }\n        mutation()"),
    Mutation(name: "M32 bypass guarded TorBox search send", rule: torBoxSearchRule, path: torBoxSearchPath,
             find: "DebridAuthenticatedHTTP.data(\n            session, for: req, credentialToken: credentialToken\n        )",
             replacement: "session.data(for: req)"),
    Mutation(name: "M33 drop TorBox torrent-leg revision token", rule: torBoxSearchRule, path: torBoxSearchPath,
             find: "async let torrents = fetch(\n            kind: \"torrents\", imdbId: imdbId, season: season, episode: episode,\n            apiKey: apiKey, credentialToken: credentialToken\n        )",
             replacement: "async let torrents = fetch(\n            kind: \"torrents\", imdbId: imdbId, season: season, episode: episode,\n            apiKey: apiKey\n        )"),
    Mutation(name: "M34 strip TorBox combined-result revision", rule: torBoxSearchRule, path: torBoxSearchPath,
             find: ") async -> DebridVersionedResult<SearchResult> {",
             replacement: ") async -> SearchResult {"),
    Mutation(name: "M35 publish TorBox completion without caller seam", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "_ = self.credentialStore.compareAndPublish(revision: result.revision) {",
             replacement: "if true {"),
    Mutation(name: "M36 retain TorBox cache across credential revision", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "self.cache.removeAll()",
             replacement: "_ = self.cache"),
    Mutation(name: "M37 recapture TorBox key from mutable owner", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "func refresh(imdbId: String?, season: Int? = nil, episode: Int? = nil) {\n        let snapshot = credentialStore.load()",
             replacement: "func refresh(imdbId: String?, season: Int? = nil, episode: Int? = nil) {\n        let snapshot = DebridKeys.shared.snapshot"),
    Mutation(name: "M38 split sync revision check from actual task resume", rule: syncPayloadRule,
             path: syncPath,
             find: "if let debridCredentialToken {\n                response = try await DebridAuthenticatedHTTP.data(\n                    URLSession.shared, for: req, credentialToken: debridCredentialToken\n                )",
             replacement: "if let debridCredentialToken {\n                guard DebridCredentialSnapshotStore.shared.isCurrent(revision: debridCredentialToken.revision) else { return (0, nil) }\n                response = try await URLSession.shared.data(for: req)"),
    Mutation(name: "M39 drop rebuilt sync payload revision", rule: syncPayloadRule, path: syncPath,
             find: "doc.object, version: version, debridRevision: doc.debridRevision",
             replacement: "doc.object, version: version, debridRevision: DebridCredentialSnapshotStore.shared.load().revision"),
    Mutation(name: "M40 mix a second credential snapshot into sync payload", rule: syncPayloadRule,
             path: syncPath,
             find: "if let value = debridSnapshot.keys[.torBox] { keys[\"torBox\"] = value }",
             replacement: "if let value = DebridCredentialSnapshotStore.shared.load().keys[.torBox] { keys[\"torBox\"] = value }"),
    Mutation(name: "M41 retain cache-awareness dedupe across credential revision", rule: callerRule,
             path: resolverPath,
             find: "self.lastQueried.removeAll()",
             replacement: "_ = self.lastQueried"),
    Mutation(name: "M42 suppress live credential invalidation signal", rule: callerRule, path: statePath,
             find: "NotificationCenter.default.post(name: Self.didPublishNotification, object: self)",
             replacement: "_ = Self.didPublishNotification"),
    Mutation(name: "M43 serialize stale sync payload before checking revision", rule: syncPayloadRule,
             path: syncPath,
             find: "guard DebridCredentialSnapshotStore.shared.isCurrent(revision: debridRevision) else {\n            return .error\n        }",
             replacement: "_ = debridRevision"),
    Mutation(name: "M44 restore blind sync payload helper", rule: syncPayloadRule, path: syncPath,
             find: "private struct DerivedSyncDocument {",
             replacement: "func pushSyncDoc(_ obj: [String: Any]) async -> Bool { false }\n\n    private struct DerivedSyncDocument {"),
    Mutation(name: "M45 suppress live TorBox contributor invalidation", rule: torBoxSearchRule,
             path: torBoxSearchPath,
             find: "forName: DebridCredentialSnapshotStore.didPublishNotification,",
             replacement: "forName: Notification.Name(\"mutant.torbox.no-invalidation\"),"),
    Mutation(name: "M46 omit durable quarantine recovery guard", rule: envelopeRule, path: statePath,
             find: "io.write(guardRaw, accounts.recoveryGuard)",
             replacement: "true"),
    Mutation(name: "M47 recapture playback usenet child", rule: apiRule, path: resolverPath,
             find: "nzbUrl: nzb, knownHash: knownHash, fileMustInclude: mustInclude,\n                            fileIdx: fileIdx, episode: selectionEpisode, generation: generation",
             replacement: "nzbUrl: nzb, knownHash: knownHash, fileMustInclude: mustInclude,\n                            fileIdx: fileIdx, episode: selectionEpisode"),
    Mutation(name: "M48 recapture playback torrent child", rule: apiRule, path: resolverPath,
             find: "infoHash: hash, magnet: magnet, fileIdx: fileIdx,\n                        episode: selectionEpisode, generation: generation",
             replacement: "infoHash: hash, magnet: magnet, fileIdx: fileIdx,\n                        episode: selectionEpisode"),
    Mutation(name: "M49 recapture singleton cached-race child", rule: apiRule, path: resolverPath,
             find: "let result = await resolvedPlaybackRefVersioned(\n                for: racing[0],\n                episode: episode,\n                confirmedCachedHashes: cachedHashes,\n                confirmedUsenetURLs: cachedUsenetURLs,\n                generation: generation",
             replacement: "let result = await resolvedPlaybackRefVersioned(\n                for: racing[0],\n                episode: episode,\n                confirmedCachedHashes: cachedHashes,\n                confirmedUsenetURLs: cachedUsenetURLs"),
    Mutation(name: "M50 recapture fanout cached-race child", rule: apiRule, path: resolverPath,
             find: "let result = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(\n                        for: stream,\n                        episode: episode,\n                        confirmedCachedHashes: cachedHashes,\n                        confirmedUsenetURLs: cachedUsenetURLs,\n                        generation: generation",
             replacement: "let result = await DebridCoordinator.shared.resolvedPlaybackRefVersioned(\n                        for: stream,\n                        episode: episode,\n                        confirmedCachedHashes: cachedHashes,\n                        confirmedUsenetURLs: cachedUsenetURLs"),
    Mutation(name: "M51 recapture torrent cache-awareness child", rule: callerRule, path: resolverPath,
             find: "hashes: Array(hashes),\n                    pinning: snapshot.revision",
             replacement: "hashes: Array(hashes)"),
    Mutation(name: "M52 recapture usenet cache-awareness child", rule: callerRule, path: resolverPath,
             find: "nzbMD5s: Array(byMD5.keys),\n                    pinning: revision",
             replacement: "nzbMD5s: Array(byMD5.keys)"),
    Mutation(name: "M53 recapture Continue Watching generation", rule: apiRule, path: coreModelsPath,
             find: "resolverGeneration(pinning: entryRevision)",
             replacement: "resolverGeneration(pinning: DebridCredentialSnapshotStore.shared.load().revision)"),
    Mutation(name: "M54 drop Continue Watching pinned spend", rule: apiRule, path: coreModelsPath,
             find: "requiresSemanticSelection: isEpisode,\n               generation: generation",
             replacement: "requiresSemanticSelection: isEpisode"),
    Mutation(name: "M55 let stale child enter", rule: apiRule, path: statePath,
             find: "value: token.isCurrent() ? token : nil",
             replacement: "value: token"),
    Mutation(name: "M56 bypass returned child-entry token", rule: apiRule, path: resolverPath,
             find: "let r = try await withCurrentCredential(token: credentialToken) {",
             replacement: "let r = try await withCurrentCredential(revision: revision) {"),
    Mutation(name: "M57 allow authority-free quarantine repair", rule: envelopeRule, path: statePath,
             find: "guard !normalized.isEmpty else { return .failed(.quarantinedCurrent) }",
             replacement: "_ = normalized"),
    Mutation(name: "M58 skip global recovery winner proof", rule: envelopeRule, path: statePath,
             find: "case .committed(let verified) = load(owner: owner, read: io.read),\n              verified.slot == target, verified.envelope == fresh",
             replacement: "true"),
    Mutation(name: "M59 detach cloud library task from credential revision", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: ".task(id: debrid.revision) {",
             replacement: ".task {"),
    Mutation(name: "M60 recapture cloud library task snapshot at the model call", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "let snapshot = debrid.snapshot\n            await model.loadIfNeeded(snapshot: snapshot)",
             replacement: "await model.loadIfNeeded(snapshot: debrid.snapshot)"),
    Mutation(name: "M61 restore one-shot cloud library load state", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "private(set) var loadedRevision: UInt64?",
             replacement: "private var didLoad = false"),
    Mutation(name: "M62 reuse a cloud library attempt token", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "nextAttemptID += 1",
             replacement: "_ = nextAttemptID"),
    Mutation(name: "M63 accept a cloud result from another credential revision", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "guard result.revision == snapshot.revision else {",
             replacement: "if false {"),
    Mutation(name: "M64 publish cloud loading outside the active-attempt seam", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "guard mutateIfActive(attemptID: attemptID, snapshot: snapshot, mutation: {\n            phase = .loading\n        }) else { return }",
             replacement: "phase = .loading"),
    Mutation(name: "M65 strand a canceled initial cloud library load", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "guard !Task.isCancelled else {\n            recoverAfterInterruptedAttempt(attemptID: attemptID, snapshot: snapshot)\n            return\n        }",
             replacement: "guard !Task.isCancelled else { return }"),
    Mutation(name: "M66 let an older same-revision cloud refresh publish", rule: libraryLivenessRule,
             path: debridLibraryPath,
             find: "guard self.activeAttemptID == attemptID,\n                      self.credentialStore.load() == snapshot,\n                      !Task.isCancelled else { return }",
             replacement: "guard self.activeAttemptID == attemptID || true,\n                      self.credentialStore.load() == snapshot,\n                      !Task.isCancelled else { return }"),
    Mutation(name: "M67 let older cloud recovery clear newer attempt ownership",
             rule: libraryRecoveryOwnershipRule, path: debridLibraryPath,
             find: "guard self.activeAttemptID == attemptID,\n                      self.credentialStore.load() == snapshot else { return }",
             replacement: "guard self.activeAttemptID == attemptID || true,\n                      self.credentialStore.load() == snapshot else { return }"),
]

@main
private enum DebridCredentialCallerGateRunner {
    static func main() {
        let root = CommandLine.arguments.dropFirst().first
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().path
        var failures: [String] = []
        var checks = 0

        for rule in rules {
            checks += 1
            var production: [String: SourceFile] = [:]
            for path in rule.files {
                guard let file = load(root: root, path: path) else {
                    failures.append("\(rule.name): missing production file \(path)")
                    continue
                }
                production[path] = file
            }
            let live = rule.violations(production)
            if live.isEmpty {
                print("PASS  \(rule.name)")
            } else {
                failures.append(contentsOf: live.map { "\(rule.name): \($0)" })
                print("FAIL  \(rule.name)")
            }
        }

        for mutation in mutations {
            checks += 1
            guard let rule = rules.first(where: { $0.name == mutation.rule }) else {
                failures.append("\(mutation.name): missing named rule \(mutation.rule)")
                print("FAIL  \(mutation.name)")
                continue
            }
            var mutated: [String: SourceFile] = [:]
            for path in rule.files {
                guard let file = load(root: root, path: path) else {
                    failures.append("\(mutation.name): missing production file \(path)")
                    continue
                }
                mutated[path] = file
            }
            guard let target = mutated[mutation.path] else {
                failures.append("\(mutation.name): target is outside named rule")
                print("FAIL  \(mutation.name)")
                continue
            }
            let matches = occurrenceCount(mutation.find, in: target.text)
            guard matches == 1 else {
                failures.append("\(mutation.name): expected one live mutation target, found \(matches)")
                print("FAIL  \(mutation.name)")
                continue
            }
            mutated[mutation.path] = SourceFile(
                path: target.path,
                text: target.text.replacingOccurrences(of: mutation.find, with: mutation.replacement)
            )
            if rule.violations(mutated).isEmpty {
                failures.append("\(mutation.name): live-source mutation survived")
                print("FAIL  \(mutation.name)")
            } else {
                print("PASS  \(mutation.name)")
            }
        }

        guard let publicationRule = rules.first(where: { $0.name == nonPlayerPublicationRule }) else {
            failures.append("missing named rule \(nonPlayerPublicationRule)")
            print("FAIL  non-player publication mutant setup")
            if !failures.isEmpty {
                print("FAILED \(failures.count) finding(s) across \(checks) checks")
                for failure in failures { print(" - \(failure)") }
                exit(1)
            }
            return
        }
        for site in publicationSites {
            for mutationKind in ["strip revision", "move mutation"] {
                checks += 1
                let name = "\(site.label): \(mutationKind)"
                var mutated: [String: SourceFile] = [:]
                for path in publicationRule.files {
                    guard let file = load(root: root, path: path) else {
                        failures.append("\(name): missing production file \(path)")
                        continue
                    }
                    mutated[path] = file
                }
                guard let target = mutated[site.path] else {
                    failures.append("\(name): target is outside named rule")
                    print("FAIL  \(name)")
                    continue
                }
                let changed = mutationKind == "strip revision"
                    ? stripPublicationRevision(site, from: target)
                    : movePublicationOutsideSeam(site, from: target)
                guard let changed else {
                    failures.append("\(name): expected one live site-specific mutation target")
                    print("FAIL  \(name)")
                    continue
                }
                mutated[site.path] = changed
                let findings = publicationRule.violations(mutated)
                if !findings.contains(where: { $0.contains(site.label) }) {
                    failures.append("\(name): site-specific live-source mutation survived")
                    print("FAIL  \(name)")
                } else {
                    print("PASS  \(name)")
                }
            }
        }

        if failures.isEmpty {
            print("ALL PASS (\(checks) checks)")
        } else {
            print("FAILED \(failures.count) finding(s) across \(checks) checks")
            for failure in failures { print(" - \(failure)") }
            exit(1)
        }
    }
}
