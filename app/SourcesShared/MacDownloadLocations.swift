#if os(macOS)
import AppKit
import Darwin
import Foundation
import SwiftUI

/// Local-only locations for macOS downloads. A record retains its location ID when the preference changes.
@MainActor
final class MacDownloadLocations: ObservableObject {
    static let shared = MacDownloadLocations()

    private static let defaultsKey = "vortx.downloads.macLocations.v1"
    private static let directoryName = "VortX Downloads"
    private static let markerName = ".vortx-download-location"

    private struct Location: Codable {
        let id: UUID
        let bookmark: Data
        let name: String
        let volumeID: String?
    }

    private struct State: Codable {
        var selected: UUID?
        var locations: [Location]
    }

    enum LocationError: LocalizedError {
        case unavailable, cannotPrepare, unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "Reconnect the download drive and try again.")
            case .cannotPrepare: return String(localized: "VortX could not prepare a downloads folder at this location.")
            case .unsupportedFormat: return String(localized: "This drive’s format does not support safely finishing downloads. Choose another drive.")
            }
        }
    }

    @Published private(set) var selectedFolderURL: URL?
    /// Refresh all download surfaces on mount changes, including records whose folder is no longer selected.
    @Published private(set) var volumeRevision = 0
    private let defaults: UserDefaults
    private var state: State

    var selectedLocationID: UUID? { state.selected }
    var selectedFolderName: String? {
        guard let id = state.selected else { return nil }
        return state.locations.first { $0.id == id }?.name ?? String(localized: "Download drive")
    }

    init(defaults: UserDefaults = .standard, observeVolumeChanges: Bool = true) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State(selected: nil, locations: [])
        refresh()
        guard observeVolumeChanges else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func choose(_ folder: URL) throws {
        guard folder.isFileURL,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LocationError.cannotPrepare
        }
        let parent = folder.resolvingSymlinksInPath()
        let directory = parent.appendingPathComponent(Self.directoryName, isDirectory: true)
        if let known = state.locations.first(where: {
            guard let current = resolve($0) else { return false }
            return current == directory || current == parent
        }) {
            try select(known.id)
            return
        }

        // Create a child exclusively. Never take ownership of an existing folder or replace its files.
        let id = UUID()
        let volume = try parent.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeSupportsExclusiveRenamingKey])
        guard volume.volumeSupportsExclusiveRenaming != false else { throw LocationError.unsupportedFormat }
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw LocationError.cannotPrepare }
        do {
            let marker = directory.appendingPathComponent(Self.markerName)
            try Data(id.uuidString.utf8).write(to: marker, options: .withoutOverwriting)
            let bookmark = try directory.bookmarkData(options: [])
            let location = Location(id: id, bookmark: bookmark, name: parent.lastPathComponent, volumeID: volume.volumeUUIDString)
            guard resolve(location) == directory else { throw LocationError.cannotPrepare }
            var next = state
            next.locations.append(location)
            next.selected = id
            try save(next)
        } catch {
            let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if descriptor >= 0 {
                if MacExternalDownloadTransfer.directoryHasMarker(descriptor, locationID: id) {
                    _ = unlinkat(descriptor, Self.markerName, 0)
                }
                Darwin.close(descriptor)
            }
            _ = Darwin.rmdir(directory.path) // Empty only, including after a failed marker write.
            throw LocationError.cannotPrepare
        }
    }

    func useDefault() {
        try? select(nil)
    }

    func directory(for id: UUID) -> URL? {
        state.locations.first { $0.id == id }.flatMap(resolve)
    }

    /// Remove only a partial tied to a persisted attempt on its original, verified volume.
    func discardIncomplete(location: UUID, attempt: UUID) -> Bool {
        removeManagedFile(location: location, filename: MacExternalDownloadTransfer.stagingFilename(for: attempt))
    }

    /// A final file is owned only when it matches the persisted installation receipt.
    func removeInstalledFile(location: UUID, filename: String, fileID: UInt64, bytes: Int64) -> Bool {
        removeManagedFile(location: location, filename: filename, receipt: (fileID, bytes))
    }

    private func removeManagedFile(
        location: UUID, filename: String, receipt: (fileID: UInt64, bytes: Int64)? = nil
    ) -> Bool {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else { return false }
        return withLocationDirectory(location) { descriptor in
            var info = stat()
            guard fstatat(descriptor, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
            if let receipt, info.st_mode & S_IFMT != S_IFREG ||
                UInt64(info.st_ino) != receipt.fileID || info.st_size != receipt.bytes {
                return true // Preserve a file VortX cannot establish ownership of.
            }
            guard info.st_mode & S_IFMT == S_IFREG else { return false }
            return unlinkat(descriptor, filename, 0) == 0
        }
    }

    func matchesInstalledFile(location: UUID, filename: String, fileID: UInt64, bytes: Int64) -> Bool {
        withLocationDirectory(location) { descriptor in
            var info = stat()
            return fstatat(descriptor, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                info.st_mode & S_IFMT == S_IFREG && info.st_size == bytes && UInt64(info.st_ino) == fileID
        }
    }

    private func withLocationDirectory(_ location: UUID, perform: (Int32) -> Bool) -> Bool {
        guard let directory = directory(for: location) else { return false }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard MacExternalDownloadTransfer.directoryHasMarker(descriptor, locationID: location) else { return false }
        return perform(descriptor)
    }

    func refresh() {
        selectedFolderURL = state.selected.flatMap(directory(for:))
        volumeRevision &+= 1
    }

    private func select(_ id: UUID?) throws {
        var next = state
        next.selected = id
        try save(next)
    }

    private func save(_ next: State) throws {
        defaults.set(try JSONEncoder().encode(next), forKey: Self.defaultsKey)
        state = next
        refresh()
    }

    private func resolve(_ location: Location) -> URL? {
        var stale = false
        guard let candidate = try? URL(resolvingBookmarkData: location.bookmark,
                                       options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                       bookmarkDataIsStale: &stale),
              let attributes = try? candidate.resourceValues(forKeys: [
                  .isDirectoryKey, .isSymbolicLinkKey, .volumeUUIDStringKey,
              ]),
              attributes.isDirectory == true, attributes.isSymbolicLink == false,
              location.volumeID.map({ $0 == attributes.volumeUUIDString }) ?? true else { return nil }
        let directory = candidate.resolvingSymlinksInPath()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard MacExternalDownloadTransfer.directoryHasMarker(descriptor, locationID: location.id) else { return nil }
        return directory
    }
}
#endif
