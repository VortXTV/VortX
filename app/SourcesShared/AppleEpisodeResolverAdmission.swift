/// Pure route-selection and resolution seam shared by Apple PlayerScreen composition and its standalone
/// contracts. A refreshed CoreVideo is authoritative for this route: when present, the ID-only launch
/// resolver is never eligible as a fallback.
enum AppleEpisodeResolverAdmission {
    enum Route<Output> {
        case launch(id: String, resolver: (String) async -> Output?)
        case refreshed(metadata: CoreVideo, resolver: (CoreVideo) async -> Output?)
    }

    /// Admit exactly one resolver route without mutating caller state. Refreshed metadata wins over the
    /// launch-ID path, and a missing exact resolver rejects the route even if an ID resolver exists.
    static func route<Output>(
        videoID: String,
        refreshedMetadata: CoreVideo?,
        idResolver: ((String) async -> Output?)?,
        metadataResolver: ((CoreVideo) async -> Output?)?
    ) -> Route<Output>? {
        if let refreshedMetadata {
            guard let metadataResolver else { return nil }
            return .refreshed(metadata: refreshedMetadata, resolver: metadataResolver)
        }
        guard let idResolver else { return nil }
        return .launch(id: videoID, resolver: idResolver)
    }

    /// Execute the already-admitted route. The route enum makes the no-fallback decision once, before any
    /// async work or caller-owned playback state can be consumed.
    static func resolve<Output>(_ route: Route<Output>) async -> Output? {
        switch route {
        case .launch(let id, let resolver):
            return await resolver(id)
        case .refreshed(let metadata, let resolver):
            return await resolver(metadata)
        }
    }
}
