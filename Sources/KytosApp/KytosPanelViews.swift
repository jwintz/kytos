// KytosPanelViews.swift — navigator sidebar + inspector panels

import SwiftUI
import Foundation

// MARK: - Tmux Monitor

@Observable
@MainActor
final class TmuxMonitor {
    static let shared = TmuxMonitor()

    struct Session: Identifiable, Hashable, Sendable {
        let name: String
        let windows: Int
        let attached: Bool
        var id: String { name }
    }

    private(set) var sessions: [Session] = []
    private(set) var isServerRunning = false
    @ObservationIgnored private var timer: Timer?

    private init() {
        // Init is async — first poll happens on next runloop tick
        // Schedule first refresh and timer after init completes
        DispatchQueue.main.async { [weak self] in
            self?.startPolling()
        }
    }

    private func startPolling() {
        pollOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }

    private func pollOnce() {
        Task.detached {
            let result = Self.queryTmux()
            await MainActor.run { [weak self] in
                self?.sessions = result.sessions
                self?.isServerRunning = result.running
            }
        }
    }

    /// Runs tmux list-sessions off the main thread. Returns parsed results.
    nonisolated private static func queryTmux() -> (running: Bool, sessions: [Session]) {
        guard let tmuxPath = findTmux() else {
            return (false, [])
        }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_attached}"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, [])
        }
        guard process.terminationStatus == 0 else {
            return (false, [])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return (false, [])
        }
        let sessions = output.split(separator: "\n").compactMap { line -> Session? in
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { return nil }
            return Session(
                name: String(parts[0]),
                windows: Int(parts[1]) ?? 0,
                attached: parts[2] == "1"
            )
        }
        return (true, sessions)
    }

    nonisolated private static func findTmux() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.pixi/bin/tmux" },
            Optional("/opt/homebrew/bin/tmux"),
            Optional("/usr/local/bin/tmux"),
            Optional("/usr/bin/tmux"),
        ]
        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

// MARK: - Sessions Sidebar

struct KytosSessionsSidebar: View {
    @Environment(KytosWorkspace.self) private var workspace
    @State private var tmux = TmuxMonitor.shared

    var body: some View {
        @Bindable var ws = workspace

        List {
            Section("Terminal") {
                HStack {
                    Image(systemName: "terminal")
                    TextField("Name", text: $ws.session.name)
                        .textFieldStyle(.plain)
                }
            }

            if tmux.isServerRunning {
                Section("tmux Sessions") {
                    ForEach(tmux.sessions) { session in
                        HStack {
                            Image(systemName: session.attached ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(session.attached ? .green : .secondary)
                            Text(session.name)
                            Spacer()
                            Text("\(session.windows)W")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Process Info View

struct KytosProcessInfoView: View {
    @Environment(KytosWorkspace.self) private var workspace
    @State private var tmux = TmuxMonitor.shared

    var body: some View {
        List {
            Section("Terminal") {
                LabeledContent("Session", value: workspace.session.name)
                LabeledContent("ID", value: workspace.session.id.uuidString.prefix(8))
            }

            if tmux.isServerRunning {
                Section("tmux") {
                    LabeledContent("Server", value: "Running")
                    LabeledContent("Sessions", value: "\(tmux.sessions.count)")
                    ForEach(tmux.sessions) { session in
                        LabeledContent(session.name, value: session.attached ? "attached" : "detached")
                    }
                }
            } else {
                Section("tmux") {
                    Text("No tmux server running")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Panel Empty State

struct KytosPanelEmpty: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
