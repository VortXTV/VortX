import SwiftUI

/// Native tvOS Home, driven by the **stremio-core** engine (via `CoreBridge`): a "Continue Watching"
/// rail + every catalog of every installed addon, correct by construction, matching the official app.
/// Selecting a title opens its detail page (still the legacy meta resolver for now; migrated later).
struct HomeView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 48) {
                    header
                    if !core.continueWatching.isEmpty {
                        CoreContinueWatchingRow(items: core.continueWatching)
                    }
                    ForEach(core.boardRows) { row in
                        CoreCatalogRowView(row: row)
                    }
                    if core.continueWatching.isEmpty && core.boardRows.isEmpty {
                        if account.isSignedIn { placeholder } else { CoreEmptyState.signedOut }
                    }
                }
                .padding(.vertical, 40)
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.tv.fill").font(.system(size: 40)).foregroundStyle(.cyan)
            Text("StremioX").font(.system(size: 52, weight: .heavy))
            Spacer()
        }
        .padding(.horizontal, 60)
    }

    private var placeholder: some View {
        HStack(spacing: 16) {
            ProgressView()
            Text("Loading your library and catalogs…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 60).padding(.top, 40)
    }
}

/// "Continue Watching" rail from the engine (`continue_watching_preview`), every in-progress title,
/// newest first, with a real progress bar.
struct CoreContinueWatchingRow: View {
    let items: [CoreCWItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue Watching").font(.title2.weight(.semibold)).padding(.horizontal, 60)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(items) { item in
                        VStack(spacing: 12) {
                            NavigationLink {
                                DetailView(type: item.type, id: item.id)
                            } label: {
                                VStack(spacing: 0) {
                                    CorePoster(item.poster)
                                    ProgressView(value: item.progress).tint(.cyan).padding(.top, 6)
                                }
                            }
                            .buttonStyle(.card)
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(.secondary).frame(width: 220)
                        }
                        .frame(width: 220)
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One engine catalog row from the board (all installed-addon catalogs).
struct CoreCatalogRowView: View {
    let row: CoreBoardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(row.title).font(.title2.weight(.semibold)).padding(.horizontal, 60)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(row.items) { item in
                        VStack(spacing: 12) {
                            NavigationLink {
                                DetailView(type: item.type, id: item.id)
                            } label: {
                                CorePoster(item.poster)
                            }
                            .buttonStyle(.card)
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(.secondary).frame(width: 220)
                        }
                        .frame(width: 220)
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Poster artwork (the focusable card content) from an optional URL string.
struct CorePoster: View {
    let urlString: String?
    init(_ urlString: String?) { self.urlString = urlString }

    var body: some View {
        AsyncImage(url: urlString.flatMap { URL(string: $0) }) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
            default: Color.gray.opacity(0.2).overlay(ProgressView())
            }
        }
        .frame(width: 220, height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Just the poster artwork, the focusable element shared by Discover/Search (legacy `MetaPreview`).
struct PosterImage: View {
    let item: MetaPreview

    var body: some View {
        AsyncImage(url: URL(string: item.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Color.gray.opacity(0.2).overlay(ProgressView())
            }
        }
        .frame(width: 220, height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
