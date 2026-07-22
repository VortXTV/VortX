import Foundation

// =============================================================================
// fMP4 media-segment inspection for contract (2): does the segment's FIRST
// sample start on an IDR (sync) frame?
//
// In an ISO-BMFF fragmented segment the sync status of sample 0 comes from the
// `moof > traf` boxes, in this precedence:
//   1. `trun` first-sample-flags   (trun flag 0x000004)  - the movenc path for a
//      cleanly-cut fragment stamps sample 0 here.
//   2. `trun` per-sample sample-flags (trun flag 0x000400) - first record.
//   3. `tfhd` default-sample-flags (tfhd flag 0x000020).
// A sample is a sync sample when `sample_is_non_sync_sample` (bit 0x00010000 of
// the 32-bit sample_flags word) is 0. A hard-cut fragment that begins mid-GOP
// stamps sample 0 with that bit SET, which is exactly the violation.
//
// Only the header boxes are needed, so this reads the first moof without ever
// materialising the mdat.
// =============================================================================

enum FMP4 {

    /// nil when sample-0 sync status cannot be determined from the segment alone
    /// (no flags in trun or tfhd - would require the moov `trex` defaults), OR when the
    /// video traf cannot be resolved.
    ///
    /// `videoTrackID` MUST identify the video track (resolved from the init segment's moov
    /// via `videoTrackID(inInit:)`). We select the `traf` whose `tfhd.track_ID` matches, and
    /// NEVER default to the first traf: a multi-track fragment that carries audio first would
    /// otherwise false-pass the video IDR check against the audio track. When the track cannot
    /// be identified (nil id, or no matching traf), we fail SAFE to nil (indeterminate) rather
    /// than inspect the wrong track. A single unnamed track is still resolvable when its lone
    /// traf matches the id.
    static func firstSampleIsSync(_ data: Data, videoTrackID: UInt32?) -> Bool? {
        guard let moof = topLevelBox(named: "moof", in: data, from: data.startIndex) else { return nil }
        guard let videoTrackID else { return nil }
        guard let traf = trafForTrack(videoTrackID, inMoof: moof, of: data) else { return nil }

        var defaultSampleFlags: UInt32?
        if let tfhd = childBox(named: "tfhd", inContainer: traf, of: data) {
            defaultSampleFlags = tfhdDefaultSampleFlags(tfhd, of: data)
        }
        guard let trun = childBox(named: "trun", inContainer: traf, of: data) else {
            return defaultSampleFlags.map(isSync)
        }
        if let first = trunFirstSampleFlags(trun, of: data) { return isSync(first) }
        if let perSample0 = trunFirstPerSampleFlags(trun, of: data) { return isSync(perSample0) }
        return defaultSampleFlags.map(isSync)
    }

    /// The `traf` whose `tfhd.track_ID` matches `trackID`, iterating ALL traf boxes in the moof
    /// (not just the first). tfhd payload is version/flags(4) then track_ID(4).
    private static func trafForTrack(_ trackID: UInt32, inMoof moof: Range<Data.Index>, of d: Data) -> Range<Data.Index>? {
        var i = moof.lowerBound
        while let (box, next) = nextBox(d, i, moof.upperBound) {
            if box.type == "traf",
               let tfhd = childBox(named: "tfhd", inContainer: box.payload, of: d),
               tfhd.count >= 8,
               be32(d, tfhd.lowerBound + 4) == trackID {
                return box.payload
            }
            i = next
        }
        return nil
    }

    /// Resolve the video track's track_ID from an init segment's moov: the `trak` whose
    /// `mdia > hdlr` handler_type is 'vide', reading its `tkhd` track_ID.
    static func videoTrackID(inInit data: Data) -> UInt32? {
        guard let moov = topLevelBox(named: "moov", in: data, from: data.startIndex) else { return nil }
        var i = moov.lowerBound
        while let (box, next) = nextBox(data, i, moov.upperBound) {
            if box.type == "trak",
               let mdia = childBox(named: "mdia", inContainer: box.payload, of: data),
               let hdlr = childBox(named: "hdlr", inContainer: mdia, of: data),
               hdlr.count >= 12,
               String(bytes: data[(hdlr.lowerBound + 8) ..< (hdlr.lowerBound + 12)], encoding: .ascii) == "vide",
               let tkhd = childBox(named: "tkhd", inContainer: box.payload, of: data),
               tkhd.count >= 1 {
                let version = data[tkhd.lowerBound]
                let idOffset = tkhd.lowerBound + 4 + (version == 1 ? 16 : 8)   // vf(4) + [creation+mod: 16 v1 / 8 v0]
                if idOffset + 4 <= tkhd.upperBound { return be32(data, idOffset) }
            }
            i = next
        }
        return nil
    }

    /// sample_is_non_sync_sample is bit 16 of the sample_flags word (ISO 14496-12).
    static func isSync(_ flags: UInt32) -> Bool { (flags & 0x0001_0000) == 0 }

    // MARK: - Minimal box walker (32-bit sizes; `size == 1` 64-bit form handled)

    struct Box { let type: String; let payload: Range<Data.Index> }

    private static func be32(_ d: Data, _ i: Data.Index) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
    private static func be64(_ d: Data, _ i: Data.Index) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(d[i + $1]) }
    }

    /// Iterate boxes in [start, end). Returns (type, payloadRange, nextIndex).
    private static func nextBox(_ d: Data, _ start: Data.Index, _ end: Data.Index) -> (Box, Data.Index)? {
        guard start + 8 <= end else { return nil }
        var size = Int(be32(d, start))
        let type = String(bytes: d[start + 4 ..< start + 8], encoding: .ascii) ?? "????"
        var headerLen = 8
        if size == 1 {
            guard start + 16 <= end else { return nil }
            size = Int(be64(d, start + 8))
            headerLen = 16
        } else if size == 0 {
            size = end - start   // box extends to end
        }
        guard size >= headerLen, start + size <= end else { return nil }
        let payload = (start + headerLen) ..< (start + size)
        return (Box(type: type, payload: payload), start + size)
    }

    private static func topLevelBox(named name: String, in d: Data, from: Data.Index) -> Range<Data.Index>? {
        var i = from
        while let (box, next) = nextBox(d, i, d.endIndex) {
            if box.type == name { return box.payload }
            i = next
        }
        return nil
    }

    private static func childBox(named name: String, inContainer c: Range<Data.Index>, of d: Data) -> Range<Data.Index>? {
        var i = c.lowerBound
        while let (box, next) = nextBox(d, i, c.upperBound) {
            if box.type == name { return box.payload }
            i = next
        }
        return nil
    }

    // MARK: - Field extraction

    private static func tfhdDefaultSampleFlags(_ p: Range<Data.Index>, of d: Data) -> UInt32? {
        guard p.count >= 8 else { return nil }
        let flags = be32(d, p.lowerBound) & 0x00FF_FFFF
        var cur = p.lowerBound + 8   // version/flags(4) + track_ID(4)
        if flags & 0x0000_0001 != 0 { cur += 8 }   // base-data-offset
        if flags & 0x0000_0002 != 0 { cur += 4 }   // sample-description-index
        if flags & 0x0000_0008 != 0 { cur += 4 }   // default-sample-duration
        if flags & 0x0000_0010 != 0 { cur += 4 }   // default-sample-size
        guard flags & 0x0000_0020 != 0, cur + 4 <= p.upperBound else { return nil }
        return be32(d, cur)                          // default-sample-flags
    }

    private static func trunFirstSampleFlags(_ p: Range<Data.Index>, of d: Data) -> UInt32? {
        guard p.count >= 8 else { return nil }
        let flags = be32(d, p.lowerBound) & 0x00FF_FFFF
        guard flags & 0x0000_0004 != 0 else { return nil }   // first-sample-flags-present
        var cur = p.lowerBound + 8                             // version/flags(4) + sample_count(4)
        if flags & 0x0000_0001 != 0 { cur += 4 }              // data-offset
        guard cur + 4 <= p.upperBound else { return nil }
        return be32(d, cur)
    }

    private static func trunFirstPerSampleFlags(_ p: Range<Data.Index>, of d: Data) -> UInt32? {
        guard p.count >= 8 else { return nil }
        let flags = be32(d, p.lowerBound) & 0x00FF_FFFF
        guard flags & 0x0000_0400 != 0 else { return nil }    // sample-flags-present
        var cur = p.lowerBound + 8
        if flags & 0x0000_0001 != 0 { cur += 4 }              // data-offset
        if flags & 0x0000_0004 != 0 { cur += 4 }              // first-sample-flags (rare with per-sample)
        // First sample record: duration? size? then flags?
        if flags & 0x0000_0100 != 0 { cur += 4 }              // sample-duration
        if flags & 0x0000_0200 != 0 { cur += 4 }              // sample-size
        guard cur + 4 <= p.upperBound else { return nil }
        return be32(d, cur)                                    // sample-flags
    }

    // MARK: - Synthetic segments (self-test fixtures)

    /// Build a minimal moof whose sole trun stamps sample 0 with first-sample-flags
    /// marking it sync or non-sync. Enough for the parser self-test; not a full
    /// playable segment.
    static func syntheticSegment(firstSampleSync: Bool) -> Data {
        let sampleFlags: UInt32 = firstSampleSync ? 0x0200_0000 /* depends-on=2 */ : 0x0201_0000 /* +non_sync */
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + payload.count)
            return [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
                + Array(type.utf8) + payload
        }
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let mfhd = box("mfhd", be(0) + be(1))
        let tfhd = box("tfhd", be(0x0000_0000) + be(1))                   // no default-sample-flags
        // trun: flags = data-offset(0x1) + first-sample-flags(0x4); sample_count=1; data_offset=0; first_sample_flags
        let trun = box("trun", be(0x0000_0005) + be(1) + be(0) + be(sampleFlags))
        let traf = box("traf", tfhd + trun)
        let moof = box("moof", mfhd + traf)
        let mdat = box("mdat", [0x00, 0x00, 0x00, 0x00])
        return Data(moof + mdat)
    }
}
