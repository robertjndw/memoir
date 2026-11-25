import AppKit
import Foundation
import Observation

/// Serves the meeting library to AI assistants over MCP. Clients reach it through the
/// `memoir-mcp` bridge, which forwards their stdio to the Unix socket this listens on.
@Observable
final class MCPServer {
    struct Client: Identifiable, Equatable {
        let id: UUID
        var name: String
        var connectedAt: Date
    }

    /// Sessions that completed `initialize`, in connection order.
    private(set) var clients: [Client] = []
    private(set) var isListening = false
    private(set) var lastError: String?

    @ObservationIgnored private let socketURL: URL
    @ObservationIgnored private let library: any MeetingLibrary
    @ObservationIgnored private let indexSource: MCPIndexSource
    @ObservationIgnored private var listener: MCPSocketListener?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    init(socketURL: URL = RecordingFiles.mcpSocketURL, library: any MeetingLibrary) {
        self.socketURL = socketURL
        self.library = library
        indexSource = MCPIndexSource(library: library)
    }

    /// Meetings were added, changed or deleted: the next tool call reads the library afresh.
    func libraryChanged() {
        indexSource.invalidate()
    }

    /// The bridge executable inside the app bundle that MCP clients are configured to run.
    static var bridgeURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/memoir-mcp")
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    func start() {
        guard listener == nil else { return }
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let listener = MCPSocketListener(path: socketURL.path) { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        do {
            try listener.start()
        } catch {
            lastError = error.localizedDescription
            isListening = false
            return
        }
        self.listener = listener
        isListening = true
        lastError = nil
        // A socket file left behind would look like a running server to the bridge.
        terminationObserver = terminationObserver ?? NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        clients = []
        isListening = false
    }

    private func serve(_ connection: MCPConnection) {
        guard let listener else {
            connection.close(force: true)
            return
        }
        let id = UUID()
        let session = MCPSession(tools: MCPTools(library: library, indexSource: indexSource), serverVersion: Self.version)
        Task { [weak self] in
            await Self.run(connection, session: session) { name in
                guard let self, self.listener === listener else { return }
                if let index = self.clients.firstIndex(where: { $0.id == id }) {
                    self.clients[index].name = name
                } else {
                    self.clients.append(Client(id: id, name: name, connectedAt: .now))
                }
            }
            self?.clients.removeAll { $0.id == id }
        }
    }

    /// Answers one connection's requests in order, off the main actor. `named` reports the
    /// client's name once it introduced itself.
    @concurrent private nonisolated static func run(
        _ connection: MCPConnection,
        session: MCPSession,
        named: @escaping @MainActor (String) -> Void
    ) async {
        var reportedName: String?
        for await line in connection.lines {
            if let response = await session.handle(line) {
                connection.send(response)
            }
            guard await session.protocolVersion != nil else { continue }
            let name = await session.clientName ?? "Unknown client"
            if name != reportedName {
                reportedName = name
                await named(name)
            }
        }
        connection.close()
    }
}
