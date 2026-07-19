import Foundation
import CoreMedia
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

// ATTRIBUTION (licence-relevant, do not strip):
// - The hardware-tier gate below (VortXDirectDVDeviceTier) is TAKEN, with renames and comment rewrites,
//   from prehakanson-art/NuvioTVAppleTV (GPL-3.0), NuvioTV/Core/PerformanceProfile.swift: the AppleTV5/
//   AppleTV6 machine-prefix tiers, the 2.5 GB / 3.5 GB physicalMemory fallbacks, and the rule that the
//   dual-layer Profile 7 conversion should default ON only on boxes above those tiers. VortX is GPL-3.0,
//   so the incorporation is licence-compatible; this notice preserves provenance per GPLv3 section 5.
// - The extensions-dictionary shape handed to CMVideoFormatDescriptionCreate (sample-description
//   extension atoms + colorimetry keys read off AVCodecParameters) follows the pattern in
//   kingslay/KSPlayer (GPL-3.0), Sources/KSPlayer/MEPlayer/FFmpegAssetTrack.swift. The Dolby Vision
//   configuration atom (dvcC/dvvC) added alongside hvcC is OUR addition: upstream KSPlayer does not
//   attach the DOVI record to the format description (and on tvOS it explicitly demotes DV display
//   criteria to HDR10 in KSOptions.updateVideo), which is exactly why its decoded-pixel path cannot
//   emit true Dolby Vision there.

/// Builders for the CoreMedia format descriptions the DIRECT Dolby Vision lane feeds to
/// AVSampleBufferDisplayLayer / AVSampleBufferAudioRenderer, plus the device-tier defaults.
///
/// Why this lane exists: the remux lane reaches Apple's pipeline through an HLS master playlist, and a
/// master playlist carries declarations (SUPPLEMENTAL-CODECS media-profile brands) that CoreMedia
/// cross-checks against the served init segment; a mismatch is CoreMediaErrorDomain -12927. The direct
/// lane hands compressed HEVC access units straight to the sample-buffer pipeline with the Dolby Vision
/// configuration carried IN the CMVideoFormatDescription. There is no playlist and no declaration, so
/// the -12927 class of failure cannot exist here by construction.
enum VortXDirectDVFormat {

    /// The subset of an AVDOVIDecoderConfigurationRecord the atom serializer needs. Plain value type so
    /// callers can relabel (P7 -> 8.1) without touching libav memory.
    struct DoViConfig {
        var profile: Int
        var level: Int
        var rpuPresent: Bool
        var elPresent: Bool
        var blPresent: Bool
        var blSignalCompatibilityId: Int
    }

    /// Read the container Dolby Vision configuration off a codecpar, if present.
    static func doviConfig(from par: UnsafeMutablePointer<AVCodecParameters>) -> DoViConfig? {
        let n = Int(par.pointee.nb_coded_side_data)
        guard n > 0, let arr = par.pointee.coded_side_data else { return nil }
        for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF {
            guard let data = arr[i].data,
                  Int(arr[i].size) >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return nil }
            return data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { r in
                DoViConfig(profile: Int(r.pointee.dv_profile),
                           level: Int(r.pointee.dv_level),
                           rpuPresent: r.pointee.rpu_present_flag != 0,
                           elPresent: r.pointee.el_present_flag != 0,
                           blPresent: r.pointee.bl_present_flag != 0,
                           blSignalCompatibilityId: Int(r.pointee.dv_bl_signal_compatibility_id))
            }
        }
        return nil
    }

    /// Serialize a DOVI configuration to the 24-byte dvcC/dvvC atom payload (ISO/IEC 14496-12 Dolby
    /// Vision box, the same layout FFmpeg's movenc writes): version 1.0, then
    /// 16 bits = profile(7) level(6) rpu(1) el(1) bl(1), then 32 bits = compatibility id << 28,
    /// then four reserved 32-bit zeros. The atom NAME is dvvC for profile > 7 and dvcC otherwise
    /// (movenc's rule; Profile 5 rides dvcC, Profile 8.x rides dvvC).
    static func serializeDoViAtom(_ c: DoViConfig) -> (name: String, payload: Data) {
        var b = [UInt8](repeating: 0, count: 24)
        b[0] = 1   // dv_version_major
        b[1] = 0   // dv_version_minor
        let bits16 = (UInt16(c.profile & 0x7F) << 9)
            | (UInt16(c.level & 0x3F) << 3)
            | (c.rpuPresent ? 1 << 2 : 0)
            | (c.elPresent ? 1 << 1 : 0)
            | (c.blPresent ? 1 : 0)
        b[2] = UInt8(bits16 >> 8)
        b[3] = UInt8(bits16 & 0xFF)
        b[4] = UInt8((c.blSignalCompatibilityId & 0x0F) << 4)   // compat id in the top nibble of the 32-bit word
        return (c.profile > 7 ? "dvvC" : "dvcC", Data(b))
    }

    /// Build the compressed-video CMVideoFormatDescription for the direct lane: HEVC with the hvcC
    /// parameter sets out-of-band PLUS the Dolby Vision configuration atom, so VideoToolbox (inside the
    /// sample-buffer pipeline) selects its Dolby Vision decode path and the RPUs in the enqueued access
    /// units are consumed as dynamic metadata rather than discarded.
    ///
    /// Codec type mirrors the remux lane's sample-entry choice (and Apple authoring rule 1.10): Profile 5
    /// has no cross-compatible base layer, so it is typed 'dvh1' (kCMVideoCodecType_DolbyVisionHEVC);
    /// Profile 8.x (including a converted P7) keeps 'hvc1' with the dvvC atom alongside.
    ///
    /// Returns nil when the extradata is not a usable hvcC record; the caller fails fast and the chrome
    /// demotes to the remux lane, whose extradata repair can rebuild parameter sets from the bitstream.
    static func videoFormatDescription(par: UnsafeMutablePointer<AVCodecParameters>,
                                       dovi: DoViConfig) -> CMVideoFormatDescription? {
        guard let extradata = par.pointee.extradata else { return nil }
        let extraSize = Int(par.pointee.extradata_size)
        // A structurally plausible hvcC: version byte 1, long enough to carry the header + arrays.
        guard extraSize >= 23, extradata[0] == 1 else { return nil }
        let hvcC = Data(bytes: extradata, count: extraSize)
        let (atomName, doviPayload) = serializeDoViAtom(dovi)

        var atoms: [String: Any] = ["hvcC": hvcC]
        atoms[atomName] = doviPayload

        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
            // DV bitstreams are BT.2020; PQ transfer for every profile this lane accepts (5 / 8.1;
            // an 8.4/HLG source keeps its container-signalled transfer below). The VUI of a Profile 5
            // stream is routinely "unspecified", so these defaults are load-bearing there.
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        if par.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
        if par.pointee.color_range == AVCOL_RANGE_JPEG {
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = true
        }

        let codecType: CMVideoCodecType = dovi.profile == 5
            ? kCMVideoCodecType_DolbyVisionHEVC
            : kCMVideoCodecType_HEVC
        var out: CMVideoFormatDescription?
        let rc = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: par.pointee.width,
            height: par.pointee.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &out
        )
        guard rc == noErr else { return nil }
        return out
    }

    /// The audio codecs the direct lane passes through COMPRESSED to AVSampleBufferAudioRenderer (the
    /// system decodes or bitstreams them; E-AC-3 JOC keeps its Atmos signalling this way). Anything else
    /// fails the lane fast so the chrome demotes to the remux lane, which can transcode.
    enum PassthroughAudio {
        case eac3, ac3, aac

        init?(codecID: AVCodecID) {
            switch codecID {
            case AV_CODEC_ID_EAC3: self = .eac3
            case AV_CODEC_ID_AC3:  self = .ac3
            case AV_CODEC_ID_AAC:  self = .aac
            default: return nil
            }
        }

        var formatID: AudioFormatID {
            switch self {
            case .eac3: return kAudioFormatEnhancedAC3
            case .ac3:  return kAudioFormatAC3
            case .aac:  return kAudioFormatMPEG4AAC
            }
        }

        /// PCM frames per compressed packet (constant for all three codecs).
        var framesPerPacket: UInt32 {
            switch self {
            case .eac3, .ac3: return 1536
            case .aac:        return 1024
            }
        }

        /// Selection priority: Atmos-capable first (mirrors the remux lane's ranking).
        var score: Int {
            switch self {
            case .eac3: return 3
            case .ac3:  return 2
            case .aac:  return 1
            }
        }
    }

    /// Build the compressed-audio CMAudioFormatDescription. AAC needs its AudioSpecificConfig
    /// (the codecpar extradata) attached as the magic cookie; AC-3 / E-AC-3 are self-describing.
    static func audioFormatDescription(par: UnsafeMutablePointer<AVCodecParameters>,
                                       kind: PassthroughAudio) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(par.pointee.sample_rate),
            mFormatID: kind.formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: kind.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, par.pointee.ch_layout.nb_channels)),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var cookie: [UInt8] = []
        if kind == .aac, let extra = par.pointee.extradata, par.pointee.extradata_size > 0 {
            cookie = Array(UnsafeBufferPointer(start: extra, count: Int(par.pointee.extradata_size)))
        }
        var out: CMAudioFormatDescription?
        let rc = cookie.withUnsafeBytes { raw -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: cookie.isEmpty ? 0 : cookie.count,
                magicCookie: cookie.isEmpty ? nil : raw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &out
            )
        }
        guard rc == noErr else { return nil }
        return out
    }
}

/// Hardware-tier detection for the direct lane's Profile 7 default (see the attribution block at the top
/// of this file: taken from NuvioTVAppleTV's PerformanceProfile, GPL-3.0). The P7 conversion re-writes
/// every RPU NAL with libdovi while the stream downloads; the 2 GB Apple TV HD and the 3 GB first-gen
/// 4K cannot sustain that alongside decode without risking a jetsam kill, so P7 conversion on the DIRECT
/// lane defaults ON only above those tiers. The remux lane's shipped always-convert behavior is untouched.
enum VortXDirectDVDeviceTier {
    /// Machine identifier, e.g. "AppleTV5,3" (HD) or "AppleTV6,2" (4K 1st gen).
    static let machine: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    /// Apple TV HD (A8, 2 GB), or any unknown box under 2.5 GB.
    static let isLowPower: Bool = {
        if machine.hasPrefix("AppleTV5") { return true }
        return ProcessInfo.processInfo.physicalMemory < 2_500_000_000
    }()

    /// 4K first-gen (A10X, 3 GB), or any unknown box under 3.5 GB.
    static let isMidPower: Bool = {
        if isLowPower { return false }
        if machine.hasPrefix("AppleTV6") { return true }
        return ProcessInfo.processInfo.physicalMemory < 3_500_000_000
    }()

    /// Whether the direct lane's Profile 7 -> 8.1 conversion should default ON for this hardware.
    static var recommendsProfile7Conversion: Bool { !isLowPower && !isMidPower }

    /// Bounded in-RAM packet-queue budget for the direct lane, sized to the box (the direct lane's
    /// equivalent of the remux window): the demux thread BLOCKS when the queue is full, so memory use
    /// is capped by construction rather than by pacing heuristics.
    static var packetQueueByteBudget: Int {
        if isLowPower { return 24 << 20 }
        if isMidPower { return 40 << 20 }
        return 96 << 20
    }
}
