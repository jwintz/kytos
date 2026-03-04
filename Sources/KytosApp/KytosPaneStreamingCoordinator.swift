#if os(macOS)
import Foundation
import SwiftTerm

/// Streaming terminal coordinator backed by a pane server session.
/// Subclasses `MacOSLocalProcessTerminalCoordinator` so it fits the existing
/// `KytosTerminalManager.ManagedTerminal` type without requiring a coordinator
/// type refactor. The inherited `process` is never started.
final class KytosPaneStreamingCoordinator: MacOSLocalProcessTerminalCoordinator {

    private var connection: KytosPaneConnection?
    private let readQueue = DispatchQueue(label: "kytos.pane.stream", qos: .userInitiated)

    // MARK: - Start

    /// Starts streaming from the given pane session ID.
    /// Call instead of `start(commandLine:)`.
    func startStream(sessionID: String) {
        guard let tv = terminalView else { return }
        let cols = tv.terminal.cols > 0 ? tv.terminal.cols : 80
        let rows = tv.terminal.rows > 0 ? tv.terminal.rows : 24

        readQueue.async { [weak self] in
            guard let self else { return }
            do {
                let conn = try KytosPaneClient.shared.openAttachConnection(
                    sessionID: sessionID, cols: cols, rows: rows)

                // Read attach response
                guard case .response(let resp)? = try conn.readFullMessage(), resp.ok else {
                    print("[KytosDebug][PaneStream] Attach response not ok for session \(sessionID)")
                    return
                }
                // Read initial snapshot
                guard case .snapshot(let snap)? = try conn.readFullMessage() else {
                    print("[KytosDebug][PaneStream] No snapshot received for session \(sessionID)")
                    return
                }
                self.connection = conn

                let bytes = snap.toANSIBytes()
                DispatchQueue.main.async {
                    tv.feed(byteArray: bytes[...])
                }
                print("[KytosDebug][PaneStream] Attached to \(sessionID), snapshot \(snap.cols)x\(snap.rows)")
                self.readLoop(conn: conn, tv: tv)
            } catch {
                print("[KytosDebug][PaneStream] Failed to attach to \(sessionID): \(error)")
            }
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
        print("[KytosDebug][PaneStream] Stream ended for terminal \(terminalID?.uuidString.prefix(8) ?? "?")")
        if let id = terminalID {
            DispatchQueue.main.async {
                KytosTerminalManager.shared.removeTerminal(id: id)
            }
        }
        connection = nil
    }

    // MARK: - TerminalViewDelegate overrides

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let conn = connection else { return }
        try? conn.sendBinaryInput(Data(data))
    }

    override func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let conn = connection, newCols > 0, newRows > 0,
              newCols != lastCols || newRows != lastRows else { return }
        lastCols = newCols
        lastRows = newRows
        try? conn.sendBinaryResize(cols: newCols, rows: newRows)
    }

    override func processTerminated(_ source: SwiftTerm.LocalProcess, exitCode: Int32?) {
        // pane server manages process lifecycle; we don't handle this here
    }
}
#endif
