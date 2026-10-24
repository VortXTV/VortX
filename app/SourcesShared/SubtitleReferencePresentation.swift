import Foundation

/// Fully prepared, immutable presentation data. This type conveys no account/player authority.
/// Build it on the subtitle worker from the native adapter's complete validated cue array. Final
/// adoption is a reference swap; platform attributed-text/font preparation is a separate seam.
enum SubtitleReferencePresentation {
    struct RunStyle: Sendable, Equatable {
        var bold = false
        var italic = false
        var underline = false
        /// An authored sRGB colour, not the user's default colour. Nil means inherit the default.
        var foregroundRGB: UInt32?
    }

    struct Run: Sendable, Equatable {
        let text: String
        let style: RunStyle
    }

    final class Cue: Sendable {
        let index: Int
        let startMs: UInt64
        let endMs: UInt64
        /// Retained verbatim, including whitespace, entities and authored markup.
        let originalText: String
        let runs: [Run]

        fileprivate init(index: Int, source: SubtitleReferenceNativeQuery.RetimedCue, runs: [Run]) {
            self.index = index
            startMs = source.startMs
            endMs = source.endMs
            originalText = source.text
            self.runs = runs
        }
    }

    /// Persistent AVL nodes share unchanged subtrees between boundary presentations. There is no
    /// quadratic array of complete active sets, even when all 12,000 cues overlap for hours.
    fileprivate final class Node: Sendable {
        let cue: Cue
        let left: Node?
        let right: Node?
        let height: Int
        let count: Int

        init(_ cue: Cue, _ left: Node? = nil, _ right: Node? = nil) {
            self.cue = cue
            self.left = left
            self.right = right
            height = 1 + max(left?.height ?? 0, right?.height ?? 0)
            count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
        }
    }

    final class Presentation: Sendable {
        /// Stable only within this Prepared instance; Clock also compares the Prepared identity.
        let boundaryIdentity: Int
        let activeCueCount: Int
        fileprivate let root: Node

        fileprivate init(boundaryIdentity: Int, root: Node) {
            self.boundaryIdentity = boundaryIdentity
            self.root = root
            activeCueCount = root.count
        }

        /// Visits every overlapping cue in original file order, in O(active cues) time. A caller
        /// performs this only after an identity change, never under an ownership/effect lock.
        func forEachCue(_ body: (Cue) -> Void) {
            func visit(_ node: Node?) {
                guard let node else { return }
                visit(node.left)
                body(node.cue)
                visit(node.right)
            }
            visit(root)
        }
    }

    fileprivate struct Boundary: Sendable {
        let atMs: UInt64
        let presentation: Presentation?
    }

    final class Prepared: Sendable {
        let originalJob: UUID
        /// Exact corrected native output, not the pre-alignment external sidecar.
        let retimedSRT: Data
        let cues: [Cue]
        let boundaryCount: Int
        /// Presentation identity only, not an authority token. Unlike ObjectIdentifier it cannot
        /// be recycled if the previous prepared object has already been released.
        fileprivate let presentationIdentity = UUID()
        fileprivate let boundaries: [Boundary]

        fileprivate init(file: SubtitleReferenceNativeQuery.RetimedFile, cues: [Cue], boundaries: [Boundary]) {
            originalJob = file.originalJob
            retimedSRT = file.srt
            self.cues = cues
            self.boundaries = boundaries
            boundaryCount = boundaries.count
        }

        /// O(log cue count), no cue scan, string building or allocation. Positive manual delay
        /// displays subtitles later. The delay is not clamped to the alignment search window.
        func lookup(mediaSeconds: Double, manualDelaySeconds: Double) -> Lookup {
            guard mediaSeconds.isFinite, manualDelaySeconds.isFinite else { return .clear }
            let subtitleSeconds = mediaSeconds - manualDelaySeconds
            guard subtitleSeconds.isFinite else { return .clear }
            var low = 0
            var high = boundaries.count
            while low < high {
                let middle = low + (high - low) / 2
                // Compare in the sampled seconds domain. Multiplying e.g. 1.001 by 1000
                // can round just below 1001 and miss an exactly sampled cue boundary.
                if Double(boundaries[middle].atMs) / 1_000 <= subtitleSeconds {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let presentation = low == 0 ? nil : boundaries[low - 1].presentation
            let next = low < boundaries.count
                ? Double(boundaries[low].atMs) / 1_000 + manualDelaySeconds : nil
            return Lookup(presentation: presentation, nextBoundaryMediaSeconds: next.flatMap { $0.isFinite ? $0 : nil })
        }
    }

    struct Lookup: Sendable {
        let presentation: Presentation?
        /// In the sampled media-clock domain, not wall-clock time. A paused player must not
        /// advance captions by extrapolating this timestamp with a wall-clock timer.
        let nextBoundaryMediaSeconds: Double?
        fileprivate static let clear = Lookup(presentation: nil, nextBoundaryMediaSeconds: nil)
    }

    struct Update: Sendable {
        let changed: Bool
        let presentation: Presentation?
        let nextBoundaryMediaSeconds: Double?
    }

    /// Pure identity-change publication state. Seeks (including backward seeks) use the same
    /// binary lookup; manual-delay changes always refresh the next boundary even without redraw.
    struct Clock: Sendable {
        private var previousPrepared: UUID?
        private var previousBoundary: Int?
        private var sampled = false

        mutating func sample(_ prepared: Prepared, mediaSeconds: Double, manualDelaySeconds: Double) -> Update {
            let lookup = prepared.lookup(mediaSeconds: mediaSeconds, manualDelaySeconds: manualDelaySeconds)
            let owner = prepared.presentationIdentity
            let boundary = lookup.presentation?.boundaryIdentity
            let changed = !sampled || previousPrepared != owner || previousBoundary != boundary
            previousPrepared = owner
            previousBoundary = boundary
            sampled = true
            return Update(changed: changed, presentation: lookup.presentation,
                          nextBoundaryMediaSeconds: lookup.nextBoundaryMediaSeconds)
        }

        mutating func reset() {
            previousPrepared = nil
            previousBoundary = nil
            sampled = false
        }
    }

    enum Failure: Error, Sendable, Equatable {
        case invalidCompleteFile
        case invalidCue(index: Int)
        /// Refuse the whole app-overlay representation. Do not strip the offending tag or mount
        /// a partial result; the untouched original file remains available for native fallback.
        case unsupportedMarkup(index: Int)
    }

    private struct Event {
        let atMs: UInt64
        let index: Int
        let starts: Bool
    }

    /// Consumes every validated cue directly, without reparsing/re-serializing the SRT. The bounds
    /// mirror the native reply serializer, not the permissive ordinary renderer's smaller caps.
    static func prepare(_ file: SubtitleReferenceNativeQuery.RetimedFile) throws -> Prepared {
        guard !file.srt.isEmpty, file.srt.count <= 8 * 1024 * 1024,
              (1...12_000).contains(file.cues.count) else { throw Failure.invalidCompleteFile }
        var cues: [Cue] = []
        cues.reserveCapacity(file.cues.count)
        var events: [Event] = []
        events.reserveCapacity(file.cues.count * 2)
        var previousStart: UInt64?
        for (index, source) in file.cues.enumerated() {
            guard source.startMs < source.endMs, source.endMs <= 91_000_000,
                  previousStart.map({ source.startMs > $0 }) ?? true,
                  !source.text.isEmpty, source.text.utf8.count <= 16_384,
                  !source.text.contains("\0") else { throw Failure.invalidCue(index: index) }
            guard let runs = parseRuns(source.text) else { throw Failure.unsupportedMarkup(index: index) }
            let cue = Cue(index: index, source: source, runs: runs)
            cues.append(cue)
            events.append(Event(atMs: source.startMs, index: index, starts: true))
            events.append(Event(atMs: source.endMs, index: index, starts: false))
            previousStart = source.startMs
        }
        events.sort {
            if $0.atMs != $1.atMs { return $0.atMs < $1.atMs }
            if $0.starts != $1.starts { return !$0.starts }
            return $0.index < $1.index
        }
        var root: Node?
        var boundaries: [Boundary] = []
        boundaries.reserveCapacity(events.count)
        var cursor = 0
        while cursor < events.count {
            let atMs = events[cursor].atMs
            repeat {
                let event = events[cursor]
                root = event.starts ? inserting(cues[event.index], into: root) : removing(event.index, from: root)
                cursor += 1
            } while cursor < events.count && events[cursor].atMs == atMs
            // Applying the complete equal-time group gives conventional half-open [start, end).
            let presentation = root.map { Presentation(boundaryIdentity: boundaries.count, root: $0) }
            boundaries.append(Boundary(atMs: atMs, presentation: presentation))
        }
        return Prepared(file: file, cues: cues, boundaries: boundaries)
    }

    private static func inserting(_ cue: Cue, into node: Node?) -> Node {
        guard let node else { return Node(cue) }
        if cue.index < node.cue.index {
            return balanced(Node(node.cue, inserting(cue, into: node.left), node.right))
        }
        return balanced(Node(node.cue, node.left, inserting(cue, into: node.right)))
    }

    private static func removing(_ index: Int, from node: Node?) -> Node? {
        guard let node else { return nil }
        if index < node.cue.index {
            return balanced(Node(node.cue, removing(index, from: node.left), node.right))
        }
        if index > node.cue.index {
            return balanced(Node(node.cue, node.left, removing(index, from: node.right)))
        }
        guard let left = node.left else { return node.right }
        guard let right = node.right else { return left }
        var successor = right
        while let next = successor.left { successor = next }
        return balanced(Node(successor.cue, left, removing(successor.cue.index, from: right)))
    }

    private static func balanced(_ node: Node) -> Node {
        let balance = (node.left?.height ?? 0) - (node.right?.height ?? 0)
        if balance > 1, let left = node.left {
            let adjusted = (left.left?.height ?? 0) < (left.right?.height ?? 0)
                ? Node(node.cue, rotatingLeft(left), node.right) : node
            return rotatingRight(adjusted)
        }
        if balance < -1, let right = node.right {
            let adjusted = (right.right?.height ?? 0) < (right.left?.height ?? 0)
                ? Node(node.cue, node.left, rotatingRight(right)) : node
            return rotatingLeft(adjusted)
        }
        return node
    }

    private static func rotatingLeft(_ node: Node) -> Node {
        guard let pivot = node.right else { return node }
        return Node(pivot.cue, Node(node.cue, node.left, pivot.left), pivot.right)
    }

    private static func rotatingRight(_ node: Node) -> Node {
        guard let pivot = node.left else { return node }
        return Node(pivot.cue, pivot.left, Node(node.cue, pivot.right, node.right))
    }

    private enum Tag: String { case bold = "b", italic = "i", underline = "u", font }

    /// A finite SRT span subset, not HTML rendering. Unsupported attributes/effects refuse the
    /// complete representation. Entity decoding happens once, after lexical tag recognition, so
    /// escaped tag text never becomes markup. No whitespace trimming or plain-text flattening.
    private static func parseRuns(_ text: String) -> [Run]? {
        guard !text.contains("{\\") else { return nil }
        let scalars = Array(text.unicodeScalars)
        var runs: [Run] = []
        var style = RunStyle()
        var stack: [(Tag, RunStyle)] = []
        var buffer = String.UnicodeScalarView()
        var cursor = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            // Do not repeatedly concatenate equal-style runs: authored empty tag transitions
            // can otherwise turn a bounded cue into quadratic string-copy work.
            runs.append(Run(text: String(buffer), style: style))
            buffer = String.UnicodeScalarView()
        }
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar.value == 60 { // <
                guard let end = scalars[(cursor + 1)...].firstIndex(where: { $0.value == 62 }) else { return nil }
                let raw = String(String.UnicodeScalarView(scalars[(cursor + 1)..<end]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = raw.lowercased()
                if lower == "br" || lower == "br/" {
                    buffer.append("\n")
                } else if lower.hasPrefix("/") {
                    guard let tag = Tag(rawValue: String(lower.dropFirst())),
                          let previous = stack.last, previous.0 == tag else { return nil }
                    flush()
                    style = previous.1
                    stack.removeLast()
                } else {
                    let tag: Tag
                    var next = style
                    switch lower {
                    case "b": tag = .bold; next.bold = true
                    case "i": tag = .italic; next.italic = true
                    case "u": tag = .underline; next.underline = true
                    default:
                        guard lower.hasPrefix("font"), let rgb = fontColour(raw) else { return nil }
                        tag = .font
                        next.foregroundRGB = rgb
                    }
                    flush()
                    stack.append((tag, style))
                    style = next
                }
                cursor = end + 1
                continue
            }
            if scalar.value == 38 { // &
                var end = cursor + 1
                // A finite lexical token, not a fixed lookahead that could silently leave a
                // long valid numeric entity undecoded. Stop at the next token delimiter so
                // repeated literal ampersands cannot cause quadratic suffix scanning.
                while end < scalars.count && scalars[end].value != 59
                    && scalars[end].value != 38 && scalars[end].value != 60
                    && !CharacterSet.whitespacesAndNewlines.contains(scalars[end]) {
                    end += 1
                }
                if end < scalars.count && scalars[end].value == 59 {
                    let name = String(String.UnicodeScalarView(scalars[(cursor + 1)..<end]))
                    guard let value = entity(name) else { return nil }
                    buffer.append(value)
                    cursor = end + 1
                    continue
                }
            }
            buffer.append(scalar)
            cursor += 1
        }
        guard stack.isEmpty else { return nil }
        flush()
        return runs
    }

    private static func fontColour(_ raw: String) -> UInt32? {
        guard raw.count > 4, raw.prefix(4).lowercased() == "font",
              raw[raw.index(raw.startIndex, offsetBy: 4)].isWhitespace else { return nil }
        var attribute = raw.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        guard attribute.count >= 5, attribute.prefix(5).lowercased() == "color" else { return nil }
        attribute = attribute.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard attribute.first == "=" else { return nil }
        attribute = attribute.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard attribute.count == 9, let quote = attribute.first, quote == "\"" || quote == "'",
              attribute.last == quote else { return nil }
        let value = attribute.dropFirst().dropLast()
        guard value.first == "#", value.count == 7,
              value.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }

    private static func entity(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            guard name.first == "#" else { return nil }
            let digits = name.dropFirst()
            let hexadecimal = digits.first == "x" || digits.first == "X"
            let number = hexadecimal ? digits.dropFirst() : digits[...]
            guard !number.isEmpty,
                  number.allSatisfy({ $0.isASCII && (hexadecimal ? $0.isHexDigit : $0.isNumber) }),
                  let value = UInt32(number, radix: hexadecimal ? 16 : 10), value != 0 else { return nil }
            return Unicode.Scalar(value)
        }
    }
}
