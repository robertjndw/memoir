// memoir-mcp: stdio <-> Unix socket bridge between MCP clients and Memoir.app.
// Works like `xcrun mcpbridge`: it only forwards bytes, and all MCP handling
// happens in the app, so this rarely needs to change.
import AppKit
import Foundation

// Duplicates RecordingFiles.baseDirectory in the app on purpose: the bridge must
// not link app code. Keep both in sync.
let socketPath = NSString(string: "~/Library/Application Support/Memoir/mcp.sock").expandingTildeInPath
let appBundleID = "de.jandow.Memoir"
let disabledMessage = "Memoir access for AI assistants is turned off. Turn it on in Memoir Settings > AI Assistants."

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

func launchAppIfNeeded() {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty else { return }
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

func connectWithLaunch() -> Int32? {
    if let fd = connectToSocket() { return fd }
    launchAppIfNeeded()
    // The app creates the socket shortly after launch, if the setting is on.
    for _ in 0..<50 {
        if let fd = connectToSocket() { return fd }
        usleep(100_000)
    }
    return nil
}

/// Answers every request with a JSON-RPC error until stdin closes. Notifications
/// carry no id and must not be answered.
func runDisabledResponder() {
    log(disabledMessage)
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"], !(id is NSNull) else { continue }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32001, "message": disabledMessage],
        ]
        guard var out = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { continue }
        out.append(0x0A)
        if !writeAll(STDOUT_FILENO, out) { break }
    }
}

guard let sock = connectWithLaunch() else {
    runDisabledResponder()
    exit(0)
}

// Stdin closing only half-closes the socket: replies to requests already sent must
// still reach stdout, and the app closes its side once it has answered them.
// The socket closing ends the bridge right away, since nobody is left to answer.
Thread.detachNewThread {
    pump(from: STDIN_FILENO, to: sock)
    shutdown(sock, SHUT_WR)
}
pump(from: sock, to: STDOUT_FILENO)
exit(0)
