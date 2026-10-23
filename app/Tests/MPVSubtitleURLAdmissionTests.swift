import Foundation

// The runner extracts the production prefilter. Passing it does NOT bypass PinnedHTTPClient's
// HTTPS, resolved-address, TLS, redirect and response-budget checks. No DNS or sockets in this test.
@main
enum MPVSubtitleURLAdmissionTests {
    static func main() {
        let cases: [(String, Bool)] = [
            ("https://fctv.example/sub.srt", true),
            ("https://fd-subtitles.example/sub.srt", true),
            ("https://FCTV.example/sub.srt", true),
            ("https://captions.example/sub.srt", true),
            ("https://[fc00::1]/sub.srt", false),
            ("https://[fd12:3456::1]/sub.srt", false),
            ("https://[::1]/sub.srt", false),
            ("https://127.0.0.1/sub.srt", false),
            ("https://10.0.0.1/sub.srt", false),
            ("https://192.168.1.2/sub.srt", false),
            ("https://172.16.0.1/sub.srt", false),
            ("https://169.254.169.254/sub.srt", false),
            ("https://localhost/sub.srt", false),
            ("https://user:pass@captions.example/sub.srt", false),
            ("file:///captions.srt", false),
            ("ftp://captions.example/sub.srt", false),
        ]
        for (raw, expected) in cases {
            precondition(MPVSubtitleAdmission.acceptsExternalSubtitleURL(URL(string: raw)!) == expected, raw)
        }
        print("PASS MPV subtitle URL prefilter: \(cases.count) actual-source checks, pinned transport unchanged")
    }
}
