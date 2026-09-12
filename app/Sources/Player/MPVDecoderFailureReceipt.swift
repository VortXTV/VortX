import Foundation

/// Decoder-only evidence, never raw libmpv messages: those can contain credentialed URLs/headers.
/// The phrases below are emitted by the pinned mpv vd_lavc.c and FFmpeg videotoolbox.c.
enum MPVDecoderFailureReceipt {
    static func code(prefix: String, message: String) -> String? {
        guard prefix == "vd" || prefix == "ffmpeg/video",
              message.utf8.count <= 1024 else { return nil }
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // mpv common/av_log.c prepends the AVCodecContext item name. Strip only known decoder names,
        // not an arbitrary prefix that could hide a URL/header in an otherwise allowlisted message.
        for codec in ["h264", "hevc", "av1", "vp9", "mpeg2video", "prores"] {
            if text.hasPrefix(codec + ": ") {
                text = String(text.dropFirst(codec.count + 2))
                break
            }
        }
        let known: [String: String] = [
            "VideoToolbox session not available.": "vt-session-unavailable",
            "VideoToolbox does not support this format.": "vt-format-unsupported",
            "VideoToolbox decoder for this format not found.": "vt-decoder-not-found",
            "VideoToolbox malfunction.": "vt-malfunction",
            "VideoToolbox reported invalid data.": "vt-invalid-data",
            "format description creation failed": "vt-format-description-failed",
            "decoder specification creation failed": "vt-specification-failed",
            "Could not create device.": "hw-device-creation-failed",
            "Error while decoding frame (hardware decoding)!": "hw-frame-decode-error",
            "Using software decoding.": "software-selected",
            "Falling back to software decoding.": "software-fallback",
            "VideoToolbox decoder needs reconfig, restarting..": "vt-session-reconfiguration",
            "Waiting for keyframe after reinit (dropping frame).": "hw-waiting-for-keyframe",
        ]
        if let code = known[text] { return code }
        // Distinguish a no-output callback from a session-creation error. Keep only the bounded
        // numeric status/reconfiguration flag, never a free-form decoder or source description.
        if text.range(of: #"^vt decoder cb: output image buffer is null: -?[0-9]{1,11}, reconfig [01]$"#,
                      options: .regularExpression) != nil {
            let fields = text.components(separatedBy: ": ").last!.components(separatedBy: ", reconfig ")
            return "vt-no-output-status=" + fields[0] + " reconfig=" + fields[1]
        }
        if text.range(of: #"^Failed to decode frame \((bad data|decoder malfunction|invalid session|unknown), -?[0-9]{1,11}\)$"#,
                      options: .regularExpression) != nil {
            return "vt-frame-status=" + text.components(separatedBy: ", ").last!.dropLast()
        }
        if let range = text.range(of: #"^Unknown VideoToolbox session creation error -?[0-9]{1,11}$"#,
                                  options: .regularExpression), range == text.startIndex..<text.endIndex {
            return "vt-session-status=" + (text.split(separator: " ").last.map(String.init) ?? "unknown")
        }
        // This is a bounded codec description, not arbitrary stream metadata or a URL.
        if text.range(of: #"^Codec profile: [A-Za-z0-9 _-]{1,64} \(0x[0-9a-fA-F]{1,8}\)$"#,
                      options: .regularExpression) != nil { return text }
        return nil
    }
}
