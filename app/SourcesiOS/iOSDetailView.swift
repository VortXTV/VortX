import SwiftUI

/// Touch detail page — stub during the rebase. Loads meta through the shared engine and shows the
/// hero + synopsis; the ranked Watch Now button, quality picker, source list, and the touch player
/// land in the next iterations (0.3.0 Track 1.3-1.4).
struct iOSDetailView: View {
    let id: String
    let type: String
    let title: String
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                AsyncImage(url: URL(string: meta?.background ?? meta?.poster ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(16/9, contentMode: .fill)
                    default: Theme.Palette.surface1.aspectRatio(16/9, contentMode: .fill)
                    }
                }
                .clipped()
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(meta?.name ?? title)
                        .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                    if let info = meta?.releaseInfo { Text(info).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary) }
                    if let overview = meta?.description {
                        Text(overview).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Label("Watch Now and source picker land in the next 0.3.0 build", systemImage: "hammer")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.top, Theme.Space.sm)
                }
                .padding(.horizontal, Theme.Space.md)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(meta?.name ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { core.loadMeta(type: type, id: id) }
        .onDisappear { core.unloadMeta() }
    }

    // metaDetails is a single shared @Published on the CoreBridge singleton. Guard on the id so a
    // previous page's still-resident meta (A -> back -> B) can't render A's hero/title under B.
    // Mirrors tvOS DetailView.
    private var meta: CoreMetaItem? {
        let m = core.metaDetails?.meta
        return m?.id == id ? m : nil
    }
}
