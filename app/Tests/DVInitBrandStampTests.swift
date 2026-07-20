// DVInitBrandStampTests: byte-level regression guard for the -12927 Dolby Vision init-segment fix.
//
// WHAT THIS GUARDS. The DV remux master playlist declares SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p"
// (or db4h), but FFmpeg's movenc cannot write the Dolby Vision CMAF media-profile brand into the
// init segment's ftyp: it writes exactly [iso5(major), iso5, iso6, dby1, mp41] (32 bytes). tvOS
// AVPlayer cross-checks the DECLARATION against the CONTENT and rejects the mismatch with
// CoreMediaErrorDomain -12927 (54 occurrences in one b182 reporter log), silently degrading DV to
// HDR10. The #143 fix rewrites the SERVED copies in VortXMKVRemuxStream.hlsFinalizeInit:
//   - /init.mp4     (DV variant):      appendFtypCompatibleBrand stamps the declared brand into ftyp
//   - /init-hdr.mp4 (lifeboat variant): stripDoViConfigBox removes the dvvC/dvcC the variant denies
// This test pins BOTH transforms byte-for-byte so the fix can never regress silently again.
//
// HOW IT TESTS THE REAL CODE (not a mirror). VortX's Apple app has no Xcode unit-test bundle, and
// the remux file imports Libavformat, which a bare toolchain cannot link. But the two functions
// under test are pure Foundation byte surgery, so this script EXTRACTS THEIR REAL SOURCE TEXT from
// app/Sources/Player/VortXMKVRemuxStream.swift (brace-matched, all five members: be32, putBE32,
// fourccAt, appendFtypCompatibleBrand, stripDoViConfigBox), wraps them in an enum, and runs them
// with the system toolchain against REAL CAPTURED FIXTURES. Any edit to the shipped functions is
// therefore what gets tested. If extraction fails (rename / move), this test FAILS loudly; update
// the signatures list below, never weaken it to a skip.
//
// FIXTURES. Captured 2026-07-17 from an off-device run of the REAL remux pipeline on macOS:
// VortXMKVRemuxStream (HLS lane) built against the app's exact pinned libavformat (MPVKit
// 0.41.0-n8.1.2, libavformat 62.12.102) remuxing a local MKV that carries a genuine DOVI
// configuration record (profile 8, bl compat id 1; x265 Main10 PQ video + AC3 audio).
//   rawInit   = movenc's untouched ftyp+moov output (what the pre-fix code served, ftyp 32B, no db1p)
//   servedDV  = the published /init.mp4 bytes  (ftyp 36B, db1p appended, size field patched)
//   servedHDR = the published /init-hdr.mp4 bytes (dvvC stripped, ancestor sizes fixed)
// The raw fixture is self-checked against the documented movenc shape before any assertion.
//
// RUN:              swift app/Tests/DVInitBrandStampTests.swift
// NEGATIVE CONTROL: point the extractor at a scratch copy whose stamping is broken and the test
// must FAIL (this was executed when the test landed, deleting the b.insert line: FAILED as
// required; re-run it after any change to this test):
//   cp app/Sources/Player/VortXMKVRemuxStream.swift /tmp/neutered.swift
//   (break appendFtypCompatibleBrand in /tmp/neutered.swift, e.g. delete the b.insert line)
//   VORTX_REMUX_SOURCE=/tmp/neutered.swift swift app/Tests/DVInitBrandStampTests.swift  # must fail

import Foundation

// MARK: - Locate the real source file

let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultSource = testDir.deletingLastPathComponent()
    .appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift")
let sourcePath = ProcessInfo.processInfo.environment["VORTX_REMUX_SOURCE"] ?? defaultSource.path

guard let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
    print("FAIL: cannot read \(sourcePath)")
    exit(1)
}
print("source under test: \(sourcePath)")

// MARK: - Extract the real members (brace-matched; a miss is a hard FAIL, never a skip)

func extractMember(signature: String, from text: String) -> String? {
    guard let sigRange = text.range(of: signature) else { return nil }
    // Start of the signature's line.
    let lineStart = text[..<sigRange.lowerBound].lastIndex(of: "\n").map(text.index(after:))
        ?? text.startIndex
    guard let braceStart = text[sigRange.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var i = braceStart
    while i < text.endIndex {
        let c = text[i]
        if c == "{" { depth += 1 }
        if c == "}" {
            depth -= 1
            if depth == 0 { return String(text[lineStart...i]) }
        }
        i = text.index(after: i)
    }
    return nil
}

// NOTE: none of these members contain a brace inside a string literal or comment; if one is ever
// added, the brace matcher above must learn to skip strings first.
let signatures = [
    "private static func be32(",
    "private static func putBE32(",
    "private static func fourccAt(",
    "static func appendFtypCompatibleBrand(",
    "static func stripDoViConfigBox(",
]
var extracted: [String] = []
for sig in signatures {
    guard let member = extractMember(signature: sig, from: source) else {
        print("FAIL: could not extract `\(sig)` from \(sourcePath).")
        print("      If the function was renamed or moved, update the signatures list in this test.")
        exit(1)
    }
    extracted.append(member)
}
print("extracted \(extracted.count) real members (\(extracted.map { $0.count }.reduce(0, +)) chars)")

// MARK: - Real captured fixtures (see header for provenance)

let rawInitB64 = "AAAAIGZ0eXBpc281AAACAGlzbzVpc282ZGJ5MW1wNDEAAA6AbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAAAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAC6p0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAABQAAAALQAAAAAAAwZWR0cwAAAChlbHN0AAAAAAAAAAIAAAAF/////wABAAAAAAAAAAAc1AABAAAAAAsWbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAFfkAAAAABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAKwW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAACoFzdGJsAAAKNXN0c2QAAAAAAAAAAQAACiVodmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAABQAC0ABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAJgmh2Y0MBAiAAAACQAAAAAABd8AD8/fr6AAAPBKAAAQAYQAEMAf//AiAAAAMAkAAAAwAAAwBdlZgJoQABAC5CAQECIAAAAwCQAAADAAADAF2gAoCALRNllZpJMrwFqEiASCAAAAMAIAAAAwMBogABAAdEAcFytGJAJwABCQJOAQX///////////0sot4JtRdH27tVpP5/wvxOeDI2NSAoYnVpbGQgMjE2KSAtIDQuMisxLWU0NDQ3NDQ6W01hYyBPUyBYXVtjbGFuZyAyMS4wLjBdWzY0IGJpdF0gMTBiaXQgLSBILjI2NS9IRVZDIGNvZGVjIC0gQ29weXJpZ2h0IDIwMTMtMjAxOCAoYykgTXVsdGljb3Jld2FyZSwgSW5jIC0gaHR0cDovL3gyNjUub3JnIC0gb3B0aW9uczogY3B1aWQ9OTggZnJhbWUtdGhyZWFkcz0zIHdwcCBuby1wbW9kZSBuby1wbWUgbm8tcHNuciBuby1zc2ltIGxvZy1sZXZlbD0wIGJpdGRlcHRoPTEwIGlucHV0LWNzcD0xIGZwcz0yNC8xIGlucHV0LXJlcz0xMjgweDcyMCBpbnRlcmxhY2U9MCB0b3RhbC1mcmFtZXM9MCBsZXZlbC1pZGM9MCBoaWdoLXRpZXI9MSB1aGQtYmQ9MCByZWY9MiBuby1hbGxvdy1ub24tY29uZm9ybWFuY2Ugbm8tcmVwZWF0LWhlYWRlcnMgYW5uZXhiIG5vLWF1ZCBuby1lb2Igbm8tZW9zIG5vLWhyZCBpbmZvIGhhc2g9MCB0ZW1wb3JhbC1sYXllcnM9MCBvcGVuLWdvcCBtaW4ta2V5aW50PTI0IGtleWludD0yNCBnb3AtbG9va2FoZWFkPTAgYmZyYW1lcz00IGItYWRhcHQ9MCBiLXB5cmFtaWQgYmZyYW1lLWJpYXM9MCByYy1sb29rYWhlYWQ9MTUgbG9va2FoZWFkLXNsaWNlcz00IHNjZW5lY3V0PTQwIG5vLWhpc3Qtc2NlbmVjdXQgcmFkbD0wIG5vLXNwbGljZSBuby1pbnRyYS1yZWZyZXNoIGN0dT02NCBtaW4tY3Utc2l6ZT04IG5vLXJlY3Qgbm8tYW1wIG1heC10dS1zaXplPTMyIHR1LWludGVyLWRlcHRoPTEgdHUtaW50cmEtZGVwdGg9MSBsaW1pdC10dT0wIHJkb3EtbGV2ZWw9MCBkeW5hbWljLXJkPTAuMDAgbm8tc3NpbS1yZCBzaWduaGlkZSBuby10c2tpcCBuci1pbnRyYT0wIG5yLWludGVyPTAgbm8tY29uc3RyYWluZWQtaW50cmEgc3Ryb25nLWludHJhLXNtb290aGluZyBtYXgtbWVyZ2U9MiBsaW1pdC1yZWZzPTMgbm8tbGltaXQtbW9kZXMgbWU9MSBzdWJtZT0xIG1lcmFuZ2U9NTcgdGVtcG9yYWwtbXZwIG5vLWZyYW1lLWR1cCBuby1obWUgd2VpZ2h0cCBuby13ZWlnaHRiIG5vLWFuYWx5emUtc3JjLXBpY3MgZGVibG9jaz0wOjAgc2FvIG5vLXNhby1ub24tZGVibG9jayByZD0yIHNlbGVjdGl2ZS1zYW89NCBlYXJseS1za2lwIHJza2lwIGZhc3QtaW50cmEgbm8tdHNraXAtZmFzdCBuby1jdS1sb3NzbGVzcyBuby1iLWludHJhIG5vLXNwbGl0cmQtc2tpcCByZHBlbmFsdHk9MCBwc3ktcmQ9Mi4wMCBwc3ktcmRvcT0wLjAwIG5vLXJkLXJlZmluZSBuby1sb3NzbGVzcyBjYnFwb2Zmcz0wIGNycXBvZmZzPTAgcmM9Y3JmIGNyZj0yOC4wIHFjb21wPTAuNjAgcXBzdGVwPTQgc3RhdHMtd3JpdGU9MCBzdGF0cy1yZWFkPTAgaXByYXRpbz0xLjQwIHBicmF0aW89MS4zMCBhcS1tb2RlPTIgYXEtc3RyZW5ndGg9MS4wMCBjdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIgcWctc2l6ZT0zMiBuby1yYy1ncmFpbiBxcG1heD02OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9ybWF0PTUgcmFuZ2U9MCBjb2xvcnByaW09OSB0cmFuc2Zlcj0xNiBjb2xvcm1hdHJpeD05IGNocm9tYWxvYz0wIGRpc3BsYXktd2luZG93PTAgY2xsPTAsMCBtaW4tbHVtYT0wIG1heC1sdW1hPTEwMjMgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1pbmctaW5mbyB2dWktaHJkLWluZm8gc2xpY2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1tdWx0aS1wYXNzLW9wdC1ycHMgc2NlbmVjdXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gbm8taGRyMTAgbm8taGRyMTAtb3B0IG5vLWRoZHIxMC1vcHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFuYWx5c2lzLXNhdmUtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5lLWludHJhPTAgcmVmaW5lLWludGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZvPTAgbm8tbG93cGFzcy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBuby1keW5hbWljLXJlZmluZSBuby1zaW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRpb24tcmFuZ2U9MS4wMCBzY2VuZWN1dC1hd2FyZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209MCBkZWNvZGVyLW1heC1yYXRlPTAgbm8tdmJ2LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAAAApmaWVsAQAAAAATY29scm5jbHgACQAQAAkAAAAAIGR2dkMBABA1EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQcGFzcAAAAAEAAAABAAAAEHN0dHMAAAAAAAAAAAAAABBzdHNjAAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAAAAAAABBzdGNvAAAAAAAAAAAAAAG4dHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAAAAAAAAAAQAAAAABMG1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAu4AAAAAAVcQAAAAAAC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAANttaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAJ9zdGJsAAAAU3N0c2QAAAAAAAAAAQAAAENhYy0zAAAAAAAAAAEAAAAAAAAAAAAGABAAAAAAu4AAAAAAAAtkYWMzED3gAAAAFGJ0cnQAAAAAAAbWAAAG1gAAAAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAAABRzdHN6AAAAAAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAEhtdmV4AAAAIHRyZXgAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAAAAAAgdHJleAAAAAAAAAACAAAAAQAAAAAAAAAAAAAAAAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAy"

let servedDVB64 = "AAAAJGZ0eXBpc281AAACAGlzbzVpc282ZGJ5MW1wNDFkYjFwAAAOgG1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAAAAAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAuqdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAUAAAAC0AAAAAAAMGVkdHMAAAAoZWxzdAAAAAAAAAACAAAABf////8AAQAAAAAAAAAAHNQAAQAAAAALFm1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAABX5AAAAAAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAACsFtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAqBc3RibAAACjVzdHNkAAAAAAAAAAEAAAolaHZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAUAAtAASAAAAEgAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAACYJodmNDAQIgAAAAkAAAAAAAXfAA/P36+gAADwSgAAEAGEABDAH//wIgAAADAJAAAAMAAAMAXZWYCaEAAQAuQgEBAiAAAAMAkAAAAwAAAwBdoAKAgC0TZZWaSTK8BahIgEggAAADACAAAAMDAaIAAQAHRAHBcrRiQCcAAQkCTgEF///////////9LKLeCbUXR9u7VaT+f8L8TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltNYWMgT1MgWF1bY2xhbmcgMjEuMC4wXVs2NCBiaXRdIDEwYml0IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAyMDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIEluYyAtIGh0dHA6Ly94MjY1Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTk4IGZyYW1lLXRocmVhZHM9MyB3cHAgbm8tcG1vZGUgbm8tcG1lIG5vLXBzbnIgbm8tc3NpbSBsb2ctbGV2ZWw9MCBiaXRkZXB0aD0xMCBpbnB1dC1jc3A9MSBmcHM9MjQvMSBpbnB1dC1yZXM9MTI4MHg3MjAgaW50ZXJsYWNlPTAgdG90YWwtZnJhbWVzPTAgbGV2ZWwtaWRjPTAgaGlnaC10aWVyPTEgdWhkLWJkPTAgcmVmPTIgbm8tYWxsb3ctbm9uLWNvbmZvcm1hbmNlIG5vLXJlcGVhdC1oZWFkZXJzIGFubmV4YiBuby1hdWQgbm8tZW9iIG5vLWVvcyBuby1ocmQgaW5mbyBoYXNoPTAgdGVtcG9yYWwtbGF5ZXJzPTAgb3Blbi1nb3AgbWluLWtleWludD0yNCBrZXlpbnQ9MjQgZ29wLWxvb2thaGVhZD0wIGJmcmFtZXM9NCBiLWFkYXB0PTAgYi1weXJhbWlkIGJmcmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTE1IGxvb2thaGVhZC1zbGljZXM9NCBzY2VuZWN1dD00MCBuby1oaXN0LXNjZW5lY3V0IHJhZGw9MCBuby1zcGxpY2Ugbm8taW50cmEtcmVmcmVzaCBjdHU9NjQgbWluLWN1LXNpemU9OCBuby1yZWN0IG5vLWFtcCBtYXgtdHUtc2l6ZT0zMiB0dS1pbnRlci1kZXB0aD0xIHR1LWludHJhLWRlcHRoPTEgbGltaXQtdHU9MCByZG9xLWxldmVsPTAgZHluYW1pYy1yZD0wLjAwIG5vLXNzaW0tcmQgc2lnbmhpZGUgbm8tdHNraXAgbnItaW50cmE9MCBuci1pbnRlcj0wIG5vLWNvbnN0cmFpbmVkLWludHJhIHN0cm9uZy1pbnRyYS1zbW9vdGhpbmcgbWF4LW1lcmdlPTIgbGltaXQtcmVmcz0zIG5vLWxpbWl0LW1vZGVzIG1lPTEgc3VibWU9MSBtZXJhbmdlPTU3IHRlbXBvcmFsLW12cCBuby1mcmFtZS1kdXAgbm8taG1lIHdlaWdodHAgbm8td2VpZ2h0YiBuby1hbmFseXplLXNyYy1waWNzIGRlYmxvY2s9MDowIHNhbyBuby1zYW8tbm9uLWRlYmxvY2sgcmQ9MiBzZWxlY3RpdmUtc2FvPTQgZWFybHktc2tpcCByc2tpcCBmYXN0LWludHJhIG5vLXRza2lwLWZhc3Qgbm8tY3UtbG9zc2xlc3Mgbm8tYi1pbnRyYSBuby1zcGxpdHJkLXNraXAgcmRwZW5hbHR5PTAgcHN5LXJkPTIuMDAgcHN5LXJkb3E9MC4wMCBuby1yZC1yZWZpbmUgbm8tbG9zc2xlc3MgY2JxcG9mZnM9MCBjcnFwb2Zmcz0wIHJjPWNyZiBjcmY9MjguMCBxY29tcD0wLjYwIHFwc3RlcD00IHN0YXRzLXdyaXRlPTAgc3RhdHMtcmVhZD0wIGlwcmF0aW89MS40MCBwYnJhdGlvPTEuMzAgYXEtbW9kZT0yIGFxLXN0cmVuZ3RoPTEuMDAgY3V0cmVlIHpvbmUtY291bnQ9MCBuby1zdHJpY3QtY2JyIHFnLXNpemU9MzIgbm8tcmMtZ3JhaW4gcXBtYXg9NjkgcXBtaW49MCBuby1jb25zdC12YnYgc2FyPTEgb3ZlcnNjYW49MCB2aWRlb2Zvcm1hdD01IHJhbmdlPTAgY29sb3JwcmltPTkgdHJhbnNmZXI9MTYgY29sb3JtYXRyaXg9OSBjaHJvbWFsb2M9MCBkaXNwbGF5LXdpbmRvdz0wIGNsbD0wLDAgbWluLWx1bWE9MCBtYXgtbHVtYT0xMDIzIGxvZzItbWF4LXBvYy1sc2I9OCB2dWktdGltaW5nLWluZm8gdnVpLWhyZC1pbmZvIHNsaWNlcz0xIG5vLW9wdC1xcC1wcHMgbm8tb3B0LXJlZi1saXN0LWxlbmd0aC1wcHMgbm8tbXVsdGktcGFzcy1vcHQtcnBzIHNjZW5lY3V0LWJpYXM9MC4wNSBuby1vcHQtY3UtZGVsdGEtcXAgbm8tYXEtbW90aW9uIG5vLWhkcjEwIG5vLWhkcjEwLW9wdCBuby1kaGRyMTAtb3B0IG5vLWlkci1yZWNvdmVyeS1zZWkgYW5hbHlzaXMtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1zYXZlLXJldXNlLWxldmVsPTAgYW5hbHlzaXMtbG9hZC1yZXVzZS1sZXZlbD0wIHNjYWxlLWZhY3Rvcj0wIHJlZmluZS1pbnRyYT0wIHJlZmluZS1pbnRlcj0wIHJlZmluZS1tdj0xIHJlZmluZS1jdHUtZGlzdG9ydGlvbj0wIG5vLWxpbWl0LXNhbyBjdHUtaW5mbz0wIG5vLWxvd3Bhc3MtZGN0IHJlZmluZS1hbmFseXNpcy10eXBlPTAgY29weS1waWM9MSBtYXgtYXVzaXplLWZhY3Rvcj0xLjAgbm8tZHluYW1pYy1yZWZpbmUgbm8tc2luZ2xlLXNlaSBuby1oZXZjLWFxIG5vLXN2dCBuby1maWVsZCBxcC1hZGFwdGF0aW9uLXJhbmdlPTEuMDAgc2NlbmVjdXQtYXdhcmUtcXA9MGNvbmZvcm1hbmNlLXdpbmRvdy1vZmZzZXRzIHJpZ2h0PTAgYm90dG9tPTAgZGVjb2Rlci1tYXgtcmF0ZT0wIG5vLXZidi1saXZlLW11bHRpLXBhc3Mgbm8tbWNzdGYgbm8tc2JyYyBuby1mcmFtZS1yY4AAAAAKZmllbAEAAAAAE2NvbHJuY2x4AAkAEAAJAAAAACBkdnZDAQAQNRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEHBhc3AAAAABAAAAAQAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAABuHRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAAAAAAAAAAEAAAAAATBtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAADbbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAACfc3RibAAAAFNzdHNkAAAAAAAAAAEAAABDYWMtMwAAAAAAAAABAAAAAAAAAAAABgAQAAAAALuAAAAAAAALZGFjMxA94AAAABRidHJ0AAAAAAAG1gAABtYAAAAAEHN0dHMAAAAAAAAAAAAAABBzdHNjAAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAAAAAAABBzdGNvAAAAAAAAAAAAAABIbXZleAAAACB0cmV4AAAAAAAAAAEAAAABAAAAAAAAAAAAAAAAAAAAIHRyZXgAAAAAAAAAAgAAAAEAAAAAAAAAAAAAAAAAAABidWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMg=="

let servedHDRB64 = "AAAAIGZ0eXBpc281AAACAGlzbzVpc282ZGJ5MW1wNDEAAA5gbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAAAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAC4p0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAABQAAAALQAAAAAAAwZWR0cwAAAChlbHN0AAAAAAAAAAIAAAAF/////wABAAAAAAAAAAAc1AABAAAAAAr2bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAFfkAAAAABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAKoW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAACmFzdGJsAAAKFXN0c2QAAAAAAAAAAQAACgVodmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAABQAC0ABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAJgmh2Y0MBAiAAAACQAAAAAABd8AD8/fr6AAAPBKAAAQAYQAEMAf//AiAAAAMAkAAAAwAAAwBdlZgJoQABAC5CAQECIAAAAwCQAAADAAADAF2gAoCALRNllZpJMrwFqEiASCAAAAMAIAAAAwMBogABAAdEAcFytGJAJwABCQJOAQX///////////0sot4JtRdH27tVpP5/wvxOeDI2NSAoYnVpbGQgMjE2KSAtIDQuMisxLWU0NDQ3NDQ6W01hYyBPUyBYXVtjbGFuZyAyMS4wLjBdWzY0IGJpdF0gMTBiaXQgLSBILjI2NS9IRVZDIGNvZGVjIC0gQ29weXJpZ2h0IDIwMTMtMjAxOCAoYykgTXVsdGljb3Jld2FyZSwgSW5jIC0gaHR0cDovL3gyNjUub3JnIC0gb3B0aW9uczogY3B1aWQ9OTggZnJhbWUtdGhyZWFkcz0zIHdwcCBuby1wbW9kZSBuby1wbWUgbm8tcHNuciBuby1zc2ltIGxvZy1sZXZlbD0wIGJpdGRlcHRoPTEwIGlucHV0LWNzcD0xIGZwcz0yNC8xIGlucHV0LXJlcz0xMjgweDcyMCBpbnRlcmxhY2U9MCB0b3RhbC1mcmFtZXM9MCBsZXZlbC1pZGM9MCBoaWdoLXRpZXI9MSB1aGQtYmQ9MCByZWY9MiBuby1hbGxvdy1ub24tY29uZm9ybWFuY2Ugbm8tcmVwZWF0LWhlYWRlcnMgYW5uZXhiIG5vLWF1ZCBuby1lb2Igbm8tZW9zIG5vLWhyZCBpbmZvIGhhc2g9MCB0ZW1wb3JhbC1sYXllcnM9MCBvcGVuLWdvcCBtaW4ta2V5aW50PTI0IGtleWludD0yNCBnb3AtbG9va2FoZWFkPTAgYmZyYW1lcz00IGItYWRhcHQ9MCBiLXB5cmFtaWQgYmZyYW1lLWJpYXM9MCByYy1sb29rYWhlYWQ9MTUgbG9va2FoZWFkLXNsaWNlcz00IHNjZW5lY3V0PTQwIG5vLWhpc3Qtc2NlbmVjdXQgcmFkbD0wIG5vLXNwbGljZSBuby1pbnRyYS1yZWZyZXNoIGN0dT02NCBtaW4tY3Utc2l6ZT04IG5vLXJlY3Qgbm8tYW1wIG1heC10dS1zaXplPTMyIHR1LWludGVyLWRlcHRoPTEgdHUtaW50cmEtZGVwdGg9MSBsaW1pdC10dT0wIHJkb3EtbGV2ZWw9MCBkeW5hbWljLXJkPTAuMDAgbm8tc3NpbS1yZCBzaWduaGlkZSBuby10c2tpcCBuci1pbnRyYT0wIG5yLWludGVyPTAgbm8tY29uc3RyYWluZWQtaW50cmEgc3Ryb25nLWludHJhLXNtb290aGluZyBtYXgtbWVyZ2U9MiBsaW1pdC1yZWZzPTMgbm8tbGltaXQtbW9kZXMgbWU9MSBzdWJtZT0xIG1lcmFuZ2U9NTcgdGVtcG9yYWwtbXZwIG5vLWZyYW1lLWR1cCBuby1obWUgd2VpZ2h0cCBuby13ZWlnaHRiIG5vLWFuYWx5emUtc3JjLXBpY3MgZGVibG9jaz0wOjAgc2FvIG5vLXNhby1ub24tZGVibG9jayByZD0yIHNlbGVjdGl2ZS1zYW89NCBlYXJseS1za2lwIHJza2lwIGZhc3QtaW50cmEgbm8tdHNraXAtZmFzdCBuby1jdS1sb3NzbGVzcyBuby1iLWludHJhIG5vLXNwbGl0cmQtc2tpcCByZHBlbmFsdHk9MCBwc3ktcmQ9Mi4wMCBwc3ktcmRvcT0wLjAwIG5vLXJkLXJlZmluZSBuby1sb3NzbGVzcyBjYnFwb2Zmcz0wIGNycXBvZmZzPTAgcmM9Y3JmIGNyZj0yOC4wIHFjb21wPTAuNjAgcXBzdGVwPTQgc3RhdHMtd3JpdGU9MCBzdGF0cy1yZWFkPTAgaXByYXRpbz0xLjQwIHBicmF0aW89MS4zMCBhcS1tb2RlPTIgYXEtc3RyZW5ndGg9MS4wMCBjdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIgcWctc2l6ZT0zMiBuby1yYy1ncmFpbiBxcG1heD02OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9ybWF0PTUgcmFuZ2U9MCBjb2xvcnByaW09OSB0cmFuc2Zlcj0xNiBjb2xvcm1hdHJpeD05IGNocm9tYWxvYz0wIGRpc3BsYXktd2luZG93PTAgY2xsPTAsMCBtaW4tbHVtYT0wIG1heC1sdW1hPTEwMjMgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1pbmctaW5mbyB2dWktaHJkLWluZm8gc2xpY2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1tdWx0aS1wYXNzLW9wdC1ycHMgc2NlbmVjdXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gbm8taGRyMTAgbm8taGRyMTAtb3B0IG5vLWRoZHIxMC1vcHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFuYWx5c2lzLXNhdmUtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5lLWludHJhPTAgcmVmaW5lLWludGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZvPTAgbm8tbG93cGFzcy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBuby1keW5hbWljLXJlZmluZSBuby1zaW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRpb24tcmFuZ2U9MS4wMCBzY2VuZWN1dC1hd2FyZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209MCBkZWNvZGVyLW1heC1yYXRlPTAgbm8tdmJ2LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAAAApmaWVsAQAAAAATY29scm5jbHgACQAQAAkAAAAAEHBhc3AAAAABAAAAAQAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAABuHRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAAAAAAAAAAEAAAAAATBtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAADbbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAACfc3RibAAAAFNzdHNkAAAAAAAAAAEAAABDYWMtMwAAAAAAAAABAAAAAAAAAAAABgAQAAAAALuAAAAAAAALZGFjMxA94AAAABRidHJ0AAAAAAAG1gAABtYAAAAAEHN0dHMAAAAAAAAAAAAAABBzdHNjAAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAAAAAAABBzdGNvAAAAAAAAAAAAAABIbXZleAAAACB0cmV4AAAAAAAAAAEAAAABAAAAAAAAAAAAAAAAAAAAIHRyZXgAAAAAAAAAAgAAAAEAAAAAAAAAAAAAAAAAAABidWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMg=="

// MARK: - Generate the child test program (real extracted members + assertions) and run it

let driver = """
import Foundation

enum RealSurgery {
\(extracted.joined(separator: "\n\n"))
}

func b64(_ s: String) -> Data {
    guard let d = Data(base64Encoded: s) else { print("FAIL: fixture base64"); exit(1) }
    return d
}
let rawInit = b64("\(rawInitB64)")
let servedDV = b64("\(servedDVB64)")
let servedHDR = b64("\(servedHDRB64)")

func fail(_ msg: String) -> Never { print("FAIL: \\(msg)"); exit(1) }
func be32(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3]) }
func fourcc(_ b: [UInt8], _ i: Int) -> String { String(bytes: b[i..<i+4], encoding: .ascii) ?? "?" }
func brands(_ d: Data) -> (size: Int, major: String, list: [String])? {
    let b = [UInt8](d)
    guard b.count >= 16, fourcc(b, 4) == "ftyp" else { return nil }
    let size = be32(b, 0)
    guard size >= 16, size <= b.count else { return nil }
    var out: [String] = []
    var off = 16   // size(4) + 'ftyp'(4) + major(4) + minor(4), then the compatible_brands list
    while off + 4 <= size { out.append(fourcc(b, off)); off += 4 }
    return (size, fourcc(b, 8), out)
}
func containsBox(_ d: Data, _ name: String) -> Bool {
    let n = [UInt8](name.utf8), b = [UInt8](d)
    guard b.count >= 4 else { return false }
    for i in 0...(b.count - 4) where b[i] == n[0] && b[i+1] == n[1] && b[i+2] == n[2] && b[i+3] == n[3] { return true }
    return false
}

// C1: the raw fixture IS the documented movenc shape: 32B ftyp, major iso5,
// compatible [iso5, iso6, dby1, mp41], and no db1p anywhere.
guard let raw = brands(rawInit), raw.size == 32, raw.major == "iso5",
      raw.list == ["iso5", "iso6", "dby1", "mp41"]
else { fail("C1 raw fixture ftyp shape unexpected") }
print("PASS C1: raw movenc ftyp = 32B major=iso5 compatible=\\(raw.list), no db1p")

// C2: the REAL appendFtypCompatibleBrand reproduces the served /init.mp4 byte-for-byte.
guard let stamped = RealSurgery.appendFtypCompatibleBrand(rawInit, brand: "db1p") else {
    fail("C2 appendFtypCompatibleBrand returned nil on the real movenc init")
}
if stamped != servedDV { fail("C2 stamped bytes differ from the captured served /init.mp4 (\\(stamped.count)B vs \\(servedDV.count)B)") }
print("PASS C2: append(raw, db1p) == served /init.mp4 fixture, byte-exact (\\(stamped.count)B)")

// C3: the stamped ftyp declares db1p and stays structurally sane (size +4, db1p appended, moov next).
guard let st = brands(stamped), st.size == 36, st.major == "iso5",
      st.list == ["iso5", "iso6", "dby1", "mp41", "db1p"],
      fourcc([UInt8](stamped), st.size + 4) == "moov"
else { fail("C3 stamped ftyp not the expected 36B [iso5, iso6, dby1, mp41, db1p] + moov shape") }
print("PASS C3: stamped ftyp = 36B compatible=\\(st.list), moov follows")

// C4: idempotence contract, a brand already present must return nil (never double-append).
if RealSurgery.appendFtypCompatibleBrand(servedDV, brand: "db1p") != nil {
    fail("C4 append on an already-branded init must return nil")
}
print("PASS C4: append is idempotent (already-branded init returns nil)")

// C5: malformed inputs return nil (fail-soft contract: caller then serves original bytes).
if RealSurgery.appendFtypCompatibleBrand(Data(count: 8), brand: "db1p") != nil { fail("C5 short data must return nil") }
if RealSurgery.appendFtypCompatibleBrand(rawInit, brand: "toolong") != nil { fail("C5 non-4-char brand must return nil") }
print("PASS C5: malformed input / brand returns nil")

// C6: the REAL stripDoViConfigBox reproduces the served /init-hdr.mp4 byte-for-byte, dvvC gone.
guard let stripped = RealSurgery.stripDoViConfigBox(rawInit) else { fail("C6 stripDoViConfigBox returned nil") }
if stripped != servedHDR { fail("C6 stripped bytes differ from the captured served /init-hdr.mp4") }
if containsBox(stripped, "dvvC") || containsBox(stripped, "dvcC") { fail("C6 stripped init still carries a DV config box") }
if !containsBox(rawInit, "dvvC") { fail("C6 raw fixture lost its dvvC (fixture integrity)") }
print("PASS C6: strip(raw) == served /init-hdr.mp4 fixture, dvvC removed (\\(stripped.count)B)")

// C7: strip fixed the moov size chain (moov shrinks by exactly the 32B dvvC box).
let rawMoov = be32([UInt8](rawInit), 32)
let hdrMoov = be32([UInt8](stripped), 32)
if rawMoov - hdrMoov != 32 { fail("C7 moov size delta \\(rawMoov - hdrMoov), expected 32") }
print("PASS C7: moov size \\(rawMoov) -> \\(hdrMoov) (-32, the dvvC box)")

print("ALL PASS: the served DV init carries the declared brand and the lifeboat carries no DV box")
"""

let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("vortx-dv-brand-test-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let driverURL = tmpDir.appendingPathComponent("driver.swift")
do { try driver.write(to: driverURL, atomically: true, encoding: .utf8) } catch {
    print("FAIL: cannot write driver: \(error)")
    exit(1)
}
defer { try? FileManager.default.removeItem(at: tmpDir) }

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
proc.arguments = ["swift", driverURL.path]
do { try proc.run() } catch {
    print("FAIL: cannot launch swift for the driver: \(error)")
    exit(1)
}
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    print("FAIL: DV init brand-stamp assertions failed (exit \(proc.terminationStatus))")
    exit(1)
}
print("DVInitBrandStampTests: OK")
