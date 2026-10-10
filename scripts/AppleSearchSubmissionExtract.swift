import Foundation

private struct SourceExtractor {
    let source: String

    private func index(of needle: String, after start: String.Index? = nil) -> String.Index? {
        source.range(of: needle, range: start.map { $0..<source.endIndex }).map(\.lowerBound)
    }

    private func matchingBrace(from open: String.Index) -> String.Index {
        var depth = 0
        var index = open
        var lineComment = false
        var blockCommentDepth = 0
        var stringLiteral = false
        var escaped = false

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : Character("\0")

            if lineComment {
                if character == "\n" { lineComment = false }
            } else if blockCommentDepth > 0 {
                if character == "/" && nextCharacter == "*" {
                    blockCommentDepth += 1
                    index = source.index(after: next)
                    continue
                }
                if character == "*" && nextCharacter == "/" {
                    blockCommentDepth -= 1
                    index = source.index(after: next)
                    continue
                }
            } else if stringLiteral {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    stringLiteral = false
                }
            } else {
                if character == "/" && nextCharacter == "/" {
                    lineComment = true
                    index = source.index(after: next)
                    continue
                }
                if character == "/" && nextCharacter == "*" {
                    blockCommentDepth = 1
                    index = source.index(after: next)
                    continue
                }
                if character == "\"" {
                    stringLiteral = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = next
        }

        fatalError("unbalanced brace in extracted Apple Search source")
    }

    private func openingBrace(after anchor: String, occurrence: Int = 0) -> (start: String.Index, open: String.Index) {
        var searchStart = source.startIndex
        var anchorStart: String.Index?
        for _ in 0...occurrence {
            guard let found = index(of: anchor, after: searchStart) else {
                fatalError("missing extraction anchor: \(anchor)")
            }
            anchorStart = found
            searchStart = source.index(found, offsetBy: anchor.count)
        }
        guard let start = anchorStart,
              let open = source[start...].firstIndex(of: "{") else {
            fatalError("missing opening brace after extraction anchor: \(anchor)")
        }
        return (start, open)
    }

    func closureBody(anchor: String, occurrence: Int = 0) -> String {
        let (_, open) = openingBrace(after: anchor, occurrence: occurrence)
        let close = matchingBrace(from: open)
        var bodyStart = source.index(after: open)
        if anchor.contains(" in"),
           let parameterEnd = source[bodyStart..<close].range(of: " in")?.upperBound {
            bodyStart = parameterEnd
        }
        return String(source[bodyStart..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func function(anchor: String) -> String {
        let (start, open) = openingBrace(after: anchor)
        let close = matchingBrace(from: open)
        return String(source[start...close]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func optionalFunction(anchor: String) -> String? {
        guard source.range(of: anchor) != nil else { return nil }
        return function(anchor: anchor)
    }
}
private struct ExtractionInput {
    var source: String
    var template: String
    var output: String
}

@main
private struct AppleSearchSubmissionExtract {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        var sourcePath: String?
        var templatePath: String?
        var outputPath: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--source": sourcePath = iterator.next()
            case "--template": templatePath = iterator.next()
            case "--output": outputPath = iterator.next()
            default: throw usageError
            }
        }
        guard let sourcePath, let templatePath, let outputPath else { throw usageError }

        let input = ExtractionInput(
            source: try String(contentsOfFile: sourcePath, encoding: .utf8),
            template: try String(contentsOfFile: templatePath, encoding: .utf8),
            output: outputPath
        )
        let extractor = SourceExtractor(source: input.source)

        let mergedSubmit: String
        if let productionMethod = extractor.optionalFunction(anchor: "private func submitMergedSearch(") {
            mergedSubmit = productionMethod
        } else {
            let legacySubmitBody = extractor.closureBody(
                anchor: ".onSubmit { core.suggestSearch(searchQuery); core.search(searchQuery) }"
            )
            mergedSubmit = "private func submitMergedSearch(_ submittedQuery: String? = nil) {\n\(legacySubmitBody)\n}"
        }

        let replacements: [String: String] = [
            "/*__DEDICATED_HANDOFF_BODY__*/": extractor.closureBody(
                anchor: ".onReceive(MacSearchBridge.shared.$pending) { pending in", occurrence: 0
            ),
            "/*__DEDICATED_CHANGE_BODY__*/": extractor.closureBody(
                anchor: ".onChange(of: query) { value in"
            ),
            "/*__MERGED_HANDOFF_BODY__*/": extractor.closureBody(
                anchor: ".onReceive(MacSearchBridge.shared.$pending) { pending in", occurrence: 1
            ),
            "/*__MERGED_CHANGE_BODY__*/": extractor.closureBody(
                anchor: ".onChange(of: searchQuery) { value in"
            ),
            "/*__SUBMIT_TOUCH_SEARCH__*/": extractor.function(anchor: "private func submitTouchSearch("),
            "/*__SCHEDULE_SEARCH__*/": extractor.function(anchor: "private func scheduleSearch("),
            "/*__SUBMIT_MERGED_SEARCH__*/": mergedSubmit,
            "/*__SCHEDULE_MERGED_SEARCH__*/": extractor.function(anchor: "private func scheduleMergedSearch("),
            "/*__SET_QUERY__*/": extractor.function(anchor: "    func setQuery("),
            "/*__SCHEDULE_SUGGESTIONS_REFRESH__*/": extractor.function(anchor: "private func scheduleSuggestionsRefresh(")
        ]

        var generated = input.template
        for (token, replacement) in replacements {
            guard generated.components(separatedBy: token).count == 2 else {
                throw NSError(domain: "AppleSearchSubmissionExtract", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "missing or duplicate template token \(token)"])
            }
            generated = generated.replacingOccurrences(of: token, with: replacement)
        }
        try generated.write(toFile: input.output, atomically: true, encoding: .utf8)
    }

    private static var usageError: NSError {
        NSError(domain: "AppleSearchSubmissionExtract", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "usage: AppleSearchSubmissionExtract --source PATH --template PATH --output PATH"])
    }
}
