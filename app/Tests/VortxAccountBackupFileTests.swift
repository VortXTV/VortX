import Foundation
import CryptoKit

@MainActor
@main enum VortxAccountBackupFileTests {
    private static var count = 0
    private static func check(_ name: String, _ value: Bool) {
        guard value else { fatalError("FAIL: " + name) }
        count += 1
        print("PASS: " + name)
    }
    private static func refuses(_ text: String, _ expected: VortxAccountBackupFile.Failure) {
        do {
            _ = try VortxAccountBackupFile.inspect(Data(text.utf8))
            fatalError("FAIL: invalid file admitted")
        } catch {
            check("refuses " + String(describing: expected), (error as? VortxAccountBackupFile.Failure) == expected)
        }
    }
    static func main() throws {
        let key = Data(repeating: 7, count: 32)
        let account = "fixture-account"
        let plaintext = Data(#"{ "future":9007199254740993, "profiles":[], "addon":"https://fixture.invalid/private-config" }"#.utf8)
        for versionBound in [false, true] {
            let encrypted = VortXSyncCrypto.sealDocument(dataKey: key, plaintext: plaintext,
                accountId: account, version: 42, writeV2: versionBound)!
            let exported = try VortxAccountBackupFile.encode(document: encrypted, version: 42,
                username: "fixture", now: Date(timeIntervalSince1970: 1000))
            let file = try VortxAccountBackupFile.inspect(exported)
            check("ciphertext retained exactly", file.document == encrypted)
            check("revision retained exactly", file.version == 42)
            check("source file retained exactly", file.original == exported)
            check("encryption label is inspection only", file.usesVersionBoundEncryption == versionBound)
            check("original authenticated plaintext conserved", VortXSyncCrypto.openDocument(dataKey: key,
                stored: file.document, accountId: account, version: file.version) == plaintext)
            check("wrong key still fails authentication", VortXSyncCrypto.openDocument(dataKey: Data(repeating: 8, count: 32),
                stored: file.document, accountId: account, version: file.version) == nil)
            if versionBound {
                check("wrong account still fails authentication", VortXSyncCrypto.openDocument(dataKey: key,
                    stored: file.document, accountId: "other", version: file.version) == nil)
                check("wrong revision still fails authentication", VortXSyncCrypto.openDocument(dataKey: key,
                    stored: file.document, accountId: account, version: 43) == nil)
            }
        }
        let ciphertext = Data(repeating: 0, count: 28).base64EncodedString()
        let exact = #"{ "vortxBackup":1,"document":""# + ciphertext + #"","version":42,"future":{"n":9007199254740993,"label":"秘密"} }"#
        let source = Data(exact.utf8)
        let inspected = try VortxAccountBackupFile.inspect(source)
        check("unknown metadata and numeric spelling conserved", inspected.original == source)
        check("digest binds original bytes", inspected.sourceSHA256 == SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined())
        let largest = try VortxAccountBackupFile.encode(document: ciphertext, version: 9_007_199_254_740_991,
            username: "fixture")
        check("largest safe revision remains downloadable", try VortxAccountBackupFile.inspect(largest).version == 9_007_199_254_740_991)
        for revision in ["-1", "1.0", "1e0", "true", "9007199254740992", "999999999999999999999999999999"] {
            let text = #"{"vortxBackup":1,"document":""# + ciphertext + #"","version":"# + revision + "}"
            do {
                _ = try VortxAccountBackupFile.inspect(Data(text.utf8))
                fatalError("FAIL: noncanonical or excessive revision admitted")
            } catch { check("noncanonical/excessive revision refused", error is VortxAccountBackupFile.Failure) }
        }
        refuses(#"{"vortxBackup":2,"document":""# + ciphertext + #"","version":42}"#, .unsupportedFormat)
        refuses(#"{"format":"vortx-backup","schema":1,"payloadBase64":"AA=="}"#, .wrongFormat)
        refuses(#"{"vortxBackup":1,"document":""# + ciphertext + #"","version":1,"\u0076ersion":2}"#, .damaged)
        refuses(exact + "{}", .damaged)
        refuses(#"{"vortxBackup":1,"document":"v3.AAAA","version":42}"#, .unsupportedFormat)
        refuses(#"{"vortxBackup":1,"document":"not-base64","version":42}"#, .damaged)
        refuses(#"{"vortxBackup":1,"document":"AA==","version":42}"#, .damaged)
        for response in [
            #"{"document":""# + ciphertext + #"","version":1,"version":2}"#,
            #"{"document":""# + ciphertext + #"","version":1.00000000000000000001}"#,
            #"{"document":""# + ciphertext + #"","version":true}"#,
        ] {
            do {
                _ = try VortxAccountBackupFile.encodeServerResponse(Data(response.utf8), username: "fixture")
                fatalError("FAIL: ambiguous response admitted")
            } catch { check("actual response lexeme refused", (error as? VortxAccountBackupFile.Failure) == .damaged) }
        }
        do {
            _ = try VortxAccountBackupFile.inspect(Data(repeating: 32, count: VortxAccountBackupFile.maximumFileBytes + 1))
            fatalError("FAIL: oversized source admitted")
        } catch { check("oversize refused before parsing", (error as? VortxAccountBackupFile.Failure) == .tooLarge) }
        print("PASS: \(count) account-backup file checks")
    }
}
