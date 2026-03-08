#if os(iOS)
import Foundation
import SwiftTerm
import UIKit
import ios_system

/// Bridges ios_system's thread-local I/O to SwiftTerm on iPadOS.
///
/// Architecture:
///   User types → send(source:data:) → write to stdin pipe
///                                        ↓
///                                 ios_system reads thread_stdin
///                                 ios_system writes thread_stdout
///                                        ↓
///                                 read from stdout pipe → feed(byteArray:) → TerminalView
final class KytosIOSSystemCoordinator: NSObject, TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var terminalID: UUID?
    var lastCols: Int = -1
    var lastRows: Int = -1

    // POSIX pipe file descriptors
    private var stdinReadFD: Int32 = -1
    private var stdinWriteFD: Int32 = -1
    private var stdoutReadFD: Int32 = -1
    private var stdoutWriteFD: Int32 = -1

    private var shellThread: Thread?
    private var readThread: Thread?
    private var isRunning = false

    // MARK: - Lifecycle

    func start(commandLine: [String]? = nil) {
        guard !isRunning else { return }
        isRunning = true

        // Set up home directory
        let home = KytosIOSFilesystem.setupHomeDirectory()

        // Create pipe pairs
        var stdinPipe: [Int32] = [0, 0]
        var stdoutPipe: [Int32] = [0, 0]
        pipe(&stdinPipe)
        pipe(&stdoutPipe)

        stdinReadFD = stdinPipe[0]
        stdinWriteFD = stdinPipe[1]
        stdoutReadFD = stdoutPipe[0]
        stdoutWriteFD = stdoutPipe[1]

        // Initialize ios_system environment
        initializeEnvironment()

        // Set environment variables
        setenv("HOME", home, 1)
        setenv("TERM", "xterm-256color", 1)
        setenv("COLORTERM", "truecolor", 1)
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("SHELL", "dash", 1)
        if lastCols > 0 { setenv("COLUMNS", "\(lastCols)", 1) }
        if lastRows > 0 { setenv("LINES", "\(lastRows)", 1) }

        // Add ~/Library/bin and ~/Documents/bin to PATH
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(home)/Library/bin:\(home)/Documents/bin:\(existingPath)", 1)

        // Start stdout read loop
        let readFD = stdoutReadFD
        readThread = Thread { [weak self] in
            self?.readLoop(fd: readFD)
        }
        readThread?.name = "KytosIOSSystem.stdout"
        readThread?.qualityOfService = .userInteractive
        readThread?.start()

        // Start shell on background thread — dash runs its own interactive
        // command loop, streaming output as it's produced (like iTerm2's
        // select(2)-based read loop on PTY file descriptors).
        let inFD = stdinReadFD
        let outFD = stdoutWriteFD
        shellThread = Thread { [weak self] in
            self?.shellLoop(stdinFD: inFD, stdoutFD: outFD)
        }
        shellThread?.name = "KytosIOSSystem.shell"
        shellThread?.qualityOfService = .userInitiated
        shellThread?.start()
    }

    func disconnect() {
        isRunning = false
        if stdinWriteFD >= 0 { close(stdinWriteFD); stdinWriteFD = -1 }
        if stdinReadFD >= 0 { close(stdinReadFD); stdinReadFD = -1 }
        if stdoutWriteFD >= 0 { close(stdoutWriteFD); stdoutWriteFD = -1 }
        if stdoutReadFD >= 0 { close(stdoutReadFD); stdoutReadFD = -1 }
    }

    deinit {
        disconnect()
    }

    // MARK: - Shell Loop

    private func shellLoop(stdinFD: Int32, stdoutFD: Int32) {
        // Wrap raw FDs in FILE* for ios_system's thread-local streams
        let stdinFile = fdopen(stdinFD, "r")
        let stdoutFile = fdopen(stdoutFD, "w")
        // Separate fdopen for stderr so closing doesn't double-close stdoutFD
        let stderrFD = dup(stdoutFD)
        let stderrFile = fdopen(stderrFD, "w")

        guard let stdinFile, let stdoutFile, let stderrFile else {
            return
        }

        // Disable buffering so output streams to the read loop immediately,
        // matching iTerm2's approach of feeding data as soon as it arrives.
        setvbuf(stdoutFile, nil, _IONBF, 0)
        setvbuf(stderrFile, nil, _IONBF, 0)

        // Set thread-local streams for ios_system
        thread_stdin = stdinFile
        thread_stdout = stdoutFile
        thread_stderr = stderrFile

        // Launch dash as an interactive shell — it owns the command loop,
        // reading from thread_stdin character-by-character and writing output
        // to thread_stdout as it goes. This gives true streaming (no batching).
        ios_system("dash -i")

        // Shell exited — clean up
        fclose(stdinFile)
        fclose(stdoutFile)
        fclose(stderrFile)
    }

    // MARK: - Read Loop

    private func readLoop(fd: Int32) {
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while isRunning {
            let bytesRead = read(fd, buffer, bufferSize)
            if bytesRead <= 0 { break }

            let data = Array(UnsafeBufferPointer(start: buffer, count: bytesRead))
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.feed(byteArray: data[...])
            }
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        guard stdinWriteFD >= 0 else { return }
        let bytes = Array(data)
        bytes.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                _ = write(stdinWriteFD, base, ptr.count)
            }
        }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != lastCols || newRows != lastRows else { return }
        lastCols = newCols
        lastRows = newRows
        // ios_system has no SIGWINCH; update env vars for TUI apps
        setenv("COLUMNS", "\(newCols)", 1)
        setenv("LINES", "\(newRows)", 1)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
    }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
#endif
