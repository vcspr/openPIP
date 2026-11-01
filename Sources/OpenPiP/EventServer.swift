import Foundation
import OpenPiPCore

/// Receives events on a user-only Unix stream socket and by tailing a jsonl file.
///
///   ~/.openpip/openpip.sock   one JSON object per line, any number of lines per connection
///   ~/.openpip/events.jsonl    fallback; only lines added after launch are read
final class EventServer {
    let directory: URL
    var socketPath: String { directory.appendingPathComponent("openpip.sock").path }
    var jsonlPath: String { directory.appendingPathComponent("events.jsonl").path }

    private let onEvent: (Event) -> Void
    private let queue = DispatchQueue(label: "app.hemii.openpip.events")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: LineBuffer] = [:]
    private static let maxClients = 32

    private var tailTimer: DispatchSourceTimer?
    private var tailOffset: UInt64 = 0
    private var tailBuffer = LineBuffer()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openpip"),
         onEvent: @escaping (Event) -> Void) {
        self.directory = directory
        self.onEvent = onEvent
    }

    struct SocketError: LocalizedError {
        let step: String, code: Int32
        var errorDescription: String? { "\(step) failed: \(String(cString: strerror(code)))" }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        try openSocket()
        startTail()
    }

    func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for (_, s) in clients { s.cancel() }
            clients.removeAll()
            tailTimer?.cancel()
            tailTimer = nil
        }
        unlink(socketPath)
    }

    // MARK: socket

    private func openSocket() throws {
        let path = socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(step: "socket", code: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw SocketError(step: "socket path", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // Create the socket file as 0600 from the start, then make sure.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else { let e = errno; close(fd); throw SocketError(step: "bind", code: e) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw SocketError(step: "listen", code: e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
    }

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Only this user may talk to us, even if file modes are changed.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), clients.count < Self.maxClients else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // We never reply. Closing our write side lets one-shot clients like `nc -U` exit at once.
            shutdown(fd, SHUT_WR)

            buffers[fd] = LineBuffer()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readClient(fd) }
            source.setCancelHandler { close(fd) }
            clients[fd] = source
            source.resume()
        }
    }

    private func readClient(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                deliver(buffers[fd]?.append(Data(chunk[0..<n])) ?? [])
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                deliver(buffers[fd]?.flush() ?? [])
                buffers[fd] = nil
                clients.removeValue(forKey: fd)?.cancel()
                return
            } else {
                return
            }
        }
    }

    // MARK: jsonl tail

    private func startTail() {
        tailOffset = fileSize(jsonlPath) ?? 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.pollTail() }
        timer.resume()
        tailTimer = timer
    }

    private func pollTail() {
        guard let size = fileSize(jsonlPath) else { tailOffset = 0; return }
        if size < tailOffset { tailOffset = 0; tailBuffer = LineBuffer() } // truncated or replaced
        guard size > tailOffset, let handle = FileHandle(forReadingAtPath: jsonlPath) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: tailOffset)
            let data = try handle.read(upToCount: Int(min(size - tailOffset, 1 << 20))) ?? Data()
            tailOffset += UInt64(data.count)
            deliver(tailBuffer.append(data))
        } catch {
            return
        }
    }

    private func fileSize(_ path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(st.st_size)
    }

    private func deliver(_ lines: [String]) {
        let events = lines.compactMap(Event.parse)
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [onEvent] in events.forEach(onEvent) }
    }
}
