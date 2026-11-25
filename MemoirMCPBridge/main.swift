// memoir-mcp: stdio <-> Unix socket bridge between MCP clients and Memoir.app.
// Works like `xcrun mcpbridge`: it only forwards bytes, and all MCP handling
// happens in the app, so this rarely needs to change.
import AppKit
import Foundation

// Duplicates RecordingFiles.baseDirectory in the app on purpose: the bridge must
// not link app code. Keep both in sync. The bridge is built in the same
// configuration as the app that embeds it, so DEBUG matches the app's.
#if DEBUG
let socketPath = NSString(string: "~/Library/Application Support/Memoir Dev/mcp.sock").expandingTildeInPath
#else
let socketPath = NSString(string: "~/Library/Application Support/Memoir/mcp.sock").expandingTildeInPath
#endif

func log(_ message: String) {
    FileHandle.standardError.write(Data("memoir-mcp: \(message)\n".utf8))
}

// A closed peer must surface as EPIPE from write(), not kill the process.
signal(SIGPIPE, SIG_IGN)

func connectToSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    if ok { return fd }
    close(fd)
    return nil
}

func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < buffer.count {
        let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += n
    }
    return true
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { writeAll(fd, $0) }
}

/// Copies `from` to `to` until EOF or error. Each chunk is written out before the
/// next read, so messages are never held back waiting for more input.
func pump(from: Int32, to: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(from, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        let ok = buffer.withUnsafeBytes { writeAll(to, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        if !ok { return }
    }
}

/// The app that contains this executable, if any. Running straight out of a
/// build products directory has no enclosing bundle, so callers fall back to the bundle id.
func enclosingAppURL() -> URL? {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if let path = Bundle.main.executablePath { url = URL(fileURLWithPath: path).resolvingSymlinksInPath() }
    while url.path != "/" {
        url.deleteLastPathComponent()
        if url.pathExtension == "app" { return url }
    }
    return nil
}

// Read from the enclosing app, since Config/Local.xcconfig can change it. The
// fallback only matters when the bridge runs outside an app bundle.
#if DEBUG
let fallbackBundleID = "de.jandow.Memoir.debug"
#else
let fallbackBundleID = "de.jandow.Memoir"
#endif
let appBundleID = enclosingAppURL().flatMap { Bundle(url: $0)?.bundleIdentifier } ?? fallbackBundleID

func launchApp() {
    guard let appURL = enclosingAppURL()
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else {
        log("could not locate Memoir.app")
        return
    }
    let config = NSWorkspace.OpenConfiguration()
    // The client launched us, not the user: don't steal focus from them.
    config.activates = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
        if let error { log("launching Memoir failed: \(error.localizedDescription)") }
        done.signal()
    }
    done.wait()
}

enum Failure {
    /// Memoir is running but serves no socket, which is what a turned-off setting looks like.
    case settingOff
    /// Memoir is not running, did not come up in time, or left a socket that refuses connections.
    case unreachable

    var message: String {
        switch self {
        case .settingOff:
            "Memoir access for AI assistants is turned off. Turn it on in Memoir Settings > AI Assistants."
        case .unreachable:
            "Memoir could not be reached. If it is still starting, try again in a moment. If this keeps happening, open Memoir and check that access is turned on in Settings > AI Assistants."
        }
    }
}

enum Connection {
    case connected(Int32)
    case failed(Failure)
}

// Only touched from the main thread, before any relay thread exists.
nonisolated(unsafe) var lastLaunch = Date.distantPast

/// An app that has been running for a while and serves no socket has the setting off, so
/// there is nothing to wait for. Only an app that is still coming up is waited for: one we
/// launch ourselves (at most every 30 seconds, so a client that keeps asking does not pay
/// the wait on each request) or one that was launched a moment ago.
func connectWithLaunch() -> Connection {
    if let fd = connectToSocket() { return .connected(fd) }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first {
        // Launched moments ago (at login, or by the user alongside the assistant): the socket
        // may not exist yet, and "turned off" would be the wrong answer.
        let justLaunched = app.launchDate.map { Date.now.timeIntervalSince($0) < 10 } ?? !app.isFinishedLaunching
        if justLaunched {
            for _ in 0..<30 {
                usleep(100_000)
                if let fd = connectToSocket() { return .connected(fd) }
            }
            return .failed(.unreachable)
        }
        return .failed(FileManager.default.fileExists(atPath: socketPath) ? .unreachable : .settingOff)
    }
    guard Date.now.timeIntervalSince(lastLaunch) > 30 else { return .failed(.unreachable) }
    lastLaunch = .now
    launchApp()
    // The app creates the socket shortly after launch, if the setting is on.
    for _ in 0..<50 {
        if let fd = connectToSocket() { return .connected(fd) }
        usleep(100_000)
    }
    // A slow launch and a turned-off setting look the same from here, so the wording stays neutral.
    return .failed(.unreachable)
}

/// The id of a JSON-RPC request. Notifications carry none and must not be answered.
func requestID(in line: ArraySlice<UInt8>) -> Any? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let id = object["id"], !(id is NSNull) else { return nil }
    return id
}

func writeError(id: Any, _ message: String) -> Bool {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "error": ["code": -32001, "message": message],
    ]
    guard var out = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { return true }
    out.append(0x0A)
    return writeAll(STDOUT_FILENO, out)
}

/// Answers every request with a JSON-RPC error, but tries the socket again for each one:
/// the app may only have been slow to start, or the setting may have been turned on since.
/// Returns the connected socket once that works, with the request that found it (and
/// everything read after it) already written to it. Returns nil when stdin closes.
/// Reads stdin directly, since bytes buffered by `readLine` could not be handed to the socket.
func runDisabledResponder(_ initial: Failure) -> Int32? {
    log(initial.message)
    var pending: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    var atEnd = false
    while true {
        while true {
            let newline = pending.firstIndex(of: 0x0A)
            // At EOF an unterminated last line still counts, as it does for readLine.
            if newline == nil && !(atEnd && !pending.isEmpty) { break }
            let end = newline ?? pending.count
            guard let id = requestID(in: pending[..<end]) else {
                pending.removeSubrange(..<min(end + 1, pending.count))
                continue
            }
            switch connectWithLaunch() {
            case .connected(let fd):
                if !writeAll(fd, Data(pending) + (newline == nil ? [0x0A] : [])) {
                    close(fd)
                    return nil
                }
                return fd
            case .failed(let failure):
                if !writeError(id: id, failure.message) { return nil }
                pending.removeSubrange(..<min(end + 1, pending.count))
            }
        }
        if atEnd { return nil }
        let n = read(STDIN_FILENO, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { atEnd = true; continue }
        pending.append(contentsOf: chunk[0..<n])
    }
}

let sock: Int32
switch connectWithLaunch() {
case .connected(let fd):
    sock = fd
case .failed(let failure):
    guard let fd = runDisabledResponder(failure) else { exit(0) }
    sock = fd
}

// Stdin closing only half-closes the socket: replies to requests already sent must
// still reach stdout, and the app closes its side once it has answered them.
// The socket closing ends the bridge right away, since nobody is left to answer.
let relayed = sock
Thread.detachNewThread {
    pump(from: STDIN_FILENO, to: relayed)
    shutdown(relayed, SHUT_WR)
}
pump(from: relayed, to: STDOUT_FILENO)
exit(0)
