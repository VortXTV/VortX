import Foundation
import CryptoKit

/// The encrypted account export used by the VortX website. This is not a settings
/// export, a native checkpoint, or permission to replace the current account.
enum VortxAccountBackupFile {
    static let maximumFileBytes = 10 * 1024 * 1024
    static let maximumRevision = 9_007_199_254_740_991

    enum Failure: Error, LocalizedError, Equatable {
        case tooLarge, wrongFormat, unsupportedFormat, damaged, noBackup, sessionChanged, unavailable

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This backup exceeds this tool's 10 MB limit. Your original file is unchanged."
            case .wrongFormat: return "Choose a VortX account backup. Settings exports and device checkpoints are different files."
            case .unsupportedFormat: return "This backup uses a newer format that this version of VortX cannot repair. Your original file is unchanged."
            case .damaged: return "This backup could not be read safely. Your original file is unchanged."
            case .noBackup: return "This account does not have a cloud backup to download yet."
            case .sessionChanged: return "Your account changed. Open Tools again before continuing."
            case .unavailable: return "The backup could not be downloaded. Try again when your connection and sign-in are working."
            }
        }
    }

    struct Inspection: Sendable {
        /// Preserve the user's exact file, including future metadata and numeric spelling.
        let original: Data
        let sourceSHA256: String
        let document: String
        let version: Int
        let usesVersionBoundEncryption: Bool
    }

    private struct Header: Decodable {
        let vortxBackup: Int
        let document: String
        let version: Int
    }

    static func inspect(_ source: Data) throws -> Inspection {
        guard source.count <= maximumFileBytes else { throw Failure.tooLarge }
        // Reject duplicate keys and ambiguous encodings before decoding the header.
        // The remaining values stay in original bytes, rather than a lossy JSON round trip.
        let members: [VortxNativeBootstrapArchive.RawJSONMember]
        do {
            members = try VortxNativeBootstrapArchive.rawJSONObjectMembers(
                source, maximumBytes: maximumFileBytes)
        }
        catch { throw Failure.damaged }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: source) }
        catch { throw Failure.wrongFormat }
        guard header.vortxBackup == 1,
              members.first(where: { $0.key == "vortxBackup" })?.valueJSON == Data("1".utf8) else {
            throw Failure.unsupportedFormat
        }
        let revision = try revision(in: members)
        guard header.version == revision else { throw Failure.damaged }
        let versionBound = header.document.hasPrefix("v2.")
        if !versionBound, header.document.range(of: "^v[0-9]+\\.", options: .regularExpression) != nil {
            throw Failure.unsupportedFormat
        }
        let encoded = versionBound ? String(header.document.dropFirst(3)) : header.document
        guard let sealed = Data(base64Encoded: encoded), sealed.count >= 28,
              sealed.base64EncodedString() == encoded else { throw Failure.damaged }
        return Inspection(original: source,
            sourceSHA256: SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            document: header.document, version: header.version,
            usesVersionBoundEncryption: versionBound)
    }

    private static func revision(in members: [VortxNativeBootstrapArchive.RawJSONMember]) throws -> Int {
        guard let revisionBytes = members.first(where: { $0.key == "version" })?.valueJSON,
              let revisionText = String(data: revisionBytes, encoding: .utf8),
              revisionText.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
              let revision = Int(revisionText), revision <= maximumRevision else { throw Failure.damaged }
        return revision
    }

    /// Read the actual bounded HTTP response, before a dictionary decoder can collapse
    /// duplicate fields or round a fractional revision into an apparently valid integer.
    static func encodeServerResponse(_ source: Data, username: String, now: Date = Date()) throws -> Data {
        guard source.count <= maximumFileBytes else { throw Failure.tooLarge }
        let members: [VortxNativeBootstrapArchive.RawJSONMember]
        do {
            members = try VortxNativeBootstrapArchive.rawJSONObjectMembers(
                source, maximumBytes: maximumFileBytes)
        } catch { throw Failure.damaged }
        guard let documentJSON = members.first(where: { $0.key == "document" })?.valueJSON,
              let document = try? JSONDecoder().decode(String.self, from: documentJSON) else {
            throw Failure.damaged
        }
        return try encode(document: document, version: revision(in: members), username: username, now: now)
    }

    /// Wrap the untouched ciphertext returned by the authenticated account endpoint.
    /// Download does not acknowledge native receipts, change sync floors, or repair data.
    static func encode(document: String, version: Int, username: String, now: Date = Date()) throws -> Data {
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= Double(maximumRevision) else {
            throw Failure.damaged
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "vortxBackup": 1, "username": username, "exportedAt": Int(milliseconds),
            "document": document, "version": version,
        ], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        _ = try inspect(bytes)
        return bytes
    }
}
