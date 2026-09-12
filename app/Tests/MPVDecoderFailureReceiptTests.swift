import Foundation

@main
enum MPVDecoderFailureReceiptTests {
    static func main() {
        let cases = [
            ("VideoToolbox session not available.\n", "vt-session-unavailable"),
            ("VideoToolbox does not support this format.", "vt-format-unsupported"),
            ("VideoToolbox decoder for this format not found.", "vt-decoder-not-found"),
            ("VideoToolbox malfunction.", "vt-malfunction"),
            ("VideoToolbox reported invalid data.", "vt-invalid-data"),
            ("Unknown VideoToolbox session creation error -12913", "vt-session-status=-12913"),
            ("Error while decoding frame (hardware decoding)!", "hw-frame-decode-error"),
            ("Codec profile: High (0x64)", "Codec profile: High (0x64)"),
            ("VideoToolbox decoder needs reconfig, restarting..", "vt-session-reconfiguration"),
            ("Waiting for keyframe after reinit (dropping frame).", "hw-waiting-for-keyframe"),
            ("vt decoder cb: output image buffer is null: -12909, reconfig 1", "vt-no-output-status=-12909 reconfig=1"),
            ("vt decoder cb: output image buffer is null: 0, reconfig 0", "vt-no-output-status=0 reconfig=0"),
            ("Failed to decode frame (bad data, -12909)", "vt-frame-status=-12909"),
        ]
        for (input, expected) in cases {
            precondition(MPVDecoderFailureReceipt.code(prefix: "ffmpeg/video", message: input) == expected)
            precondition(MPVDecoderFailureReceipt.code(prefix: "vd", message: input) == expected)
            precondition(MPVDecoderFailureReceipt.code(prefix: "stream", message: input) == nil)
            precondition(MPVDecoderFailureReceipt.code(prefix: "ffmpeg/video", message: "h264: " + input) == expected)
        }
        for unsafe in ["https://example.com/private?token=secret", "Authorization: Bearer secret",
                       "VideoToolbox session not available. https://example.com/secret",
                       "Codec profile: https://example.com (0x64)",
                       "Unknown VideoToolbox session creation error -12913 token=secret",
                       "vt decoder cb: output image buffer is null: -12909, reconfig 1 token=secret",
                       "vt decoder cb: output image buffer is null: -12909, reconfig 10",
                       "Failed to decode frame (https://example.com/private, -12909)",
                       String(repeating: "x", count: 2048)] {
            precondition(MPVDecoderFailureReceipt.code(prefix: "ffmpeg/video", message: unsafe) == nil)
        }
        print("PASS decoder failure receipts: \(cases.count * 4) category/prefix checks and 9 credential/privacy rejections")
    }
}
