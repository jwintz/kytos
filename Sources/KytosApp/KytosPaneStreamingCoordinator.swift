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
    private var resizeReconnectItem: DispatchWorkItem?

    /// Tracks whether the initial snapshot (with scrollback) has been fed to the terminal.
    /// On reconnects we only replay the visible screen, preserving the existing scrollback ring.
    private var hasCompletedInitialAttach = false

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
    /// Monotonically increasing counter. Incremented by `disconnect()` so that a
    /// stale readQueue `defer` block does not clear `streaming` for a newer stream.
    private var _streamGen: Int = 0
    private var streamGen: Int {
        get { lock.withLock { _streamGen } }
        set { lock.withLock { _streamGen = newValue } }
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
        let gen = streamGen
        kLog("[KytosDebug][PaneStream] startStream session=\(sessionID) cols=\(cols) rows=\(rows)")

        readQueue.async { [weak self] in
            guard let self else { return }
            defer {
                // Only clear `streaming` if no disconnect() invalidated this generation.
                if self.streamGen == gen {
                    self.streaming = false
                }
            }

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
                        earlyDeltas.append(delta.toANSIBytes(terminalRows: rows))
                        kLog("[KytosDebug][PaneStream] got early delta")
                    case .rawOutput:
                        // Raw bytes during attach are already captured in the snapshot;
                        // skip to avoid duplicate output.
                        break
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
                    earlyDeltas.append(delta.toANSIBytes(terminalRows: rows))
                case .rawOutput:
                    // Raw bytes during attach are already in the snapshot; skip.
                    break
                case .other: break
                }
                if response != nil && snapshot != nil { break }
            }
            guard let snap = snapshot else {
                kLog("[KytosDebug][PaneStream] handleAttachResponse: no snapshot for session \(sessionID)")
                self.notifyStreamFailed()
                return
            }
            finishAttach(conn: conn, tv: tv, snapshot: snap, earlyDeltas: earlyDeltas, cols: cols, rows: rows)
        } catch {
            kLog("[KytosDebug][PaneStream] handleAttachResponse error: \(error)")
        }
    }

    private func finishAttach(conn: KytosPaneConnection, tv: TerminalView, snapshot: KytosPaneTerminalSnapshot, earlyDeltas: [[UInt8]], cols: Int, rows: Int) {
        self.connection = conn
        let bytes = snapshot.toANSIBytes()
        if hasCompletedInitialAttach {
            // Reconnect (e.g. after resize): clear stale scrollback before feeding fresh snapshot.
            kLog("[KytosDebug][PaneStream] Reconnect: resetting scrollback, feeding full snapshot \(snapshot.cols)x\(snapshot.rows) (\(bytes.count) bytes, \(snapshot.scrollbackLines.count) scrollback lines)")
            DispatchQueue.main.async {
                tv.terminal.resetToInitialState()
                tv.feed(byteArray: bytes[...])
                for delta in earlyDeltas {
                    tv.feed(byteArray: delta[...])
                }
            }
        } else {
            hasCompletedInitialAttach = true
            kLog("[KytosDebug][PaneStream] Initial attach: feeding snapshot \(snapshot.cols)x\(snapshot.rows) (\(bytes.count) bytes, \(snapshot.scrollbackLines.count) scrollback lines)")
            DispatchQueue.main.async { [weak self] in
                tv.feed(byteArray: bytes[...])
                for delta in earlyDeltas {
                    tv.feed(byteArray: delta[...])
                }
                guard let tid = self?.terminalID else { return }
                NotificationCenter.default.post(
                    name: NSNotification.Name("KytosStreamAttached"), object: tid)
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
        resizeReconnectItem?.cancel()
        resizeReconnectItem = nil
        streamGen += 1  // Invalidate the old readQueue defer
        if let conn = connection {
            conn.cancelled = true       // Tell poll-based readExact to exit
            conn.shutdownSocket()       // Wake any blocked poll/read
            conn.close()
        }
        connection = nil
        streaming = false              // Allow immediate reconnection
    }

    /// Reconnects the stream using the last known dimensions and session ID.
    /// Called by the "Retry" button in the stream-failed overlay.
    func retry() {
        guard !streaming, connection == nil else { return }
        guard let tid = terminalID,
              let sid = KytosTerminalManager.shared.sessionID(for: tid),
              lastCols > 0, lastRows > 0 else {
            // Fall back to forcing a layout pass — sizeChanged will reconnect.
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.needsLayout = true
                self?.terminalView?.layoutSubtreeIfNeeded()
            }
            return
        }
        kLog("[KytosDebug][PaneStream] retry() — reconnecting session=\(sid) \(lastCols)x\(lastRows)")
        startStream(sessionID: sid, cols: lastCols, rows: lastRows)
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
        var readError: Error?
        while true {
            do {
                guard let msg = try conn.readFullMessage() else {
                    kLog("[KytosDebug][PaneStream] readFullMessage returned nil (EOF or cancelled)")
                    break
                }
                if case .rawOutput(let data) = msg {
                    // Feed raw PTY bytes directly — preserves sixel, kitty graphics,
                    // and all DCS sequences that cell-based deltas would lose.
                    let bytes = [UInt8](data)
                    DispatchQueue.main.async {
                        tv.feed(byteArray: bytes[...])
                    }
                } else if case .delta(_) = msg {
                    // Deltas are still sent alongside rawOutput but we prefer raw
                    // bytes for full fidelity. Skip cell-based deltas.
                }
            } catch {
                readError = error
                break
            }
        }
        let tid = terminalID?.uuidString.prefix(8) ?? "?"
        if let err = readError {
            kLog("[KytosDebug][PaneStream] Stream error for terminal \(tid): \(err)")
        } else {
            kLog("[KytosDebug][PaneStream] Stream ended for terminal \(tid)")
        }
        connection = nil

        // Auto-reconnect unless the disconnect was intentional (cancelled).
        guard !conn.cancelled else {
            kLog("[KytosDebug][PaneStream] Stream cancelled for \(tid), not reconnecting")
            return
        }
        guard let termID = terminalID,
              let sid = KytosTerminalManager.shared.sessionID(for: termID),
              lastCols > 0, lastRows > 0 else {
            kLog("[KytosDebug][PaneStream] Cannot auto-reconnect \(tid) — missing session info")
            return
        }
        // Backoff reconnect on readQueue (we're already on it).
        for attempt in 0..<5 {
            let delay = UInt32(500_000 * min(attempt + 1, 3)) // 500ms–1.5s
            usleep(delay)
            guard !conn.cancelled else { return }
            kLog("[KytosDebug][PaneStream] Auto-reconnect attempt \(attempt) for \(tid) session=\(sid)")
            streaming = false
            startStream(sessionID: sid, cols: lastCols, rows: lastRows)
            return  // startStream dispatches to readQueue again
        }
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
        // SwiftUI can fire sizeChanged with a tiny probe size (e.g. 2×1) during the
        // initial layout pass, before the view reaches its real dimensions. If we
        // start the stream at that size the pane server resizes the live session to
        // 2×1 before snapshotting, destroying any existing scrollback. Ignore any
        // dimensions that couldn't represent a usable terminal.
        guard newCols >= 10, newRows >= 2 else { return }

        // If we haven't connected yet and have a pending session, this first
        // sizeChanged gives us the real terminal dimensions — start the stream now.
        if connection == nil, let sid = pendingSessionID {
            pendingSessionID = nil
            lastCols = newCols
            lastRows = newRows
            // Apply scrollback setting now — setupOptions already ran and may have
            // reset it to the default (500). changeScrollback is safe post-layout.
            let scrollback = KytosSettings.shared.scrollbackSize
            if source.terminal.options.scrollback != scrollback {
                source.terminal.changeScrollback(scrollback)
                kLog("[KytosDebug][PaneStream] Applied scrollback setting: \(scrollback)")
            }
            kLog("[KytosDebug][PaneStream] sizeChanged triggering startStream for pending session \(sid), \(newCols)x\(newRows)")
            startStream(sessionID: sid, cols: newCols, rows: newRows)
            return
        }

        // Resize arrived while the initial snapshot handshake is still in progress —
        // buffer it so finishAttach can flush it once the connection is live.
        if streaming, connection == nil, resizeReconnectItem == nil {
            pendingResizeDuringAttach = (cols: newCols, rows: newRows)
            lastCols = newCols
            lastRows = newRows
            return
        }

        // Reconnect if the stream died (connection nil + streaming cleared by readLoop)
        // but NOT if a debounced resize reconnect is already pending.
        if connection == nil, !streaming, pendingSessionID == nil, resizeReconnectItem == nil,
           let sid = terminalID.flatMap({ KytosTerminalManager.shared.sessionID(for: $0) }) {
            lastCols = newCols
            lastRows = newRows
            kLog("[KytosDebug][PaneStream] sizeChanged reconnecting for session \(sid), \(newCols)x\(newRows)")
            startStream(sessionID: sid, cols: newCols, rows: newRows)
            return
        }

        // Active connection or pending resize — handle size change.
        guard newCols != lastCols || newRows != lastRows else { return }
        lastCols = newCols
        lastRows = newRows

        // Send in-band resize so the shell gets SIGWINCH immediately.
        // Keep the stream alive — disconnecting here races with the
        // debounced reconnect and can leave the connection permanently
        // cancelled (the next resize's disconnect kills the just-reconnected
        // stream before the readLoop has a chance to process any deltas).
        if let conn = connection {
            try? conn.sendBinaryResize(cols: newCols, rows: newRows)
        }

        // Debounced snapshot refresh — reconnect once resize settles to get
        // a clean snapshot at the final dimensions. This avoids garbled TUI
        // output from deltas computed at intermediate sizes.
        resizeReconnectItem?.cancel()
        let cols = newCols
        let rows = newRows
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeReconnectItem = nil
            guard let sid = self.terminalID.flatMap({ KytosTerminalManager.shared.sessionID(for: $0) }) else { return }
            kLog("[KytosDebug][PaneStream] Resize settled, reconnecting \(cols)x\(rows)")
            self.disconnect()
            self.startStream(sessionID: sid, cols: cols, rows: rows)
        }
        resizeReconnectItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    override func processTerminated(_ source: SwiftTerm.LocalProcess, exitCode: Int32?) {
        // pane server manages process lifecycle; we don't handle this here
    }
}
#endif
