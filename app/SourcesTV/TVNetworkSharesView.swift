import SwiftUI

/// Library > Network shares on Apple TV: the shares saved on this device, a form to add one, and a folder
/// browser that plays a video straight from the share (WebDAV or a web folder), no media server needed.
struct TVNetworkSharesView: View {
    @ObservedObject private var store = NetworkShareStore.shared
    @State private var adding = false
    @State private var removing: NetworkShare?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Network shares").screenTitleStyle()
                Text("Play videos straight from a NAS or computer on your network: an SMB share (smb://nas/Movies), a WebDAV address, or a web server's folder listing.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
                Button { adding = true } label: { Label("Add a share", systemImage: "plus") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                if store.shares.isEmpty {
                    Text("No shares yet. On a Synology, QNAP or TrueNAS, turn on its WebDAV service and add that address here.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                ForEach(store.shares) { share in
                    NavigationLink { TVNetworkFolderView(share: share, folder: nil, title: share.name) } label: {
                        TVNetworkShareRow(icon: "externaldrive.connected.to.line.below", title: share.name,
                                          detail: "\(share.kind.label) · \(share.url)")
                    }
                    .vortxCardButton()
                    .contextMenu {
                        Button(role: .destructive) { removing = share } label: { Label("Remove share", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .sheet(isPresented: $adding) { TVAddNetworkShareView() }
        .confirmationDialog("Remove this share?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let share = removing { store.remove(share) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its address and saved password are deleted from this Apple TV. Nothing on the share changes.")
        }
    }
}

/// One folder of a share: its folders and videos. A folder opens the next level; a video plays.
struct TVNetworkFolderView: View {
    let share: NetworkShare
    let folder: URL?
    let title: String
    @EnvironmentObject private var presenter: PlayerPresenter
    @State private var entries: [NetworkShareEntry]?
    @State private var errorMessage: String?
    @State private var playMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(title).screenTitleStyle()
                if let playMessage {
                    Text(playMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    Button { Task { await load() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(ChipButtonStyle(selected: false))
                } else if let entries {
                    if entries.isEmpty {
                        Text("No folders or videos here.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    ForEach(entries) { entry in
                        if entry.isFolder {
                            NavigationLink { TVNetworkFolderView(share: share, folder: entry.url, title: entry.name) } label: {
                                TVNetworkShareRow(icon: "folder.fill", title: entry.name, detail: nil)
                            }
                            .vortxCardButton()
                        } else {
                            Button { play(entry) } label: {
                                TVNetworkShareRow(icon: "play.rectangle.fill", title: entry.name,
                                                  detail: entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                            }
                            .vortxCardButton()
                        }
                    }
                } else {
                    ProgressView().tint(Theme.Palette.textSecondary)
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task(id: folder) { await load() }
    }

    private func load() async {
        errorMessage = nil
        do { entries = try await NetworkShareStore.shared.list(share, folder: folder) }
        catch { errorMessage = (error as? NetworkShareError)?.message ?? NetworkShareError.unreachable.message }
    }

    /// Resolves the file's final address first (redirects only within the share), so the player never takes
    /// the login anywhere else.
    private func play(_ entry: NetworkShareEntry) {
        playMessage = nil
        Task {
            do {
                let target = try await NetworkShareStore.shared.playbackTarget(share, for: entry.url)
                // smb:// plays only through libmpv (its FFmpeg carries the SMB protocol), never AVPlayer.
                presenter.request = PlaybackRequest(url: target.url, title: entry.name, headers: target.headers,
                                                    forceMPV: share.kind == .smb)
            } catch {
                playMessage = (error as? NetworkShareError)?.message ?? NetworkShareError.unreachable.message
            }
        }
    }
}

/// Add a share: its address and, when it needs one, a login. Saved only after the address actually lists.
private struct TVAddNetworkShareView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Add a network share").font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text("For example smb://192.168.1.20/Movies for a shared folder, or 192.168.1.20:5005/video for a Synology WebDAV share. Leave the username empty if the share has no login.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            field { TextField("Address", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled() }
            field { TextField("Name (optional)", text: $name) }
            field { TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled() }
            field { SecureField("Password", text: $password) }
            if let errorMessage {
                Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
            }
            HStack(spacing: Theme.Space.md) {
                Button { save() } label: { Text(busy ? "Checking…" : "Add share").frame(width: 260) }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { dismiss() }.buttonStyle(ChipButtonStyle(selected: false))
            }
        }
        .frame(width: 900)
        .padding(Theme.Space.xl)
    }

    private func save() {
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await NetworkShareStore.shared.add(name: name, address: address, username: username, password: password)
                dismiss()
            } catch {
                errorMessage = (error as? NetworkShareError)?.message ?? NetworkShareError.unreachable.message
            }
            busy = false
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .vortxGlassField(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

private struct TVNetworkShareRow: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon).font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.accent)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                if let detail {
                    Text(detail).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: 1100, alignment: .leading)
        .vortxSettingsCard()
    }
}
