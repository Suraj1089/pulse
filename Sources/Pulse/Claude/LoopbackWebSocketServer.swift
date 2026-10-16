import Darwin
import Foundation

/// A WebSocket server (RFC 6455) on 127.0.0.1, for Claude Code's IDE
/// connection. Plain BSD sockets and dispatch sources on the main queue:
/// no networking framework is loaded, no thread is added, and nothing runs
/// until a client connects or sends something (no timers, no pings). Text
/// messages only, and every limit is small because the peer is a local CLI.
final class LoopbackWebSocketServer {
    static let maxConnections = 8
    static let maxHandshakeBytes = 8 * 1024
    static let maxMessageBytes = 1024 * 1024
    /// A client that stops reading is dropped rather than buffered for.
    static let maxQueuedBytes = 4 * 1024 * 1024
    static let handshakeTimeout: TimeInterval = 5

    let port: UInt16
    /// Whether a handshake may upgrade; header names are lowercased.
    var authorize: (([String: String]) -> Bool)?
    var onOpen: ((Connection) -> Void)?
    var onMessage: ((Connection, Data) -> Void)?
    /// Only for connections that had opened.
    var onClose: ((Connection) -> Void)?

    private(set) var connections: [Connection] = []
    var openConnections: [Connection] { connections.filter(\.isOpen) }

    private let listenSocket: Int32
    private let listener: DispatchSourceRead
    private var stopped = false
    /// Shared by every connection: reads happen one at a time on the main queue.
    fileprivate var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    /// Listens on 127.0.0.1 at a port the system picks; nil if that fails.
    init?() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, length) == 0 && Darwin.getsockname(fd, socketAddress, &length) == 0
            }
        }
        guard bound, Darwin.listen(fd, 8) == 0, LoopbackWebSocketServer.configure(fd) else {
            Darwin.close(fd)
            return nil
        }
        listenSocket = fd
        port = UInt16(bigEndian: address.sin_port)
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        listener.setCancelHandler { _ = Darwin.close(fd) }
        listener.setEventHandler { [weak self] in self?.acceptClients() }
        listener.resume()
    }

    deinit { stop() }

    /// Drops every client and stops listening. The port is not reused.
    func stop() {
        guard !stopped else { return }
        stopped = true
        connections.forEach { $0.teardown() }
        listener.cancel()
    }

    /// Non-blocking, closed on exec (shells must not inherit it), and no
    /// SIGPIPE when a client disappears mid-write.
    fileprivate static func configure(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        return Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
            && Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func acceptClients() {
        while !stopped {
            let fd = Darwin.accept(listenSocket, nil, nil)
            guard fd >= 0 else { return }
            guard connections.count < LoopbackWebSocketServer.maxConnections, LoopbackWebSocketServer.configure(fd) else {
                Darwin.close(fd)
                continue
            }
            connections.append(Connection(fd: fd, server: self))
        }
    }

    fileprivate func remove(_ connection: Connection) {
        connections.removeAll { $0 === connection }
    }

    // MARK: Handshake key

    /// Sec-WebSocket-Accept for a client's Sec-WebSocket-Key.
    static func acceptKey(for key: String) -> String {
        Data(sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// SHA-1, only for the handshake above (not for anything secret), so
    /// no crypto library is needed.
    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var bytes = message
        let bitLength = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { value << count | value >> (32 - count) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
            }
            for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotate(b, 30)
                b = a
                a = temp
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }
        return h.flatMap { word in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) } }
    }

    // MARK: Connection

    /// One client. Messages arrive whole (fragments are joined).
    final class Connection {
        fileprivate(set) var isOpen = false
        /// The handshake's headers, names lowercased.
        fileprivate(set) var headers: [String: String] = [:]
        /// Set by the owner: Claude Code reports its process id after connecting.
        var pid: pid_t?

        private let fd: Int32
        private weak var server: LoopbackWebSocketServer?
        private var reader: DispatchSourceRead?
        private var writer: DispatchSourceWrite?
        /// The socket is closed once every source watching it is cancelled.
        private var liveSources = 0
        private var input: [UInt8] = []
        private var message: [UInt8] = []
        private var inMessage = false
        private var output: [Data] = []
        private var outputOffset = 0
        private var queuedBytes = 0
        /// A close frame was sent or the handshake refused: nothing more is read.
        private var closing = false
        private var closeAfterFlush = false
        private var closed = false
        private var handshakeTimer: DispatchWorkItem?

        fileprivate init(fd: Int32, server: LoopbackWebSocketServer) {
            self.fd = fd
            self.server = server
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            reader.setCancelHandler { self.sourceCancelled() }
            liveSources = 1
            self.reader = reader
            reader.resume()
            // Connected but silent: dropped, so a stray client can't hold a slot.
            let timer = DispatchWorkItem { [weak self] in
                if let self, !self.isOpen { self.teardown() }
            }
            handshakeTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + LoopbackWebSocketServer.handshakeTimeout, execute: timer)
        }

        /// Sends one text message (a JSON-RPC message, for Claude Code).
        func send(text: Data) {
            guard isOpen, !closing else { return }
            sendFrame(opcode: 0x1, payload: text)
        }

        /// Closes politely (close frame first) when open, at once otherwise.
        func close() {
            guard !closed else { return }
            guard isOpen, !closing else { teardown(); return }
            closing = true
            closeAfterFlush = true
            sendFrame(opcode: 0x8, payload: Data([0x03, 0xE8]))   // 1000: normal closure
        }

        // MARK: Reading

        private func readAvailable() {
            guard !closed, let server else { return }
            let count = server.readBuffer.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                teardown()
                return
            }
            guard count > 0 else { teardown(); return }   // the client went away
            // While closing, input is read and dropped: unread data would keep
            // the read source firing.
            guard !closing else { return }
            input.append(contentsOf: server.readBuffer[0..<count])
            if isOpen { readFrames() } else { readHandshake() }
        }

        private func readHandshake() {
            guard let end = Connection.headerEnd(in: input) else {
                if input.count > LoopbackWebSocketServer.maxHandshakeBytes { refuse("431 Request Header Fields Too Large") }
                return
            }
            let head = String(decoding: input[0..<end], as: UTF8.self)
            input.removeFirst(end + 4)
            var lines = head.components(separatedBy: "\r\n")
            let request = lines.removeFirst().split(separator: " ")
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let server, request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
                  headers["upgrade"]?.lowercased() == "websocket",
                  headers["connection"]?.lowercased().contains("upgrade") == true,
                  headers["sec-websocket-version"] == "13",
                  let key = headers["sec-websocket-key"], key.count == 24 else {
                refuse("400 Bad Request")
                return
            }
            // Browsers always send Origin and their own Host; Claude Code sends
            // no Origin and Host 127.0.0.1:port. Refusing anything else keeps
            // web pages out even if they find the port (DNS rebinding included).
            let hosts = ["127.0.0.1:\(server.port)", "localhost:\(server.port)"]
            guard headers["origin"] == nil, hosts.contains(headers["host"]?.lowercased() ?? ""),
                  server.authorize?(headers) == true else {
                refuse("403 Forbidden")
                return
            }
            var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            response += "Sec-WebSocket-Accept: \(LoopbackWebSocketServer.acceptKey(for: key))\r\n"
            // Claude Code asks for "mcp" and gives up if it isn't echoed.
            if let offered = headers["sec-websocket-protocol"]?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
               !offered.isEmpty {
                response += "Sec-WebSocket-Protocol: \(offered)\r\n"
            }
            enqueue(Data((response + "\r\n").utf8))
            isOpen = true
            handshakeTimer?.cancel()
            handshakeTimer = nil
            server.onOpen?(self)
            if !input.isEmpty { readFrames() }
        }

        private static func headerEnd(in bytes: [UInt8]) -> Int? {
            guard bytes.count >= 4 else { return nil }
            for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
                return i
            }
            return nil
        }

        private func refuse(_ status: String) {
            closing = true
            closeAfterFlush = true
            enqueue(Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
        }

        private func readFrames() {
            var offset = 0
            while !closed, !closing {
                let available = input.count - offset
                guard available >= 2 else { break }
                let first = input[offset]
                let second = input[offset + 1]
                // No extensions are agreed, so the RSV bits must be clear;
                // client frames must be masked.
                guard first & 0x70 == 0, second & 0x80 != 0 else { fail(1002); break }
                var length = Int(second & 0x7F)
                var header = 2
                if length == 126 {
                    guard available >= 4 else { break }
                    length = Int(input[offset + 2]) << 8 | Int(input[offset + 3])
                    header = 4
                } else if length == 127 {
                    guard available >= 10 else { break }
                    var value: UInt64 = 0
                    for i in 2..<10 { value = value << 8 | UInt64(input[offset + i]) }
                    guard value <= UInt64(LoopbackWebSocketServer.maxMessageBytes) else { fail(1009); break }
                    length = Int(value)
                    header = 10
                }
                // Checked before waiting for the payload, so input stays bounded.
                guard length <= LoopbackWebSocketServer.maxMessageBytes else { fail(1009); break }
                guard available >= header + 4 + length else { break }
                let mask = offset + header
                let start = mask + 4
                var payload = [UInt8](repeating: 0, count: length)
                for i in 0..<length { payload[i] = input[start + i] ^ input[mask + i % 4] }
                offset = start + length
                handleFrame(opcode: first & 0x0F, isFinal: first & 0x80 != 0, payload: payload)
            }
            guard !closed else { return }
            input.removeFirst(min(offset, input.count))
            if input.isEmpty, input.capacity > 64 * 1024 { input = [] }
        }

        private func handleFrame(opcode: UInt8, isFinal: Bool, payload: [UInt8]) {
            switch opcode {
            case 0x0, 0x1:
                // A continuation needs a message in progress; a new text frame needs none.
                guard (opcode == 0x0) == inMessage else { fail(1002); return }
                message += payload
                guard message.count <= LoopbackWebSocketServer.maxMessageBytes else { fail(1009); return }
                inMessage = !isFinal
                guard isFinal else { return }
                let data = Data(message)
                message = []
                server?.onMessage?(self, data)
            case 0x8:
                closing = true
                closeAfterFlush = true
                sendFrame(opcode: 0x8, payload: Data(payload.prefix(2)))
            case 0x9:
                guard isFinal, payload.count <= 125 else { fail(1002); return }
                sendFrame(opcode: 0xA, payload: Data(payload))
            case 0xA:
                break
            case 0x2:
                fail(1003)   // binary: not something Claude Code sends
            default:
                fail(1002)
            }
        }

        private func fail(_ code: UInt16) {
            guard !closing else { return }
            closing = true
            closeAfterFlush = true
            sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
        }

        // MARK: Writing

        private func sendFrame(opcode: UInt8, payload: Data) {
            var header: [UInt8] = [0x80 | opcode]
            let count = payload.count
            if count < 126 {
                header.append(UInt8(count))
            } else if count <= 0xFFFF {
                header += [126, UInt8(count >> 8), UInt8(count & 0xFF)]
            } else {
                header.append(127)
                for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8(truncatingIfNeeded: count >> shift)) }
            }
            output.append(Data(header))
            queuedBytes += header.count
            if count > 0 {
                output.append(payload)
                queuedBytes += count
            }
            guard queuedBytes <= LoopbackWebSocketServer.maxQueuedBytes else { teardown(); return }
            flush()
        }

        private func enqueue(_ data: Data) {
            output.append(data)
            queuedBytes += data.count
            flush()
        }

        private func flush() {
            while !closed, let chunk = output.first {
                let written = chunk.withUnsafeBytes { buffer -> Int in
                    Darwin.write(fd, buffer.baseAddress! + outputOffset, buffer.count - outputOffset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { waitUntilWritable(); return }
                    teardown()
                    return
                }
                outputOffset += written
                queuedBytes -= written
                if outputOffset == chunk.count {
                    output.removeFirst()
                    outputOffset = 0
                }
            }
            guard !closed else { return }
            writer?.cancel()
            writer = nil
            if closeAfterFlush { teardown() }
        }

        /// Only while something is queued and the socket is full.
        private func waitUntilWritable() {
            guard writer == nil else { return }
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            writer.setEventHandler { [weak self] in self?.flush() }
            writer.setCancelHandler { self.sourceCancelled() }
            liveSources += 1
            self.writer = writer
            writer.resume()
        }

        // MARK: Teardown

        fileprivate func teardown() {
            guard !closed else { return }
            closed = true
            let wasOpen = isOpen
            isOpen = false
            handshakeTimer?.cancel()
            handshakeTimer = nil
            input = []
            message = []
            output = []
            queuedBytes = 0
            writer?.cancel()
            writer = nil
            reader?.cancel()
            reader = nil
            let server = self.server
            server?.remove(self)
            if wasOpen { server?.onClose?(self) }
        }

        private func sourceCancelled() {
            liveSources -= 1
            if liveSources == 0 { _ = Darwin.close(fd) }
        }
    }
}
