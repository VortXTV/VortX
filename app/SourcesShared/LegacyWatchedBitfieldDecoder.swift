import Foundation
import zlib

/// Strict decoder for Stremio's legacy `{anchor}:{anchorLength}:{base64-zlib}` episode bitmap.
///
/// Callers must supply the exact, authenticated source inventory. This decoder deliberately does
/// not create history clocks, infer an unwatch, or substitute an empty bitmap when evidence is
/// malformed or incomplete.
struct LegacyWatchedBitfieldEpisode: Hashable, Decodable {
    let id: String
    let season: Int
    let episode: Int
    let releasedMs: Int64?
}

enum LegacyWatchedBitfieldDecoder {
    private static let maximumInventory = 10_000
    private static let maximumCompressedBytes = 64 * 1024
    private static let maximumEncodedBytes = 87_384 // base64 ceiling for maximumCompressedBytes
    private static let maximumDecompressedBytes = 16 * 1024
    private static let maximumAnchorBytes = 4 * 1024
    private static let maximumSerializedBytes = maximumAnchorBytes + maximumEncodedBytes + 32

    /// IDs retain their exact UTF-8 source spelling and legacy inventory order.
    static func decode(serialized: String, inventory: [LegacyWatchedBitfieldEpisode]) throws -> [String] {
        try validate(inventory)
        let field = try parse(serialized)
        let bytes = try inflate(field.payload)
        guard field.anchorLength <= bytes.count * 8 else { throw failure("Anchor length exceeds bitmap") }
        let anchorKey = opaqueKey(field.anchor)
        let anchorMatches = inventory.indices.filter { opaqueKey(inventory[$0].id) == anchorKey }
        guard anchorMatches.count == 1 else { throw failure("Anchor is absent or ambiguous") }
        let anchorIndex = anchorMatches[0]
        guard bit(bytes, field.anchorLength - 1) else { throw failure("Anchor does not identify a watched bit") }

        let offset = Int64(field.anchorLength) - Int64(anchorIndex) - 1
        var watched = [String]()
        var watchedKeys = Set<Data>()
        for sourceIndex in 0..<(bytes.count * 8) where bit(bytes, sourceIndex) {
            guard sourceIndex < field.anchorLength else { throw failure("Bitmap has a watched bit after its anchor") }
            let inventoryIndex = Int64(sourceIndex) - offset
            guard inventoryIndex >= 0, inventoryIndex < Int64(inventory.count) else {
                throw failure("Bitmap would drop a watched video outside the supplied inventory")
            }
            let id = inventory[Int(inventoryIndex)].id
            if watchedKeys.insert(opaqueKey(id)).inserted { watched.append(id) }
        }
        return watched
    }

    private static func validate(_ inventory: [LegacyWatchedBitfieldEpisode]) throws {
        guard !inventory.isEmpty, inventory.count <= maximumInventory else { throw failure("Invalid inventory size") }
        var ids = Set<Data>()
        var coordinates = Set<Coordinate>()
        for episode in inventory {
            guard !episode.id.isEmpty, episode.season >= 0, episode.episode >= 0 else { throw failure("Invalid episode inventory") }
            guard ids.insert(opaqueKey(episode.id)).inserted else { throw failure("Duplicate video identifier") }
            guard coordinates.insert(Coordinate(season: episode.season, episode: episode.episode, releasedMs: episode.releasedMs)).inserted else {
                throw failure("Ambiguous episode coordinates")
            }
        }
        let sorted = inventory.sorted { lhs, rhs in
            if lhs.season != rhs.season { return lhs.season < rhs.season }
            if lhs.episode != rhs.episode { return lhs.episode < rhs.episode }
            return releasedPrecedes(lhs.releasedMs, rhs.releasedMs)
        }
        guard zip(sorted, inventory).allSatisfy({ exactEpisode($0, $1) }) else { throw failure("Inventory is not in exact legacy episode order") }
    }

    private static func parse(_ serialized: String) throws -> (anchor: String, anchorLength: Int, payload: Data) {
        guard serialized.utf8.count <= maximumSerializedBytes else { throw failure("Watched bitmap frame exceeds limit") }
        guard let payloadSeparator = serialized.lastIndex(of: ":") else { throw failure("Bitmap has no payload") }
        let payloadString = String(serialized[serialized.index(after: payloadSeparator)...])
        let prefix = String(serialized[..<payloadSeparator])
        guard let lengthSeparator = prefix.lastIndex(of: ":") else { throw failure("Bitmap has no anchor length") }
        let anchor = String(prefix[..<lengthSeparator])
        let lengthString = String(prefix[prefix.index(after: lengthSeparator)...])
        guard !anchor.isEmpty, anchor.utf8.count <= maximumAnchorBytes,
              !payloadString.isEmpty, payloadString.utf8.count <= maximumEncodedBytes,
              lengthString.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let anchorLength = Int(lengthString), anchorLength > 0,
              anchorLength <= maximumDecompressedBytes * 8 else { throw failure("Malformed watched bitmap") }
        guard let payload = Data(base64Encoded: payloadString), payload.count <= maximumCompressedBytes,
              payload.base64EncodedString() == payloadString else { throw failure("Malformed base64 bitmap") }
        return (anchor, anchorLength, payload)
    }

    private static func inflate(_ compressed: Data) throws -> [UInt8] {
        try compressed.withUnsafeBytes { raw in
            guard let input = raw.bindMemory(to: Bytef.self).baseAddress else { throw failure("Empty compressed bitmap") }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(compressed.count)
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw failure("Cannot initialize bitmap inflater")
            }
            defer { inflateEnd(&stream) }
            var output = [UInt8]()
            var status: Int32 = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: 1024)
                status = chunk.withUnsafeMutableBytes { target in
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                guard output.count + produced <= maximumDecompressedBytes else { throw failure("Bitmap exceeds decompressed limit") }
                output.append(contentsOf: chunk.prefix(produced))
                guard status == Z_OK || status == Z_STREAM_END else { throw failure("Truncated or malformed zlib bitmap") }
                guard produced > 0 || status == Z_STREAM_END else { throw failure("Truncated zlib bitmap") }
            } while status != Z_STREAM_END
            guard stream.avail_in == 0 else { throw failure("Bitmap has trailing compressed data") }
            return output
        }
    }

    private static func bit(_ bytes: [UInt8], _ index: Int) -> Bool {
        (bytes[index / 8] & (1 << UInt8(index % 8))) != 0
    }

    private static func opaqueKey(_ value: String) -> Data { Data(value.utf8) }
    private static func releasedPrecedes(_ lhs: Int64?, _ rhs: Int64?) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): return true
        case (.some, nil), (nil, nil): return false
        case let (.some(left), .some(right)): return left < right
        }
    }
    private static func exactEpisode(_ lhs: LegacyWatchedBitfieldEpisode, _ rhs: LegacyWatchedBitfieldEpisode) -> Bool {
        opaqueKey(lhs.id) == opaqueKey(rhs.id) && lhs.season == rhs.season && lhs.episode == rhs.episode && lhs.releasedMs == rhs.releasedMs
    }

    private struct Coordinate: Hashable { let season: Int; let episode: Int; let releasedMs: Int64? }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LegacyWatchedBitfieldDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
