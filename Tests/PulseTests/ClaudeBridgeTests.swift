import AppKit
import SwiftTerm
import XCTest
@testable import Pulse

/// Claude Code's IDE connection: the lock file, the WebSocket handshake and
/// frames, the replies Claude Code needs, and the selection it is sent. A
/// small raw-socket client stands in for Claude Code; the exchanges follow
/// what the real CLI (2.1.301) sends. Everything lives in the test's temp
/// folder (PulseTestCase points the Claude config folder there).
final class ClaudeBridgeTests: PulseTestCase {
    private static let sample = "alpha\nbeta 😀 gamma\ndelta\nepsilon\n"

    // MARK: Helpers

    /// Claude Code "installed": its config folder exists.
    private func installClaudeCode() throws {
        try FileManager.default.createDirectory(at: ClaudeBridge.configDirectory, withIntermediateDirectories: true)
    }

    private func makeProject(_ files: [String: String] = ["main.swift": ClaudeBridgeTests.sample]) throws -> (URL, MainWindowController) {
        let root = try makeFolder(files: files)
        let first = files.keys.sorted().first!
        return (root, makeController(opening: [root, root.appendingPathComponent(first)]))
    }

    private func lockFile(_ controller: MainWindowController) throws -> [String: Any] {
        let url = try XCTUnwrap(controller.editor.claude.lockURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func startBridge(_ controller: MainWindowController) throws -> (port: UInt16, token: String) {
        try installClaudeCode()
        XCTAssertTrue(controller.editor.claude.start())
        let token = try XCTUnwrap(lockFile(controller)["authToken"] as? String)
        return (try XCTUnwrap(controller.editor.claude.port), token)
    }

    /// A client past the handshake, like Claude Code after it read the lock file.
    private func connect(_ controller: MainWindowController) throws -> TestIDEClient {
        let (port, token) = try startBridge(controller)
        let client = try TestIDEClient(port: port)
        client.handshake(token: token)
        let head = try XCTUnwrap(response(client))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        return client
    }

    /// Connected and initialized, with the first selection_changed consumed.
    private func connectAndInitialize(_ controller: MainWindowController) throws -> TestIDEClient {
        let client = try connect(controller)
        XCTAssertNotNil(request(client, "initialize", ["protocolVersion": "2025-11-25"], id: 0))
        client.sendJSON(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(nextMessage(client)?["method"] as? String, "selection_changed", "the open file is sent on connect")
        return client
    }

    private func response(_ client: TestIDEClient) -> String? {
        var head: String?
        wait(timeout: 5, "handshake response") {
            client.pump()
            head = client.takeHTTPResponse()
            return head != nil || client.peerClosed
        }
        return head
    }

    private func nextMessage(_ client: TestIDEClient, file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
        var message: [String: Any]?
        wait(timeout: 5, "a message from Pulse", file: file, line: line) {
            client.pump()
            // Other frames (pongs) are skipped.
            while let frame = client.takeFrame() {
                if frame.opcode == 0x1 {
                    message = (try? JSONSerialization.jsonObject(with: Data(frame.payload))) as? [String: Any]
                    return true
                }
            }
            return false
        }
        return message
    }

    private func nextFrame(_ client: TestIDEClient) -> (opcode: UInt8, payload: [UInt8])? {
        var frame: (opcode: UInt8, payload: [UInt8])?
        wait(timeout: 5, "a frame from Pulse") {
            client.pump()
            frame = client.takeFrame()
            return frame != nil
        }
        return frame
    }

    /// Sends a request and waits for its response (notifications in between are skipped).
    private func request(_ client: TestIDEClient, _ method: String, _ params: [String: Any] = [:], id: Int) -> [String: Any]? {
        client.sendJSON(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        for _ in 0..<10 {
            guard let message = nextMessage(client) else { return nil }
            if message["id"] as? Int == id { return message }
        }
        return nil
    }

    private func callTool(_ client: TestIDEClient, _ name: String, _ arguments: [String: Any] = [:], id: Int) -> [String: Any]? {
        request(client, "tools/call", ["name": name, "arguments": arguments], id: id)
    }

    private func toolText(_ response: [String: Any]?) -> String? {
        ((response?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    private func toolJSON(_ response: [String: Any]?) -> [String: Any]? {
        toolText(response).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    /// Nothing more arrives within `seconds`.
    private func assertQuiet(_ client: TestIDEClient, for seconds: TimeInterval = 0.4, file: StaticString = #filePath, line: UInt = #line) {
        spin(seconds)
        client.pump()
        XCTAssertNil(client.takeFrame(), "expected nothing to be sent", file: file, line: line)
    }

    private func select(_ text: String, in controller: MainWindowController) {
        let textView = controller.editor.textView!
        textView.setSelectedRange((textView.string as NSString).range(of: text))
    }

    private func params(_ message: [String: Any]?) -> [String: Any] {
        message?["params"] as? [String: Any] ?? [:]
    }

    private func position(_ params: [String: Any], _ key: String) -> [Int] {
        let point = (params["selection"] as? [String: Any])?[key] as? [String: Any]
        return [point?["line"] as? Int ?? -1, point?["character"] as? Int ?? -1]
    }

    /// Runs `command` in the window's first terminal and returns its output.
    private func shellOutput(_ command: String, in controller: MainWindowController) throws -> String {
        let view = try XCTUnwrap(views(LocalProcessTerminalView.self, in: controller).last(where: { $0.window != nil }))
        let file = temp.appendingPathComponent("out-\(UUID().uuidString)")
        view.send(txt: "\(command) > '\(file.path)'\r")
        wait(timeout: 10, "shell output") {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").hasSuffix("\n")
        }
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Handshake key

    func testHandshakeKeyAndSHA1MatchTheirStandards() {
        XCTAssertEqual(LoopbackWebSocketServer.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455's example")
        func hex(_ text: String) -> String { LoopbackWebSocketServer.sha1(Array(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    // MARK: Lifecycle

    func testWithoutClaudeCodeInstalledNothingStartsAndTerminalsArePlain() throws {
        let (_, controller) = try makeProject()
        XCTAssertFalse(controller.editor.claude.start(), "no config folder: Claude Code isn't installed")
        controller.editor.showTerminal()
        layout(controller)
        XCTAssertFalse(controller.editor.claude.isRunning)
        XCTAssertEqual(try shellOutput("echo \"[$CLAUDE_CODE_SSE_PORT]\"", in: controller), "[]")
    }

    func testTerminalsGetTheirWindowsPortAndTheLockFileDescribesIt() throws {
        try installClaudeCode()
        let (root, controller) = try makeProject()
        controller.editor.showTerminal()
        layout(controller)
        let port = try XCTUnwrap(controller.editor.claude.port, "the first terminal starts the connection")
        XCTAssertEqual(try shellOutput("echo \"$CLAUDE_CODE_SSE_PORT $ENABLE_IDE_INTEGRATION\"", in: controller), "\(port) true")

        let lockURL = try XCTUnwrap(controller.editor.claude.lockURL)
        XCTAssertEqual(lockURL, ClaudeBridge.lockDirectory.appendingPathComponent("\(port).lock"))
        let lock = try lockFile(controller)
        XCTAssertEqual(lock["ideName"] as? String, "Pulse")
        XCTAssertEqual(lock["transport"] as? String, "ws")
        XCTAssertEqual(lock["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(lock["workspaceFolders"] as? [String], [root.path])
        let token = try XCTUnwrap(lock["authToken"] as? String)
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
        let permissions = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "the lock file holds the token")

        // Switched off: the connection and its lock file go; new shells get nothing.
        ClaudeBridge.isEnabled = false
        XCTAssertFalse(controller.editor.claude.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        controller.editor.newTerminal()
        layout(controller)
        XCTAssertEqual(try shellOutput("echo \"[$CLAUDE_CODE_SSE_PORT]\"", in: controller), "[]")
    }

    func testTheLockFileFollowsTheWindowsFolderAndGoesAwayWithTheWindow() throws {
        let (_, controller) = try makeProject()
        _ = try startBridge(controller)
        let other = try makeFolder("other", files: ["b.swift": "\n"])
        controller.setRoot(other)
        XCTAssertEqual(try lockFile(controller)["workspaceFolders"] as? [String], [other.path])

        let lockURL = try XCTUnwrap(controller.editor.claude.lockURL)
        controller.prepareForQuit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertFalse(controller.editor.claude.isRunning)
    }

    func testStaleLockFilesFromAPulseThatIsGoneAreRemoved() throws {
        try installClaudeCode()
        try FileManager.default.createDirectory(at: ClaudeBridge.lockDirectory, withIntermediateDirectories: true)
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let gone = Int(exited.processIdentifier)
        func write(_ name: String, ideName: String, pid: Int) throws -> URL {
            let url = ClaudeBridge.lockDirectory.appendingPathComponent(name)
            let lock: [String: Any] = ["pid": pid, "ideName": ideName, "transport": "ws", "authToken": "x", "workspaceFolders": [String]()]
            try JSONSerialization.data(withJSONObject: lock).write(to: url)
            return url
        }
        let stale = try write("1.lock", ideName: "Pulse", pid: gone)
        let otherEditor = try write("2.lock", ideName: "Visual Studio Code", pid: gone)
        let otherWindow = try write("3.lock", ideName: "Pulse", pid: Int(getpid()))

        let (_, controller) = try makeProject()
        XCTAssertTrue(controller.editor.claude.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "Pulse's own, and its process is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherEditor.path), "never another editor's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherWindow.path), "another window of this Pulse")
    }

    // MARK: Handshake

    func testHandshakeNeedsTheTokenAndRefusesBrowsers() throws {
        let (_, controller) = try makeProject()
        let (port, token) = try startBridge(controller)
        let refused: [(String?, String, [String])] = [
            (nil, "127.0.0.1", []),
            (String(repeating: "0", count: 32), "127.0.0.1", []),
            (token, "127.0.0.1", ["Origin: https://example.com"]),
            (token, "attacker.example", []),
        ]
        for (given, host, headers) in refused {
            let client = try TestIDEClient(port: port)
            client.handshake(token: given, host: host, headers: headers)
            let head = response(client) ?? ""
            XCTAssertTrue(head.hasPrefix("HTTP/1.1 403"), "\(given ?? "no token") \(host) \(headers): \(head)")
        }

        let client = try TestIDEClient(port: port)
        client.handshake(token: token)
        let head = try XCTUnwrap(response(client))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        XCTAssertTrue(head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), head)
        XCTAssertTrue(head.contains("Sec-WebSocket-Protocol: mcp"), "Claude Code gives up without it")
    }

    // MARK: Protocol

    func testRepliesToWhatClaudeCodeAsks() throws {
        let (root, controller) = try makeProject()
        let client = try connect(controller)

        let initialize = request(client, "initialize", ["protocolVersion": "2025-11-25"], id: 0)
        let result = initialize?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "pulse")
        client.sendJSON(["jsonrpc": "2.0", "method": "notifications/initialized"])
        client.sendJSON(["jsonrpc": "2.0", "method": "ide_connected", "params": ["pid": 1]])

        let tools = (request(client, "tools/list", id: 1)?["result"] as? [String: Any])?["tools"] as? [Any]
        XCTAssertEqual(tools?.count, 0, "nothing for the model")
        XCTAssertEqual(toolText(callTool(client, "closeAllDiffTabs", id: 2)), "CLOSED_0_DIFF_TABS")
        XCTAssertEqual(toolText(callTool(client, "getDiagnostics", ["uri": root.appendingPathComponent("main.swift").absoluteString], id: 3)), "[]")
        XCTAssertEqual(toolText(callTool(client, "close_tab", ["tab_name": "✻ [Claude Code] main.swift (abc123) ⧉"], id: 4)), "TAB_CLOSED")

        // An error for openDiff makes Claude Code ask in the terminal instead.
        let openDiff = callTool(client, "openDiff", ["old_file_path": "/a", "new_file_path": "/a", "new_file_contents": "", "tab_name": "x"], id: 5)
        XCTAssertEqual((openDiff?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((request(client, "no/such/method", id: 6)?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNotNil(request(client, "ping", id: 7)?["result"])

        let folders = toolJSON(callTool(client, "getWorkspaceFolders", id: 8))
        XCTAssertEqual(folders?["rootPath"] as? String, root.path)
        let file = root.appendingPathComponent("main.swift").path
        XCTAssertEqual(toolJSON(callTool(client, "checkDocumentDirty", ["filePath": file], id: 9))?["isDirty"] as? Bool, false)
        let editors = toolJSON(callTool(client, "getOpenEditors", id: 10))?["tabs"] as? [[String: Any]]
        XCTAssertEqual(editors?.first?["label"] as? String, "main.swift")
        XCTAssertEqual(toolJSON(callTool(client, "getCurrentSelection", id: 11))?["filePath"] as? String, file)

        let label = views(NSTextField.self, in: controller).first { $0.stringValue == "✻ Claude Code" }
        XCTAssertEqual(label?.isHidden, false, "the status bar says Claude Code is connected")
        controller.editor.claude.stop()
        wait(timeout: 5, "the client to be disconnected") {
            client.pump()
            return client.peerClosed
        }
        XCTAssertEqual(label?.isHidden, true)
    }

    // MARK: Selection

    func testTheSelectionReachesClaudeInItsUnits() throws {
        let (root, controller) = try makeProject()
        let client = try connectAndInitialize(controller)

        select("gamma\ndelta", in: controller)
        let message = nextMessage(client)
        XCTAssertEqual(message?["method"] as? String, "selection_changed")
        let shared = params(message)
        XCTAssertEqual(shared["text"] as? String, "gamma\ndelta")
        XCTAssertEqual(shared["filePath"] as? String, root.appendingPathComponent("main.swift").path)
        XCTAssertEqual(shared["fileUrl"] as? String, root.appendingPathComponent("main.swift").absoluteString)
        // "beta 😀 " is 8 UTF-16 units: the emoji counts twice, as in VS Code.
        XCTAssertEqual(position(shared, "start"), [1, 8])
        XCTAssertEqual(position(shared, "end"), [2, 5])
        XCTAssertEqual((shared["selection"] as? [String: Any])?["isEmpty"] as? Bool, false)

        // Clearing the selection is sent; moving the caret within the file isn't.
        controller.editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        let cleared = params(nextMessage(client))
        XCTAssertEqual((cleared["selection"] as? [String: Any])?["isEmpty"] as? Bool, true)
        XCTAssertEqual(cleared["text"] as? String, "")
        controller.editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        assertQuiet(client)
    }

    func testSwitchingTabsSendsTheOtherFile() throws {
        let (root, controller) = try makeProject(["a.swift": "let a = 1\n", "b.swift": "let b = 2\n"])
        controller.editor.open(root.appendingPathComponent("b.swift"))
        let client = try connectAndInitialize(controller)
        controller.editor.selectTab(offset: -1)
        XCTAssertEqual(params(nextMessage(client))["filePath"] as? String, root.appendingPathComponent("a.swift").path)
    }

    func testALongSelectionIsCutShortButItsRangeIsExact() throws {
        let line = String(repeating: "x", count: 39) + "\n"
        let (_, controller) = try makeProject(["big.txt": String(repeating: line, count: 3000)])
        let client = try connectAndInitialize(controller)
        controller.editor.textView.selectAll(nil)
        let shared = params(nextMessage(client))
        XCTAssertLessThanOrEqual((shared["text"] as? String)?.utf16.count ?? .max, ClaudeBridge.maxSelectionCharacters)
        XCTAssertEqual(position(shared, "start"), [0, 0])
        XCTAssertEqual(position(shared, "end"), [3000, 0])
    }

    func testSendSelectionMentionsTheSelectedLines() throws {
        let (root, controller) = try makeProject()
        let client = try connectAndInitialize(controller)

        select("beta 😀 gamma\ndelta\n", in: controller)
        _ = nextMessage(client)   // its selection_changed
        controller.sendSelectionToClaude(nil)
        let mention = nextMessage(client)
        XCTAssertEqual(mention?["method"] as? String, "at_mentioned")
        // Claude Code shows this as @main.swift#L2-3: the line after the
        // selection's end isn't included.
        XCTAssertEqual(params(mention)["filePath"] as? String, root.appendingPathComponent("main.swift").path)
        XCTAssertEqual(params(mention)["lineStart"] as? Int, 1)
        XCTAssertEqual(params(mention)["lineEnd"] as? Int, 2)

        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = nextMessage(client)
        controller.sendSelectionToClaude(nil)
        let file = params(nextMessage(client))
        XCTAssertNil(file["lineStart"], "no selection: the whole file (@main.swift)")
    }

    // MARK: Frames

    func testFramesAreReadStrictly() throws {
        let (_, controller) = try makeProject()
        let client = try connect(controller)

        client.sendFrame(opcode: 0x9, payload: [1, 2, 3])
        let pong = nextFrame(client)
        XCTAssertEqual(pong?.opcode, 0xA)
        XCTAssertEqual(pong?.payload, [1, 2, 3])

        // A request in two fragments, with a 16-bit length on the first.
        let body = Array(#"{"jsonrpc":"2.0","id":41,"method":"ping","params":{"padding":"\#(String(repeating: "p", count: 300))"}}"#.utf8)
        client.sendFrame(opcode: 0x1, payload: Array(body[..<200]), fin: false)
        client.sendFrame(opcode: 0x0, payload: Array(body[200...]))
        XCTAssertEqual(nextMessage(client)?["id"] as? Int, 41)

        // Unmasked: a protocol error (1002), then the connection closes.
        client.sendFrame(opcode: 0x1, payload: Array("{}".utf8), masked: false)
        let close = nextFrame(client)
        XCTAssertEqual(close?.opcode, 0x8)
        XCTAssertEqual(close?.payload, [0x03, 0xEA])
        wait(timeout: 5, "the connection to close") {
            client.pump()
            return client.peerClosed
        }

        // Too big to buffer: refused from the length alone (1009).
        let big = try connect(controller)
        big.sendFrame(opcode: 0x1, payload: [], claimedLength: 2 * 1024 * 1024)
        XCTAssertEqual(nextFrame(big)?.payload, [0x03, 0xF1])

        // Junk never takes Pulse down; the next client is served as usual.
        let junk = try connect(controller)
        junk.send((0..<4096).map { _ in UInt8.random(in: 0...255) })
        spin(0.2)
        let next = try connect(controller)
        XCTAssertNotNil(request(next, "ping", id: 1)?["result"])
    }
}

/// Stands in for Claude Code: a raw socket that speaks just enough WebSocket.
/// Reads never block, since the server runs on the main queue the tests spin.
final class TestIDEClient {
    let fd: Int32
    let port: UInt16
    private(set) var peerClosed = false
    private var buffer: [UInt8] = []

    init(port: UInt16) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard socketFD >= 0, connected == 0 else {
            if socketFD >= 0 { close(socketFD) }
            throw NSError(domain: "TestIDEClient", code: Int(errno))
        }
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
        self.port = port
    }

    deinit { close(fd) }

    func send(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// The upgrade request Claude Code sends (its key is RFC 6455's example).
    func handshake(token: String?, host: String = "127.0.0.1", headers: [String] = []) {
        var lines = ["GET / HTTP/1.1", "Host: \(host):\(port)", "Connection: Upgrade", "Upgrade: websocket",
                     "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                     "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits", "Sec-WebSocket-Protocol: mcp",
                     "User-Agent: claude-code/2.1.301 (cli)"]
        if let token { lines.append("X-Claude-Code-Ide-Authorization: \(token)") }
        lines += headers
        send(Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }

    func sendFrame(opcode: UInt8, payload: [UInt8], fin: Bool = true, masked: Bool = true, claimedLength: Int? = nil) {
        let first: UInt8 = (fin ? 0x80 : 0) | opcode
        let maskBit: UInt8 = masked ? 0x80 : 0
        let length = claimedLength ?? payload.count
        var frame = [first]
        if length < 126 {
            frame.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            frame += [maskBit | 126, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: length >> shift)) }
        }
        if masked {
            let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            frame += mask
            frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        } else {
            frame += payload
        }
        send(frame)
    }

    func sendJSON(_ object: [String: Any]) {
        sendFrame(opcode: 0x1, payload: Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data()))
    }

    /// Takes whatever has arrived, without waiting.
    func pump() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &chunk, 65536, MSG_DONTWAIT)
        if count > 0 {
            buffer += chunk[0..<count]
        } else if count == 0 {
            peerClosed = true
        }
    }

    func takeHTTPResponse() -> String? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            let head = String(decoding: buffer[0..<i], as: UTF8.self)
            buffer.removeFirst(i + 4)
            return head
        }
        return nil
    }

    /// One server frame (never masked).
    func takeFrame() -> (opcode: UInt8, payload: [UInt8])? {
        guard buffer.count >= 2 else { return nil }
        var length = Int(buffer[1] & 0x7F)
        var header = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            header = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | Int(buffer[i]) }
            header = 10
        }
        guard buffer.count >= header + length else { return nil }
        let frame = (opcode: buffer[0] & 0x0F, payload: Array(buffer[header..<(header + length)]))
        buffer.removeFirst(header + length)
        return frame
    }
}
