import Foundation
import Security

enum VortXSecureEntropy {
    static func randomBytes(_ count: Int) -> Data? {
        randomBytes(count) { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress) == errSecSuccess
        }
    }

    /// Injectable seam for proving that entropy failure returns no key material. A failed provider must never
    /// leave the zero-filled allocation looking like a successful random value.
    static func randomBytes(
        _ count: Int,
        fill: (UnsafeMutableRawBufferPointer) -> Bool
    ) -> Data? {
        guard count > 0 else { return nil }
        var data = Data(count: count)
        let filled = data.withUnsafeMutableBytes(fill)
        return filled ? data : nil
    }

    /// A strong human-friendly recovery code, identical to the website: VX- plus 26 Crockford base32
    /// characters over 128 random bits, grouped in fours.
    static func makeRecoveryCode() -> String? {
        guard let bytes = randomBytes(16) else { return nil }
        return recoveryCode(from: bytes)
    }

    static func recoveryCode(from bytes: Data) -> String? {
        guard bytes.count == 16 else { return nil }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits = ""
        for byte in bytes { bits += String(byte, radix: 2).leftPadded(to: 8) }
        var output = ""
        var index = bits.startIndex
        while index < bits.endIndex {
            let end = bits.index(index, offsetBy: 5, limitedBy: bits.endIndex) ?? bits.endIndex
            let chunk = String(bits[index..<end]).rightPadded(to: 5)
            if let value = Int(chunk, radix: 2) { output.append(alphabet[value]) }
            index = end
        }
        let groups = stride(from: 0, to: output.count, by: 4).map { start -> String in
            let groupStart = output.index(output.startIndex, offsetBy: start)
            let groupEnd = output.index(
                groupStart,
                offsetBy: 4,
                limitedBy: output.endIndex) ?? output.endIndex
            return String(output[groupStart..<groupEnd])
        }
        return "VX-" + groups.joined(separator: "-")
    }
}

private extension String {
    func leftPadded(to count: Int) -> String {
        self.count >= count ? self : String(repeating: "0", count: count - self.count) + self
    }

    func rightPadded(to count: Int) -> String {
        self.count >= count ? self : self + String(repeating: "0", count: count - self.count)
    }
}
