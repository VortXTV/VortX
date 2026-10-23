import SwiftUI

/// Library > Network shares on iPhone, iPad and Mac: the shares saved on this device, a form to add one, and a
/// folder browser that plays a video straight from the share (WebDAV or a web folder). Playback goes through
/// the Library's player cover via `onPlay`, carrying the share's login only for files inside it.
struct iOSNetworkSharesView: View {
    let onPlay: (iOSPlayerLaunch) -> Void
    @ObservedObject private var store = NetworkShareStore.shared
    @State private var adding = false
    @State private var removing: NetworkShare?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Play videos straight from a NAS or computer on your network: an SMB share (smb://nas/Movies), a WebDAV address, or a web server's folder listing.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                Button { adding = true } label: { Label("Add a share", systemImage: "plus") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                if store.shares.isEmpty {
                    Text("No shares yet. On a Synology, QNAP or TrueNAS, turn on its WebDAV service and add that address here.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                ForEach(store.shares) { share in
                    NavigationLink { iOSNetworkFolderView(share: share, folder: nil, title: share.name, onPlay: onPlay) } label: {
                        iOSNetworkShareRow(icon: "externaldrive.connected.to.line.below", title: share.name,
                                           detail: "\(share.kind.label) · \(share.url)")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { removing = share } label: { Label("Remove share", systemImage: "trash") }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(Text("Network shares"))
        .sheet(isPresented: $adding) { iOSAddNetworkShareView() }
        .confirmationDialog("Remove this share?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let share = removing { store.remove(share) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its address and saved password are deleted from this device. Nothing on the share changes.")
        }
    }
}

/// One folder of a share: folders open the next level, videos play.
private struct iOSNetworkFolderView: View {
    let share: NetworkShare
    let folder: URL?
    let title: String
    let onPlay: (iOSPlayerLaunch) -> Void
    @State private var entries: [NetworkShareEntry]?
    @State private var errorMessage: String?
    @State private var playMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
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
                            NavigationLink { iOSNetworkFolderView(share: share, folder: entry.url, title: entry.name, onPlay: onPlay) } label: {
                                iOSNetworkShareRow(icon: "folder.fill", title: entry.name, detail: nil)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { play(entry) } label: {
                                iOSNetworkShareRow(icon: "play.rectangle.fill", title: entry.name,
                                                   detail: entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(Theme.Space.lg)
                }
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(Text(title))
        .task(id: folder) { await load() }
        .refreshable { await load() }
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
                onPlay(iOSPlayerLaunch(url: target.url, title: entry.name, headers: target.headers))
            } catch {
                playMessage = (error as? NetworkShareError)?.message ?? NetworkShareError.unreachable.message
            }
        }
    }
}

/// Add a share: its address and, when it needs one, a login. Saved only after the address actually lists.
private struct iOSAddNetworkShareView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("For example smb://192.168.1.20/Movies for a shared folder, or 192.168.1.20:5005/video for a Synology WebDAV share.")
                }
                Section {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                } footer: {
                    Text("Leave the username empty if the share has no login. The password stays in this device's Keychain.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Theme.Palette.danger) }
                }
            }
            .navigationTitle(Text("Add a share"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Checking…" : "Add") { save() }
                        .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
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
}

private struct iOSNetworkShareRow: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Palette.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
                if let detail {
                    Text(detail).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .vortxSettingsCard()
        .contentShape(Rectangle())
    }
}
