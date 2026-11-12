#if os(macOS)
import Darwin
import Foundation

/// A foreground transfer that writes directly to an admitted download directory.
/// The manager owns the launch generation and commits the returned stage only while that launch is current.
final class MacExternalDownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error, LocalizedError, Equatable, Sendable {
        case cancelled
        case destinationUnavailable
        case noSpace
        case writeFailed
        case destinationExists
        case invalidResponse
        case httpStatus(Int)
        case incompleteResponse
        case notMedia
        case network

        var message: String {
            switch self {
            case .cancelled: return String(localized: "Download interrupted. Retry starts the download again.")
            case .destinationUnavailable: return String(localized: "The download folder is unavailable. Reconnect the drive and retry.")
            case .noSpace: return String(localized: "There is not enough space on the selected drive.")
            case .writeFailed: return String(localized: "Could not save the download on the selected drive.")
            case .destinationExists: return String(localized: "A file already exists at the download destination.")
            case .invalidResponse: return String(localized: "The source did not return a downloadable file.")
            case .httpStatus(let status): return String(localized: "The source refused the download (HTTP \(status)).")
            case .incompleteResponse: return String(localized: "The source returned an incomplete download. Try another source or retry.")
            case .notMedia: return String(localized: "This source returned a web page or playlist instead of a downloadable media file.")
            case .network: return String(localized: "The download connection was interrupted. Retry to start again.")
            }
        }

        var errorDescription: String? { message }

        fileprivate static func disk(_ code: Int32) -> Self {
            switch code {
            case ENOSPC, EDQUOT: return .noSpace
            case ENOENT, ENXIO, ENODEV, ESTALE, EROFS, ENOTDIR, ELOOP: return .destinationUnavailable
            default: return .writeFailed
            }
        }
    }

    /// Owns a private, uniquely named stage on the selected volume. Dropping it discards the stage.
    /// Descriptor-relative operations keep cleanup on the originally opened directory.
    final class StagedFile: @unchecked Sendable {
        let url: URL
        private let name: String
        private let lock = NSLock()
        private let locationID: UUID
        private let device: dev_t
        private let inode: ino_t
        private var directoryFD: Int32
        private var fileFD: Int32
        private var written: Int64 = 0
        private var sealed = false

        var bytes: Int64 {
            lock.lock(); defer { lock.unlock() }
            return written
        }

        var fileIdentity: UInt64 { UInt64(inode) }

        fileprivate init(directory: URL, locationID: UUID, stagingID: UUID) throws {
            let directoryFD = try Self.openDirectory(directory)
            guard MacExternalDownloadTransfer.directoryHasMarker(directoryFD, locationID: locationID) else {
                Darwin.close(directoryFD)
                throw Failure.destinationUnavailable
            }
            let name = MacExternalDownloadTransfer.stagingFilename(for: stagingID)
            let fileFD = Darwin.openat(
                directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)
            )
            guard fileFD >= 0 else {
                let failure = Failure.disk(errno)
                Darwin.close(directoryFD)
                throw failure
            }
            var info = stat()
            guard Darwin.fstat(fileFD, &info) == 0 else {
                let failure = Failure.disk(errno)
                Darwin.close(fileFD)
                Darwin.close(directoryFD)
                throw failure
            }
            self.directoryFD = directoryFD
            self.fileFD = fileFD
            self.name = name
            self.locationID = locationID
            self.device = info.st_dev
            self.inode = info.st_ino
            self.url = directory.appendingPathComponent(name)
        }

        fileprivate func append(_ data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            guard fileFD >= 0, !sealed else { throw Failure.writeFailed }
            let (newCount, overflow) = written.addingReportingOverflow(Int64(data.count))
            guard !overflow else { throw Failure.writeFailed }
            try data.withUnsafeBytes { bytes in
                guard let start = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fileFD, start.advanced(by: offset), bytes.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        throw count < 0 ? Failure.disk(errno) : Failure.writeFailed
                    }
                }
            }
            written = newCount
        }

        fileprivate func seal() throws {
            lock.lock(); defer { lock.unlock() }
            guard fileFD >= 0, !sealed, written > 0 else { throw Failure.writeFailed }
            while Darwin.fsync(fileFD) != 0 {
                guard errno == EINTR else { throw Failure.disk(errno) }
            }
            guard ownsEntry(name) else { throw Failure.destinationUnavailable }
            sealed = true
        }

        /// Publish within the same admitted directory, using an atomic rename that refuses any existing name.
        func commit(to destination: URL) throws {
            lock.lock(); defer { lock.unlock() }
            let finalName = destination.lastPathComponent
            guard sealed, directoryFD >= 0, destination.isFileURL,
                  !finalName.isEmpty, finalName != ".", finalName != "..",
                  !finalName.utf8.contains(0), !finalName.contains("/"),
                  ownsEntry(name) else { throw Failure.destinationUnavailable }

            let currentFD = try Self.openDirectory(destination.deletingLastPathComponent())
            defer { Darwin.close(currentFD) }
            var opened = stat()
            var current = stat()
            guard Darwin.fstat(directoryFD, &opened) == 0, Darwin.fstat(currentFD, &current) == 0,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
                  MacExternalDownloadTransfer.directoryHasMarker(directoryFD, locationID: locationID) else {
                throw Failure.destinationUnavailable
            }
            guard Darwin.renameatx_np(directoryFD, name, directoryFD, finalName, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                throw code == EEXIST ? Failure.destinationExists : Failure.disk(code)
            }
            guard ownsEntry(finalName) else { throw Failure.destinationUnavailable }
            closeDescriptors()
        }

        func discard() {
            lock.lock(); defer { lock.unlock() }
            if directoryFD >= 0, ownsEntry(name, checkSize: false) {
                Darwin.unlinkat(directoryFD, name, 0)
            }
            closeDescriptors()
        }

        deinit { discard() }

        private func ownsEntry(_ name: String, checkSize: Bool = true) -> Bool {
            var info = stat()
            return Darwin.fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
                && info.st_dev == device && info.st_ino == inode
                && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
                && (!checkSize || info.st_size == written)
        }

        private func closeDescriptors() {
            if fileFD >= 0 { Darwin.close(fileFD); fileFD = -1 }
            if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
        }

        private static func openDirectory(_ directory: URL) throws -> Int32 {
            guard directory.isFileURL,
                  directory.host?.isEmpty != false || directory.host == "localhost" else {
                throw Failure.destinationUnavailable
            }
            let components = directory.pathComponents
            guard components.first == "/", components.count > 1 else { throw Failure.destinationUnavailable }

            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var fd = Darwin.open("/", flags)
            guard fd >= 0 else { throw Failure.destinationUnavailable }
            // Walk each component under an opened descriptor, refusing both leaf and ancestor symlinks.
            for component in components.dropFirst() {
                guard !component.isEmpty, component != ".", component != "..",
                      !component.utf8.contains(0), !component.contains("/") else {
                    Darwin.close(fd)
                    throw Failure.destinationUnavailable
                }
                let next = Darwin.openat(fd, component, flags)
                Darwin.close(fd)
                guard next >= 0 else { throw Failure.destinationUnavailable }
                fd = next
            }
            return fd
        }
    }

    private let request: URLRequest
    private let directory: URL
    private let locationID: UUID
    private let stagingID: UUID
    private let progress: @Sendable (Int64, Int64) -> Void
    private let completion: @Sendable (Result<StagedFile, Failure>) -> Void

    // All transfer state and URLSession delegate callbacks run on this same serial queue.
    private let queue = DispatchQueue(label: "com.vortx.external-download", qos: .utility)
    private var session: URLSession?
    private var stage: StagedFile?
    private var finished = false
    private var receivedResponse = false
    private var expectedBytes: Int64 = 0
    private var preview = Data()
    private var lastProgressAt: TimeInterval = 0

    init(
        request: URLRequest,
        directory: URL,
        locationID: UUID,
        stagingID: UUID,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        completion: @escaping @Sendable (Result<StagedFile, Failure>) -> Void
    ) {
        self.request = request
        self.directory = directory
        self.locationID = locationID
        self.stagingID = stagingID
        self.progress = progress
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            guard session == nil, !finished else { return }
            guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                finish(.failure(.invalidResponse))
                return
            }
            do {
                stage = try StagedFile(directory: directory, locationID: locationID, stagingID: stagingID)
            } catch let failure as Failure {
                finish(.failure(failure))
                return
            } catch {
                finish(.failure(.writeFailed))
                return
            }
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            var byteRequest = request
            byteRequest.cachePolicy = .reloadIgnoringLocalCacheData
            // File lengths and Content-Range are in the on-disk representation.
            byteRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            session.dataTask(with: byteRequest).resume()
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(.cancelled)) }
    }

    static func stagingFilename(for stagingID: UUID) -> String {
        ".vortx-download-\(stagingID.uuidString).partial"
    }

    /// Verify the selected folder using the same descriptor that will receive writes.
    nonisolated static func directoryHasMarker(_ fd: Int32, locationID: UUID) -> Bool {
        let marker = Darwin.openat(fd, ".vortx-download-location", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { return false }
        defer { Darwin.close(marker) }
        var info = stat()
        guard Darwin.fstat(marker, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == 36, info.st_nlink == 1 else { return false }

        var bytes = [UInt8](repeating: 0, count: 36)
        let readComplete = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(marker, base.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 || errno != EINTR {
                    return false
                }
            }
            return true
        }
        var trailing: UInt8 = 0
        guard readComplete, Darwin.read(marker, &trailing, 1) == 0 else { return false }
        return bytes.elementsEqual(locationID.uuidString.utf8)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Let Foundation supply the redirect request (including its credential handling).
        // Only HTTP(S) responses are useful to this byte transport.
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(self.session === session && !finished && (scheme == "http" || scheme == "https") ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard self.session === session, !finished, !receivedResponse,
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            if self.session === session { finish(.failure(.invalidResponse)) }
            return
        }
        switch Self.expectedLength(of: http, requestedRange: request.value(forHTTPHeaderField: "Range")) {
        case .success(let length):
            receivedResponse = true
            expectedBytes = length
            progress(0, length)
            lastProgressAt = ProcessInfo.processInfo.systemUptime
            completionHandler(.allow)
        case .failure(let failure):
            completionHandler(.cancel)
            finish(.failure(failure))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.session === session, !finished else { return }
        guard receivedResponse, let stage else {
            finish(.failure(.invalidResponse))
            return
        }
        let (newCount, overflow) = stage.bytes.addingReportingOverflow(Int64(data.count))
        guard !overflow, expectedBytes == 0 || newCount <= expectedBytes else {
            finish(.failure(.incompleteResponse))
            return
        }
        if preview.count < 64 {
            preview.append(contentsOf: data.prefix(64 - preview.count))
            if preview.count == 64, Self.looksLikeNonMedia(preview) {
                finish(.failure(.notMedia))
                return
            }
        }
        do {
            try stage.append(data)
        } catch let failure as Failure {
            finish(.failure(failure))
            return
        } catch {
            finish(.failure(.writeFailed))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressAt >= 0.25 {
            lastProgressAt = now
            progress(newCount, expectedBytes)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.session === session, !finished else { return }
        guard error == nil else {
            finish(.failure(.network))
            return
        }
        guard receivedResponse, let stage, stage.bytes > 0,
              expectedBytes == 0 || stage.bytes == expectedBytes else {
            finish(.failure(.incompleteResponse))
            return
        }
        guard !Self.looksLikeNonMedia(preview) else {
            finish(.failure(.notMedia))
            return
        }
        do {
            try stage.seal()
        } catch let failure as Failure {
            finish(.failure(failure))
            return
        } catch {
            finish(.failure(.writeFailed))
            return
        }
        progress(stage.bytes, expectedBytes)
        finish(.success(stage))
    }

    private func finish(_ result: Result<StagedFile, Failure>) {
        guard !finished else { return }
        finished = true
        let active = session
        session = nil
        active?.invalidateAndCancel()
        if case .failure = result { stage?.discard() }
        stage = nil
        completion(result)
    }

    /// A resumed or provider-supplied Range is admissible only if the response still covers the entire file.
    static func expectedLength(of response: HTTPURLResponse, requestedRange: String?) -> Result<Int64, Failure> {
        guard let scheme = response.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.invalidResponse)
        }
        let status = response.statusCode
        guard (200..<300).contains(status) else { return .failure(.httpStatus(status)) }
        guard status != 204, status != 205 else { return .failure(.incompleteResponse) }
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
           encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return .failure(.invalidResponse)
        }
        let range = response.value(forHTTPHeaderField: "Content-Range")
        let declared = response.expectedContentLength
        guard status == 206 else {
            guard range == nil, declared != 0 else { return .failure(.incompleteResponse) }
            return .success(max(0, declared))
        }
        guard let requestedRange, !requestedRange.isEmpty, let range else {
            return .failure(.incompleteResponse)
        }
        let fields = range.lowercased().split(separator: " ")
        guard fields.count == 2, fields[0] == "bytes" else { return .failure(.incompleteResponse) }
        let totals = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard totals.count == 2, let total = Int64(totals[1]), total > 0 else {
            return .failure(.incompleteResponse)
        }
        let bounds = totals[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, Int64(bounds[0]) == 0, Int64(bounds[1]) == total - 1,
              declared < 0 || declared == total else { return .failure(.incompleteResponse) }
        return .success(total)
    }

    private static func looksLikeNonMedia(_ head: Data) -> Bool {
        guard let text = String(data: head, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return text.hasPrefix("#extm3u") || text.hasPrefix("#ext-x-")
            || text.hasPrefix("<!doctype") || text.hasPrefix("<html")
            || text.hasPrefix("<?xml") || text.hasPrefix("<head")
    }
}
#endif
