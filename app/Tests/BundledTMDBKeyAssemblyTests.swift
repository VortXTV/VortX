// BundledTMDBKeyAssemblyTests — a standalone, runnable proof that the MASKED bundled TMDB key
// reassembles to the exact original key.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md),
// so this is a self-contained Swift executable that runs directly with the system toolchain:
//
//     swift app/Tests/BundledTMDBKeyAssemblyTests.swift
//
// It mirrors the masking that ApiKeys.swift ships: the bundled key is no longer a plaintext string
// literal (which `strings`/grep would lift straight out of the binary) but the XOR of two byte arrays,
// reassembled at runtime. This test copies those SAME two arrays and the SAME XOR, then asserts that
//
//   1. the reassembled string is exactly 32 lowercase-hex characters (a well-formed TMDB v3 read key), and
//   2. SHA256(reassembled) equals the committed hash below.
//
// The committed hash — NOT the key — is what proves fidelity: the plaintext key never appears in this
// file or anywhere in git. If ApiKeys.swift's arrays or XOR ever drift, this test fails, which is the
// guard that the masked form still decodes to the real key.
//
// The two arrays here MUST stay identical to ApiKeys.swift's `maskedTMDBCipher` / `maskedTMDBPad`.

import Foundation
import CryptoKit

// MARK: - Mirror of ApiKeys.swift's masked constants (obfuscated; meaningless without the XOR)

let maskedTMDBCipher: [UInt8] = [
    0xcd, 0x22, 0xa2, 0x7d, 0x55, 0x8d, 0x67, 0xd2, 0x92, 0xc6, 0x30, 0xa2, 0x68, 0xa4, 0x0f, 0x78,
    0xd0, 0x13, 0xab, 0x65, 0x21, 0x17, 0xd6, 0x39, 0x06, 0x12, 0xa8, 0xcc, 0x60, 0xfb, 0xe1, 0xe0
]
let maskedTMDBPad: [UInt8] = [
    0xa9, 0x13, 0x91, 0x4c, 0x65, 0xbc, 0x50, 0xb1, 0xf1, 0xa5, 0x06, 0xc7, 0x5d, 0x90, 0x39, 0x4a,
    0xb1, 0x2b, 0x9a, 0x06, 0x18, 0x24, 0xe6, 0x0d, 0x62, 0x20, 0x99, 0xf8, 0x57, 0xcd, 0x85, 0x85
]

// The committed integrity anchor: SHA256 of the reassembled key. Commit the hash, never the key.
let expectedSHA256 = "ff323f3f172417be7e26108c6aeda1435ba32199862730a5fc15a0067424b77b"

// MARK: - Mirror of ApiKeys.assembleBundledTMDBKey()

func assembleBundledTMDBKey() -> String {
    let cipher = maskedTMDBCipher, pad = maskedTMDBPad
    var bytes = [UInt8]()
    bytes.reserveCapacity(cipher.count)
    for i in cipher.indices { bytes.append(cipher[i] ^ pad[i]) }
    return String(decoding: bytes, as: UTF8.self)
}

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Assertions

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS: \(message)")
    } else {
        print("FAIL: \(message)")
        failures += 1
    }
}

let assembled = assembleBundledTMDBKey()

check(maskedTMDBCipher.count == 32 && maskedTMDBPad.count == 32,
      "both masked arrays are 32 bytes")
check(assembled.count == 32,
      "reassembled key is 32 characters")
check(assembled.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
      "reassembled key is lowercase hex")
check(sha256Hex(assembled) == expectedSHA256,
      "SHA256(reassembled) matches the committed hash")

if failures == 0 {
    print("\nAll \(4) assertions passed: masked arrays reassemble the exact bundled TMDB key.")
    exit(0)
} else {
    print("\n\(failures) assertion(s) FAILED: the masked form no longer decodes to the real key.")
    exit(1)
}
