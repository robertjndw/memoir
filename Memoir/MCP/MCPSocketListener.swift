import Darwin
import Foundation

/// Splits a byte stream into newline-terminated lines, keeping the unfinished tail.
nonisolated struct LineBuffer {
    private(set) var pending: [UInt8] = []

    /// Complete lines in `chunk` and whatever was pending before it, without their `\n` (and
    /// a `\r` before it, for clients that send CRLF). Blank lines are dropped.
    mutating func append(_ chunk: some Sequence<UInt8>) -> [String] {
        let scanFrom = pending.count
        pending.append(contentsOf: chunk)
        var lines: [String] = []
        var lineStart = 0
        var index = scanFrom
        while let newline = pending[index...].firstIndex(of: 0x0A) {
            var end = newline
            if end > lineStart, pending[end - 1] == 0x0D { end -= 1 }
            if end > lineStart {
                lines.append(String(decoding: pending[lineStart..<end], as: UTF8.self))
            }
            lineStart = newline + 1
            index = lineStart
        }
        if lineStart > 0 { pending.removeFirst(lineStart) }
        return lines
    }
}

nonisolated enum MCPSocketError: LocalizedError {
    case pathTooLong(String)
    case inUse
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "The socket path is too long: \(path)"
        case .inUse:
            "Another copy of Memoir is already serving AI assistants. Quit it and turn this setting off and on again."
        case .system(let call, let code):
            "Could not open the connection for AI assistants (\(call): \(String(cString: strerror(code))))."
        }
    }
}

/// Listens on a Unix domain socket and hands out one `MCPConnection` per client. All socket
/// state lives on `queue`; the class is only touched from outside through `start` and `stop`.
nonisolated final class MCPSocketListener: @unchecked Sendable {
    private let path: String
    private let onConnection: @Sendable (MCPConnection) -> Void
    private let queue = DispatchQueue(label: "Memoir.MCP.listener")
    private var source: DispatchSourceRead?
    private var connections: [ObjectIdentifier: MCPConnection] = [:]
    /// Identifies our socket file, so `stop` never unlinks one a later instance bound.
    private var inode: ino_t = 0

    init(path: String, onConnection: @escaping @Sendable (MCPConnection) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    /// Binds and starts accepting. Synchronous and quick, so it is fine on the main thread.
    func start() throws(MCPSocketError) {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw .pathTooLong(path) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // A socket file left by a crash is stale and gets replaced, but one that still accepts
        // belongs to another running Memoir (say a debug build next to the installed one).
        if Self.isAccepting(&address) { throw .inUse }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        Self.configure(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw .system("bind", code)
        }
        // Clients cannot connect before listen(), so there is no window with wider permissions.
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system("listen", code)
        }
        var info = stat()
        if stat(path, &info) == 0 { inode = info.st_ino }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Closes every connection and removes the socket file. Safe to call more than once.
    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            for connection in connections.values {
                connection.close(force: true)
            }
            connections.removeAll()
        }
        var info = stat()
        if inode != 0, stat(path, &info) == 0, info.st_ino == inode {
            unlink(path)
        }
        inode = 0
    }

    private func acceptPending(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // The 0600 mode should already keep other users out. Checking the uid is cheap insurance.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            Self.configure(client)
            let connection = MCPConnection(fd: client) { [weak self] connection in
                guard let self else { return }
                queue.async { self.connections[ObjectIdentifier(connection)] = nil }
            }
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
            onConnection(connection)
        }
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A client that quits mid-response must not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func isAccepting(_ address: inout sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}

/// One accepted client. Incoming bytes arrive as `lines`; `send` writes one line back.
nonisolated final class MCPConnection: @unchecked Sendable {
    /// Requests are a few hundred bytes. Anything this long without a newline is not MCP.
    static let maxLineLength = 4 << 20

    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let queue = DispatchQueue(label: "Memoir.MCP.connection")
    private let channel: DispatchIO
    private let onClose: @Sendable (MCPConnection) -> Void
    // Only touched on `queue`.
    private var buffer = LineBuffer()
    private var isClosed = false

    init(fd: Int32, onClose: @escaping @Sendable (MCPConnection) -> Void) {
        (lines, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.onClose = onClose
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in Darwin.close(fd) }
        // Deliver whatever arrived instead of waiting to fill a large read.
        channel.setLimit(lowWater: 1)
    }

    func start() {
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
            if let data, !data.isEmpty, !isClosed {
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
                if buffer.pending.count > Self.maxLineLength {
                    closeOnQueue(force: true)
                    return
                }
            }
            // End of input or an error. Lines already yielded are still answered; whoever
            // consumes `lines` closes the connection once they are done.
            if done { continuation.finish() }
        }
    }

    func send(_ line: String) {
        let bytes = Data(line.utf8) + [0x0A]
        queue.async { [self] in
            guard !isClosed else { return }
            let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: data, queue: queue) { [self] done, _, error in
                if done, error != 0 { closeOnQueue(force: true) }
            }
        }
    }

    /// `force` drops pending writes. Without it, responses already queued still go out first.
    func close(force: Bool = false) {
        queue.async { [self] in closeOnQueue(force: force) }
    }

    private func closeOnQueue(force: Bool) {
        guard !isClosed else { return }
        isClosed = true
        channel.close(flags: force ? .stop : [])
        continuation.finish()
        onClose(self)
    }
}
