/// App-owned Apple mpv trust policy. This does not replace or assert freshness of OS distrust data.
enum MPVTLSOptions {
    struct Option: Equatable, Sendable {
        let name: String
        let value: String
    }

    struct Rejection: Equatable, Sendable {
        let name: String
        let status: Int32
    }

    /// Keep rendering/audio/network-header overrides, but never hand indirect option loaders or
    /// trust dictionaries to mpv. Do not attempt to sanitize mpv's escaped dictionary grammar.
    static func allowsCustomOption(_ name: String, value: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first,
              isASCIIAlphanumeric(first),
              bytes.allSatisfy({ isASCIIAlphanumeric($0) || $0 == 45 }),
              !value.utf8.contains(0) else { return false }

        // These are the app's existing documented, built-in rendering profiles, not arbitrary
        // user/config-defined profiles. Config/include/profile mutation channels remain blocked.
        if name == "profile" { return value == "gpu-hq" || value == "fast" }

        var canonical = name.lowercased()
        while canonical.hasPrefix("no-") { canonical = String(canonical.dropFirst(3)) }
        guard !canonical.isEmpty else { return false }
        return !reservedRoots.contains { canonical == $0 || canonical.hasPrefix($0 + "-") }
    }

    static func streamOptions(live: Bool) -> String {
        live
            ? "tls_verify=1,reconnect=1,reconnect_streamed=0,reconnect_delay_max=1"
            : "tls_verify=1,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7,multiple_requests=1"
    }

    static func demuxerOptions(live: Bool) -> String {
        live ? "tls_verify=1,live_start_index=-3" : "tls_verify=1"
    }

    static var initializationOptions: [Option] {
        var options: [Option] = [
            .init(name: "config", value: "no"),
            .init(name: "load-scripts", value: "no"),
            .init(name: "resume-playback", value: "no"),
            .init(name: "tls-verify", value: "yes"),
            .init(name: "stream-lavf-o", value: streamOptions(live: false)),
            .init(name: "demuxer-lavf-o", value: demuxerOptions(live: false)),
            .init(name: "demuxer-lavf-propagate-opts", value: "yes"),
        ]
        // This pinned macOS build includes Lua's built-in downloader hook. load-scripts=no
        // disables external scripts, not that hook. iOS/tvOS omit Lua and the ytdl option.
        #if os(macOS)
        options.append(.init(name: "ytdl", value: "no"))
        #endif
        return options
    }

    /// Synchronous setter boundary: stop on the first rejection; never initialize a partial policy.
    static func enforceInitialization(
        setOption: (String, String) -> Int32
    ) -> Rejection? {
        for option in initializationOptions {
            let status = setOption(option.name, option.value)
            if status < 0 { return .init(name: option.name, status: status) }
        }
        return nil
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }

    private static let reservedRoots = [
        "tls", "config", "include", "profile", "script", "scripts", "load-scripts",
        "use-filedir-conf", "resume-playback", "watch-later", "reset-on-next-file",
        "input-conf", "input-file", "input-ipc-server", "input-ipc-client", "input-commands",
        "stream-lavf-o", "demuxer-lavf-o", "demuxer-lavf-propagate-opts",
        "ytdl", "o", "of", "ofopts", "ovc", "ovcopts", "oac", "oacopts",
    ]
}
