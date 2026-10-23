import Foundation

/// Lists SMB folders through libsmbclient (declared in VortXSMBShim.h; linked by MPVKit-GPL). Each listing uses
/// its own context on a background thread, so blocking network calls never touch the main thread and nothing
/// is shared between listings. The login goes to libsmbclient through its authentication callback, never in
/// the listing URL.
enum NetworkShareSMBClient {
    private static let timeoutMilliseconds: Int32 = 15_000

    /// The visible contents of `folder` (a server root lists its shares).
    static func list(_ folder: URL, root: URL, login: NetworkShareClient.Login) async throws -> [NetworkShareEntry] {
        guard NetworkSharePolicy.isInside(folder, root: root) else { throw NetworkShareError.redirectedAway }
        let raw = try await Task.detached(priority: .userInitiated) {
            try readDirectory(folder.absoluteString, login: login)
        }.value
        return NetworkSharePolicy.visible(NetworkSharePolicy.smbEntries(raw, directory: folder))
    }

    private static func readDirectory(_ url: String, login: NetworkShareClient.Login) throws -> [(name: String, type: UInt32)] {
        guard let context = smbc_new_context() else { throw NetworkShareError.unreachable }
        let credentials = NetworkShareSMBCredentials(username: login.username, password: login.password)
        let box = Unmanaged.passRetained(credentials)
        defer {
            smbc_free_context(context, 1)
            box.release()
        }
        smbc_setTimeout(context, timeoutMilliseconds)
        smbc_setOptionUserData(context, box.toOpaque())
        // With a login, never fall back to guest; without one, guest is the point.
        smbc_setOptionNoAutoAnonymousLogin(context, login.username.isEmpty ? 0 : 1)
        smbc_setFunctionAuthDataWithContext(context, { context, _, _, workgroup, workgroupLength, username, usernameLength, password, passwordLength in
            guard let context, let data = smbc_getOptionUserData(context) else { return }
            let credentials = Unmanaged<NetworkShareSMBCredentials>.fromOpaque(data).takeUnretainedValue()
            smbCopy(credentials.workgroup, into: workgroup, capacity: workgroupLength)
            smbCopy(credentials.username, into: username, capacity: usernameLength)
            smbCopy(credentials.password, into: password, capacity: passwordLength)
        })
        guard smbc_init_context(context) != nil,
              let open = smbc_getFunctionOpendir(context), let read = smbc_getFunctionReaddir(context),
              let close = smbc_getFunctionClosedir(context) else { throw NetworkShareError.unreachable }
        errno = 0
        guard let directory = open(context, url) else { throw error(for: errno) }
        defer { _ = close(context, directory) }
        var entries: [(name: String, type: UInt32)] = []
        // `name` is a C flexible array (`char name[1]`) running past the struct, NUL-terminated.
        guard let nameOffset = MemoryLayout<smbc_dirent>.offset(of: \.name) else { throw NetworkShareError.unreachable }
        while let entry = read(context, directory) {
            let name = String(cString: (UnsafeRawPointer(entry) + nameOffset).assumingMemoryBound(to: CChar.self))
            entries.append((name, entry.pointee.smbc_type))
        }
        return entries
    }

    private static func error(for code: Int32) -> NetworkShareError {
        switch code {
        case EACCES, EPERM: return .unauthorized
        case ENOENT, ENOTDIR, EINVAL: return .notAShare
        default: return .unreachable
        }
    }
}

/// The credentials the auth callback hands libsmbclient, kept alive for the context's lifetime. File-level (as is
/// `smbCopy`) because a C callback cannot capture context, not even an enum's metatype.
private final class NetworkShareSMBCredentials {
    let workgroup: [CChar]
    let username: [CChar]
    let password: [CChar]

    init(username: String, password: String) {
        // "DOMAIN\\user" logs in to a domain; a bare name uses the server's own accounts.
        let parts = username.split(separator: "\\", maxSplits: 1).map(String.init)
        workgroup = Array((parts.count == 2 ? parts[0] : "WORKGROUP").utf8CString)
        self.username = Array((parts.count == 2 ? parts[1] : username).utf8CString)
        self.password = Array(password.utf8CString)
    }
}

/// Copies a NUL-terminated buffer into libsmbclient's fixed-size field, truncating safely.
private func smbCopy(_ source: [CChar], into destination: UnsafeMutablePointer<CChar>?, capacity: Int32) {
    guard let destination, capacity > 0 else { return }
    let count = min(source.count, Int(capacity))
    source.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        destination.update(from: base, count: count)
    }
    destination[Int(capacity) - 1] = 0
}
