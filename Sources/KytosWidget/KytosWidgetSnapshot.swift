// KytosWidgetSnapshot.swift — shared data model between app and widget targets
// Linked into: Kytos-macOS, Kytos-Widget-macOS

import Foundation

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

public struct KytosWidgetSnapshot: Codable {
    public let date: Date
    public let version: UInt64
    public let windows: [KytosWidgetWindow]
    /// Flattened process tree for large widget display.
    public let processTree: [KytosWidgetProcessNode]
    public var totalTerminals: Int { windows.reduce(0) { $0 + $1.terminalCount } }

    public init(
        date: Date,
        version: UInt64 = 0,
        windows: [KytosWidgetWindow],
        processTree: [KytosWidgetProcessNode] = []
    ) {
        self.date = date
        self.version = version
        self.windows = windows
        self.processTree = processTree
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        version = try c.decodeIfPresent(UInt64.self, forKey: .version) ?? 0
        windows = try c.decode([KytosWidgetWindow].self, forKey: .windows)
        processTree = try c.decodeIfPresent([KytosWidgetProcessNode].self, forKey: .processTree) ?? []
    }

    private static let widgetBundleID = "me.jwintz.Kytos.KytosWidget"
    private static let appGroupID = "group.me.jwintz.Kytos"

    /// Shared URL for widget snapshot data.
    /// The unsandboxed main app writes directly into the widget's container.
    /// The sandboxed widget reads from its own Application Support.
    private static var sharedURL: URL {
        let dir: URL
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kytos", isDirectory: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    /// URL used by the main app (unsandboxed on macOS) to write widget data.
    public static var appWriteURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/Kytos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    public static func read() -> KytosWidgetSnapshot? {
        guard let data = try? Data(contentsOf: sharedURL),
              let snapshot = try? JSONDecoder().decode(KytosWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    public static func write(_ snapshot: KytosWidgetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: appWriteURL, options: .atomic)
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
            ]
        )
    }
}
