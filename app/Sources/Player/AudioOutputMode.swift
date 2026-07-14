import Foundation

/// How the player drives audio output, the escape hatch for soundbars and receivers that
/// mis-negotiate audio over HDMI-ARC. The recurring "no sound through my soundbar, but the same
/// Apple TV plays fine straight to the TV, and official Stremio plays it" reports are an ARC
/// format/layout mismatch: the audio path the player hands the bar is one it silently drops.
/// Channel count alone cannot detect this (a 2.1 bar and a TV both report ~2 channels yet one is
/// silent), so the viewer gets an explicit switch.
///
/// Device-scoped: it describes the audio hardware attached to THIS Apple TV, not the viewer, so it
/// stays global (like the HDR tonemap and performance-mode toggles), never per-profile.
enum AudioOutputMode: String, CaseIterable {
    /// Match the route: a multichannel receiver gets native surround, anything stereo gets a clean
    /// downmix. The right default for most setups.
    case auto
    /// Force a guaranteed stereo (2.0) downmix and the most compatible session mode. The reliable
    /// fix when a soundbar or receiver plays no sound, because every endpoint can render 2.0.
    case stereo
    /// Force multichannel even when the route reports stereo, for a receiver that under-reports.
    case surround
    /// Bitstream Dolby / DTS untouched to an AV receiver that decodes them itself (lossless TrueHD /
    /// DTS-HD MA), rather than decoding to PCM here. For a real AVR; if the route can't take the
    /// bitstream, mpv falls back to decoding so it never goes silent.
    case passthrough

    static let key = "stremiox.audioOutputMode"

    static var current: AudioOutputMode {
        AudioOutputMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }

    /// The mpv `audio-spdif` codec list when bitstreaming, else nil (decode to PCM). Only Passthrough
    /// bitstreams; the decode modes leave this nil so DTS/Atmos are decoded to multichannel PCM.
    var spdifCodecs: String? {
        self == .passthrough ? "ac3,dts,eac3,truehd,dts-hd" : nil
    }

    /// tvOS bitstream EXPERIMENT gate (Atmos survival on the libmpv fallback lane). App-side spdif on tvOS
    /// historically WEDGED the audiounit AO open and froze the whole player (#78/#101), so Passthrough is
    /// deliberately ignored there today and a DV demote lands on decoded multichannel PCM: the receiver loses
    /// the E-AC-3 JOC (Atmos) bitstream even when it could take it. The avfoundation AO (MPVKit n8.1.2) opens
    /// the route the way AVPlayer does, which MAY accept a compressed format cleanly, but there is no Atmos
    /// receiver in the build loop to prove it, so arming is DOUBLE-gated: the user's explicit Passthrough pick
    /// AND this flag (an explicit UserDefaults value wins for local testing, else the RemoteConfig `tvosSpdif`
    /// feature, default FALSE). Fleet default stays exactly today's decode path until the owner device-verifies;
    /// a bad outcome is one RemoteConfig flip (or Settings pick) away from off. iOS is untouched (its spdif
    /// gating already works); macOS keeps mpv's native coreaudio negotiation.
    static let tvosSpdifKey = "stremiox.tvosSpdif"
    static var tvosSpdifExperimentEnabled: Bool {
        if UserDefaults.standard.object(forKey: tvosSpdifKey) != nil {
            return UserDefaults.standard.bool(forKey: tvosSpdifKey)
        }
        return RemoteConfig.snapshot.isFeatureOn("tvosSpdif", default: false)
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .stereo: return "Stereo"
        case .surround: return "Surround"
        case .passthrough: return "Passthrough"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Matches your TV or receiver. Best for most setups."
        case .stereo: return "Forces a stereo downmix. Choose this if a soundbar or receiver plays no sound."
        case .surround: return "Decodes Dolby/DTS to multichannel PCM and forces it on. Pick this if a soundbar that doesn't support DTS drops to stereo."
        case .passthrough: return "Hands Dolby/DTS to the system audio path for your receiver. On Apple TV it decodes and lets the OS route it (app-side bitstream froze playback, so it's off there); use Auto for most setups."
        }
    }
}
