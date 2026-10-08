import Foundation
import CryptoKit

/// Cross-host, credential-free framing for the authenticated UUID-scoped profile overlay.
/// This is deliberately a binary value codec, not Foundation's JSON printer.
enum VortxProfileOverlayWitness {
    enum Failure: Error { case malformed }
    private static let maximumFrameBytes = 16_777_216
    private static let maximumNodes = 100_000
    private static let maximumDepth = 64
    private indirect enum Value { case null, bool(Bool), number(Double), string(String), array([Value]), object([(String, Value)]) }

    static func digest(json: Data) throws -> String {
        SHA256.hash(data: try framed(json: json)).map { String(format: "%02x", $0) }.joined()
    }

    /// Strictly decodes a raw JSON object for host ingress after the same duplicate-key, lexical
    /// number and resource checks used by witness framing. The returned Foundation shape is only
    /// for local projection; callers must retain the original bytes for raw-source provenance.
    /// A Unicode-equivalent Swift dictionary collision is refused rather than silently dropping a
    /// byte-distinct JSON key.
    static func decodeObject(json: Data) throws -> [String: Any] {
        var parser = try Parser(json)
        let value = try parser.value()
        try parser.finish()
        // Parsing bounds raw input, while framing also accounts for type tags and length words.
        // Exercise the writer here as well so ingress cannot accept a document that the witness
        // codec would reject solely because its aggregate framed representation is too large.
        var writer = Writer()
        try writer.append(contentsOf: Array("vortx.profile-overlay/1".utf8) + [0])
        try writer.write(value)
        guard case .object(let pairs) = value, let object = try materialize(value) as? [String: Any], object.count == pairs.count else {
            throw Failure.malformed
        }
        return object
    }

    /// Internal so the focused conformance harness can independently check framing boundaries.
    static func framed(json: Data) throws -> Data {
        var parser = try Parser(json)
        let value = try parser.value()
        try parser.finish()
        var writer = Writer()
        try writer.append(contentsOf: Array("vortx.profile-overlay/1".utf8) + [0])
        try writer.write(value)
        return Data(writer.bytes)
    }

    private static func materialize(_ value: Value) throws -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .number(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let values): return try values.map(materialize)
        case .object(let pairs):
            var object: [String: Any] = [:]
            for (key, value) in pairs {
                // Foundation/Swift key equality applies Unicode canonical equivalence. The parser
                // intentionally permits byte-distinct keys, so an ingress dictionary must refuse
                // this lossy representation rather than overwrite one of them.
                guard object[key] == nil else { throw Failure.malformed }
                object[key] = try materialize(value)
            }
            return object
        }
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func reserve(_ count: Int) throws {
            guard count >= 0, bytes.count <= VortxProfileOverlayWitness.maximumFrameBytes - count else { throw Failure.malformed }
        }

        mutating func append(_ byte: UInt8) throws {
            try reserve(1)
            bytes.append(byte)
        }

        mutating func append(contentsOf raw: [UInt8]) throws {
            try reserve(raw.count)
            bytes += raw
        }

        mutating func count(_ value: Int) throws {
            guard value >= 0 && value <= Int(UInt32.max) else { throw Failure.malformed }
            let n = UInt32(value)
            try append(contentsOf: [
                UInt8(truncatingIfNeeded: n >> 24),
                UInt8(truncatingIfNeeded: n >> 16),
                UInt8(truncatingIfNeeded: n >> 8),
                UInt8(truncatingIfNeeded: n)
            ])
        }

        mutating func string(_ value: String) throws {
            let raw = Array(value.utf8)
            try append(115)
            try count(raw.count)
            try append(contentsOf: raw)
        }

        mutating func write(_ value: Value) throws {
            switch value {
            case .null:
                try append(110)
            case .bool(false):
                try append(102)
            case .bool(true):
                try append(116)
            case .number(var number):
                guard number.isFinite, abs(number) <= 9_007_199_254_740_991 else { throw Failure.malformed }
                if number == 0 { number = 0 } // Normalize negative zero.
                try append(100)
                let bits = number.bitPattern
                try append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> UInt64($0 * 8)) })
            case .string(let string):
                try self.string(string)
            case .array(let values):
                try append(97)
                try count(values.count)
                for value in values { try write(value) }
            case .object(let pairs):
                try append(111)
                try count(pairs.count)
                for (key, value) in pairs.sorted(by: { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }) {
                    try string(key)
                    try write(value)
                }
            }
        }
    }

    private struct Parser {
        let raw: [UInt8]
        var index = 0
        var nodes = 0

        init(_ data: Data) throws {
            // Bound before materializing Data as an Array. The encoder's own aggregate frame limit
            // is stricter than any useful input size and avoids an attacker-controlled bulk copy.
            guard data.count <= VortxProfileOverlayWitness.maximumFrameBytes else { throw Failure.malformed }
            raw = Array(data)
        }

        mutating func finish() throws {
            skip()
            guard index == raw.count else { throw Failure.malformed }
        }

        mutating func skip() {
            while index < raw.count && [9, 10, 13, 32].contains(raw[index]) { index += 1 }
        }

        mutating func node() throws {
            nodes += 1
            guard nodes <= VortxProfileOverlayWitness.maximumNodes else { throw Failure.malformed }
        }

        mutating func value(_ depth: Int = 0) throws -> Value {
            guard depth <= VortxProfileOverlayWitness.maximumDepth else { throw Failure.malformed }
            try node()
            skip()
            guard index < raw.count else { throw Failure.malformed }
            switch raw[index] {
            case 110: try literal("null"); return .null
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 34: return .string(try string())
            case 91: return .array(try array(depth + 1))
            case 123: return .object(try object(depth + 1))
            case 45, 48...57: return .number(try number())
            default: throw Failure.malformed
            }
        }

        mutating func literal(_ text: String) throws {
            let bytes = Array(text.utf8)
            guard raw.dropFirst(index).starts(with: bytes) else { throw Failure.malformed }
            index += bytes.count
        }

        mutating func string() throws -> String {
            let start = index
            index += 1
            var escaped = false
            while index < raw.count {
                let byte = raw[index]
                index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    let literal = Data(raw[start..<index])
                    guard let value = try? JSONSerialization.jsonObject(with: Data([91]) + literal + Data([93])) as? [String],
                          let string = value.first,
                          !string.unicodeScalars.contains(where: { $0.value >= 0xD800 && $0.value <= 0xDFFF }) else {
                        throw Failure.malformed
                    }
                    return string
                }
                if byte < 0x20 { throw Failure.malformed }
            }
            throw Failure.malformed
        }

        mutating func array(_ depth: Int) throws -> [Value] {
            index += 1
            skip()
            if index < raw.count && raw[index] == 93 { index += 1; return [] }
            var values: [Value] = []
            while true {
                values.append(try value(depth))
                skip()
                guard index < raw.count else { throw Failure.malformed }
                if raw[index] == 93 { index += 1; return values }
                guard raw[index] == 44 else { throw Failure.malformed }
                index += 1
            }
        }

        mutating func object(_ depth: Int) throws -> [(String, Value)] {
            index += 1
            skip()
            if index < raw.count && raw[index] == 125 { index += 1; return [] }
            var values: [(String, Value)] = []
            var keys = Set<Data>()
            while true {
                skip()
                guard index < raw.count && raw[index] == 34 else { throw Failure.malformed }
                let key = try string()
                try node() // Keys are explicitly counted by the grammar, as are values.
                guard keys.insert(Data(key.utf8)).inserted else { throw Failure.malformed }
                skip()
                guard index < raw.count && raw[index] == 58 else { throw Failure.malformed }
                index += 1
                values.append((key, try value(depth)))
                skip()
                guard index < raw.count else { throw Failure.malformed }
                if raw[index] == 125 { index += 1; return values }
                guard raw[index] == 44 else { throw Failure.malformed }
                index += 1
            }
        }

        mutating func number() throws -> Double {
            let start = index
            if raw[index] == 45 { index += 1 }
            guard index < raw.count else { throw Failure.malformed }
            if raw[index] == 48 {
                index += 1
            } else {
                guard (49...57).contains(raw[index]) else { throw Failure.malformed }
                while index < raw.count && (48...57).contains(raw[index]) { index += 1 }
            }
            if index < raw.count && raw[index] == 46 {
                index += 1
                let digits = index
                while index < raw.count && (48...57).contains(raw[index]) { index += 1 }
                guard index > digits else { throw Failure.malformed }
            }
            if index < raw.count && (raw[index] == 69 || raw[index] == 101) {
                index += 1
                if index < raw.count && (raw[index] == 43 || raw[index] == 45) { index += 1 }
                let digits = index
                while index < raw.count && (48...57).contains(raw[index]) { index += 1 }
                guard index > digits else { throw Failure.malformed }
            }
            let token = raw[start..<index]
            guard Self.isWithinExactMagnitude(token) else { throw Failure.malformed }
            let spelling = String(decoding: token, as: UTF8.self)
            guard let value = Double(spelling), value.isFinite, abs(value) <= 9_007_199_254_740_991 else { throw Failure.malformed }
            return value
        }

        /// Compares the original decimal token against 2^53-1 without Decimal's precision or
        /// exponent range limits. Zero remains valid at every exponent; otherwise the comparison
        /// only needs the first sixteen integral digits and any remaining non-zero fraction.
        private static func isWithinExactMagnitude(_ token: ArraySlice<UInt8>) -> Bool {
            let bytes = Array(token)
            var cursor = bytes[0] == 45 ? 1 : 0
            var exponentStart = bytes.count
            var decimalStart: Int?
            while cursor < bytes.count {
                if bytes[cursor] == 101 || bytes[cursor] == 69 { exponentStart = cursor; break }
                if bytes[cursor] == 46 { decimalStart = cursor }
                cursor += 1
            }
            let significandEnd = exponentStart
            let fractionalDigits = decimalStart.map { significandEnd - $0 - 1 } ?? 0
            var firstDigits: [UInt8] = []
            var significantDigits = 0
            var sawNonZero = false
            var nonZeroAfterFirstSixteen = false
            var position = bytes[0] == 45 ? 1 : 0
            while position < significandEnd {
                let digit = bytes[position]
                position += 1
                if digit == 46 { continue }
                if !sawNonZero {
                    if digit == 48 { continue }
                    sawNonZero = true
                }
                significantDigits += 1
                if firstDigits.count < 16 { firstDigits.append(digit) }
                else if digit != 48 { nonZeroAfterFirstSixteen = true }
            }
            if !sawNonZero { return true }

            var exponent = 0
            if exponentStart < bytes.count {
                var exponentPosition = exponentStart + 1
                let negative = exponentPosition < bytes.count && bytes[exponentPosition] == 45
                if exponentPosition < bytes.count && (bytes[exponentPosition] == 45 || bytes[exponentPosition] == 43) { exponentPosition += 1 }
                let cap = 20_000_000
                while exponentPosition < bytes.count {
                    let digit = Int(bytes[exponentPosition] - 48)
                    exponent = min(cap, exponent * 10 + digit)
                    exponentPosition += 1
                }
                if negative { exponent = -exponent }
            }
            let integralDigits = significantDigits + exponent - fractionalDigits
            if integralDigits < 16 { return true }
            if integralDigits > 16 { return false }
            let maximum = Array("9007199254740991".utf8)
            while firstDigits.count < 16 { firstDigits.append(48) }
            if firstDigits.lexicographicallyPrecedes(maximum) { return true }
            if maximum.lexicographicallyPrecedes(firstDigits) { return false }
            return !nonZeroAfterFirstSixteen
        }
    }
}
