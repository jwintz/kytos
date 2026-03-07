#if os(macOS)
import Foundation
import Darwin

// MARK: - Protocol Types (mirrors PaneProtocol.swift)

enum KytosPaneCommand: String, Codable {
    case createSession, listSessions, destroySession, attachSession, ping
}

enum KytosPaneMessageType: String, Codable {
    case request, response, snapshot, delta, input, resize
}

struct KytosPaneRequest: Codable {
    var command: KytosPaneCommand
    var sessionID: String?
    var name: String?
    var commandLine: [String]?
    var cols: Int?
    var rows: Int?
}

struct KytosPaneSessionInfo: Codable {
    let id: String
    let name: String?
    let createdAt: Date
    let isRunning: Bool
    let processID: Int32?
}

struct KytosPaneResponse: Codable {
    var ok: Bool
    var message: String?
    var sessions: [KytosPaneSessionInfo]?
    var session: KytosPaneSessionInfo?
}

struct KytosPaneWireMessage: Codable {
    var type: KytosPaneMessageType
    var request: KytosPaneRequest?
    var response: KytosPaneResponse?

    static func request(_ req: KytosPaneRequest) -> KytosPaneWireMessage {
        KytosPaneWireMessage(type: .request, request: req, response: nil)
    }
}

// MARK: - Terminal Cell Types (mirrors PaneProtocol.swift binary codec)

enum KytosPaneCellColor: Equatable {
    case defaultColor
    case defaultInvertedColor
    case ansi(UInt8)
    case trueColor(UInt8, UInt8, UInt8)
}

struct KytosPaneCellAttribute: Equatable {
    let foreground: KytosPaneCellColor
    let background: KytosPaneCellColor
    let style: UInt8 // bit 0=bold 1=underline 2=blink 3=inverse 5=dim
    let underlineColor: KytosPaneCellColor?

    static func == (lhs: KytosPaneCellAttribute, rhs: KytosPaneCellAttribute) -> Bool {
        lhs.style == rhs.style &&
        lhs.foreground == rhs.foreground &&
        lhs.background == rhs.background
    }
}

struct KytosPaneCell {
    let char: String
    let width: Int8
    let attribute: KytosPaneCellAttribute
}

struct KytosPaneTerminalSnapshot {
    let cols: Int
    let rows: Int
    let cursorX: Int
    let cursorY: Int
    let isAlternate: Bool
    let lines: [[KytosPaneCell]]
    /// Scrollback history received from the server, oldest line first. Empty when unavailable.
    let scrollbackLines: [[KytosPaneCell]]
}

struct KytosPaneTerminalDelta {
    let startY: Int
    let endY: Int
    let cursorX: Int
    let cursorY: Int
    let scrolledOffLines: [[KytosPaneCell]]
    let lines: [[KytosPaneCell]]
}

/// Decoded message that can represent any wire message type.
enum KytosPaneFullMessage {
    case response(KytosPaneResponse)
    case snapshot(KytosPaneTerminalSnapshot)
    case delta(KytosPaneTerminalDelta)
    case other
}

// MARK: - Binary Decoder

private struct BinaryReader {
    let data: Data
    var offset: Int = 0
    var remaining: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw KytosPaneError.invalidData }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readInt8() throws -> Int8 { Int8(bitPattern: try readUInt8()) }

    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw KytosPaneError.invalidData }
        let b0 = data[data.startIndex + offset]
        let b1 = data[data.startIndex + offset + 1]
        offset += 2
        return (UInt16(b0) << 8) | UInt16(b1)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw KytosPaneError.invalidData }
        let b0 = data[data.startIndex + offset]
        let b1 = data[data.startIndex + offset + 1]
        let b2 = data[data.startIndex + offset + 2]
        let b3 = data[data.startIndex + offset + 3]
        offset += 4
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    mutating func readData(_ count: Int) throws -> Data {
        guard offset + count <= data.count else { throw KytosPaneError.invalidData }
        let start = data.startIndex + offset
        let value = Data(data[start..<start + count])
        offset += count
        return value
    }

    mutating func readColor() throws -> KytosPaneCellColor {
        let tag = try readUInt8()
        switch tag {
        case 0: return .defaultColor
        case 1: return .defaultInvertedColor
        case 2: return .ansi(try readUInt8())
        case 3: return .trueColor(try readUInt8(), try readUInt8(), try readUInt8())
        default: throw KytosPaneError.invalidData
        }
    }

    mutating func readAttribute() throws -> KytosPaneCellAttribute {
        let fg = try readColor()
        let bg = try readColor()
        let style = try readUInt8()
        let hasUnderline = try readUInt8()
        let underline = hasUnderline != 0 ? try readColor() : nil
        return KytosPaneCellAttribute(foreground: fg, background: bg, style: style, underlineColor: underline)
    }

    mutating func readCell() throws -> KytosPaneCell {
        let charLen = Int(try readUInt8())
        let charData = try readData(charLen)
        let char = String(data: charData, encoding: .utf8) ?? " "
        let width = try readInt8()
        let attr = try readAttribute()
        return KytosPaneCell(char: char, width: width, attribute: attr)
    }

    mutating func readSnapshot() throws -> KytosPaneTerminalSnapshot {
        let cols = Int(try readUInt16())
        let rows = Int(try readUInt16())
        let cursorX = Int(try readUInt16())
        let cursorY = Int(try readUInt16())
        let isAlternate = try readUInt8() != 0
        let lineCount = Int(try readUInt16())
        var lines: [[KytosPaneCell]] = []
        lines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            let cellCount = Int(try readUInt16())
            var line: [KytosPaneCell] = []
            line.reserveCapacity(cellCount)
            for _ in 0..<cellCount { try line.append(readCell()) }
            lines.append(line)
        }
        // Scrollback is optional — old servers won't send this field.
        var scrollbackLines: [[KytosPaneCell]] = []
        if remaining >= 2 {
            let scrollbackCount = Int(try readUInt16())
            scrollbackLines.reserveCapacity(scrollbackCount)
            for _ in 0..<scrollbackCount {
                let cellCount = Int(try readUInt16())
                var line: [KytosPaneCell] = []
                line.reserveCapacity(cellCount)
                for _ in 0..<cellCount { try line.append(readCell()) }
                scrollbackLines.append(line)
            }
        }
        return KytosPaneTerminalSnapshot(cols: cols, rows: rows, cursorX: cursorX, cursorY: cursorY, isAlternate: isAlternate, lines: lines, scrollbackLines: scrollbackLines)
    }

    mutating func readDelta() throws -> KytosPaneTerminalDelta {
        let startY = Int(try readUInt16())
        let endY = Int(try readUInt16())
        let cursorX = Int(try readUInt16())
        let cursorY = Int(try readUInt16())
        let scrolledCount = Int(try readUInt16())
        var scrolledOffLines: [[KytosPaneCell]] = []
        scrolledOffLines.reserveCapacity(scrolledCount)
        for _ in 0..<scrolledCount {
            let cellCount = Int(try readUInt16())
            var line: [KytosPaneCell] = []
            line.reserveCapacity(cellCount)
            for _ in 0..<cellCount { try line.append(readCell()) }
            scrolledOffLines.append(line)
        }
        let lineCount = Int(try readUInt16())
        var lines: [[KytosPaneCell]] = []
        lines.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            let cellCount = Int(try readUInt16())
            var line: [KytosPaneCell] = []
            line.reserveCapacity(cellCount)
            for _ in 0..<cellCount { try line.append(readCell()) }
            lines.append(line)
        }
        return KytosPaneTerminalDelta(startY: startY, endY: endY, cursorX: cursorX, cursorY: cursorY, scrolledOffLines: scrolledOffLines, lines: lines)
    }
}

// MARK: - Error

enum KytosPaneError: Error {
    case socketFailed, connectFailed, serverStartFailed, writeFailed, invalidResponse, invalidData
}

// MARK: - Framed Connection

final class KytosPaneConnection {
    private var fd: Int32
    private var closed = false
    /// Set to `true` to make `readExact` return nil on the next poll cycle.
    var cancelled = false

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fd: Int32) { self.fd = fd }
    deinit { if !closed { Darwin.close(fd) } }

    /// Shut down the socket for reading and writing, waking any blocked read().
    func shutdownSocket() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    /// Send a JSON control message.
    func send(_ message: KytosPaneWireMessage) throws {
        let payload = try KytosPaneConnection.encoder.encode(message)
        try writeFrame(payload, format: 0)
    }

    /// Send binary input data to the terminal.
    func sendBinaryInput(_ data: Data) throws {
        // Binary format tag 4 = input; see PaneMessageType.binaryTag
        var writer = BinaryWriter()
        writer.writeUInt8(4)         // type tag: input
        writer.writeUInt32(UInt32(data.count))
        writer.write(data)
        try writeFrame(writer.data, format: 1)
    }

    /// Send a resize event.
    func sendBinaryResize(cols: Int, rows: Int) throws {
        guard cols > 0, rows > 0 else { return }
        var writer = BinaryWriter()
        writer.writeUInt8(5)         // type tag: resize
        writer.writeUInt16(UInt16(cols))
        writer.writeUInt16(UInt16(rows))
        try writeFrame(writer.data, format: 1)
    }

    /// Read a JSON response (for control messages).
    func readResponse() throws -> KytosPaneResponse? {
        guard let msg = try readFullMessage() else { return nil }
        if case .response(let r) = msg { return r }
        return nil
    }

    /// Read any message — JSON or binary.
    func readFullMessage() throws -> KytosPaneFullMessage? {
        guard let (payload, format) = try readFrame() else { return nil }
        if format == 0 {
            // JSON
            let msg = try KytosPaneConnection.decoder.decode(KytosPaneWireMessage.self, from: payload)
            if let r = msg.response { return .response(r) }
            return .other
        } else {
            // Binary
            guard !payload.isEmpty else { return .other }
            var reader = BinaryReader(data: payload)
            let tag = try reader.readUInt8()
            switch tag {
            case 2: return try .snapshot(reader.readSnapshot())
            case 3: return try .delta(reader.readDelta())
            default: return .other
            }
        }
    }

    func close() { if !closed { Darwin.close(fd); closed = true } }

    // MARK: - Private I/O

    private func writeFrame(_ data: Data, format: UInt8) throws {
        let totalLen = UInt32(data.count + 1).bigEndian
        var frame = Data(count: 5 + data.count)
        frame.withUnsafeMutableBytes { ptr in
            withUnsafeBytes(of: totalLen) { src in ptr.copyBytes(from: src) }
        }
        frame[4] = format
        frame.replaceSubrange(5..., with: data)
        try writeAll(frame)
    }

    private func readFrame() throws -> (Data, UInt8)? {
        guard let lenBytes = readExact(4) else { return nil }
        let length = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, let payload = readExact(Int(length)) else { return nil }
        let format = payload[0]
        return (Data(payload.dropFirst()), format)
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { throw KytosPaneError.writeFailed }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n <= 0 { throw KytosPaneError.writeFailed }
                offset += n
            }
        }
    }

    private func readExact(_ count: Int) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        let success = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            while offset < count {
                if cancelled { return false }
                // Poll with 500ms timeout so we can check `cancelled` periodically.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pr = Darwin.poll(&pfd, 1, 500)
                if pr == 0 { continue } // timeout — recheck cancelled
                if pr < 0 { return false }
                if pfd.revents & Int16(POLLERR | POLLNVAL) != 0 { return false }
                // POLLHUP can arrive WITH POLLIN when the server closes after writing.
                // Only bail on POLLHUP if no data is available.
                if pfd.revents & Int16(POLLHUP) != 0 && pfd.revents & Int16(POLLIN) == 0 { return false }
                let n = Darwin.read(fd, base + offset, count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return success ? buffer : nil
    }
}

// MARK: - Binary Writer

private struct BinaryWriter {
    var data = Data()
    mutating func writeUInt8(_ v: UInt8) { data.append(v) }
    mutating func writeUInt16(_ v: UInt16) {
        var be = v.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &be) { Array($0) })
    }
    mutating func writeUInt32(_ v: UInt32) {
        var be = v.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &be) { Array($0) })
    }
    mutating func write(_ d: Data) { data.append(d) }
}

// MARK: - Client

final class KytosPaneClient {
    static let shared = KytosPaneClient()
    private init() {}

    // Serializes server-start attempts so concurrent callers don't each launch a new process.
    private let serverStartLock = NSLock()
    private var serverStarted = false

    private var socketPath: String {
        let uid = Darwin.geteuid()
        let dir = "/tmp/pane-\(uid)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(bitPattern: 0o700))]
        )
        // Fixed socket name — sessions persist across app relaunches.
        // The TERM=dumb issue is handled by patches, so mtime-based versioning
        // is no longer needed and was preventing session restoration.
        return "\(dir)/kytos"
    }

    private var paneExecutablePath: String? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "pane") {
            return url.path
        }
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/pane").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    // MARK: - Public API

    @discardableResult
    func createSession(commandLine: [String], name: String? = nil) throws -> KytosPaneSessionInfo {
        let req = KytosPaneRequest(command: .createSession, name: name, commandLine: commandLine)
        let response = try sendControl(req, allowStart: true)
        guard response.ok, let session = response.session else {
            throw KytosPaneError.invalidResponse
        }
        return session
    }

    func listSessions() throws -> [KytosPaneSessionInfo] {
        let req = KytosPaneRequest(command: .listSessions)
        let response = try sendControl(req, allowStart: false)
        return response.sessions ?? []
    }

    /// Like `listSessions()` but starts the server if needed.
    func listSessionsWithStart() throws -> [KytosPaneSessionInfo] {
        let req = KytosPaneRequest(command: .listSessions)
        let response = try sendControl(req, allowStart: true)
        return response.sessions ?? []
    }

    func destroySession(id: String) throws {
        let req = KytosPaneRequest(command: .destroySession, sessionID: id)
        _ = try sendControl(req, allowStart: false)
    }

    /// Opens a persistent streaming connection for attaching to a session.
    /// The caller owns the returned connection and must close it when done.
    func openAttachConnection(sessionID: String, cols: Int, rows: Int) throws -> KytosPaneConnection {
        let connection = try openConnection(allowStart: false)
        let req = KytosPaneRequest(command: .attachSession, sessionID: sessionID, cols: cols, rows: rows)
        try connection.send(.request(req))
        return connection
    }

    /// Fetches a one-shot snapshot of a session's current screen contents.
    func fetchSnapshot(sessionID: String) throws -> KytosPaneTerminalSnapshot {
        let conn = try openAttachConnection(sessionID: sessionID, cols: 220, rows: 50)
        defer { conn.close() }
        guard case .response(let resp)? = try conn.readFullMessage(), resp.ok else {
            throw KytosPaneError.invalidResponse
        }
        guard case .snapshot(let snap)? = try conn.readFullMessage() else {
            throw KytosPaneError.invalidResponse
        }
        return snap
    }

    // MARK: - Private

    private func sendControl(_ req: KytosPaneRequest, allowStart: Bool) throws -> KytosPaneResponse {
        kLog("[KytosDebug][PaneClient] sendControl \(req.command) allowStart=\(allowStart)")
        let conn = try openConnection(allowStart: allowStart)
        defer { conn.close() }
        try conn.send(.request(req))
        guard let response = try conn.readResponse() else {
            throw KytosPaneError.invalidResponse
        }
        return response
    }

    private func openConnection(allowStart: Bool) throws -> KytosPaneConnection {
        do {
            let fd = try connectOnce()
            kLog("[KytosDebug][PaneClient] openConnection — connected fd=\(fd)")
            return KytosPaneConnection(fd: fd)
        } catch {
            guard allowStart else { throw error }
            // Serialize server startup: only one caller launches the process; others wait and retry.
            serverStartLock.lock()
            if !serverStarted {
                try startServer()
                serverStarted = true
            }
            serverStartLock.unlock()
            var lastError = error
            for _ in 0..<25 {
                do { return KytosPaneConnection(fd: try connectOnce()) }
                catch let e { lastError = e; usleep(100_000) }
            }
            throw lastError
        }
    }

    private func connectOnce() throws -> Int32 {
        let path = socketPath
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KytosPaneError.socketFailed }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCStr = path.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.initializeMemory(as: UInt8.self, repeating: 0)
            pathCStr.withUnsafeBytes { src in _ = src.copyBytes(to: buf) }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { Darwin.close(fd); throw KytosPaneError.connectFailed }
        return fd
    }

    private func startServer() throws {
        guard let execPath = paneExecutablePath else {
            print("[KytosDebug][PaneClient] pane binary not found in app bundle")
            throw KytosPaneError.serverStartFailed
        }

        // Launch the pane server in its own session (setsid) so Xcode's
        // "stop" doesn't kill it along with the app's process group.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        // Start the server in $HOME so shells inherit it as their cwd.
        let home = env["HOME"] ?? NSHomeDirectory()
        posix_spawn_file_actions_addchdir_np(&fileActions, home)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // POSIX_SPAWN_SETSID puts the child in a new session (new process group leader).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let args = [execPath, "--server", "--socket", socketPath]
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { $0.map { free($0) } }
            cEnv.forEach { $0.map { free($0) } }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, execPath, &fileActions, &attr, cArgs, cEnv)
        guard rc == 0 else {
            throw KytosPaneError.serverStartFailed
        }
        print("[KytosDebug][PaneClient] Started pane server at \(execPath) (pid \(pid), new session)")
    }
}

// MARK: - ANSI Generation from Terminal Cells

extension KytosPaneTerminalSnapshot {
    /// Converts the snapshot to raw ANSI escape sequences for SwiftTerm.
    ///
    /// Scrollback lines are written first as plain output (each ending \r\n) so they
    /// push naturally into SwiftTerm's scrollback ring. The screen content follows,
    /// using absolute cursor positioning to overwrite in-place without a flash.
    ///
    /// Use this only on the **initial** attach for a terminal. For reconnects, use
    /// `toANSIBytesScreenOnly()` to avoid duplicating the scrollback ring.
    func toANSIBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((scrollbackLines.count + rows) * cols * 8)

        // --- Scrollback ---
        if !scrollbackLines.isEmpty {
            var lastAttr: KytosPaneCellAttribute? = nil
            for line in scrollbackLines {
                // Trim trailing space/empty cells so lines recorded at a wider
                // terminal width don't wrap incorrectly in the current view.
                var trimmedEnd = line.count
                while trimmedEnd > 0 {
                    let c = line[trimmedEnd - 1]
                    let ch = c.char
                    if (ch == " " || ch.isEmpty || ch == "\0") && c.width <= 1 {
                        trimmedEnd -= 1
                    } else {
                        break
                    }
                }
                var col = 0
                for cell in line.prefix(trimmedEnd) {
                    if cell.width == 0 { col += 1; continue }
                    if lastAttr != cell.attribute {
                        out.append(contentsOf: cell.attribute.sgrBytes())
                        lastAttr = cell.attribute
                    }
                    let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
                    out.append(contentsOf: ch.utf8)
                    col += Int(max(1, cell.width))
                }
                // Reset attributes and emit CR+LF to push the line into scrollback.
                out.appendAnsi("\u{1b}[0m")
                lastAttr = nil
                out.appendAnsi("\r\n")
            }
            // After emitting N scrollback lines via \r\n, the last min(rows-1, N) lines
            // sit on the visible screen rather than in SwiftTerm's scrollback ring.
            // screenANSIBytes() uses absolute cursor positioning and does NOT scroll,
            // so those lines would be silently overwritten and lost.
            // Emitting `rows - 1` bare newlines scrolls the visible area up exactly far
            // enough to push every scrollback line into the ring (one fewer than `rows`
            // because the final newline in the loop above already moved the cursor one
            // row down from the last scrollback line).
            for _ in 0..<(rows - 1) {
                out.appendAnsi("\r\n")
            }
        }

        out.append(contentsOf: screenANSIBytes())
        return out
    }

    /// Converts only the visible screen portion to ANSI, skipping scrollback.
    ///
    /// Used on reconnects to refresh the visible area without adding duplicate lines
    /// to SwiftTerm's scrollback ring (which already holds the initial-attach data).
    func toANSIBytesScreenOnly() -> [UInt8] {
        return screenANSIBytes()
    }

    private func screenANSIBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(rows * cols * 8)
        var lastAttr: KytosPaneCellAttribute? = nil
        for (rowIdx, line) in lines.prefix(rows).enumerated() {
            // Move cursor to start of this row.
            out.appendAnsi("\u{1b}[\(rowIdx + 1);1H")
            var col = 0
            for cell in line.prefix(cols) {
                // Skip spacer cells that follow a wide character (width == 0).
                if cell.width == 0 { col += 1; continue }
                // Only emit SGR when the attribute changes — avoids per-cell reset banding.
                if lastAttr != cell.attribute {
                    out.append(contentsOf: cell.attribute.sgrBytes())
                    lastAttr = cell.attribute
                }
                let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
                out.append(contentsOf: ch.utf8)
                col += Int(max(1, cell.width))
            }
            // Erase to end-of-line if the line was shorter than cols.
            if col < cols { out.appendAnsi("\u{1b}[K") }
        }
        out.appendAnsi("\u{1b}[0m")
        out.appendAnsi("\u{1b}[\(cursorY + 1);\(cursorX + 1)H")
        return out
    }
}

extension KytosPaneTerminalDelta {
    /// Converts the delta to ANSI escape sequences for the affected rows.
    ///
    /// When the server reports lines that scrolled off the top, those lines are
    /// emitted using a clear-write-flush approach:
    /// 1. Clear the visible screen (ring unaffected)
    /// 2. Write all scrolled-off lines from home with `\r\n`
    /// 3. Flush them into the ring with exactly the right number of newlines
    /// 4. Apply positioned screen content from the delta
    func toANSIBytes(terminalRows: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity((scrolledOffLines.count + lines.count) * 200)

        let N = scrolledOffLines.count
        if N > 0 {
            // Clear visible area (doesn't touch ring) and position cursor at home.
            out.appendAnsi("\u{1b}[2J\u{1b}[H")
            var lastAttr: KytosPaneCellAttribute? = nil
            for line in scrolledOffLines {
                var trimmedEnd = line.count
                while trimmedEnd > 0 {
                    let c = line[trimmedEnd - 1]
                    if (c.char == " " || c.char.isEmpty || c.char == "\0") && c.width <= 1 {
                        trimmedEnd -= 1
                    } else { break }
                }
                for cell in line.prefix(trimmedEnd) {
                    if cell.width == 0 { continue }
                    if lastAttr != cell.attribute {
                        out.append(contentsOf: cell.attribute.sgrBytes())
                        lastAttr = cell.attribute
                    }
                    let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
                    out.append(contentsOf: ch.utf8)
                }
                out.appendAnsi("\u{1b}[0m\r\n")
                lastAttr = nil
            }
            // Flush scrolled-off lines into the ring. For N < rows, push exactly N
            // lines (avoiding blank lines in ring). For N >= rows, natural scrolling
            // already pushed N-rows+1 lines; flush the remaining rows-1.
            let flushCount = min(N, terminalRows - 1)
            out.appendAnsi("\u{1b}[\(terminalRows);1H")
            for _ in 0..<flushCount {
                out.appendAnsi("\n")
            }
        }

        out.appendAnsi("\u{1b}[s")  // save cursor position
        for (offset, line) in lines.enumerated() {
            let row = startY + offset
            guard row <= endY else { break }
            out.appendAnsi("\u{1b}[\(row + 1);1H\u{1b}[2K")
            var lastAttr: KytosPaneCellAttribute? = nil
            for cell in line {
                if cell.width == 0 { continue }
                if lastAttr != cell.attribute {
                    out.append(contentsOf: cell.attribute.sgrBytes())
                    lastAttr = cell.attribute
                }
                let ch = cell.char.isEmpty || cell.char == "\0" ? " " : cell.char
                out.append(contentsOf: ch.utf8)
            }
        }
        out.appendAnsi("\u{1b}[0m")
        out.appendAnsi("\u{1b}[u")  // restore saved cursor position
        out.appendAnsi("\u{1b}[\(cursorY + 1);\(cursorX + 1)H")
        return out
    }
}

private extension KytosPaneCellAttribute {
    func sgrBytes() -> [UInt8] {
        var parts: [String] = ["0"]  // reset first
        if style & 1  != 0 { parts.append("1") }   // bold
        if style & 2  != 0 { parts.append("4") }   // underline
        if style & 4  != 0 { parts.append("5") }   // blink
        if style & 8  != 0 { parts.append("7") }   // inverse
        if style & 32 != 0 { parts.append("2") }   // dim
        // If a color is marked as inverted-default and the inverse style bit isn't already
        // set, emit SGR 7 to enable reverse-video so the inversion takes effect.
        if style & 8 == 0,
           foreground == .defaultInvertedColor || background == .defaultInvertedColor {
            parts.append("7")
        }
        parts.append(foreground.sgrForeground())
        parts.append(background.sgrBackground())
        let sgr = "\u{1b}[" + parts.joined(separator: ";") + "m"
        return [UInt8](sgr.utf8)
    }
}

private extension KytosPaneCellColor {
    func sgrForeground() -> String {
        switch self {
        case .defaultColor, .defaultInvertedColor: return "39"
        case .ansi(let c):
            return c < 8 ? "3\(c)" : c < 16 ? "9\(c - 8)" : "38;5;\(c)"
        case .trueColor(let r, let g, let b): return "38;2;\(r);\(g);\(b)"
        }
    }

    func sgrBackground() -> String {
        switch self {
        case .defaultColor, .defaultInvertedColor: return "49"
        case .ansi(let c):
            return c < 8 ? "4\(c)" : c < 16 ? "10\(c - 8)" : "48;5;\(c)"
        case .trueColor(let r, let g, let b): return "48;2;\(r);\(g);\(b)"
        }
    }
}

private extension Array where Element == UInt8 {
    mutating func appendAnsi(_ str: String) {
        append(contentsOf: str.utf8)
    }
}
#endif

