import Foundation

/// Parses the bundled CHANGELOG.md into flat display blocks for the Settings > What's New screens
/// (SourcesiOS/WhatsNewView on iPhone/iPad/Mac, SourcesTV/TVWhatsNewView on Apple TV). Pure parsing,
/// no UI, so it lives in the shared layer and both views render the same structure. Falls back to the
/// curated WhatsNew.highlights for the current version when the changelog resource is missing.
enum ChangelogParser {

    struct Block {
        enum Kind { case version, subhead, bullet, paragraph }
        let kind: Kind
        let text: String
    }

    /// Render inline markdown (bold, links) without treating block syntax specially, so a "- **Title.** body"
    /// bullet shows the bold run. Falls back to the raw string if parsing fails.
    static func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    /// Load and parse the bundled CHANGELOG.md into display blocks. Everything before the first `## ` version
    /// header (the top title + intro links) is skipped. Falls back to the current version's highlights.
    static func loadBlocks() -> [Block] {
        guard let text = bundledChangelog(), !text.isEmpty else { return fallbackBlocks() }
        let blocks = parse(text)
        return blocks.isEmpty ? fallbackBlocks() : blocks
    }

    /// The pure markdown-to-blocks pass: `## ` starts a version, `### ` a subhead, `- `/`* ` a bullet,
    /// other heading levels are dropped, anything else is a paragraph.
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var started = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                started = true
                blocks.append(.init(kind: .version, text: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard started else { continue } // skip the "# Changelog" title + intro before the first version
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                blocks.append(.init(kind: .subhead, text: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.init(kind: .bullet, text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("#") {
                continue // any other heading level: skip the marker line, keep it out of the body
            } else {
                blocks.append(.init(kind: .paragraph, text: line))
            }
        }
        return blocks
    }

    private static func bundledChangelog() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Used only when CHANGELOG.md is not bundled: the current version's curated highlights.
    private static func fallbackBlocks() -> [Block] {
        var blocks: [Block] = [.init(kind: .version, text: "VortX \(WhatsNew.version)")]
        blocks.append(contentsOf: WhatsNew.highlights.map { .init(kind: .bullet, text: $0) })
        return blocks
    }
}
