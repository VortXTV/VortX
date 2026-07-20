// PlayerEngineRouterPlainRemuxTests: runnable verification of the #147 PLAIN (non-DV) remux routing.
//
// Unlike the mirror-style scripts in this folder, this compiles the REAL router file, so the shipped
// predicates (plainRemuxEnabled / isPlainRemuxCandidate / isPlainRemuxRetryCandidate / shouldPlainRemux,
// plus the untouched engine() + DV candidacy) are what is asserted, with only RemoteConfig and
// DVDisplaySupport stubbed (they are app-target types the router reads one value from). Run:
//
//     swiftc -o /tmp/vortx-router-tests \
//         app/Sources/Player/PlayerEngineRouter.swift \
//         app/Tests/PlayerEngineRouterPlainRemuxTests.swift \
//     && /tmp/vortx-router-tests
//
// The ONE mirrored piece is `loadFileMountLane`, a faithful copy of AVPlayerEngine.loadFile's
// wantsDVRemux / wantsPlainRemux resolution (the engine file needs AVFoundation and cannot compile
// standalone). It MUST stay in lockstep with AVPlayerEngine.loadFile; the compile/link proof for the
// shipped engine code is the 2-scheme Xcode build gate, as for every script in this folder.

import Foundation

// MARK: - Stubs for the two app-target types the router reads (see header)

/// Stub of SourcesShared/RemoteConfig.swift's ResolvedConfig surface the router consumes.
final class ResolvedConfig {
    var features: [String: Bool] = [:]
    func isFeatureOn(_ key: String, default fallback: Bool) -> Bool { features[key] ?? fallback }
}

enum RemoteConfig {
    nonisolated(unsafe) static var snapshot = ResolvedConfig()
}

enum DVDisplaySupport {
    @MainActor static var isCapable = true
}

// MARK: - Lockstep mirror of AVPlayerEngine.loadFile's mount-lane resolution (#147)

enum MountLane: String { case dvRemux, plainRemux, raw }

/// MUST match AVPlayerEngine.loadFile: wantsDVRemux = forceRemux || (contentIsDolbyVision && shouldDVRemux);
/// wantsPlainRemux = !wantsDVRemux && !contentIsDolbyVision && deliveryEnabled && (forcePlainRemux ||
/// shouldPlainRemux). shouldDVRemux is decomposed into its two nonisolated predicates (its exact definition)
/// so this mirror needs no MainActor.
func loadFileMountLane(url: URL, contentIsDolbyVision: Bool,
                       forceRemux: Bool = false, forcePlainRemux: Bool = false,
                       deliveryEnabled: Bool = true, dvDisplayCapable: Bool = true) -> MountLane {
    let wantsDVRemux = forceRemux || (contentIsDolbyVision
        && PlayerEngineRouter.dvRemuxEnabled(dvDisplayCapable: dvDisplayCapable)
        && PlayerEngineRouter.isDVRemuxCandidate(url))
    let wantsPlainRemux = !wantsDVRemux && !contentIsDolbyVision && deliveryEnabled
        && (forcePlainRemux || PlayerEngineRouter.shouldPlainRemux(url: url))
    if wantsDVRemux { return .dvRemux }
    if wantsPlainRemux { return .plainRemux }
    return .raw
}

// MARK: - Harness

nonisolated(unsafe) var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

func url(_ s: String) -> URL { URL(string: s)! }

/// Reset every persisted/remote input the router reads, so runs are deterministic.
func resetFlags() {
    UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.plainRemuxKey)
    UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.dvRemuxKey)
    UserDefaults.standard.removeObject(forKey: PlayerEngineRouter.overrideKey)
    RemoteConfig.snapshot = ResolvedConfig()
}

@main
struct Runner {
static func main() {
resetFlags()

// The exact #147 field case: a NON-DV H.264/HE-AAC 1080p MKV (konrepo, Beta 4).
let konrepoMKV = url("https://cdn.example.com/dl/Agent.Kim.Reactivated.S01E01.PLSUB.1080p.NF.WEB-DL.HE-AAC2.0.H264-Ralf.mkv")
let dvMKV = url("https://cdn.example.com/dl/Movie.2026.2160p.WEB-DL.DV.HDR.H265.mkv")
let plainMP4 = url("https://cdn.example.com/dl/Movie.2026.1080p.WEB-DL.mp4")
let queryMKV = url("https://debrid.example.com/download/8371?file=Show.S01E02.1080p.mkv")
let extensionless = url("https://debrid.example.com/download/8371aa02")
let loopbackMKV = url("http://127.0.0.1:11470/local/file.mkv")
let hlsManifest = url("https://cdn.example.com/live/master.m3u8")

// 1. AUTO routing is UNTOUCHED: a non-DV MKV still routes to libmpv (no PiP intent, no behavior change).
check(PlayerEngineRouter.engine(for: konrepoMKV, isTorrent: false, isDolbyVision: false,
                                override: .auto, dvDisplayCapable: true) == .mpv,
      "auto: non-DV MKV still routes to libmpv (unchanged)")

// 2. The #147 fix: AVPlayer intent (the Prefer-AVPlayer override) on a non-DV MKV resolves to the PLAIN
//    remux lane, NOT a raw mount (which cannot demux Matroska) and NOT a libmpv demote.
check(PlayerEngineRouter.engine(for: konrepoMKV, isTorrent: false, isDolbyVision: false,
                                override: .avfoundation, dvDisplayCapable: true) == .avfoundation,
      "override: non-DV MKV reaches the AVPlayer engine")
check(loadFileMountLane(url: konrepoMKV, contentIsDolbyVision: false) == .plainRemux,
      "override: non-DV MKV mounts the PLAIN remux (retains PiP), not raw / not demote")

// 3. DV routing is UNTOUCHED: a DV MKV on a DV display still takes the DV remux lane.
check(PlayerEngineRouter.engine(for: dvMKV, isTorrent: false, isDolbyVision: true,
                                override: .auto, dvDisplayCapable: true) == .avfoundation,
      "auto: DV MKV still routes to AVPlayer (DV mandate, unchanged)")
check(loadFileMountLane(url: dvMKV, contentIsDolbyVision: true) == .dvRemux,
      "DV MKV still mounts the DV remux lane (unchanged)")

// 4. A non-DV AVPlayer-native container direct-plays raw exactly as before (no remux overhead).
check(loadFileMountLane(url: plainMP4, contentIsDolbyVision: false) == .raw,
      "non-DV MP4 stays a raw direct AVPlayer mount (no remux)")

// 5. Proactive candidacy is EXPLICIT-Matroska only.
check(PlayerEngineRouter.isPlainRemuxCandidate(konrepoMKV), "candidate: .mkv path extension")
check(PlayerEngineRouter.isPlainRemuxCandidate(queryMKV), "candidate: mkv token in the query filename")
check(!PlayerEngineRouter.isPlainRemuxCandidate(extensionless),
      "NOT a proactive candidate: extensionless link with no Matroska hint (may be a direct-playable MP4)")
check(!PlayerEngineRouter.isPlainRemuxCandidate(plainMP4), "NOT a candidate: mp4")
check(!PlayerEngineRouter.isPlainRemuxCandidate(loopbackMKV), "NOT a candidate: loopback host")
check(!PlayerEngineRouter.isPlainRemuxCandidate(hlsManifest), "NOT a candidate: HLS manifest")

// 6. The REACTIVE retry gate is broader (probe-and-fail-fast), covering extensionless-actually-MKV, but
//    still refuses AVPlayer-native containers and loopback.
check(PlayerEngineRouter.isPlainRemuxRetryCandidate(extensionless),
      "retry candidate: extensionless link (AVPlayer already proved it cannot demux the bytes)")
check(PlayerEngineRouter.isPlainRemuxRetryCandidate(konrepoMKV), "retry candidate: .mkv")
check(!PlayerEngineRouter.isPlainRemuxRetryCandidate(plainMP4), "NOT a retry candidate: mp4")
check(!PlayerEngineRouter.isPlainRemuxRetryCandidate(hlsManifest), "NOT a retry candidate: HLS manifest")
check(!PlayerEngineRouter.isPlainRemuxRetryCandidate(loopbackMKV), "NOT a retry candidate: loopback")

// 7. Flag resolution: baked default ON; RemoteConfig fleet kill-switch; explicit UserDefaults always wins.
check(PlayerEngineRouter.plainRemuxEnabled(), "flag: baked default is ON")
RemoteConfig.snapshot.features["plainRemux"] = false
check(!PlayerEngineRouter.plainRemuxEnabled(), "flag: RemoteConfig false is a fleet kill-switch")
check(loadFileMountLane(url: konrepoMKV, contentIsDolbyVision: false) == .raw,
      "flag off: the non-DV MKV falls back to the raw mount (pre-#147 behavior)")
RemoteConfig.snapshot.features["plainRemux"] = true
check(PlayerEngineRouter.plainRemuxEnabled(), "flag: RemoteConfig true enables")
UserDefaults.standard.set(false, forKey: PlayerEngineRouter.plainRemuxKey)
check(!PlayerEngineRouter.plainRemuxEnabled(), "flag: explicit local OFF beats a remote ON")
resetFlags()

// 8. HLS delivery rollback disables the plain lane entirely (it has no legacy-loader form).
check(loadFileMountLane(url: konrepoMKV, contentIsDolbyVision: false, deliveryEnabled: false) == .raw,
      "delivery rolled back: plain lane fully off, raw mount as before")

// 9. The reactive force flag mounts the plain remux even for a URL the proactive gate skipped.
check(loadFileMountLane(url: extensionless, contentIsDolbyVision: false, forcePlainRemux: true) == .plainRemux,
      "reactive retry: forcePlainRemux mounts the plain remux for an extensionless URL")
// ...but never for a DV title (the DV lane owns those).
check(loadFileMountLane(url: dvMKV, contentIsDolbyVision: true, forcePlainRemux: true) == .dvRemux,
      "reactive force can never steal a DV title from the DV lane")

// 10. The DV lane's own candidacy still behaves (no regression to the 0.3.14 field fixes).
check(PlayerEngineRouter.dvRemuxCandidacy(url("https://cdn.example.com/dl/Movie.2026.WEB-DL.DV.Atmos.H265-AOC")).candidate,
      "DV candidacy: pseudo-extension release tail still probes (0.3.14 fix intact)")
check(!PlayerEngineRouter.dvRemuxCandidacy(plainMP4).candidate,
      "DV candidacy: native mp4 still vetoes")

resetFlags()
if failures > 0 {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
print("\nALL PASS")
}
}
