import Foundation
import CryptoKit

/// Encodes the 256-bit VortX account key as a standard BIP39 24-word recovery phrase, so a user can
/// write it down and recover (or sign in on the website) without a second device to scan. The format
/// is exactly BIP39: 256 bits of entropy plus an 8-bit SHA-256 checksum = 264 bits = 24 words. The
/// website mirrors this byte for byte (same wordlist + checksum) so a phrase works in either place.
///
/// The phrase IS the master secret: anyone with it can read the account, so it is shown once, never
/// stored server-side, and treated like the e2e key it encodes.
enum RecoveryPhrase {
    static func phrase(from key: SymmetricKey) -> String {
        encode(key.withUnsafeBytes { Data($0) }).joined(separator: " ")
    }

    static func key(from phrase: String) -> SymmetricKey? {
        guard let data = decode(phrase) else { return nil }
        return SymmetricKey(data: data)
    }

    /// 32 entropy bytes -> 24 words. Returns [] if the input is not 32 bytes.
    static func encode(_ entropy: Data) -> [String] {
        guard entropy.count == 32 else { return [] }
        let checksum = Data(SHA256.hash(data: entropy)).first ?? 0   // 8-bit checksum for 256-bit entropy
        var bits: [Bool] = []
        bits.reserveCapacity(264)
        for byte in entropy { for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> shift) & 1 == 1) } }
        for shift in stride(from: 7, through: 0, by: -1) { bits.append((checksum >> shift) & 1 == 1) }
        var words: [String] = []
        words.reserveCapacity(24)
        for group in 0..<24 {
            var index = 0
            for j in 0..<11 { index = (index << 1) | (bits[group * 11 + j] ? 1 : 0) }
            words.append(Bip39.words[index])
        }
        return words
    }

    /// 24 words -> 32 entropy bytes, validating the checksum. nil if malformed or the checksum fails.
    static func decode(_ phrase: String) -> Data? {
        let tokens = phrase.lowercased().split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
        guard tokens.count == 24 else { return nil }
        var bits: [Bool] = []
        bits.reserveCapacity(264)
        for token in tokens {
            guard let index = indexByWord[token] else { return nil }
            for shift in stride(from: 10, through: 0, by: -1) { bits.append((index >> shift) & 1 == 1) }
        }
        guard bits.count == 264 else { return nil }
        var entropy = [UInt8](repeating: 0, count: 32)
        for byteIdx in 0..<32 {
            var byte: UInt8 = 0
            for j in 0..<8 { byte = (byte << 1) | (bits[byteIdx * 8 + j] ? 1 : 0) }
            entropy[byteIdx] = byte
        }
        var checksum: UInt8 = 0
        for j in 0..<8 { checksum = (checksum << 1) | (bits[256 + j] ? 1 : 0) }
        guard checksum == (Data(SHA256.hash(data: Data(entropy))).first ?? 0) else { return nil }
        return Data(entropy)
    }

    private static let indexByWord: [String: Int] = {
        var map = [String: Int](minimumCapacity: 2048)
        for (i, word) in Bip39.words.enumerated() { map[word] = i }
        return map
    }()
}
