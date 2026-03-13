// KytosWidgetSnapshot.swift — shared data model between app and widget targets
// Linked into: Kytos-macOS, Kytos-Widget-macOS

import Foundation

private func widgetSnapshotLog(_ message: @autoclosure () -> String) {
    fputs("[WidgetSnapshot] \(message())\n", stderr)
}

public struct KytosWidgetTerminal: Codable, Identifiable {
    public let id: UUID
    public let process: String
}

public struct KytosWidgetWindow: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let terminals: [KytosWidgetTerminal]
    public var terminalCount: Int { terminals.count }
    public var topProcess: String? { terminals.first?.process }
}

/// A flattened process tree node for widget display.
public struct KytosWidgetProcessNode: Codable, Identifiable {
    public let id: UUID
    public let pid: Int32
    public let command: String
    public let depth: Int
    public let rssMB: Double
    public let cpu: String
    public let isDeepest: Bool

    public init(pid: Int32, command: String, depth: Int, rssMB: Double, cpu: String, isDeepest: Bool) {
        self.id = UUID()
        self.pid = pid
        self.command = command
        self.depth = depth
        self.rssMB = rssMB
        self.cpu = cpu
        self.isDeepest = isDeepest
    }
}

/// A pane entry for navigator-style widget display.
public struct KytosWidgetPane: Codable, Identifiable {
    public let id: UUID
    public let processName: String
    public let path: String
    /// SF Symbol names representing position in split tree (e.g. "rectangle.lefthalf.filled").
    public let positionSymbols: [String]
    public let isFocused: Bool

    public init(id: UUID, processName: String, path: String, positionSymbols: [String], isFocused: Bool) {
        self.id = id
        self.processName = processName
        self.path = path
        self.positionSymbols = positionSymbols
        self.isFocused = isFocused
    }
}

public struct KytosWidgetSnapshot: Codable {
    public let date: Date
    public let version: UInt64
    public let windows: [KytosWidgetWindow]
    /// Flattened process tree for large widget display.
    public let processTree: [KytosWidgetProcessNode]
    /// Navigator-style pane list for medium widget display.
    public let panes: [KytosWidgetPane]
    public var totalTerminals: Int { windows.reduce(0) { $0 + $1.terminalCount } }

    public init(
        date: Date,
        version: UInt64 = 0,
        windows: [KytosWidgetWindow],
        processTree: [KytosWidgetProcessNode] = [],
        panes: [KytosWidgetPane] = []
    ) {
        self.date = date
        self.version = version
        self.windows = windows
        self.processTree = processTree
        self.panes = panes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        version = try c.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
        windows = try c.decode([KytosWidgetWindow].self, forKey: .windows)
        processTree = try c.decodeIfPresent([KytosWidgetProcessNode].self, forKey: .processTree) ?? []
        panes = try c.decodeIfPresent([KytosWidgetPane].self, forKey: .panes) ?? []
    }

    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    private static var snapshotURL: URL? {
        // The widget is sandboxed; it reads from its own container's Application Support.
        // The main app is NOT sandboxed, so it writes directly into the widget's container
        // using the same resolved path. This avoids needing App Group provisioning.
        let dir: URL
        if isAppExtension {
            // Widget: read from own Application Support (sandbox-relative)
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                widgetSnapshotLog("Missing widget Application Support directory")
                return nil
            }
            dir = appSupport.appendingPathComponent("Kytos", isDirectory: true)
        } else {
            // Main app (non-sandboxed): write into the widget's container directly
            let widgetContainer = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/me.jwintz.Kytos.KytosWidget/Data/Library/Application Support/Kytos", isDirectory: true)
            dir = widgetContainer
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            widgetSnapshotLog("Failed to create snapshot dir: \(error)")
            return nil
        }
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    public static func read() -> KytosWidgetSnapshot? {
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(KytosWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    public static func write(_ snapshot: KytosWidgetSnapshot) {
        guard let snapshotURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            widgetSnapshotLog("Failed to write snapshot: \(error)")
        }
    }

    public static func placeholder() -> KytosWidgetSnapshot {
        KytosWidgetSnapshot(
            date: .now,
            version: 0,
            windows: [
                KytosWidgetWindow(id: UUID(), name: "main", terminals: [
                    KytosWidgetTerminal(id: UUID(), process: "zsh"),
                    KytosWidgetTerminal(id: UUID(), process: "vim"),
                ]),
                KytosWidgetWindow(id: UUID(), name: "server", terminals: [
                    KytosWidgetTerminal(id: UUID(), process: "python"),
                ]),
            ],
            processTree: [
                KytosWidgetProcessNode(pid: 1000, command: "Kytos", depth: 0, rssMB: 42, cpu: "0.1%", isDeepest: false),
                KytosWidgetProcessNode(pid: 1001, command: "login", depth: 1, rssMB: 1, cpu: "0.0%", isDeepest: false),
                KytosWidgetProcessNode(pid: 1002, command: "zsh", depth: 2, rssMB: 8, cpu: "0.0%", isDeepest: false),
                KytosWidgetProcessNode(pid: 1003, command: "vim", depth: 3, rssMB: 12, cpu: "0.2%", isDeepest: true),
            ],
            panes: [
                KytosWidgetPane(id: UUID(), processName: "vim", path: "~/Projects/kytos", positionSymbols: ["rectangle.lefthalf.filled"], isFocused: true),
                KytosWidgetPane(id: UUID(), processName: "zsh", path: "~/Projects/kytos", positionSymbols: ["rectangle.righthalf.filled"], isFocused: false),
            ]
        )
    }
}
