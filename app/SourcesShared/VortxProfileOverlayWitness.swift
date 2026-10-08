import Foundation
import CryptoKit

/// Cross-host, credential-free framing for the authenticated UUID-scoped profile overlay.
/// This is deliberately a binary value codec, not Foundation's JSON printer.
enum VortxProfileOverlayWitness {
    enum Failure: Error { case malformed }
    private indirect enum Value { case null, bool(Bool), number(Double), string(String), array([Value]), object([(String, Value)]) }

    static func digest(json: Data) throws -> String {
        var parser = Parser(json)
        let value = try parser.value()
        try parser.finish()
        var writer = Writer()
        writer.bytes += Array("vortx.profile-overlay/1".utf8) + [0]
        try writer.write(value)
        guard writer.bytes.count <= 16_777_216 else { throw Failure.malformed }
        return SHA256.hash(data: Data(writer.bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Writer {
        var bytes: [UInt8] = []
        mutating func count(_ value: Int) throws {
            guard value >= 0 && value <= Int(UInt32.max) else { throw Failure.malformed }
            let n = UInt32(value); bytes += [UInt8(n >> 24), UInt8(n >> 16), UInt8(n >> 8), UInt8(n)]
        }
        mutating func string(_ value: String) throws { let raw = Array(value.utf8); bytes.append(115); try count(raw.count); bytes += raw }
        mutating func write(_ value: Value) throws {
            switch value {
            case .null: bytes.append(110)
            case .bool(false): bytes.append(102)
            case .bool(true): bytes.append(116)
            case .number(var number):
                guard number.isFinite, abs(number) <= 9_007_199_254_740_991 else { throw Failure.malformed }
                if number == 0 { number = 0 }
                bytes.append(100); let n = number.bitPattern
                bytes += (0..<8).reversed().map { UInt8((n >> UInt64($0 * 8)) & 0xff) }
            case .string(let string): try self.string(string)
            case .array(let values): bytes.append(97); try count(values.count); for value in values { try write(value) }
            case .object(let pairs):
                bytes.append(111); try count(pairs.count)
                for (key, value) in pairs.sorted(by: { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }) { try string(key); try write(value) }
            }
            guard bytes.count <= 16_777_216 else { throw Failure.malformed }
        }
    }

    private struct Parser {
        let raw: [UInt8]; var index = 0; var nodes = 0
        init(_ data: Data) { raw = Array(data) }
        mutating func finish() throws { skip(); guard index == raw.count else { throw Failure.malformed } }
        mutating func skip() { while index < raw.count && [9, 10, 13, 32].contains(raw[index]) { index += 1 } }
        mutating func value(_ depth: Int = 0) throws -> Value {
            guard depth <= 64 else { throw Failure.malformed }; nodes += 1; guard nodes <= 100_000 else { throw Failure.malformed }
            skip(); guard index < raw.count else { throw Failure.malformed }
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
        mutating func literal(_ text: String) throws { let bytes = Array(text.utf8); guard raw.dropFirst(index).starts(with: bytes) else { throw Failure.malformed }; index += bytes.count }
        mutating func string() throws -> String {
            let start = index; index += 1; var escaped = false
            while index < raw.count {
                let byte = raw[index]; index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    let literal = Data(raw[start..<index])
                    guard let value = try? JSONSerialization.jsonObject(with: Data([91]) + literal + Data([93])) as? [String], let string = value.first,
                          !string.unicodeScalars.contains(where: { $0.value >= 0xD800 && $0.value <= 0xDFFF }) else { throw Failure.malformed }
                    return string
                }
                if byte < 0x20 { throw Failure.malformed }
            }
            throw Failure.malformed
        }
        mutating func array(_ depth: Int) throws -> [Value] {
            index += 1; skip(); if index < raw.count && raw[index] == 93 { index += 1; return [] }
            var values: [Value] = []
            while true { values.append(try value(depth)); skip(); guard index < raw.count else { throw Failure.malformed }; if raw[index] == 93 { index += 1; return values }; guard raw[index] == 44 else { throw Failure.malformed }; index += 1 }
        }
        mutating func object(_ depth: Int) throws -> [(String, Value)] {
            index += 1; skip(); if index < raw.count && raw[index] == 125 { index += 1; return [] }
            var values: [(String, Value)] = []; var keys = Set<String>()
            while true { skip(); guard index < raw.count && raw[index] == 34 else { throw Failure.malformed }; let key = try string(); guard keys.insert(key).inserted else { throw Failure.malformed }; skip(); guard index < raw.count && raw[index] == 58 else { throw Failure.malformed }; index += 1; values.append((key, try value(depth))); skip(); guard index < raw.count else { throw Failure.malformed }; if raw[index] == 125 { index += 1; return values }; guard raw[index] == 44 else { throw Failure.malformed }; index += 1 }
        }
        mutating func number() throws -> Double {
            let start = index; if raw[index] == 45 { index += 1 }; guard index < raw.count else { throw Failure.malformed }
            if raw[index] == 48 { index += 1 } else { guard (49...57).contains(raw[index]) else { throw Failure.malformed }; while index < raw.count && (48...57).contains(raw[index]) { index += 1 } }
            if index < raw.count && raw[index] == 46 { index += 1; let digits = index; while index < raw.count && (48...57).contains(raw[index]) { index += 1 }; guard index > digits else { throw Failure.malformed } }
            if index < raw.count && (raw[index] == 69 || raw[index] == 101) { index += 1; if index < raw.count && (raw[index] == 43 || raw[index] == 45) { index += 1 }; let digits = index; while index < raw.count && (48...57).contains(raw[index]) { index += 1 }; guard index > digits else { throw Failure.malformed } }
            let token = String(decoding: raw[start..<index], as: UTF8.self)
            let maximum = Decimal(9_007_199_254_740_991)
            guard let decimal = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")), abs(decimal) <= maximum,
                  let value = Double(token), value.isFinite, abs(value) <= 9_007_199_254_740_991 else { throw Failure.malformed }
            return value
        }
    }
}
