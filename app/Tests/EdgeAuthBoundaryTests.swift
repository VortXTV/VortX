// SEC-05 boundary contract for the Apple edge-auth helper (compiles the REAL production source).
//
// RUN:
//   swiftc -swift-version 5 -parse-as-library \
//     app/SourcesShared/VortXEdgeAuth.swift \
//     app/Tests/EdgeAuthBoundaryTests.swift \
//     -o /tmp/vortx-edge-auth-boundary-tests && \
//   /tmp/vortx-edge-auth-boundary-tests
//
// WHAT THIS LOCKS IN (SEC-05 remediation):
//   1. The shared client HMAC is abuse-friction/attribution telemetry ONLY: in an UNPROVISIONED build
//      every public endpoint degrades safely (header signing stamps the observe-mode empty-key shape,
//      query signing fails open, OAuth v2 fails closed WITHOUT stamping), so no behavior ever treats
//      possession of the secret as privilege.
//   2. The provisioning pipeline is total: absent/malformed/placeholder blobs collapse to "" (never
//      sign-with-garbage) and maskedValue <-> deMaskedSecret round-trip exactly.
//   3. Secret NON-LEAKAGE: the helper logs nothing, and its outputs carry only ts/kid/sig artifacts.
//   4. Layer separation: NO short-lived-token (MOAT) machinery lives in this file; privileged
//      authorization stays with the server-issued token seam (MoatToken + api.vortx.tv issuer +
//      worker moat_auth.ts), never with this shared secret.

import Foundation
import CryptoKit

@main
private enum EdgeAuthBoundaryTests {
    static func main() {
        var failures = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                print("PASS  \(message)")
            } else {
                failures += 1
                print("FAIL  \(message)")
            }
        }

        let app = appRoot()
        let edgeSource = read(app, "SourcesShared/VortXEdgeAuth.swift")

        // ---- 1. Unprovisioned environment: capability flags ------------------------------------------
        // The compiled harness bundle carries no VortXEdgeSecret, mirroring an unprovisioned sideload.
        let probe = URLRequest(url: URL(string: "https://skip.vortx.tv/skip")!)
        var oauthProbe = probe
        oauthProbe.httpMethod = "POST"
        check(VortXEdgeAuth.canSignOAuthV2 == false,
              "unprovisioned build reports canSignOAuthV2 false (capability, not entitlement)")
        check(VortXEdgeAuth.signOAuthV2(&oauthProbe, body: Data("{\"session\":\"s\"}".utf8)) == false,
              "unprovisioned OAuth v2 signer fails closed")
        check(oauthProbe.value(forHTTPHeaderField: "X-VX-Sig") == nil
                && oauthProbe.value(forHTTPHeaderField: "X-VX-Ts") == nil
                && oauthProbe.value(forHTTPHeaderField: "X-VX-Kid") == nil
                && oauthProbe.value(forHTTPHeaderField: "X-VX-Nonce") == nil
                && oauthProbe.value(forHTTPHeaderField: "X-VX-Body-SHA256") == nil
                && oauthProbe.value(forHTTPHeaderField: "X-VX-Auth-Version") == nil,
              "failed OAuth v2 signature stamps NO partial X-VX-* headers")

        // ---- 2. Observe-mode header signing: identical wire shape with an empty key -------------------
        var observe = URLRequest(url: URL(string: "https://skip.vortx.tv/skip?ids=a,b")!)
        VortXEdgeAuth.sign(&observe)
        let ts = observe.value(forHTTPHeaderField: "X-VX-Ts")
        let kid = observe.value(forHTTPHeaderField: "X-VX-Kid")
        let sig = observe.value(forHTTPHeaderField: "X-VX-Sig")
        check(ts != nil && kid == "k1" && sig != nil, "unprovisioned sign() stamps the full X-VX-* triple")
        check(ts?.count == 10 && Int(ts ?? "") != nil
                && abs(Int(Date().timeIntervalSince1970) - Int(ts ?? "0")!) <= 300,
              "X-VX-Ts is current unix seconds inside the worker skew window")
        check(sig?.count == 64 && sig == sig?.lowercased(), "X-VX-Sig is 64-char lowercase hex")
        if let ts, let sig {
            let message = "GET\n/skip\n\(ts)"
            let expected = hmacEmptyKeyHex(message)
            check(sig == expected, "empty-key signature matches the workers' METHOD\\npath\\nts contract")
        } else {
            check(false, "signature verifiable against METHOD\\npath\\nts contract")
        }
        check(observe.url?.absoluteString == "https://skip.vortx.tv/skip?ids=a,b",
              "header signing never mutates the URL")

        // Percent-encoded path parity: the signed message uses the ENCODED path.
        var encodedPathProbe = URLRequest(url: URL(string: "https://trickplay.vortx.tv/tp/a%20b")!)
        VortXEdgeAuth.sign(&encodedPathProbe)
        if let ts2 = encodedPathProbe.value(forHTTPHeaderField: "X-VX-Ts"),
           let sig2 = encodedPathProbe.value(forHTTPHeaderField: "X-VX-Sig") {
            check(sig2 == hmacEmptyKeyHex("GET\n/tp/a%20b\n\(ts2)"),
                  "signed path is the percent-encoded pathname (worker url.pathname parity)")
        } else {
            check(false, "percent-encoded path probe was stamped")
        }

        // ---- 3. Non-gated hosts are never touched -----------------------------------------------------
        var foreign = URLRequest(url: URL(string: "https://api.vortx.tv/v1/sync")!)
        VortXEdgeAuth.sign(&foreign)
        check(foreign.value(forHTTPHeaderField: "X-VX-Ts") == nil
                && foreign.value(forHTTPHeaderField: "X-VX-Kid") == nil
                && foreign.value(forHTTPHeaderField: "X-VX-Sig") == nil,
              "account-authed api.vortx.tv is excluded from the friction layer")
        var thirdParty = URLRequest(url: URL(string: "https://api.trakt.tv/shows")!)
        VortXEdgeAuth.sign(&thirdParty)
        check(thirdParty.value(forHTTPHeaderField: "X-VX-Sig") == nil,
              "third-party hosts are never stamped")

        // ---- 4. Body-bound variant keeps the exact message contract ------------------------------------
        var bodySigned = URLRequest(url: URL(string: "https://add.vortx.tv/pair")!)
        bodySigned.httpMethod = "POST"
        let payload = Data("{\"ack\":true}".utf8)
        bodySigned.httpBody = payload
        VortXEdgeAuth.signIncludingBody(&bodySigned)
        if let ts3 = bodySigned.value(forHTTPHeaderField: "X-VX-Ts"),
           let sig3 = bodySigned.value(forHTTPHeaderField: "X-VX-Sig"),
           let bodyHeader = bodySigned.value(forHTTPHeaderField: "X-VX-Body") {
            let digest = sha256Hex(payload)
            check(bodyHeader == digest, "X-VX-Body carries the SHA-256 of the exact bytes sent")
            check(sig3 == hmacEmptyKeyHex("POST\n/pair\n\(ts3)\n\(digest)"),
                  "body-bound signature covers METHOD\\npath\\nts\\nbodyDigest with the empty key")
        } else {
            check(false, "body-bound signing stamped all four headers")
        }

        // ---- 5. Query signing fails open without a secret ----------------------------------------------
        let gatedAsset = URL(string: "https://erdb.vortx.tv/logo/tt123.png")!
        let unsigned = VortXEdgeAuth.signedURL(gatedAsset)
        check(unsigned == gatedAsset, "unprovisioned signedURL returns the URL UNCHANGED (fail-open)")
        check(unsigned.query?.contains("vsig=") != true, "fail-open signedURL carries no vsig artifact")
        let foreignAsset = URL(string: "https://example.com/logo.png")!
        check(VortXEdgeAuth.signedURL(foreignAsset) == foreignAsset,
              "non-gated asset URLs are returned untouched")

        // ---- 6. Provisioning pipeline is total (no sign-with-garbage states) ---------------------------
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: nil) == "", "nil masked blob => unprovisioned")
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: "") == "", "empty masked blob => unprovisioned")
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: "   \n ") == "", "blank masked blob => unprovisioned")
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: "!!!not-base64!!!") == "",
              "malformed base64 => unprovisioned, never a crash or garbage key")
        let vectors = [
            String(repeating: "ab", count: 32),
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            String(repeating: "f", count: 64),
        ]
        for vector in vectors {
            let masked = VortXEdgeAuth.maskedValue(for: vector)
            check(masked != vector && !masked.isEmpty,
                  "maskedValue applies the runtime mask (output differs from input)")
            check(VortXEdgeAuth.maskedValue(for: vector) == masked, "maskedValue is deterministic")
            check(VortXEdgeAuth.deMaskedSecret(fromMasked: masked) == vector,
                  "masked blob round-trips to the original 64-hex secret (\(vector.prefix(4))...)")
        }
        // Wrong length and non-hex payloads collapse to unprovisioned even when properly masked.
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: VortXEdgeAuth.maskedValue(for: String(repeating: "a", count: 63))) == "",
              "63-hex de-mask result is rejected (length gate)")
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: VortXEdgeAuth.maskedValue(for: String(repeating: "z", count: 64))) == "",
              "non-hex de-mask result is rejected (validity gate)")
        // A raw key pasted where the MASKED blob belongs collapses to unprovisioned (documented footgun).
        check(VortXEdgeAuth.deMaskedSecret(fromMasked: vectors[0]) == "",
              "raw hex pasted into the masked slot collapses to unprovisioned, not to a broken key")

        // ---- 7. Secret non-leakage ----------------------------------------------------------------------
        let sinkKeywords = ["print(", "NSLog(", "os_log", "DiagnosticsLog", "Logger("]
        let lines = edgeSource.split(separator: "\n")
        let leaking = lines.filter { line in
            sinkKeywords.contains(where: line.contains)
        }
        check(leaking.isEmpty, "helper source contains no logging sinks (secret never reaches a log)")
        let signedShape = VortXEdgeAuth.signedURL(gatedAsset)
        check(signedShape.absoluteString == gatedAsset.absoluteString,
              "no secret-derived material enters fail-open URLs")

        // ---- 8. Honest classification pins + preserved broker contract identifiers ----------------------
        check(edgeSource.contains("NEVER AUTHORIZATION") && edgeSource.contains("ABUSE-FRICTION"),
              "helper documents itself as optional abuse-friction telemetry, never authorization")
        check(edgeSource.contains("NOT an authentication or authorization boundary"),
              "helper states plainly that the shipped secret cannot be an authority boundary")
        check(edgeSource.contains("/v1/moat/token") && edgeSource.contains("moat_auth.ts"),
              "helper points privileged flows at the server-issued short-lived MOAT seam")
        check(!edgeSource.contains("X-VX-Moat") && !edgeSource.contains("vmoat"),
              "NO short-lived-token stamping lives in this layer (MoatToken owns that seam)")
        check(edgeSource.contains("signOAuthV2")
                && edgeSource.contains("oauthBodyDigestHeader")
                && edgeSource.contains("oauthNonceHeader")
                && edgeSource.contains("canSignOAuthV2"),
              "deployed VORTX-OAUTH-V2 broker contract identifiers remain intact")

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }

    // MARK: - Independent primitives

    /// HMAC-SHA256 with an EMPTY key (the observe-mode shape the helper stamps when unprovisioned),
    /// recomputed here independently so the wire contract is pinned, not assumed.
    private static func hmacEmptyKeyHex(_ message: String) -> String {
        let key = SymmetricKey(data: Data())
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appRoot() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("SourcesShared").path) {
            return cwd
        }
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("app/SourcesShared").path) {
            return cwd.appendingPathComponent("app")
        }
        fatalError("Run from the repository root or app directory")
    }

    private static func read(_ root: URL, _ relativePath: String) -> String {
        let url = root.appendingPathComponent(relativePath)
        guard let value = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Could not read \(url.path)")
        }
        return value
    }
}
