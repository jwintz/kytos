#if os(macOS)
import Foundation
import SwiftTerm

/// Streaming terminal coordinator backed by a pane server session.
/// Subclasses `MacOSLocalProcessTerminalCoordinator` so it fits the existing
/// `KytosTerminalManager.ManagedTerminal` type without requiring a coordinator
/// type refactor. The inherited `process` is never started.
final class KytosPaneStreamingCoordinator: MacOSLocalProcessTerminalCoordinator {

    /// Set before the view is laid out. The stream starts on the first `sizeChanged`
    /// call (real terminal dimensions), not at construction time (80×25 default).
    var pendingSessionID: String?

    /// Stores a resize that arrived while the initial snapshot handshake was in progress,
    /// so it can be flushed once the stream is established.
    private var pendingResizeDuringAttach: (cols: Int, rows: Int)?

    private let lock = NSLock()
    private var _connection: KytosPaneConnection?
    private var connection: KytosPaneConnection? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }
    /// Prevents multiple concurrent startStream calls from racing on the readQueue.
    private var _streaming = false
    private var streaming: Bool {
        get { lock.withLock { _streaming } }
        set { lock.withLock { _streaming = newValue } }
    }
    private let readQueue = DispatchQueue(label: "kytos.pane.stream.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "kytos.pane.stream.write", qos: .userInteractive)

    // MARK: - Start

    /// Starts streaming from the given pane session ID at the specified dimensions.
    /// Called from `sizeChanged` on the first layout, ensuring we use real terminal size.
    func startStream(sessionID: String, cols: Int, rows: Int) {
        guard let tv = terminalView else {
            kLog("[KytosDebug][PaneStream] startStream — no terminalView!")
            return
        }
        // Prevent multiple concurrent startStream calls from racing.
        guard !streaming else {
            kLog("[KytosDebug][PaneStream] startStream session=\(sessionID) — already streaming, skipping")
            return
        }
        streaming = true
        kLog("[KytosDebug][PaneStream] startStream session=\(sessionID) cols=\(cols) rows=\(rows)")

        readQueue.async { [weak self] in
            guard let self else { return }
            defer { self.streaming = false }

            var effectiveID = sessionID

            // Retry with backoff — the pane server may still be starting
            // (reconciliation runs asynchronously off the main thread).
            var conn: KytosPaneConnection?
            for attempt in 0..<10 {
                do {
                    conn = try KytosPaneClient.shared.openAttachConnection(
                        sessionID: effectiveID, cols: cols, rows: rows)
                    kLog("[KytosDebug][PaneStream] attach connected on attempt \(attempt)")
                    break
                } catch {
                    if attempt < 9 {
                        let delay = UInt32(100_000 * min(attempt + 1, 5)) // 100ms–500ms
                        usleep(delay)
                    } else {
                        kLog("[KytosDebug][PaneStream] Failed to attach to \(effectiveID) after 10 attempts: \(error)")
                        return
                    }
                }
            }
            guard let conn else { return }

            do {
                // The server subscribes us then resizes then sends response then snapshot.
                // The resize triggers SIGWINCH → shell redraws → deltas can arrive at
                // ANY point: before the response, between response and snapshot, or after.
                // Read messages in a loop, collecting deltas until we have both response + snapshot.
                var response: KytosPaneResponse?
                var snapshot: KytosPaneTerminalSnapshot?
                var earlyDeltas: [[UInt8]] = []

                var budget = 500
                while budget > 0 {
                    budget -= 1
                    guard let msg = try conn.readFullMessage() else {
                        kLog("[KytosDebug][PaneStream] readFullMessage returned nil (budget=\(budget))")
                        break
                    }
                    switch msg {
                    case .response(let resp):
                        response = resp
                        kLog("[KytosDebug][PaneStream] got response ok=\(resp.ok) msg=\(resp.message ?? "")")
                        if !resp.ok {
                            // Session not found — create a new one and retry
                            conn.close()
                            kLog("[KytosDebug][PaneStream] session \(effectiveID) not found, creating new")
                            if let newInfo = try? KytosPaneClient.shared.createSession(
                                commandLine: KytosSettings.shared.resolvedCommandLine()) {
                                effectiveID = newInfo.id
                                kLog("[KytosDebug][PaneStream] created replacement session \(effectiveID), retrying attach")
                                // Update layout on main thread
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("KytosPaneSessionReplaced"),
                                        object: nil,
                                        userInfo: ["oldID": sessionID, "newID": effectiveID])
                                }
                                // Retry attach with new session
                                if let newConn = try? KytosPaneClient.shared.openAttachConnection(
                                    sessionID: effectiveID, cols: cols, rows: rows) {
                                    self.handleAttachResponse(conn: newConn, tv: tv, sessionID: effectiveID, cols: cols, rows: rows)
                                }
                            }
                            return
                        }
                    case .snapshot(let snap):
                        snapshot = snap
                        kLog("[KytosDebug][PaneStream] got snapshot \(snap.cols)x\(snap.rows), \(snap.lines.count) lines")
                    case .delta(let delta):
                        earlyDeltas.append(delta.toANSIBytes())
                        kLog("[KytosDebug][PaneStream] got early delta")
                    case .other:
                        kLog("[KytosDebug][PaneStream] got .other message")
                        break
                    }
                    if response != nil && snapshot != nil { break }
                }

                guard let snap = snapshot else {
                    kLog("[KytosDebug][PaneStream] No snapshot received for session \(effectiveID) (response=\(response != nil))")
                    self.notifyStreamFailed()
                    return
                }
                self.finishAttach(conn: conn, tv: tv, snapshot: snap, earlyDeltas: earlyDeltas, cols: cols, rows: rows)
            } catch {
                kLog("[KytosDebug][PaneStream] Stream setup error for \(effectiveID): \(error)")
                self.notifyStreamFailed()
            }
        }
    }

    // MARK: - Attach Helpers

    private func handleAttachResponse(conn: KytosPaneConnection, tv: TerminalView, sessionID: String, cols: Int, rows: Int) {
        do {
            var response: KytosPaneResponse?
            var snapshot: KytosPaneTerminalSnapshot?
            var earlyDeltas: [[UInt8]] = []

            var budget = 500
            while budget > 0 {
                budget -= 1
                guard let msg = try conn.readFullMessage() else { break }
                switch msg {
                case .response(let resp):
                    response = resp
                    kLog("[KytosDebug][PaneStream] got response ok=\(resp.ok) msg=\(resp.message ?? "")")
                    if !resp.ok { return }
                case .snapshot(let snap):
                    snapshot = snap
                    kLog("[KytosDebug][PaneStream] got snapshot \(snap.cols)x\(snap.rows), \(snap.lines.count) lines")
                case .delta(let delta):
                    earlyDeltas.append(delta.toANSIBytes())
                case .other: break
                }
                if response != nil && snapshot != nil { break }
            }
            guard let snap = snapshot else { return }
            finishAttach(conn: conn, tv: tv, snapshot: snap, earlyDeltas: earlyDeltas, cols: cols, rows: rows)
        } catch {
            kLog("[KytosDebug][PaneStream] handleAttachResponse error: \(error)")
        }
    }

    private func finishAttach(conn: KytosPaneConnection, tv: TerminalView, snapshot: KytosPaneTerminalSnapshot, earlyDeltas: [[UInt8]], cols: Int, rows: Int) {
        self.connection = conn
        let bytes = snapshot.toANSIBytes()
        kLog("[KytosDebug][PaneStream] Feeding snapshot \(snapshot.cols)x\(snapshot.rows) (\(bytes.count) bytes, \(snapshot.lines.count) lines) to terminal")
        DispatchQueue.main.async {
            tv.feed(byteArray: bytes[...])
            for delta in earlyDeltas {
                tv.feed(byteArray: delta[...])
            }
        }
        // Inform the server of the real terminal size; it will SIGWINCH the shell.
        // Also flush any resize that arrived while the snapshot handshake was in progress.
        let finalCols = pendingResizeDuringAttach?.cols ?? cols
        let finalRows = pendingResizeDuringAttach?.rows ?? rows
        pendingResizeDuringAttach = nil
        try? conn.sendBinaryResize(cols: finalCols, rows: finalRows)
        self.readLoop(conn: conn, tv: tv)
    }

    // MARK: - Disconnect

    /// Close the streaming connection, breaking the blocking readLoop.
    func disconnect() {
        if let conn = connection {
            conn.cancelled = true       // Tell poll-based readExact to exit
            conn.shutdownSocket()       // Wake any blocked poll/read
            conn.close()
        }
        connection = nil
    }

    /// Posts `KytosStreamFailed` so the owning view can show a reconnecting overlay.
    private func notifyStreamFailed() {
        guard let tid = terminalID else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosStreamFailed"),
                object: tid)
        }
    }

    // MARK: - Read Loop

    private func readLoop(conn: KytosPaneConnection, tv: TerminalView) {
        while true {
            guard let msg = try? conn.readFullMessage() else { break }
            if case .delta(let delta) = msg {
                let bytes = delta.toANSIBytes()
                DispatchQueue.main.async {
                    tv.feed(byteArray: bytes[...])
                }
            }
        }
        kLog("[KytosDebug][PaneStream] Stream ended for terminal \(terminalID?.uuidString.prefix(8) ?? "?")")
        connection = nil
        // Don't remove terminal from manager — the view can reconnect on next sizeChanged.
    }

    // MARK: - TerminalViewDelegate overrides

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let conn = connection else { return }
        let inputData = Data(data)
        writeQueue.async {
            try? conn.sendBinaryInput(inputData)
        }
    }

    override func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }

        // If we haven't connected yet and have a pending session, this first
        // sizeChanged gives us the real terminal dimensions — start the stream now.
        if connection == nil, let sid = pendingSessionID {
            pendingSessionID = nil
            lastCols = newCols
            lastRows = newRows
            kLog("[KytosDebug][PaneStream] sizeChanged triggering startStream for pending session \(sid), \(newCols)x\(newRows)")
            startStream(sessionID: sid, cols: newCols, rows: newRows)
            return
        }

        // Resize arrived while the initial snapshot handshake is still in progress —
        // buffer it so finishAttach can flush it once the connection is live.
        if streaming, connection == nil {
            pendingResizeDuringAttach = (cols: newCols, rows: newRows)
            lastCols = newCols
            lastRows = newRows
            return
        }

        // Reconnect if the stream died (connection nil + streaming cleared by readLoop)
        if connection == nil, !streaming, pendingSessionID == nil,
           let sid = terminalID.flatMap({ KytosTerminalManager.shared.sessionID(for: $0) }) {
            lastCols = newCols
            lastRows = newRows
            kLog("[KytosDebug][PaneStream] sizeChanged reconnecting for session \(sid), \(newCols)x\(newRows)")
            startStream(sessionID: sid, cols: newCols, rows: newRows)
            return
        }

        guard connection != nil,
              newCols != lastCols || newRows != lastRows else { return }
        lastCols = newCols
        lastRows = newRows
        // Dispatch socket write off the main thread to prevent UI freezes.
        let conn = connection
        writeQueue.async {
            try? conn?.sendBinaryResize(cols: newCols, rows: newRows)
        }
    }

    override func processTerminated(_ source: SwiftTerm.LocalProcess, exitCode: Int32?) {
        // pane server manages process lifecycle; we don't handle this here
    }
}
#endif
