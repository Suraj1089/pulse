import Darwin
import Foundation

/// The active file and its selection, in Claude Code's terms: 0-based lines,
/// characters counted in UTF-16 units (the same units as NSRange).
struct ClaudeSelection: Equatable {
    struct Position: Equatable {
        var line: Int
        var character: Int
    }

    var url: URL
    /// At most `ClaudeBridge.maxSelectionCharacters`; the range stays exact.
    var text: String
    var start: Position
    var end: Position

    var isEmpty: Bool { start == end }
}

/// An open file tab, for Claude Code's getOpenEditors and checkDocumentDirty.
struct ClaudeOpenEditor {
    var url: URL
    var isActive: Bool
    var isDirty: Bool
}

/// What a window's bridge asks of its editor.
protocol ClaudeBridgeHost: AnyObject {
    /// Nil when the active tab isn't a file on disk (untitled, Welcome, a diff).
    func claudeSelection() -> ClaudeSelection?
    func claudeOpenEditors() -> [ClaudeOpenEditor]
    /// Saves the open file at `url`: nil when it isn't open here.
    func claudeSave(_ url: URL) -> Bool?
    func claudeConnectionsDidChange(_ count: Int)
}

extension Notification.Name {
    /// View › Share Selection with Claude Code was switched.
    static let claudeIntegrationDidChange = Notification.Name("PulseClaudeIntegrationDidChange")
}

/// Claude Code's IDE connection for one window, the protocol VS Code's
/// extension speaks: a WebSocket server on 127.0.0.1, a lock file in
/// ~/.claude/ide naming its port and auth token, and two environment
/// variables in the window's terminals so `claude` started there connects on
/// its own (`/ide` connects from any other terminal). Claude Code then shows
/// "⧉ 5 lines selected" for the editor's selection, and Send Selection puts
/// `@file#L5-9` in its prompt.
///
/// Lazy and idle-free: started with the window's first terminal (or Connect
/// from Another Terminal), only when Claude Code is installed (its config
/// folder exists). Until Claude connects it is one listening socket, and
/// selection changes cost nothing. The selection text is never kept.
final class ClaudeBridge {
    static let ideName = "Pulse"
    /// Claude Code 2.1 keeps the first 2,000 characters of a selection; the
    /// line range says the rest. Sending more would only cost memory.
    static let maxSelectionCharacters = 64 * 1024
    static let selectionDebounce: TimeInterval = 0.1

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "claudeIntegration") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "claudeIntegration")
            NotificationCenter.default.post(name: .claudeIntegrationDidChange, object: nil)
        }
    }

    /// Claude Code's config folder: $CLAUDE_CONFIG_DIR or ~/.claude. Settable
    /// so tests never write to the real one.
    static var configDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }()

    static var lockDirectory: URL { configDirectory.appendingPathComponent("ide", isDirectory: true) }

    weak var host: ClaudeBridgeHost?
    /// The window's folder; written to the lock file so `/ide` can tell windows apart.
    var workspaceFolders: [URL] = [] {
        didSet { if oldValue != workspaceFolders { writeLockFile() } }
    }

    private var server: LoopbackWebSocketServer?
    private var token = ""
    private(set) var lockURL: URL?
    private var selectionWork: DispatchWorkItem?
    /// What was last sent, to skip repeats; never the text.
    private var lastSent: (url: URL, start: ClaudeSelection.Position, end: ClaudeSelection.Position)?

    var port: UInt16? { server?.port }
    var isRunning: Bool { server != nil }
    var connectionCount: Int { server?.openConnections.count ?? 0 }

    deinit { stop() }

    // MARK: Lifecycle

    /// Variables for a new terminal in this window, starting the bridge if
    /// needed; none when sharing is off or Claude Code isn't installed.
    func terminalEnvironment() -> [String] {
        guard start(), let port else { return [] }
        return ["CLAUDE_CODE_SSE_PORT=\(port)", "ENABLE_IDE_INTEGRATION=true"]
    }

    /// Listens and writes the lock file. False when sharing is off, Claude
    /// Code isn't installed, or the socket or lock file can't be made.
    @discardableResult
    func start() -> Bool {
        if server != nil { return true }
        guard ClaudeBridge.isEnabled,
              FileManager.default.fileExists(atPath: ClaudeBridge.configDirectory.path),
              let server = LoopbackWebSocketServer() else { return false }
        ClaudeBridge.removeStaleLockFiles()
        let token = ClaudeBridge.makeToken()
        self.token = token
        server.authorize = { headers in ClaudeBridge.matches(headers["x-claude-code-ide-authorization"], token) }
        server.onOpen = { [weak self] _ in self?.connectionsChanged() }
        server.onClose = { [weak self] _ in self?.connectionsChanged() }
        server.onMessage = { [weak self] connection, data in self?.handle(data, from: connection) }
        self.server = server
        writeLockFile()
        // Without the lock file Claude Code can't learn the token.
        guard lockURL != nil else {
            stop()
            return false
        }
        return true
    }

    /// Disconnects Claude Code and removes the lock file (window closed,
    /// Pulse quitting, or sharing switched off).
    func stop() {
        selectionWork?.cancel()
        selectionWork = nil
        if let lockURL { try? FileManager.default.removeItem(at: lockURL) }
        lockURL = nil
        let hadClients = connectionCount > 0
        server?.onOpen = nil
        server?.onClose = nil
        server?.onMessage = nil
        server?.stop()
        server = nil
        lastSent = nil
        if hadClients { host?.claudeConnectionsDidChange(0) }
    }

    private func connectionsChanged() {
        if connectionCount == 0 { lastSent = nil }
        host?.claudeConnectionsDidChange(connectionCount)
    }

    // MARK: Lock file

    private func writeLockFile() {
        guard let server else { return }
        let fileManager = FileManager.default
        let directory = ClaudeBridge.lockDirectory
        let lock: [String: Any] = [
            "pid": Int(getpid()),
            "workspaceFolders": workspaceFolders.map(\.path),
            "ideName": ClaudeBridge.ideName,
            "transport": "ws",
            "authToken": token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: lock, options: [.withoutEscapingSlashes]),
              (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])) != nil else { return }
        // Owner-only (it holds the token), and renamed into place so Claude
        // Code never reads half a file. The temporary name doesn't end in .lock.
        let url = directory.appendingPathComponent("\(server.port).lock")
        let temporary = directory.appendingPathComponent(".\(server.port).lock.\(getpid())")
        try? fileManager.removeItem(at: temporary)
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            return
        }
        lockURL = url
    }

    /// Lock files left by a Pulse that didn't quit cleanly (killed, crashed):
    /// only Pulse's own, and only when that process is gone.
    static func removeStaleLockFiles() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: lockDirectory.path) else { return }
        for name in names where name.hasSuffix(".lock") {
            let url = lockDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let lock = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  lock["ideName"] as? String == ideName,
                  let number = lock["pid"] as? Int, let pid = pid_t(exactly: number), pid > 0, pid != getpid(),
                  Darwin.kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, 16)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time, so the token can't be guessed a byte at a time.
    static func matches(_ given: String?, _ token: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8)
        let b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    // MARK: Selection

    /// The editor's selection or active file changed. Debounced, and only
    /// while Claude Code is connected.
    func selectionDidChange() {
        guard connectionCount > 0 else { return }
        selectionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.selectionWork = nil
            self?.sendSelection()
        }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeBridge.selectionDebounce, execute: work)
    }

    /// To every client, or just `client` (one that has just connected).
    private func sendSelection(to client: LoopbackWebSocketServer.Connection? = nil) {
        guard let selection = host?.claudeSelection() else { return }
        if client == nil, let last = lastSent, last.url == selection.url {
            // Same range, or a caret moved within the file: Claude Code would show nothing new.
            if last.start == selection.start, last.end == selection.end { return }
            if last.start == last.end, selection.isEmpty { return }
        }
        guard let data = ClaudeBridge.encode(ClaudeBridge.notification("selection_changed", ClaudeBridge.payload(selection))) else { return }
        lastSent = (selection.url, selection.start, selection.end)
        let clients = client.map { [$0] } ?? server?.openConnections ?? []
        clients.forEach { $0.send(text: data) }
    }

    static func payload(_ selection: ClaudeSelection) -> [String: Any] {
        let range: [String: Any] = [
            "start": ["line": selection.start.line, "character": selection.start.character],
            "end": ["line": selection.end.line, "character": selection.end.character],
            "isEmpty": selection.isEmpty,
        ]
        return [
            "text": selection.text,
            "filePath": selection.url.path,
            "fileUrl": selection.url.absoluteString,
            "selection": range,
        ]
    }

    /// Puts `@file#L5-9` (or `@file` for an empty selection) in Claude Code's
    /// prompt: the Claude running in `shell` (the focused terminal) when there
    /// is one, otherwise every connected Claude. False when none is connected.
    @discardableResult
    func mention(_ selection: ClaudeSelection, inShell shell: pid_t?) -> Bool {
        let clients = server?.openConnections ?? []
        guard !clients.isEmpty else { return false }
        var params: [String: Any] = ["filePath": selection.url.path]
        if !selection.isEmpty {
            // A selection that ends at the start of a line doesn't include that line.
            var lineEnd = selection.end.line
            if selection.end.character == 0, lineEnd > selection.start.line { lineEnd -= 1 }
            params["lineStart"] = selection.start.line
            params["lineEnd"] = lineEnd
        }
        guard let data = ClaudeBridge.encode(ClaudeBridge.notification("at_mentioned", params)) else { return false }
        let inShell: [LoopbackWebSocketServer.Connection] = shell.map { shell in
            clients.filter { client in client.pid.map { ClaudeBridge.process($0, descendsFrom: shell) } ?? false }
        } ?? []
        (inShell.isEmpty ? clients : inShell).forEach { $0.send(text: data) }
        return true
    }

    /// True when `ancestor` is `pid` or one of its parents.
    static func process(_ pid: pid_t, descendsFrom ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 {
            if current == ancestor { return true }
            guard current > 1, let parent = parentProcess(of: current) else { return false }
            current = parent
        }
        return false
    }

    private static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(truncatingIfNeeded: info.pbi_ppid)
    }

    // MARK: Messages from Claude Code

    private func handle(_ data: Data, from client: LoopbackWebSocketServer.Connection) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reply(to: client, id: NSNull(), errorCode: -32700, "Parse error")
            return
        }
        // Without a method it's a response; Pulse sends no requests.
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else {
            handleNotification(method, params, from: client)
            return
        }
        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "pulse", "version": Updater.currentVersion],
            ]
            reply(to: client, id: id, result: result)
        case "tools/list":
            // Nothing for the model: getDiagnostics would always say "no
            // problems", and Pulse has no language server to back it.
            reply(to: client, id: id, result: ["tools": [Any]()])
        case "prompts/list":
            reply(to: client, id: id, result: ["prompts": [Any]()])
        case "resources/list":
            reply(to: client, id: id, result: ["resources": [Any]()])
        case "ping":
            reply(to: client, id: id, result: [:])
        case "tools/call":
            callTool(params, id: id, from: client)
        default:
            reply(to: client, id: id, errorCode: -32601, "Method not found: \(method)")
        }
    }

    private func handleNotification(_ method: String, _ params: [String: Any], from client: LoopbackWebSocketServer.Connection) {
        switch method {
        case "notifications/initialized":
            // So Claude Code shows the open file right away.
            sendSelection(to: client)
        case "ide_connected":
            if let number = params["pid"] as? Int { client.pid = pid_t(exactly: number) }
        default:
            break
        }
    }

    /// The tools Claude Code calls on its own, listed or not.
    private func callTool(_ params: [String: Any], id: Any, from client: LoopbackWebSocketServer.Connection) {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch name {
        case "closeAllDiffTabs":
            // Called at the start of every turn; Pulse opens no diff tabs for Claude.
            result = ClaudeBridge.toolText("CLOSED_0_DIFF_TABS")
        case "close_tab":
            result = ClaudeBridge.toolText("TAB_CLOSED")
        case "getDiagnostics":
            // Called around every edit.
            result = ClaudeBridge.toolText("[]")
        case "getCurrentSelection", "getLatestSelection":
            if let selection = host?.claudeSelection() {
                result = ClaudeBridge.toolJSON(ClaudeBridge.payload(selection).merging(["success": true]) { $1 })
            } else {
                result = ClaudeBridge.toolJSON(["success": false, "message": "No active editor found"])
            }
        case "getWorkspaceFolders":
            let folders = workspaceFolders.map { ["name": $0.lastPathComponent, "uri": $0.absoluteString, "path": $0.path] }
            result = ClaudeBridge.toolJSON(["success": true, "folders": folders, "rootPath": workspaceFolders.first?.path ?? ""])
        case "getOpenEditors":
            let tabs = (host?.claudeOpenEditors() ?? []).map { editor -> [String: Any] in
                ["uri": editor.url.absoluteString, "isActive": editor.isActive, "label": editor.url.lastPathComponent,
                 "isDirty": editor.isDirty]
            }
            result = ClaudeBridge.toolJSON(["tabs": tabs])
        case "checkDocumentDirty":
            let path = arguments["filePath"] as? String ?? ""
            let target = URL(fileURLWithPath: path).standardizedFileURL
            if let editor = host?.claudeOpenEditors().first(where: { $0.url.standardizedFileURL == target }) {
                result = ClaudeBridge.toolJSON(["success": true, "filePath": path, "isDirty": editor.isDirty, "isUntitled": false])
            } else {
                result = ClaudeBridge.toolJSON(["success": false, "message": "Document not open: \(path)"])
            }
        case "saveDocument":
            let path = arguments["filePath"] as? String ?? ""
            switch host?.claudeSave(URL(fileURLWithPath: path)) {
            case true?:
                result = ClaudeBridge.toolJSON(["success": true, "filePath": path, "saved": true, "message": "Document saved successfully"])
            case false?:
                result = ClaudeBridge.toolJSON(["success": false, "message": "Failed to save: \(path)"])
            case nil:
                result = ClaudeBridge.toolJSON(["success": false, "message": "Document not open: \(path)"])
            }
        default:
            // openDiff among them: Claude Code then asks in the terminal, as
            // it does without an editor.
            reply(to: client, id: id, errorCode: -32601, "Tool not found: \(name)")
            return
        }
        reply(to: client, id: id, result: result)
    }

    // MARK: JSON-RPC

    private func reply(to client: LoopbackWebSocketServer.Connection, id: Any, result: [String: Any]) {
        if let data = ClaudeBridge.encode(["jsonrpc": "2.0", "id": id, "result": result]) { client.send(text: data) }
    }

    private func reply(to client: LoopbackWebSocketServer.Connection, id: Any, errorCode code: Int, _ message: String) {
        let error: [String: Any] = ["code": code, "message": message]
        if let data = ClaudeBridge.encode(["jsonrpc": "2.0", "id": id, "error": error]) { client.send(text: data) }
    }

    private static func notification(_ method: String, _ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method, "params": params]
    }

    private static func toolText(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private static func toolJSON(_ object: [String: Any]) -> [String: Any] {
        toolText(encode(object).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
    }

    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
